part of '_gpu.dart';

/// The default graphics context, on the backend [selectGpuBackend] chose.
final GpuContext gpuContext = _openGpuContext();

GpuContext _openGpuContext() {
  final context = switch (_backend) {
    GpuBackendKind.impeller => GpuContext._impeller(fg.gpuContext),
    GpuBackendKind.wgpu => GpuContext._wgpu(WgpuContext.open()),
  };
  _backendInUse = true;
  return context;
}

/// A handle on the GPU device that creates every other GPU object.
final class GpuContext {
  GpuContext._impeller(fg.GpuContext this._impeller) : _wgpu = null;
  GpuContext._wgpu(WgpuContext this._wgpu) : _impeller = null;

  final fg.GpuContext? _impeller;
  final WgpuContext? _wgpu;

  /// The color format Flutter's own rendering uses.
  PixelFormat get defaultColorFormat =>
      _impeller?.defaultColorFormat ?? _wgpu!.defaultColorFormat;

  /// The stencil-only format the device prefers.
  PixelFormat get defaultStencilFormat =>
      _impeller?.defaultStencilFormat ?? _wgpu!.defaultStencilFormat;

  /// The combined depth-stencil format the device prefers.
  PixelFormat get defaultDepthStencilFormat =>
      _impeller?.defaultDepthStencilFormat ?? _wgpu!.defaultDepthStencilFormat;

  /// The alignment every uniform buffer view's offset must have.
  int get minimumUniformByteAlignment =>
      _impeller?.minimumUniformByteAlignment ??
      _wgpu!.minimumUniformByteAlignment;

  /// Whether offscreen render targets can be multisampled.
  bool get doesSupportOffscreenMSAA =>
      _impeller?.doesSupportOffscreenMSAA ?? _wgpu!.doesSupportOffscreenMSAA;

  /// Whether a pass can render into a mip level other than the base.
  bool get doesSupportFramebufferRenderMipmap =>
      _impeller?.doesSupportFramebufferRenderMipmap ??
      _wgpu!.doesSupportFramebufferRenderMipmap;

  /// Whether each mip level can be uploaded separately.
  bool get doesSupportManuallyMippedTextures =>
      _impeller?.doesSupportManuallyMippedTextures ??
      _wgpu!.doesSupportManuallyMippedTextures;

  /// The largest anisotropy a sampler takes; 1 without anisotropic filtering.
  int get maxSamplerAnisotropy =>
      _impeller?.maxSamplerAnisotropy ?? _wgpu!.maxSamplerAnisotropy;

  /// Whether the device samples textures of [family].
  bool supportsTextureCompression(TextureCompressionFamily family) =>
      _impeller?.supportsTextureCompression(family) ??
      _wgpu!.supportsTextureCompression(family);

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
      _wgpu!.supportsTextureFormat(
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
    return DeviceBuffer._wgpu(
      _wgpu!.createDeviceBuffer(storageMode, sizeInBytes),
    );
  }

  /// Allocates host-visible GPU memory holding a copy of [data].
  DeviceBuffer createDeviceBufferWithCopy(ByteData data) {
    final impeller = _impeller;
    if (impeller != null) {
      return DeviceBuffer._impeller(impeller.createDeviceBufferWithCopy(data));
    }
    return DeviceBuffer._wgpu(_wgpu!.createDeviceBufferWithCopy(data));
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
    return HostBuffer._wgpu(
      _wgpu!.createHostBuffer(blockLengthInBytes: blockLengthInBytes),
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
    return Texture._wgpu(
      _wgpu!.createTexture(
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
    final wgpu = _wgpu!;
    return GpuImageSurface._wgpu(
      wgpu.createImageSurface(
        width,
        height,
        format: format ?? wgpu.defaultColorFormat,
      ),
    );
  }

  /// Creates a command buffer that records and submits GPU work.
  CommandBuffer createCommandBuffer() {
    final impeller = _impeller;
    if (impeller != null) {
      return CommandBuffer._impeller(impeller.createCommandBuffer());
    }
    return CommandBuffer._wgpu(_wgpu!.createCommandBuffer());
  }

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
    return RenderPipeline._wgpu(
      vertexShader,
      fragmentShader,
      _wgpu!.createRenderPipeline(
        vertexShader._wgpu!,
        fragmentShader._wgpu!,
        vertexLayout: vertexLayout,
      ),
    );
  }
}
