// Covers the shadow map layouts: the layout follows the probe and the test
// override, and a directional shadow draws the same frame from the half float
// layout as from the 32-bit float target, near and at twenty-five times the
// distance, where the far cascade's depth range is widest. GPU-gated like the
// other render suites.

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

Future<Uint8List> _frame({
  required bool split,
  required double distance,
  required bool shadows,
}) async {
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
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(
      position: Vector3(distance * 0.6, distance * 0.5, -distance),
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
      final whole = await _frame(
        split: false,
        distance: distance,
        shadows: true,
      );
      final split = await _frame(
        split: true,
        distance: distance,
        shadows: true,
      );
      final unshadowed = await _frame(
        split: false,
        distance: distance,
        shadows: false,
      );
      final layouts = _difference(whole, split);
      final drawn = _difference(whole, unshadowed);
      expect(drawn.most, greaterThanOrEqualTo(10), reason: '$drawn');
      // The half float layout keeps the depth to about 2^-20, so a receiver
      // that close to a caster's depth at the shadow edge may flip one of the
      // 16 filter taps, a few levels on a few pixels.
      expect(layouts.most, lessThanOrEqualTo(8), reason: '$layouts');
      expect(
        layouts.mean,
        lessThanOrEqualTo(drawn.mean / 100),
        reason: '$layouts against $drawn',
      );
    });
  }
}
