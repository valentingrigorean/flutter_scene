// Each test file runs in its own isolate, so the fake backend registered here
// is the one every GPU object of the file is created on.

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' show StorageMode;
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/gpu_backend.dart';
import 'package:flutter_test/flutter_test.dart';

final List<String> _calls = [];

final class _Backend implements GpuBackend {
  @override
  GpuBackendKind get kind => GpuBackendKind.wgpu;

  @override
  GpuBackendContext openContext() => _context;

  @override
  bool get presents => false;

  @override
  Future<GpuBackendPresenter> openPresenter({
    required int width,
    required int height,
  }) => throw UnsupportedError('this backend presents nothing');
}

final _context = _Context();

final class _Context implements GpuBackendContext {
  bool hasCompute = true;

  @override
  GpuBackendCompute? get compute => hasCompute ? _Compute() : null;

  @override
  GpuBackendDeviceBuffer createDeviceBuffer(
    StorageMode storageMode,
    int size,
  ) => _Buffer(size);

  @override
  GpuBackendCommandBuffer createCommandBuffer() => _CommandBuffer();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Compute implements GpuBackendCompute {
  @override
  GpuBackendComputePipeline createComputePipeline(
    String source, {
    required String entryPoint,
  }) {
    _calls.add('pipeline $source $entryPoint');
    return _Pipeline();
  }

  @override
  ByteData readDeviceBuffer(
    GpuBackendDeviceBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
  }) {
    _calls.add('read $offsetInBytes $lengthInBytes');
    return ByteData(lengthInBytes);
  }
}

final class _Pipeline implements GpuBackendComputePipeline {}

final class _Buffer implements GpuBackendDeviceBuffer {
  _Buffer(this.sizeInBytes);

  @override
  final int sizeInBytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CommandBuffer implements GpuBackendCommandBuffer {
  @override
  GpuBackendComputePass createComputePass() {
    _calls.add('pass');
    return _Pass();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Pass implements GpuBackendComputePass {
  @override
  void bindPipeline(GpuBackendComputePipeline pipeline) =>
      _calls.add('bind pipeline');

  @override
  void bindBuffer(
    int group,
    int binding,
    GpuBackendDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) => _calls.add('bind $group $binding $offsetInBytes $lengthInBytes');

  @override
  void bindTexture(int group, int binding, GpuBackendTexture texture) =>
      _calls.add('bind sampled $group $binding');

  @override
  void bindStorageTexture(
    int group,
    int binding,
    GpuBackendTexture texture, {
    required int mipLevel,
  }) => _calls.add('bind texture $group $binding $mipLevel');

  @override
  void dispatch(int x, int y, int z) => _calls.add('dispatch $x $y $z');

  @override
  void dispatchIndirect(GpuBackendDeviceBuffer buffer, int offsetInBytes) =>
      _calls.add('dispatch indirect $offsetInBytes');
}

void main() {
  setUpAll(() => useGpuBackend(_Backend()));
  setUp(_calls.clear);

  test('the compute extension reaches the registered backend', () {
    final pipeline = gpu.gpuContext.createComputePipeline(
      'wgsl',
      entryPoint: 'main',
    );
    final buffer = gpu.gpuContext.createDeviceBuffer(
      StorageMode.devicePrivate,
      64,
    );
    final view = gpu.BufferView(buffer, offsetInBytes: 16, lengthInBytes: 32);
    gpu.gpuContext.createCommandBuffer().createComputePass()
      ..bindPipeline(pipeline)
      ..bindBuffer(1, 2, view)
      ..dispatch(4, 2)
      ..dispatchIndirect(view);
    expect(gpu.gpuContext.readBuffer(view).lengthInBytes, 32);
    expect(_calls, [
      'pipeline wgsl main',
      'pass',
      'bind pipeline',
      'bind 1 2 16 32',
      'dispatch 4 2 1',
      'dispatch indirect 16',
      'read 16 32',
    ]);
  });

  test('a backend without compute refuses compute pipelines and passes', () {
    _context.hasCompute = false;
    addTearDown(() => _context.hasCompute = true);
    expect(
      () => gpu.gpuContext.createComputePipeline('wgsl'),
      throwsUnsupportedError,
    );
    expect(
      () => gpu.gpuContext.createCommandBuffer().createComputePass(),
      throwsUnsupportedError,
    );
    expect(_calls, isEmpty);
  });
}
