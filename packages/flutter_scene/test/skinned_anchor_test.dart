// An anchored skinned mesh draws at its anchor less the draw origin, as an
// anchored unskinned mesh does: its joint matrices leave the anchor out like
// every globalTransform, so the skinned draw adds it. The draws need a GPU
// device: flutter test --enable-impeller --enable-flutter-gpu.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

const int _width = 128;
const int _height = 64;

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

PerspectiveCamera _camera() => PerspectiveCamera(
  position: Vector3(0, 0, 10),
  target: Vector3.zero(),
  fovRadiansY: math.pi / 4,
);

Material _green() => UnlitMaterial()..baseColorFactor = Vector4(0, 1, 0, 1);

// Whether the quarter and three-quarter points of the middle row are green.
Future<({bool first, bool second})> _draw(Scene scene) async {
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera(),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _width + 0.0, _height + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_width, _height);
  final ByteData bytes = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  image.dispose();
  bool green(int x) {
    final offset = ((_height ~/ 2) * _width + x) * 4;
    return bytes.getUint8(offset + 1) > 128 && bytes.getUint8(offset) < 64;
  }

  return (first: green(_width ~/ 4), second: green(_width * 3 ~/ 4));
}

// A quad of both windings over x in [-5.5, -2.5], bound wholly to joint 0.
SkinnedGeometry _skinnedQuad() {
  const corners = [
    [-5.5, -1.5],
    [-2.5, -1.5],
    [-2.5, 1.5],
    [-5.5, 1.5],
  ];
  final vertices = Float32List(4 * 26);
  for (var index = 0; index < 4; index++) {
    final at = index * 26;
    vertices
      ..[at] = corners[index][0]
      ..[at + 1] = corners[index][1]
      ..[at + 5] = 1
      ..[at + 10] = 1
      ..[at + 11] = 1
      ..[at + 12] = 1
      ..[at + 13] = 1
      ..[at + 22] = 1;
  }
  return SkinnedGeometry()..uploadVertexData(
    vertices,
    4,
    Uint16List.fromList([0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]),
  );
}

// The anchor lies far from the scene's zero, and the draw origin eight units
// short of it along x, so a mesh stated over x in [-5.5, -2.5] from its
// anchor draws over [2.5, 5.5], which the camera sees at the first point; at
// the draw origin itself it would cover the second.
const double _anchorX = 6371000.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('an anchored mesh draws at its anchor less the draw origin', () {
    if (_gpuAvailable()) setUpAll(Scene.preload);

    test(
      'a skinned mesh draws at its anchor, as an unskinned one does',
      () async {
        if (!_gpuAvailable()) {
          markTestSkipped('Flutter GPU is unavailable.');
          return;
        }
        Future<({bool first, bool second})> drawAnchored(Node node) async {
          final scene = Scene();
          addTearDown(scene.dispose);
          scene.setDrawOrigin(_anchorX - 8, 0, 0);
          node.setAnchor(_anchorX, 0, 0);
          scene.add(node);
          return _draw(scene);
        }

        final unskinned = await drawAnchored(
          Node(mesh: Mesh(CuboidGeometry(Vector3(3, 3, 0.2)), _green()))
            ..position = Vector3(-4, 0, 0),
        );
        expect(unskinned, (first: true, second: false));

        final joint = Node(name: 'joint');
        final skinned = Node(
          name: 'skinned',
          mesh: Mesh(_skinnedQuad(), _green()),
        )..add(joint);
        skinned.skin = Skin()
          ..joints.add(joint)
          ..inverseBindMatrices.add(Matrix4.identity());
        expect(await drawAnchored(skinned), (first: true, second: false));
      },
    );
  });
}
