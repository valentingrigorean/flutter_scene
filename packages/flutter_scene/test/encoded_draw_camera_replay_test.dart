// A frame whose color pass encodes a draw is rendered again for another
// camera, where a frame of kept draws alone is replayed
// (`Scene.cameraFrame`): a replay draws the kept items and nothing the last
// frame encoded. A color pass encodes a draw the scene does not keep, and
// every draw where it keeps none: split by a custom pass, or culled by
// planes of the view's own.
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

// Splits the color pass after its opaque draws and draws nothing.
class _Split extends CustomRenderPass {
  @override
  String get name => 'split';

  @override
  double get beforeRenderOrder => 1;

  @override
  RenderStage get stage => RenderStage.afterOpaqueScene;

  @override
  bool get drawsInPlace => true;

  @override
  void execute(RenderPassContext context) {}
}

// A plane that culls nothing in front of the cameras.
final _planes = [Plane.normalconstant(Vector3(0, 0, -1), 0)];

RenderView _view(RenderTexture target, double x, {List<Plane>? planes}) =>
    RenderView(
      camera: PerspectiveCamera(
        position: Vector3(x, 0, 0),
        target: Vector3(x, 0, -1),
        up: Vector3(0, 1, 0),
        fovNear: 0.1,
        fovFar: 1000,
      ),
      target: target,
      cullingPlanes: planes ?? const [],
    );

// A scene of one red sheet that fills the middle of the view from x = 0.
Scene _scene({required bool kept, bool split = false}) {
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
  if (split) scene.addRenderPass(_Split());
  addTearDown(scene.dispose);
  return scene;
}

RenderTexture _target() {
  final target = RenderTexture(width: _side, height: _side, presents: true);
  addTearDown(target.dispose);
  return target;
}

void _render(Scene scene, RenderView view) {
  final recorder = ui.PictureRecorder();
  scene.renderViews([view], ui.Canvas(recorder));
  recorder.endRecording().dispose();
}

// The frame an app shows for [view]: the last frame replayed for its camera
// where the scene gives one, else a full render. A replay draws the kept
// items for the camera and none of what the last frame encoded; this
// backend draws no replay, so the target then still shows the last frame.
// Returns whether the scene gave a replay.
bool _appFrame(Scene scene, RenderView view) {
  final replay = scene.cameraFrame([view]);
  if (replay == null) _render(scene, view);
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
      _render(warmUp, _view(target, 0));
      await _pixels(target);
    }
    target.dispose();
    warmUp.dispose();
  });

  for (final (name, kept, split, planes) in [
    ('whose only encoded draw is a translucent one', false, false, null),
    ('split by a custom pass, which keeps no draw,', false, true, null),
    (
      'culled by planes of its view, which keeps no draw,',
      true,
      false,
      _planes,
    ),
  ]) {
    test('a frame $name shows its draw where another camera sees it, as a '
        'full render does', () async {
      final wantTarget = _target();
      _render(
        _scene(kept: kept, split: split),
        _view(wantTarget, 8, planes: planes),
      );
      final want = await _pixels(wantTarget);

      final target = _target();
      final scene = _scene(kept: kept, split: split);
      // The frames a kept draw takes to be kept, were the pass to keep it.
      for (var frame = 0; frame < 3; frame++) {
        _render(scene, _view(target, 0, planes: planes));
      }
      expect(
        await _pixels(target),
        isNot(want),
        reason: 'the sheet moves with the camera',
      );

      final replayed = _appFrame(scene, _view(target, 8, planes: planes));
      expect(await _pixels(target), want);
      expect(replayed, isFalse);
    });
  }

  test('a frame of kept translucent draws alone is replayed for another '
      'camera', () async {
    final target = _target();
    final scene = _scene(kept: true);
    for (var frame = 0; frame < 3; frame++) {
      _render(scene, _view(target, 0));
    }
    expect(_appFrame(scene, _view(target, 8)), isTrue);
    expect(
      _appFrame(scene, _view(target, 16)),
      isTrue,
      reason: 'still replays',
    );
  });
}
