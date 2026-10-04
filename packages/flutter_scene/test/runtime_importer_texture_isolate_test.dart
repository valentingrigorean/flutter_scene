// Covers the texture stage of a runtime glTF import: each decoded image's mip
// chain is built on a background isolate, so the UI isolate only decodes,
// hands the pixels off and uploads the returned chain. Prints the UI-isolate
// time of the stage next to the time the same chains take built in place.
// GPU-gated; the upload needs a device.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' show Scene;
import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/importer/texture_roles.dart';
import 'package:flutter_scene/src/render/mip_sampling_probe.dart';
import 'package:flutter_scene/src/runtime_importer/texture_builder.dart';
import 'package:flutter_scene/src/texture/mipmap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _size = 1024;
const _runs = 3;

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

Uint8List _png(int seed) {
  final image = img.Image(width: _size, height: _size, numChannels: 4);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 7 + seed) & 0xff
      ..g = (pixel.y * 5 + seed) & 0xff
      ..b = ((pixel.x ^ pixel.y) + seed) & 0xff
      ..a = 255;
  }
  return img.encodePng(image, level: 1);
}

({GltfDocument doc, Uint8List buffer, List<Uint8List> pngs})
_texturedDocument() {
  final color = _png(0);
  final normal = _png(97);
  final buffer = Uint8List(color.length + normal.length)
    ..setAll(0, color)
    ..setAll(color.length, normal);
  final doc = parseGltfJson(
    jsonDecode(
          jsonEncode({
            'asset': {'version': '2.0'},
            'buffers': [
              {'byteLength': buffer.length},
            ],
            'bufferViews': [
              {'buffer': 0, 'byteOffset': 0, 'byteLength': color.length},
              {
                'buffer': 0,
                'byteOffset': color.length,
                'byteLength': normal.length,
              },
            ],
            'images': [
              {'bufferView': 0, 'mimeType': 'image/png'},
              {'bufferView': 1, 'mimeType': 'image/png'},
            ],
            'textures': [
              {'source': 0},
              {'source': 1},
            ],
            'materials': [
              {
                'pbrMetallicRoughness': {
                  'baseColorTexture': {'index': 0},
                },
                'normalTexture': {'index': 1},
              },
            ],
          }),
        )
        as Map<String, dynamic>,
  );
  return (doc: doc, buffer: buffer, pngs: [color, normal]);
}

Future<T> _onUiIsolate<T>(Stopwatch watch, Future<T> Function() body) {
  var depth = 0;
  R timed<R>(R Function() run) {
    if (depth++ == 0) watch.start();
    try {
      return run();
    } finally {
      if (--depth == 0) watch.stop();
    }
  }

  return Zone.current
      .fork(
        specification: ZoneSpecification(
          run: <R>(self, parent, zone, f) => timed(() => parent.run(zone, f)),
          runUnary: <R, A>(self, parent, zone, f, A a) =>
              timed(() => parent.runUnary(zone, f, a)),
          runBinary: <R, A, B>(self, parent, zone, f, A a, B b) =>
              timed(() => parent.runBinary(zone, f, a, b)),
        ),
      )
      .run(body);
}

String _median(List<int> micros) {
  final sorted = [...micros]..sort();
  return (sorted[sorted.length ~/ 2] / 1000).toStringAsFixed(1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'runtime importer texture isolate suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  test('one import builds its texture mip chains off the UI isolate', () async {
    final (:doc, :buffer, :pngs) = _texturedDocument();
    final contents = gltfTextureContents(doc);
    expect(contents, [TextureContent.color, TextureContent.normal]);
    final decoded = [
      for (final png in pngs)
        img.decodePng(png)!.getBytes(order: img.ChannelOrder.rgba),
    ];

    final stage = <int>[];
    final inPlace = <int>[];
    for (var run = 0; run < _runs; run++) {
      final before = mipChainsBuiltOnThisIsolate;
      final watch = Stopwatch();
      final textures = await _onUiIsolate(
        watch,
        () => buildTextures(doc, buffer),
      );
      stage.add(watch.elapsedMicroseconds);
      expect(
        mipChainsBuiltOnThisIsolate - before,
        0,
        reason: 'no mip chain of the import is built on the UI isolate',
      );
      expect(textures, hasLength(2));
      for (final texture in textures) {
        expect(texture.gpuTexture.width, _size);
        expect(
          texture.gpuTexture.mipLevelCount,
          mipChainsAreSampled ? greaterThan(1) : 1,
        );
      }

      final chains = Stopwatch()..start();
      for (var i = 0; i < contents.length; i++) {
        generateMipChain(decoded[i], _size, _size, contents[i]);
      }
      chains.stop();
      inPlace.add(chains.elapsedMicroseconds);
    }
    stdout.writeln(
      'TEXTURE STAGE: 2 textures of $_size x $_size, UI isolate ms per import '
      '${_median(stage)}, the same chains built in place ${_median(inPlace)} '
      '(median of $_runs)',
    );
  });
}
