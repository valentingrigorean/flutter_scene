// A warm-up with allShadowStates builds the no-shadow variants of the lit
// materials a casting light draws, so the frame after the light stops casting
// builds no pipeline, and the light casts again once the warm-up returns.
// Needs a GPU device: flutter test --enable-impeller --enable-flutter-gpu.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'warm-up shadow states (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.',
    );
    return;
  }

  test('a warm-up of every shadow state leaves no pipeline for the frame '
      'after the directional light stops casting', () async {
    await Scene.initializeStaticResources();
    final light = DirectionalLight(
      direction: Vector3(-1, -2, -1),
      castsShadow: true,
    );
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..directionalLight = light
      ..add(
        Node(
          mesh: Mesh(CuboidGeometry(Vector3.all(1)), PhysicallyBasedMaterial()),
        ),
      );
    addTearDown(scene.dispose);
    final views = [
      RenderView(
        camera: PerspectiveCamera(
          position: Vector3(0, 2, 6),
          target: Vector3.zero(),
          fovRadiansY: math.pi / 4,
        ),
      ),
    ];
    const size = ui.Size(64, 64);
    await scene.warmUp(views, size: size, allShadowStates: true);
    expect(light.castsShadow, isTrue);

    light.castsShadow = false;
    final built = scenePipelinesBuilt;
    final recorder = ui.PictureRecorder();
    scene.renderViews(
      views,
      ui.Canvas(recorder),
      region: ui.Offset.zero & size,
    );
    recorder.endRecording().dispose();
    expect(scenePipelinesBuiltSince(built), isEmpty);
  });
}
