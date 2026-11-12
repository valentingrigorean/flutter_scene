// Two opaque draws that cover the same pixels at the same depth draw in one
// order from scene to scene, and kept as render items in the order they are
// encoded in.

import 'dart:ui' as ui;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart'
    show activeRenderCounters;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);
const _size = ui.Size(16, 16);

class _Flat extends UnlitMaterial {
  _Flat(Vector4 color) {
    baseColorFactor = color;
  }

  @override
  bool get participatesInDebugViews => false;
}

// The red, green and blue of the centre pixel of the third frame of two
// slabs in one place, the green one made first and added last, and how many
// colour draws that frame drew from kept items.
Future<({List<int> color, int kept})> _overlap() async {
  final geometry = CuboidGeometry(Vector3(20, 20, 0.01));
  final green = _Flat(Vector4(0, 1, 0, 1));
  final red = _Flat(Vector4(1, 0, 0, 1));
  final at = Matrix4.translationValues(0, 0, -50);
  final scene = Scene()
    ..add(Node(mesh: Mesh(geometry, red), localTransform: at))
    ..add(Node(mesh: Mesh(geometry, green), localTransform: at));
  addTearDown(scene.dispose);
  late List<int> color;
  for (var frame = 0; frame < 3; frame++) {
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
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
    final centre = (8 * _size.width.round() + 8) * 4;
    color = [for (var c = 0; c < 3; c++) bytes.getUint8(centre + c)];
  }
  return (color: color, kept: activeRenderCounters.colorItemsKept);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!gpuAvailable()) {
    test(
      'opaque draws draw in one order (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(() async {
    await Scene.initializeStaticResources();
    // The first scene builds the pipelines the others keep their draws with.
    await _overlap();
  });

  test('two opaque draws at one depth show the material made last in every '
      'scene, encoded or kept', () async {
    final kept = [for (var scene = 0; scene < 8; scene++) await _overlap()];
    gpu.debugKeepsNoItems = true;
    addTearDown(() => gpu.debugKeepsNoItems = false);
    final encoded = [for (var scene = 0; scene < 8; scene++) await _overlap()];

    expect([for (final drawn in kept) drawn.kept], everyElement(2));
    expect([for (final drawn in encoded) drawn.kept], everyElement(0));
    final red = encoded.first.color;
    expect(red[0], greaterThan(red[1]));
    expect([for (final drawn in encoded) drawn.color], everyElement(red));
    expect([for (final drawn in kept) drawn.color], everyElement(red));
  });
}
