// Each test file runs in its own isolate, so the backend starts unchosen and
// unregistered here.

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/impeller/_gpu.dart' as gpu;
import 'package:flutter_scene/gpu_backend.dart';
import 'package:flutter_test/flutter_test.dart';

final class _UnopenedBackend implements GpuBackend {
  @override
  GpuBackendKind get kind => GpuBackendKind.wgpu;

  @override
  GpuBackendContext openContext() =>
      throw UnsupportedError('this backend opens no device');
}

void main() {
  test('wgpu is not selectable before a backend registers', () {
    expect(
      () => gpu.selectGpuBackend(GpuBackendKind.wgpu),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('registerGpuBackend'),
        ),
      ),
    );
    expect(gpu.gpuBackend, GpuBackendKind.impeller);
  });

  test('a registered backend can be chosen and changed before first use', () {
    final backend = _UnopenedBackend();
    registerGpuBackend(backend);
    expect(registeredGpuBackend, same(backend));
    gpu.selectGpuBackend(GpuBackendKind.wgpu);
    expect(gpu.gpuBackend, GpuBackendKind.wgpu);
    gpu.selectGpuBackend(GpuBackendKind.impeller);
    expect(gpu.gpuBackend, GpuBackendKind.impeller);
  });

  test('the first GPU object fixes the backend and the registration', () async {
    try {
      await gpu.ShaderLibrary.fromBytes(ByteData(0));
    } on Exception {
      // An empty bundle fails to load; the attempt still uses the backend.
    }
    expect(() => gpu.selectGpuBackend(GpuBackendKind.wgpu), throwsStateError);
    expect(() => registerGpuBackend(_UnopenedBackend()), throwsStateError);
    gpu.selectGpuBackend(GpuBackendKind.impeller);
    expect(gpu.gpuBackend, GpuBackendKind.impeller);
  });
}
