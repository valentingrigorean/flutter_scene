// Each test file runs in its own isolate, so the backend starts unchosen here.

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a backend can be chosen and changed before first use', () {
    gpu.selectGpuBackend(gpu.GpuBackendKind.wgpu);
    expect(gpu.gpuBackend, gpu.GpuBackendKind.wgpu);
    gpu.selectGpuBackend(gpu.GpuBackendKind.impeller);
    expect(gpu.gpuBackend, gpu.GpuBackendKind.impeller);
  });

  test('the wgpu backend is a stub that does not fix the choice', () {
    gpu.selectGpuBackend(gpu.GpuBackendKind.wgpu);
    expect(() => gpu.gpuContext, throwsUnsupportedError);
    gpu.selectGpuBackend(gpu.GpuBackendKind.impeller);
    expect(gpu.gpuBackend, gpu.GpuBackendKind.impeller);
  });

  test('the first GPU object fixes the backend', () async {
    try {
      await gpu.ShaderLibrary.fromBytes(ByteData(0));
    } on Exception {
      // An empty bundle fails to load; the attempt still uses the backend.
    }
    expect(
      () => gpu.selectGpuBackend(gpu.GpuBackendKind.wgpu),
      throwsStateError,
    );
    gpu.selectGpuBackend(gpu.GpuBackendKind.impeller);
    expect(gpu.gpuBackend, gpu.GpuBackendKind.impeller);
  });
}
