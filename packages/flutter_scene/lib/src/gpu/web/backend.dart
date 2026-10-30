part of '_gpu.dart';

// The web shim's API as backend-neutral interfaces, and the switch that picks
// which backend implements them. The members are exactly what flutter_scene
// calls (the stub's surface), so a backend is complete when these are.

const String _backendDefine = String.fromEnvironment(
  'FLUTTER_SCENE_GPU_BACKEND',
);

/// Whether `--dart-define=FLUTTER_SCENE_GPU_BACKEND=webgl2` forces WebGL2.
///
/// Const, so a forced build leaves the WebGPU backend out. A conditional
/// import cannot make this choice: the web compilers ignore environment tests
/// in import conditions.
const bool webGl2Forced = _backendDefine == webGl2BackendDefine;

/// Everything a web backend provides beyond its resource classes.
abstract base class WebBackend {
  /// Readies the backend; WebGPU acquires its device here. Must complete
  /// before [context] is read.
  Future<void> initialize();

  GpuContext get context;
  GpuHost get host;

  /// Whether the backend runs GPU work while passes are encoded, as WebGL2
  /// does, rather than at submission, as WebGPU does.
  bool get immediateExecution;

  Texture textureFromImage(GpuContext gpuContext, ui.Image image);

  Future<ShaderLibrary?> loadShaderLibraryAsync(String assetName);
  Future<ShaderLibrary?> loadShaderLibraryFromBytesAsync(ByteData bytes);
  Future<void> reinitializeShaderLibraryAsync(String assetKey);
  Future<String?> reinitializeShaderLibraryFromBytesAsync(
    ShaderLibrary library,
    ByteData bytes,
  );
  ShaderLibrary compileShaderLibraryInline(
    Map<String, ({String source, ShaderStage stage})> shaders,
  );

  Future<Texture?> createTextureFromEncodedImage(
    Uint8List encoded, {
    MipContent content = MipContent.color,
    bool mipmaps = true,
    int? maxMipLevels,
    int? maxSize,
  });

  Future<ui.Image> presentTextureAsImage(
    Texture texture, {
    bool transferOwnership = false,
  });
  PixelFormat get reversedDepthStencilFormat;
  ({DeviceBuffer vertex, DeviceBuffer index, int indexBaseOffset})
  createGeometryBuffers(int vertexBytes, int indexBytes);
  bool writeGeometryData(
    DeviceBuffer buffer,
    TypedData source, {
    required int destinationOffsetInBytes,
  });

  Surface createSurface({required int width, required int height});
}

WebBackend? _selected = webGl2Forced ? createWebGlBackend() : null;

Future<void>? _initializing;

WebBackend get _backend =>
    _selected ??
    (throw StateError(
      'The web GPU backend was used before startup chose it. Await '
      'Scene.initializeStaticResources() (or initializeGpuBackend()) before '
      'creating GPU resources.',
    ));

/// Chooses the backend, WebGPU where the browser hands out a device and
/// WebGL2 elsewhere, and readies it. `Scene.initializeStaticResources` awaits
/// it before anything touches [gpuContext]; concurrent and later callers
/// share one start, and a failed one is tried again on the next call.
Future<void> initializeGpuBackend() =>
    _initializing ??= _initialize().catchError((Object error) {
      _initializing = null;
      throw error;
    });

Future<void> _initialize() async {
  final backend = _selected ??= await _select();
  await backend.initialize();
}

Future<WebBackend> _select() async {
  if (webGl2Forced) return createWebGlBackend();
  final probe = await WebGpuDevice.request(allowFallbackAdapter: true);
  final device = probe.device;
  switch (chooseWebBackend(
    define: _backendDefine,
    webGpuDevice: device != null,
  )) {
    case WebBackendKind.webGpu:
      return createWebGpuBackend(device!, probe);
    case WebBackendKind.webGl2:
      if (kDebugMode) debugPrint('flutter_scene: WebGL2 backend, $probe');
      return createWebGlBackend();
  }
}

/// The backend once startup chose it, for entry points that are asynchronous
/// anyway and so may run before startup finishes.
Future<WebBackend> _ready() async {
  await initializeGpuBackend();
  return _backend;
}

/// Whether the active backend runs GPU work while passes are encoded.
bool get immediateGpuExecution => _backend.immediateExecution;

/// The active backend's context.
GpuContext get gpuContext => _backend.context;

/// How many times the context opened again after a lost device; always 0 on
/// web, where the backend keeps its one context.
int get gpuContextGeneration => 0;

/// The context whose textures Flutter composites without a copy. The web has
/// one context, so this is [gpuContext].
GpuContext get flutterGpuContext => gpuContext;

/// The active backend's host integration.
GpuHost get gpuHost => _backend.host;

abstract base class GpuContext {
  /// Render items kept from frame to frame; the web keeps none and encodes
  /// every draw each frame.
  ItemSet? createItemSet({
    required List<String> viewBlockNames,
    required int viewBlockLength,
  }) => null;

  PixelFormat get defaultColorFormat;
  PixelFormat get defaultStencilFormat;
  PixelFormat get defaultDepthStencilFormat;
  int get minimumUniformByteAlignment;

  /// The maximum anisotropy clamp a sampler takes; 1 where anisotropic
  /// filtering is unsupported.
  int get maxSamplerAnisotropy;
  bool get doesSupportOffscreenMSAA;
  bool get doesSupportFramebufferRenderMipmap;
  bool get doesSupportManuallyMippedTextures;
  DeviceBuffer createDeviceBuffer(StorageMode storageMode, int sizeInBytes);
  DeviceBuffer createDeviceBufferWithCopy(ByteData data);
  HostBuffer createHostBuffer({
    int blockLengthInBytes = HostBuffer.kDefaultBlockLengthInBytes,
  });
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
  });
  bool supportsTextureCompression(TextureCompressionFamily family);

  /// Creates a command buffer. [label] names it in a GPU capture or trace
  /// where the backend has labels; WebGL2 drops it.
  CommandBuffer createCommandBuffer({String? label});

  /// Compiles the compute entry point [entryPoint] of the WGSL [source]; an
  /// empty [entryPoint] picks the only one.
  ///
  /// Throws an [UnsupportedError] where `gpuHost.capabilities.compute` is
  /// false, as on WebGL2.
  ComputePipeline createComputePipeline(
    String source, {
    String entryPoint = '',
  });
  RenderPipeline createRenderPipeline(
    Shader vertexShader,
    Shader fragmentShader, {
    VertexLayout? vertexLayout,
  });
}

abstract base class DeviceBuffer {
  StorageMode get storageMode;
  int get sizeInBytes;
  bool get isValid;
  bool overwrite(ByteData sourceBytes, {int destinationOffsetInBytes = 0});
  void flush({int offsetInBytes = 0, int lengthInBytes = -1});
}

abstract base class HostBuffer {
  static const int kDefaultBlockLengthInBytes = 1024000;
  int get blockLengthInBytes;
  int get frameCount;
  BufferView emplace(ByteData bytes);
  void reset();
}

abstract base class Texture {
  Texture();

  factory Texture.fromImage(GpuContext gpuContext, ui.Image image) =>
      _backend.textureFromImage(gpuContext, image);

  /// The mip count the engine requests for a full chain.
  static int fullMipCount(int width, int height) {
    if (width < 1 || height < 1) return 1;
    final smallest = width < height ? width : height;
    final count = smallest.bitLength - 1;
    return count > 0 ? count : 1;
  }

  StorageMode get storageMode;
  PixelFormat get format;
  int get width;
  int get height;
  int get sampleCount;
  TextureType get textureType;
  bool get enableRenderTargetUsage;
  bool get enableShaderReadUsage;
  bool get enableShaderWriteUsage;
  int get mipLevelCount;
  bool get isValid;
  int get sliceCount;
  int get bytesPerTexel;
  int getMipLevelSizeInBytes(int mipLevel);
  int getBaseMipLevelSizeInBytes();
  void overwrite(ByteData sourceBytes, {int mipLevel = 0, int slice = 0});
  ui.Image asImage();
}

abstract base class UniformSlot {
  Shader get shader;
  String get uniformName;
  int? get sizeInBytes;
  int? getMemberOffsetInBytes(String memberName);
}

abstract base class Shader {
  ShaderStage get stage;
  UniformSlot getUniformSlot(String uniformName);
}

abstract base class RenderPipeline {
  Shader get vertexShader;
  Shader get fragmentShader;
}

/// A compute pipeline compiled from WGSL, which a [ComputePass] dispatches.
abstract base class ComputePipeline {}

/// Dispatches compute pipelines within one compute pass of a
/// [CommandBuffer]. Resources bind by their WGSL `@group` and `@binding`,
/// and the pass starts with none bound.
abstract base class ComputePass {
  /// Binds [pipeline] for the following dispatches.
  void bindPipeline(ComputePipeline pipeline);

  /// Binds the uniform or storage buffer range [view] at [group] and
  /// [binding].
  void bindBuffer(int group, int binding, BufferView view);

  /// Binds [texture] as the sampled texture at [group] and [binding], which
  /// the pipeline reads with `textureLoad`.
  void bindTexture(int group, int binding, Texture texture);

  /// Binds mip level [mipLevel] of [texture], created with shader write
  /// usage, as the storage texture at [group] and [binding].
  void bindStorageTexture(
    int group,
    int binding,
    Texture texture, {
    int mipLevel = 0,
  });

  /// Dispatches [x] by [y] by [z] workgroups of the bound pipeline.
  void dispatch(int x, [int y = 1, int z = 1]);

  /// Dispatches the workgroup counts held as three 32-bit unsigned integers
  /// at the start of [arguments].
  void dispatchIndirect(BufferView arguments);
}

abstract base class CommandBuffer {
  /// Starts a render pass into [renderTarget]. [label] names the pass in a
  /// GPU capture or trace where the backend has labels; WebGL2 drops it.
  RenderPass createRenderPass(RenderTarget renderTarget, {String? label});

  /// Starts a compute pass, ending the pass before it.
  ///
  /// Throws an [UnsupportedError] where `gpuHost.capabilities.compute` is
  /// false, as on WebGL2.
  ComputePass createComputePass();

  /// Copies tightly packed texel data from [source] into [destination].
  void copyBufferToTexture(BufferView source, TextureRegion destination);
  void submit({CompletionCallback? completionCallback});
}

/// States that [buffer] holds a frame's transient data; the web keeps no
/// items that could read it.
void markTransientBuffer(DeviceBuffer buffer) {}

/// Render items a backend keeps and draws inside a render pass; the web
/// makes none ([GpuContext.createItemSet]).
abstract final class ItemSet {
  RenderPass recorder(RenderTarget target);
  int? keep(
    RenderPass recorder, {
    int id = 0,
    required int passes,
    Float32List? bounds,
  });
  void remove(int id);
  void draw(
    RenderPass pass,
    int index, {
    required List<ByteData> viewBlocks,
    required Float32List clip,
  });
  void dispose();
}

abstract base class RenderPass {
  void bindPipeline(RenderPipeline pipeline);
  void bindVertexBuffer(BufferView bufferView, {int slot = 0});
  void bindIndexBuffer(BufferView bufferView, IndexType indexType);
  void bindUniform(UniformSlot slot, BufferView bufferView);
  void bindTexture(
    UniformSlot slot,
    Texture texture, {
    SamplerOptions? sampler,
  });
  void clearBindings();
  void setColorBlendEnable(bool enable, {int colorAttachmentIndex = 0});
  void setColorBlendEquation(
    ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  });
  void setDepthWriteEnable(bool enable);
  void setDepthCompareOperation(CompareFunction compareFunction);
  void setStencilReference(int referenceValue);
  void setStencilConfig(
    StencilConfig configuration, {
    StencilFace targetFace = StencilFace.both,
  });
  void setCullMode(CullMode cullMode);
  void setPolygonMode(PolygonMode polygonMode);
  void setPrimitiveType(PrimitiveType primitiveType);
  void setWindingOrder(WindingOrder windingOrder);
  void setScissor(Scissor scissor);
  void setViewport(Viewport viewport);
  void draw(int vertexCount, {int instanceCount = 1});
  void drawIndexed(int indexCount, {int instanceCount = 1});

  /// Draws indexed primitives with the five 32-bit draw arguments at the
  /// start of [arguments]: index count, instance count, first index, base
  /// vertex and first instance, which a compute pass may have written.
  ///
  /// Throws an [UnsupportedError] where `gpuHost.capabilities.indirectDraw`
  /// is false, as on WebGL2.
  void drawIndexedIndirect(BufferView arguments);
}

abstract base class ShaderLibrary {
  /// Synchronous loading is unsupported on web; use [loadShaderLibraryAsync].
  static ShaderLibrary? fromAsset(String assetName) => throw UnimplementedError(
    'ShaderLibrary.fromAsset is synchronous and unsupported on web. '
    'Use loadShaderLibraryAsync(assetName) instead.',
  );

  /// Mirrors flutter_gpu's in-place hot reload. Fires the asynchronous
  /// recompile and returns; await [reinitializeShaderLibraryAsync] when
  /// ordering matters.
  static void reinitialize(String assetKey) {
    unawaited(reinitializeShaderLibraryAsync(assetKey));
  }

  Shader? operator [](String shaderName);
}

/// An offscreen drawing surface whose frames reach Flutter as images.
abstract base class Surface {
  Surface.base();

  factory Surface({required int width, required int height}) =>
      _backend.createSurface(width: width, height: height);

  int get width;
  int get height;
  abstract bool isLost;
  abstract void Function()? onContextLost;
  abstract void Function()? onContextRestored;
  void clearToColor(double r, double g, double b, double a);
  FutureOr<ui.Image> snapshot({bool transferOwnership = false});
  bool forceContextLoss();
  bool forceContextRestore();
  void dispose();
}

/// The active backend's integration with the Flutter host.
abstract base class GpuHost {
  const GpuHost();

  GpuCapabilities get capabilities;

  /// Hands [texture] to Flutter as a `ui.Image`.
  ui.Image textureToImage(Texture texture);

  /// Wraps a Flutter-rendered [image]'s backing texture, or null when this
  /// backend cannot adopt it.
  Texture? imageToTexture(ui.Image image);

  /// Presents [texture] through the backend's own offscreen canvas path.
  Future<ui.Image> present(Texture texture, {bool transferOwnership = false});

  /// Completes once every render pipeline asked for so far has compiled. A
  /// web backend compiles where a pipeline is first drawn, so this completes
  /// at once.
  Future<void> pipelinesReady() => Future.value();

  /// Runs [record] and returns 0: a web backend records every draw, compiling
  /// its pipeline where it is first drawn.
  int skipCompilingDraws(void Function() record) {
    record();
    return 0;
  }

  /// Frees [texture]'s GPU memory now instead of when it is collected.
  ///
  /// [texture] must not be used again. Work already submitted is unaffected.
  void releaseTexture(Texture texture);

  /// Frees [buffer]'s GPU memory now instead of when it is collected.
  ///
  /// [buffer] must not be used again. Work already submitted is unaffected.
  void releaseBuffer(DeviceBuffer buffer);
}

Future<ShaderLibrary?> loadShaderLibraryAsync(String assetName) async =>
    (await _ready()).loadShaderLibraryAsync(assetName);

/// Loads a shader bundle from [bytes]. The web has one context, so [context]
/// is [gpuContext] wherever it is given.
Future<ShaderLibrary?> loadShaderLibraryFromBytesAsync(
  ByteData bytes, {
  GpuContext? context,
}) async => (await _ready()).loadShaderLibraryFromBytesAsync(bytes);

Future<void> reinitializeShaderLibraryAsync(String assetKey) async =>
    (await _ready()).reinitializeShaderLibraryAsync(assetKey);

Future<String?> reinitializeShaderLibraryFromBytesAsync(
  ShaderLibrary library,
  ByteData bytes,
) async =>
    (await _ready()).reinitializeShaderLibraryFromBytesAsync(library, bytes);

ShaderLibrary compileShaderLibraryInline(
  Map<String, ({String source, ShaderStage stage})> shaders,
) => _backend.compileShaderLibraryInline(shaders);

Future<Texture?> createTextureFromEncodedImage(
  Uint8List encoded, {
  MipContent content = MipContent.color,
  bool mipmaps = true,
  int? maxMipLevels,
  int? maxSize,
}) async => (await _ready()).createTextureFromEncodedImage(
  encoded,
  content: content,
  mipmaps: mipmaps,
  maxMipLevels: maxMipLevels,
  maxSize: maxSize,
);

Future<ui.Image> presentTextureAsImage(
  Texture texture, {
  bool transferOwnership = false,
}) => _backend.presentTextureAsImage(
  texture,
  transferOwnership: transferOwnership,
);

PixelFormat get reversedDepthStencilFormat =>
    _backend.reversedDepthStencilFormat;

({DeviceBuffer vertex, DeviceBuffer index, int indexBaseOffset})
createGeometryBuffers(int vertexBytes, int indexBytes) =>
    _backend.createGeometryBuffers(vertexBytes, indexBytes);

bool writeGeometryData(
  DeviceBuffer buffer,
  TypedData source, {
  required int destinationOffsetInBytes,
}) => _backend.writeGeometryData(
  buffer,
  source,
  destinationOffsetInBytes: destinationOffsetInBytes,
);
