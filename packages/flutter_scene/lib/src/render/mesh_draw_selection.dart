import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/mesh_draw.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:vector_math/vector_math.dart';

final MeshDrawContext _context = MeshDrawContext(
  pass: MeshDrawPass.color,
  cameraPosition: Vector3.zero(),
  primaryView: true,
);

/// Runs [item]'s [MeshDrawSelector] for one draw and applies its index range
/// to [geometry], and states the turns of a mesh drawn alone. Pair with
/// [endMeshDraw].
MeshDrawSelection beginMeshDraw(
  RenderItem item,
  Geometry geometry,
  MeshDrawPass pass,
  Vector3 cameraPosition,
  bool primaryView,
) {
  item.beginSpinDraw();
  final selector = item.drawSource?.drawSelector;
  if (selector == null) return MeshDrawSelection.all;
  _context
    ..pass = pass
    ..cameraPosition = cameraPosition
    ..primaryView = primaryView;
  final selection = selector(_context);
  if (selection.firstIndex != 0 || selection.indexCount != null) {
    geometry.setDrawWindow(selection.firstIndex, selection.indexCount);
  }
  return selection;
}

/// Restores [geometry] to its full range and clears the turns stated by
/// [beginMeshDraw].
void endMeshDraw(Geometry geometry) {
  RenderItem.endSpinDraw();
  geometry.clearDrawWindow();
}

/// Whether [item] has a selector, which keeps it out of cross-node batching.
bool hasMeshDrawSelector(RenderItem item) =>
    item.drawSource?.drawSelector != null;

/// The rows of [ranges] (first row, row count and a winding entry per range,
/// ascending) below [limit], one by one. For a draw that orders its rows
/// itself, such as a back-to-front sort.
List<int> instanceRowsOf(List<int> ranges, int? limit) {
  final rows = <int>[];
  for (var range = 0; range < ranges.length; range += 3) {
    var end = ranges[range] + ranges[range + 1];
    if (limit != null && end > limit) end = limit;
    for (var row = ranges[range]; row < end; row++) {
      rows.add(row);
    }
  }
  return rows;
}
