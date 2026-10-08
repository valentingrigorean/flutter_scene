/// The size of the geometry a runtime glTF import handed to the device.
///
/// Read from the root node an import returns (`Node.importStats`), so a
/// caller budgeting memory does not parse the file a second time to count it.
/// Each node that draws a mesh uploads its own vertex and index buffers, so a
/// mesh two nodes share counts twice, as it does on the device.
///
/// Textures and morph target deltas are not part of these counts.
/// {@category Assets and loading}
class GltfImportStats {
  const GltfImportStats({required this.vertexBytes, required this.indexBytes});

  /// Total bytes of the packed vertex buffers the import uploaded.
  final int vertexBytes;

  /// Total bytes of the packed index buffers the import uploaded.
  final int indexBytes;

  /// [vertexBytes] plus [indexBytes].
  int get geometryBytes => vertexBytes + indexBytes;

  @override
  String toString() =>
      'GltfImportStats(vertexBytes: $vertexBytes, indexBytes: $indexBytes)';
}
