// Each test file runs in its own isolate, so the backend starts unchosen and
// unregistered here.

@TestOn('vm')
library;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/gpu_backend.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Context implements GpuBackendContext {
  _Context(this.device);

  final int device;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Backend implements GpuBackend {
  int opens = 0;

  @override
  GpuBackendKind get kind => GpuBackendKind.wgpu;

  @override
  GpuBackendContext openContext() => _Context(++opens);

  @override
  bool get presents => false;

  @override
  Future<GpuBackendPresenter> openPresenter({
    required int width,
    required int height,
  }) => throw UnsupportedError('this backend presents nothing');
}

void main() {
  test('a context reopened after a lost device opens the backend again, and '
      'a device-local object is made again on the new device', () {
    final backend = _Backend();
    useGpuBackend(backend);
    final made = gpu.DeviceLocal(() => backend.opens);

    gpu.gpuContext;
    expect(made.value, 1);
    expect(made.value, 1);

    reopenGpuContext();

    expect(backend.opens, 2);
    expect(gpu.gpuContextGeneration, 1);
    expect(made.value, 2);
  });
}
