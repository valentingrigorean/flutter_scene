// Copies tightly packed buffer rows into a texture region on the WebGPU
// backend, checked by reading the texture back from the GPU.
//
//   flutter test --platform chrome \
//     test/gpu/webgpu/webgpu_region_copy_browser_test.dart
//
// ignore_for_file: implementation_imports
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/web/_gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/webgpu/webgpu_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// Copies [width] x [height] texels, each byte its texel index plus one, from
/// a buffer 4 bytes in into a region at (1, 1) of a texture one texel wider
/// and taller, and reads the texture back.
Future<(Uint8List, Uint8List)> _copy(int width, int height) async {
  final region = Uint8List(width * height * 4);
  for (var i = 0; i < region.length; i++) {
    region[i] = i ~/ 4 % 255 + 1;
  }
  final buffer = gpu.gpuContext.createDeviceBuffer(
    gpu.StorageMode.hostVisible,
    region.length + 4,
  );
  buffer.overwrite(ByteData.sublistView(region), destinationOffsetInBytes: 4);
  final texture = gpu.gpuContext.createTexture(
    gpu.StorageMode.hostVisible,
    width + 1,
    height + 1,
  );
  gpu.gpuContext.createCommandBuffer()
    ..copyBufferToTexture(
      gpu.BufferView(buffer, offsetInBytes: 4, lengthInBytes: region.length),
      gpu.TextureRegion(texture, x: 1, y: 1, width: width, height: height),
    )
    ..submit();
  return (region, await webGpuReadTexture(texture));
}

void _expectRegion(Uint8List read, Uint8List region, int width, int height) {
  final pitch = (width + 1) * 4;
  expect(read.sublist(0, pitch), everyElement(0));
  for (var row = 0; row < height; row++) {
    final start = (row + 1) * pitch;
    expect(read.sublist(start, start + 4), everyElement(0));
    expect(
      read.sublist(start + 4, start + pitch),
      region.sublist(row * width * 4, (row + 1) * width * 4),
    );
  }
}

void main() {
  if (gpu.webGl2Forced) {
    test('needs a build without FLUTTER_SCENE_GPU_BACKEND=webgl2', () {
      markTestSkipped('The build forces the WebGL2 shim.');
    });
    return;
  }

  setUpAll(() async {
    await gpu.initializeGpuBackend();
  });

  test('copies rows off the 256-byte stride into a region', () async {
    final (region, read) = await _copy(3, 2);
    _expectRegion(read, region, 3, 2);
  });

  test('copies rows on the 256-byte stride into a region', () async {
    final (region, read) = await _copy(64, 3);
    _expectRegion(read, region, 64, 3);
  });
}
