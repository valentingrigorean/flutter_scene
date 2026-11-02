// A draw the kept color pass encodes each frame, one the backend does not
// keep, is culled to the view as the draws the pass keeps are.

import 'dart:ui' as ui;

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

class _Encoded extends UnlitMaterial {
  _Encoded({required this.blends});

  final bool blends;

  @override
  bool isOpaque() => !blends;

  @override
  bool get colorRetainable => false;

  @override
  bool get participatesInDebugViews => false;
}

Node _box(_Encoded material, Vector3 at) => Node(
  mesh: Mesh(CuboidGeometry(Vector3.all(2)), material),
  localTransform: Matrix4.translation(at),
);

// The color pass's draws in the last of four frames, each of which changes
// [material] so that it renders.
Future<int> _colorDraws(Scene scene, _Encoded material) async {
  for (var frame = 0; frame < 4; frame++) {
    material.baseColorFactor = Vector4(1, 0, frame / 100, 0.5);
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
  final passes = scene.renderStats.latest!.views.single.passes;
  return passes.singleWhere((pass) => pass.name == 'ScenePass').counters.draws;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test(
      'an encoded draw outside the view is culled (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(Scene.initializeStaticResources);

  for (final blends in [false, true]) {
    final kind = blends ? 'a translucent' : 'an opaque';
    test('$kind draw the backend does not keep is not encoded in a frame '
        'that does not show it, and is in one that does', () async {
      final material = _Encoded(blends: blends);
      final behind = Scene()..add(_box(material, Vector3(0, 0, 10)));
      addTearDown(behind.dispose);
      expect(await _colorDraws(behind, material), 0);
      expect(activeRenderCounters.colorItemsEncoded, 1);

      final ahead = Scene()..add(_box(material, Vector3(0, 0, -10)));
      addTearDown(ahead.dispose);
      expect(await _colorDraws(ahead, material), 1);
      expect(activeRenderCounters.colorItemsEncoded, 1);
    });
  }
}
