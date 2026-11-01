// The opaque draws the backend keeps draw at their node's render order among
// the opaque draws the pass encodes, so of two coplanar surfaces the one of
// the higher render order shows, whichever of them is kept.

import 'dart:typed_data';
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

// The test shader bundle compiles the debug views in, which keep a draw that
// takes part in them from being kept.
class _Flat extends UnlitMaterial {
  _Flat(double red, double blue) {
    baseColorFactor = Vector4(red, 0, blue, 1);
  }

  @override
  bool get participatesInDebugViews => false;
}

Node _slab(UnlitMaterial material, double order) => Node(
  mesh: Mesh(CuboidGeometry(Vector3(200, 200, 0.01)), material),
  localTransform: Matrix4.translationValues(0, 0, -50),
)..renderOrder = order;

Future<List<int>> _centre(Scene scene) async {
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
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final rgba = Uint8List.sublistView(bytes!);
  final at = (32 * _size.width.round() + 32) * 4;
  return rgba.sublist(at, at + 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test(
      'a kept opaque draw draws at its render order (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(() async {
    await Scene.initializeStaticResources();
    final warmUp = Scene()..add(_slab(_Flat(1, 1), 0));
    for (var frame = 0; frame < 2; frame++) {
      await _centre(warmUp);
    }
    warmUp.dispose();
  });

  for (final (keptOrder, encodedOrder) in const [(0.0, -1.0), (-1.0, 0.0)]) {
    test('a kept opaque draw of render order $keptOrder and an encoded one '
        'of $encodedOrder in the same place show the one of the higher '
        'order', () async {
      final kept = _Flat(0, 1);
      final encoded = _Flat(1, 0);
      final scene = Scene()
        ..add(_slab(kept, keptOrder))
        ..add(_slab(encoded, encodedOrder));
      addTearDown(scene.dispose);

      var centre = <int>[];
      for (var frame = 0; frame < 4; frame++) {
        encoded.baseColorFactor = Vector4(1, 0, frame / 100, 1);
        activeRenderCounters.reset();
        centre = await _centre(scene);
      }

      expect(activeRenderCounters.colorItemsKept, 1);
      expect(activeRenderCounters.colorItemsEncoded, 1);
      final keptShows = keptOrder > encodedOrder;
      expect(
        centre[keptShows ? 2 : 0],
        greaterThan(200),
        reason: 'the centre at $centre',
      );
    });
  }

  test('a frame whose opaque draws are all encoded is not one another camera '
      'replays', () async {
    final target = RenderTexture(width: 64, height: 64, presents: true);
    final scene = Scene()
      ..add(_slab(UnlitMaterial()..baseColorFactor = Vector4(1, 0, 0, 1), 0));
    addTearDown(scene.dispose);
    RenderView view(double x) => RenderView(
      camera: PerspectiveCamera(
        position: Vector3(x, 0, 0),
        target: Vector3(x, 0, -1),
        up: Vector3(0, 1, 0),
        fovNear: 0.1,
        fovFar: 1000,
      ),
      target: target,
    );

    for (var frame = 0; frame < 3; frame++) {
      activeRenderCounters.reset();
      final recorder = ui.PictureRecorder();
      scene.renderViews([view(0)], ui.Canvas(recorder));
      recorder.endRecording().dispose();
    }

    expect(activeRenderCounters.colorItemsKept, 0);
    expect(activeRenderCounters.colorItemsEncoded, 1);
    expect(scene.cameraFrame([view(1)]), isNull);
  });
}
