// A draw that changes while it streams in stays kept; one that keeps changing
// is encoded each frame. An encoded draw refuses the walk of a render thread,
// so it takes a run of changes, not a pair.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_scene/scene.dart';
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

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);
const _size = ui.Size(64, 64);

// The test shader bundle compiles the debug views in, which keep a draw that
// takes part in them from being kept.
class _Flat extends UnlitMaterial {
  @override
  bool get participatesInDebugViews => false;
}

Scene _sceneOf(Material material) => Scene()
  ..add(
    Node(
      mesh: Mesh(CuboidGeometry(Vector3(200, 200, 0.01)), material),
      localTransform: Matrix4.translationValues(0, 0, -50),
    ),
  );

Future<void> _render(Scene scene) async {
  activeRenderCounters.reset();
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera,
    ui.Canvas(recorder),
    viewport: ui.Offset.zero & _size,
    pixelRatio: 1.0,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.round(),
    _size.height.round(),
  );
  picture.dispose();
  await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test(
      'a changing draw stays kept (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(() async {
    await Scene.initializeStaticResources();
    final warmUp = _sceneOf(_Flat());
    for (var frame = 0; frame < 2; frame++) {
      await _render(warmUp);
    }
    warmUp.dispose();
  });

  test('a draw that changes in a few frames in a row stays kept', () async {
    final material = _Flat();
    final scene = _sceneOf(material);
    addTearDown(scene.dispose);
    await _render(scene);
    for (var frame = 0; frame < 3; frame++) {
      material.baseColorFactor = Vector4(frame / 10, 0, 0, 1);
      await _render(scene);
      expect(activeRenderCounters.colorItemsEncoded, 0);
      expect(activeRenderCounters.colorItemsKept, 1);
    }
  });

  test('a draw that changes in every frame is encoded', () async {
    final material = _Flat();
    final scene = _sceneOf(material);
    addTearDown(scene.dispose);
    for (var frame = 0; frame < 8; frame++) {
      material.baseColorFactor = Vector4(frame / 10, 0, 0, 1);
      await _render(scene);
    }
    expect(activeRenderCounters.colorItemsEncoded, 1);
    expect(activeRenderCounters.colorItemsKept, 0);
  });

  test('a frame drawn only into a target is not a blank frame', () {
    final scene = _sceneOf(_Flat());
    addTearDown(scene.dispose);
    final printed = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    addTearDown(() => debugPrint = print);
    final target = RenderTexture(width: 64, height: 64, presents: true);
    final recorder = ui.PictureRecorder();
    scene.renderViews([
      RenderView(camera: _camera, target: target),
    ], ui.Canvas(recorder));
    recorder.endRecording().dispose();
    expect(printed.where((line) => line.contains('blank frame')), isEmpty);
  });
}
