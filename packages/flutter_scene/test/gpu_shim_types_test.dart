// On native the shim's resource types are its own, over the backend chosen at
// start-up, and the scene's signatures name them; enums and value types stay
// package:flutter_gpu's. The analyzer reads a conditional export's default
// branch, so these assignments analyze against the native shim.

@TestOn('vm')
library;

import 'package:flutter_gpu/gpu.dart' as flutter_gpu;
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the scene takes the shim buffer view and texture', () {
    final geometry = UnskinnedGeometry();
    final void Function(gpu.BufferView, int) setVertices =
        geometry.setVertices;
    final void Function(gpu.BufferView, gpu.IndexType) setIndices =
        geometry.setIndices;
    final TextureSource Function(gpu.Texture) wrap = GpuTextureSource.new;

    expect([setVertices, setIndices, wrap], everyElement(isNotNull));
  });

  test('enums and value types are flutter_gpu\'s own', () {
    const flutter_gpu.PixelFormat format = gpu.PixelFormat.r8g8b8a8UNormInt;
    final flutter_gpu.SamplerOptions sampler = gpu.SamplerOptions();

    expect([format, sampler], everyElement(isNotNull));
  });

  test('the backend is Impeller unless chosen otherwise', () {
    expect(gpu.gpuBackend, gpu.GpuBackendKind.impeller);
  });
}
