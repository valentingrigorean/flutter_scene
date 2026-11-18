// A frame that encodes a translucent draw is rendered again for another
// camera, where a frame of kept translucent draws alone is replayed
// (`Scene.cameraFrame`): a replay draws the kept items and nothing the last
// frame encoded.
//
// Its own file: it reads frames back.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';
import 'support/sheet_material.dart';

const _side = 64;

PerspectiveCamera _cameraAt(double x) => PerspectiveCamera(
  position: Vector3(x, 0, 0),
  target: Vector3(x, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);

// A scene of one red sheet that fills the middle of the view from x = 0.
Scene _scene({required bool kept}) {
  final scene = Scene()
    ..maxGpuFramesInFlight = 0
    ..add(
      Node(
        mesh: Mesh(
          CuboidGeometry(Vector3(20, 20, 0.01)),
          SheetMaterial(Vector4(1, 0, 0, 0.5), kept: kept),
        ),
        localTransform: Matrix4.translationValues(0, 0, -50),
      ),
    );
  addTearDown(scene.dispose);
  return scene;
}

void _render(Scene scene, RenderTexture target, double x) {
  final recorder = ui.PictureRecorder();
  scene.renderViews([
    RenderView(camera: _cameraAt(x), target: target),
  ], ui.Canvas(recorder));
  recorder.endRecording().dispose();
}

// The frame an app shows for the camera at [x]: the last frame replayed for
// it where the scene gives one, else a full render. A replay draws the kept
// items for the camera and none of what the last frame encoded; this
// backend draws no replay, so [target] then still shows the last frame.
// Returns whether the scene gave a replay.
bool _appFrame(Scene scene, RenderTexture target, double x) {
  final replay = scene.cameraFrame([
    RenderView(camera: _cameraAt(x), target: target),
  ]);
  if (replay == null) _render(scene, target, x);
  return replay != null;
}

Future<Uint8List> _pixels(RenderTexture target) async {
  final image = gpu.gpuHost.textureToImage(target.texture!);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return Uint8List.sublistView(bytes!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!gpuAvailable()) return;

  setUpAll(() async {
    await Scene.initializeStaticResources();
    // The first frames of a process build their pipelines, and a scene
    // keeps no draw and replays no frame meanwhile.
    final warmUp = _scene(kept: true);
    final target = RenderTexture(width: _side, height: _side, presents: true);
    for (var frame = 0; frame < 2; frame++) {
      _render(warmUp, target, 0);
      await _pixels(target);
    }
    target.dispose();
    warmUp.dispose();
  });

  test('a frame whose only encoded draw is a translucent one shows that '
      'draw where another camera sees it, as a full render does', () async {
    final wantTarget = RenderTexture(
      width: _side,
      height: _side,
      presents: true,
    );
    addTearDown(wantTarget.dispose);
    _render(_scene(kept: false), wantTarget, 8);
    final want = await _pixels(wantTarget);

    final target = RenderTexture(width: _side, height: _side, presents: true);
    addTearDown(target.dispose);
    final scene = _scene(kept: false);
    _render(scene, target, 0);
    final first = await _pixels(target);
    expect(first, isNot(want), reason: 'the sheet moves with the camera');

    final replayed = _appFrame(scene, target, 8);
    expect(await _pixels(target), want);
    expect(replayed, isFalse);
  });

  test('a frame of kept translucent draws alone is replayed for another '
      'camera', () async {
    final target = RenderTexture(width: _side, height: _side, presents: true);
    addTearDown(target.dispose);
    final scene = _scene(kept: true);
    for (var frame = 0; frame < 3; frame++) {
      _render(scene, target, 0);
    }
    expect(_appFrame(scene, target, 8), isTrue);
    expect(_appFrame(scene, target, 16), isTrue, reason: 'still replays');
  });
}
