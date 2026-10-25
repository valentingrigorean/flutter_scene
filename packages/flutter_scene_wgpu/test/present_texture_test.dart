// Presents device API textures through an offscreen presenter and reads
// the presenter's IOSurface back. The example's present_texture_test does
// the same with flutter_scene's GPU shim textures.
@TestOn('mac-os')
library;

import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';
import 'package:flutter_scene_wgpu/flutter_scene_wgpu.dart';
import 'package:flutter_scene_wgpu/present.dart';
import 'package:flutter_test/flutter_test.dart';

const source = 32;
const target = 64;

// Linear 0.5 and 0.2 after sRGB encoding.
const half = 188;
const fifth = 124;

Uint8List quadrants(List<List<int>> texels, int bytesPerTexel) {
  final out = Uint8List(source * source * bytesPerTexel);
  for (var y = 0; y < source; y++) {
    for (var x = 0; x < source; x++) {
      final q = (y < source / 2 ? 0 : 2) + (x < source / 2 ? 0 : 1);
      out.setAll((y * source + x) * bytesPerTexel, texels[q]);
    }
  }
  return out;
}

List<int> halfs(List<int> bits) =>
    Uint16List.fromList(bits).buffer.asUint8List();

/// The centre of each quadrant of the presenter's latest frame, as RGBA.
List<List<int>> centres(WgpuPresenter presenter) {
  final bgra = presenter.readLatestFrame();
  List<int> at(int x, int y) {
    final i = (y * target + x) * 4;
    return [bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]];
  }

  const a = target ~/ 4, b = target * 3 ~/ 4;
  return [at(a, a), at(b, a), at(a, b), at(b, b)];
}

void main() {
  late WgpuDevice device;
  late WgpuPresenter presenter;

  setUpAll(() {
    device = WgpuDevice.createHeadless();
    presenter = WgpuPresenter.createOffscreen(width: target, height: target);
  });
  tearDownAll(() => presenter.dispose());

  test('an 8-bit texture is shown as stored, scaled to the presenter', () {
    final texture = device.createTexture(source, source)
      ..write(
        quadrants([
          [255, 0, 0, 255],
          [0, 255, 0, 255],
          [0, 0, 255, 255],
          [128, 64, 32, 255],
        ], 4),
      );
    expect(presenter.presentWgpuTexture(texture), PresentResult.rendered);
    expect(centres(presenter), [
      [255, 0, 0, 255],
      [0, 255, 0, 255],
      [0, 0, 255, 255],
      [128, 64, 32, 255],
    ]);
    texture.destroy();
  });

  test('a 16-bit float texture rendered by a pass is sRGB-encoded', () {
    final texture = device.createTexture(
      source,
      source,
      format: PixelFormat.r16g16b16a16Float,
    );
    final commands = WgpuCommandStream()
      ..beginRenderPass([
        WgpuColorAttachment(
          texture: texture,
          clearColor: const WgpuColor(0.2, 0.5, 2, 1),
        ),
      ])
      ..endRenderPass();
    device.submit(commands);
    commands.dispose();
    expect(presenter.presentWgpuTexture(texture), PresentResult.rendered);
    final c = centres(presenter).first;
    expect(c[0], closeTo(fifth, 1));
    expect(c.sublist(1), [half, 255, 255]);

    texture.write(
      quadrants([
        halfs([0x3C00, 0, 0, 0x3C00]),
        halfs([0x3800, 0x3800, 0x3800, 0x3C00]),
        halfs([0x4000, 0x4000, 0x4000, 0x3C00]),
        halfs([0, 0x3266, 0x3800, 0x3C00]),
      ], 8),
    );
    expect(presenter.presentWgpuTexture(texture), PresentResult.rendered);
    final q = centres(presenter);
    expect(q[0], [255, 0, 0, 255]);
    expect(q[1], [half, half, half, 255]);
    expect(q[2], [255, 255, 255, 255]);
    expect(q[3][1], closeTo(fifth, 1));
    texture.destroy();
  });
}
