import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_gpu/gpu.dart';

import 'command_stream.dart';
import 'errors.dart';
import 'ffi/bindings.dart';
import 'packed_writer.dart';

/// The graphics API a [WgpuDevice] runs on.
enum WgpuBackend { noop, vulkan, metal, dx12, gl, webgpu }

/// Optional device capabilities, from `fsw_device_features`.
class WgpuFeatures {
  /// Wraps the native feature bit set.
  const WgpuFeatures(this.bits);

  /// The raw bit set.
  final int bits;

  bool _has(int bit) => bits & (1 << bit) != 0;

  /// Compute shaders are available.
  bool get compute => _has(0);

  /// Indirect draws are available.
  bool get indirectDraw => _has(1);

  /// Arrays of texture bindings are available.
  bool get textureBindingArrays => _has(2);

  /// Timestamp queries are available.
  bool get timestampQueries => _has(3);

  /// BC compressed textures are available.
  bool get bcCompression => _has(4);

  /// ETC2 compressed textures are available.
  bool get etc2Compression => _has(5);

  /// ASTC LDR compressed textures are available.
  bool get astcCompression => _has(6);

  /// ASTC HDR compressed textures are available.
  bool get astcHdrCompression => _has(7);

  /// The d32FloatS8UInt format is available.
  bool get depth32FloatStencil8 => _has(8);

  /// r32Float and r32g32b32a32Float can be filtered.
  bool get float32Filterable => _has(9);

  /// Indirect draws may use a non-zero first instance.
  bool get indirectFirstInstance => _has(10);
}

/// Device limits, in the order `fsw_device_limits` writes them.
class WgpuLimits {
  WgpuLimits._(this._values);

  final List<int> _values;

  /// Number of limits the native side reports.
  static const count = 18;

  /// Largest 2D texture width or height.
  int get maxTextureDimension2D => _values[0];

  /// Largest number of texture array layers.
  int get maxTextureArrayLayers => _values[1];

  /// Largest number of bind groups in a pipeline.
  int get maxBindGroups => _values[2];

  /// Largest number of bindings in one bind group.
  int get maxBindingsPerBindGroup => _values[3];

  /// Largest uniform buffer binding size in bytes.
  int get maxUniformBufferBindingSize => _values[4];

  /// Largest storage buffer binding size in bytes.
  int get maxStorageBufferBindingSize => _values[5];

  /// Largest number of vertex buffers in a pipeline.
  int get maxVertexBuffers => _values[6];

  /// Largest number of vertex attributes in a pipeline.
  int get maxVertexAttributes => _values[7];

  /// Largest vertex buffer stride in bytes.
  int get maxVertexBufferArrayStride => _values[8];

  /// Largest buffer size in bytes.
  int get maxBufferSize => _values[9];

  /// Required alignment of uniform binding offsets.
  int get minUniformBufferOffsetAlignment => _values[10];

  /// Required alignment of storage binding offsets.
  int get minStorageBufferOffsetAlignment => _values[11];

  /// Largest number of color attachments in a pass.
  int get maxColorAttachments => _values[12];

  /// Largest number of samplers per shader stage.
  int get maxSamplersPerShaderStage => _values[13];

  /// Largest number of sampled textures per shader stage.
  int get maxSampledTexturesPerShaderStage => _values[14];

  /// Largest compute workgroup width.
  int get maxComputeWorkgroupSizeX => _values[15];

  /// Largest compute invocations per workgroup.
  int get maxComputeInvocationsPerWorkgroup => _values[16];

  /// Largest 3D texture dimension.
  int get maxTextureDimension3D => _values[17];
}

/// A native object addressed by a `u64` handle.
abstract class WgpuObject {
  WgpuObject._(this.handle);

  /// The native handle; never 0 while the object is alive.
  final int handle;

  bool _destroyed = false;

  /// Destroys the native object. Calling it twice is a no-op.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    check(fswDestroy(handle));
  }
}

/// Buffer usages for [WgpuDevice.createBuffer]; combine with `|`.
abstract final class WgpuBufferUsage {
  /// Vertex data.
  static const vertex = 1;

  /// Index data.
  static const index = 2;

  /// Uniform bindings.
  static const uniform = 4;

  /// Storage bindings.
  static const storage = 8;

  /// Indirect draw arguments.
  static const indirect = 16;
}

/// A GPU buffer.
class WgpuBuffer extends WgpuObject {
  WgpuBuffer._(super.handle, this.sizeInBytes) : super._();

  /// The requested size in bytes.
  final int sizeInBytes;

  /// Writes [data] at [offsetInBytes]; ordered before the next submit.
  void write(Uint8List data, {int offsetInBytes = 0}) {
    using((arena) {
      final ptr = arena<Uint8>(data.length);
      ptr.asTypedList(data.length).setAll(0, data);
      check(fswBufferWrite(handle, offsetInBytes, ptr, data.length));
    });
  }
}

/// A GPU texture.
class WgpuTexture extends WgpuObject {
  WgpuTexture._(
    super.handle, {
    required this.type,
    required this.format,
    required this.width,
    required this.height,
    required this.mipLevelCount,
    required this.sampleCount,
  }) : super._();

  /// The texture type.
  final TextureType type;

  /// The texel format.
  final PixelFormat format;

  /// Width of mip level 0.
  final int width;

  /// Height of mip level 0.
  final int height;

  /// Number of mip levels.
  final int mipLevelCount;

  /// Samples per texel.
  final int sampleCount;

  /// Writes texel data into a region of one mip level and slice;
  /// [bytesPerRow] 0 means tightly packed.
  void write(
    Uint8List data, {
    int mipLevel = 0,
    int slice = 0,
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    int bytesPerRow = 0,
  }) {
    using((arena) {
      final ptr = arena<Uint8>(data.length);
      ptr.asTypedList(data.length).setAll(0, data);
      check(
        fswTextureWrite(
          handle,
          mipLevel,
          slice,
          x,
          y,
          width ?? (this.width >> mipLevel).clamp(1, this.width),
          height ?? (this.height >> mipLevel).clamp(1, this.height),
          ptr,
          data.length,
          bytesPerRow,
        ),
      );
    });
  }

  /// Reads a region back after all submitted work completes, tightly
  /// packed. Blocks until the GPU is done.
  Uint8List read({
    int mipLevel = 0,
    int slice = 0,
    int x = 0,
    int y = 0,
    required int width,
    required int height,
    required int bytesPerPixel,
  }) {
    final len = width * height * bytesPerPixel;
    return using((arena) {
      final ptr = arena<Uint8>(len);
      check(
        fswTextureRead(handle, mipLevel, slice, x, y, width, height, ptr, len),
      );
      return Uint8List.fromList(ptr.asTypedList(len));
    });
  }
}

/// A texture sampler.
class WgpuSampler extends WgpuObject {
  WgpuSampler._(super.handle) : super._();
}

/// A compiled shader module; holds every entry point of its source.
class WgpuShader extends WgpuObject {
  WgpuShader._(super.handle) : super._();
}

/// One vertex attribute read from a vertex buffer.
class WgpuVertexAttribute {
  /// Creates an attribute at shader [location].
  const WgpuVertexAttribute({
    required this.location,
    required this.format,
    this.offsetInBytes = 0,
  });

  /// The shader input location.
  final int location;

  /// The attribute's data format.
  final VertexFormat format;

  /// Offset within one vertex.
  final int offsetInBytes;
}

/// The layout of one bound vertex buffer.
class WgpuVertexBufferLayout {
  /// Creates a layout with [strideInBytes] between elements.
  const WgpuVertexBufferLayout({
    required this.strideInBytes,
    required this.attributes,
    this.stepMode = VertexStepMode.vertex,
  });

  /// Bytes between consecutive elements.
  final int strideInBytes;

  /// The attributes read from each element.
  final List<WgpuVertexAttribute> attributes;

  /// Whether elements advance per vertex or per instance.
  final VertexStepMode stepMode;
}

/// A pipeline color target.
class WgpuColorTarget {
  /// Creates a target of [format], blending with [blend] when set.
  const WgpuColorTarget({
    required this.format,
    this.blend,
    this.writeMask = 0xF,
  });

  /// The attachment format.
  final PixelFormat format;

  /// The blend equation, or null for no blending.
  final ColorBlendEquation? blend;

  /// Channel write mask: r 1, g 2, b 4, a 8.
  final int writeMask;
}

/// A pipeline depth/stencil state.
class WgpuDepthStencilState {
  /// Creates a state for a [format] attachment.
  WgpuDepthStencilState({
    required this.format,
    this.depthWriteEnabled = true,
    this.depthCompare = CompareFunction.less,
    StencilConfig? stencilFront,
    StencilConfig? stencilBack,
  }) : stencilFront = stencilFront ?? StencilConfig(),
       stencilBack = stencilBack ?? StencilConfig();

  /// The attachment format.
  final PixelFormat format;

  /// Whether depth writes are on.
  final bool depthWriteEnabled;

  /// The depth test.
  final CompareFunction depthCompare;

  /// Stencil state for front faces; its masks apply to both faces.
  final StencilConfig stencilFront;

  /// Stencil state for back faces.
  final StencilConfig stencilBack;
}

/// Everything a render pipeline bakes in.
class WgpuPipelineDescriptor {
  /// Creates a descriptor; an empty entry point name picks the only one.
  const WgpuPipelineDescriptor({
    required this.vertexShader,
    this.vertexEntryPoint = '',
    this.fragmentShader,
    this.fragmentEntryPoint = '',
    this.vertexBuffers = const [],
    this.colorTargets = const [],
    this.depthStencil,
    this.primitiveType = PrimitiveType.triangle,
    this.cullMode = CullMode.none,
    this.windingOrder = WindingOrder.counterClockwise,
    this.polygonMode = PolygonMode.fill,
    this.sampleCount = 1,
    this.bindingOverrides = const [],
  });

  /// The vertex stage module.
  final WgpuShader vertexShader;

  /// The vertex entry point.
  final String vertexEntryPoint;

  /// The fragment stage module, or null for a depth-only pipeline.
  final WgpuShader? fragmentShader;

  /// The fragment entry point.
  final String fragmentEntryPoint;

  /// Vertex buffer layouts, by slot.
  final List<WgpuVertexBufferLayout> vertexBuffers;

  /// Color targets, by attachment index.
  final List<WgpuColorTarget> colorTargets;

  /// Depth/stencil state, or null without a depth attachment.
  final WgpuDepthStencilState? depthStencil;

  /// The primitive topology.
  final PrimitiveType primitiveType;

  /// Which faces are culled.
  final CullMode cullMode;

  /// Which winding is front-facing.
  final WindingOrder windingOrder;

  /// Fill or wireframe.
  final PolygonMode polygonMode;

  /// MSAA sample count of the attachments.
  final int sampleCount;

  /// Replaces the layout type reflection gives a binding.
  final List<WgpuBindingOverride> bindingOverrides;

  void _write(PackedWriter w) {
    w.u64(vertexShader.handle);
    w.string(vertexEntryPoint);
    w.u64(fragmentShader?.handle ?? 0);
    w.string(fragmentEntryPoint);
    w.u32(primitiveType.index);
    w.u32(cullMode.index);
    w.u32(windingOrder.index);
    w.u32(polygonMode.index);
    w.u32(sampleCount);
    w.u32(vertexBuffers.length);
    for (final buffer in vertexBuffers) {
      w.u32(buffer.strideInBytes);
      w.u32(buffer.stepMode.index);
      w.u32(buffer.attributes.length);
      for (final a in buffer.attributes) {
        w.u32(a.format.index);
        w.u32(a.offsetInBytes);
        w.u32(a.location);
      }
    }
    w.u32(colorTargets.length);
    for (final target in colorTargets) {
      final blend = target.blend ?? ColorBlendEquation();
      w.u32(target.format.index);
      w.boolean(target.blend != null);
      w.u32(blend.colorBlendOperation.index);
      w.u32(blend.sourceColorBlendFactor.index);
      w.u32(blend.destinationColorBlendFactor.index);
      w.u32(blend.alphaBlendOperation.index);
      w.u32(blend.sourceAlphaBlendFactor.index);
      w.u32(blend.destinationAlphaBlendFactor.index);
      w.u32(target.writeMask);
    }
    final ds = depthStencil;
    w.boolean(ds != null);
    if (ds != null) {
      w.u32(ds.format.index);
      w.boolean(ds.depthWriteEnabled);
      w.u32(ds.depthCompare.index);
      for (final face in [ds.stencilFront, ds.stencilBack]) {
        w.u32(face.compareFunction.index);
        w.u32(face.stencilFailureOperation.index);
        w.u32(face.depthFailureOperation.index);
        w.u32(face.depthStencilPassOperation.index);
      }
      w.u32(ds.stencilFront.readMask);
      w.u32(ds.stencilFront.writeMask);
    }
    w.u32(bindingOverrides.length);
    for (final o in bindingOverrides) {
      w.u32(o.group);
      w.u32(o.binding);
      w.u32(o.type.code);
    }
  }
}

/// The layout type of a texture or sampler binding, which reflection alone
/// cannot tell: whether a float texture is filterable depends on the texture
/// bound, and a sampler's type on the texture it samples.
enum WgpuBindingType {
  /// A filterable float texture.
  floatTexture(0),

  /// A float texture sampled without filtering, such as a 32-bit float one.
  unfilterableFloatTexture(1),

  /// A depth texture.
  depthTexture(2),

  /// A signed integer texture.
  sintTexture(3),

  /// An unsigned integer texture.
  uintTexture(4),

  /// A sampler that may filter.
  filteringSampler(16),

  /// A sampler that does not filter.
  nonFilteringSampler(17),

  /// A comparison sampler.
  comparisonSampler(18);

  const WgpuBindingType(this.code);

  /// The code the native pipeline descriptor carries.
  final int code;
}

/// A binding whose layout type replaces the reflected one.
typedef WgpuBindingOverride = ({int group, int binding, WgpuBindingType type});

/// A render pipeline, compiled synchronously or on a worker thread.
class WgpuPipeline extends WgpuObject {
  WgpuPipeline._(super.handle) : super._();

  /// True once compiled; throws the compile error if compiling failed.
  bool get isReady {
    final status = fswPipelineStatus(handle);
    if (codeOf(status) == WgpuErrorCode.notReady) return false;
    check(status);
    return true;
  }

  /// Blocks until compiling finishes; throws the compile error on failure.
  void waitUntilReady() => check(fswPipelineWait(handle));
}

/// A headless wgpu device: creates resources and submits command streams.
class WgpuDevice extends WgpuObject {
  WgpuDevice._(super.handle) : super._();

  /// Creates a device on the adapter wgpu prefers. [backends] is a wgpu
  /// `Backends` bit set (Vulkan 1, GL 2, Metal 4, DX12 8); 0 allows all.
  factory WgpuDevice.createHeadless({int backends = 0}) =>
      WgpuDevice._(_out((out) => fswDeviceCreate(backends, out)));

  static final Pointer<Uint64> _outHandle = malloc<Uint64>();

  static int _out(int Function(Pointer<Uint64> out) call) {
    check(call(_outHandle));
    return _outHandle.value;
  }

  /// The graphics API in use.
  WgpuBackend get backend => using((arena) {
    final out = arena<Uint32>();
    check(fswDeviceBackend(handle, out));
    return WgpuBackend.values[out.value];
  });

  /// The adapter's name.
  String get adapterName => using((arena) {
    final buf = arena<Uint8>(256);
    final len = arena<Size>();
    check(fswDeviceAdapterName(handle, buf, 256, len));
    return utf8.decode(buf.asTypedList(len.value.clamp(0, 256)));
  });

  /// The optional capabilities the device enabled.
  WgpuFeatures get features =>
      WgpuFeatures(_out((out) => fswDeviceFeatures(handle, out)));

  /// The device limits.
  WgpuLimits get limits => using((arena) {
    final out = arena<Uint64>(WgpuLimits.count);
    check(fswDeviceLimits(handle, out, WgpuLimits.count));
    return WgpuLimits._(List.of(out.asTypedList(WgpuLimits.count)));
  });

  /// Creates a buffer; [usage] combines [WgpuBufferUsage] bits.
  WgpuBuffer createBuffer(int sizeInBytes, int usage) => WgpuBuffer._(
    _out((out) => fswBufferCreate(handle, sizeInBytes, usage, out)),
    sizeInBytes,
  );

  /// Creates a buffer holding [data].
  WgpuBuffer createBufferWithData(Uint8List data, int usage) {
    final buffer = createBuffer(data.length, usage);
    buffer.write(data);
    return buffer;
  }

  /// Creates a texture.
  WgpuTexture createTexture(
    int width,
    int height, {
    PixelFormat format = PixelFormat.r8g8b8a8UNormInt,
    TextureType? type,
    int sampleCount = 1,
    int mipLevelCount = 1,
    bool enableRenderTargetUsage = true,
    bool enableShaderReadUsage = true,
    bool enableShaderWriteUsage = false,
  }) {
    final textureType =
        type ??
        (sampleCount > 1
            ? TextureType.texture2DMultisample
            : TextureType.texture2D);
    final usage =
        (enableShaderReadUsage ? 1 : 0) |
        (enableShaderWriteUsage ? 2 : 0) |
        (enableRenderTargetUsage ? 4 : 0);
    return WgpuTexture._(
      _out(
        (out) => fswTextureCreate(
          handle,
          textureType.index,
          format.index,
          width,
          height,
          mipLevelCount,
          sampleCount,
          usage,
          out,
        ),
      ),
      type: textureType,
      format: format,
      width: width,
      height: height,
      mipLevelCount: mipLevelCount,
      sampleCount: sampleCount,
    );
  }

  /// Creates a sampler; [compare] makes it a comparison sampler.
  WgpuSampler createSampler({
    MinMagFilter minFilter = MinMagFilter.nearest,
    MinMagFilter magFilter = MinMagFilter.nearest,
    MipFilter mipFilter = MipFilter.nearest,
    SamplerAddressMode addressU = SamplerAddressMode.clampToEdge,
    SamplerAddressMode addressV = SamplerAddressMode.clampToEdge,
    SamplerAddressMode addressW = SamplerAddressMode.clampToEdge,
    double lodMin = 0,
    double lodMax = 32,
    CompareFunction? compare,
    int maxAnisotropy = 1,
  }) => WgpuSampler._(
    _out(
      (out) => fswSamplerCreate(
        handle,
        minFilter.index,
        magFilter.index,
        mipFilter.index,
        addressU.index,
        addressV.index,
        addressW.index,
        lodMin,
        lodMax,
        compare == null ? 0 : compare.index + 1,
        maxAnisotropy,
        out,
      ),
    ),
  );

  /// Compiles a WGSL module.
  WgpuShader createShaderFromWgsl(String source) {
    final bytes = utf8.encode(source);
    return _withBytes(
      bytes,
      (ptr, len) => WgpuShader._(
        _out((out) => fswShaderCreateWgsl(handle, ptr, len, out)),
      ),
    );
  }

  /// Compiles a SPIR-V module.
  WgpuShader createShaderFromSpirv(Uint8List bytes) => _withBytes(
    bytes,
    (ptr, len) => WgpuShader._(
      _out((out) => fswShaderCreateSpirv(handle, ptr, len, out)),
    ),
  );

  static T _withBytes<T>(
    Uint8List bytes,
    T Function(Pointer<Uint8>, int) body,
  ) => using((arena) {
    final ptr = arena<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return body(ptr, bytes.length);
  });

  WgpuPipeline _pipeline(
    WgpuPipelineDescriptor descriptor,
    int Function(int, Pointer<Uint8>, int, Pointer<Uint64>) create,
  ) {
    final writer = PackedWriter(512);
    try {
      descriptor._write(writer);
      return WgpuPipeline._(
        _out((out) => create(handle, writer.pointer, writer.length, out)),
      );
    } finally {
      writer.dispose();
    }
  }

  /// Creates a render pipeline and compiles it before returning.
  WgpuPipeline createPipeline(WgpuPipelineDescriptor descriptor) =>
      _pipeline(descriptor, fswPipelineCreate);

  /// Creates a render pipeline compiled on a worker thread; poll
  /// [WgpuPipeline.isReady] before binding it.
  WgpuPipeline createPipelineAsync(WgpuPipelineDescriptor descriptor) =>
      _pipeline(descriptor, fswPipelineCreateAsync);

  /// Decodes and submits the commands in [commands] with one native call.
  void submit(WgpuCommandStream commands) =>
      check(fswSubmit(handle, commands.pointer, commands.length));

  /// Blocks until all submitted work completes.
  void waitIdle() => check(fswDeviceWaitIdle(handle));
}
