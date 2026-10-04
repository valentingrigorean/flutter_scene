// A caller that renders with package:flutter_gpu hands its buffers and
// textures to flutter_scene, whose signatures name the bundled GPU shim. The
// analyzer reads a conditional export's default branch, so the shim's default
// must be the native backend: an assignment below that fails to analyze means
// analysis resolves the shim to some other type than package:flutter_gpu's.

import 'package:flutter_gpu/gpu.dart' as flutter_gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a flutter_gpu buffer view and texture bind to the scene types', () {
    final geometry = UnskinnedGeometry();
    final void Function(flutter_gpu.BufferView, int) setVertices =
        geometry.setVertices;
    final void Function(flutter_gpu.BufferView, flutter_gpu.IndexType)
    setIndices = geometry.setIndices;
    final TextureSource Function(flutter_gpu.Texture) wrap =
        GpuTextureSource.new;

    expect([setVertices, setIndices, wrap], everyElement(isNotNull));
  });
}
