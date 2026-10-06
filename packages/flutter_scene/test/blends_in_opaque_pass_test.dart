// A translucent material that blends in the opaque pass draws among the
// opaque draws at its node's render order, blended and with no depth write,
// so an opaque draw of a higher render order draws over it wherever it is
// nearer, and sceneTranslucentDraws leaves it out.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _RecordingMaterial extends UnlitMaterial {
  _RecordingMaterial(this.label, this.drawn, {required bool opaque}) {
    if (!opaque) {
      alphaMode = AlphaMode.blend;
      baseColorFactor = Vector4(1, 1, 1, 0.5);
    }
  }

  final String label;
  final List<String> drawn;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    drawn.add(label);
    super.bind(pass, transientsBuffer, lighting);
  }
}

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
const _size = ui.Size(200, 200);

Node _slab(
  String name,
  double distance,
  Material material, {
  double order = 0,
  double width = 200,
  double x = 0,
}) => Node(
  name: name,
  mesh: Mesh(CuboidGeometry(Vector3(width, 200, 0.01)), material),
  localTransform: Matrix4.translationValues(x, 0, -distance),
)..renderOrder = order;

UnlitMaterial _flat(Vector4 color, {bool overOpaque = false}) {
  final material = UnlitMaterial()..baseColorFactor = color;
  if (color.w < 1) material.alphaMode = AlphaMode.blend;
  material.blendsInOpaquePass = overOpaque;
  return material;
}

Future<Uint8List> _frame(Scene scene) async {
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
  return bytes!.buffer.asUint8List();
}

List<int> _pixel(Uint8List rgba, int x, int y) {
  final at = (y * _size.width.round() + x) * 4;
  return rgba.sublist(at, at + 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sceneTranslucentDraws leaves out a translucent material that blends '
      'in the opaque pass', () {
    final root = Node()
      ..add(_slab('glass', 60, _flat(Vector4(1, 1, 1, 0.5))))
      ..add(
        _slab('overlay', 50, _flat(Vector4(1, 1, 1, 0.5), overOpaque: true)),
      );

    final draws = sceneTranslucentDraws(root, _camera, _size);

    expect([for (final draw in draws) draw.node.name], ['glass']);
  });

  if (!_gpuAvailable()) {
    test(
      'a material that blends in the opaque pass draws at its render order '
      '(skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  test('a material that blends in the opaque pass draws after the opaque '
      'draws of a lower render order and before those of a higher one and '
      'every translucent draw', () async {
    await Scene.initializeStaticResources();
    final drawn = <String>[];
    final scene = Scene();
    for (final node in [
      _slab(
        'glass',
        20,
        _RecordingMaterial('glass', drawn, opaque: false),
        order: -5,
      ),
      _slab('wall', 40, _RecordingMaterial('wall', drawn, opaque: true)),
      _slab(
        'overlay',
        49,
        _RecordingMaterial('overlay', drawn, opaque: false)
          ..blendsInOpaquePass = true,
        order: -1,
      ),
      _slab(
        'ground',
        50,
        _RecordingMaterial('ground', drawn, opaque: true),
        order: -2,
      ),
    ]) {
      scene.add(node);
    }

    await _frame(scene);
    scene.dispose();

    expect(drawn, ['ground', 'overlay', 'wall', 'glass']);
  });

  test('an opaque draw of a higher render order that lies between a ground '
      'and its overlay that blends in the opaque pass keeps its colour, and '
      'the overlay blends over the ground beside it', () async {
    await Scene.initializeStaticResources();
    final scene = Scene()
      ..add(_slab('ground', 50, _flat(Vector4(0, 1, 0, 1)), order: -2))
      ..add(
        _slab(
          'overlay',
          49,
          _flat(Vector4(1, 0, 0, 0.5), overOpaque: true),
          order: -1,
        ),
      )
      ..add(_slab('foot', 49.5, _flat(Vector4(0, 0, 1, 1)), width: 20, x: -10));

    final rgba = await _frame(scene);
    scene.dispose();

    final foot = _pixel(rgba, 160, 100);
    final ground = _pixel(rgba, 40, 100);
    expect(foot[2], greaterThan(200), reason: 'the foot at $foot');
    expect(foot[0], lessThan(60), reason: 'the foot at $foot');
    expect(ground[0], greaterThan(100), reason: 'the overlay at $ground');
    expect(ground[1], greaterThan(100), reason: 'the ground at $ground');
  });
}
