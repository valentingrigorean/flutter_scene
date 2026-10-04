/// Covers CPU mip-chain generation: chain sizing, and content-aware
/// downsampling (sRGB color averaged in linear light, data averaged directly,
/// normals averaged as vectors and renormalized). The color chain converts
/// through tables and must hold the bytes of the `pow` conversion for every
/// byte value and on both sides of every rounding edge's fallback band. Also covers the off-isolate chain and uploading a prebuilt
/// chain through Texture2D.fromMipLevels, which is GPU-gated.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' show Scene;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/mip_sampling_probe.dart';
import 'package:flutter_scene/src/texture/mipmap.dart';
import 'package:flutter_scene/src/texture/mipmap_async.dart';
import 'package:flutter_scene/src/texture/texture2d.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _solid(int w, int h, int r, int g, int b, int a) {
  final p = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    p[i * 4] = r;
    p[i * 4 + 1] = g;
    p[i * 4 + 2] = b;
    p[i * 4 + 3] = a;
  }
  return p;
}

String? _firstDifference(Uint8List table, Uint8List pow) {
  if (table.length != pow.length) {
    return 'length ${table.length} against ${pow.length}';
  }
  for (var i = 0; i < table.length; i++) {
    if (table[i] != pow[i]) {
      return 'texel ${i ~/ 4} channel ${i % 4} reads ${table[i]} against '
          '${pow[i]}';
    }
  }
  return null;
}

void _expectPowChain(Uint8List pixels, int width, int height, String what) {
  final pow = generateColorMipChainWithPow(pixels, width, height);
  final table = generateMipChain(pixels, width, height, TextureContent.color);
  expect(table, hasLength(pow.length), reason: '$what level count');
  for (var level = 0; level < table.length; level++) {
    expect(table[level].width, pow[level].width, reason: '$what width');
    expect(table[level].height, pow[level].height, reason: '$what height');
    expect(
      _firstDifference(table[level].pixels, pow[level].pixels),
      isNull,
      reason: '$what level $level holds the pow chain bytes',
    );
  }
}

Uint8List _block(int a, int b, int c, int d, {int alpha = 255}) {
  final pixels = Uint8List(2 * 2 * 4);
  final bytes = [a, b, c, d];
  for (var texel = 0; texel < 4; texel++) {
    pixels[texel * 4] = bytes[texel];
    pixels[texel * 4 + 1] = bytes[texel];
    pixels[texel * 4 + 2] = bytes[texel];
    pixels[texel * 4 + 3] = alpha;
  }
  return pixels;
}

Uint8List _randomPixels(int width, int height, int seed) {
  final random = Random(seed);
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = random.nextInt(256);
  }
  return pixels;
}

const _timedExtent = 1024;
const _timedRuns = 5;

String _millis(List<int> runs) {
  final sorted = [...runs]..sort();
  String ms(int micros) => (micros / 1000).toStringAsFixed(2);
  return '${runs.map(ms).join(' ')}, fastest ${ms(sorted.first)} '
      'median ${ms(sorted[runs.length ~/ 2])}';
}

List<int> _timed(void Function() build) {
  build();
  final runs = <int>[];
  final watch = Stopwatch();
  for (var run = 0; run < _timedRuns; run++) {
    watch
      ..reset()
      ..start();
    build();
    watch.stop();
    runs.add(watch.elapsedMicroseconds);
  }
  return runs;
}

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('mipLevelCountFor is floor(log2(max)) + 1', () {
    expect(mipLevelCountFor(256, 256), 9);
    expect(mipLevelCountFor(1, 1), 1);
    expect(mipLevelCountFor(8, 2), 4);
  });

  test('chain halves down to 1x1 with level 0 first', () {
    final chain = generateMipChain(
      _solid(4, 4, 10, 20, 30, 255),
      4,
      4,
      TextureContent.data,
    );
    expect(chain.map((l) => '${l.width}x${l.height}'), ['4x4', '2x2', '1x1']);
    // A solid image stays solid at every level.
    expect(chain.last.pixels, [10, 20, 30, 255]);
  });

  test('color content averages in linear light, not naively', () {
    // A 2x2 checker of black and white. Naive byte average = 127; correct
    // linear average is 0.5 in linear -> ~188 in sRGB.
    final pixels = Uint8List.fromList([
      0, 0, 0, 255, // black
      255, 255, 255, 255, // white
      255, 255, 255, 255, // white
      0, 0, 0, 255, // black
    ]);
    final chain = generateMipChain(pixels, 2, 2, TextureContent.color);
    final mip = chain[1].pixels; // 1x1
    expect(mip[0], greaterThan(180));
    expect(mip[0], lessThan(195));
  });

  test('data content averages bytes directly', () {
    final pixels = Uint8List.fromList([
      0, 0, 0, 0, //
      255, 255, 255, 255, //
      255, 255, 255, 255, //
      0, 0, 0, 0, //
    ]);
    final chain = generateMipChain(pixels, 2, 2, TextureContent.data);
    expect(chain[1].pixels, [128, 128, 128, 128]);
  });

  test('normal content renormalizes to a unit vector', () {
    // Flat normals (0,0,1) encoded as (128,128,255) stay flat.
    final chain = generateMipChain(
      _solid(2, 2, 128, 128, 255, 255),
      2,
      2,
      TextureContent.normal,
    );
    final mip = chain[1].pixels;
    expect(mip[0], closeTo(128, 1));
    expect(mip[1], closeTo(128, 1));
    expect(mip[2], closeTo(255, 1));
  });

  test(
    'a $_timedExtent by $_timedExtent color mip chain cost, table and pow',
    () {
      final pixels = _randomPixels(_timedExtent, _timedExtent, 11);
      final table = _timed(
        () => generateMipChain(
          pixels,
          _timedExtent,
          _timedExtent,
          TextureContent.color,
        ),
      );
      final pow = _timed(
        () => generateColorMipChainWithPow(pixels, _timedExtent, _timedExtent),
      );
      stdout.writeln(
        'COLOR MIP CHAIN $_timedExtent by $_timedExtent ms per chain: table '
        '${_millis(table)}; pow ${_millis(pow)}',
      );
    },
    skip: 'a timing reading; run with --run-skipped',
  );

  group('the color chain holds the bytes of the pow chain', () {
    test('a flat block of every byte value', () {
      for (var byte = 0; byte < 256; byte++) {
        _expectPowChain(_block(byte, byte, byte, byte), 2, 2, 'flat $byte');
      }
    });

    test('every ordered pair of source bytes', () {
      for (var a = 0; a < 256; a++) {
        for (var b = 0; b < 256; b++) {
          _expectPowChain(_block(a, a, b, b), 2, 2, 'pair $a and $b');
        }
      }
    });

    test('every block of the bytes below the sRGB knee, where a block average '
        'lands on a rounding edge exactly', () {
      for (var a = 0; a <= 12; a++) {
        for (var b = 0; b <= 12; b++) {
          for (var c = 0; c <= 12; c++) {
            for (var d = 0; d <= 12; d++) {
              _expectPowChain(_block(a, b, c, d), 2, 2, 'knee $a $b $c $d');
            }
          }
        }
      }
    });

    test('pow gives the byte below each rounding edge at the lower bound of '
        'its fallback band and the byte above at the upper bound, so the '
        'table walk outside every band holds the pow byte', () {
      final bands = srgbEdgeFallbackBands;
      expect(bands, hasLength(255));
      for (var byte = 1; byte < 256; byte++) {
        final band = bands[byte - 1];
        expect(
          srgbByteOfLinearWithPow(band.below),
          byte - 1,
          reason: 'below edge $byte',
        );
        expect(
          srgbByteOfLinearWithPow(band.above),
          byte,
          reason: 'above edge $byte',
        );
      }
    });

    test('a block of each alpha keeps the pow color and alpha', () {
      for (final alpha in [0, 1, 2, 3, 127, 128, 254, 255]) {
        _expectPowChain(
          _block(17, 200, 43, 255, alpha: alpha),
          2,
          2,
          'alpha $alpha',
        );
      }
    });

    test('an image of every awkward size, filled with random bytes', () {
      const sizes = [
        [1, 1],
        [1, 7],
        [7, 1],
        [3, 3],
        [5, 3],
        [17, 9],
        [129, 71],
        [256, 256],
      ];
      var seed = 7;
      for (final [width, height] in sizes) {
        _expectPowChain(
          _randomPixels(width, height, seed++),
          width,
          height,
          'random $width by $height',
        );
      }
    });
  });

  group('generateMipChainAsync', () {
    test('builds the synchronous chain off the isolate and keeps the base '
        'pixels as given', () async {
      for (final content in TextureContent.values) {
        final pixels = _randomPixels(37, 21, content.index);
        final built = mipChainsBuiltOnThisIsolate;
        final chain = await generateMipChainAsync(pixels, 37, 21, content);
        final reference = generateMipChain(pixels, 37, 21, content);
        expect(mipChainsBuiltOnThisIsolate, built + 1, reason: '$content');
        expect(identical(chain.first.pixels, pixels), isTrue);
        expect(chain, hasLength(reference.length));
        for (var level = 0; level < chain.length; level++) {
          expect(chain[level].width, reference[level].width);
          expect(chain[level].height, reference[level].height);
          expect(
            chain[level].pixels,
            orderedEquals(reference[level].pixels),
            reason: '$content level $level',
          );
        }
      }
    });
  });

  group('Texture2D.fromMipLevels', () {
    if (!_gpuAvailable()) {
      // ignore: avoid_print
      print('GPU unavailable - skipping.');
      return;
    }

    List<MipLevel> chain(int w, int h) => generateMipChain(
      _solid(w, h, 10, 20, 30, 255),
      w,
      h,
      TextureContent.data,
    );

    test('uploads the chain at the size of its base level', () {
      final texture = Texture2D.fromMipLevels(chain(16, 16)).gpuTexture;
      expect(texture.width, 16);
      expect(texture.height, 16);
      expect(
        texture.mipLevelCount,
        mipChainsAreSampled ? gpu.Texture.fullMipCount(16, 16) : 1,
      );
    });

    test('caps the chain at the sampling maxMipmapLevels', () {
      final texture = Texture2D.fromMipLevels(
        chain(16, 16),
        sampling: const TextureSampling(maxMipmapLevels: 2),
      ).gpuTexture;
      expect(texture.mipLevelCount, mipChainsAreSampled ? 2 : 1);
    });

    test('caps a non-square chain at what the allocator accepts', () {
      final levels = chain(16, 4);
      final texture = Texture2D.fromMipLevels(levels).gpuTexture;
      expect(levels, hasLength(5));
      expect(
        texture.mipLevelCount,
        mipChainsAreSampled ? gpu.Texture.fullMipCount(16, 4) : 1,
      );
    });

    test('uploads the base level alone with mipmaps off', () {
      final texture = Texture2D.fromMipLevels(
        chain(16, 16),
        sampling: const TextureSampling(mipmaps: false),
      );
      expect(texture.gpuTexture.mipLevelCount, 1);
      expect(texture.sampledSampler.mipFilter, gpu.MipFilter.nearest);
    });
  });

  group('Texture2D.fromMipLevels rejects before allocating', () {
    Matcher namesLevel(int level) => throwsA(
      isA<ArgumentError>().having(
        (e) => e.message,
        'message',
        contains('level $level'),
      ),
    );

    test('an empty chain', () {
      expect(() => Texture2D.fromMipLevels(const []), throwsArgumentError);
    });

    test('a base level whose length is not width * height * 4', () {
      expect(
        () => Texture2D.fromMipLevels([MipLevel(4, 4, Uint8List(4 * 4 * 3))]),
        namesLevel(0),
      );
    });

    test('a level whose extent is not the halved base', () {
      expect(
        () => Texture2D.fromMipLevels([
          MipLevel(8, 4, Uint8List(8 * 4 * 4)),
          MipLevel(4, 4, Uint8List(4 * 4 * 4)),
        ]),
        namesLevel(1),
      );
    });

    test('a level past the 1 x 1 floor that is not 1 x 1', () {
      expect(
        () => Texture2D.fromMipLevels([
          MipLevel(4, 1, Uint8List(4 * 1 * 4)),
          MipLevel(2, 1, Uint8List(2 * 1 * 4)),
          MipLevel(1, 1, Uint8List(1 * 1 * 4)),
          MipLevel(1, 2, Uint8List(1 * 2 * 4)),
        ]),
        namesLevel(3),
      );
    });

    test('a level whose length does not match its extent', () {
      expect(
        () => Texture2D.fromMipLevels([
          MipLevel(4, 4, Uint8List(4 * 4 * 4)),
          MipLevel(2, 2, Uint8List(2 * 2 * 4)),
          MipLevel(1, 1, Uint8List(8)),
        ]),
        namesLevel(2),
      );
    });
  });
}
