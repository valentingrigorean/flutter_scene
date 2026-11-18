// The value types and enums of Flutter's flutter_gpu package, which imports
// dart:ffi and so does not compile for the web, copied from its sources
// (Copyright 2013 The Flutter Authors, BSD-3-Clause) in the same order, as
// the GPU backend contract packs an enum's index. Its resource classes are
// interfaces no object implements on the web: Flutter GPU (Impeller) does
// not run there, and every resource is a registered backend's.
//
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:vector_math/vector_math.dart' as vm;

// ATTENTION! ATTENTION! ATTENTION!
// All enum classes defined in this file must exactly match the contents and
// order of the corresponding enums defined in `gpu/formats.h`.

/// Specifies where an allocation resides and how it may be used.
enum StorageMode {
  /// Allocations can be mapped onto the hosts address space and also be used by
  /// the device.
  hostVisible,

  /// Allocations can only be used by the device. This location is optimal for
  /// use by the device. If the host needs to access these allocations, the
  /// data must first be copied into a host visible allocation.
  devicePrivate,

  /// Used by the device for temporary render targets. These allocations cannot
  /// be copied to or from other allocations. This storage mode is only valid
  /// for Textures.
  ///
  /// These allocations reside in tile memory which has higher bandwidth, lower
  /// latency and lower power consumption. The total device memory usage is
  /// also lower as a separate allocation does not need to be created in
  /// device memory. Prefer using these allocations for intermediates like depth
  /// and stencil buffers.
  deviceTransient,
}

/// The memory layout of the texels in a [Texture].
///
/// Each name spells out the texture's components in order, the bit width of
/// each component, and how those bits are interpreted. For example,
/// [r8g8b8a8UNormInt] is a 32 bit per pixel format with four 8 bit components
/// ordered red, green, blue, alpha, each stored as an unsigned normalized
/// integer.
///
/// Component key:
///
///  * `r`, `g`, `b`: the red, green, and blue color components.
///  * `a`: the alpha component.
///  * `d`: the depth component.
///  * `s`: the stencil component.
///  * `UNorm`: an unsigned integer that is mapped from the range
///    `[0, 2^bits - 1]` onto the floating point range `[0.0, 1.0]` when read.
///  * `UInt`: an unsigned integer that is read without normalization.
///  * `Float`: an IEEE 754 floating point value.
///  * `SRGB`: the color components are stored in the sRGB color space and are
///    converted to and from linear space when read and written.
///
/// The block-compressed formats are named after their compression scheme (BC,
/// ETC2, or ASTC) and block dimensions. See [PixelFormatProperties] for block
/// geometry and [TextureCompressionFamily] for how hardware support is
/// grouped.
enum PixelFormat {
  /// An invalid or unspecified format.
  ///
  /// Used as a placeholder and never as the format of a real texture.
  unknown,

  /// A single 8 bit alpha component, stored as an unsigned normalized integer.
  a8UNormInt,

  /// A single 8 bit red component, stored as an unsigned normalized integer.
  r8UNormInt,

  /// Two 8 bit components (red, green), stored as unsigned normalized integers.
  r8g8UNormInt,

  /// Four 8 bit components (red, green, blue, alpha), stored as unsigned
  /// normalized integers.
  ///
  /// This is the most common 32 bit per pixel color format and the default for
  /// [GpuContext.createTexture].
  r8g8b8a8UNormInt,

  /// Like [r8g8b8a8UNormInt], but the color components are stored in the sRGB
  /// color space.
  r8g8b8a8UNormIntSRGB,

  /// Four 8 bit components ordered blue, green, red, alpha, stored as unsigned
  /// normalized integers.
  b8g8r8a8UNormInt,

  /// Like [b8g8r8a8UNormInt], but the color components are stored in the sRGB
  /// color space.
  b8g8r8a8UNormIntSRGB,

  /// Four 32 bit floating point components (red, green, blue, alpha), for a
  /// total of 128 bits per pixel.
  r32g32b32a32Float,

  /// Four 16 bit (half precision) floating point components (red, green, blue,
  /// alpha), for a total of 64 bits per pixel.
  r16g16b16a16Float,

  /// A single-channel 32-bit floating-point pixel format.
  r32Float,
  // Depth and stencil formats.
  /// A single 8 bit stencil component, stored as an unsigned integer.
  s8UInt,

  /// A 24 bit depth component stored as an unsigned normalized integer, packed
  /// together with an 8 bit unsigned integer stencil component.
  d24UnormS8Uint,

  /// A 32 bit floating point depth component, packed together with an 8 bit
  /// unsigned integer stencil component.
  d32FloatS8UInt,
  // Block-compressed formats. These are sample-only: they cannot be used as
  // render targets, with storage modes other than `hostVisible`/`devicePrivate`,
  // for shader writes, or with multisampling. Hardware support varies by
  // family; check [GpuContext.supportsTextureCompression] before allocating.
  /// BC1 RGBA, 4x4 blocks, 8 bytes per block. Desktop BC family.
  bc1RGBAUNormInt,

  /// BC1 RGBA sRGB, 4x4 blocks, 8 bytes per block. Desktop BC family.
  bc1RGBAUNormIntSRGB,

  /// BC3 RGBA, 4x4 blocks, 16 bytes per block. Desktop BC family.
  bc3RGBAUNormInt,

  /// BC3 RGBA sRGB, 4x4 blocks, 16 bytes per block. Desktop BC family.
  bc3RGBAUNormIntSRGB,

  /// BC5 RG, 4x4 blocks, 16 bytes per block. Desktop BC family.
  bc5RGUNormInt,

  /// BC7 RGBA, 4x4 blocks, 16 bytes per block. Desktop BC family.
  bc7RGBAUNormInt,

  /// BC7 RGBA sRGB, 4x4 blocks, 16 bytes per block. Desktop BC family.
  bc7RGBAUNormIntSRGB,

  /// ETC2 RGB8, 4x4 blocks, 8 bytes per block. Mobile ETC2 family.
  etc2RGB8UNormInt,

  /// ETC2 RGB8 sRGB, 4x4 blocks, 8 bytes per block. Mobile ETC2 family.
  etc2RGB8UNormIntSRGB,

  /// ETC2 RGBA8, 4x4 blocks, 16 bytes per block. Mobile ETC2 family.
  etc2RGBA8UNormInt,

  /// ETC2 RGBA8 sRGB, 4x4 blocks, 16 bytes per block. Mobile ETC2 family.
  etc2RGBA8UNormIntSRGB,

  /// ASTC LDR, 4x4 blocks, 16 bytes per block. Modern mobile ASTC family.
  astc4x4LDR,

  /// ASTC LDR sRGB, 4x4 blocks, 16 bytes per block. Modern mobile ASTC family.
  astc4x4LDRSRGB,

  /// ASTC LDR, 8x8 blocks, 16 bytes per block. Modern mobile ASTC family.
  astc8x8LDR,

  /// ASTC LDR sRGB, 8x8 blocks, 16 bytes per block. Modern mobile ASTC family.
  astc8x8LDRSRGB,

  /// ASTC HDR, 4x4 blocks, 16 bytes per block. Modern mobile ASTC HDR family.
  /// HDR samples are linear floating point, so there is no sRGB variant.
  astc4x4HDR,

  /// ASTC HDR, 8x8 blocks, 16 bytes per block. Modern mobile ASTC HDR family.
  /// HDR samples are linear floating point, so there is no sRGB variant.
  astc8x8HDR,
}

/// The family of a block-compressed pixel format. Hardware support for
/// compressed formats is granted on a per-family basis.
enum TextureCompressionFamily {
  /// BC1 through BC7. Typical on desktop GPUs.
  bc,

  /// ETC2 and EAC. Typical on mobile, OpenGL ES 3.0, and WebGL2.
  etc2,

  /// ASTC LDR. Typical on modern mobile and some desktop GPUs.
  astc,

  /// ASTC HDR. A separate device feature from ASTC LDR. Typical on newer mobile
  /// GPUs.
  astcHdr,
}

/// Block-geometry and family queries for [PixelFormat].
extension PixelFormatProperties on PixelFormat {
  /// Whether this is a block-compressed pixel format.
  bool get isCompressed {
    return blockWidth > 1 || blockHeight > 1;
  }

  /// The width, in texels, of a single block. Uncompressed formats return 1.
  int get blockWidth {
    switch (this) {
      case PixelFormat.astc8x8LDR:
      case PixelFormat.astc8x8LDRSRGB:
      case PixelFormat.astc8x8HDR:
        return 8;
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
      case PixelFormat.astc4x4HDR:
        return 4;
      // ignore: no_default_cases
      default:
        return 1;
    }
  }

  /// The height, in texels, of a single block. Uncompressed formats return 1.
  int get blockHeight {
    switch (this) {
      case PixelFormat.astc8x8LDR:
      case PixelFormat.astc8x8LDRSRGB:
      case PixelFormat.astc8x8HDR:
        return 8;
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
      case PixelFormat.astc4x4HDR:
        return 4;
      // ignore: no_default_cases
      default:
        return 1;
    }
  }

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
      case PixelFormat.d24UnormS8Uint:
        return 4;
      case PixelFormat.d32FloatS8UInt:
        return 5;
      case PixelFormat.r16g16b16a16Float:
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

  /// The compression family this format belongs to. Returns null for
  /// uncompressed formats.
  TextureCompressionFamily? get compressionFamily {
    switch (this) {
      case PixelFormat.bc1RGBAUNormInt:
      case PixelFormat.bc1RGBAUNormIntSRGB:
      case PixelFormat.bc3RGBAUNormInt:
      case PixelFormat.bc3RGBAUNormIntSRGB:
      case PixelFormat.bc5RGUNormInt:
      case PixelFormat.bc7RGBAUNormInt:
      case PixelFormat.bc7RGBAUNormIntSRGB:
        return TextureCompressionFamily.bc;
      case PixelFormat.etc2RGB8UNormInt:
      case PixelFormat.etc2RGB8UNormIntSRGB:
      case PixelFormat.etc2RGBA8UNormInt:
      case PixelFormat.etc2RGBA8UNormIntSRGB:
        return TextureCompressionFamily.etc2;
      case PixelFormat.astc4x4LDR:
      case PixelFormat.astc4x4LDRSRGB:
      case PixelFormat.astc8x8LDR:
      case PixelFormat.astc8x8LDRSRGB:
        return TextureCompressionFamily.astc;
      case PixelFormat.astc4x4HDR:
      case PixelFormat.astc8x8HDR:
        return TextureCompressionFamily.astcHdr;
      // ignore: no_default_cases
      default:
        return null;
    }
  }
}

/// A coefficient that scales one input to the blend equation.
///
/// When blending is enabled for a color attachment, the new (source) color
/// produced by the fragment shader is combined with the existing (destination)
/// color already in the attachment. Each side is first multiplied by a
/// [BlendFactor] and then combined by a [BlendOperation]:
///
/// ```
/// result.rgb = (sourceColorFactor * source.rgb) <op> (destinationColorFactor * destination.rgb);
/// result.a   = (sourceAlphaFactor * source.a)   <op> (destinationAlphaFactor * destination.a);
/// ```
///
/// The "blend color" referenced by some factors is a separate constant color
/// supplied to the blend equation, distinct from the source and destination
/// colors.
enum BlendFactor {
  /// Multiplies the input by zero, dropping it from the blend.
  zero,

  /// Multiplies the input by one, leaving it unchanged.
  one,

  /// Multiplies the input by the source color, component by component.
  sourceColor,

  /// Multiplies the input by one minus the source color, component by
  /// component.
  oneMinusSourceColor,

  /// Multiplies the input by the source alpha.
  sourceAlpha,

  /// Multiplies the input by one minus the source alpha.
  oneMinusSourceAlpha,

  /// Multiplies the input by the destination color, component by component.
  destinationColor,

  /// Multiplies the input by one minus the destination color, component by
  /// component.
  oneMinusDestinationColor,

  /// Multiplies the input by the destination alpha.
  destinationAlpha,

  /// Multiplies the input by one minus the destination alpha.
  oneMinusDestinationAlpha,

  /// Multiplies the input by `min(sourceAlpha, 1 - destinationAlpha)`.
  sourceAlphaSaturated,

  /// Multiplies the input by the constant blend color, component by component.
  blendColor,

  /// Multiplies the input by one minus the constant blend color, component by
  /// component.
  oneMinusBlendColor,

  /// Multiplies the input by the alpha of the constant blend color.
  blendAlpha,

  /// Multiplies the input by one minus the alpha of the constant blend color.
  oneMinusBlendAlpha,
}

/// The operator that combines the scaled source and destination values in the
/// blend equation.
///
/// Each operand is first scaled by a [BlendFactor] before this operation is
/// applied.
enum BlendOperation {
  /// Adds the source and destination values: `source + destination`.
  add,

  /// Subtracts the destination from the source: `source - destination`.
  subtract,

  /// Subtracts the source from the destination: `destination - source`.
  reverseSubtract,
}

/// What happens to the contents of an attachment's [Texture] when a render
/// pass begins.
enum LoadAction {
  /// The existing contents are not preserved and may be left undefined.
  ///
  /// Use this when the entire attachment will be drawn over during the pass.
  dontCare,

  /// The existing contents of the texture are loaded so that the render pass
  /// draws on top of them.
  load,

  /// The texture is cleared to the attachment's clear value before drawing.
  clear,
}

/// What happens to the contents of an attachment's [Texture] when a render
/// pass ends.
enum StoreAction {
  /// The results are not guaranteed to be stored and may be discarded.
  ///
  /// Use this for transient attachments that are not read after the pass, such
  /// as a depth or stencil buffer used only during rendering.
  dontCare,

  /// The results are written back to the texture so they can be read later.
  store,

  /// The multisampled results are resolved into the attachment's resolve
  /// texture. The multisampled texture itself is not stored.
  multisampleResolve,

  /// The multisampled results are both stored and resolved into the
  /// attachment's resolve texture.
  storeAndMultisampleResolve,
}

/// A programmable stage of the render pipeline that a [Shader] runs in.
enum ShaderStage {
  /// The vertex stage, which runs once per input vertex.
  vertex,

  /// The fragment stage, which runs once per rasterized fragment.
  fragment,
}

/// How a [Texture] is sampled when it is minified or magnified to fit the area
/// being drawn.
enum MinMagFilter {
  /// Uses the value of the single texel nearest to the sample point.
  ///
  /// This is the most widely supported filter.
  nearest,

  /// Linearly interpolates between the texels nearest to the sample point.
  linear,
}

/// How samples are selected and filtered between the mipmap levels of a
/// [Texture].
enum MipFilter {
  /// Samples from the single nearest mipmap level.
  nearest,

  /// Samples from the two nearest mipmap levels and linearly interpolates
  /// between them.
  linear,
}

/// How texture coordinates outside the range `[0, 1]` are mapped back onto a
/// [Texture] when sampling.
enum SamplerAddressMode {
  /// Coordinates are clamped to the edge of the texture, so sampling outside
  /// the texture repeats its border texels.
  clampToEdge,

  /// The texture is tiled by wrapping coordinates around, keeping only their
  /// fractional part.
  repeat,

  /// The texture is tiled by mirroring it at every integer coordinate
  /// boundary.
  mirror,
}

/// The width of each element in an index buffer.
///
/// See [RenderPass.bindIndexBuffer].
enum IndexType {
  /// Each index is a 16 bit unsigned integer.
  int16,

  /// Each index is a 32 bit unsigned integer.
  int32,
}

/// How a sequence of vertices is assembled into primitives to be rasterized.
enum PrimitiveType {
  /// Draws a separate triangle for each group of three vertices.
  ///
  /// Vertices `[A, B, C, D, E, F]` produce triangles `[ABC, DEF]`.
  triangle,

  /// Draws a connected strip of triangles, adding one triangle for each vertex
  /// after the first two.
  ///
  /// Vertices `[A, B, C, D, E, F]` produce triangles
  /// `[ABC, BCD, CDE, DEF]`.
  triangleStrip,

  /// Draws a separate line segment for each pair of vertices.
  ///
  /// Vertices `[A, B, C, D]` produce line segments `[AB, CD]`.
  line,

  /// Draws a single connected line that passes through every vertex in order.
  ///
  /// Vertices `[A, B, C]` produce one connected line `[ABC]`.
  lineStrip,

  /// Draws a point at each vertex.
  point,
}

/// Which triangle faces, if any, are discarded before rasterization.
///
/// A triangle's facing is determined by its [WindingOrder].
enum CullMode {
  /// No triangles are culled. Both front and back faces are drawn.
  none,

  /// Front facing triangles are culled.
  frontFace,

  /// Back facing triangles are culled.
  backFace,
}

/// The vertex winding direction that defines the front face of a triangle.
///
/// Used together with [CullMode] to decide which triangles are discarded.
enum WindingOrder {
  /// Triangles whose vertices appear in clockwise order are front facing.
  clockwise,

  /// Triangles whose vertices appear in counter clockwise order are front
  /// facing.
  counterClockwise,
}

/// How triangles are rasterized: as filled areas or as outlines.
enum PolygonMode {
  /// Triangles are filled.
  fill,

  /// Only the edges of triangles are drawn, producing a wireframe.
  line,
}

/// The comparison applied between a new value and the value already stored in
/// the depth or stencil buffer.
///
/// The test passes when the comparison evaluates to true.
enum CompareFunction {
  /// Comparison test never passes.
  never,

  /// Comparison test always passes.
  always,

  /// Comparison test passes if new_value < current_value.
  less,

  /// Comparison test passes if new_value == current_value.
  equal,

  /// Comparison test passes if new_value <= current_value.
  lessEqual,

  /// Comparison test passes if new_value > current_value.
  greater,

  /// Comparison test passes if new_value != current_value.
  notEqual,

  /// Comparison test passes if new_value >= current_value.
  greaterEqual,
}

/// The operation performed on the value in the stencil buffer based on the
/// outcome of the stencil and depth tests.
///
/// See [StencilConfig].
enum StencilOperation {
  /// Don't modify the current stencil value.
  keep,

  /// Reset the stencil value to zero.
  zero,

  /// Reset the stencil value to the reference value.
  setToReferenceValue,

  /// Increment the current stencil value by 1. Clamp it to the maximum.
  incrementClamp,

  /// Decrement the current stencil value by 1. Clamp it to zero.
  decrementClamp,

  /// Perform a logical bitwise invert on the current stencil value.
  invert,

  /// Increment the current stencil value by 1. If at maximum, set to zero.
  incrementWrap,

  /// Decrement the current stencil value by 1. If at zero, set to maximum.
  decrementWrap,
}

/// The kind of a [Texture], which determines its dimensionality and how it is
/// sampled.
enum TextureType {
  /// A 2-dimensional texture.
  texture2D,

  /// A 2-dimensional texture with multisampling enabled.
  texture2DMultisample,

  /// A cubemap texture.
  textureCube,

  /// A texture sourced from an external source.
  textureExternalOES,

  /// A 2-dimensional texture with multiple same-size layers, sampled in
  /// shaders as `sampler2DArray`. The layer count is set with the
  /// `layerCount` argument to `GpuContext.createTexture`.
  texture2DArray,
}

/// The format of a single vertex attribute.
///
/// Each value names a component count, scalar type, and bit width. The enum
/// currently covers the 32-bit-per-component scalar types (float, signed
/// integer, unsigned integer) in 1, 2, 3, and 4 component widths. Normalized
/// integer, packed, half-float, BGRA-swizzled, and 64-bit attribute formats
/// will be added in a future release; new values are purely additive and
/// won't affect callers using existing values.
// TODO(https://github.com/flutter/flutter/issues/186309): Add normalized,
// packed, half-float, BGRA-swizzled, and 64-bit vertex attribute formats.
enum VertexFormat {
  /// One 32-bit float (4 bytes).
  float32(bytesPerElement: 4, componentCount: 1),

  /// Two 32-bit floats (8 bytes).
  float32x2(bytesPerElement: 8, componentCount: 2),

  /// Three 32-bit floats (12 bytes).
  float32x3(bytesPerElement: 12, componentCount: 3),

  /// Four 32-bit floats (16 bytes).
  float32x4(bytesPerElement: 16, componentCount: 4),

  /// One 32-bit unsigned integer (4 bytes).
  uint32(bytesPerElement: 4, componentCount: 1),

  /// Two 32-bit unsigned integers (8 bytes).
  uint32x2(bytesPerElement: 8, componentCount: 2),

  /// Three 32-bit unsigned integers (12 bytes).
  uint32x3(bytesPerElement: 12, componentCount: 3),

  /// Four 32-bit unsigned integers (16 bytes).
  uint32x4(bytesPerElement: 16, componentCount: 4),

  /// One 32-bit signed integer (4 bytes).
  sint32(bytesPerElement: 4, componentCount: 1),

  /// Two 32-bit signed integers (8 bytes).
  sint32x2(bytesPerElement: 8, componentCount: 2),

  /// Three 32-bit signed integers (12 bytes).
  sint32x3(bytesPerElement: 12, componentCount: 3),

  /// Four 32-bit signed integers (16 bytes).
  sint32x4(bytesPerElement: 16, componentCount: 4);

  const VertexFormat({
    required this.bytesPerElement,
    required this.componentCount,
  });

  /// Total size in bytes of a single attribute element of this format.
  final int bytesPerElement;

  /// Number of scalar components in a single attribute element.
  final int componentCount;
}

/// Controls how a [VertexBuffer] advances through its elements while drawing.
///
/// The step mode is a property of the buffer slot, not of an individual
/// attribute. All attributes in the same [VertexBuffer] advance together.
enum VertexStepMode {
  /// Advance to the next buffer element for each vertex.
  ///
  /// This is the default mode and is appropriate for ordinary mesh data such
  /// as positions, normals, texture coordinates, and vertex colors. During an
  /// instanced draw, a vertex-rate buffer supplies the same sequence of vertex
  /// elements to every instance.
  vertex,

  /// Advance to the next buffer element for each instance.
  ///
  /// Use this for per-instance data such as an object offset, transform, or
  /// tint color. During a draw with `instanceCount: n`, the first instance
  /// reads element 0 from this buffer, the second instance reads element 1,
  /// and so on.
  instance,
}

/// Describes a single vertex attribute: which shader input it feeds (by name),
/// its byte offset within the owning vertex buffer's element, and its format.
///
/// The [name] must exactly match an `in` (or equivalent stage input)
/// declaration in the bound vertex shader. Looking the attribute up by name
/// (rather than by raw location index) keeps Dart-side layouts robust to
/// shader source edits, mirroring how uniform bindings are resolved by name
/// via `Shader.getUniformSlot`.
///
/// Two attributes within the same [VertexBuffer] must not occupy overlapping
/// byte ranges (i.e. `[offsetInBytes, offsetInBytes + format.bytesPerElement)`
/// ranges must be disjoint across the buffer's attributes).
final class VertexAttribute {
  /// Creates a vertex attribute description bound to the shader-side input
  /// named [name], reading its data in the given [format] starting at byte
  /// [offsetInBytes] into each element of the owning vertex buffer.
  const VertexAttribute({
    required this.name,
    required this.format,
    this.offsetInBytes = 0,
  });

  /// Name of the shader-side input this attribute feeds (e.g. `position`).
  final String name;

  /// Format of each attribute element.
  final VertexFormat format;

  /// Byte offset of this attribute from the start of each element in the
  /// owning vertex buffer. Must satisfy
  /// `offsetInBytes + format.bytesPerElement <= VertexBuffer.strideInBytes`.
  ///
  /// Defaults to 0, which is the common case for a structure-of-arrays
  /// layout where each buffer holds exactly one attribute.
  final int offsetInBytes;
}

/// Describes one vertex buffer slot: its per-element stride, step mode, and
/// the attributes that are read from it.
///
/// A buffer's position in [VertexLayout.buffers] determines the binding
/// slot it is bound to via [RenderPass.bindVertexBuffer]; the first buffer
/// is slot 0, the second is slot 1, and so on. Sparse binding slots are
/// not currently supported.
///
/// The [stepMode] determines whether the buffer advances once per vertex or
/// once per instance. Keep the default [VertexStepMode.vertex] for mesh data
/// that describes the geometry being repeated. Use [VertexStepMode.instance]
/// for data that changes from one instance to the next when calling
/// [RenderPass.draw] or [RenderPass.drawIndexed] with an `instanceCount`
/// greater than 1.
// TODO(https://github.com/flutter/flutter/issues/186307): Add support for
// instance step rates greater than one.
// TODO(https://github.com/flutter/flutter/issues/186308): Allow sparse
// vertex buffer binding slots.
final class VertexBuffer {
  /// Creates a vertex buffer slot description with the given per-element
  /// [strideInBytes] and the list of [attributes] that the vertex shader
  /// reads from this buffer.
  const VertexBuffer({
    required this.strideInBytes,
    required this.attributes,
    this.stepMode = VertexStepMode.vertex,
  });

  /// Byte distance from the start of one element to the start of the next
  /// element in this vertex buffer (not the gap between an element's end and
  /// the next element's start). Equivalent to the size of a single vertex
  /// element plus any trailing padding before the next element begins. For a
  /// tightly packed structure-of-arrays buffer carrying a single attribute,
  /// this is the same as `attributes[0].format.bytesPerElement`.
  final int strideInBytes;

  /// Attributes read from this vertex buffer by the vertex shader.
  final List<VertexAttribute> attributes;

  /// How this vertex buffer advances while drawing.
  ///
  /// Defaults to [VertexStepMode.vertex]. Set this to
  /// [VertexStepMode.instance] when the buffer contains one element per
  /// instance rather than one element per vertex.
  final VertexStepMode stepMode;
}

/// A complete vertex input layout: zero or more vertex buffer slots and the
/// attributes that read from each one.
///
/// Pass an instance of this class to `GpuContext.createRenderPipeline` to
/// override the default interleaved layout that the shader bundle declares
/// (e.g. to bind position and color attributes from separate buffers, or to
/// consume a structure-of-arrays mesh without converting to interleaved
/// form on the CPU).
final class VertexLayout {
  /// Creates a vertex input layout that reads from the given [buffers].
  const VertexLayout({required this.buffers});

  /// Vertex buffer slots this layout uses. Each buffer's position in this
  /// list determines the binding slot it must be bound to via
  /// [RenderPass.bindVertexBuffer] before drawing.
  final List<VertexBuffer> buffers;
}

/// A reference to a byte range within a GPU-resident [Buffer].
class BufferView {
  /// The device buffer of this view.
  final DeviceBuffer buffer;

  /// The start of the view, in bytes starting from the beginning of the
  /// [buffer].
  final int offsetInBytes;

  /// The length of the view.
  final int lengthInBytes;

  /// Create a new view into a buffer on the GPU.
  const BufferView(
    this.buffer, {
    required this.offsetInBytes,
    required this.lengthInBytes,
  });
}

typedef CompletionCallback<T> = void Function(bool success);

/// A rectangular region within a [Texture].
///
/// [width] and [height] default to the full size of [texture] at [mipLevel].
/// Buffer-to-texture and texture-to-buffer copies use tightly packed rows; the
/// copied byte count is rounded up to whole pixel-format blocks.
base class TextureRegion {
  const TextureRegion(
    this.texture, {
    this.x = 0,
    this.y = 0,
    this.width = -1,
    this.height = -1,
    this.mipLevel = 0,
    this.slice = 0,
  });

  final Texture texture;
  final int x;
  final int y;
  final int width;
  final int height;
  final int mipLevel;
  final int slice;
}

/// The upper-left destination of a texture-to-texture copy.
base class TextureDestinationRegion {
  const TextureDestinationRegion(
    this.texture, {
    this.x = 0,
    this.y = 0,
    this.mipLevel = 0,
    this.slice = 0,
  });

  final Texture texture;
  final int x;
  final int y;
  final int mipLevel;
  final int slice;
}

base class ColorAttachment {
  ColorAttachment({
    this.loadAction = LoadAction.clear,
    this.storeAction = StoreAction.store,
    vm.Vector4? clearValue = null,
    required this.texture,
    this.resolveTexture = null,
    this.mipLevel = 0,
    this.slice = 0,
  }) : clearValue = clearValue ?? vm.Vector4.zero();

  LoadAction loadAction;
  StoreAction storeAction;
  vm.Vector4 clearValue;

  Texture texture;
  Texture? resolveTexture;

  /// The mip level of [texture] to render into. Must be in the range
  /// `[0, texture.mipLevelCount)`.
  ///
  /// Rendering into a non-zero mip level is supported on Metal and Vulkan but
  /// not currently on the GLES backend. See
  /// [GpuContext.doesSupportFramebufferRenderMipmap].
  int mipLevel;

  /// The slice of [texture] to render into. For cubemap textures this selects
  /// the face in the order `+X, -X, +Y, -Y, +Z, -Z`; for 2D array textures it
  /// selects the layer. Must be in the range `[0, texture.sliceCount)`
  /// (always 0 for other texture types).
  int slice;
}

base class DepthStencilAttachment {
  DepthStencilAttachment({
    this.depthLoadAction = LoadAction.clear,
    this.depthStoreAction = StoreAction.dontCare,
    this.depthClearValue = 0.0,
    this.stencilLoadAction = LoadAction.clear,
    this.stencilStoreAction = StoreAction.dontCare,
    this.stencilClearValue = 0,
    required this.texture,
    this.mipLevel = 0,
    this.slice = 0,
  });

  LoadAction depthLoadAction;
  StoreAction depthStoreAction;
  double depthClearValue;

  LoadAction stencilLoadAction;
  StoreAction stencilStoreAction;
  int stencilClearValue;

  Texture texture;

  /// The mip level of [texture] to render into. Must match the mip level of
  /// the color attachments so all attachments share the same size. See
  /// [ColorAttachment.mipLevel].
  int mipLevel;

  /// The slice of [texture] to render into. See [ColorAttachment.slice].
  int slice;
}

base class StencilConfig {
  StencilConfig({
    this.compareFunction = CompareFunction.always,
    this.stencilFailureOperation = StencilOperation.keep,
    this.depthFailureOperation = StencilOperation.keep,
    this.depthStencilPassOperation = StencilOperation.keep,
    this.readMask = 0xFFFFFFFF,
    this.writeMask = 0xFFFFFFFF,
  });

  CompareFunction compareFunction;
  StencilOperation stencilFailureOperation;
  StencilOperation depthFailureOperation;
  StencilOperation depthStencilPassOperation;
  int readMask;
  int writeMask;
}

enum StencilFace { both, front, back }

base class ColorBlendEquation {
  ColorBlendEquation({
    this.colorBlendOperation = BlendOperation.add,
    this.sourceColorBlendFactor = BlendFactor.one,
    this.destinationColorBlendFactor = BlendFactor.oneMinusSourceAlpha,
    this.alphaBlendOperation = BlendOperation.add,
    this.sourceAlphaBlendFactor = BlendFactor.one,
    this.destinationAlphaBlendFactor = BlendFactor.oneMinusSourceAlpha,
  });

  BlendOperation colorBlendOperation;
  BlendFactor sourceColorBlendFactor;
  BlendFactor destinationColorBlendFactor;

  BlendOperation alphaBlendOperation;
  BlendFactor sourceAlphaBlendFactor;
  BlendFactor destinationAlphaBlendFactor;
}

base class SamplerOptions {
  SamplerOptions({
    this.minFilter = MinMagFilter.nearest,
    this.magFilter = MinMagFilter.nearest,
    this.mipFilter = MipFilter.nearest,
    this.widthAddressMode = SamplerAddressMode.clampToEdge,
    this.heightAddressMode = SamplerAddressMode.clampToEdge,
    this.maxAnisotropy = 1,
  });

  MinMagFilter minFilter;
  MinMagFilter magFilter;
  MipFilter mipFilter;
  SamplerAddressMode widthAddressMode;
  SamplerAddressMode heightAddressMode;

  /// The maximum anisotropy clamp used when sampling. The default value of 1
  /// disables anisotropic filtering.
  ///
  /// When greater than 1, [minFilter], [magFilter], and [mipFilter] must all
  /// be linear. Values beyond [GpuContext.maxSamplerAnisotropy] are clamped
  /// to it, and a maximum of 1 means the device does not support anisotropic
  /// filtering.
  ///
  /// Anisotropic filtering samples across the mip chain, so populate mip
  /// levels (via [Texture.overwrite] or by rendering into them) to get the
  /// full quality benefit.
  int maxAnisotropy;
}

base class Scissor {
  Scissor({this.x = 0, this.y = 0, this.width = 0, this.height = 0});

  int x, y, width, height;
}

base class DepthRange {
  DepthRange({this.zNear = 0.0, this.zFar = 1.0});

  double zNear;
  double zFar;
}

base class Viewport {
  Viewport({
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    DepthRange? depthRange = null,
  }) : this.depthRange = depthRange ?? DepthRange();

  int x, y, width, height;
  DepthRange depthRange;
}

base class RenderTarget {
  const RenderTarget({
    this.colorAttachments = const <ColorAttachment>[],
    this.depthStencilAttachment,
  });

  RenderTarget.singleColor(
    ColorAttachment colorAttachment, {
    DepthStencilAttachment? depthStencilAttachment,
  }) : this(
         colorAttachments: [colorAttachment],
         depthStencilAttachment: depthStencilAttachment,
       );

  final List<ColorAttachment> colorAttachments;
  final DepthStencilAttachment? depthStencilAttachment;
}

/// The result of presenting a [GpuSurfaceFrame].
///
/// Image surfaces always report [success]. The other values exist for
/// destinations whose presentation can fail or require reconfiguration, so that
/// one calling pattern is correct for every surface type.
enum GpuPresentStatus {
  /// The frame was presented and no reconfiguration is needed.
  success,

  /// The frame was presented, but the surface should be reconfigured before the
  /// next frame.
  suboptimal,

  /// The surface is out of date and must be reconfigured before presenting
  /// again.
  outOfDate,
}

base class TextureBinding {
  const TextureBinding(this.texture, {this.sampler});

  /// The texture to read.
  final Texture texture;

  /// The sampler to read [texture] with. Defaults to the same nearest
  /// filtering and clamped addressing as [RenderPass.bindTexture] when null.
  final SamplerOptions? sampler;
}

abstract interface class BindingSet {}

abstract interface class DeviceBuffer {
  dynamic get isValid;
  StorageMode get storageMode;
  int get sizeInBytes;
  bool overwrite(ByteData sourceBytes, {int destinationOffsetInBytes = 0});
  void flush({int offsetInBytes = 0, int lengthInBytes = -1});
}

abstract interface class HostBuffer {
  static const int kDefaultBlockLengthInBytes = 1024000;
  int get blockLengthInBytes;
  int get frameCount;
  BufferView emplace(ByteData bytes);
  void reset();
}

abstract class Texture {
  dynamic get isValid;
  static int fullMipCount(int width, int height) {
    if (width < 1 || height < 1) {
      return 1;
    }
    final int smallest = width < height ? width : height;
    final int count = smallest.bitLength - 1;
    return count > 0 ? count : 1;
  }
  static Texture fromImage(GpuContext gpuContext, ui.Image image) =>
      throw UnsupportedError(_noGpu);
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
  int get layerCount;
  int get sliceCount;
  int getMipLevelWidth(int mipLevel);
  int getMipLevelHeight(int mipLevel);
  int getMipLevelSizeInBytes(int mipLevel);
  int getBaseMipLevelSizeInBytes();
  void overwrite(ByteData sourceBytes, {int mipLevel = 0, int slice = 0});
  ui.Image asImage();
}

abstract interface class Shader {
  UniformSlot getUniformSlot(String uniformName);
  bool get debugIsDirty;
}

abstract interface class UniformSlot {
  Shader get shader;
  String get uniformName;
  int? get sizeInBytes;
  int? getMemberOffsetInBytes(String memberName);
}

abstract class ShaderLibrary {
  static Future<ShaderLibrary?> fromAsset(String assetName) async =>
      throw UnsupportedError(_noGpu);
  static Future<ShaderLibrary?> fromBytes(ByteData bytes) async =>
      throw UnsupportedError(_noGpu);
  Map<String, Shader?> get shaders_;
  Shader? operator [](String shaderName);
  static void reinitialize(String assetKey) => throw UnsupportedError(_noGpu);
  String? debugReinitializeFromAsset(String assetName);
  String? reinitializeFromBytes(ByteData bytes);
}

abstract interface class RenderPipeline {
  Shader get vertexShader;
  Shader get fragmentShader;
}

abstract interface class CommandBuffer {
  bool get submitted;
  RenderPass createRenderPass(RenderTarget renderTarget);
  void copyBufferToTexture(BufferView source, TextureRegion destination);
  void copyTextureToBuffer(TextureRegion source, BufferView destination);
  void copyTextureToTexture(
    TextureRegion source,
    TextureDestinationRegion destination,
  );
  void submit({CompletionCallback? completionCallback});
}

abstract interface class RenderPass {
  static const int maxBindingSets = 4;
  void bindPipeline(RenderPipeline pipeline);
  void bindVertexBuffer(BufferView bufferView, {int slot = 0});
  void bindIndexBuffer(BufferView bufferView, IndexType indexType);
  void bindUniform(UniformSlot slot, BufferView bufferView);
  void bindTexture(
    UniformSlot slot,
    Texture texture, {
    SamplerOptions? sampler,
  });
  void bindSet(BindingSet bindingSet, {int slot = 0});
  void clearBindings();
  void setColorBlendEnable(bool enable, {int colorAttachmentIndex = 0});
  void setColorBlendEquation(
    ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  });
  void setDepthWriteEnable(bool enable);
  void setViewport(Viewport viewport);
  void setDepthCompareOperation(CompareFunction compareFunction);
  void setStencilReference(int referenceValue);
  void setStencilConfig(
    StencilConfig configuration, {
    StencilFace targetFace = StencilFace.both,
  });
  void setScissor(Scissor scissor);
  void setCullMode(CullMode cullMode);
  void setPolygonMode(PolygonMode polygonMode);
  void setPrimitiveType(PrimitiveType primitiveType);
  void setWindingOrder(WindingOrder windingOrder);
  void draw(int vertexCount, {int instanceCount = 1});
  void drawIndexed(int indexCount, {int instanceCount = 1});
}

abstract interface class GpuContext {
  PixelFormat get defaultColorFormat;
  PixelFormat get defaultStencilFormat;
  PixelFormat get defaultDepthStencilFormat;
  int get minimumUniformByteAlignment;
  bool get doesSupportOffscreenMSAA;
  bool get doesSupportFramebufferRenderMipmap;
  bool get doesSupportManuallyMippedTextures;
  bool get doesSupportTextureArrays;
  int get maxSamplerAnisotropy;
  bool supportsTextureCompression(TextureCompressionFamily family);
  bool supportsTextureFormat(
    PixelFormat format, {
    bool renderTarget = false,
    bool shaderRead = true,
    bool shaderWrite = false,
  });
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
    sampleCount = 1,
    TextureType? textureType,
    bool enableRenderTargetUsage = true,
    bool enableShaderReadUsage = true,
    bool enableShaderWriteUsage = false,
    int mipLevelCount = 1,
    int layerCount = 1,
  });
  GpuImageSurface createImageSurface(
    int width,
    int height, {
    PixelFormat? format,
  });
  CommandBuffer createCommandBuffer();
  BindingSet createBindingSet({
    Map<UniformSlot, BufferView> uniforms = const <UniformSlot, BufferView>{},
    Map<UniformSlot, TextureBinding> textures =
        const <UniformSlot, TextureBinding>{},
  });
  RenderPipeline createRenderPipeline(
    Shader vertexShader,
    Shader fragmentShader, {
    VertexLayout? vertexLayout,
  });
}

abstract interface class GpuImageSurface {
  int get width;
  int get height;
  PixelFormat get format;
  int get debugBackingTextureCount;
  ui.Image? get currentImage;
  void resize(int width, int height);
  GpuImageSurfaceFrame acquireNextFrame();
}

abstract interface class GpuImageSurfaceFrame {
  Texture get colorTexture;
  GpuPresentStatus present(CommandBuffer commandBuffer);
  void discard();
}

const _noGpu = 'Flutter GPU (Impeller) does not run on the web';

/// Flutter GPU does not run on the web.
GpuContext get gpuContext => throw UnsupportedError(_noGpu);
