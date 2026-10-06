// Covers the shadow map layouts: the layout follows the probe and the test
// override, and a shadow draws the same frame from the half float layout as
// from the 32-bit float target: a directional shadow near and at twenty-five
// times the distance, where the far cascade's depth range is widest, and a
// spot shadow on ground 50 to 150 units away at a grazing angle, where a
// perspective depth leaves the least room between a receiver and its caster.
// GPU-gated like the other render suites.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/render/linear_depth_probe.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/shadow_pass.dart';

import 'support/gpu_available.dart';

const int _frameSize = 160;

Future<Uint8List> _render(Scene scene, PerspectiveCamera camera) async {
  final recorder = ui.PictureRecorder();
  scene.render(
    camera,
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _frameSize + 0.0, _frameSize + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_frameSize, _frameSize);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  return bytes.buffer.asUint8List();
}

Future<Uint8List> _directionalFrame({
  required bool split,
  required double distance,
  required bool shadows,
}) {
  debugSplitShadowMap = split;
  final scene = Scene()
    ..directionalLight = DirectionalLight(
      direction: Vector3(-0.4, -1.0, -0.3),
      castsShadow: shadows,
      shadowMaxDistance: distance * 10,
    );
  final floor = PhysicallyBasedMaterial()..roughnessFactor = 0.8;
  final block = PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(1.0, 0.2, 0.1, 1.0);
  scene
    ..add(
      Node(
        mesh: Mesh(
          PlaneGeometry(width: distance * 4, depth: distance * 4),
          floor,
        ),
      ),
    )
    ..add(
      Node(mesh: Mesh(CuboidGeometry(Vector3.all(distance * 0.3)), block))
        ..position = Vector3(0, distance * 0.3, 0),
    );
  return _render(
    scene,
    PerspectiveCamera(
      position: Vector3(distance * 0.6, distance * 0.5, -distance),
      target: Vector3.zero(),
    ),
  );
}

Future<Uint8List> _spotFrame({required bool split, required bool shadows}) {
  debugSplitShadowMap = split;
  final scene = Scene()..environmentIntensity = 0.05;
  final light = Node(localTransform: Matrix4.translation(Vector3(0, 8, 0)))
    ..addComponent(
      SpotLightComponent(
        SpotLight(
          direction: Vector3(0, -0.08, 1),
          intensity: 3.0,
          falloffExponent: 0.0,
          outerConeAngle: 0.35,
          range: 200.0,
          castsShadow: shadows,
        ),
      ),
    );
  final floor = PhysicallyBasedMaterial()..roughnessFactor = 0.8;
  final block = PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(1.0, 0.2, 0.1, 1.0);
  scene
    ..add(light)
    ..add(Node(mesh: Mesh(PlaneGeometry(width: 400, depth: 400), floor)))
    ..add(
      Node(mesh: Mesh(CuboidGeometry(Vector3.all(4)), block))
        ..position = Vector3(0, 2, 60),
    );
  return _render(
    scene,
    PerspectiveCamera(
      position: Vector3(30, 40, 40),
      target: Vector3(0, 0, 100),
    ),
  );
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

  group('the half float shadow map layout', () {
    tearDown(() {
      debugSplitShadowMap = false;
      platformRendersFloat32ColorTargets = null;
    });

    test('is taken where the probe measured no 32-bit float color target, '
        'or under the test override', () {
      expect(shadowMapIsSplit, isFalse);
      expect(shadowMapFormat, gpu.PixelFormat.r32Float);
      platformRendersFloat32ColorTargets = true;
      expect(shadowMapIsSplit, isFalse);
      platformRendersFloat32ColorTargets = false;
      expect(shadowMapIsSplit, isTrue);
      expect(shadowMapFormat, gpu.PixelFormat.r16g16b16a16Float);
      platformRendersFloat32ColorTargets = null;
      debugSplitShadowMap = true;
      expect(shadowMapIsSplit, isTrue);
    });
  });

  if (!gpuAvailable()) {
    test(
      'shadow map layout (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  setUpAll(Scene.initializeStaticResources);
  tearDown(() => debugSplitShadowMap = false);

  for (final distance in [4.0, 100.0]) {
    test('a directional shadow at $distance units draws the same frame from '
        'the half float layout as from the 32-bit float target', () async {
      final whole = await _directionalFrame(
        split: false,
        distance: distance,
        shadows: true,
      );
      final split = await _directionalFrame(
        split: true,
        distance: distance,
        shadows: true,
      );
      final unshadowed = await _directionalFrame(
        split: false,
        distance: distance,
        shadows: false,
      );
      _expectSameShadow(whole, split, unshadowed);
    });
  }

  test('a spot shadow on ground 50 to 150 units away at a grazing angle draws '
      'the same frame from the half float layout as from the 32-bit float '
      'target', () async {
    final whole = await _spotFrame(split: false, shadows: true);
    final split = await _spotFrame(split: true, shadows: true);
    final unshadowed = await _spotFrame(split: false, shadows: false);
    _expectSameShadow(whole, split, unshadowed);
  });
}

void _expectSameShadow(Uint8List whole, Uint8List split, Uint8List unshadowed) {
  final layouts = _difference(whole, split);
  final drawn = _difference(whole, unshadowed);
  expect(drawn.most, greaterThanOrEqualTo(10), reason: '$drawn');
  expect(layouts.most, lessThanOrEqualTo(8), reason: '$layouts');
  expect(
    layouts.mean,
    lessThanOrEqualTo(drawn.mean / 1000),
    reason: '$layouts against $drawn',
  );
}
