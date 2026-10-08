// Decodes ETC2 RGB8 and ETC2 RGBA8 (EAC alpha) blocks to rgba8, every mode
// the Khronos Data Format Specification 1.3 section 21.2 defines: the ETC1
// individual and differential modes, and the T, H and planar modes ETC2
// signals through an overflowing differential color. Pure data, no GPU; the
// transcode of a KTX 1 file to another block family decodes through it.

import 'dart:typed_data';

// ETC1 intensity modifiers, indexed [table][pixel index], where the pixel
// index is (msb << 1) | lsb.
const List<List<int>> _modifiers = [
  [2, 8, -2, -8],
  [5, 17, -5, -17],
  [9, 29, -9, -29],
  [13, 42, -13, -42],
  [18, 60, -18, -60],
  [24, 80, -24, -80],
  [33, 106, -33, -106],
  [47, 183, -47, -183],
];

// The T and H mode distances.
const List<int> _distances = [3, 6, 11, 16, 23, 32, 41, 64];

// EAC modifiers, indexed [table][pixel index].
const List<List<int>> _eacModifiers = [
  [-3, -6, -9, -15, 2, 5, 8, 14],
  [-3, -7, -10, -13, 2, 6, 9, 12],
  [-2, -5, -8, -13, 1, 4, 7, 12],
  [-2, -4, -6, -13, 1, 3, 5, 12],
  [-3, -6, -8, -12, 2, 5, 7, 11],
  [-3, -7, -9, -11, 2, 6, 8, 10],
  [-4, -7, -8, -11, 3, 6, 7, 10],
  [-3, -5, -8, -11, 2, 4, 7, 10],
  [-2, -6, -8, -10, 1, 5, 7, 9],
  [-2, -5, -8, -10, 1, 4, 7, 9],
  [-2, -4, -8, -10, 1, 3, 7, 9],
  [-2, -5, -7, -10, 1, 4, 6, 9],
  [-3, -4, -7, -10, 2, 3, 6, 9],
  [-1, -2, -3, -10, 0, 1, 2, 9],
  [-4, -6, -8, -9, 3, 5, 7, 8],
  [-3, -5, -7, -9, 2, 4, 6, 8],
];

int _clamp(int value) => value < 0 ? 0 : (value > 255 ? 255 : value);

int _bits(int word, int high, int low) =>
    (word >> low) & ((1 << (high - low + 1)) - 1);

int _expand4(int value) => (value << 4) | value;

int _expand5(int value) => (value << 3) | (value >> 2);

int _expand6(int value) => (value << 2) | (value >> 4);

int _expand7(int value) => (value << 1) | (value >> 6);

/// Decodes ETC2 RGB8 [blocks] of a [width] x [height] image to rgba8 with
/// opaque alpha. ETC1 blocks decode the same.
Uint8List decodeEtc2Rgb8(Uint8List blocks, int width, int height) {
  final out = Uint8List(width * height * 4);
  _decodeColor(blocks, 8, 0, width, height, out);
  return out;
}

/// Decodes ETC2 RGBA8 [blocks] (EAC alpha then ETC2 RGB8 a block) of a
/// [width] x [height] image to rgba8.
Uint8List decodeEtc2Rgba8(Uint8List blocks, int width, int height) {
  final out = Uint8List(width * height * 4);
  _decodeColor(blocks, 16, 8, width, height, out);
  _decodeEacAlpha(blocks, 16, width, height, out, 4, 3);
  return out;
}

/// The alpha of ETC2 RGBA8 [blocks] of a [width] x [height] image, one byte a
/// texel, decoded from the EAC alpha half of each block alone.
Uint8List decodeEtc2Alpha(Uint8List blocks, int width, int height) {
  final out = Uint8List(width * height);
  _decodeEacAlpha(blocks, 16, width, height, out, 1, 0);
  return out;
}

void _decodeColor(
  Uint8List blocks,
  int stride,
  int colorOffset,
  int width,
  int height,
  Uint8List out,
) {
  final blocksX = (width + 3) >> 2;
  final blocksY = (height + 3) >> 2;
  final paint = Int32List(4 * 3);
  final texels = Int32List(16 * 3);
  for (var by = 0; by < blocksY; by++) {
    for (var bx = 0; bx < blocksX; bx++) {
      final at = (by * blocksX + bx) * stride + colorOffset;
      final high =
          (blocks[at] << 24) |
          (blocks[at + 1] << 16) |
          (blocks[at + 2] << 8) |
          blocks[at + 3];
      final low =
          (blocks[at + 4] << 24) |
          (blocks[at + 5] << 16) |
          (blocks[at + 6] << 8) |
          blocks[at + 7];
      _decodeBlock(high, low, paint, texels);
      for (var y = 0; y < 4; y++) {
        final row = by * 4 + y;
        if (row >= height) break;
        for (var x = 0; x < 4; x++) {
          final column = bx * 4 + x;
          if (column >= width) break;
          final texel = (y * 4 + x) * 3;
          final dst = (row * width + column) * 4;
          out[dst] = texels[texel];
          out[dst + 1] = texels[texel + 1];
          out[dst + 2] = texels[texel + 2];
          out[dst + 3] = 255;
        }
      }
    }
  }
}

// Decodes one block into [texels], three channels a texel in row-major order.
// [high] holds bits 63 to 32 of the block and [low] bits 31 to 0.
void _decodeBlock(int high, int low, Int32List paint, Int32List texels) {
  final diff = _bits(high, 1, 1);
  if (diff == 0) {
    _decodeEtc1(
      high,
      low,
      _expand4(_bits(high, 31, 28)),
      _expand4(_bits(high, 23, 20)),
      _expand4(_bits(high, 15, 12)),
      _expand4(_bits(high, 27, 24)),
      _expand4(_bits(high, 19, 16)),
      _expand4(_bits(high, 11, 8)),
      texels,
    );
    return;
  }
  final r = _bits(high, 31, 27);
  final g = _bits(high, 23, 19);
  final b = _bits(high, 15, 11);
  final r2 = r + _signed3(_bits(high, 26, 24));
  final g2 = g + _signed3(_bits(high, 18, 16));
  final b2 = b + _signed3(_bits(high, 10, 8));
  if (r2 < 0 || r2 > 31) {
    _decodeT(high, low, paint, texels);
  } else if (g2 < 0 || g2 > 31) {
    _decodeH(high, low, paint, texels);
  } else if (b2 < 0 || b2 > 31) {
    _decodePlanar(high, low, texels);
  } else {
    _decodeEtc1(
      high,
      low,
      _expand5(r),
      _expand5(g),
      _expand5(b),
      _expand5(r2),
      _expand5(g2),
      _expand5(b2),
      texels,
    );
  }
}

int _signed3(int value) => value >= 4 ? value - 8 : value;

// A pixel's 2-bit index: its most significant bit in bits 31 to 16 of [low]
// and its least in bits 15 to 0, the pixels numbered down each column.
int _index(int low, int x, int y) {
  final p = x * 4 + y;
  return (((low >> (16 + p)) & 1) << 1) | ((low >> p) & 1);
}

void _decodeEtc1(
  int high,
  int low,
  int r1,
  int g1,
  int b1,
  int r2,
  int g2,
  int b2,
  Int32List texels,
) {
  final table1 = _modifiers[_bits(high, 7, 5)];
  final table2 = _modifiers[_bits(high, 4, 2)];
  final flip = _bits(high, 0, 0);
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final first = flip == 0 ? x < 2 : y < 2;
      final modifier = (first ? table1 : table2)[_index(low, x, y)];
      final texel = (y * 4 + x) * 3;
      texels[texel] = _clamp((first ? r1 : r2) + modifier);
      texels[texel + 1] = _clamp((first ? g1 : g2) + modifier);
      texels[texel + 2] = _clamp((first ? b1 : b2) + modifier);
    }
  }
}

void _setPaint(Int32List paint, int index, int r, int g, int b) {
  paint[index * 3] = _clamp(r);
  paint[index * 3 + 1] = _clamp(g);
  paint[index * 3 + 2] = _clamp(b);
}

void _paintTexels(int low, Int32List paint, Int32List texels) {
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final color = _index(low, x, y) * 3;
      final texel = (y * 4 + x) * 3;
      texels[texel] = paint[color];
      texels[texel + 1] = paint[color + 1];
      texels[texel + 2] = paint[color + 2];
    }
  }
}

void _decodeT(int high, int low, Int32List paint, Int32List texels) {
  final r1 = _expand4((_bits(high, 28, 27) << 2) | _bits(high, 25, 24));
  final g1 = _expand4(_bits(high, 23, 20));
  final b1 = _expand4(_bits(high, 19, 16));
  final r2 = _expand4(_bits(high, 15, 12));
  final g2 = _expand4(_bits(high, 11, 8));
  final b2 = _expand4(_bits(high, 7, 4));
  final d = _distances[(_bits(high, 3, 2) << 1) | _bits(high, 0, 0)];
  _setPaint(paint, 0, r1, g1, b1);
  _setPaint(paint, 1, r2 + d, g2 + d, b2 + d);
  _setPaint(paint, 2, r2, g2, b2);
  _setPaint(paint, 3, r2 - d, g2 - d, b2 - d);
  _paintTexels(low, paint, texels);
}

void _decodeH(int high, int low, Int32List paint, Int32List texels) {
  final r1 = _bits(high, 30, 27);
  final g1 = (_bits(high, 26, 24) << 1) | _bits(high, 20, 20);
  final b1 = (_bits(high, 19, 19) << 3) | _bits(high, 17, 15);
  final r2 = _bits(high, 14, 11);
  final g2 = _bits(high, 10, 7);
  final b2 = _bits(high, 6, 3);
  final first = (r1 << 8) | (g1 << 4) | b1;
  final second = (r2 << 8) | (g2 << 4) | b2;
  final d =
      _distances[(_bits(high, 2, 2) << 2) |
          (_bits(high, 0, 0) << 1) |
          (first >= second ? 1 : 0)];
  final (er1, eg1, eb1) = (_expand4(r1), _expand4(g1), _expand4(b1));
  final (er2, eg2, eb2) = (_expand4(r2), _expand4(g2), _expand4(b2));
  _setPaint(paint, 0, er1 + d, eg1 + d, eb1 + d);
  _setPaint(paint, 1, er1 - d, eg1 - d, eb1 - d);
  _setPaint(paint, 2, er2 + d, eg2 + d, eb2 + d);
  _setPaint(paint, 3, er2 - d, eg2 - d, eb2 - d);
  _paintTexels(low, paint, texels);
}

void _decodePlanar(int high, int low, Int32List texels) {
  final ro = _expand6(_bits(high, 30, 25));
  final go = _expand7((_bits(high, 24, 24) << 6) | _bits(high, 22, 17));
  final bo = _expand6(
    (_bits(high, 16, 16) << 5) | (_bits(high, 12, 11) << 3) | _bits(high, 9, 7),
  );
  final rh = _expand6((_bits(high, 6, 2) << 1) | _bits(high, 0, 0));
  final gh = _expand7(_bits(low, 31, 25));
  final bh = _expand6(_bits(low, 24, 19));
  final rv = _expand6(_bits(low, 18, 13));
  final gv = _expand7(_bits(low, 12, 6));
  final bv = _expand6(_bits(low, 5, 0));
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final texel = (y * 4 + x) * 3;
      texels[texel] = _clamp((x * (rh - ro) + y * (rv - ro) + 4 * ro + 2) >> 2);
      texels[texel + 1] = _clamp(
        (x * (gh - go) + y * (gv - go) + 4 * go + 2) >> 2,
      );
      texels[texel + 2] = _clamp(
        (x * (bh - bo) + y * (bv - bo) + 4 * bo + 2) >> 2,
      );
    }
  }
}

void _decodeEacAlpha(
  Uint8List blocks,
  int stride,
  int width,
  int height,
  Uint8List out,
  int texelBytes,
  int channel,
) {
  final blocksX = (width + 3) >> 2;
  final blocksY = (height + 3) >> 2;
  for (var by = 0; by < blocksY; by++) {
    for (var bx = 0; bx < blocksX; bx++) {
      final at = (by * blocksX + bx) * stride;
      final base = blocks[at];
      final multiplier = blocks[at + 1] >> 4;
      final table = _eacModifiers[blocks[at + 1] & 0xF];
      // The 48 index bits as two 24-bit halves, so no shift passes 32 bits
      // on the web; no pixel's three bits straddle the halves.
      final upper =
          (blocks[at + 2] << 16) | (blocks[at + 3] << 8) | blocks[at + 4];
      final lower =
          (blocks[at + 5] << 16) | (blocks[at + 6] << 8) | blocks[at + 7];
      for (var p = 0; p < 16; p++) {
        // Pixel p, numbered down each column, holds bits 47 - 3p to 45 - 3p.
        final bit = 45 - 3 * p;
        final index = bit >= 24
            ? (upper >> (bit - 24)) & 7
            : (lower >> bit) & 7;
        final x = p >> 2;
        final y = p & 3;
        final column = bx * 4 + x;
        final row = by * 4 + y;
        if (column >= width || row >= height) continue;
        out[(row * width + column) * texelBytes + channel] = _clamp(
          base + table[index] * multiplier,
        );
      }
    }
  }
}
