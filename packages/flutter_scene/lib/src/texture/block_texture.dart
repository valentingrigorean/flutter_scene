// Transcodes a KTX texture to the block format a device samples, with its mip
// chain, as plain data that crosses an isolate boundary, and uploads it. The
// transcode is pure Dart, so an app runs it on a worker of its own and only
// the upload runs on the main thread.
//
// Sources: a KTX 1 file of ETC1 or ETC2 blocks, a standard KTX2 file
// (KHR_texture_basisu: Basis Universal ETC1S or UASTC, or RGBA8), and the
// engine's own KTX2 files.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/mip_sampling_probe.dart';
import 'package:flutter_scene/src/texture/basisu/basis_ktx2.dart';
import 'package:flutter_scene/src/texture/basisu/etc1s_targets.dart';
import 'package:flutter_scene/src/texture/block/decode_etc2.dart';
import 'package:flutter_scene/src/texture/block/transcode_astc.dart';
import 'package:flutter_scene/src/texture/block/transcode_bc1.dart';
import 'package:flutter_scene/src/texture/block/transcode_bc3.dart';
import 'package:flutter_scene/src/texture/block/transcode_etc2.dart';
import 'package:flutter_scene/src/texture/block/universal_block.dart';
import 'package:flutter_scene/src/texture/basisu/basis_ktx2_loader.dart';
import 'package:flutter_scene/src/texture/compressed_texture.dart';
import 'package:flutter_scene/src/texture/ktx1/ktx1.dart';
import 'package:flutter_scene/src/texture/ktx2/dfd.dart';
import 'package:flutter_scene/src/texture/ktx2/ktx2.dart';
import 'package:flutter_scene/src/texture/ktx2_image.dart';
import 'package:flutter_scene/src/texture/mipmap.dart';
import 'package:flutter_scene/src/texture/texture2d.dart';

/// The GPU format a [BlockTexture] uploads in.
enum BlockTextureFormat {
  /// Decoded pixels, for a device that samples no block family.
  rgba8(gpu.PixelFormat.r8g8b8a8UNormInt),

  /// ASTC 4x4 LDR, 16 bytes a block.
  astc4x4(gpu.PixelFormat.astc4x4LDR),

  /// ETC2 RGB8, 8 bytes a block.
  etc2Rgb8(gpu.PixelFormat.etc2RGB8UNormInt),

  /// ETC2 RGBA8 (EAC alpha), 16 bytes a block.
  etc2Rgba8(gpu.PixelFormat.etc2RGBA8UNormInt),

  /// BC1, 8 bytes a block.
  bc1(gpu.PixelFormat.bc1RGBAUNormInt),

  /// BC3, 16 bytes a block.
  bc3(gpu.PixelFormat.bc3RGBAUNormInt);

  const BlockTextureFormat(this.pixelFormat);

  /// The pixel format of the GPU texture.
  final gpu.PixelFormat pixelFormat;

  /// Bytes one 4x4 block takes, or four for a texel of [rgba8].
  int get _unitBytes => switch (this) {
    rgba8 => 4,
    etc2Rgb8 || bc1 => 8,
    astc4x4 || etc2Rgba8 || bc3 => 16,
  };

  /// Bytes a [width] x [height] level takes in this format.
  int levelBytes(int width, int height) => this == rgba8
      ? width * height * 4
      : ((width + 3) >> 2) * ((height + 3) >> 2) * _unitBytes;
}

/// What [transcodeKtxTexture] makes of a file, read from its header alone.
final class BlockTexturePlan {
  const BlockTexturePlan({
    required this.format,
    required this.width,
    required this.height,
    required this.levelCount,
    required this.hasAlpha,
  });

  final BlockTextureFormat format;
  final int width;
  final int height;

  /// The levels it uploads, base first: the stored chain, or a chain built
  /// from the base where the file stores the base alone.
  final int levelCount;

  /// Whether the texture carries alpha, as the file declares it.
  final bool hasAlpha;

  /// Bytes the levels take on the GPU.
  int get byteLength {
    var bytes = 0;
    for (var level = 0; level < levelCount; level++) {
      final size = mipSize(width, height, level);
      bytes += format.levelBytes(size.width, size.height);
    }
    return bytes;
  }
}

/// A texture transcoded for upload: [levels] in [format], base first. Plain
/// data, so it crosses an isolate boundary.
final class BlockTexture {
  const BlockTexture({required this.plan, required this.levels, this.alpha});

  final BlockTexturePlan plan;

  final List<Uint8List> levels;

  /// The alpha of the base level, one byte a texel, where the transcode was
  /// asked for it and the texture carries alpha.
  final Uint8List? alpha;

  BlockTextureFormat get format => plan.format;

  int get width => plan.width;

  int get height => plan.height;

  bool get hasAlpha => plan.hasAlpha;
}

/// Whether [bytes] start with a KTX 1 or KTX2 file identifier.
bool isKtxTexture(Uint8List bytes) =>
    looksLikeKtx1(bytes) || looksLikeKtx2(bytes);

/// The block families the current GPU context samples, most preferred first.
/// Must run on the main thread.
List<gpu.TextureCompressionFamily> blockTextureSupport() =>
    currentCompressionSupport();

/// Whether the current GPU context samples a mip chain a texture uploads by
/// hand. Must run on the main thread.
bool get blockTextureMips => uploadableMipChains;

enum _Kind { ktx1, uastc, etc1s, internal, rgba8 }

final class _Source {
  _Source._(
    this.kind,
    this.width,
    this.height,
    this.storedLevels,
    this.hasAlpha, {
    this.ktx1,
    this.ktx2,
  });

  factory _Source.of(Uint8List bytes) {
    if (looksLikeKtx1(bytes)) {
      final texture = readKtx1Etc(bytes);
      return _Source._(
        _Kind.ktx1,
        texture.pixelWidth,
        texture.pixelHeight,
        texture.levels.length,
        texture.format.hasAlpha,
        ktx1: texture,
      );
    }
    final texture = readKtx2(bytes);
    final width = texture.pixelWidth;
    final height = math.max(1, texture.pixelHeight);
    if (texture.faceCount != 1 ||
        texture.layerCount > 1 ||
        texture.pixelDepth > 1) {
      throw Ktx2FormatException('Only 2D non-array KTX2 textures are read');
    }
    if (width < 1 || width > 16384 || height > 16384) {
      throw Ktx2FormatException('Implausible dimensions ${width}x$height');
    }
    final levels = texture.levels.length;
    if (isInternalKtx2(texture)) {
      return _Source._(
        _Kind.internal,
        width,
        height,
        levels,
        ktx2HasAlpha(texture),
        ktx2: texture,
      );
    }
    final format = readDataFormat(texture);
    final kind = switch (format.colorModel) {
      kDfModelUastc => _Kind.uastc,
      kDfModelEtc1s => _Kind.etc1s,
      _ => _Kind.rgba8,
    };
    return _Source._(
      kind,
      width,
      height,
      levels,
      kind == _Kind.rgba8 || format.hasAlpha,
      ktx2: texture,
    );
  }

  final _Kind kind;
  final int width;
  final int height;
  final int storedLevels;
  final bool hasAlpha;
  final Ktx1EtcTexture? ktx1;
  final Ktx2Texture? ktx2;

  bool get wholeBlocks => width % 4 == 0 && height % 4 == 0;
}

BlockTextureFormat _formatOf(gpu.TextureCompressionFamily family, bool alpha) =>
    switch (family) {
      gpu.TextureCompressionFamily.astc => BlockTextureFormat.astc4x4,
      gpu.TextureCompressionFamily.bc =>
        alpha ? BlockTextureFormat.bc3 : BlockTextureFormat.bc1,
      gpu.TextureCompressionFamily.etc2 =>
        alpha ? BlockTextureFormat.etc2Rgba8 : BlockTextureFormat.etc2Rgb8,
      gpu.TextureCompressionFamily.astcHdr => BlockTextureFormat.rgba8,
    };

// The format a source uploads in on a device that samples [support], most
// preferred first. ETC2 blocks pass through where the device samples ETC2
// and not BC: a desktop driver reports ETC2 and expands it to RGBA8 on upload,
// so a device that samples BC takes BC. UASTC repacks to ASTC and ETC1S
// transcodes to BC or ETC2 without decoding pixels; every other pairing
// decodes and encodes into the first family the device samples.
BlockTextureFormat _choose(
  _Source source,
  List<gpu.TextureCompressionFamily> support,
) {
  final families = [
    for (final family in support)
      if (family != gpu.TextureCompressionFamily.astcHdr) family,
  ];
  if (families.isEmpty) return BlockTextureFormat.rgba8;
  final alpha = source.hasAlpha;
  switch (source.kind) {
    case _Kind.ktx1:
      if (families.contains(gpu.TextureCompressionFamily.etc2) &&
          !families.contains(gpu.TextureCompressionFamily.bc)) {
        return _formatOf(gpu.TextureCompressionFamily.etc2, alpha);
      }
    case _Kind.etc1s:
      for (final family in families) {
        if (family != gpu.TextureCompressionFamily.astc) {
          return _formatOf(family, alpha);
        }
      }
    case _Kind.uastc || _Kind.internal || _Kind.rgba8:
      break;
  }
  return _formatOf(families.first, alpha);
}

int _levelCount(_Source source, {required bool mips}) {
  if (!mips) return 1;
  final chain = engineMipLevelCount(source.width, source.height);
  return source.storedLevels > 1 ? math.min(source.storedLevels, chain) : chain;
}

BlockTexturePlan _planOf(
  _Source source,
  List<gpu.TextureCompressionFamily> support, {
  required bool mips,
}) => BlockTexturePlan(
  format: _choose(source, support),
  width: source.width,
  height: source.height,
  levelCount: _levelCount(source, mips: mips),
  hasAlpha: source.hasAlpha,
);

/// What [transcodeKtxTexture] makes of the KTX 1 or KTX2 file [bytes] on a
/// device that samples the block families [support], most preferred first,
/// and its mip chains where [mips]. Reads the header alone. Throws a
/// [FormatException] for a file it cannot read.
BlockTexturePlan planKtxTexture(
  Uint8List bytes, {
  required List<gpu.TextureCompressionFamily> support,
  required bool mips,
}) => _planOf(_Source.of(bytes), support, mips: mips);

/// Transcodes the KTX 1 or KTX2 file [bytes] to the block format of the
/// first family in [support] it reaches, as [planKtxTexture] states it, with
/// its stored mip chain where [mips], or a chain built from its base where it
/// stores the base alone. [alpha] asks for the base level's alpha as well.
///
/// Pure Dart: run it on a worker isolate. Throws a [FormatException] for a
/// file it cannot read.
BlockTexture transcodeKtxTexture(
  Uint8List bytes, {
  required List<gpu.TextureCompressionFamily> support,
  required bool mips,
  bool alpha = false,
}) {
  final source = _Source.of(bytes);
  final plan = _planOf(source, support, mips: mips);
  final direct = _directLevels(source, plan);
  final List<Uint8List> levels;
  Uint8List? base;
  if (direct != null && direct.length >= plan.levelCount) {
    levels = direct.sublist(0, plan.levelCount);
  } else {
    final decoded = _decodedLevels(source, plan.levelCount);
    base = decoded.first.pixels;
    levels = [
      for (var level = 0; level < plan.levelCount; level++)
        if (direct != null && level < direct.length)
          direct[level]
        else
          _encode(decoded[level], plan.format),
    ];
  }
  Uint8List? alphaPlane;
  if (alpha && source.hasAlpha) {
    alphaPlane = source.ktx1?.format == Ktx1EtcFormat.rgba8
        ? decodeEtc2Alpha(
            source.ktx1!.levels.first,
            source.width,
            source.height,
          )
        : _alphaOf(base ?? _decodedLevels(source, 1).first.pixels);
  }
  return BlockTexture(plan: plan, levels: levels, alpha: alphaPlane);
}

Uint8List _alphaOf(Uint8List rgba) {
  final out = Uint8List(rgba.length >> 2);
  for (var texel = 0; texel < out.length; texel++) {
    out[texel] = rgba[texel * 4 + 3];
  }
  return out;
}

// The stored levels in [plan]'s format without decoding pixels, or null where
// the source needs a decode to reach it.
List<Uint8List>? _directLevels(_Source source, BlockTexturePlan plan) {
  final format = plan.format;
  switch (source.kind) {
    case _Kind.ktx1:
      final passes =
          (format == BlockTextureFormat.etc2Rgb8 &&
              source.ktx1!.format == Ktx1EtcFormat.rgb8) ||
          (format == BlockTextureFormat.etc2Rgba8 &&
              source.ktx1!.format == Ktx1EtcFormat.rgba8);
      return passes ? source.ktx1!.levels : null;
    case _Kind.uastc:
      if (format != BlockTextureFormat.astc4x4) return null;
      return [
        for (final level in repackStandardKtx2ToAstc(
          source.ktx2!,
          plan.levelCount,
        )!)
          level.blocks,
      ];
    case _Kind.etc1s:
      final target = switch (format) {
        BlockTextureFormat.etc2Rgb8 => Etc1sTarget.etc1,
        BlockTextureFormat.etc2Rgba8 => Etc1sTarget.etc2Rgba,
        BlockTextureFormat.bc1 => Etc1sTarget.bc1,
        BlockTextureFormat.bc3 => Etc1sTarget.bc3,
        _ => null,
      };
      if (target == null || !source.wholeBlocks) return null;
      return [
        for (final level in transcodeStandardKtx2Etc1s(
          source.ktx2!,
          target,
          plan.levelCount,
        )!)
          level.blocks,
      ];
    case _Kind.internal:
      if (format == BlockTextureFormat.rgba8) return null;
      return [
        for (
          var level = 0;
          level < math.min(source.storedLevels, plan.levelCount);
          level++
        )
          _fromUniversal(
            ktx2LevelBlocks(source.ktx2!, level),
            mipSize(source.width, source.height, level),
            format,
          ),
      ];
    case _Kind.rgba8:
      return null;
  }
}

// The levels as rgba8, base first: the stored levels decoded, then a chain
// built from the base for the levels the file does not store.
List<MipLevel> _decodedLevels(_Source source, int count) {
  final width = source.width;
  final height = source.height;
  final List<MipLevel> stored;
  switch (source.kind) {
    case _Kind.ktx1:
      final texture = source.ktx1!;
      final decode = texture.format == Ktx1EtcFormat.rgba8
          ? decodeEtc2Rgba8
          : decodeEtc2Rgb8;
      stored = [
        for (
          var level = 0;
          level < math.min(count, texture.levels.length);
          level++
        )
          () {
            final size = mipSize(width, height, level);
            return MipLevel(
              size.width,
              size.height,
              decode(texture.levels[level], size.width, size.height),
            );
          }(),
      ];
    case _Kind.internal:
      stored = [
        for (
          var level = 0;
          level < math.min(count, source.storedLevels);
          level++
        )
          () {
            final decoded = decodeKtx2Level(source.ktx2!, level: level);
            return MipLevel(decoded.width, decoded.height, decoded.rgba);
          }(),
      ];
    case _Kind.uastc || _Kind.etc1s || _Kind.rgba8:
      stored = decodeStandardKtx2(source.ktx2!).levels;
  }
  if (stored.length >= count) return stored.sublist(0, count);
  final base = stored.first;
  return generateMipChain(
    base.pixels,
    base.width,
    base.height,
    TextureContent.color,
  ).sublist(0, count);
}

Uint8List _encode(MipLevel level, BlockTextureFormat format) {
  if (format == BlockTextureFormat.rgba8) return level.pixels;
  return _fromUniversal(
    encodeUniversalBlocks(level.pixels, level.width, level.height),
    (width: level.width, height: level.height),
    format,
  );
}

Uint8List _fromUniversal(
  Uint8List blocks,
  ({int width, int height}) size,
  BlockTextureFormat format,
) {
  final count = ((size.width + 3) >> 2) * ((size.height + 3) >> 2);
  return switch (format) {
    BlockTextureFormat.astc4x4 => transcodeUniversalToAstc4x4(blocks, count),
    BlockTextureFormat.bc1 => transcodeUniversalToBc1(blocks, count),
    BlockTextureFormat.bc3 => transcodeUniversalToBc3(blocks, count),
    BlockTextureFormat.etc2Rgb8 => transcodeUniversalToEtc2Rgb(blocks, count),
    BlockTextureFormat.etc2Rgba8 => transcodeUniversalToEtc2Rgba(blocks, count),
    BlockTextureFormat.rgba8 => decodeUniversalBlocksToRgba8(
      blocks,
      size.width,
      size.height,
    ),
  };
}

/// Uploads [texture] as one GPU texture holding its levels, sampled with
/// [sampling]: the base level alone where [TextureSampling.mipmaps] is off or
/// [mipChainsAreSampled] is false. Must run on the main thread.
Texture2D blockTextureToTexture2D(
  BlockTexture texture, {
  TextureSampling sampling = const TextureSampling(),
}) {
  final count = sampling.mipmaps && mipChainsAreSampled
      ? math.min(
          texture.levels.length,
          sampling.maxMipmapLevels ?? texture.levels.length,
        )
      : 1;
  final gpuTexture = gpu.gpuContext.createTexture(
    gpu.StorageMode.hostVisible,
    texture.width,
    texture.height,
    format: texture.format.pixelFormat,
    mipLevelCount: count,
    enableRenderTargetUsage: false,
    enableShaderWriteUsage: false,
  );
  for (var level = 0; level < count; level++) {
    gpuTexture.overwrite(
      ByteData.sublistView(texture.levels[level]),
      mipLevel: level,
    );
  }
  return Texture2D.fromGpuTexture(gpuTexture, sampling: sampling);
}
