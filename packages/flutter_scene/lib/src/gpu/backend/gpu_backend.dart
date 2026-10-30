/// The contract a native GPU backend other than Impeller implements for the
/// GPU shim, which an app registers with `registerGpuBackend` before the first
/// GPU object exists.
///
/// The shim's public classes are final facades that hold either a flutter_gpu
/// object or one of these backend objects. On Impeller each member is a direct
/// call to flutter_gpu; on a registered backend it is one interface call into
/// the objects below. The members take and return backend objects and
/// flutter_gpu's value types, never the shim's own classes, and carry the
/// shim's argument values with every default already applied.
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
import 'package:meta/meta.dart' show experimental;
import 'package:vector_math/vector_math.dart' as vm;

import '../shared/gpu_capabilities.dart';

/// A GPU backend the shim can render through instead of Impeller.
@experimental
abstract interface class GpuBackend {
  /// The kind `selectGpuBackend` and `FLUTTER_SCENE_GPU_BACKEND` name this
  /// backend by; never [GpuBackendKind.impeller].
  GpuBackendKind get kind;

  /// Opens the device every GPU object of the process is created on. The shim
  /// calls it on the first GPU object, and again from `reopenGpuContext`
  /// after the device is lost: the context it then returns keeps the shader
  /// libraries, shaders and render pipelines made before working on the new
  /// device.
  GpuBackendContext openContext();

  /// Whether [openPresenter] shows frames on this platform. Where false, an
  /// app reads its frames back into `ui.Image`s instead.
  bool get presents;

  /// Opens a presenter whose Flutter external texture shows frames of [width]
  /// by [height] physical pixels. Throws where it cannot open, as in a test
  /// process with no platform side.
  Future<GpuBackendPresenter> openPresenter({
    required int width,
    required int height,
  });
}

/// Shows frames rendered on a [GpuBackend] in a Flutter external texture,
/// with no readback.
@experimental
abstract interface class GpuBackendPresenter {
  /// The id to pass to Flutter's `Texture` widget.
  int get textureId;

  /// The frame width in physical pixels.
  int get width;

  /// The frame height in physical pixels.
  int get height;

  /// The native graphics API the frames reach the screen through, such as
  /// `metal` or `vulkan`, or null where unknown.
  String? get deviceApi;

  /// Resizes later frames to [width] by [height] physical pixels.
  Future<void> resize(int width, int height);

  /// Lends the buffer the next frame shows in, so the frame renders its final
  /// pass straight into it with no copy; or says why no buffer can be lent
  /// this frame: [GpuBackendUnlent.format] where the frame renders into a
  /// texture of its own that [present] copies, [GpuBackendUnlent.busy] where
  /// the texture keeps the frame it shows.
  GpuBackendAcquired acquireFrame();

  /// Draws [frame], a texture of the same backend, scaled to the presenter
  /// size, into the Flutter texture: the copy for a frame that rendered
  /// elsewhere than a buffer [acquireFrame] lent.
  void present(GpuBackendTexture frame);

  /// Releases the Flutter texture and its buffers.
  Future<void> dispose();
}

/// What [GpuBackendPresenter.acquireFrame] gives a frame: a
/// [GpuBackendLent] buffer, or the [GpuBackendUnlent] reason none is lent.
@experimental
sealed class GpuBackendAcquired {}

/// A buffer [GpuBackendPresenter.acquireFrame] lent for one frame.
@experimental
final class GpuBackendLent implements GpuBackendAcquired {
  /// Wraps the lent [frame].
  const GpuBackendLent(this.frame);

  /// The lent buffer.
  final GpuBackendPresenterFrame frame;
}

/// Why [GpuBackendPresenter.acquireFrame] lent no buffer.
@experimental
enum GpuBackendUnlent implements GpuBackendAcquired {
  /// The platform's buffers hold a format a frame cannot render into, so the
  /// frame renders into a texture of its own that
  /// [GpuBackendPresenter.present] copies.
  format,

  /// No buffer is free (shown, displayed or in flight), the presenter is
  /// resizing or its surface is not ready, so the texture keeps the frame it
  /// shows.
  busy,
}

/// One buffer of a [GpuBackendPresenter], lent for one frame.
@experimental
abstract interface class GpuBackendPresenterFrame {
  /// The buffer: a single-sampled, display-referred 8-bit color texture of
  /// the presenter's size that a render pass can write and a copy can write
  /// into.
  GpuBackendTexture get texture;

  /// Shows the buffer in the Flutter frame that calls this, once the GPU work
  /// submitted before the call has finished. The frame is lent no longer.
  void present();

  /// Returns the buffer unshown.
  void discard();
}

/// One color attachment of a backend render pass.
typedef GpuBackendColorTarget = ({
  GpuBackendTexture texture,
  GpuBackendTexture? resolveTexture,
  LoadAction loadAction,
  StoreAction storeAction,
  vm.Vector4 clearValue,
  int mipLevel,
  int slice,
});

/// The depth-stencil attachment of a backend render pass.
typedef GpuBackendDepthStencilTarget = ({
  GpuBackendTexture texture,
  LoadAction depthLoadAction,
  StoreAction depthStoreAction,
  double depthClearValue,
  LoadAction stencilLoadAction,
  StoreAction stencilStoreAction,
  int stencilClearValue,
  int mipLevel,
  int slice,
});

/// A rectangle of one mip level and slice of a backend texture, with its
/// extent resolved.
typedef GpuBackendTextureRegion = ({
  GpuBackendTexture texture,
  int x,
  int y,
  int width,
  int height,
  int mipLevel,
  int slice,
});

/// A range of a backend buffer.
typedef GpuBackendBufferRange = ({
  GpuBackendDeviceBuffer buffer,
  int offsetInBytes,
  int lengthInBytes,
});

/// The backend device behind the shim's `GpuContext`.
@experimental
abstract interface class GpuBackendContext {
  /// What the device can do; `gpuHost.capabilities` on this backend.
  GpuCapabilities get capabilities;

  /// The compute extension; non-null exactly where [capabilities] reports
  /// `compute`.
  GpuBackendCompute? get compute;

  /// The color format Flutter's own rendering uses.
  PixelFormat get defaultColorFormat;

  /// The stencil-only format the device prefers.
  PixelFormat get defaultStencilFormat;

  /// The combined depth-stencil format the device prefers.
  PixelFormat get defaultDepthStencilFormat;

  /// The alignment every uniform buffer view's offset must have.
  int get minimumUniformByteAlignment;

  /// Whether offscreen render targets can be multisampled.
  bool get doesSupportOffscreenMSAA;

  /// Whether a pass can render into a mip level other than the base.
  bool get doesSupportFramebufferRenderMipmap;

  /// Whether each mip level can be uploaded separately.
  bool get doesSupportManuallyMippedTextures;

  /// The largest anisotropy a sampler takes; 1 without anisotropic filtering.
  int get maxSamplerAnisotropy;

  /// Whether the device samples textures of [family].
  bool supportsTextureCompression(TextureCompressionFamily family);

  /// Whether the device allocates a texture of [format] with this usage.
  bool supportsTextureFormat(
    PixelFormat format, {
    required bool renderTarget,
    required bool shaderRead,
    required bool shaderWrite,
  });

  /// Allocates [size] bytes of GPU memory usable as any kind of buffer.
  GpuBackendDeviceBuffer createDeviceBuffer(StorageMode storageMode, int size);

  /// Allocates a host-visible buffer holding a copy of [data].
  GpuBackendDeviceBuffer createDeviceBufferWithCopy(ByteData data);

  /// Creates a per-frame bump allocator over blocks of [blockLengthInBytes].
  GpuBackendHostBuffer createHostBuffer({required int blockLengthInBytes});

  /// Allocates a texture.
  GpuBackendTexture createTexture(
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
  });

  /// Wraps or uploads a Flutter-rendered [image]. Throws an [Exception] when
  /// the backend cannot, which `gpuHost.imageToTexture` turns into null.
  GpuBackendTexture textureFromImage(ui.Image image);

  /// Creates a command buffer. [label] names it in a GPU capture or trace.
  GpuBackendCommandBuffer createCommandBuffer({String? label});

  /// Completes once every pipeline variant the device was asked for so far
  /// has finished compiling, whether it compiled or failed.
  ///
  /// A backend with [GpuCapabilities.aheadOfTimePipelines] compiles off the
  /// calling thread, so a caller that recorded draws ahead of a frame awaits
  /// this before the frame that binds the same variants, and that frame's
  /// submit waits for no compile. A compile error still surfaces where the
  /// variant is bound.
  Future<void> pipelinesReady();

  /// Runs [record], during which a draw whose pipeline variant is still
  /// compiling records nothing, and returns how many draws it skipped.
  ///
  /// A warm-up that discards its frame records through this, awaits
  /// [pipelinesReady] and records again, so its submits wait for no compile.
  int skipCompilingDraws(void Function() record);

  /// Creates a pipeline from a vertex and a fragment shader.
  GpuBackendRenderPipeline createRenderPipeline(
    GpuBackendShader vertexShader,
    GpuBackendShader fragmentShader, {
    VertexLayout? vertexLayout,
  });

  /// Loads the shader bundle asset [assetName], or null when it is missing.
  /// The shim calls it once per asset.
  Future<GpuBackendShaderLibrary?> loadShaderLibraryFromAsset(String assetName);

  /// Reads a shader bundle from [bytes], or null when it is not one.
  GpuBackendShaderLibrary? loadShaderLibraryFromBytes(ByteData bytes);

  /// Creates a surface of [width] by [height] frames of [format] whose
  /// presented frame Flutter draws as a `ui.Image`.
  GpuBackendImageSurface createImageSurface(
    int width,
    int height, {
    required PixelFormat format,
  });

  /// Creates a set of render items the backend keeps and draws inside a
  /// render pass, or null where it keeps none. A draw's uniform blocks named
  /// in [viewBlockNames] are the pass's view blocks, of at most
  /// [viewBlockLength] bytes each, which each [GpuBackendItemSet.draw]
  /// states in that order. A draw's textures named in [viewTextureNames] are
  /// the pass's view textures, re-supplied in that order each
  /// [GpuBackendItemSet.draw], so a kept item may sample a frame-transient
  /// target whose handle changes each frame.
  GpuBackendItemSet? createItemSet({
    required List<String> viewBlockNames,
    required int viewBlockLength,
    List<String> viewTextureNames = const [],
  });
}

/// Render items a backend keeps from frame to frame and draws inside a
/// render pass, so an unchanged item costs no encoding.
///
/// A draw is recorded on a [recorder] as it would be encoded into a pass and
/// kept as an item by [keep]; it draws in each [draw] of a pass it names
/// until it is kept again or removed. The resources it binds stay bound to
/// it, so a buffer it reads keeps the range it named: a change to what the
/// item draws keeps it again.
@experimental
abstract interface class GpuBackendItemSet {
  /// A pass that records draws for [keep] instead of encoding them, for
  /// attachments of [colorFormats], [depthStencilFormat] and [sampleCount].
  /// Its [GpuBackendRenderPass.clearBindings] also drops the draws it
  /// recorded since the last keep.
  GpuBackendRenderPass recorder({
    required List<PixelFormat> colorFormats,
    required PixelFormat? depthStencilFormat,
    required int sampleCount,
  });

  /// Keeps the one draw [recorder] recorded since its last keep as item
  /// [id] (0: a new one) and returns its id, which then draws in the passes
  /// of [passes] (bit n: pass n). [bounds] holds min x, y, z and max x, y, z
  /// in the space a [draw]'s clip matrix maps, and a null [bounds] is never
  /// culled. Returns null, keeping nothing and removing [id], when the
  /// recorder recorded no draw or several. The recorder's bindings are
  /// cleared either way.
  int? keep(
    GpuBackendRenderPass recorder, {
    int id = 0,
    required int passes,
    Float32List? bounds,
  });

  /// Removes item [id]; an unknown id is ignored.
  void remove(int id);

  /// Draws the items of pass [index] into [pass] where it stands, under its
  /// viewport and scissor, with [viewBlocks] as the pass's view blocks and
  /// [viewTextures] as its view textures, each in the order the set names
  /// them, culled by [clip] (a column-major matrix into clip space). A
  /// command buffer draws a pass index once.
  void draw(
    GpuBackendRenderPass pass,
    int index, {
    required List<ByteData> viewBlocks,
    required Float32List clip,
    List<GpuBackendTexture> viewTextures = const [],
  });

  /// Releases every item.
  void destroy();
}

/// The compute half of a [GpuBackendContext]: pipelines compiled from WGSL
/// and reading results back. A [GpuBackendCommandBuffer] records the passes
/// that dispatch them.
@experimental
abstract interface class GpuBackendCompute {
  /// Compiles the compute entry point [entryPoint] of the WGSL [source]; an
  /// empty [entryPoint] picks the only one. Throws when it does not compile.
  GpuBackendComputePipeline createComputePipeline(
    String source, {
    required String entryPoint,
  });

  /// Reads [lengthInBytes] of [buffer] from [offsetInBytes] once the work
  /// submitted before the call completes, blocking until then. Both are
  /// multiples of 4.
  ByteData readDeviceBuffer(
    GpuBackendDeviceBuffer buffer, {
    required int offsetInBytes,
    required int lengthInBytes,
  });
}

/// A compute pipeline; a compute pass of the same backend binds it.
@experimental
abstract interface class GpuBackendComputePipeline {}

/// Dispatches compute pipelines within one compute pass. Resources bind by
/// their WGSL `@group` and `@binding`, and the pass starts with none bound.
@experimental
abstract interface class GpuBackendComputePass {
  /// Binds [pipeline] for the following dispatches.
  void bindPipeline(GpuBackendComputePipeline pipeline);

  /// Binds a uniform or storage buffer range at [group] and [binding].
  void bindBuffer(
    int group,
    int binding,
    GpuBackendDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  );

  /// Binds [texture] as the sampled texture at [group] and [binding], which
  /// the pipeline reads with `textureLoad`.
  void bindTexture(int group, int binding, GpuBackendTexture texture);

  /// Binds mip level [mipLevel] of [texture], created with shader write
  /// usage, as the storage texture at [group] and [binding].
  void bindStorageTexture(
    int group,
    int binding,
    GpuBackendTexture texture, {
    required int mipLevel,
  });

  /// Dispatches [x] by [y] by [z] workgroups.
  void dispatch(int x, int y, int z);

  /// Dispatches the workgroup counts held as three 32-bit unsigned integers
  /// in [buffer] at [offsetInBytes].
  void dispatchIndirect(GpuBackendDeviceBuffer buffer, int offsetInBytes);
}

/// A region of GPU memory.
@experimental
abstract interface class GpuBackendDeviceBuffer {
  /// How the memory is reachable from the host.
  StorageMode get storageMode;

  /// The buffer's size.
  int get sizeInBytes;

  /// Whether the buffer is still backed by GPU memory.
  bool get isValid;

  /// Copies [sourceBytes] into the buffer from [destinationOffsetInBytes].
  /// Returns false when the copy did not happen.
  bool overwrite(ByteData sourceBytes, {required int destinationOffsetInBytes});

  /// Makes host writes to the range visible to the GPU; a [lengthInBytes] of
  /// -1 spans the rest of the buffer.
  void flush({required int offsetInBytes, required int lengthInBytes});

  /// Frees the buffer's GPU memory now rather than when it becomes
  /// unreachable; work already submitted keeps it. The buffer must not be
  /// used afterwards, and a second call does nothing.
  void destroy();
}

/// A per-frame bump allocator for transient data such as uniforms.
@experimental
abstract interface class GpuBackendHostBuffer {
  /// How many frames of blocks the allocator rotates through.
  int get frameCount;

  /// Copies [bytes] into the current frame's blocks and returns its range,
  /// aligned for a uniform binding.
  GpuBackendBufferRange emplace(ByteData bytes);

  /// Advances to the next frame's blocks.
  void reset();
}

/// A texture in GPU memory.
@experimental
abstract interface class GpuBackendTexture {
  /// How the memory is reachable from the host.
  StorageMode get storageMode;

  /// The texel format.
  PixelFormat get format;

  /// The base level's width.
  int get width;

  /// The base level's height.
  int get height;

  /// Samples per texel; above 1 for a multisampled texture.
  int get sampleCount;

  /// The texture's dimensionality.
  TextureType get textureType;

  /// Whether a pass can render into the texture.
  bool get enableRenderTargetUsage;

  /// Whether shaders can sample the texture.
  bool get enableShaderReadUsage;

  /// Whether shaders can write the texture.
  bool get enableShaderWriteUsage;

  /// The number of mip levels.
  int get mipLevelCount;

  /// Whether the texture is still backed by GPU memory.
  bool get isValid;

  /// Replaces the texels of one mip level and slice with [sourceBytes].
  void overwrite(
    ByteData sourceBytes, {
    required int mipLevel,
    required int slice,
  });

  /// Hands the base level to Flutter as a `ui.Image`.
  ui.Image asImage();

  /// Frees the texture's GPU memory now rather than when it becomes
  /// unreachable; work already submitted keeps it. The texture must not be
  /// used afterwards, and a second call does nothing. A texture a presenter
  /// lent stays with the presenter.
  void destroy();
}

/// The shaders of one loaded shader bundle.
@experimental
abstract interface class GpuBackendShaderLibrary {
  /// The shader named [shaderName], or null when the bundle has none. The
  /// shim asks once per name.
  GpuBackendShader? operator [](String shaderName);

  /// Replaces the library's shaders in place from regenerated bundle [bytes],
  /// keeping every shader it handed out. Returns an error description, or
  /// null on success.
  String? reinitializeFromBytes(ByteData bytes);

  /// Reloads the library in place from the asset [assetName]. Returns an
  /// error description, or null on success.
  String? reinitializeFromAsset(String assetName);
}

/// One compiled shader stage and the reflection it binds by.
@experimental
abstract interface class GpuBackendShader {
  /// The size of the uniform struct [uniformName], or null when absent.
  int? uniformStructSize(String uniformName);

  /// Where [memberName] sits in the uniform struct [uniformName], or null
  /// when absent.
  int? uniformMemberOffset(String uniformName, String memberName);
}

/// A pipeline built from a vertex and a fragment shader; a render pass of the
/// same backend binds it.
@experimental
abstract interface class GpuBackendRenderPipeline {}

/// Records render passes, compute passes and copies, then submits them to the
/// GPU.
@experimental
abstract interface class GpuBackendCommandBuffer {
  /// Starts a render pass into [colors] and [depthStencil], ending the pass
  /// before it. [label] names the pass in a GPU capture or trace.
  GpuBackendRenderPass createRenderPass({
    required List<GpuBackendColorTarget> colors,
    GpuBackendDepthStencilTarget? depthStencil,
    String? label,
  });

  /// Starts a compute pass, ending the pass before it. Called only where
  /// the context's [GpuBackendContext.compute] is non-null.
  GpuBackendComputePass createComputePass();

  /// Copies tightly packed texel data from [source] into [destination].
  void copyBufferToTexture(
    GpuBackendBufferRange source,
    GpuBackendTextureRegion destination,
  );

  /// Copies the texels of [source] into [destination], tightly packed.
  void copyTextureToBuffer(
    GpuBackendTextureRegion source,
    GpuBackendBufferRange destination,
  );

  /// Copies the texels of [source] into [destination] at [x], [y] of
  /// [mipLevel] and [slice].
  void copyTextureToTexture(
    GpuBackendTextureRegion source,
    GpuBackendTexture destination, {
    required int x,
    required int y,
    required int mipLevel,
    required int slice,
  });

  /// Submits the recorded work. [completionCallback] runs once the GPU is
  /// done with it. The shim calls it at most once.
  void submit({CompletionCallback? completionCallback});
}

/// Draws into the attachments of one render pass.
@experimental
abstract interface class GpuBackendRenderPass {
  /// Binds [pipeline] for the following draws.
  void bindPipeline(GpuBackendRenderPipeline pipeline);

  /// Binds a vertex buffer range to [slot].
  void bindVertexBuffer(
    GpuBackendDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes, {
    required int slot,
  });

  /// Binds the index buffer range.
  void bindIndexBuffer(
    GpuBackendDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
    IndexType indexType,
  );

  /// Binds a buffer range to [shader]'s uniform block [uniformName].
  void bindUniform(
    GpuBackendShader shader,
    String uniformName,
    GpuBackendDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  );

  /// Binds [texture], sampled with [sampler], to [shader]'s texture
  /// [uniformName].
  void bindTexture(
    GpuBackendShader shader,
    String uniformName,
    GpuBackendTexture texture,
    SamplerOptions? sampler,
  );

  /// Forgets every uniform, texture, vertex and index binding.
  void clearBindings();

  /// Turns blending on or off for one color attachment.
  void setColorBlendEnable(bool enable, {required int colorAttachmentIndex});

  /// Sets the blend equation for one color attachment.
  void setColorBlendEquation(
    ColorBlendEquation equation, {
    required int colorAttachmentIndex,
  });

  /// Turns depth writes on or off.
  void setDepthWriteEnable(bool enable);

  /// Sets the depth test.
  void setDepthCompareOperation(CompareFunction compareFunction);

  /// Sets the stencil reference value.
  void setStencilReference(int referenceValue);

  /// Sets the stencil test and operations for [targetFace].
  void setStencilConfig(StencilConfig configuration, StencilFace targetFace);

  /// Sets which faces are culled.
  void setCullMode(CullMode cullMode);

  /// Sets whether triangles fill or draw as lines.
  void setPolygonMode(PolygonMode polygonMode);

  /// Sets the primitive topology.
  void setPrimitiveType(PrimitiveType primitiveType);

  /// Sets which winding is front-facing.
  void setWindingOrder(WindingOrder windingOrder);

  /// Sets the scissor rectangle.
  void setScissor(Scissor scissor);

  /// Sets the viewport.
  void setViewport(Viewport viewport);

  /// Draws [vertexCount] vertices, [instanceCount] times.
  void draw(int vertexCount, {required int instanceCount});

  /// Draws [indexCount] indices from the bound index buffer, [instanceCount]
  /// times.
  void drawIndexed(int indexCount, {required int instanceCount});

  /// Draws indexed primitives with the five 32-bit draw arguments held in
  /// [buffer] at [offsetInBytes]: index count, instance count, first index,
  /// base vertex and first instance. The device's capabilities report
  /// `indirectDraw`.
  void drawIndexedIndirect(GpuBackendDeviceBuffer buffer, int offsetInBytes);
}

/// A ring of textures whose presented frame Flutter draws as a `ui.Image`.
@experimental
abstract interface class GpuBackendImageSurface {
  /// The frame width.
  int get width;

  /// The frame height.
  int get height;

  /// The color format of every frame.
  PixelFormat get format;

  /// How many textures back the surface.
  int get debugBackingTextureCount;

  /// The most recently presented frame, or null before the first.
  ui.Image? get currentImage;

  /// Resizes later frames.
  void resize(int width, int height);

  /// A texture to render the next frame into.
  GpuBackendTexture acquireNextFrame();

  /// Presents [frame] once [commandBuffer], which renders it, is submitted.
  GpuPresentStatus present(
    GpuBackendTexture frame,
    GpuBackendCommandBuffer commandBuffer,
  );

  /// Returns [frame] unpresented.
  void discard(GpuBackendTexture frame);
}
