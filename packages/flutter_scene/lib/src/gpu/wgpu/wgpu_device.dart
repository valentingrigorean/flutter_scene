/// The wgpu device the native GPU shim drives when `selectGpuBackend` picks
/// [GpuBackendKind.wgpu].
///
/// Every resource is a handle on the `flutter_scene_wgpu` native library. The
/// shim's public classes wrap these, so the members here take and return wgpu
/// handles and flutter_gpu's value types, never the shim's own classes.
///
/// wgpu bakes into a pipeline what flutter_gpu sets per draw (blend, depth,
/// stencil, cull, winding, topology), plus the attachment formats and each
/// texture's sample type. So a [WgpuRenderPipeline] is a shader pair and a
/// vertex layout, and its native pipelines are variants built the first time
/// a draw needs each combination. Shaders are the Vulkan SPIR-V entries of
/// the shader bundle, bound by the bundle's reflection.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpu/gpu.dart'
    show
        CompareFunction,
        ColorBlendEquation,
        CompletionCallback,
        CullMode,
        GpuPresentStatus,
        IndexType,
        LoadAction,
        MinMagFilter,
        MipFilter,
        PixelFormat,
        PixelFormatProperties,
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
        VertexFormat,
        VertexLayout,
        Viewport,
        WindingOrder;
import 'package:flutter_scene_wgpu/flutter_scene_wgpu.dart' as fsw;
import 'package:vector_math/vector_math.dart' as vm;

import '../shared/gpu_capabilities.dart';
import '../web/shader_bundle_generated.dart' as fb;

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

/// Where a split sampler binds relative to its texture; the native SPIR-V
/// loader moves it there.
const int _samplerBindingOffset = 128;

bool _hasDepth(PixelFormat f) =>
    f == PixelFormat.d24UnormS8Uint || f == PixelFormat.d32FloatS8UInt;

bool _hasStencil(PixelFormat f) =>
    f == PixelFormat.s8UInt ||
    f == PixelFormat.d24UnormS8Uint ||
    f == PixelFormat.d32FloatS8UInt;

bool _isFloat32(PixelFormat f) =>
    f == PixelFormat.r32Float || f == PixelFormat.r32g32b32a32Float;

/// The wgpu device and its queue.
final class WgpuContext {
  WgpuContext._(this.device)
    : limits = device.limits,
      features = device.features;

  /// Opens the wgpu device.
  factory WgpuContext.open() => WgpuContext._(fsw.WgpuDevice.createHeadless());

  /// The native device.
  final fsw.WgpuDevice device;

  /// The device's limits.
  final fsw.WgpuLimits limits;

  /// The device's optional features.
  final fsw.WgpuFeatures features;

  final Map<int, fsw.WgpuSampler> _samplers = {};

  /// What this device can do.
  late final GpuCapabilities capabilities = GpuCapabilities(
    textureToImage: true,
    imageToTexture: false,
    presentAsImage: false,
    compute: false,
    indirectDraw: features.indirectDraw,
    textureArrays: features.textureBindingArrays,
    timestampQueries: features.timestampQueries,
    aheadOfTimePipelines: true,
  );

  /// The color format the device renders and reads back without a swizzle.
  PixelFormat get defaultColorFormat => PixelFormat.r8g8b8a8UNormInt;

  /// The stencil-only format.
  PixelFormat get defaultStencilFormat => PixelFormat.s8UInt;

  /// The combined depth-stencil format the device prefers.
  PixelFormat get defaultDepthStencilFormat => features.depth32FloatStencil8
      ? PixelFormat.d32FloatS8UInt
      : PixelFormat.d24UnormS8Uint;

  /// The alignment every uniform buffer binding's offset must have.
  int get minimumUniformByteAlignment => limits.minUniformBufferOffsetAlignment;

  /// Offscreen targets can be multisampled.
  bool get doesSupportOffscreenMSAA => true;

  /// A pass can render into any mip level.
  bool get doesSupportFramebufferRenderMipmap => true;

  /// Each mip level can be uploaded separately.
  bool get doesSupportManuallyMippedTextures => true;

  /// The largest anisotropy a sampler takes.
  int get maxSamplerAnisotropy => 16;

  /// Whether the device samples textures of [family].
  bool supportsTextureCompression(TextureCompressionFamily family) =>
      switch (family) {
        TextureCompressionFamily.bc => features.bcCompression,
        TextureCompressionFamily.etc2 => features.etc2Compression,
        TextureCompressionFamily.astc => features.astcCompression,
        TextureCompressionFamily.astcHdr => features.astcHdrCompression,
      };

  /// Whether the device allocates a texture of [format] with this usage.
  bool supportsTextureFormat(
    PixelFormat format, {
    required bool renderTarget,
    required bool shaderRead,
    required bool shaderWrite,
  }) {
    if (format == PixelFormat.unknown) return false;
    if (format.isCompressed) {
      return !renderTarget && !shaderWrite && _compressedSupported(format);
    }
    if (shaderWrite) return false;
    if (format == PixelFormat.d32FloatS8UInt) {
      return features.depth32FloatStencil8;
    }
    return true;
  }

  bool _compressedSupported(PixelFormat format) {
    final name = format.name;
    if (name.startsWith('bc')) return features.bcCompression;
    if (name.startsWith('etc2') || name.startsWith('eac')) {
      return features.etc2Compression;
    }
    if (name.startsWith('astc')) return features.astcCompression;
    return false;
  }

  /// Allocates [size] bytes of GPU memory usable as any kind of buffer.
  WgpuDeviceBuffer createDeviceBuffer(StorageMode storageMode, int size) =>
      WgpuDeviceBuffer._(this, storageMode, size);

  /// Allocates a buffer holding a copy of [data].
  WgpuDeviceBuffer createDeviceBufferWithCopy(ByteData data) {
    final buffer = WgpuDeviceBuffer._(
      this,
      StorageMode.hostVisible,
      data.lengthInBytes,
    );
    buffer.overwrite(data, destinationOffsetInBytes: 0);
    return buffer;
  }

  /// Creates a per-frame bump allocator.
  WgpuHostBuffer createHostBuffer({required int blockLengthInBytes}) =>
      WgpuHostBuffer._(this, blockLengthInBytes);

  /// Allocates a texture.
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
  }) => WgpuTexture._(
    device.createTexture(
      width,
      height,
      format: format,
      type: textureType,
      sampleCount: sampleCount,
      mipLevelCount: mipLevelCount,
      enableRenderTargetUsage: enableRenderTargetUsage,
      enableShaderReadUsage: enableShaderReadUsage,
      // Storage textures have no counterpart in the shim's draw path yet,
      // and most render formats cannot be storage-bound.
      enableShaderWriteUsage: false,
    ),
    storageMode: storageMode,
    enableRenderTargetUsage: enableRenderTargetUsage,
    enableShaderReadUsage: enableShaderReadUsage,
    enableShaderWriteUsage: enableShaderWriteUsage,
  );

  /// Uploads a Flutter-rendered [image] into a new texture. wgpu cannot read
  /// a `ui.Image` synchronously, so this throws; `gpuHost.imageToTexture`
  /// turns that into null.
  WgpuTexture textureFromImage(ui.Image image) => throw Exception(
    'The wgpu backend cannot read a ui.Image synchronously; upload its '
    'pixels with Texture.overwrite instead.',
  );

  /// Creates a command buffer.
  WgpuCommandBuffer createCommandBuffer() => WgpuCommandBuffer._(this);

  /// Creates a pipeline from a vertex and a fragment shader.
  WgpuRenderPipeline createRenderPipeline(
    WgpuShader vertexShader,
    WgpuShader fragmentShader, {
    VertexLayout? vertexLayout,
  }) => WgpuRenderPipeline._(this, vertexShader, fragmentShader, vertexLayout);

  /// Loads the shader bundle asset [assetName], or null when it is missing.
  Future<WgpuShaderLibrary?> loadShaderLibraryFromAsset(
    String assetName,
  ) async {
    final ByteData bytes;
    try {
      bytes = await rootBundle.load(assetName);
    } on Exception {
      return null;
    }
    return loadShaderLibraryFromBytes(bytes);
  }

  /// Reads a shader bundle from [bytes], or null when it is not one.
  WgpuShaderLibrary? loadShaderLibraryFromBytes(ByteData bytes) {
    final entries = _readBundle(bytes);
    return entries == null ? null : WgpuShaderLibrary._(this, entries);
  }

  /// Creates a surface whose frames read back into `ui.Image`s.
  WgpuImageSurface createImageSurface(
    int width,
    int height, {
    required PixelFormat format,
  }) => WgpuImageSurface._(this, width, height, format);

  fsw.WgpuSampler _sampler(SamplerOptions? options, {required bool filters}) {
    final o = options ?? _defaultSampler;
    final linear = filters;
    final key =
        (linear && o.minFilter == MinMagFilter.linear ? 1 : 0) |
        (linear && o.magFilter == MinMagFilter.linear ? 2 : 0) |
        (linear && o.mipFilter == MipFilter.linear ? 4 : 0) |
        o.widthAddressMode.index << 3 |
        o.heightAddressMode.index << 6 |
        (linear ? o.maxAnisotropy.clamp(1, 16) : 1) << 9;
    return _samplers[key] ??= device.createSampler(
      minFilter: key & 1 != 0 ? MinMagFilter.linear : MinMagFilter.nearest,
      magFilter: key & 2 != 0 ? MinMagFilter.linear : MinMagFilter.nearest,
      mipFilter: key & 4 != 0 ? MipFilter.linear : MipFilter.nearest,
      addressU: o.widthAddressMode,
      addressV: o.heightAddressMode,
      // wgpu needs every filter linear for anisotropy above 1.
      maxAnisotropy: key & 7 == 7 ? (key >> 9) : 1,
    );
  }

  static final SamplerOptions _defaultSampler = SamplerOptions();
}

/// The shaders of a shader bundle, by name.
Map<String, fb.Shader>? _readBundle(ByteData bytes) {
  try {
    final bundle = fb.ShaderBundle(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    return {
      for (final shader in bundle.shaders ?? const <fb.Shader>[])
        if (shader.name case final name?) name: shader,
    };
  } on Object {
    return null;
  }
}

/// A region of GPU memory, with a host copy so writes of any alignment
/// reach the 4-byte granular native buffer intact.
final class WgpuDeviceBuffer {
  WgpuDeviceBuffer._(WgpuContext context, this.storageMode, this.sizeInBytes)
    : _buffer = context.device.createBuffer(
        sizeInBytes < 4 ? 4 : sizeInBytes,
        fsw.WgpuBufferUsage.vertex |
            fsw.WgpuBufferUsage.index |
            fsw.WgpuBufferUsage.uniform |
            fsw.WgpuBufferUsage.storage |
            fsw.WgpuBufferUsage.indirect,
      ),
      _shadow = Uint8List((sizeInBytes + 3) & ~3);

  final fsw.WgpuBuffer _buffer;
  final Uint8List _shadow;

  /// How the memory is reachable from the host.
  final StorageMode storageMode;

  /// The buffer's size.
  final int sizeInBytes;

  /// The buffer stays valid for its lifetime.
  bool get isValid => true;

  /// Copies [sourceBytes] into the buffer from [destinationOffsetInBytes].
  /// Returns false when the range does not fit.
  bool overwrite(ByteData sourceBytes, {required int destinationOffsetInBytes}) {
    final length = sourceBytes.lengthInBytes;
    if (destinationOffsetInBytes < 0 ||
        destinationOffsetInBytes + length > sizeInBytes) {
      return false;
    }
    if (length == 0) return true;
    _shadow.setRange(
      destinationOffsetInBytes,
      destinationOffsetInBytes + length,
      sourceBytes.buffer.asUint8List(sourceBytes.offsetInBytes, length),
    );
    final start = destinationOffsetInBytes & ~3;
    final end = (destinationOffsetInBytes + length + 3) & ~3;
    _buffer.write(
      Uint8List.sublistView(_shadow, start, end),
      offsetInBytes: start,
    );
    return true;
  }

  /// Host writes are queued on the device, so there is nothing to flush.
  void flush({required int offsetInBytes, required int lengthInBytes}) {}
}

/// A bump allocator over buffer blocks, one list of blocks per frame.
final class WgpuHostBuffer {
  WgpuHostBuffer._(this._context, this._blockLength);

  final WgpuContext _context;
  final int _blockLength;
  final List<List<WgpuDeviceBuffer>> _frames = [for (var i = 0; i < 4; i++) []];
  int _frame = 0;
  int _block = 0;
  int _offset = 0;

  /// How many frames of blocks the allocator rotates through.
  int get frameCount => _frames.length;

  /// Copies [bytes] into the current frame's blocks and returns its range,
  /// aligned for a uniform binding.
  WgpuBufferRange emplace(ByteData bytes) {
    final length = bytes.lengthInBytes;
    final alignment = _context.minimumUniformByteAlignment;
    if (length > _blockLength) {
      final buffer = _context.createDeviceBuffer(StorageMode.hostVisible, length)
        ..overwrite(bytes, destinationOffsetInBytes: 0);
      return (buffer: buffer, offsetInBytes: 0, lengthInBytes: length);
    }
    final blocks = _frames[_frame];
    var offset = (_offset + alignment - 1) ~/ alignment * alignment;
    if (_block < blocks.length && offset + length > _blockLength) {
      _block++;
      offset = 0;
    }
    if (_block >= blocks.length) {
      blocks.add(
        _context.createDeviceBuffer(StorageMode.hostVisible, _blockLength),
      );
    }
    final buffer = blocks[_block];
    buffer.overwrite(bytes, destinationOffsetInBytes: offset);
    _offset = offset + length;
    return (buffer: buffer, offsetInBytes: offset, lengthInBytes: length);
  }

  /// Advances to the next frame's blocks.
  void reset() {
    _frame = (_frame + 1) % _frames.length;
    _block = 0;
    _offset = 0;
  }
}

/// A texture in GPU memory.
final class WgpuTexture {
  WgpuTexture._(
    this._texture, {
    required this.storageMode,
    required this.enableRenderTargetUsage,
    required this.enableShaderReadUsage,
    required this.enableShaderWriteUsage,
  });

  final fsw.WgpuTexture _texture;

  /// The device API texture behind this one.
  fsw.WgpuTexture get native => _texture;

  /// How the memory is reachable from the host.
  final StorageMode storageMode;

  /// Whether a pass can render into the texture.
  final bool enableRenderTargetUsage;

  /// Whether shaders can sample the texture.
  final bool enableShaderReadUsage;

  /// Whether shaders can write the texture.
  final bool enableShaderWriteUsage;

  /// The texel format.
  PixelFormat get format => _texture.format;

  /// The base level's width.
  int get width => _texture.width;

  /// The base level's height.
  int get height => _texture.height;

  /// Samples per texel.
  int get sampleCount => _texture.sampleCount;

  /// The texture's dimensionality.
  TextureType get textureType => _texture.type;

  /// The number of mip levels.
  int get mipLevelCount => _texture.mipLevelCount;

  /// The texture stays valid for its lifetime.
  bool get isValid => true;

  int _mipExtent(int base, int mipLevel) {
    final size = base >> mipLevel;
    return size < 1 ? 1 : size;
  }

  /// Replaces the texels of one mip level and slice with [sourceBytes].
  void overwrite(
    ByteData sourceBytes, {
    required int mipLevel,
    required int slice,
  }) {
    _texture.write(
      sourceBytes.buffer.asUint8List(
        sourceBytes.offsetInBytes,
        sourceBytes.lengthInBytes,
      ),
      mipLevel: mipLevel,
      slice: slice,
      width: _mipExtent(width, mipLevel),
      height: _mipExtent(height, mipLevel),
    );
  }

  /// Reads the base level back into a `ui.Image`. This waits for the GPU and
  /// copies through host memory on every call.
  ui.Image asImage() {
    final (bytesPerPixel, pixelFormat) = switch (format) {
      PixelFormat.r8g8b8a8UNormInt ||
      PixelFormat.r8g8b8a8UNormIntSRGB => (4, ui.PixelFormat.rgba8888),
      PixelFormat.b8g8r8a8UNormInt ||
      PixelFormat.b8g8r8a8UNormIntSRGB => (4, ui.PixelFormat.bgra8888),
      PixelFormat.r8UNormInt || PixelFormat.a8UNormInt => (
        1,
        ui.PixelFormat.rgba8888,
      ),
      PixelFormat.r8g8UNormInt => (2, ui.PixelFormat.rgba8888),
      PixelFormat.r16g16b16a16Float => (8, ui.PixelFormat.rgbaFloat32),
      PixelFormat.r32g32b32a32Float => (16, ui.PixelFormat.rgbaFloat32),
      PixelFormat.r32Float ||
      PixelFormat.d32FloatS8UInt => (4, ui.PixelFormat.rFloat32),
      _ => throw UnsupportedError(
        'The wgpu backend cannot read a ${format.name} texture into a '
        'ui.Image.',
      ),
    };
    final raw = _texture.read(
      width: width,
      height: height,
      bytesPerPixel: bytesPerPixel,
    );
    final pixels = switch (format) {
      PixelFormat.r8UNormInt || PixelFormat.a8UNormInt => _expand(raw, 1),
      PixelFormat.r8g8UNormInt => _expand(raw, 2),
      PixelFormat.r16g16b16a16Float => _halfsToFloats(raw),
      _ => raw,
    };
    if (!_syncDecodeUnavailable) {
      try {
        return ui.decodeImageFromPixelsSync(pixels, width, height, pixelFormat);
      } on Object {
        // Skia has no synchronous decode; paint the pixels instead.
        _syncDecodeUnavailable = true;
      }
    }
    return _paintedImage(_toRgba8(pixels, pixelFormat), width, height);
  }

  static bool _syncDecodeUnavailable = false;

  static Uint8List _toRgba8(Uint8List pixels, ui.PixelFormat format) {
    switch (format) {
      case ui.PixelFormat.rgba8888:
        return pixels;
      case ui.PixelFormat.bgra8888:
        final out = Uint8List.fromList(pixels);
        for (var i = 0; i < out.length; i += 4) {
          out[i] = pixels[i + 2];
          out[i + 2] = pixels[i];
        }
        return out;
      case ui.PixelFormat.rgbaFloat32 || ui.PixelFormat.rFloat32:
        final floats = Float32List.sublistView(pixels);
        final channels = format == ui.PixelFormat.rFloat32 ? 1 : 4;
        final count = floats.length ~/ channels;
        final out = Uint8List(count * 4);
        for (var i = 0; i < count; i++) {
          for (var c = 0; c < channels; c++) {
            out[i * 4 + c] = (floats[i * channels + c].clamp(0.0, 1.0) * 255)
                .round();
          }
          if (channels == 1) out[i * 4 + 3] = 255;
        }
        return out;
    }
  }

  /// A `ui.Image` of tightly packed RGBA8 [pixels], painted as one rectangle
  /// per run of equal pixels in a row and rasterized synchronously.
  static ui.Image _paintedImage(Uint8List pixels, int width, int height) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()
      ..blendMode = ui.BlendMode.src
      ..isAntiAlias = false;
    final words = Uint32List.sublistView(pixels);
    for (var y = 0; y < height; y++) {
      var x = 0;
      while (x < width) {
        final value = words[y * width + x];
        var end = x + 1;
        while (end < width && words[y * width + end] == value) {
          end++;
        }
        if (value != 0) {
          final i = (y * width + x) * 4;
          paint.color = ui.Color.fromARGB(
            pixels[i + 3],
            pixels[i],
            pixels[i + 1],
            pixels[i + 2],
          );
          canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), (end - x) + 0.0, 1),
            paint,
          );
        }
        x = end;
      }
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    return image;
  }

  static Uint8List _expand(Uint8List raw, int channels) {
    final count = raw.length ~/ channels;
    final out = Uint8List(count * 4);
    for (var i = 0; i < count; i++) {
      for (var c = 0; c < channels; c++) {
        out[i * 4 + c] = raw[i * channels + c];
      }
      out[i * 4 + 3] = 255;
    }
    return out;
  }

  static Uint8List _halfsToFloats(Uint8List raw) {
    final halfs = Uint16List.sublistView(raw);
    final floats = Float32List(halfs.length);
    for (var i = 0; i < halfs.length; i++) {
      floats[i] = _halfToFloat(halfs[i]);
    }
    return Uint8List.sublistView(floats);
  }

  static double _halfToFloat(int h) {
    final sign = (h & 0x8000) != 0 ? -1.0 : 1.0;
    final exponent = (h >> 10) & 0x1f;
    final mantissa = h & 0x3ff;
    if (exponent == 0) return sign * mantissa * 5.960464477539063e-8;
    if (exponent == 31) {
      return mantissa == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1 + mantissa / 1024) * _pow2(exponent - 15);
  }

  static double _pow2(int e) {
    var r = 1.0;
    if (e >= 0) {
      for (var i = 0; i < e; i++) {
        r *= 2;
      }
    } else {
      for (var i = 0; i < -e; i++) {
        r /= 2;
      }
    }
    return r;
  }
}

/// The shaders of one loaded bundle.
final class WgpuShaderLibrary {
  WgpuShaderLibrary._(this._context, this._entries);

  final WgpuContext _context;
  Map<String, fb.Shader> _entries;
  final Map<String, WgpuShader> _shaders = {};

  /// The shader named [shaderName], or null when the bundle has none. The
  /// shader compiles the first time it is asked for.
  WgpuShader? operator [](String shaderName) {
    final cached = _shaders[shaderName];
    if (cached != null) return cached;
    final entry = _entries[shaderName];
    if (entry == null) return null;
    final shader = WgpuShader._(shaderName)
      .._load(_context, _vulkanEntry(shaderName, entry));
    return _shaders[shaderName] = shader;
  }

  static fb.BackendShader _vulkanEntry(String name, fb.Shader entry) =>
      entry.vulkan ??
      (throw StateError(
        'The shader bundle entry "$name" has no Vulkan SPIR-V, which the wgpu '
        'backend loads. Build with `wgpu: true` under `hooks: user_defines: '
        'flutter_scene:` (`flutter_scene_wgpu: true` for an app hook that '
        'builds shaders) in the workspace root pubspec.',
      ));

  /// Replaces the library's shaders in place, keeping every [WgpuShader]
  /// handed out. Returns an error description, or null on success.
  String? reinitializeFromBytes(ByteData bytes) {
    final entries = _readBundle(bytes);
    if (entries == null) return 'The bytes are not a shader bundle.';
    try {
      for (final MapEntry(:key, :value) in _shaders.entries) {
        final entry = entries[key];
        if (entry != null) value._load(_context, _vulkanEntry(key, entry));
      }
    } on Object catch (error) {
      return '$error';
    }
    _entries = entries;
    return null;
  }

  /// Asset reloads read the asset asynchronously, which this synchronous
  /// call cannot; returns why.
  String? reinitializeFromAsset(String assetName) =>
      'The wgpu backend reloads a shader library from bytes, not from the '
      'asset "$assetName".';
}

typedef _UniformBlock = ({
  int group,
  int binding,
  int size,
  Map<String, int> members,
});

typedef _TextureSlot = ({int group, int binding});

typedef _VertexInput = ({
  String name,
  int location,
  VertexFormat format,
  int offset,
});

/// Turns a bundle's Vulkan SPIR-V into a native shader module. This is the
/// one place a bundle's code reaches wgpu.
fsw.WgpuShader _createModule(WgpuContext context, fb.BackendShader entry) =>
    context.device.createShaderFromSpirv(Uint8List.fromList(entry.shader!));

/// One compiled shader stage and the reflection it binds by.
final class WgpuShader {
  WgpuShader._(this.name);

  /// The shader's name in its bundle.
  final String name;

  late fsw.WgpuShader _module;
  final Map<String, _UniformBlock> _uniforms = {};
  final Map<String, _TextureSlot> _textures = {};
  final List<_VertexInput> _inputs = [];
  int _vertexStride = 0;
  int _generation = 0;

  void _load(WgpuContext context, fb.BackendShader entry) {
    _module = _createModule(context, entry);
    _uniforms
      ..clear()
      ..addAll({
        for (final u in entry.uniformStructs ?? const <fb.ShaderUniformStruct>[])
          if (u.name case final name?)
            name: (
              group: u.$set,
              binding: u.binding,
              size: u.sizeInBytes,
              members: {
                for (final f
                    in u.fields ?? const <fb.ShaderUniformStructField>[])
                  if (f.name case final member?) member: f.offsetInBytes,
              },
            ),
      });
    _textures
      ..clear()
      ..addAll({
        for (final t
            in entry.uniformTextures ?? const <fb.ShaderUniformTexture>[])
          if (t.name case final name?) name: (group: t.$set, binding: t.binding),
      });
    _inputs
      ..clear()
      ..addAll([
        for (final i in entry.inputs ?? const <fb.ShaderInput>[])
          if (i.name case final name?)
            (
              name: name,
              location: i.location,
              format: _vertexFormat(i.type, i.vecSize),
              offset: i.offset,
            ),
      ]);
    var stride = 0;
    for (final input in _inputs) {
      final end = input.offset + input.format.bytesPerElement;
      if (end > stride) stride = end;
    }
    _vertexStride = stride;
    _generation++;
  }

  static VertexFormat _vertexFormat(fb.InputDataType type, int vecSize) {
    final prefix = switch (type) {
      fb.InputDataType.kSignedInt => 'sint32',
      fb.InputDataType.kUnsignedInt => 'uint32',
      _ => 'float32',
    };
    final name = vecSize <= 1 ? prefix : '${prefix}x$vecSize';
    return VertexFormat.values.firstWhere(
      (f) => f.name == name,
      orElse: () => VertexFormat.float32x4,
    );
  }

  /// The size of the uniform struct [uniformName], or null when absent.
  int? uniformStructSize(String uniformName) => _uniforms[uniformName]?.size;

  /// Where [memberName] sits in the uniform struct [uniformName].
  int? uniformMemberOffset(String uniformName, String memberName) =>
      _uniforms[uniformName]?.members[memberName];
}

/// A shader pair and vertex layout, and the native pipelines built from it
/// for each combination of per-draw state.
final class WgpuRenderPipeline {
  WgpuRenderPipeline._(
    this._context,
    this._vertex,
    this._fragment,
    this._vertexLayout,
  );

  final WgpuContext _context;
  final WgpuShader _vertex;
  final WgpuShader _fragment;
  final VertexLayout? _vertexLayout;
  final Map<String, fsw.WgpuPipeline> _variants = {};
  int _vertexGeneration = -1;
  int _fragmentGeneration = -1;
  List<fsw.WgpuVertexBufferLayout> _buffers = const [];

  int get _bufferCount => _vertexLayout?.buffers.length ?? 1;

  void _refresh() {
    if (_vertexGeneration == _vertex._generation &&
        _fragmentGeneration == _fragment._generation) {
      return;
    }
    _variants.clear();
    _buffers = _buildBuffers();
    _vertexGeneration = _vertex._generation;
    _fragmentGeneration = _fragment._generation;
  }

  List<fsw.WgpuVertexBufferLayout> _buildBuffers() {
    final layout = _vertexLayout;
    if (layout == null) {
      return [
        fsw.WgpuVertexBufferLayout(
          strideInBytes: _vertex._vertexStride,
          attributes: [
            for (final input in _vertex._inputs)
              fsw.WgpuVertexAttribute(
                location: input.location,
                format: input.format,
                offsetInBytes: input.offset,
              ),
          ],
        ),
      ];
    }
    return [
      for (final buffer in layout.buffers)
        fsw.WgpuVertexBufferLayout(
          strideInBytes: buffer.strideInBytes,
          stepMode: buffer.stepMode,
          attributes: [
            for (final attribute in buffer.attributes)
              fsw.WgpuVertexAttribute(
                location: _locationOf(attribute.name),
                format: attribute.format,
                offsetInBytes: attribute.offsetInBytes,
              ),
          ],
        ),
    ];
  }

  int _locationOf(String name) {
    for (final input in _vertex._inputs) {
      if (input.name == name) return input.location;
    }
    throw Exception(
      'Vertex shader "${_vertex.name}" has no input named "$name".',
    );
  }

  fsw.WgpuPipeline _variant(
    _DrawState state,
    _TargetShape target,
    List<fsw.WgpuBindingOverride> overrides,
    String overrideKey,
  ) {
    _refresh();
    final key = '${target.key}|${state.key(target)}|$overrideKey';
    return _variants[key] ??= _context.device.createPipeline(
      fsw.WgpuPipelineDescriptor(
        vertexShader: _vertex._module,
        fragmentShader: _fragment._module,
        vertexBuffers: _buffers,
        colorTargets: [
          for (var i = 0; i < target.colors.length; i++)
            fsw.WgpuColorTarget(
              format: target.colors[i],
              // wgpu blends into a 32-bit float target only with a feature
              // this device does not request; draw unblended there.
              blend: _isFloat32(target.colors[i]) ? null : state.blendFor(i),
            ),
        ],
        depthStencil: switch (target.depthStencil) {
          null => null,
          final format => fsw.WgpuDepthStencilState(
            format: format,
            depthWriteEnabled: _hasDepth(format) && state.depthWrite,
            depthCompare: _hasDepth(format)
                ? state.depthCompare
                : CompareFunction.always,
            stencilFront: _hasStencil(format) ? state.stencilFront : null,
            stencilBack: _hasStencil(format) ? state.stencilBack : null,
          ),
        },
        primitiveType: state.primitiveType,
        cullMode: state.cullMode,
        windingOrder: state.windingOrder,
        sampleCount: target.samples,
        bindingOverrides: overrides,
      ),
    );
  }
}

/// The attachment formats a pass renders into.
final class _TargetShape {
  _TargetShape(this.colors, this.depthStencil, this.samples)
    : key =
          '${colors.map((f) => f.index).join(',')}/${depthStencil?.index}/'
          '$samples';

  final List<PixelFormat> colors;
  final PixelFormat? depthStencil;
  final int samples;
  final String key;
}

/// What flutter_gpu sets per draw and wgpu bakes into a pipeline.
final class _DrawState {
  CullMode cullMode = CullMode.none;
  WindingOrder windingOrder = WindingOrder.counterClockwise;
  PrimitiveType primitiveType = PrimitiveType.triangle;
  bool depthWrite = false;
  CompareFunction depthCompare = CompareFunction.always;
  StencilConfig stencilFront = StencilConfig();
  StencilConfig stencilBack = StencilConfig();
  final List<bool> blendEnabled = [];
  final List<ColorBlendEquation> blendEquations = [];

  ColorBlendEquation? blendFor(int attachment) =>
      attachment < blendEnabled.length && blendEnabled[attachment]
      ? blendEquations[attachment]
      : null;

  void _grow(int attachment) {
    while (blendEnabled.length <= attachment) {
      blendEnabled.add(false);
      blendEquations.add(ColorBlendEquation());
    }
  }

  static String _stencilKey(StencilConfig c) =>
      '${c.compareFunction.index}.${c.stencilFailureOperation.index}.'
      '${c.depthFailureOperation.index}.${c.depthStencilPassOperation.index}.'
      '${c.readMask}.${c.writeMask}';

  static String _blendKey(ColorBlendEquation e) =>
      '${e.colorBlendOperation.index}.${e.sourceColorBlendFactor.index}.'
      '${e.destinationColorBlendFactor.index}.${e.alphaBlendOperation.index}.'
      '${e.sourceAlphaBlendFactor.index}.'
      '${e.destinationAlphaBlendFactor.index}';

  String key(_TargetShape target) {
    final buffer = StringBuffer()
      ..write(cullMode.index)
      ..write(windingOrder.index)
      ..write(primitiveType.index);
    final depth = target.depthStencil;
    if (depth != null && _hasDepth(depth)) {
      buffer
        ..write(depthWrite ? 'w' : 'r')
        ..write(depthCompare.index);
    }
    if (depth != null && _hasStencil(depth)) {
      buffer
        ..write('s')
        ..write(_stencilKey(stencilFront))
        ..write('/')
        ..write(_stencilKey(stencilBack));
    }
    for (var i = 0; i < target.colors.length; i++) {
      final blend = blendFor(i);
      buffer
        ..write('b')
        ..write(blend == null ? '-' : _blendKey(blend));
    }
    return buffer.toString();
  }
}

/// Records render passes and copies into one native command stream, which
/// [submit] hands to the device in a single call.
final class WgpuCommandBuffer {
  WgpuCommandBuffer._(this._context);

  final WgpuContext _context;
  final fsw.WgpuCommandStream _stream = fsw.WgpuCommandStream();
  WgpuRenderPass? _active;
  bool _submitted = false;

  // What the native decoder holds bound, which lasts for the whole stream.
  final Map<(int, int), Object> _emitted = {};

  void _checkOpen() {
    if (_submitted) {
      throw StateError('This command buffer was already submitted.');
    }
  }

  void _endPass() {
    final active = _active;
    if (active == null) return;
    _stream.endRenderPass();
    active._ended = true;
    _active = null;
  }

  /// Starts a render pass, ending the one before it.
  WgpuRenderPass createRenderPass({
    required List<WgpuColorTarget> colors,
    WgpuDepthStencilTarget? depthStencil,
  }) {
    _checkOpen();
    _endPass();
    _stream.beginRenderPass(
      [
        for (final c in colors)
          fsw.WgpuColorAttachment(
            texture: c.texture._texture,
            loadAction: c.loadAction,
            storeAction: c.storeAction,
            clearColor: fsw.WgpuColor(
              c.clearValue.x,
              c.clearValue.y,
              c.clearValue.z,
              c.clearValue.w,
            ),
            resolveTexture: c.resolveTexture?._texture,
            mipLevel: c.mipLevel,
            slice: c.slice,
          ),
      ],
      depthStencil: switch (depthStencil) {
        null => null,
        final d => fsw.WgpuDepthStencilAttachment(
          texture: d.texture._texture,
          depthLoadAction: d.depthLoadAction,
          depthStoreAction: d.depthStoreAction,
          depthClearValue: d.depthClearValue.clamp(0.0, 1.0),
          stencilLoadAction: d.stencilLoadAction,
          stencilStoreAction: d.stencilStoreAction,
          stencilClearValue: d.stencilClearValue,
          mipLevel: d.mipLevel,
          slice: d.slice,
        ),
      },
    );
    final first = colors.isNotEmpty ? colors.first.texture : depthStencil!.texture;
    final mip = colors.isNotEmpty ? colors.first.mipLevel : depthStencil!.mipLevel;
    return _active = WgpuRenderPass._(
      this,
      _TargetShape(
        [for (final c in colors) c.texture.format],
        depthStencil?.texture.format,
        first.sampleCount,
      ),
      first._mipExtent(first.width, mip),
      first._mipExtent(first.height, mip),
    );
  }

  /// Copies tightly packed texel data from [source] into [destination].
  void copyBufferToTexture(
    WgpuBufferRange source,
    WgpuTextureRegion destination,
  ) {
    _checkOpen();
    _endPass();
    final format = destination.texture.format;
    _stream.copyBufferToTexture(
      source.buffer._buffer,
      destination.texture._texture,
      bufferOffset: source.offsetInBytes,
      bytesPerRow:
          (destination.width + format.blockWidth - 1) ~/
          format.blockWidth *
          format.bytesPerBlock,
      width: destination.width,
      height: destination.height,
      mipLevel: destination.mipLevel,
      slice: destination.slice,
      x: destination.x,
      y: destination.y,
    );
  }

  /// Copies the texels of [source] into [destination], tightly packed.
  void copyTextureToBuffer(
    WgpuTextureRegion source,
    WgpuBufferRange destination,
  ) {
    _checkOpen();
    _endPass();
    final format = source.texture.format;
    _stream.copyTextureToBuffer(
      source.texture._texture,
      destination.buffer._buffer,
      bufferOffset: destination.offsetInBytes,
      bytesPerRow:
          (source.width + format.blockWidth - 1) ~/
          format.blockWidth *
          format.bytesPerBlock,
      width: source.width,
      height: source.height,
      mipLevel: source.mipLevel,
      slice: source.slice,
      x: source.x,
      y: source.y,
    );
  }

  /// Copies the texels of [source] into [destination].
  void copyTextureToTexture(
    WgpuTextureRegion source,
    WgpuTexture destination, {
    required int x,
    required int y,
    required int mipLevel,
    required int slice,
  }) {
    _checkOpen();
    _endPass();
    _stream.copyTextureToTexture(
      source.texture._texture,
      destination._texture,
      width: source.width,
      height: source.height,
      srcMipLevel: source.mipLevel,
      srcSlice: source.slice,
      srcX: source.x,
      srcY: source.y,
      dstMipLevel: mipLevel,
      dstSlice: slice,
      dstX: x,
      dstY: y,
    );
  }

  /// Submits the recorded work. The device runs submissions and host writes
  /// in queue order, so [completionCallback] runs on the next microtask.
  void submit({CompletionCallback? completionCallback}) {
    _checkOpen();
    _endPass();
    _submitted = true;
    try {
      _context.device.submit(_stream);
    } finally {
      _stream.dispose();
    }
    if (completionCallback != null) {
      scheduleMicrotask(() => completionCallback(true));
    }
  }
}

typedef _BoundBuffer = ({WgpuDeviceBuffer buffer, int offset, int length});

typedef _BoundTexture = ({WgpuTexture texture, SamplerOptions? sampler});

/// One render pass of a [WgpuCommandBuffer].
final class WgpuRenderPass {
  WgpuRenderPass._(this._commands, this._target, this._width, this._height);

  final WgpuCommandBuffer _commands;
  final _TargetShape _target;
  final int _width;
  final int _height;
  final _DrawState _state = _DrawState();
  bool _ended = false;

  WgpuRenderPipeline? _pipeline;
  fsw.WgpuPipeline? _encodedPipeline;

  final Map<(int, int), _BoundBuffer> _uniforms = {};
  final Map<String, _BoundBuffer> _uniformsByName = {};
  final Map<(int, int), _BoundTexture> _textures = {};
  final Map<String, _BoundTexture> _texturesByName = {};
  final Map<int, _BoundBuffer> _vertexBuffers = {};
  _BoundBuffer? _indexBuffer;
  IndexType _indexType = IndexType.int32;
  final Map<int, _BoundBuffer> _encodedVertex = {};
  (_BoundBuffer, IndexType)? _encodedIndex;

  fsw.WgpuCommandStream get _stream => _commands._stream;

  void _checkOpen() {
    if (_ended) {
      throw StateError(
        'This render pass has ended; a command buffer ends a pass when it '
        'starts the next one or is submitted.',
      );
    }
  }

  /// Binds [pipeline] for the following draws.
  void bindPipeline(WgpuRenderPipeline pipeline) {
    _checkOpen();
    _pipeline = pipeline;
  }

  /// Binds a vertex buffer range to [slot].
  void bindVertexBuffer(
    WgpuDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes, {
    required int slot,
  }) {
    _vertexBuffers[slot] = (
      buffer: buffer,
      offset: offsetInBytes,
      length: lengthInBytes,
    );
  }

  /// Binds the index buffer range.
  void bindIndexBuffer(
    WgpuDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
    IndexType indexType,
  ) {
    _indexBuffer = (
      buffer: buffer,
      offset: offsetInBytes,
      length: lengthInBytes,
    );
    _indexType = indexType;
  }

  /// Binds a buffer range to [shader]'s uniform block [uniformName]. A block
  /// of the same name in the other stage takes it too, unless bound itself.
  void bindUniform(
    WgpuShader shader,
    String uniformName,
    WgpuDeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) {
    final block = shader._uniforms[uniformName];
    if (block == null) {
      throw StateError(
        'Failed to bind uniform. The shader "${shader.name}" declares no '
        'uniform block named "$uniformName".',
      );
    }
    final bound = (
      buffer: buffer,
      offset: offsetInBytes,
      length: lengthInBytes,
    );
    _uniforms[(block.group, block.binding)] = bound;
    _uniformsByName[uniformName] = bound;
  }

  /// Binds [texture] and a sampler built from [sampler] to [shader]'s
  /// texture [uniformName]. A texture of the same name in the other stage
  /// takes it too, unless bound itself.
  void bindTexture(
    WgpuShader shader,
    String uniformName,
    WgpuTexture texture,
    SamplerOptions? sampler,
  ) {
    final slot = shader._textures[uniformName];
    if (slot == null) {
      throw StateError(
        'Failed to bind texture. The shader "${shader.name}" declares no '
        'texture named "$uniformName".',
      );
    }
    final bound = (texture: texture, sampler: sampler);
    _textures[(slot.group, slot.binding)] = bound;
    _texturesByName[uniformName] = bound;
  }

  /// Forgets every uniform, texture, vertex and index binding.
  void clearBindings() {
    _uniforms.clear();
    _uniformsByName.clear();
    _textures.clear();
    _texturesByName.clear();
    _vertexBuffers.clear();
    _indexBuffer = null;
  }

  /// Turns blending on or off for one color attachment.
  void setColorBlendEnable(bool enable, {required int colorAttachmentIndex}) {
    _state._grow(colorAttachmentIndex);
    _state.blendEnabled[colorAttachmentIndex] = enable;
  }

  /// Sets the blend equation for one color attachment.
  void setColorBlendEquation(
    ColorBlendEquation equation, {
    required int colorAttachmentIndex,
  }) {
    _state._grow(colorAttachmentIndex);
    _state.blendEquations[colorAttachmentIndex] = equation;
  }

  /// Turns depth writes on or off.
  void setDepthWriteEnable(bool enable) => _state.depthWrite = enable;

  /// Sets the depth test.
  void setDepthCompareOperation(CompareFunction compareFunction) =>
      _state.depthCompare = compareFunction;

  /// Sets the stencil reference value.
  void setStencilReference(int referenceValue) {
    _checkOpen();
    _stream.setStencilReference(referenceValue);
  }

  /// Sets the stencil test and operations for [targetFace].
  void setStencilConfig(StencilConfig configuration, StencilFace targetFace) {
    if (targetFace != StencilFace.back) _state.stencilFront = configuration;
    if (targetFace != StencilFace.front) _state.stencilBack = configuration;
  }

  /// Sets which faces are culled.
  void setCullMode(CullMode cullMode) => _state.cullMode = cullMode;

  /// wgpu draws lines only with an optional feature, so every draw fills.
  void setPolygonMode(PolygonMode polygonMode) {}

  /// Sets the primitive topology.
  void setPrimitiveType(PrimitiveType primitiveType) =>
      _state.primitiveType = primitiveType;

  /// Sets which winding is front-facing.
  void setWindingOrder(WindingOrder windingOrder) =>
      _state.windingOrder = windingOrder;

  /// Sets the scissor rectangle, clipped to the attachment.
  void setScissor(Scissor scissor) {
    _checkOpen();
    final x0 = scissor.x.clamp(0, _width);
    final y0 = scissor.y.clamp(0, _height);
    final x1 = (scissor.x + scissor.width).clamp(x0, _width);
    final y1 = (scissor.y + scissor.height).clamp(y0, _height);
    _stream.setScissor(x0, y0, x1 - x0, y1 - y0);
  }

  /// Sets the viewport. wgpu needs the near depth at or below the far one.
  void setViewport(Viewport viewport) {
    _checkOpen();
    final near = viewport.depthRange.zNear.clamp(0.0, 1.0);
    final far = viewport.depthRange.zFar.clamp(0.0, 1.0);
    _stream.setViewport(
      viewport.x.toDouble(),
      viewport.y.toDouble(),
      viewport.width.toDouble(),
      viewport.height.toDouble(),
      minDepth: near < far ? near : far,
      maxDepth: near < far ? far : near,
    );
  }

  /// Draws [vertexCount] vertices.
  void draw(int vertexCount, {required int instanceCount}) {
    _checkOpen();
    final pipeline = _bound('draw');
    if (vertexCount == 0 || instanceCount == 0) return;
    _prepare(pipeline);
    _stream.draw(vertexCount, instanceCount: instanceCount);
  }

  /// Draws [indexCount] indices from the bound index buffer.
  void drawIndexed(int indexCount, {required int instanceCount}) {
    _checkOpen();
    final pipeline = _bound('drawIndexed');
    if (indexCount == 0 || instanceCount == 0) return;
    final index = _indexBuffer;
    if (index == null) {
      throw StateError('drawIndexed called before bindIndexBuffer');
    }
    _prepare(pipeline);
    final encoded = _encodedIndex;
    if (encoded == null ||
        !identical(encoded.$1, index) ||
        encoded.$2 != _indexType) {
      _stream.bindIndexBuffer(
        index.buffer._buffer,
        _indexType,
        offset: index.offset,
        size: index.length,
      );
      _encodedIndex = (index, _indexType);
    }
    _stream.drawIndexed(indexCount, instanceCount: instanceCount);
  }

  WgpuRenderPipeline _bound(String call) =>
      _pipeline ?? (throw StateError('$call called before bindPipeline'));

  void _prepare(WgpuRenderPipeline pipeline) {
    final context = _commands._context;
    final overrides = <fsw.WgpuBindingOverride>[];
    final overrideKey = StringBuffer();
    final textureBinds = <(int, int, WgpuTexture, fsw.WgpuSampler)>[];
    for (final shader in [pipeline._vertex, pipeline._fragment]) {
      for (final MapEntry(key: name, value: slot) in shader._textures.entries) {
        final bound =
            _textures[(slot.group, slot.binding)] ?? _texturesByName[name];
        if (bound == null) continue;
        final format = bound.texture.format;
        final filterable =
            !_hasDepth(format) &&
            format != PixelFormat.s8UInt &&
            (!_isFloat32(format) || context.features.float32Filterable) &&
            bound.texture.sampleCount == 1;
        overrides
          ..add((
            group: slot.group,
            binding: slot.binding,
            type: filterable
                ? fsw.WgpuBindingType.floatTexture
                : fsw.WgpuBindingType.unfilterableFloatTexture,
          ))
          ..add((
            group: slot.group,
            binding: slot.binding + _samplerBindingOffset,
            type: filterable
                ? fsw.WgpuBindingType.filteringSampler
                : fsw.WgpuBindingType.nonFilteringSampler,
          ));
        overrideKey.write(filterable ? 'f' : 'u');
        textureBinds.add((
          slot.group,
          slot.binding,
          bound.texture,
          context._sampler(bound.sampler, filters: filterable),
        ));
      }
    }
    final variant = pipeline._variant(
      _state,
      _target,
      overrides,
      overrideKey.toString(),
    );
    if (!identical(variant, _encodedPipeline)) {
      _stream.bindPipeline(variant);
      _encodedPipeline = variant;
    }
    final emitted = _commands._emitted;
    for (final shader in [pipeline._vertex, pipeline._fragment]) {
      for (final MapEntry(key: name, value: block) in shader._uniforms.entries) {
        final bound =
            _uniforms[(block.group, block.binding)] ?? _uniformsByName[name];
        if (bound == null) continue;
        final room = bound.buffer.sizeInBytes - bound.offset;
        final padded = (block.size + 15) & ~15;
        final size = padded <= room ? padded : room;
        final key = (block.group, block.binding);
        final value = (bound.buffer, bound.offset, size);
        if (emitted[key] == value) continue;
        emitted[key] = value;
        _stream.bindBuffer(
          block.group,
          block.binding,
          bound.buffer._buffer,
          offset: bound.offset,
          size: size,
        );
      }
    }
    for (final (group, binding, texture, sampler) in textureBinds) {
      final key = (group, binding);
      final value = (texture, sampler);
      if (emitted[key] == value) continue;
      emitted[key] = value;
      _stream.bindTexture(
        group,
        binding,
        texture._texture,
        sampler: sampler,
        samplerBinding: binding + _samplerBindingOffset,
      );
    }
    for (var slot = 0; slot < pipeline._bufferCount; slot++) {
      final view = _vertexBuffers[slot];
      if (view == null) {
        if (pipeline._buffers[slot].attributes.isEmpty) continue;
        throw StateError(
          'Draw with "${pipeline._vertex.name}" has no vertex buffer bound '
          'to slot $slot.',
        );
      }
      if (identical(_encodedVertex[slot], view)) continue;
      _encodedVertex[slot] = view;
      _stream.bindVertexBuffer(
        slot,
        view.buffer._buffer,
        offset: view.offset,
        size: view.length,
      );
    }
  }
}

/// A ring of textures whose presented frame reads back into a `ui.Image`.
final class WgpuImageSurface {
  WgpuImageSurface._(this._context, this._width, this._height, this.format);

  final WgpuContext _context;
  int _width;
  int _height;

  /// The color format of every frame.
  final PixelFormat format;

  final List<WgpuTexture> _free = [];
  int _allocated = 0;
  ui.Image? _current;

  /// The frame width.
  int get width => _width;

  /// The frame height.
  int get height => _height;

  /// How many textures back the surface.
  int get debugBackingTextureCount => _allocated;

  /// The most recently presented frame, or null before the first.
  ui.Image? get currentImage => _current;

  /// Resizes later frames.
  void resize(int width, int height) {
    if (width == _width && height == _height) return;
    _width = width;
    _height = height;
    _free.clear();
    _allocated = 0;
  }

  /// A texture to render the next frame into.
  WgpuTexture acquireNextFrame() {
    if (_free.isNotEmpty) return _free.removeLast();
    _allocated++;
    return _context.createTexture(
      StorageMode.devicePrivate,
      _width,
      _height,
      format: format,
      sampleCount: 1,
      textureType: TextureType.texture2D,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true,
      enableShaderWriteUsage: false,
      mipLevelCount: 1,
    );
  }

  /// Submits [commandBuffer] if needed and reads [frame] back as the current
  /// image.
  GpuPresentStatus present(WgpuTexture frame, WgpuCommandBuffer commandBuffer) {
    if (!commandBuffer._submitted) commandBuffer.submit();
    _current = frame.asImage();
    _recycle(frame);
    return GpuPresentStatus.success;
  }

  /// Returns [frame] unpresented.
  void discard(WgpuTexture frame) => _recycle(frame);

  void _recycle(WgpuTexture frame) {
    if (frame.width == _width && frame.height == _height) _free.add(frame);
  }
}
