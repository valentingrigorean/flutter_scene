// A kept draw of a frame the GPU has not run yet draws with the camera of its
// own frame, however many frames were encoded after it.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/frame_transients.dart'
    show rendererSubmissions;
import 'package:flutter_scene/src/render/render_stats.dart'
    show activeRenderCounters;
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

const _side = 64;
const _frames = 8;

// The test shader bundle compiles the debug views in, which keep a draw that
// takes part in them from being kept.
class _Flat extends UnlitMaterial {
  _Flat() {
    baseColorFactor = Vector4(0, 0, 1, 1);
  }

  @override
  bool get participatesInDebugViews => false;
}

Scene _sceneOf(double side) => Scene()
  ..add(
    Node(
      mesh: Mesh(CuboidGeometry(Vector3(side, side, 0.01)), _Flat()),
      localTransform: Matrix4.translationValues(0, 0, -50),
    ),
  );

PerspectiveCamera _cameraAt(double x) => PerspectiveCamera(
  position: Vector3(x, 0, 0),
  target: Vector3(x, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);

PerspectiveCamera _cameraOf(int frame) => _cameraAt((frame - 3.5) * 5);

RenderTexture _draw(Scene scene, Camera camera, {int side = _side}) {
  final target = RenderTexture(width: side, height: side, presents: true);
  final recorder = ui.PictureRecorder();
  scene.renderViews([
    RenderView(camera: camera, target: target),
  ], ui.Canvas(recorder));
  recorder.endRecording().dispose();
  return target;
}

// The columns of the middle row of [target] that are blue.
Future<String> _blueColumns(RenderTexture target) async {
  final image = gpu.gpuHost.textureToImage(target.texture!);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  target.dispose();
  final rgba = Uint8List.sublistView(bytes!);
  final row = (_side ~/ 2) * _side;
  return [
    for (var x = 0; x < _side; x++)
      rgba[(row + x) * 4 + 2] > 150 && rgba[(row + x) * 4] < 100 ? '#' : '.',
  ].join();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test(
      'a kept draw in flight draws its own frame (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(() async {
    await Scene.initializeStaticResources();
    final warmUp = _sceneOf(200);
    for (var frame = 0; frame < 2; frame++) {
      await _blueColumns(_draw(warmUp, _cameraAt(0)));
    }
    warmUp.dispose();
  });

  test('a kept draw of each of $_frames frames encoded behind a frame the GPU '
      'is still running draws with the camera of its own frame', () async {
    final scene = _sceneOf(6);
    addTearDown(scene.dispose);
    final veil = Mesh(
      CuboidGeometry(Vector3(200, 200, 0.01)),
      UnlitMaterial()
        ..alphaMode = AlphaMode.blend
        ..baseColorFactor = Vector4(1, 0, 0, 0.01),
    );
    final slow = Scene();
    addTearDown(slow.dispose);
    for (var layer = 0; layer < 400; layer++) {
      slow.add(
        Node(
          mesh: veil,
          localTransform: Matrix4.translationValues(0, 0, -50 - layer * 0.1),
        ),
      );
    }

    final alone = [
      for (var frame = 0; frame < _frames; frame++)
        await _blueColumns(_draw(scene, _cameraOf(frame))),
    ];
    await _blueColumns(_draw(slow, _cameraAt(0)));

    final held = _draw(slow, _cameraAt(0), side: 4096);
    activeRenderCounters.reset();
    final targets = [
      for (var frame = 0; frame < _frames; frame++)
        _draw(scene, _cameraOf(frame)),
    ];
    final kept = activeRenderCounters.colorItemsKept;
    final inFlight = rendererSubmissions.framesInFlight;
    final behind = [for (final target in targets) await _blueColumns(target)];
    held.dispose();

    expect(kept, _frames);
    expect(inFlight, greaterThan(4));
    expect(alone.toSet(), hasLength(_frames), reason: 'alone: $alone');
    expect(behind, alone);
  });
}
