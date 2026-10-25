part of '_gpu.dart';

/// A compute pipeline compiled from WGSL, which a [ComputePass] dispatches.
///
/// Compute runs only on a registered backend whose `gpuHost.capabilities`
/// report `compute`; Impeller has none.
final class ComputePipeline {
  ComputePipeline._(this._backend);

  final GpuBackendComputePipeline _backend;
}

/// Dispatches compute pipelines within one compute pass of a
/// [CommandBuffer]. Resources bind by their WGSL `@group` and `@binding`,
/// and the pass starts with none bound.
final class ComputePass {
  ComputePass._(this._backend);

  final GpuBackendComputePass _backend;

  /// Binds [pipeline] for the following dispatches.
  void bindPipeline(ComputePipeline pipeline) =>
      _backend.bindPipeline(pipeline._backend);

  /// Binds the uniform or storage buffer range [view] at [group] and
  /// [binding].
  void bindBuffer(int group, int binding, BufferView view) =>
      _backend.bindBuffer(
        group,
        binding,
        view.buffer._backend!,
        view.offsetInBytes,
        view.lengthInBytes,
      );

  /// Binds [texture] as the sampled texture at [group] and [binding], which
  /// the pipeline reads with `textureLoad`.
  void bindTexture(int group, int binding, Texture texture) =>
      _backend.bindTexture(group, binding, texture._backend!);

  /// Binds mip level [mipLevel] of [texture], created with shader write
  /// usage, as the storage texture at [group] and [binding].
  void bindStorageTexture(
    int group,
    int binding,
    Texture texture, {
    int mipLevel = 0,
  }) => _backend.bindStorageTexture(
    group,
    binding,
    texture._backend!,
    mipLevel: mipLevel,
  );

  /// Dispatches [x] by [y] by [z] workgroups of the bound pipeline.
  void dispatch(int x, [int y = 1, int z = 1]) => _backend.dispatch(x, y, z);

  /// Dispatches the workgroup counts held as three 32-bit unsigned integers
  /// at the start of [arguments].
  void dispatchIndirect(BufferView arguments) => _backend.dispatchIndirect(
    arguments.buffer._backend!,
    arguments.offsetInBytes,
  );
}

GpuBackendCompute _computeOf(GpuBackendContext? backend) =>
    backend?.compute ??
    (throw UnsupportedError(
      'The ${_kind.name} GPU backend has no compute; check '
      'gpuHost.capabilities.compute first.',
    ));
