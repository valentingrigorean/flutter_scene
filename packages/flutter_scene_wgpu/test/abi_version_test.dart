import 'package:flutter_scene_wgpu/flutter_scene_wgpu.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the native library loads and reports its ABI version', () {
    expect(fswAbiVersion(), 1);
  });
}
