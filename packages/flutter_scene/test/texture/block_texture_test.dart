// Verifies the KTX 1 ETC2 reader, the ETC2 decoder and the transcode of a
// KTX texture to the block family a device samples.
//
// Fixture provenance: test/fixtures/texture/etc2_rgba8_reference.bin holds
// 1024 pseudo-random ETC2 RGBA8 blocks of a 128x128 image, then the 128x128
// rgba8 texels the Ericsson ETCPACK reference decoder (etcdec.cxx,
// decompressBlockETC2c and decompressBlockAlphaC) decodes from them. Random
// blocks reach the individual, differential, T, H and planar modes. The
// test/fixtures/ktx2/ files are described in basis_ktx2_test.dart.

@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/texture/block/decode_etc2.dart';
import 'package:flutter_scene/src/texture/block/transcode_bc1.dart';
import 'package:flutter_scene/src/texture/block/transcode_etc2.dart';
import 'package:flutter_scene/src/texture/block/universal_block.dart';
import 'package:flutter_scene/src/texture/block_texture.dart';
import 'package:flutter_scene/src/texture/ktx1/ktx1.dart';
import 'package:flutter_test/flutter_test.dart';

const _astc = gpu.TextureCompressionFamily.astc;
const _bc = gpu.TextureCompressionFamily.bc;
const _etc2 = gpu.TextureCompressionFamily.etc2;

Uint8List _reference() =>
    File('test/fixtures/texture/etc2_rgba8_reference.bin').readAsBytesSync();

Uint8List _ktx2(String name) =>
    File('test/fixtures/ktx2/$name').readAsBytesSync();

// A KTX 1 file of [levels] in [internalFormat], base [width] x [height].
Uint8List _ktx1(
  int internalFormat,
  int width,
  int height,
  List<Uint8List> levels, {
  Endian endian = Endian.little,
}) {
  final builder = BytesBuilder();
  builder.add(ktx1Identifier);
  final header = ByteData(52);
  final fields = [
    0x04030201,
    0,
    1,
    0,
    internalFormat,
    internalFormat == glEtc2Rgba8 ? 0x1908 : 0x1907,
    width,
    height,
    0,
    0,
    1,
    levels.length,
    0,
  ];
  for (var i = 0; i < fields.length; i++) {
    header.setUint32(i * 4, fields[i], endian);
  }
  builder.add(header.buffer.asUint8List());
  for (final level in levels) {
    final size = ByteData(4)..setUint32(0, level.length, endian);
    builder.add(size.buffer.asUint8List());
    builder.add(level);
    builder.add(Uint8List((4 - level.length % 4) % 4));
  }
  return builder.toBytes();
}

// A smooth opaque gradient, so a re-encode stays close to its source.
Uint8List _gradient(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      rgba[i] = x * 255 ~/ (width - 1);
      rgba[i + 1] = y * 255 ~/ (height - 1);
      rgba[i + 2] = 128;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Uint8List _etc2Of(Uint8List rgba, int width, int height) =>
    transcodeUniversalToEtc2Rgb(
      encodeUniversalBlocks(rgba, width, height),
      ((width + 3) >> 2) * ((height + 3) >> 2),
    );

int _largestError(Uint8List a, Uint8List b) {
  var largest = 0;
  for (var i = 0; i < a.length; i++) {
    final error = (a[i] - b[i]).abs();
    if (error > largest) largest = error;
  }
  return largest;
}

void main() {
  group('ETC2 decode, Khronos Data Format Specification 1.3 section 21.2', () {
    test('every mode of random RGBA8 blocks decodes as the ETCPACK reference '
        'decoder decodes it', () {
      final reference = _reference();
      final blocks = Uint8List.sublistView(reference, 0, 1024 * 16);
      final texels = Uint8List.sublistView(reference, 1024 * 16);
      expect(decodeEtc2Rgba8(blocks, 128, 128), texels);
      final alpha = decodeEtc2Alpha(blocks, 128, 128);
      expect([for (var i = 3; i < texels.length; i += 4) texels[i]], alpha);
    });

    test('the RGB half alone decodes with opaque alpha', () {
      final reference = _reference();
      final rgb = Uint8List(1024 * 8);
      for (var block = 0; block < 1024; block++) {
        rgb.setRange(block * 8, block * 8 + 8, reference, block * 16 + 8);
      }
      final decoded = decodeEtc2Rgb8(rgb, 128, 128);
      final texels = Uint8List.sublistView(reference, 1024 * 16);
      for (var i = 0; i < decoded.length; i += 4) {
        expect(decoded.sublist(i, i + 3), texels.sublist(i, i + 3));
        expect(decoded[i + 3], 255);
      }
    });
  });

  group('KTX 1 ETC reader, KTX File Format Specification 1.0', () {
    test('reads the stored levels of either endianness', () {
      final base = Uint8List.fromList(List.generate(4 * 8, (i) => i));
      final next = Uint8List.fromList(List.generate(8, (i) => 100 + i));
      for (final endian in [Endian.little, Endian.big]) {
        final texture = readKtx1Etc(
          _ktx1(glEtc2Rgb8, 8, 8, [base, next], endian: endian),
        );
        expect(texture.format, Ktx1EtcFormat.rgb8);
        expect(texture.pixelWidth, 8);
        expect(texture.pixelHeight, 8);
        expect(texture.levels, [base, next]);
      }
    });

    test('refuses another internal format and a short level', () {
      expect(
        () => readKtx1Etc(_ktx1(0x83F1, 4, 4, [Uint8List(8)])),
        throwsFormatException,
      );
      expect(
        () => readKtx1Etc(_ktx1(glEtc2Rgba8, 8, 8, [Uint8List(16)])),
        throwsFormatException,
      );
    });
  });

  group('transcode of a KTX 1 ETC2 texture', () {
    final reference = _reference();
    final blocks = Uint8List.sublistView(reference, 0, 1024 * 16);
    final file = _ktx1(glEtc2Rgba8, 128, 128, [blocks]);

    test('passes the blocks through where the device samples ETC2 and not '
        'BC, with a chain built from the base', () {
      for (final support in [
        [_etc2],
        [_astc, _etc2],
      ]) {
        final texture = transcodeKtxTexture(file, support: support, mips: true);
        expect(texture.format, BlockTextureFormat.etc2Rgba8);
        expect(texture.levels.length, 7);
        expect(texture.levels.first, blocks);
        for (var level = 0; level < 7; level++) {
          final side = 128 >> level;
          expect(
            texture.levels[level].length,
            ((side + 3) >> 2) * ((side + 3) >> 2) * 16,
          );
        }
      }
    });

    test('becomes BC3 where the device samples BC, ASTC where it samples '
        'ASTC alone, and decoded pixels where it samples no family', () {
      final cases = {
        BlockTextureFormat.bc3: [_bc, _etc2],
        BlockTextureFormat.astc4x4: [_astc],
        BlockTextureFormat.rgba8: <gpu.TextureCompressionFamily>[],
      };
      for (final MapEntry(key: format, value: support) in cases.entries) {
        final plan = planKtxTexture(file, support: support, mips: false);
        final texture = transcodeKtxTexture(
          file,
          support: support,
          mips: false,
        );
        expect(texture.format, format);
        expect(plan.format, format);
        expect(texture.levels.length, 1);
        expect(texture.levels.first.length, plan.byteLength);
      }
      final decoded = transcodeKtxTexture(file, support: const [], mips: false);
      expect(decoded.levels.first, Uint8List.sublistView(reference, 1024 * 16));
    });

    test('a BC1 re-encode of a smooth ETC2 RGB texture stays close to it', () {
      final source = _gradient(64, 64);
      final etc2 = _etc2Of(source, 64, 64);
      final texture = transcodeKtxTexture(
        _ktx1(glEtc2Rgb8, 64, 64, [etc2]),
        support: const [_bc],
        mips: false,
      );
      expect(texture.format, BlockTextureFormat.bc1);
      expect(texture.hasAlpha, isFalse);
      expect(
        _largestError(
          decodeBc1ToRgba8(texture.levels.first, 64, 64),
          decodeEtc2Rgb8(etc2, 64, 64),
        ),
        lessThan(40),
      );
    });

    test('states the alpha of the base level where it is asked for', () {
      final texture = transcodeKtxTexture(
        file,
        support: const [_etc2],
        mips: false,
        alpha: true,
      );
      expect(texture.alpha, decodeEtc2Alpha(blocks, 128, 128));
      final opaque = transcodeKtxTexture(
        _ktx1(glEtc2Rgb8, 64, 64, [_etc2Of(_gradient(64, 64), 64, 64)]),
        support: const [_etc2],
        mips: false,
        alpha: true,
      );
      expect(opaque.alpha, isNull);
    });
  });

  group('transcode of a KTX2 Basis Universal texture', () {
    test('UASTC repacks to ASTC on an ASTC device, as the ASTC reference', () {
      final texture = transcodeKtxTexture(
        _ktx2('uastc_srgb_mips_zstd_64.ktx2'),
        support: const [_astc, _etc2],
        mips: true,
      );
      expect(texture.format, BlockTextureFormat.astc4x4);
      expect(texture.levels.length, 6);
      final reference = _ktx2('uastc_srgb_mips_zstd_64.astc');
      expect(texture.levels.first, reference.sublist(0, 256 * 16));
    });

    test('UASTC becomes BC1 on a BC device', () {
      final texture = transcodeKtxTexture(
        _ktx2('uastc_srgb_mips_zstd_64.ktx2'),
        support: const [_bc],
        mips: true,
      );
      expect(texture.format, BlockTextureFormat.bc1);
      expect(texture.levels.length, 6);
      expect(texture.levels.first.length, 256 * 8);
    });

    test('ETC1S transcodes to BC1 and ETC2 as the reference transcodes it, '
        'and to ASTC on an ASTC-only device', () {
      final file = _ktx2('etc1s_srgb_mips_64.ktx2');
      final bc1 = transcodeKtxTexture(file, support: const [_bc], mips: true);
      expect(bc1.format, BlockTextureFormat.bc1);
      expect(
        bc1.levels.first,
        _ktx2('etc1s_srgb_mips_64.bc1').sublist(0, 256 * 8),
      );
      final etc = transcodeKtxTexture(
        file,
        support: const [_astc, _etc2],
        mips: true,
      );
      expect(etc.format, BlockTextureFormat.etc2Rgb8);
      expect(
        etc.levels.first,
        _ktx2('etc1s_srgb_mips_64.etc1').sublist(0, 256 * 8),
      );
      final astc = transcodeKtxTexture(
        file,
        support: const [_astc],
        mips: true,
      );
      expect(astc.format, BlockTextureFormat.astc4x4);
      expect(astc.levels.first.length, 256 * 16);
    });
  });
}
