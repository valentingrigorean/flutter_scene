// A translucent double-sided material draws both faces, as an opaque one
// does: the translucent pass draws the mesh's back faces and then its front
// faces, so a back face blends and the near side of the mesh lies over its
// far side whatever the triangle order.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
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

// One quad across the view at [distance], counter-clockwise as the camera
// sees it when [facing], clockwise otherwise.
List<double> _quad(double distance, {required bool facing}) {
  const h = 50.0;
  final z = -distance;
  final corners = [
    [-h, -h, z],
    [h, -h, z],
    [h, h, z],
    [-h, h, z],
  ];
  return [for (final corner in facing ? corners : corners.reversed) ...corner];
}

MeshGeometry _quads(List<({double distance, bool facing, Vector4 color})> of) {
  final positions = <double>[];
  final colors = <double>[];
  final indices = <int>[];
  for (final quad in of) {
    final first = positions.length ~/ 3;
    positions.addAll(_quad(quad.distance, facing: quad.facing));
    for (var corner = 0; corner < 4; corner++) {
      colors.addAll(quad.color.storage);
    }
    indices.addAll([first, first + 1, first + 2, first, first + 2, first + 3]);
  }
  return MeshGeometry.fromArrays(
    positions: Float32List.fromList(positions),
    colors: Float32List.fromList(colors),
    indices: indices,
  );
}

UnlitMaterial _glass({required bool doubleSided}) => UnlitMaterial()
  ..baseColorFactor = Vector4(1, 1, 1, 0.5)
  ..alphaMode = AlphaMode.blend
  ..doubleSided = doubleSided;

Future<List<int>> _centre(Node node) async {
  await Scene.initializeStaticResources();
  final scene = Scene()..add(node);
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
  scene.dispose();
  final rgba = bytes!.buffer.asUint8List();
  final at = (_size.height ~/ 2 * _size.width.round() + _size.width ~/ 2) * 4;
  return rgba.sublist(at, at + 3);
}

final _red = Vector4(1, 0, 0, 1);
final _blue = Vector4(0, 0, 1, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a translucent double-sided material culls no face', () {
    expect(_glass(doubleSided: true).renderCullMode, gpu.CullMode.none);
    expect(_glass(doubleSided: false).renderCullMode, gpu.CullMode.backFace);
  });

  if (!_gpuAvailable()) {
    test(
      'a translucent double-sided mesh draws its back faces (skipped: no GPU '
      'device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  test('a translucent double-sided mesh draws a back face blended, and a '
      'single-sided one culls it', () async {
    Node turnedAway({required bool doubleSided}) => Node(
      mesh: Mesh(
        _quads([(distance: 20, facing: false, color: _red)]),
        _glass(doubleSided: doubleSided),
      ),
    );

    final both = await _centre(turnedAway(doubleSided: true));
    final one = await _centre(turnedAway(doubleSided: false));

    expect(both[0], greaterThan(60), reason: 'the back face at $both');
    expect(both[0], lessThan(250), reason: 'the back face blends at $both');
    expect(one[0], lessThan(10), reason: 'the culled face at $one');
  });

  test('a translucent double-sided mesh draws its back faces before its '
      'front faces, whatever their triangle order', () async {
    final centre = await _centre(
      Node(
        mesh: Mesh(
          _quads([
            (distance: 10, facing: true, color: _red),
            (distance: 20, facing: false, color: _blue),
          ]),
          _glass(doubleSided: true),
        ),
      ),
    );

    expect(centre[2], greaterThan(30), reason: 'the far face at $centre');
    expect(
      centre[0],
      greaterThan(centre[2]),
      reason: 'the near face lies over the far face at $centre',
    );
  });
}
