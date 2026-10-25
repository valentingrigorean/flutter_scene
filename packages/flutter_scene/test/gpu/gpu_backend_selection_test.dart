// Each test file runs in its own isolate, so the backend starts unchosen here.

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final initial = gpu.gpuBackend;
  final other = initial == gpu.GpuBackendKind.impeller
      ? gpu.GpuBackendKind.wgpu
      : gpu.GpuBackendKind.impeller;

  test('a backend can be chosen and changed before first use', () {
    gpu.selectGpuBackend(other);
    expect(gpu.gpuBackend, other);
    gpu.selectGpuBackend(initial);
    expect(gpu.gpuBackend, initial);
  });

  test('the first GPU object fixes the backend', () async {
    try {
      await gpu.ShaderLibrary.fromBytes(ByteData(0));
    } on Exception {
      // An empty bundle fails to load; the attempt still uses the backend.
    }
    expect(() => gpu.selectGpuBackend(other), throwsStateError);
    gpu.selectGpuBackend(initial);
    expect(gpu.gpuBackend, initial);
  });
}
