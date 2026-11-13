// A geometry whose vertex stage reads the draw origin from a view block keeps
// its draw across a move of the origin: the pass places the bounds of the
// draw and records nothing. The app's view blocks reach the depth prepass and
// the shadow cascades at the index the item set gives them.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/shared/kept_draw.dart'
    show debugChecksKeptDraws;
import 'package:flutter_scene/src/render/render_stats.dart'
    show activeRenderCounters;
import 'package:flutter_scene/src/render/retained_draws.dart';
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
const _site = 6378137.0;

final Float32List _quad = Float32List.fromList([
  -3, -3, 0, 3, -3, 0, 3, 3, 0, -3, 3, 0, //
]);

// The test shader bundle compiles the debug views in, which keep a draw that
// takes part in them from being kept.
class _Flat extends UnlitMaterial {
  _Flat() {
    baseColorFactor = Vector4(0, 0, 1, 1);
  }

  @override
  bool get participatesInDebugViews => false;
}

// A quad that says its vertex stage reads the draw origin from the view.
// It reads none, so the draw a pass keeps of it is stale after a move: the
// cases read what the pass recorded and culled, not where the draw landed.
class _FromView extends MeshGeometry {
  _FromView() : super.fromArrays(positions: _quad, indices: [0, 1, 2, 0, 2, 3]);

  @override
  bool get drawsFromViewOrigin => true;
}

Scene _sceneOf(Geometry geometry) => Scene()
  ..setDrawOrigin(_site, 0, 0)
  ..add(
    Node(
      mesh: Mesh(geometry, _Flat()),
      localTransform: Matrix4.translationValues(0, 0, -50),
    )..setAnchor(_site, 0, 0),
  );

final PerspectiveCamera _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);

// Draws [scene] and returns the draws the frame recorded and whether the
// middle of the frame is blue.
Future<({int recorded, bool drawn})> _frame(Scene scene) async {
  final target = RenderTexture(width: _side, height: _side, presents: true);
  final before = activeRenderCounters.drawsKept;
  final recorder = ui.PictureRecorder();
  scene.renderViews([
    RenderView(camera: _camera, target: target),
  ], ui.Canvas(recorder));
  recorder.endRecording().dispose();
  final recorded = activeRenderCounters.drawsKept - before;
  final image = gpu.gpuHost.textureToImage(target.texture!);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  target.dispose();
  final rgba = Uint8List.sublistView(bytes!);
  final middle = ((_side ~/ 2) * _side + _side ~/ 2) * 4;
  return (
    recorded: recorded,
    drawn: rgba[middle + 2] > 150 && rgba[middle] < 100,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a pass that states blocks of its own supplies the app view blocks '
      'after them, at the index the item set gives the first', () {
    final scene = RenderScene();
    final view = ByteData(4);
    final depth = ByteData(8);
    expect(SceneItems.withAppBlocks(scene, [view]), [view]);
    final clock = ByteData(16);
    final origin = ByteData(16);
    scene.viewBlocks
      ..['Clock'] = (() => clock)
      ..['Origin'] = (() => origin);
    for (final engine in [
      [view],
      [view, depth],
    ]) {
      final blocks = SceneItems.withAppBlocks(scene, engine);
      expect(blocks.sublist(0, engine.length), engine);
      expect(blocks.sublist(SceneItems.appBlock), [clock, origin]);
      expect(
        blocks.sublist(engine.length, SceneItems.appBlock),
        everyElement(
          isA<ByteData>().having((b) => b.lengthInBytes, 'length', 0),
        ),
      );
    }
  });

  if (!_gpuAvailable()) {
    test(
      'a move of the draw origin records no draw (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(Scene.initializeStaticResources);

  test('a move of the draw origin records the kept draw of a mesh again the '
      'first time, and records none of a geometry that draws from the view '
      'origin, whose bounds it places', () async {
    final checks = debugChecksKeptDraws;
    debugChecksKeptDraws = false;
    addTearDown(() => debugChecksKeptDraws = checks);
    final mesh = _sceneOf(
      MeshGeometry.fromArrays(positions: _quad, indices: [0, 1, 2, 0, 2, 3]),
    );
    addTearDown(mesh.dispose);
    final fromView = _sceneOf(_FromView());
    addTearDown(fromView.dispose);
    for (final scene in [mesh, fromView]) {
      for (var frame = 0; frame < 3; frame++) {
        await _frame(scene);
      }
      expect(await _frame(scene), (recorded: 0, drawn: true));
    }

    mesh.setDrawOrigin(_site + 1, 0, 0);
    expect((await _frame(mesh)).recorded, 1);

    fromView.setDrawOrigin(_site + 1, 0, 0);
    expect(await _frame(fromView), (recorded: 0, drawn: true));
    fromView.setDrawOrigin(_site + 500, 0, 0);
    expect(
      await _frame(fromView),
      (recorded: 0, drawn: false),
      reason: 'the bounds stand 500 units off the view, so the draw is culled',
    );
    fromView.setDrawOrigin(_site, 0, 0);
    expect(await _frame(fromView), (recorded: 0, drawn: true));
  });
}
