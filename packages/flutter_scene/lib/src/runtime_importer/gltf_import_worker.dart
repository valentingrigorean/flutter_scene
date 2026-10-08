/// The data half of a runtime glTF import: everything that needs no device.
///
/// These functions run on a background isolate (inline on the web, which has
/// none) and answer plain data: the parsed document, its resolved buffer, and
/// every primitive packed into the engine's vertex layout. The calling isolate
/// then only creates device buffers, textures, materials and nodes from it.
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:vector_math/vector_math.dart';

import 'gltf_import_stats.dart';
import 'gltf_resources.dart';
import 'skin_builder.dart';

/// One primitive packed for each way a node can draw it.
///
/// Both fields are the same object unless the mesh is drawn both by a skinned
/// node and by an unskinned one.
typedef PackedPrimitiveVariants = ({
  PackedPrimitive unskinned,
  PackedPrimitive skinned,
});

/// A glTF document prepared for upload, as plain data.
class PreparedGltfImport {
  PreparedGltfImport({
    required this.doc,
    required this.bufferData,
    required this.primitives,
    required this.skinnedBounds,
    required this.stats,
  });

  /// The parsed document, its buffer views rebased onto [bufferData] and its
  /// meshopt-compressed views already decoded.
  final GltfDocument doc;

  /// Every buffer of the document as one blob. Holds the encoded image bytes
  /// (read with `resolveGltfImageBytes`) and the skin and animation accessors.
  final Uint8List bufferData;

  /// The packed primitives, indexed `[meshIndex][primitiveIndex]`, with a null
  /// entry for each non-triangle primitive.
  final List<List<PackedPrimitiveVariants?>> primitives;

  /// The pose bounds of each skinned node's primitives, by node index (see
  /// [skinnedPoseBounds]).
  final Map<int, List<Aabb3?>> skinnedBounds;

  /// The bytes of the vertex and index buffers [packedFor] answers over every
  /// node of [doc], which is what the upload creates on the device.
  final GltfImportStats stats;

  /// The packed primitive [node] draws for its mesh's primitive
  /// [primitiveIndex], or null for a non-triangle primitive.
  PackedPrimitive? packedFor(GltfNode node, int primitiveIndex) {
    final variants = primitives[node.mesh!][primitiveIndex];
    if (variants == null) return null;
    return node.skin == null ? variants.unskinned : variants.skinned;
  }
}

/// What the GLB worker answers: the prepared import, or the error that stopped
/// it, with the parse warnings raised before either.
///
/// The error travels as a value so the warnings that preceded it still reach
/// the caller, in order, before it is rethrown there (see [unwrap]).
class GlbImportWorkerResult {
  GlbImportWorkerResult.prepared(
    PreparedGltfImport this.prepared,
    this.warnings,
  ) : error = null,
      stackTrace = null;

  GlbImportWorkerResult.failed(
    Object this.error,
    StackTrace this.stackTrace,
    this.warnings,
  ) : prepared = null;

  final PreparedGltfImport? prepared;
  final List<GltfImportWarning> warnings;
  final Object? error;
  final StackTrace? stackTrace;

  /// The prepared import, or the worker's error rethrown with its own stack
  /// trace.
  PreparedGltfImport unwrap() {
    final prepared = this.prepared;
    if (prepared != null) return prepared;
    Error.throwWithStackTrace(error!, stackTrace!);
  }
}

/// Parses a GLB container and its JSON, resolves and normalizes its buffers,
/// decodes meshopt-compressed views and packs every primitive.
///
/// Top-level and synchronous so it can be an isolate's entry point.
GlbImportWorkerResult prepareGlbImport(Uint8List bytes) {
  var warnings = const <GltfImportWarning>[];
  try {
    final container = parseGlb(bytes);
    final doc = parseGltfJson(container.json);
    warnings = doc.warnings;
    final placeholders = meshoptPlaceholderBuffers(doc);
    final normalized = normalizeGltfBuffers(doc, [
      for (int i = 0; i < doc.buffers.length; i++)
        if (placeholders.contains(i))
          null
        else
          _embeddedBufferBytes(doc.buffers[i].uri, container.binaryChunk),
    ], glbBinaryChunk: container.binaryChunk);
    return GlbImportWorkerResult.prepared(
      prepareGltfImport(normalized),
      warnings,
    );
  } catch (error, stackTrace) {
    return GlbImportWorkerResult.failed(error, stackTrace, warnings);
  }
}

Uint8List _embeddedBufferBytes(String? uri, Uint8List glbBinaryChunk) {
  if (uri == null) return glbBinaryChunk; // GLB embedded buffer.
  if (uri.startsWith('data:')) return decodeGltfDataUri(uri);
  throw FormatException(
    'glTF references external buffer "$uri" but no resource resolver was '
    'provided. Use importGltf / Node.fromGltfBytes for multi-file glTF.',
  );
}

/// Decodes the meshopt-compressed views of a document whose buffers are
/// already normalized (see [normalizeGltfBuffers]) and packs every primitive.
///
/// Top-level and synchronous so it can be an isolate's entry point.
PreparedGltfImport prepareGltfImport(
  ({GltfDocument doc, Uint8List bufferData}) normalized,
) {
  final gltf = decodeMeshoptBufferViews(normalized.doc, normalized.bufferData);
  final doc = gltf.doc;
  final skinnedMeshes = <int>{};
  final unskinnedMeshes = <int>{};
  for (final node in doc.nodes) {
    final mesh = node.mesh;
    if (mesh == null) continue;
    (node.skin == null ? unskinnedMeshes : skinnedMeshes).add(mesh);
  }

  PackedPrimitiveVariants pack(int meshIndex, GltfMeshPrimitive primitive) {
    PackedPrimitive run(bool includeSkinning) => packGltfPrimitive(
      primitive: primitive,
      accessors: doc.accessors,
      bufferViews: doc.bufferViews,
      bufferData: gltf.bufferData,
      coordinatePolicy: GltfCoordinatePolicy.runtimeBoundary,
      includeSkinning: includeSkinning,
    );
    final carriesSkinning =
        primitive.attributes.containsKey('JOINTS_0') &&
        primitive.attributes.containsKey('WEIGHTS_0');
    if (carriesSkinning && skinnedMeshes.contains(meshIndex)) {
      final skinned = run(true);
      if (!unskinnedMeshes.contains(meshIndex)) {
        return (unskinned: skinned, skinned: skinned);
      }
      return (unskinned: run(false), skinned: skinned);
    }
    final unskinned = run(false);
    return (unskinned: unskinned, skinned: unskinned);
  }

  for (final mesh in doc.meshes) {
    validateMorphTargetConsistency(mesh);
  }
  final primitives = [
    for (var meshIndex = 0; meshIndex < doc.meshes.length; meshIndex++)
      [
        for (final p in doc.meshes[meshIndex].primitives)
          if (p.mode != 4) null else pack(meshIndex, p),
      ],
  ];

  // Mirrors the upload: one geometry per primitive of each node's mesh.
  var vertexBytes = 0;
  var indexBytes = 0;
  for (final node in doc.nodes) {
    final mesh = node.mesh;
    if (mesh == null) continue;
    for (final variants in primitives[mesh]) {
      if (variants == null) continue;
      final packed = node.skin == null ? variants.unskinned : variants.skinned;
      vertexBytes += packed.vertexBytes.lengthInBytes;
      indexBytes += packed.indexBytes.lengthInBytes;
    }
  }

  return PreparedGltfImport(
    doc: doc,
    bufferData: gltf.bufferData,
    primitives: primitives,
    skinnedBounds: skinnedPoseBounds(doc, gltf.bufferData),
    stats: GltfImportStats(vertexBytes: vertexBytes, indexBytes: indexBytes),
  );
}

/// Concatenates the document's buffers into one blob with [GltfBufferView]s
/// rebased to absolute offsets into it, returning a document copy that
/// carries the rebased views. Mirrors the offline importer's multi-buffer
/// normalization (`in_memory_import.dart`'s `_normalizeGltf`) so the runtime
/// path supports the same multi-buffer `.gltf` documents.
///
/// [bufferBytes] holds the resolved bytes of each of `doc.buffers`, null for
/// an EXT_meshopt_compression placeholder buffer, which holds no data the
/// decode path reads and so contributes nothing to the blob. A document
/// without buffers keeps [glbBinaryChunk] as its data.
({GltfDocument doc, Uint8List bufferData}) normalizeGltfBuffers(
  GltfDocument doc,
  List<Uint8List?> bufferBytes, {
  required Uint8List glbBinaryChunk,
}) {
  if (doc.buffers.isEmpty) {
    return (doc: doc, bufferData: glbBinaryChunk);
  }

  final blob = BytesBuilder();
  void padTo4() {
    while (blob.length % 4 != 0) {
      blob.addByte(0);
    }
  }

  final bufferBase = <int>[];
  for (int i = 0; i < doc.buffers.length; i++) {
    padTo4();
    bufferBase.add(blob.length);
    final bytes = bufferBytes[i];
    if (bytes != null) blob.add(bytes);
  }

  final bufferViews = [
    for (final v in doc.bufferViews)
      GltfBufferView(
        buffer: 0,
        byteLength: v.byteLength,
        byteOffset: v.byteOffset + bufferBase[v.buffer],
        byteStride: v.byteStride,
        meshopt: v.meshopt?.rebased(
          buffer: 0,
          byteOffset: v.meshopt!.byteOffset + bufferBase[v.meshopt!.buffer],
        ),
      ),
  ];

  final normalized = GltfDocument(
    scene: doc.scene,
    scenes: doc.scenes,
    nodes: doc.nodes,
    meshes: doc.meshes,
    accessors: doc.accessors,
    bufferViews: bufferViews,
    buffers: doc.buffers,
    materials: doc.materials,
    textures: doc.textures,
    images: doc.images,
    samplers: doc.samplers,
    skins: doc.skins,
    animations: doc.animations,
    lights: doc.lights,
    materialsVariants: doc.materialsVariants,
    warnings: doc.warnings,
  );
  return (doc: normalized, bufferData: blob.toBytes());
}
