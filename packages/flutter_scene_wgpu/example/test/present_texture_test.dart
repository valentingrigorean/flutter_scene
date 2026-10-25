// Presents textures of flutter_scene's GPU shim, on its wgpu backend,
// through an offscreen presenter and reads the presenter's IOSurface back.
@TestOn('mac-os')
library;

import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene_wgpu/present.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

const source = 32;
const target = 64;

// Linear 0.5 and 0.2 after sRGB encoding.
const half = 188;
const fifth = 124;

/// The BGRA pixel at ([x], [y]) as RGBA.
List<int> rgba(Uint8List bgra, int x, int y) {
  final i = (y * target + x) * 4;
  return [bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]];
}

/// Fills a [source]-sized texture's quadrants (top left, top right, bottom
/// left, bottom right) with [texels], each one texel's bytes.
ByteData quadrants(List<List<int>> texels, int bytesPerTexel) {
  final out = Uint8List(source * source * bytesPerTexel);
  for (var y = 0; y < source; y++) {
    for (var x = 0; x < source; x++) {
      final q = (y < source / 2 ? 0 : 2) + (x < source / 2 ? 0 : 1);
      out.setAll((y * source + x) * bytesPerTexel, texels[q]);
    }
  }
  return ByteData.sublistView(out);
}

List<int> halfs(List<int> bits) =>
    Uint16List.fromList(bits).buffer.asUint8List();

/// The centre of each quadrant of the presenter's latest frame.
List<List<int>> centres(WgpuPresenter presenter) {
  final pixels = presenter.readLatestFrame();
  const a = target ~/ 4, b = target * 3 ~/ 4;
  return [rgba(pixels, a, a), rgba(pixels, b, a), rgba(pixels, a, b), rgba(pixels, b, b)];
}

gpu.Texture cleared(gpu.PixelFormat format, vm.Vector4 colour) {
  final texture = gpu.gpuContext.createTexture(
    gpu.StorageMode.devicePrivate,
    source,
    source,
    format: format,
  );
  final commands = gpu.gpuContext.createCommandBuffer();
  commands.createRenderPass(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: texture, clearValue: colour),
    ),
  );
  commands.submit();
  return texture;
}

void main() {
  late WgpuPresenter presenter;

  setUpAll(() {
    gpu.selectGpuBackend(gpu.GpuBackendKind.wgpu);
    expect(gpu.gpuContext.createTexture(gpu.StorageMode.devicePrivate, 1, 1),
        isNotNull);
    presenter = WgpuPresenter.createOffscreen(width: target, height: target);
  });
  tearDownAll(() => presenter.dispose());

  test('an 8-bit texture is shown as stored, scaled to the presenter', () {
    final texture = gpu.gpuContext.createTexture(
      gpu.StorageMode.hostVisible,
      source,
      source,
    )..overwrite(
        quadrants([
          [255, 0, 0, 255],
          [0, 255, 0, 255],
          [0, 0, 255, 255],
          [128, 64, 32, 255],
        ], 4),
      );
    expect(presenter.presentTexture(texture), PresentResult.rendered);
    expect(centres(presenter), [
      [255, 0, 0, 255],
      [0, 255, 0, 255],
      [0, 0, 255, 255],
      [128, 64, 32, 255],
    ]);
  });

  test('a 16-bit float texture is sRGB-encoded and clamped', () {
    final texture = gpu.gpuContext.createTexture(
      gpu.StorageMode.hostVisible,
      source,
      source,
      format: gpu.PixelFormat.r16g16b16a16Float,
    )..overwrite(
        quadrants([
          // 1, 0, 0, 1
          halfs([0x3C00, 0, 0, 0x3C00]),
          // 0.5 grey
          halfs([0x3800, 0x3800, 0x3800, 0x3C00]),
          // 2 (HDR), clamps to 1
          halfs([0x4000, 0x4000, 0x4000, 0x3C00]),
          // 0, 0.2, 0.5
          halfs([0, 0x3266, 0x3800, 0x3C00]),
        ], 8),
      );
    expect(presenter.presentTexture(texture), PresentResult.rendered);
    final c = centres(presenter);
    expect(c[0], [255, 0, 0, 255]);
    expect(c[1], [half, half, half, 255]);
    expect(c[2], [255, 255, 255, 255]);
    expect(c[3][0], 0);
    expect(c[3][1], closeTo(fifth, 1));
    expect(c[3][2], half);
  });

  test('a texture a shim render pass cleared presents after that pass', () {
    final float = cleared(
      gpu.PixelFormat.r16g16b16a16Float,
      vm.Vector4(0.2, 0.5, 1, 1),
    );
    expect(presenter.presentTexture(float), PresentResult.rendered);
    final f = centres(presenter).first;
    expect(f[0], closeTo(fifth, 1));
    expect(f.sublist(1), [half, 255, 255]);

    final unorm = cleared(
      gpu.PixelFormat.r8g8b8a8UNormInt,
      vm.Vector4(0.2, 0.6, 1, 1),
    );
    expect(presenter.presentTexture(unorm), PresentResult.rendered);
    expect(centres(presenter).first, [51, 153, 255, 255]);
  });

  test('a texture without shader-read usage is copied, then drawn', () {
    final texture = gpu.gpuContext.createTexture(
      gpu.StorageMode.hostVisible,
      source,
      source,
      format: gpu.PixelFormat.r8g8b8a8UNormIntSRGB,
      enableShaderReadUsage: false,
    )..overwrite(quadrants([for (var i = 0; i < 4; i++) [10, 100, 200, 255]], 4));
    expect(presenter.presentTexture(texture), PresentResult.rendered);
    expect(centres(presenter).first, [10, 100, 200, 255]);
  });

  test('a depth texture is refused with the reason', () {
    final depth = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      source,
      source,
      format: gpu.gpuContext.defaultDepthStencilFormat,
      enableShaderReadUsage: false,
    );
    expect(
      () => presenter.presentTexture(depth),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('not a filterable colour format'))),
    );
  });
}
