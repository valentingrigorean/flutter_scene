// Covers the shadow map that is the depth attachment of its pass: where the
// device samples a stored depth attachment the atlas a shadow pass publishes
// is the depth it drew with, beside a one channel color target the pass
// discards, and a directional shadow, with its casters drawn each frame or
// replayed from cached static tiles, draws the same frame from it as from the
// color target that holds the depth elsewhere. GPU-gated like the other
// render suites.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/render/shadow_pass.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/stored_depth_probe.dart';

import 'support/gpu_available.dart';

const int _frameSize = 160;

Future<Uint8List> _frame({
  required bool depth,
  required bool shadows,
  bool cached = false,
}) async {
  debugStoredDepthUnsampled = !depth;
  final scene = Scene()
    ..directionalLight = DirectionalLight(
      direction: Vector3(-0.4, -1.0, -0.3),
      castsShadow: shadows,
      shadowMaxDistance: 40,
    );
  final floor = PhysicallyBasedMaterial()..roughnessFactor = 0.8;
  final block = PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(1.0, 0.2, 0.1, 1.0);
  scene
    ..add(Node(mesh: Mesh(PlaneGeometry(width: 16, depth: 16), floor)))
    ..add(
      Node(mesh: Mesh(CuboidGeometry(Vector3.all(1.2)), block))
        ..position = Vector3(0, 1.2, 0)
        ..shadowStatic = cached,
    )
    ..add(
      Node(mesh: Mesh(CuboidGeometry(Vector3.all(0.6)), block))
        ..position = Vector3(2.0, 0.6, 1.0),
    );
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(
      position: Vector3(2.4, 2.0, -4.0),
      target: Vector3.zero(),
    ),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _frameSize + 0.0, _frameSize + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_frameSize, _frameSize);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  return bytes.buffer.asUint8List();
}

({int most, double mean}) _difference(Uint8List a, Uint8List b) {
  var most = 0;
  var sum = 0;
  for (var index = 0; index < a.length; index++) {
    final difference = (a[index] - b[index]).abs();
    most = math.max(most, difference);
    sum += difference;
  }
  return (most: most, mean: sum / a.length);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!gpuAvailable()) {
    test(
      'depth shadow map (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  // The default environment's radiance otherwise fills a band per frame, so
  // two frames of one scene would differ by the frames drawn before them.
  setUpAll(() {
    EnvironmentMap.synchronousRadiancePrefilter = true;
    return Scene.initializeStaticResources();
  });
  tearDownAll(() => EnvironmentMap.synchronousRadiancePrefilter = false);
  tearDown(() => debugStoredDepthUnsampled = false);

  test('a shadow pass publishes the depth it drew with and discards a one '
      'channel color target where the device samples a stored depth', () async {
    if (platformSamplesStoredDepth != true) {
      markTestSkipped('This device samples no stored depth attachment.');
      return;
    }
    await _frame(depth: true, shadows: true);
    final drawn = ShadowPass.debugLastAtlas!;
    final color = drawn.target.colorAttachments.single;
    final depth = drawn.target.depthStencilAttachment!;
    expect(shadowMapIsDepth, isTrue);
    expect(drawn.atlas, same(depth.texture));
    expect(depth.depthStoreAction, gpu.StoreAction.store);
    expect(color.texture.format, gpu.PixelFormat.r8UNormInt);
    expect(color.texture.storageMode, gpu.StorageMode.deviceTransient);
    expect(color.storeAction, gpu.StoreAction.dontCare);
  });

  test('a shadow pass publishes its color target where the device samples no '
      'stored depth', () async {
    await _frame(depth: false, shadows: true);
    final drawn = ShadowPass.debugLastAtlas!;
    final color = drawn.target.colorAttachments.single;
    expect(shadowMapIsDepth, isFalse);
    expect(drawn.atlas, same(color.texture));
    expect(color.texture.format, shadowMapFormat);
    expect(color.storeAction, gpu.StoreAction.store);
  });

  for (final cached in [false, true]) {
    test('a directional shadow ${cached ? 'with a cached static tile ' : ''}'
        'draws the same frame from the depth attachment as from the color '
        'target', () async {
      if (platformSamplesStoredDepth != true) {
        markTestSkipped('This device samples no stored depth attachment.');
        return;
      }
      final encoded = await _frame(depth: false, shadows: true, cached: cached);
      final sampled = await _frame(depth: true, shadows: true, cached: cached);
      final unshadowed = await _frame(depth: true, shadows: false);
      final kinds = _difference(encoded, sampled);
      final drawn = _difference(encoded, unshadowed);
      expect(drawn.most, greaterThanOrEqualTo(10), reason: '$drawn');
      expect(kinds.most, lessThanOrEqualTo(8), reason: '$kinds');
      expect(
        kinds.mean,
        lessThanOrEqualTo(drawn.mean / 1000),
        reason: '$kinds against $drawn',
      );
    });
  }
}
