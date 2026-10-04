import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What a texture's pixels represent, which controls how mip levels are
/// downsampled so the result is correct (color must average in linear light,
/// normals must be averaged as vectors and renormalized).
///
/// {@category Assets and loading}
enum TextureContent {
  /// sRGB-encoded color (albedo, emissive). Averaged in linear light.
  color,

  /// Linear data (metallic-roughness, ambient occlusion). Averaged directly.
  data,

  /// A tangent-space normal map. Averaged as vectors and renormalized.
  normal,
}

/// The [TextureContent] named [name] (a serialized `TextureResource.content`),
/// falling back to [TextureContent.color] for an unknown name.
TextureContent textureContentFromName(String name) => switch (name) {
  'data' => TextureContent.data,
  'normal' => TextureContent.normal,
  _ => TextureContent.color,
};

/// One mip level's RGBA8888 pixels.
class MipLevel {
  MipLevel(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Builds the full mip chain (level 0 first) for RGBA8888 [pixels] of [width] x
/// [height], downsampling with a 2x2 box filter appropriate for [content].
///
/// Each level halves the previous (floored, min 1) until 1x1. The result is
/// suitable for uploading level by level to a mipmapped texture. Level 0 is
/// [pixels] itself, not a copy.
///
/// Color converts sRGB to linear light and back through lookup tables, and
/// holds the bytes the exact `pow` conversion gives for every input.
List<MipLevel> generateMipChain(
  Uint8List pixels,
  int width,
  int height,
  TextureContent content,
) {
  _mipChainsBuilt++;
  return _chain(
    pixels,
    width,
    height,
    (src, sw, sh, dw, dh) => _downsample(src, sw, sh, dw, dh, content),
  );
}

/// The color chain [generateMipChain] builds, converted with `pow` per
/// channel per texel instead of through tables: the reference the table
/// chain's bytes are held to.
@visibleForTesting
List<MipLevel> generateColorMipChainWithPow(
  Uint8List pixels,
  int width,
  int height,
) => _chain(pixels, width, height, (src, sw, sh, dw, dh) {
  final dst = Uint8List(dw * dh * 4);
  _downsampleColorWithPow(src, sw, sh, dw, dh, dst);
  return dst;
});

List<MipLevel> _chain(
  Uint8List pixels,
  int width,
  int height,
  Uint8List Function(Uint8List src, int sw, int sh, int dw, int dh) downsample,
) {
  final levels = <MipLevel>[MipLevel(width, height, pixels)];
  var w = width;
  var h = height;
  var src = pixels;
  while (w > 1 || h > 1) {
    final nw = math.max(1, w >> 1);
    final nh = math.max(1, h >> 1);
    final dst = downsample(src, w, h, nw, nh);
    levels.add(MipLevel(nw, nh, dst));
    src = dst;
    w = nw;
    h = nh;
  }
  return levels;
}

/// How many chains [generateMipChain] has built on the current isolate. Each
/// isolate counts its own, so a chain built on a background isolate leaves the
/// caller's count unchanged.
@visibleForTesting
int get mipChainsBuiltOnThisIsolate => _mipChainsBuilt;
int _mipChainsBuilt = 0;

/// The number of mip levels for a [width] x [height] texture.
int mipLevelCountFor(int width, int height) =>
    (math.log(math.max(width, height)) / math.ln2).floor() + 1;

Uint8List _downsample(
  Uint8List src,
  int sw,
  int sh,
  int dw,
  int dh,
  TextureContent content,
) {
  final dst = Uint8List(dw * dh * 4);
  // The content switch is hoisted out of the per-texel loop: a mip chain of a
  // 2048x2048 texture walks ~1.4 M destination texels, so anything left inside
  // is paid a million times over.
  switch (content) {
    case TextureContent.color:
      _downsampleColor(src, sw, sh, dw, dh, dst);
    case TextureContent.data:
      _downsampleData(src, sw, sh, dw, dh, dst);
    case TextureContent.normal:
      _downsampleNormal(src, sw, sh, dw, dh, dst);
  }
  return dst;
}

// The first of the two source coordinates a destination coordinate covers,
// clamped to the source extent for an odd-sized level.
@pragma('vm:prefer-inline')
int _clampDouble(int coordinate, int extent) {
  final doubled = coordinate * 2;
  return doubled < extent ? doubled : extent - 1;
}

// Both sRGB conversions read from tables (see [_srgbByteOfLinear]).
void _downsampleColor(
  Uint8List src,
  int sw,
  int sh,
  int dw,
  int dh,
  Uint8List dst,
) {
  for (var y = 0; y < dh; y++) {
    final y0 = _clampDouble(y, sh);
    final y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    final row0 = y0 * sw;
    final row1 = y1 * sw;
    for (var x = 0; x < dw; x++) {
      final x0 = _clampDouble(x, sw);
      final x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
      final a = (row0 + x0) * 4;
      final b = (row0 + x1) * 4;
      final c = (row1 + x0) * 4;
      final d = (row1 + x1) * 4;
      final o = (y * dw + x) * 4;
      for (var ch = 0; ch < 3; ch++) {
        final avg =
            (_linearOfByte[src[a + ch]] +
                _linearOfByte[src[b + ch]] +
                _linearOfByte[src[c + ch]] +
                _linearOfByte[src[d + ch]]) *
            0.25;
        dst[o + ch] = _srgbByteOfLinear(avg);
      }
      dst[o + 3] =
          ((src[a + 3] + src[b + 3] + src[c + 3] + src[d + 3]) + 2) ~/ 4;
    }
  }
}

// The reference [_downsampleColor] is held to: the encode through `pow`.
void _downsampleColorWithPow(
  Uint8List src,
  int sw,
  int sh,
  int dw,
  int dh,
  Uint8List dst,
) {
  for (var y = 0; y < dh; y++) {
    final y0 = _clampDouble(y, sh);
    final y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    final row0 = y0 * sw;
    final row1 = y1 * sw;
    for (var x = 0; x < dw; x++) {
      final x0 = _clampDouble(x, sw);
      final x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
      final a = (row0 + x0) * 4;
      final b = (row0 + x1) * 4;
      final c = (row1 + x0) * 4;
      final d = (row1 + x1) * 4;
      final o = (y * dw + x) * 4;
      for (var ch = 0; ch < 3; ch++) {
        final avg =
            (_linearOfByte[src[a + ch]] +
                _linearOfByte[src[b + ch]] +
                _linearOfByte[src[c + ch]] +
                _linearOfByte[src[d + ch]]) *
            0.25;
        dst[o + ch] = _linearToSrgb(avg);
      }
      dst[o + 3] =
          ((src[a + 3] + src[b + 3] + src[c + 3] + src[d + 3]) + 2) ~/ 4;
    }
  }
}

void _downsampleData(
  Uint8List src,
  int sw,
  int sh,
  int dw,
  int dh,
  Uint8List dst,
) {
  for (var y = 0; y < dh; y++) {
    final y0 = _clampDouble(y, sh);
    final y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    final row0 = y0 * sw;
    final row1 = y1 * sw;
    for (var x = 0; x < dw; x++) {
      final x0 = _clampDouble(x, sw);
      final x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
      final a = (row0 + x0) * 4;
      final b = (row0 + x1) * 4;
      final c = (row1 + x0) * 4;
      final d = (row1 + x1) * 4;
      final o = (y * dw + x) * 4;
      for (var ch = 0; ch < 4; ch++) {
        dst[o + ch] =
            ((src[a + ch] + src[b + ch] + src[c + ch] + src[d + ch]) + 2) ~/ 4;
      }
    }
  }
}

void _downsampleNormal(
  Uint8List src,
  int sw,
  int sh,
  int dw,
  int dh,
  Uint8List dst,
) {
  for (var y = 0; y < dh; y++) {
    final y0 = _clampDouble(y, sh);
    final y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    final row0 = y0 * sw;
    final row1 = y1 * sw;
    for (var x = 0; x < dw; x++) {
      final x0 = _clampDouble(x, sw);
      final x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
      final a = (row0 + x0) * 4;
      final b = (row0 + x1) * 4;
      final c = (row1 + x0) * 4;
      final d = (row1 + x1) * 4;
      final o = (y * dw + x) * 4;
      // Unrolled: the `for (final p in [a, b, c, d])` this replaces allocated a
      // four-element list per destination texel.
      var nx = src[a] / 127.5 - 1.0;
      var ny = src[a + 1] / 127.5 - 1.0;
      var nz = src[a + 2] / 127.5 - 1.0;
      nx += src[b] / 127.5 - 1.0;
      ny += src[b + 1] / 127.5 - 1.0;
      nz += src[b + 2] / 127.5 - 1.0;
      nx += src[c] / 127.5 - 1.0;
      ny += src[c + 1] / 127.5 - 1.0;
      nz += src[c + 2] / 127.5 - 1.0;
      nx += src[d] / 127.5 - 1.0;
      ny += src[d + 1] / 127.5 - 1.0;
      nz += src[d + 2] / 127.5 - 1.0;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-6) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        nx = 0.0;
        ny = 0.0;
        nz = 1.0;
      }
      dst[o] = _encodeUnit(nx);
      dst[o + 1] = _encodeUnit(ny);
      dst[o + 2] = _encodeUnit(nz);
      dst[o + 3] = 255;
    }
  }
}

// The sRGB byte of a linear value: a bucket table gives the byte at or below
// it, the rounding edges walk it up, and a value within a relative 1e-9 of an
// edge falls back to [_linearToSrgb], so the result is always its byte.
int _srgbByteOfLinear(double linear) {
  final edge = _linearAtByteEdge;
  var byte = _byteBelowBucket[(linear * _buckets).toInt()];
  while (byte < 255 && linear >= edge[byte + 1]) {
    byte++;
  }
  if ((byte > 0 && linear <= _linearJustAboveEdge[byte]) ||
      (byte < 255 && linear >= _linearJustBelowEdge[byte + 1])) {
    return _linearToSrgb(linear);
  }
  return byte;
}

/// The linear values bounding the band around each sRGB rounding edge where
/// the table chain falls back to `pow`: entry `byte - 1` holds the band below
/// and above the edge between `byte - 1` and `byte`.
@visibleForTesting
List<({double below, double above})> get srgbEdgeFallbackBands => [
  for (var byte = 1; byte < 256; byte++)
    (below: _linearJustBelowEdge[byte], above: _linearJustAboveEdge[byte]),
];

/// The sRGB byte of [linear] through `pow`, the conversion the table chain's
/// bytes are held to.
@visibleForTesting
int srgbByteOfLinearWithPow(double linear) => _linearToSrgb(linear);

const double _edgeMargin = 1e-9;

const int _buckets = 4096;

// The linear value of each sRGB byte, exactly what [_srgbToLinear] returns.
final Float64List _linearOfByte = Float64List.fromList([
  for (var byte = 0; byte < 256; byte++) _srgbToLinear(byte),
]);

// The linear value of the sRGB rounding edge below each byte, (byte - 0.5) /
// 255; entry 0 is unused.
final Float64List _linearAtByteEdge = Float64List.fromList([
  0,
  for (var byte = 1; byte < 256; byte++) _linearOfSrgb((byte - 0.5) / 255.0),
]);

final Float64List _linearJustBelowEdge = _scaledEdges(1 - _edgeMargin);

final Float64List _linearJustAboveEdge = _scaledEdges(1 + _edgeMargin);

// The byte at or below the lowest linear value of each of [_buckets] equal
// buckets of [0, 1].
final Uint8List _byteBelowBucket = _buildByteBelowBucket();

Float64List _scaledEdges(double factor) => Float64List.fromList([
  0,
  for (var byte = 1; byte < 256; byte++) _linearAtByteEdge[byte] * factor,
]);

Uint8List _buildByteBelowBucket() {
  final edge = _linearAtByteEdge;
  final table = Uint8List(_buckets + 1);
  var byte = 0;
  for (var bucket = 0; bucket <= _buckets; bucket++) {
    final low = bucket / _buckets;
    while (byte < 255 && low >= edge[byte + 1]) {
      byte++;
    }
    table[bucket] = byte;
  }
  return table;
}

double _srgbToLinear(int byte) => _linearOfSrgb(byte / 255.0);

double _linearOfSrgb(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

int _linearToSrgb(double linear) {
  final c = linear <= 0.0031308
      ? linear * 12.92
      : 1.055 * math.pow(linear, 1 / 2.4).toDouble() - 0.055;
  return (c * 255.0).round().clamp(0, 255);
}

// Maps a [-1, 1] component to a [0, 255] byte.
int _encodeUnit(double v) => ((v + 1.0) * 127.5).round().clamp(0, 255);
