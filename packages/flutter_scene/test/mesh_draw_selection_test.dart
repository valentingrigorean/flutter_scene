import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/mesh_draw_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('instanceRowsOf lists the rows of each range below the limit', () {
    const ranges = [1, 2, 0, 6, 3, 1];
    expect(instanceRowsOf(ranges, null), [1, 2, 6, 7, 8]);
    expect(instanceRowsOf(ranges, 7), [1, 2, 6]);
    expect(instanceRowsOf(ranges, 0), isEmpty);
  });

  test('MeshDrawSelection.all draws everything', () {
    expect(MeshDrawSelection.all.isAll, isTrue);
    expect(const MeshDrawSelection(instanceCount: 3).isAll, isFalse);
    expect(const MeshDrawSelection(firstIndex: 6).isAll, isFalse);
  });
}
