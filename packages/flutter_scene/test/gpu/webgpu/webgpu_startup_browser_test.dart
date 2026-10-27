// The WebGPU backend before its device is acquired. Lazy loads (the SMAA
// tables, the physical material shaders) can start before
// Scene.initializeStaticResources completes, so the asynchronous entry points
// must wait for the device rather than throw. Kept in its own file so no other
// test has acquired the device first.
//
//   flutter test --platform chrome \
//     test/gpu/webgpu/webgpu_startup_browser_test.dart
//
// ignore_for_file: implementation_imports
@TestOn('browser')
library;

import 'package:flutter_scene/src/gpu/web/_gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  if (gpu.webGl2Forced) {
    test('needs a build without FLUTTER_SCENE_GPU_BACKEND=webgl2', () {
      markTestSkipped('The build forces the WebGL2 shim.');
    });
    return;
  }

  test('an asynchronous load before startup waits for the device', () async {
    final png = img.encodePng(img.Image(width: 4, height: 4));
    // Deliberately no initializeGpuBackend first.
    final texture = await gpu.createTextureFromEncodedImage(png);
    expect((texture!.width, texture.height), (4, 4));
  });

  test('concurrent initializations share one device request', () {
    expect(
      identical(gpu.initializeGpuBackend(), gpu.initializeGpuBackend()),
      isTrue,
    );
  });
}
