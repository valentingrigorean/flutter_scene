part of '_gpu.dart';

/// The default graphics context, on the backend [selectGpuBackend] chose.
///
/// On a backend other than Impeller, the first read throws a [StateError]
/// when no backend of that kind is registered (see [registerGpuBackend]).
final GpuContext gpuContext = _openGpuContext();

GpuContext _openGpuContext() {
  final context = switch (_kind) {
    GpuBackendKind.impeller => GpuContext._impeller(fg.gpuContext),
    final kind => GpuContext._backend(_backendFor(kind).openContext()),
  };
  _backendInUse = true;
  return context;
}

/// A handle on the GPU device that creates every other GPU object.
final class GpuContext {
  GpuContext._impeller(fg.GpuContext this._impeller) : _backend = null;
  GpuContext._backend(GpuBackendContext this._backend) : _impeller = null;

  final fg.GpuContext? _impeller;
  final GpuBackendContext? _backend;

  /// The color format Flutter's own rendering uses.
  PixelFormat get defaultColorFormat =>
      _impeller?.defaultColorFormat ?? _backend!.defaultColorFormat;

  /// The stencil-only format the device prefers.
  PixelFormat get defaultStencilFormat =>
      _impeller?.defaultStencilFormat ?? _backend!.defaultStencilFormat;

  /// The combined depth-stencil format the device prefers.
  PixelFormat get defaultDepthStencilFormat =>
      _impeller?.defaultDepthStencilFormat ??
      _backend!.defaultDepthStencilFormat;

  /// The alignment every uniform buffer view's offset must have.
  int get minimumUniformByteAlignment =>
      _impeller?.minimumUniformByteAlignment ??
      _backend!.minimumUniformByteAlignment;

  /// Whether offscreen render targets can be multisampled.
  bool get doesSupportOffscreenMSAA =>
      _impeller?.doesSupportOffscreenMSAA ?? _backend!.doesSupportOffscreenMSAA;

  /// Whether a pass can render into a mip level other than the base.
  bool get doesSupportFramebufferRenderMipmap =>
      _impeller?.doesSupportFramebufferRenderMipmap ??
      _backend!.doesSupportFramebufferRenderMipmap;

  /// Whether each mip level can be uploaded separately.
  bool get doesSupportManuallyMippedTextures =>
      _impeller?.doesSupportManuallyMippedTextures ??
      _backend!.doesSupportManuallyMippedTextures;

  /// The largest anisotropy a sampler takes; 1 without anisotropic filtering.
  int get maxSamplerAnisotropy =>
      _impeller?.maxSamplerAnisotropy ?? _backend!.maxSamplerAnisotropy;

  /// Whether the device samples textures of [family].
  bool supportsTextureCompression(TextureCompressionFamily family) =>
      _impeller?.supportsTextureCompression(family) ??
      _backend!.supportsTextureCompression(family);

  /// Whether the device allocates a texture of [format] with this usage.
  bool supportsTextureFormat(
    PixelFormat format, {
    bool renderTarget = false,
    bool shaderRead = true,
    bool shaderWrite = false,
  }) =>
      _impeller?.supportsTextureFormat(
        format,
        renderTarget: renderTarget,
        shaderRead: shaderRead,
        shaderWrite: shaderWrite,
      ) ??
      _backend!.supportsTextureFormat(
        format,
        renderTarget: renderTarget,
        shaderRead: shaderRead,
        shaderWrite: shaderWrite,
      );

  /// Allocates a region of GPU memory. Throws when allocation fails.
  DeviceBuffer createDeviceBuffer(StorageMode storageMode, int sizeInBytes) {
    final impeller = _impeller;
    if (impeller != null) {
      return DeviceBuffer._impeller(
        impeller.createDeviceBuffer(storageMode, sizeInBytes),
      );
    }
    return DeviceBuffer._backend(
      _backend!.createDeviceBuffer(storageMode, sizeInBytes),
    );
  }

  /// Allocates host-visible GPU memory holding a copy of [data].
  DeviceBuffer createDeviceBufferWithCopy(ByteData data) {
    final impeller = _impeller;
    if (impeller != null) {
      return DeviceBuffer._impeller(impeller.createDeviceBufferWithCopy(data));
    }
    return DeviceBuffer._backend(_backend!.createDeviceBufferWithCopy(data));
  }

  /// Creates a per-frame bump allocator over a list of buffer blocks.
  HostBuffer createHostBuffer({
    int blockLengthInBytes = HostBuffer.kDefaultBlockLengthInBytes,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      return HostBuffer._impeller(
        impeller.createHostBuffer(blockLengthInBytes: blockLengthInBytes),
      );
    }
    return HostBuffer._backend(
      _backend!.createHostBuffer(blockLengthInBytes: blockLengthInBytes),
      blockLengthInBytes,
    );
  }

  /// Allocates a texture. Throws when allocation fails.
  Texture createTexture(
    StorageMode storageMode,
    int width,
    int height, {
    PixelFormat format = PixelFormat.r8g8b8a8UNormInt,
    int sampleCount = 1,
    TextureType? textureType,
    bool enableRenderTargetUsage = true,
    bool enableShaderReadUsage = true,
    bool enableShaderWriteUsage = false,
    int mipLevelCount = 1,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      return Texture._impeller(
        impeller.createTexture(
          storageMode,
          width,
          height,
          format: format,
          sampleCount: sampleCount,
          textureType: textureType,
          enableRenderTargetUsage: enableRenderTargetUsage,
          enableShaderReadUsage: enableShaderReadUsage,
          enableShaderWriteUsage: enableShaderWriteUsage,
          mipLevelCount: mipLevelCount,
        ),
      );
    }
    return Texture._backend(
      _backend!.createTexture(
        storageMode,
        width,
        height,
        format: format,
        sampleCount: sampleCount,
        textureType:
            textureType ??
            (sampleCount == 1
                ? TextureType.texture2D
                : TextureType.texture2DMultisample),
        enableRenderTargetUsage: enableRenderTargetUsage,
        enableShaderReadUsage: enableShaderReadUsage,
        enableShaderWriteUsage: enableShaderWriteUsage,
        mipLevelCount: mipLevelCount,
      ),
    );
  }

  /// Creates a surface whose frames Flutter draws as `ui.Image`s.
  GpuImageSurface createImageSurface(
    int width,
    int height, {
    PixelFormat? format,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      return GpuImageSurface._impeller(
        impeller.createImageSurface(width, height, format: format),
      );
    }
    final backend = _backend!;
    return GpuImageSurface._backend(
      backend.createImageSurface(
        width,
        height,
        format: format ?? backend.defaultColorFormat,
      ),
    );
  }

  /// Creates a command buffer that records and submits GPU work.
  CommandBuffer createCommandBuffer() {
    final impeller = _impeller;
    if (impeller != null) {
      return CommandBuffer._impeller(impeller.createCommandBuffer());
    }
    return CommandBuffer._backend(_backend!.createCommandBuffer());
  }

  /// Compiles the compute entry point [entryPoint] of the WGSL [source]; an
  /// empty [entryPoint] picks the only one.
  ///
  /// Throws an [UnsupportedError] where `gpuHost.capabilities.compute` is
  /// false, as on Impeller.
  ComputePipeline createComputePipeline(
    String source, {
    String entryPoint = '',
  }) => ComputePipeline._(
    _computeOf(_backend).createComputePipeline(source, entryPoint: entryPoint),
  );

  /// Reads [view] back once the work submitted before the call completes,
  /// blocking until then. Its offset and length are multiples of 4.
  ///
  /// Throws an [UnsupportedError] where `gpuHost.capabilities.compute` is
  /// false, as on Impeller.
  ByteData readBuffer(BufferView view) => _computeOf(_backend).readDeviceBuffer(
    view.buffer._backend!,
    offsetInBytes: view.offsetInBytes,
    lengthInBytes: view.lengthInBytes,
  );

  /// Creates a pipeline from a vertex and a fragment shader.
  RenderPipeline createRenderPipeline(
    Shader vertexShader,
    Shader fragmentShader, {
    VertexLayout? vertexLayout,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      return RenderPipeline._impeller(
        vertexShader,
        fragmentShader,
        impeller.createRenderPipeline(
          vertexShader._impeller!,
          fragmentShader._impeller!,
          vertexLayout: vertexLayout,
        ),
      );
    }
    return RenderPipeline._backend(
      vertexShader,
      fragmentShader,
      _backend!.createRenderPipeline(
        vertexShader._backend!,
        fragmentShader._backend!,
        vertexLayout: vertexLayout,
      ),
    );
  }
}
