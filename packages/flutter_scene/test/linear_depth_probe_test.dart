// Covers the linear depth layouts: the clear texel of the half float layout
// reads back no nearer than the far depth, the layout follows the probe and
// the test override, the probe reads a known depth back through either
// layout, and ambient occlusion and screen-space reflections draw the same
// frame from either layout, near and at ten times the distance with the
// effect radius scaled alike. GPU-gated like the other render suites.

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

import 'support/gpu_available.dart';

double _single(double value) => (Float32List(1)..[0] = value)[0];

bool _isHalfFloat(double value) {
  final magnitude = value.abs();
  if (magnitude == 0) return true;
  var exponent = -14;
  while (exponent < 15 && math.pow(2.0, exponent + 1) <= magnitude) {
    exponent++;
  }
  final step = math.pow(2.0, exponent - 10);
  return magnitude / step == (magnitude / step).roundToDouble() &&
      magnitude / step < 2048;
}

const int _frameSize = 160;

enum _Effect {
  obscurance('ambient occlusion'),
  groundTruth('ground-truth ambient occlusion'),
  reflections('screen-space reflections');

  const _Effect(this.label);

  final String label;
}

Future<Uint8List> _frame({
  required bool split,
  required double distance,
  required _Effect? effect,
}) async {
  debugSplitLinearDepth = split;
  final scene = Scene()
    ..directionalLight = DirectionalLight(direction: Vector3(-0.4, -1.0, -0.3));
  final occlusion =
      effect == _Effect.obscurance || effect == _Effect.groundTruth;
  scene.ambientOcclusion
    ..enabled = occlusion
    ..method = effect == _Effect.groundTruth
        ? AmbientOcclusionMethod.groundTruth
        : AmbientOcclusionMethod.obscurance
    ..radius = distance * 0.1
    ..depthMipChain = true;
  scene.screenSpaceReflections
    ..enabled = effect == _Effect.reflections
    ..maxDistance = distance * 6
    ..thickness = distance * 0.1;
  final floor = PhysicallyBasedMaterial()
    ..roughnessFactor = effect == _Effect.reflections ? 0.02 : 0.8
    ..metallicFactor = effect == _Effect.reflections ? 1.0 : 0.0;
  final block = UnlitMaterial()..baseColorFactor = Vector4(1.0, 0.2, 0.1, 1.0);
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
        ..position = Vector3(0, distance * 0.15, 0),
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

  group('the half float layout', () {
    tearDown(() {
      debugSplitLinearDepth = false;
      platformRendersFloat32ColorTargets = null;
    });

    test('splits a depth into half floats that read back no nearer and '
        'within one part in a million', () {
      for (final depth in [
        0.002,
        0.05,
        0.5,
        1.0,
        3.3333,
        100.0,
        2500.0,
        65504.0,
        400000.0,
        1048064.0,
      ]) {
        final split = splitLinearDepthAtLeast(depth);
        expect(_isHalfFloat(split.high), isTrue, reason: 'high of $depth');
        expect(_isHalfFloat(split.low), isTrue, reason: 'low of $depth');
        final read = _single(_single(split.high + split.low / 1024) * 16);
        expect(read, greaterThanOrEqualTo(_single(depth)), reason: '$depth');
        expect((read - depth).abs(), lessThanOrEqualTo(depth * 1e-6));
      }
    });

    test('is taken where the probe measured no 32-bit float color target, '
        'or under the test override', () {
      expect(linearDepthIsSplit, isFalse);
      expect(linearDepthFormat(normals: false), gpu.PixelFormat.r32Float);
      platformRendersFloat32ColorTargets = true;
      expect(linearDepthIsSplit, isFalse);
      platformRendersFloat32ColorTargets = false;
      expect(linearDepthIsSplit, isTrue);
      expect(
        linearDepthFormat(normals: false),
        gpu.PixelFormat.r16g16b16a16Float,
      );
      expect(
        linearDepthFormat(normals: true),
        gpu.PixelFormat.r16g16b16a16Float,
      );
      platformRendersFloat32ColorTargets = null;
      debugSplitLinearDepth = true;
      expect(linearDepthIsSplit, isTrue);
      expect(linearDepthClearValue(10).w, lessThan(0));
    });
  });

  if (!gpuAvailable()) {
    test(
      'linear depth probe (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  setUpAll(Scene.initializeStaticResources);
  tearDown(() => debugSplitLinearDepth = false);

  test('reads a known depth back from the 32-bit float target', () async {
    expect(await measureLinearDepthRead(split: false), isTrue);
  });

  test('reads a known depth back from the half float layout', () async {
    expect(await measureLinearDepthRead(split: true), isTrue);
  });

  for (final effect in _Effect.values) {
    for (final distance in [4.0, 40.0]) {
      test('${effect.label} at $distance units draws the same frame from the '
          'half float layout as from the 32-bit float target', () async {
        final whole = await _frame(
          split: false,
          distance: distance,
          effect: effect,
        );
        final split = await _frame(
          split: true,
          distance: distance,
          effect: effect,
        );
        final plain = await _frame(
          split: false,
          distance: distance,
          effect: null,
        );
        final layouts = _difference(whole, split);
        final drawn = _difference(whole, plain);
        expect(drawn.most, greaterThanOrEqualTo(10), reason: '$drawn');
        // The half float layout carries the normal in 8 bits and the
        // roughness in 6, so a reflection may move a few edge pixels by a
        // level or four; the depth itself leaves no band.
        expect(layouts.most, lessThanOrEqualTo(4), reason: '$layouts');
        expect(
          layouts.mean,
          lessThanOrEqualTo(drawn.mean / 100),
          reason: '$layouts against $drawn',
        );
      });
    }
  }
}
