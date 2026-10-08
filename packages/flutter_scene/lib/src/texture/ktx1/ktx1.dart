// Reads KTX 1 files (https://registry.khronos.org/KTX/specs/1.0/ktxspec.v1.html)
// that carry ETC1 or ETC2 blocks, the container an Indexed 3D Scene layer
// publishes as its `ktx-etc2` texture format. Pure data, no GPU.

import 'dart:typed_data';

/// The 12-byte KTX 1 file identifier: `«KTX 11»\r\n\x1A\n`.
const List<int> ktx1Identifier = <int>[
  0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A, //
];

/// `GL_ETC1_RGB8_OES`.
const int glEtc1Rgb8 = 0x8D64;

/// `GL_COMPRESSED_RGB8_ETC2`.
const int glEtc2Rgb8 = 0x9274;

/// `GL_COMPRESSED_SRGB8_ETC2`.
const int glEtc2Srgb8 = 0x9275;

/// `GL_COMPRESSED_RGBA8_ETC2_EAC`.
const int glEtc2Rgba8 = 0x9278;

/// `GL_COMPRESSED_SRGB8_ALPHA8_ETC2_EAC`.
const int glEtc2Srgb8Alpha8 = 0x9279;

/// The ETC block layout of a KTX 1 file.
enum Ktx1EtcFormat {
  /// ETC2 RGB8 (ETC1 is its subset), 8 bytes a block.
  rgb8(8, hasAlpha: false),

  /// ETC2 RGBA8: an 8-byte EAC alpha block, then an 8-byte RGB8 block.
  rgba8(16, hasAlpha: true);

  const Ktx1EtcFormat(this.bytesPerBlock, {required this.hasAlpha});

  /// Bytes one 4x4 block occupies.
  final int bytesPerBlock;

  /// Whether the blocks carry alpha.
  final bool hasAlpha;
}

/// A KTX 1 file of ETC blocks: its base size and its stored mip levels, base
/// first, each the blocks of that level in row-major block order.
class Ktx1EtcTexture {
  Ktx1EtcTexture({
    required this.format,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.levels,
  });

  final Ktx1EtcFormat format;
  final int pixelWidth;
  final int pixelHeight;
  final List<Uint8List> levels;
}

/// Whether [bytes] start with the KTX 1 file identifier.
bool looksLikeKtx1(Uint8List bytes) {
  if (bytes.length < ktx1Identifier.length) return false;
  for (var i = 0; i < ktx1Identifier.length; i++) {
    if (bytes[i] != ktx1Identifier[i]) return false;
  }
  return true;
}

const int _headerBytes = 64;

const int _sameEndian = 0x04030201;

const int _swappedEndian = 0x01020304;

/// Reads a 2D KTX 1 file of ETC1 or ETC2 blocks. A cube map, an array, a 3D
/// texture, another internal format, or a level shorter than its blocks is a
/// [FormatException] naming it.
Ktx1EtcTexture readKtx1Etc(Uint8List bytes) {
  if (!looksLikeKtx1(bytes) || bytes.length < _headerBytes) {
    throw const FormatException('Not a KTX 1 file');
  }
  final data = ByteData.sublistView(bytes);
  final Endian endian = switch (data.getUint32(12, Endian.little)) {
    _sameEndian => Endian.little,
    _swappedEndian => Endian.big,
    final other => throw FormatException(
      'KTX 1 endianness 0x${other.toRadixString(16)} is not 0x04030201',
    ),
  };
  int field(int index) => data.getUint32(16 + index * 4, endian);
  final internalFormat = field(3);
  final width = field(5);
  final height = field(6);
  final depth = field(7);
  final arrayElements = field(8);
  final faces = field(9);
  final mipLevels = field(10);
  final keyValueBytes = field(11);
  final format = switch (internalFormat) {
    glEtc1Rgb8 || glEtc2Rgb8 || glEtc2Srgb8 => Ktx1EtcFormat.rgb8,
    glEtc2Rgba8 || glEtc2Srgb8Alpha8 => Ktx1EtcFormat.rgba8,
    _ => throw FormatException(
      'KTX 1 internal format 0x${internalFormat.toRadixString(16)} is not '
      'ETC1, ETC2 RGB8 or ETC2 RGBA8',
    ),
  };
  if (depth > 1 || arrayElements > 0 || faces != 1) {
    throw const FormatException(
      'Only 2D KTX 1 textures with one face and no array are read',
    );
  }
  if (width < 1 || width > 16384 || height > 16384) {
    throw FormatException('Implausible KTX 1 dimensions ${width}x$height');
  }
  final baseHeight = height < 1 ? 1 : height;
  var offset = _headerBytes + keyValueBytes;
  final levels = <Uint8List>[];
  final count = mipLevels < 1 ? 1 : mipLevels;
  for (var level = 0; level < count; level++) {
    if (offset + 4 > bytes.length) {
      throw FormatException('KTX 1 level $level is missing');
    }
    final size = data.getUint32(offset, endian);
    offset += 4;
    final levelWidth = width >> level < 1 ? 1 : width >> level;
    final levelHeight = baseHeight >> level < 1 ? 1 : baseHeight >> level;
    final blocks = ((levelWidth + 3) >> 2) * ((levelHeight + 3) >> 2);
    final needed = blocks * format.bytesPerBlock;
    if (size < needed || offset + size > bytes.length) {
      throw FormatException(
        'KTX 1 level $level holds $size bytes, not the $needed its '
        '${levelWidth}x$levelHeight blocks take',
      );
    }
    levels.add(Uint8List.sublistView(bytes, offset, offset + needed));
    offset += (size + 3) & ~3;
  }
  return Ktx1EtcTexture(
    format: format,
    pixelWidth: width,
    pixelHeight: baseHeight,
    levels: levels,
  );
}
