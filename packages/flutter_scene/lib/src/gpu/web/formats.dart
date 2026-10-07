part of '_gpu.dart';

// Enum order and naming must match `package:flutter_gpu` exactly so
// consumer code typechecks the same way on both backends. Comments
// abbreviated; see flutter_gpu/src/formats.dart for authoritative docs.

enum StorageMode { hostVisible, devicePrivate, deviceTransient }

enum PixelFormat {
  unknown,
  a8UNormInt,
  r8UNormInt,
  r8g8UNormInt,
  r8g8b8a8UNormInt,
  r8g8b8a8UNormIntSRGB,
  b8g8r8a8UNormInt,
  b8g8r8a8UNormIntSRGB,
  r32g32b32a32Float,
  r16g16b16a16Float,
  r32Float,
  b10g10r10XR,
  b10g10r10XRSRGB,
  b10g10r10a10XR,
  s8UInt,
  d24UnormS8Uint,
  d32FloatS8UInt,
  // Block-compressed (sample-only) formats. Support varies by family; check
  // GpuContext.supportsTextureCompression before allocating.
  bc1RGBAUNormInt,
  bc1RGBAUNormIntSRGB,
  bc3RGBAUNormInt,
  bc3RGBAUNormIntSRGB,
  bc5RGUNormInt,
  bc7RGBAUNormInt,
  bc7RGBAUNormIntSRGB,
  etc2RGB8UNormInt,
  etc2RGB8UNormIntSRGB,
  etc2RGBA8UNormInt,
  etc2RGBA8UNormIntSRGB,
  astc4x4LDR,
  astc4x4LDRSRGB,
  astc8x8LDR,
  astc8x8LDRSRGB,
  astc4x4HDR,
  astc8x8HDR;

  /// Whether this is a block-compressed (sample-only) format.
  bool get isCompressed {
    switch (this) {
      case PixelFormat.bc1RGBAUNormInt:
      case PixelFormat.bc1RGBAUNormIntSRGB:
      case PixelFormat.bc3RGBAUNormInt:
      case PixelFormat.bc3RGBAUNormIntSRGB:
      case PixelFormat.bc5RGUNormInt:
      case PixelFormat.bc7RGBAUNormInt:
      case PixelFormat.bc7RGBAUNormIntSRGB:
      case PixelFormat.etc2RGB8UNormInt:
      case PixelFormat.etc2RGB8UNormIntSRGB:
      case PixelFormat.etc2RGBA8UNormInt:
      case PixelFormat.etc2RGBA8UNormIntSRGB:
      case PixelFormat.astc4x4LDR:
      case PixelFormat.astc4x4LDRSRGB:
      case PixelFormat.astc8x8LDR:
      case PixelFormat.astc8x8LDRSRGB:
      case PixelFormat.astc4x4HDR:
      case PixelFormat.astc8x8HDR:
        return true;
      default:
        return false;
    }
  }

  /// The width, in texels, of a single block. Uncompressed formats return 1.
  int get blockWidth {
    switch (this) {
      case PixelFormat.astc8x8LDR:
      case PixelFormat.astc8x8LDRSRGB:
      case PixelFormat.astc8x8HDR:
        return 8;
      default:
        return isCompressed ? 4 : 1;
    }
  }

  /// The height, in texels, of a single block. Uncompressed formats return 1.
  int get blockHeight => blockWidth;

  /// The number of bytes used to store one block. For uncompressed formats a
  /// block is a single texel, so this matches the bytes per texel.
  int get bytesPerBlock {
    switch (this) {
      case PixelFormat.unknown:
        return 0;
      case PixelFormat.a8UNormInt:
      case PixelFormat.r8UNormInt:
      case PixelFormat.s8UInt:
        return 1;
      case PixelFormat.r8g8UNormInt:
        return 2;
      case PixelFormat.r8g8b8a8UNormInt:
      case PixelFormat.r8g8b8a8UNormIntSRGB:
      case PixelFormat.b8g8r8a8UNormInt:
      case PixelFormat.b8g8r8a8UNormIntSRGB:
      case PixelFormat.r32Float:
      case PixelFormat.b10g10r10XR:
      case PixelFormat.b10g10r10XRSRGB:
      case PixelFormat.d24UnormS8Uint:
        return 4;
      case PixelFormat.d32FloatS8UInt:
        return 5;
      case PixelFormat.r16g16b16a16Float:
      case PixelFormat.b10g10r10a10XR:
        return 8;
      case PixelFormat.r32g32b32a32Float:
        return 16;
      case PixelFormat.bc1RGBAUNormInt:
      case PixelFormat.bc1RGBAUNormIntSRGB:
      case PixelFormat.etc2RGB8UNormInt:
      case PixelFormat.etc2RGB8UNormIntSRGB:
        return 8;
      case PixelFormat.bc3RGBAUNormInt:
      case PixelFormat.bc3RGBAUNormIntSRGB:
      case PixelFormat.bc5RGUNormInt:
      case PixelFormat.bc7RGBAUNormInt:
      case PixelFormat.bc7RGBAUNormIntSRGB:
      case PixelFormat.etc2RGBA8UNormInt:
      case PixelFormat.etc2RGBA8UNormIntSRGB:
      case PixelFormat.astc4x4LDR:
      case PixelFormat.astc4x4LDRSRGB:
      case PixelFormat.astc8x8LDR:
      case PixelFormat.astc8x8LDRSRGB:
      case PixelFormat.astc4x4HDR:
      case PixelFormat.astc8x8HDR:
        return 16;
    }
  }
}

/// Hardware families for block-compressed texture support.
enum TextureCompressionFamily { bc, etc2, astc, astcHdr }

enum BlendFactor {
  zero,
  one,
  sourceColor,
  oneMinusSourceColor,
  sourceAlpha,
  oneMinusSourceAlpha,
  destinationColor,
  oneMinusDestinationColor,
  destinationAlpha,
  oneMinusDestinationAlpha,
  sourceAlphaSaturated,
  blendColor,
  oneMinusBlendColor,
  blendAlpha,
  oneMinusBlendAlpha,
}

enum BlendOperation { add, subtract, reverseSubtract }

enum LoadAction { dontCare, load, clear }

enum StoreAction {
  dontCare,
  store,
  multisampleResolve,
  storeAndMultisampleResolve,
}

enum ShaderStage { vertex, fragment }

enum MinMagFilter { nearest, linear }

enum MipFilter { nearest, linear }

enum SamplerAddressMode { clampToEdge, repeat, mirror }

enum IndexType { int16, int32 }

enum PrimitiveType { triangle, triangleStrip, line, lineStrip, point }

enum CullMode { none, frontFace, backFace }

enum WindingOrder { clockwise, counterClockwise }

enum PolygonMode { fill, line }

enum CompareFunction {
  never,
  always,
  less,
  equal,
  lessEqual,
  greater,
  notEqual,
  greaterEqual,
}

enum StencilOperation {
  keep,
  zero,
  setToReferenceValue,
  incrementClamp,
  decrementClamp,
  invert,
  incrementWrap,
  decrementWrap,
}

enum TextureType {
  texture2D,
  texture2DMultisample,
  textureCube,
  textureExternalOES,
}
