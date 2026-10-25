/// The wgpu device the native GPU shim drives when `selectGpuBackend` picks
/// [GpuBackendKind.wgpu].
///
/// Every resource is a handle on the `flutter_scene_wgpu` native library. The
/// shim's public classes wrap these, so the members here take and return wgpu
/// handles and flutter_gpu's value types, never the shim's own classes.
///
/// Every member throws [UnsupportedError] until the device is implemented
/// over `flutter_scene_wgpu`.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart'
    show
        CompareFunction,
        ColorBlendEquation,
        CompletionCallback,
        CullMode,
        GpuPresentStatus,
        IndexType,
        LoadAction,
        PixelFormat,
        PolygonMode,
        PrimitiveType,
        SamplerOptions,
        Scissor,
        StencilConfig,
        StencilFace,
        StorageMode,
        StoreAction,
        TextureCompressionFamily,
        TextureType,
        VertexLayout,
        Viewport,
        WindingOrder;
import 'package:vector_math/vector_math.dart' as vm;

import '../shared/gpu_capabilities.dart';

Never _unsupported() =>
    throw UnsupportedError('The wgpu GPU backend is not implemented yet.');

/// One color attachment of a wgpu render pass.
typedef WgpuColorTarget = ({
  WgpuTexture texture,
  WgpuTexture? resolveTexture,
  LoadAction loadAction,
  StoreAction storeAction,
  vm.Vector4 clearValue,
  int mipLevel,
  int slice,
});

/// The depth-stencil attachment of a wgpu render pass.
typedef WgpuDepthStencilTarget = ({
  WgpuTexture texture,
  LoadAction depthLoadAction,
  StoreAction depthStoreAction,
  double depthClearValue,
  LoadAction stencilLoadAction,
  StoreAction stencilStoreAction,
  int stencilClearValue,
  int mipLevel,
  int slice,
});

/// A rectangle of one mip level and slice of a wgpu texture.
typedef WgpuTextureRegion = ({
  WgpuTexture texture,
  int x,
  int y,
  int width,
  int height,
  int mipLevel,
  int slice,
});

/// A range of a wgpu buffer.
typedef WgpuBufferRange = ({
  WgpuDeviceBuffer buffer,
  int offsetInBytes,
  int lengthInBytes,
});

/// The wgpu device and its queue.
final class WgpuContext {
  /// Opens the wgpu device.
  factory WgpuContext.open() => _unsupported();

  /// What this device can do.
  GpuCapabilities get capabilities => _unsupported();

  PixelFormat get defaultColorFormat => _unsupported();
  PixelFormat get defaultStencilFormat => _unsupported();
  PixelFormat get defaultDepthStencilFormat => _unsupported();
  int get minimumUniformByteAlignment => _unsupported();
  bool get doesSupportOffscreenMSAA => _unsupported();
  bool get doesSupportFramebufferRenderMipmap => _unsupported();
  bool get doesSupportManuallyMippedTextures => _unsupported();
  int get maxSamplerAnisotropy => _unsupported();

  bool supportsTextureCompression(TextureCompressionFamily family) =>
      _unsupported();

  bool supportsTextureFormat(
    PixelFormat format, {
    required bool renderTarget,
    required bool shaderRead,
    required bool shaderWrite,
  }) => _unsupported();

  WgpuDeviceBuffer createDeviceBuffer(StorageMode storageMode, int size) =>
      _unsupported();

  WgpuDeviceBuffer createDeviceBufferWithCopy(ByteData data) => _unsupported();

  WgpuHostBuffer createHostBuffer({required int blockLengthInBytes}) =>
      _unsupported();

  WgpuTexture createTexture(
    StorageMode storageMode,
    int width,
    int height, {
    required PixelFormat format,
    required int sampleCount,
    required TextureType textureType,
    required bool enableRenderTargetUsage,
    required bool enableShaderReadUsage,
    required bool enableShaderWriteUsage,
    required int mipLevelCount,
  }) => _unsupported();

  /// Uploads a Flutter-rendered [image] into a new texture.
  WgpuTexture textureFromImage(ui.Image image) => _unsupported();

  WgpuCommandBuffer createCommandBuffer() => _unsupported();

  WgpuRenderPipeline createRenderPipeline(
    WgpuShader vertexShader,
    WgpuShader fragmentShader, {
    VertexLayout? vertexLayout,
  }) => _unsupported();

  WgpuShaderLibrary? loadShaderLibraryFromAsset(String assetName) =>
      _unsupported();

  WgpuShaderLibrary? loadShaderLibraryFromBytes(ByteData bytes) =>
      _unsupported();

  WgpuImageSurface createImageSurface(
    int width,
    int height, {
    required PixelFormat format,
  }) => _unsupported();
}

final class WgpuDeviceBuffer {
  WgpuDeviceBuffer._();

  StorageMode get storageMode => _unsupported();
  int get sizeInBytes => _unsupported();
  bool get isValid => _unsupported();

  bool overwrite(ByteData sourceBytes, {required int destinationOffsetInBytes}) =>
      _unsupported();

  void flush({required int offsetInBytes, required int lengthInBytes}) =>
      _unsupported();
}

final class WgpuHostBuffer {
  WgpuHostBuffer._();

  int get frameCount => _unsupported();

  WgpuBufferRange emplace(ByteData bytes) => _unsupported();

  void reset() => _unsupported();
}

final class WgpuTexture {
  WgpuTexture._();

  StorageMode get storageMode => _unsupported();
  PixelFormat get format => _unsupported();
  int get width => _unsupported();
  int get height => _unsupported();
  int get sampleCount => _unsupported();
  TextureType get textureType => _unsupported();
  bool get enableRenderTargetUsage => _unsupported();
  bool get enableShaderReadUsage => _unsupported();
  bool get enableShaderWriteUsage => _unsupported();
  int get mipLevelCount => _unsupported();
  bool get isValid => _unsupported();

  void overwrite(ByteData sourceBytes, {required int mipLevel, required int slice}) =>
      _unsupported();

  /// Hands the texture to Flutter as a `ui.Image`.
  ui.Image asImage() => _unsupported();
}

final class WgpuShaderLibrary {
  WgpuShaderLibrary._();

  WgpuShader? operator [](String shaderName) => _unsupported();

  /// Replaces the library's shaders in place, keeping every [WgpuShader]
  /// handed out. Returns an error description, or null on success.
  String? reinitializeFromBytes(ByteData bytes) => _unsupported();

  /// As [reinitializeFromBytes], from a bundle asset.
  String? reinitializeFromAsset(String assetName) => _unsupported();
}

final class WgpuShader {
  WgpuShader._();

  int? uniformStructSize(String uniformName) => _unsupported();

  int? uniformMemberOffset(String uniformName, String memberName) =>
      _unsupported();
}

final class WgpuRenderPipeline {
  WgpuRenderPipeline._();
}

final class WgpuCommandBuffer {
  WgpuCommandBuffer._();

  WgpuRenderPass createRenderPass({
    required List<WgpuColorTarget> colors,
    WgpuDepthStencilTarget? depthStencil,
  }) => _unsupported();

  void copyBufferToTexture(
    WgpuBufferRange source,
    WgpuTextureRegion destination,
  ) => _unsupported();

  void copyTextureToBuffer(
    WgpuTextureRegion source,
    WgpuBufferRange destination,
  ) => _unsupported();

  void copyTextureToTexture(
    WgpuTextureRegion source,
    WgpuTexture destination, {
    required int x,
    required int y,
    required int mipLevel,
    required int slice,
  }) => _unsupported();

  void submit({CompletionCallback? completionCallback}) => _unsupported();
}

final class WgpuRenderPass {
  WgpuRenderPass._();

  void bindPipeline(WgpuRenderPipeline pipeline) => _unsupported();

  void bindVertexBuffer(
    WgpuDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes, {
    required int slot,
  }) => _unsupported();

  void bindIndexBuffer(
    WgpuDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
    IndexType indexType,
  ) => _unsupported();

  void bindUniform(
    WgpuShader shader,
    String uniformName,
    WgpuDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) => _unsupported();

  void bindTexture(
    WgpuShader shader,
    String uniformName,
    WgpuTexture texture,
    SamplerOptions? sampler,
  ) => _unsupported();

  void clearBindings() => _unsupported();

  void setColorBlendEnable(bool enable, {required int colorAttachmentIndex}) =>
      _unsupported();

  void setColorBlendEquation(
    ColorBlendEquation equation, {
    required int colorAttachmentIndex,
  }) => _unsupported();

  void setDepthWriteEnable(bool enable) => _unsupported();
  void setDepthCompareOperation(CompareFunction compareFunction) =>
      _unsupported();
  void setStencilReference(int referenceValue) => _unsupported();
  void setStencilConfig(StencilConfig configuration, StencilFace targetFace) =>
      _unsupported();
  void setCullMode(CullMode cullMode) => _unsupported();
  void setPolygonMode(PolygonMode polygonMode) => _unsupported();
  void setPrimitiveType(PrimitiveType primitiveType) => _unsupported();
  void setWindingOrder(WindingOrder windingOrder) => _unsupported();
  void setScissor(Scissor scissor) => _unsupported();
  void setViewport(Viewport viewport) => _unsupported();
  void draw(int vertexCount, {required int instanceCount}) => _unsupported();
  void drawIndexed(int indexCount, {required int instanceCount}) =>
      _unsupported();
}

final class WgpuImageSurface {
  WgpuImageSurface._();

  int get width => _unsupported();
  int get height => _unsupported();
  PixelFormat get format => _unsupported();
  int get debugBackingTextureCount => _unsupported();
  ui.Image? get currentImage => _unsupported();

  void resize(int width, int height) => _unsupported();

  WgpuTexture acquireNextFrame() => _unsupported();

  GpuPresentStatus present(WgpuTexture frame, WgpuCommandBuffer commandBuffer) =>
      _unsupported();

  void discard(WgpuTexture frame) => _unsupported();
}
