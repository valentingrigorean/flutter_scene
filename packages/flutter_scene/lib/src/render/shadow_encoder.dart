import 'package:flutter_scene/src/render/depth_raster.dart';
import 'package:flutter_scene/src/geometry/geometry.dart'
    show
        Geometry,
        bindUnskinnedFrameInfo,
        currentDrawInstanceFrame,
        positionOnlyLayoutOverRecords;
import 'package:flutter_scene/src/geometry/vertex_layout.dart'
    show VertexLayoutDescriptor;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart' show ShadowCasterFaces;
import 'package:flutter_scene/src/render/draw_recorder.dart';
import 'package:flutter_scene/src/material/material.dart'
    show MaskedDepthPass, Material;
import 'package:flutter_scene/src/material/instance_attributes.dart'
    show InstanceAttributeSchema;
import 'package:flutter_scene/src/render/instance_batching.dart';
import 'package:flutter_scene/src/fmat/fmat_ast.dart' show DepthSurfaceKind;
import 'package:flutter_scene/src/mesh_draw.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/mesh_draw_selection.dart';
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/scene_encoder.dart'
    show
        PipelineInputs,
        cachedRenderPipeline,
        drawOrRejectPipeline,
        tryResolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/material/vertex_attributes.dart';

/// Which shadow casters a [ShadowEncoder] draws, keyed off
/// `RenderItem.shadowStatic`. The shadow cache renders static casters into
/// reusable tiles and dynamic casters on top every frame.
enum ShadowCasterFilter { all, staticOnly, dynamicOnly }

/// Whether [item] belongs in a shadow map drawn under [filter] for a light
/// whose casters are limited to [casterChannelMask].
///
/// The view-independent half of [ShadowEncoder.submit] (frustum culling and
/// material opacity are the rest), pulled out so the filter and channel rules
/// are testable without a render pass. Ordered so the common rejection is a
/// plain flag read.
bool shadowCasterAccepted(
  RenderItem item,
  ShadowCasterFilter filter,
  int casterChannelMask,
) {
  if (filter == ShadowCasterFilter.staticOnly && !item.shadowStatic) {
    return false;
  }
  if (filter == ShadowCasterFilter.dynamicOnly && item.shadowStatic) {
    return false;
  }
  if (!item.castsShadows) return false;
  if ((item.lightChannelMask & casterChannelMask) == 0) return false;
  return item.visible;
}

/// The cull mode that keeps the faces [item] casts with: its node's
/// [RenderItem.shadowCasterFaces], or the light's [lightFaces] when the node
/// states none. Rendering front faces means culling back faces, and vice
/// versa.
gpu.CullMode shadowCasterCullMode(
  RenderItem item,
  ShadowCasterFaces lightFaces,
) => switch (item.shadowCasterFaces ?? lightFaces) {
  ShadowCasterFaces.front => gpu.CullMode.backFace,
  ShadowCasterFaces.back => gpu.CullMode.frontFace,
  ShadowCasterFaces.both => gpu.CullMode.none,
};

/// The end of the instanced shadow draw that starts at [start]: the casters
/// [depthBatchEnd] merges, cut where a caster records other faces than the
/// first under a light that casts with [lightFaces].
int shadowBatchEnd(
  List<RenderItem> records,
  int start,
  ShadowCasterFaces lightFaces,
) {
  final end = depthBatchEnd(records, start);
  final faces = records[start].shadowCasterFaces ?? lightFaces;
  var cut = start + 1;
  while (cut < end && (records[cut].shadowCasterFaces ?? lightFaces) == faces) {
    cut++;
  }
  return cut;
}

/// Whether [item] draws in a shadow map: an accepted caster under [filter]
/// and [casterChannelMask] whose material is opaque and scene-referred (UI
/// composited over the scene casts no shadow into it).
///
/// [ShadowEncoder.submit] records an item only when this holds and the item
/// is inside the light's frustum.
bool shadowCasterDraws(
  RenderItem item,
  ShadowCasterFilter filter,
  int casterChannelMask,
) =>
    shadowCasterAccepted(item, filter, casterChannelMask) &&
    item.material.isOpaque() &&
    !item.material.displayReferred;

/// How a shadow pass draws [geometry] with [material]: its shaders, its
/// vertex layout, and the vertex inputs the draw binds.
///
/// An alpha-masked caster draws through the masked depth shader, which the
/// material may supply, so only its opaque texels cast, and a cutout `.fmat`
/// casts through its own depth fragment, cut by its surface alpha; an
/// explicitly configured mask wins over that automatic variant. Either needs
/// the full-vertex varyings, so it skips the position-only path. Unskinned
/// casters otherwise draw depth through a position-only shader and layout;
/// skinned geometry falls back to its full vertex shader. A `vertex { }`
/// material displaces geometry in the color pass, so its vertex variant runs
/// here too or the shadow detaches from the visible surface. A full-vertex
/// caster runs the material's color vertex variant, which declares its
/// per-instance attribute inputs and custom attributes, so the instance
/// record is as wide as in the color pass.
ShadowCasterDraw shadowCasterDraw(Geometry geometry, Material material) {
  final surfaceShader = material.depthAlphaMasked
      ? null
      : material.depthSurfaceShader(DepthSurfaceKind.shadow);
  final masked = surfaceShader != null || material.depthAlphaMasked;
  final fragmentShader =
      surfaceShader ??
      (masked
          ? material.maskedDepthFragmentShader(MaskedDepthPass.shadow) ??
                ShadowEncoder._maskedDepthShader
          : ShadowEncoder._depthShader);
  final depthVertex = masked || material.needsFullVertexForDepth(geometry)
      ? null
      : geometry.depthOnlyVertex;
  final materialVertex = material.vertexShaderForGeometry(
    geometry,
    depth: depthVertex != null,
  );
  final instanceSchema = depthVertex == null
      ? material.instanceAttributes
      : null;
  final attributes = depthVertex == null
      ? material.vertexAttributesFor(materialVertex)
      : VertexAttributeSchema.none;
  return ShadowCasterDraw._(
    vertexShader:
        materialVertex ?? depthVertex?.shader ?? geometry.vertexShader,
    fragmentShader: fragmentShader,
    vertexLayout:
        depthVertex?.layout ??
        geometry.instancedVertexLayoutFor(instanceSchema, attributes),
    materialVertex: materialVertex,
    positionOnly: depthVertex != null,
    surfaceShader: surfaceShader,
    masked: masked,
    instanceSchema: instanceSchema,
    attributes: attributes,
  );
}

/// The pipeline inputs of [item]'s draw in a shadow map, as [ShadowEncoder]
/// resolves them.
PipelineInputs shadowCasterPipelineInputs(RenderItem item) =>
    shadowCasterDraw(item.geometry, item.material).pipelineInputsFor(item);

/// One shadow caster draw; see [shadowCasterDraw].
final class ShadowCasterDraw {
  ShadowCasterDraw._({
    required this.vertexShader,
    required this.fragmentShader,
    required this.vertexLayout,
    required this.materialVertex,
    required this.positionOnly,
    required this.surfaceShader,
    required this.masked,
    required this.instanceSchema,
    required this.attributes,
  });

  final gpu.Shader vertexShader;
  final gpu.Shader fragmentShader;
  final VertexLayoutDescriptor? vertexLayout;

  /// The material's vertex variant, when it supplies one.
  final gpu.Shader? materialVertex;

  /// Whether the draw runs the position-only vertex path.
  final bool positionOnly;

  /// The material's own cutout depth fragment, when it casts through one.
  final gpu.Shader? surfaceShader;

  /// Whether the fragment cuts the caster, by its surface alpha or by an
  /// alpha mask.
  final bool masked;

  /// The per-instance attributes the full-vertex path reads.
  final InstanceAttributeSchema? instanceSchema;

  /// The custom vertex attributes the draw fetches.
  final VertexAttributeSchema? attributes;

  /// Whether the draw of [item] reads its model transforms from the instance
  /// records the color pass retains, which a position-only draw of
  /// node-space records does.
  bool retainsRecordsOf(RenderItem item) =>
      positionOnly && vertexLayout != null && item.nodeSpaceInstances;

  /// The pipeline inputs of the draw of [item].
  PipelineInputs pipelineInputsFor(RenderItem item) => (
    vertexShader: vertexShader,
    fragmentShader: fragmentShader,
    vertexLayout: retainsRecordsOf(item)
        ? positionOnlyLayoutOverRecords(
            vertexLayout!,
            kInstanceRecordFloats + item.instanceAttributeFloats,
          )
        : vertexLayout,
  );
}

/// Records each opaque shadow caster's depth into a shadow-map render
/// pass, from a directional light's point of view.
///
/// Reuses the engine's standard vertex shaders (so unskinned and skinned
/// geometry both cast shadows) paired with the `DepthOnlyFragment`
/// shader, supplying the light-space view-projection matrix in place of
/// the camera transform. Translucent materials don't cast shadows.
class ShadowEncoder {
  ShadowEncoder(
    this._renderPass,
    this._transientsBuffer,
    this._lightSpaceMatrix,
    this._cameraPosition,
    ShadowCasterFaces casterFaces, {
    ShadowCasterFilter filter = ShadowCasterFilter.all,
    int casterChannelMask = 0xFF,
    this.receiverPlanes = const [],
  }) : _casterFaces = casterFaces,
       _filter = filter,
       _casterChannelMask = casterChannelMask {
    frustum = Frustum.matrix(_lightSpaceMatrix);
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(false);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    // TODO(shadow-slope-bias): set a slope-scaled caster bias with
    // RenderPass.setDepthBias once Flutter GPU has it, so grazing casters stop
    // relying on the receiver's shadowNormalBias alone.
    // Cull the complement of the faces that should cast. With base CCW
    // winding (flipped per-item for mirrored casters below), back-face culling
    // keeps the light-facing faces. [ShadowCasterFaces.back] (second-depth)
    // suits solid geometry, recording the far face to avoid self-shadow acne.
    _currentCullMode = switch (casterFaces) {
      ShadowCasterFaces.front => gpu.CullMode.backFace,
      ShadowCasterFaces.back => gpu.CullMode.frontFace,
      ShadowCasterFaces.both => gpu.CullMode.none,
    };
    _renderPass.setCullMode(_currentCullMode);
    _renderPass.setWindingOrder(gpu.WindingOrder.clockwise);
  }

  final gpu.RenderPass _renderPass;
  final TransientWriter _transientsBuffer;
  final Matrix4 _lightSpaceMatrix;
  final ShadowCasterFaces _casterFaces;
  final ShadowCasterFilter _filter;

  // The light's shadow-caster channels. An item casts only when its node's
  // light channels intersect these, independently of whether the light
  // shades it.
  final int _casterChannelMask;

  // The scene camera position, bound as FrameInfo.camera_position so a
  // `vertex { }` material's camera-relative displacement (e.g. a world curve)
  // bends shadow casters the same way as the color pass. The depth fragment
  // shader ignores it, so it is harmless for materials without a vertex stage.
  final Vector3 _cameraPosition;

  // The forward handed to a surface depth fragment; a shadow pass has no
  // view axis, and no cutout decision depends on it.
  static final Vector3 _shadowForward = Vector3(0, -1, 0);

  static final gpu.Shader _depthShader =
      baseShaderLibrary['DepthOnlyFragment']!;
  static final gpu.Shader _maskedDepthShader =
      baseShaderLibrary['DepthOnlyMaskedFragment']!;

  /// The cull mode currently set on the pass. A non-masked caster switches to
  /// the faces its node or the light casts with, and an alpha-masked caster to
  /// its material's own culling (see [submit]).
  late gpu.CullMode _currentCullMode;

  /// Frustum of the light-space view-projection, used for per-item
  /// culling.
  late final Frustum frustum;

  /// Extra planes rejecting casters that cannot shadow a visible receiver
  /// (see `shadowReceiverCullingPlanes`), tested alongside [frustum].
  final List<Plane> receiverPlanes;

  final Aabb3 _cullScratchAabb = Aabb3();

  /// The pipeline currently bound on the render pass, or null before the
  /// first draw. `clearBindings` leaves the pipeline in place, so
  /// consecutive casters that share one only bind it once.
  gpu.RenderPipeline? _boundPipeline;
  final List<RenderItem> _records = [];
  // See SceneEncoder._batchPool: refilled per group, read-only downstream.
  final InstanceDataBatchPool _batchPool = InstanceDataBatchPool();

  /// Records [item]'s depth, unless it is hidden, translucent (no shadow),
  /// or culled by the light frustum.
  void submit(RenderItem item) => _submit(item, false);

  /// Records an item already accepted by [RenderScene.cull].
  void submitCulled(RenderItem item) => _submit(item, true);

  void _submit(RenderItem item, bool alreadyCulled) {
    // The flag and channel checks run first: the dynamic composite iterates
    // the whole item list (most of which is static), so the common case must
    // reject before any virtual call.
    if (!shadowCasterDraws(item, _filter, _casterChannelMask)) return;
    if (!alreadyCulled && item.frustumCulled) {
      final bounds = item.cullBounds;
      if (bounds != null) {
        _cullScratchAabb
          ..copyFrom(bounds)
          ..transform(item.worldTransform);
        if (!frustum.intersectsWithAabb3(_cullScratchAabb)) return;
        for (final plane in receiverPlanes) {
          if (_aabbOutsidePlane(_cullScratchAabb, plane)) return;
        }
      }
    }
    _records.add(item);
  }

  // Matches the Bvh's plane test: outside when the corner farthest along the
  // normal is below the plane.
  static bool _aabbOutsidePlane(Aabb3 box, Plane plane) {
    final n = plane.normal;
    final x = n.x < 0 ? box.min.x : box.max.x;
    final y = n.y < 0 ? box.min.y : box.max.y;
    final z = n.z < 0 ? box.min.z : box.max.z;
    return n.x * x + n.y * y + n.z * z + plane.constant < 0;
  }

  /// Emits the accepted casters, merging compatible spatial cells back into
  /// one hardware-instanced draw after culling.
  void flush() {
    _records.sort((a, b) {
      final byMaterial = a.materialIdentity.compareTo(b.materialIdentity);
      if (byMaterial != 0) return byMaterial;
      final byGeometry = a.geometryIdentity.compareTo(b.geometryIdentity);
      if (byGeometry != 0) return byGeometry;
      return (a.shadowCasterFaces ?? _casterFaces).index.compareTo(
        (b.shadowCasterFaces ?? _casterFaces).index,
      );
    });
    var index = 0;
    while (index < _records.length) {
      final first = _records[index];
      final end = shadowBatchEnd(_records, index, _casterFaces);
      if (end > index + 1) {
        _batchPool.reset();
        for (var batchIndex = index; batchIndex < end; batchIndex++) {
          _batchPool.addFor(_records[batchIndex], indices: null);
        }
        final batches = _batchPool.batches;
        _encode(first, batches: batches);
        index = end;
        continue;
      }
      _encode(first);
      index++;
    }
    _records.clear();
  }

  void _encode(RenderItem item, {List<InstanceDataBatch>? batches}) {
    if (batches != null) {
      _encodeBody(item, batches: batches);
      return;
    }
    final geometry = item.geometry;
    final selection = beginMeshDraw(
      item,
      geometry,
      MeshDrawPass.shadow,
      _cameraPosition,
      false,
    );
    try {
      if (selection.instanceCount == 0) return;
      _encodeBody(item, instanceLimit: selection.instanceCount);
    } finally {
      endMeshDraw(geometry);
    }
  }

  void _encodeBody(
    RenderItem item, {
    List<InstanceDataBatch>? batches,
    int? instanceLimit,
  }) {
    final geometry = item.geometry;
    // Skinned casters bind their joints texture through the full-vertex
    // path below; apply this item's skeleton to the (possibly shared)
    // geometry first.
    item.applyJointsTexture(geometry);
    item.applyMorphWeights(geometry);
    // An alpha-masked or cutout caster keeps the material's own culling, so
    // the faces that are visible are the faces that cast; the caster-face
    // mode's second-depth trick has no meaning for cutout sheets.
    final draw = shadowCasterDraw(geometry, item.material);
    final surfaceShader = draw.surfaceShader;
    final masked = draw.masked;
    final fragmentShader = draw.fragmentShader;
    // A double-sided caster records every face regardless of the light's
    // caster-face mode or the material's culling, which is what closes the
    // light leak through single-sided geometry. A double-sided material casts
    // from both faces too: it has no inside for the caster-face mode to pick
    // against, and culling one side of a card drops half of it from the map.
    final materialCull = item.material.renderCullMode;
    final cullMode = item.shadowDoubleSided || materialCull == gpu.CullMode.none
        ? gpu.CullMode.none
        : (masked ? materialCull : shadowCasterCullMode(item, _casterFaces));
    if (cullMode != _currentCullMode) {
      _renderPass.setCullMode(cullMode);
      _currentCullMode = cullMode;
    }
    final positionOnly = draw.positionOnly;
    final materialVertex = draw.materialVertex;
    final activeVertex = draw.vertexShader;
    final attributeFloats = draw.instanceSchema?.floatCount ?? 0;
    geometry.useVertexAttributes(draw.attributes);
    // A caster whose pipeline cannot build skips its own draw rather than
    // throwing out of the whole shadow pass.
    final retainsRecords = batches == null && draw.retainsRecordsOf(item);
    final vertexLayout = retainsRecords
        ? draw.pipelineInputsFor(item).vertexLayout
        : draw.vertexLayout;
    final pipeline =
        cachedRenderPipeline(activeVertex, fragmentShader, vertexLayout) ??
        _resolvePipeline(activeVertex, fragmentShader, vertexLayout, geometry);
    // A sliced warm-up builds this pipeline in a later slice.
    if (pipeline == null) return;
    if (!identical(_boundPipeline, pipeline)) {
      _renderPass.clearBindings();
      _renderPass.bindPipeline(pipeline);
      _boundPipeline = pipeline;
    }
    _renderPass.setPrimitiveType(geometry.primitiveType);
    activeDrawRecorder?.setContext(
      DrawContext(
        phase: DrawPhase.shadow,
        item: item,
        geometry: geometry,
        material: item.material,
        vertexShader: activeVertex,
        fragmentShader: fragmentShader,
        pipeline: pipeline,
        batchedItems: batches?.length ?? 1,
      ),
    );

    // Shadow maps take no depth layers or tie-break offsets.
    clearCurrentDrawDepthOffset();

    _drawItem = item;
    _drawGeometry = geometry;
    _drawDepthPath = positionOnly;
    _drawVertex = activeVertex;
    _drawMaterialVertex = materialVertex;
    _drawSurfaceShader = surfaceShader;
    _drawMasked = masked;
    _drawFragment = fragmentShader;

    // The instance-rate model transform sits in the slot after the bound
    // vertex streams: slot 1 on the position-only path, slot
    // [vertexStreamCount] when the full stream set is bound (masked casters),
    // matching the prepass and color encoders.
    final instanceSlot = positionOnly ? 1 : geometry.vertexStreamCount;

    if (batches != null) {
      _bindDraw(_identityTransform);
      final PackedInstances packed = !positionOnly
          ? packInstanceDataBatches(
              batches,
              attributeFloats: attributeFloats,
              scratch: transientInstancePackingScratch,
            )
          : packInstanceTransformBatches(
              batches,
              scratch: transientInstancePackingScratch,
            );
      _drawPacked(geometry, packed, !positionOnly, instanceSlot);
      return;
    }

    final instances = item.instanceTransforms;
    if (instances != null) {
      final visible = limitInstanceIndices(
        null,
        instances.length,
        instanceLimit,
      );
      if (geometry.instancedVertexLayout == null) {
        // Skinned geometry has no instance-attribute path; loop.
        for (final instanceTransform in instances.take(
          visible?.length ?? instances.length,
        )) {
          _bindDraw(item.worldTransform * instanceTransform);
          final flip =
              item.windingFlipped != (instanceTransform.determinant() < 0);
          _renderPass.setWindingOrder(
            flip
                ? gpu.WindingOrder.counterClockwise
                : gpu.WindingOrder.clockwise,
          );
          drawOrRejectPipeline(_renderPass, geometry, _boundPipeline);
        }
        return;
      }
      currentDrawInstanceFrame = item.instanceFrame;
      _bindDraw(item.worldTransform);
      currentDrawInstanceFrame = null;
      final packedWorldData = item.instanceWorldData;
      final packedWinding = item.instanceWorldWindingFlipped;
      if ((retainsRecords ||
              (!positionOnly &&
                  item.instanceAttributeFloats == attributeFloats)) &&
          packedWorldData != null &&
          packedWinding != null) {
        final flipped = bindRetainedInstanceData(
          _renderPass,
          packedWorldData,
          packedWinding,
          slot: instanceSlot,
        );
        if (flipped != null) {
          _renderPass.setWindingOrder(
            flipped
                ? gpu.WindingOrder.counterClockwise
                : gpu.WindingOrder.clockwise,
          );
          drawOrRejectPipeline(
            _renderPass,
            geometry,
            _boundPipeline,
            instanceCount: visible?.length ?? instances.length,
          );
          return;
        }
      }
      final cached = packedWorldData == null || packedWinding == null
          ? null
          : transientInstancePackingScratch.singleCachedBatch(
              packedWorldData: packedWorldData,
              packedWindingFlipped: packedWinding,
              indices: visible,
              attributeFloats: item.instanceAttributeFloats,
            );
      final PackedInstances packed = !positionOnly || retainsRecords
          ? (cached == null
                ? packInstanceData(
                    item.instancePackTransform,
                    instances,
                    item.instanceColors!,
                    nodeWindingFlipped: item.windingFlipped,
                    instanceWindingFlipped: item.instanceWindingFlipped,
                    indices: visible,
                    attributeData: item.instanceAttributeData,
                    attributeFloats: retainsRecords
                        ? item.instanceAttributeFloats
                        : attributeFloats,
                    scratch: transientInstancePackingScratch,
                  )
                : packInstanceDataBatches(
                    cached,
                    attributeFloats: retainsRecords
                        ? item.instanceAttributeFloats
                        : attributeFloats,
                    scratch: transientInstancePackingScratch,
                  ))
          : (cached == null
                ? packInstanceTransforms(
                    item.instancePackTransform,
                    instances,
                    nodeWindingFlipped: item.windingFlipped,
                    instanceWindingFlipped: item.instanceWindingFlipped,
                    indices: visible,
                    scratch: transientInstancePackingScratch,
                  )
                : packInstanceTransformBatches(
                    cached,
                    scratch: transientInstancePackingScratch,
                  ));
      _drawPacked(
        geometry,
        packed,
        !positionOnly || retainsRecords,
        instanceSlot,
      );
      transientInstancePackingScratch.releaseSingleBatch();
      return;
    }

    _bindDraw(item.worldTransform);
    // Skip the model-transform instance buffer for geometry that supplies its
    // own per-instance buffer (see the color encoder), or it clobbers the
    // stream slot.
    if (geometry.instancedVertexLayout != null &&
        geometry.bindsModelTransformInstance) {
      if (!positionOnly) {
        bindSingleInstanceData(
          _renderPass,
          item.worldTransform,
          slot: instanceSlot,
          attributeFloats: attributeFloats,
        );
      } else {
        bindSingleInstanceTransform(
          _renderPass,
          item.worldTransform,
          slot: instanceSlot,
        );
      }
    }
    // Mirrored casters reverse winding; flip the cull order so the same faces
    // that are visible also cast shadows.
    _renderPass.setWindingOrder(
      item.windingFlipped
          ? gpu.WindingOrder.counterClockwise
          : gpu.WindingOrder.clockwise,
    );
    drawOrRejectPipeline(_renderPass, geometry, _boundPipeline);
  }

  static final Matrix4 _identityTransform = Matrix4.identity();

  // Per-draw state for [_bindDraw], set by the encode path. Fields rather
  // than a local closure, which would allocate on every draw.
  RenderItem? _drawItem;
  Geometry? _drawGeometry;
  bool _drawDepthPath = false;
  gpu.Shader? _drawVertex;
  gpu.Shader? _drawMaterialVertex;
  gpu.Shader? _drawSurfaceShader;
  bool _drawMasked = false;
  gpu.Shader? _drawFragment;

  // Binds the vertex/index buffers and the per-frame uniform for one draw.
  // The light-space matrix takes the place of the camera transform (the depth
  // fragment shader ignores camera_position, but a material's Vertex() hook
  // reads it, so the real camera position is bound).
  void _bindDraw(Matrix4 worldTransform) {
    final item = _drawItem!;
    final geometry = _drawGeometry!;
    final activeVertex = _drawVertex!;
    final materialVertex = _drawMaterialVertex;
    final surfaceShader = _drawSurfaceShader;
    final masked = _drawMasked;
    final fragmentShader = _drawFragment!;
    if (_drawDepthPath) {
      geometry.bindPositionStream(_renderPass);
      bindUnskinnedFrameInfo(
        _renderPass,
        _transientsBuffer,
        activeVertex,
        _lightSpaceMatrix,
        _cameraPosition,
        depthBias: 0.0,
      );
    } else {
      geometry.bind(
        _renderPass,
        _transientsBuffer,
        worldTransform,
        _lightSpaceMatrix,
        _cameraPosition,
        shaderOverride: materialVertex,
        depthBias: 0.0,
      );
    }
    if (materialVertex != null) {
      item.material.bindVertexStage(
        _renderPass,
        materialVertex,
        _transientsBuffer,
      );
    }
    if (surfaceShader != null) {
      item.material.bindDepthSurface(
        _renderPass,
        fragmentShader,
        _transientsBuffer,
        cameraPosition: _cameraPosition,
        cameraForward: _shadowForward,
      );
    } else if (masked) {
      item.material.bindDepthAlphaMask(
        _renderPass,
        fragmentShader,
        _transientsBuffer,
      );
    }
  }

  // The pipeline-cache miss path. Its debug closure lives here so the
  // per-draw path does not allocate a capture context.
  gpu.RenderPipeline? _resolvePipeline(
    gpu.Shader vertexShader,
    gpu.Shader fragmentShader,
    VertexLayoutDescriptor? vertexLayout,
    Geometry geometry,
  ) => tryResolvePipeline(
    vertexShader,
    fragmentShader,
    vertexLayout: vertexLayout,
    debugContext: () => 'shadow caster ${geometry.runtimeType}',
  );

  void _drawPacked(
    Geometry geometry,
    PackedInstances packed,
    bool withColor,
    int instanceSlot,
  ) {
    if (packed.ccwCount > 0) {
      if (withColor) {
        bindInstanceData(_renderPass, packed.ccw, slot: instanceSlot);
      } else {
        bindInstanceTransforms(_renderPass, packed.ccw, slot: instanceSlot);
      }
      _renderPass.setWindingOrder(gpu.WindingOrder.clockwise);
      drawOrRejectPipeline(
        _renderPass,
        geometry,
        _boundPipeline,
        instanceCount: packed.ccwCount,
      );
    }
    if (packed.cwCount > 0) {
      if (withColor) {
        bindInstanceData(_renderPass, packed.cw, slot: instanceSlot);
      } else {
        bindInstanceTransforms(_renderPass, packed.cw, slot: instanceSlot);
      }
      _renderPass.setWindingOrder(gpu.WindingOrder.counterClockwise);
      drawOrRejectPipeline(
        _renderPass,
        geometry,
        _boundPipeline,
        instanceCount: packed.cwCount,
      );
    }
  }
}
