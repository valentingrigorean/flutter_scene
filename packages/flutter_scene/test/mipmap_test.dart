/// Covers CPU mip-chain generation: chain sizing, and content-aware
/// downsampling (sRGB color averaged in linear light, data averaged directly,
/// normals averaged as vectors and renormalized). Also covers uploading a
/// prebuilt chain through Texture2D.fromMipLevels, which is GPU-gated.
library;

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' show Scene;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/mip_sampling_probe.dart';
import 'package:flutter_scene/src/texture/mipmap.dart';
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
