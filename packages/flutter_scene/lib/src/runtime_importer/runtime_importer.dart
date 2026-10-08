import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';
import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/importer/gltf_light_units.dart';

import '../animation.dart';
import '../components/component.dart';
import '../components/directional_light_component.dart';
import '../components/image_based_light_component.dart';
import '../components/materials_variants_component.dart';
import '../components/point_light_component.dart';
import '../components/spot_light_component.dart';
import '../light.dart';
import '../material/material.dart';
import '../material/unlit_material.dart';
import '../mesh.dart';
import '../node.dart';
import '../skin.dart';
import '../texture/texture2d.dart';
import 'animation_builder.dart';
import 'geometry_builder.dart';
import 'gltf_import_worker.dart';
import 'gltf_resources.dart';
import 'material_builder.dart';
import 'skin_builder.dart';
import 'texture_builder.dart';

export 'package:flutter_scene/src/importer/gltf.dart'
    show GltfImportWarning, GltfWarningCallback;

export 'gltf_import_stats.dart' show GltfImportStats;
export 'gltf_resources.dart' show GltfResourceResolver;

/// Parse a GLB byte stream into a [Node] tree.
///
/// Returns a synthesized root node whose children are the root nodes of the
/// GLB's default scene. Each scene node is created and wired up to match the
/// glTF node hierarchy. [onWarning], when given, receives non-fatal import
/// issues (an unrecognized extension, an image that fell back to a
/// placeholder); without it they print instead.
///
/// The container and JSON parse, the meshopt decode and the primitive packing
/// run on a background isolate ([prepareGlbImport]), whose result moves back
/// without a copy; only the device buffers, textures, materials and nodes are
/// created here. On the web, where [compute] runs inline, all of it runs here.
/// The root's [Node.importStats] carries the bytes of the geometry uploaded.
Future<Node> importGlb(
  Uint8List bytes, {
  GltfWarningCallback? onWarning,
  int? maxTextureSize,
}) async {
  final result = await compute(prepareGlbImport, bytes);
  _deliverWarnings(result.warnings, onWarning);
  return _buildScene(
    result.unwrap(),
    null,
    onWarning: onWarning,
    maxTextureSize: maxTextureSize,
  );
}

/// Parse a multi-file glTF document into a [Node] tree.
///
/// [gltfJson] is the raw bytes of the `.gltf` file. [resolveUri] fetches
/// each external resource (the `.bin` buffer and image files) the
/// document references by relative URI, percent-decoded; `data:` URIs are
/// decoded internally and never reach the resolver. A document with more
/// than one buffer has every buffer concatenated and its bufferViews
/// rebased, the same normalization the offline importer performs.
/// [onWarning], when given, receives non-fatal import issues; without it
/// they print instead.
///
/// The JSON parse and the buffer fetches run on the calling isolate, since
/// [resolveUri] is the caller's; the meshopt decode and the primitive packing
/// run on a background isolate (see [importGlb]).
Future<Node> importGltf(
  Uint8List gltfJson, {
  required GltfResourceResolver resolveUri,
  GltfWarningCallback? onWarning,
  int? maxTextureSize,
}) async {
  final json = jsonDecode(utf8.decode(gltfJson)) as Map<String, Object?>;
  final doc = parseGltfJson(json);
  _deliverWarnings(doc.warnings, onWarning);
  // EXT_meshopt_compression placeholder buffers hold no data the decode path
  // reads, so they are never resolved.
  final placeholders = meshoptPlaceholderBuffers(doc);
  final normalized = normalizeGltfBuffers(doc, [
    for (int i = 0; i < doc.buffers.length; i++)
      if (placeholders.contains(i))
        null
      else
        await _resolveBufferBytes(doc.buffers[i].uri, resolveUri),
  ], glbBinaryChunk: Uint8List(0));
  return _buildScene(
    await compute(prepareGltfImport, normalized),
    resolveUri,
    onWarning: onWarning,
    maxTextureSize: maxTextureSize,
  );
}

// Delivers the parse-time warnings to onWarning, or prints them when absent.
void _deliverWarnings(
  List<GltfImportWarning> warnings,
  GltfWarningCallback? onWarning,
) {
  for (final warning in warnings) {
    if (onWarning != null) {
      onWarning(warning);
    } else {
      debugPrint('glTF import: $warning');
    }
  }
}

/// Builds the [Node] tree from a prepared import: its parsed document, its
/// resolved buffer, and its pre-packed primitives. Shared by the GLB and
/// multi-file glTF entry points. This is the half that needs the device, so
/// it runs on the calling isolate.
///
/// TODO(runtime-import-offload): the skin and animation accessor decode still
/// run here. They are small next to vertex packing, but could also move into
/// [prepareGltfImport] to fully offload a heavy import.
Future<Node> _buildScene(
  PreparedGltfImport prepared,
  GltfResourceResolver? resolveUri, {
  GltfWarningCallback? onWarning,
  int? maxTextureSize,
}) async {
  final doc = prepared.doc;
  final bufferData = prepared.bufferData;
  // Decode all textures up front so material construction can reference
  // them by index without per-material async work.
  final List<Texture2D> textures = await buildTextures(
    doc,
    bufferData,
    resolveUri: resolveUri,
    onWarning: onWarning,
    maxTextureSize: maxTextureSize,
  );
  final materials = await Future.wait([
    for (final material in doc.materials) buildMaterial(material, textures),
  ]);

  // Pre-allocate engine Node placeholders 1:1 with glTF nodes so children
  // can refer to them by index regardless of the order we visit them in.
  final List<Node> engineNodes = List.generate(doc.nodes.length, (_) => Node());

  // Collects each primitive's per-variant materials (KHR_materials_variants)
  // so the component attached to the root can swap them later.
  final List<MaterialsVariantBinding> variantBindings = [];

  for (int i = 0; i < doc.nodes.length; i++) {
    _populateNode(
      index: i,
      engineNode: engineNodes[i],
      gltfNode: doc.nodes[i],
      doc: doc,
      prepared: prepared,
      engineNodes: engineNodes,
      materials: materials,
      variantBindings: variantBindings,
    );
  }

  // Build skins (after nodes are wired so isJoint flags propagate correctly)
  // and attach them to nodes that reference them.
  final List<Skin> skins = [
    for (final s in doc.skins)
      buildSkin(
        gltfSkin: s,
        accessors: doc.accessors,
        bufferViews: doc.bufferViews,
        bufferData: bufferData,
        engineNodes: engineNodes,
        coordinatePolicy: GltfCoordinatePolicy.runtimeBoundary,
      ),
  ];
  for (int i = 0; i < doc.nodes.length; i++) {
    final skinIdx = doc.nodes[i].skin;
    if (skinIdx != null && skinIdx >= 0 && skinIdx < skins.length) {
      engineNodes[i].skin = skins[skinIdx];
    }
  }

  // Pick the default scene (or the first one, or empty).
  final sceneIndex = doc.scene ?? (doc.scenes.isNotEmpty ? 0 : null);
  // Keep source data untouched and convert once at the imported boundary.
  // Packed geometry carries its source winding so the renderer can combine
  // it with this mirror without rewriting indices or vertex data.
  final root =
      Node(
          name: 'root',
          localTransform: Matrix4.identity()..setEntry(2, 2, -1.0),
        )
        ..isImportRoot = true
        ..importStats = prepared.stats;
  if (doc.materialsVariants.isNotEmpty) {
    root.addComponent(
      MaterialsVariantsComponent.internal(
        doc.materialsVariants,
        variantBindings,
      ),
    );
  }
  final imageBasedLight = await _buildImageBasedLight(
    doc,
    bufferData,
    sceneIndex,
    resolveUri,
  );
  if (imageBasedLight != null) {
    root.addComponent(imageBasedLight);
  }
  if (sceneIndex != null && sceneIndex < doc.scenes.length) {
    for (final rootNodeIdx in doc.scenes[sceneIndex].nodes) {
      if (rootNodeIdx >= 0 && rootNodeIdx < engineNodes.length) {
        root.add(engineNodes[rootNodeIdx]);
      }
    }
  }

  // Build animations and attach them to the synthesized root, mirroring how
  // the scene realizer attaches them.
  for (final ga in doc.animations) {
    root.addParsedAnimation(
      buildAnimation(
        gltfAnimation: ga,
        accessors: doc.accessors,
        bufferViews: doc.bufferViews,
        bufferData: bufferData,
        engineNodes: engineNodes,
        coordinatePolicy: GltfCoordinatePolicy.runtimeBoundary,
      ),
    );
  }

  debugPrint(
    'Unpacking glTF (nodes: ${doc.nodes.length}, '
    'meshes: ${doc.meshes.length}, '
    'materials: ${doc.materials.length}, '
    'skins: ${doc.skins.length}, '
    'animations: ${doc.animations.length})',
  );

  return root;
}

void _populateNode({
  required int index,
  required Node engineNode,
  required GltfNode gltfNode,
  required GltfDocument doc,
  required PreparedGltfImport prepared,
  required List<Node> engineNodes,
  required List<Material> materials,
  required List<MaterialsVariantBinding> variantBindings,
}) {
  engineNode.name = resolveGltfNodeName(gltfNode.name, index);
  const coordinatePolicy = GltfCoordinatePolicy.runtimeBoundary;
  final matrix = gltfNode.matrix;
  if (matrix != null) {
    engineNode.localTransform = coordinatePolicy.convertTransform(matrix);
  } else {
    // Keep the authored TRS. Recovering it from the composed matrix puts
    // a mirrored bone's negative scale on the wrong axis, which breaks
    // animation blending.
    engineNode.setLocalTransformTrs(
      DecomposedTransform(
        translation: coordinatePolicy.convertPosition(
          gltfNode.translation ?? Vector3.zero(),
        ),
        rotation: coordinatePolicy.convertRotation(
          gltfNode.rotation ?? Quaternion.identity(),
        ),
        scale: gltfNode.scale?.clone() ?? Vector3(1.0, 1.0, 1.0),
      ),
    );
  }

  if (gltfNode.mesh != null) {
    final gltfMesh = doc.meshes[gltfNode.mesh!];
    final skinnedBounds = gltfNode.skin == null
        ? null
        : prepared.skinnedBounds[index];
    var triangles = 0;
    final primitives = <MeshPrimitive>[];
    for (int pi = 0; pi < gltfMesh.primitives.length; pi++) {
      final p = gltfMesh.primitives[pi];
      final packedPrimitive = prepared.packedFor(gltfNode, pi);
      // A null entry is a non-triangle topology skipped during packing; they
      // need shader/render-state support that flutter_scene's pipeline doesn't
      // currently expose.
      if (packedPrimitive == null) {
        debugPrint(
          'Skipping mesh primitive with unsupported topology mode ${p.mode}',
        );
        continue;
      }
      final triangle = triangles++;
      final geometry = geometryFromPacked(
        packedPrimitive,
        morphTargetNames: gltfMesh.targetNames,
        defaultMorphWeights: gltfMesh.weights,
        skinnedBounds: skinnedBounds != null && triangle < skinnedBounds.length
            ? skinnedBounds[triangle]
            : null,
      );
      final material = p.material != null
          ? materials[p.material!]
          : UnlitMaterial();
      final primitive = MeshPrimitive(geometry, material);
      if (p.variantMappings.isNotEmpty) {
        // Build each variant's material now (textures are already decoded)
        // so selection is a plain reassignment. A mapping that names the
        // default material index reuses the default instance.
        variantBindings.add(
          MaterialsVariantBinding(
            node: engineNode,
            primitiveIndex: primitives.length,
            defaultMaterial: material,
            materialsByVariant: {
              for (final entry in p.variantMappings.entries)
                if (entry.value >= 0 && entry.value < doc.materials.length)
                  entry.key: entry.value == p.material
                      ? material
                      : materials[entry.value],
            },
          ),
        );
      }
      primitives.add(primitive);
    }
    if (primitives.isNotEmpty) {
      engineNode.mesh = Mesh.primitives(primitives: primitives);
      // node.weights overrides the mesh defaults for this instance.
      final nodeWeights = gltfNode.weights;
      if (nodeWeights != null && engineNode.internalMorphWeights != null) {
        engineNode.setMorphWeights(nodeWeights);
      }
    }
  }

  final lightIndex = gltfNode.light;
  if (lightIndex != null && lightIndex >= 0 && lightIndex < doc.lights.length) {
    final component = _buildLightComponent(doc.lights[lightIndex]);
    if (component != null) {
      engineNode.addComponent(component);
    }
  }

  for (final childIndex in gltfNode.children) {
    if (childIndex < 0 || childIndex >= engineNodes.length) {
      throw Exception('glTF node child index $childIndex out of range');
    }
    engineNode.add(engineNodes[childIndex]);
  }
}

// Surfaces the default scene's EXT_lights_image_based light, resolving each
// specular face image's bytes so the caller can build an environment from
// them. Returns null when the document declares none.
Future<ImageBasedLightComponent?> _buildImageBasedLight(
  GltfDocument doc,
  Uint8List bufferData,
  int? sceneIndex,
  GltfResourceResolver? resolveUri,
) async {
  if (sceneIndex == null || sceneIndex >= doc.scenes.length) return null;
  final lightIndex = doc.scenes[sceneIndex].imageBasedLight;
  if (lightIndex == null ||
      lightIndex < 0 ||
      lightIndex >= doc.imageBasedLights.length) {
    return null;
  }
  final light = doc.imageBasedLights[lightIndex];
  final specular = <List<Uint8List>>[];
  for (final level in light.specularImages) {
    final faces = <Uint8List>[];
    for (final imageIndex in level) {
      final bytes = await resolveGltfImageBytes(
        doc,
        bufferData,
        imageIndex,
        resolveUri: resolveUri,
      );
      if (bytes == null) {
        debugPrint(
          'Skipping EXT_lights_image_based specular image $imageIndex, its '
          'bytes could not be sourced.',
        );
        continue;
      }
      faces.add(bytes);
    }
    if (faces.length == level.length) specular.add(faces);
  }
  return ImageBasedLightComponent.internal(
    name: light.name,
    rotation: light.rotation,
    intensity: light.intensity,
    irradianceCoefficients: light.irradianceCoefficients,
    specularImageSize: light.specularImageSize,
    specularImages: specular,
  );
}

// Builds the engine light component for a KHR_lights_punctual light, or null
// for an unsupported type. glTF lights emit along the node's local -Z axis, so
// directional and spot lights take that as their local direction. The node
// transform and imported boundary then aim them in native world space.
Component? _buildLightComponent(GltfPunctualLight light) {
  // The extension carries no shadow metadata, so imported lights do not add
  // shadow passes implicitly.
  final intensity = gltfLightIntensity(light);
  switch (light.type) {
    case 'directional':
      return DirectionalLightComponent.aimed(
        DirectionalLight(
          color: light.color.clone(),
          intensity: intensity,
          castsShadow: false,
        ),
        Vector3(0.0, 0.0, -1.0),
      );
    case 'point':
      return PointLightComponent(
        PointLight(
          color: light.color.clone(),
          intensity: intensity,
          range: light.range ?? 0.0,
        ),
      );
    case 'spot':
      return SpotLightComponent(
        SpotLight(
          direction: Vector3(0.0, 0.0, -1.0),
          color: light.color.clone(),
          intensity: intensity,
          range: light.range ?? 0.0,
          innerConeAngle: light.innerConeAngle,
          outerConeAngle: light.outerConeAngle,
          castsShadow: false,
        ),
      );
    default:
      debugPrint('Skipping unsupported KHR_lights_punctual type ${light.type}');
      return null;
  }
}

Future<Uint8List> _resolveBufferBytes(
  String? uri,
  GltfResourceResolver resolveUri,
) async {
  // A buffer without a uri is a GLB's embedded chunk, which a .gltf has none of.
  if (uri == null) return Uint8List(0);
  if (uri.startsWith('data:')) return decodeGltfDataUri(uri);
  return resolveUri(Uri.decodeComponent(uri));
}
