// Clip volume tests. A material's clip volume discards the fragments inside
// it in the built-in lit and unlit shaders and in every physical variant,
// and a material without one draws every fragment. GPU-gated like the other
// render suites.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
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

const int _width = 64;
const int _height = 32;

// Keeps the half of world space with x <= 0 and clips the rest.
final ClipVolume _rightHalf = ClipVolume([Vector4(1, 0, 0, 0)]);

final Map<String, Material Function()> _materials = {
  'standard': () =>
      PhysicallyBasedMaterial()..baseColorFactor = Vector4(0, 1, 0, 1),
  'unlit': () => UnlitMaterial()..baseColorFactor = Vector4(0, 1, 0, 1),
  'clearcoat': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..clearcoat = 1,
  'sheen': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..sheenColor = Vector4(1, 1, 1, 1),
  'specular': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..specularColorTexture = GpuTextureSource(
      Material.getWhitePlaceholderTexture(),
    ),
  'iridescence': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..iridescence = 1,
  'anisotropy': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..anisotropy = 0.5,
  'transmission': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..transmission = 1,
  'diffuse transmission': () => PhysicallyBasedMaterial()
    ..baseColorFactor = Vector4(0, 1, 0, 1)
    ..diffuseTransmission = 1,
};

// Draws a wide card in [front] material over a red unlit backdrop and
// returns the red and green of a pixel on each side of x = 0.
Future<({ui.Color left, ui.Color right})> _draw(Material front) async {
  final scene = Scene()
    ..add(
      Node(
        mesh: Mesh(
          CuboidGeometry(Vector3(40, 40, 0.1)),
          UnlitMaterial()..baseColorFactor = Vector4(1, 0, 0, 1),
        ),
      )..position = Vector3(0, 0, 2),
    )
    ..add(Node(mesh: Mesh(CuboidGeometry(Vector3(40, 40, 0.1)), front)));
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _width + 0.0, _height + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_width, _height);
  final ByteData bytes = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  image.dispose();
  scene.dispose();
  ui.Color at(int x) {
    final offset = ((_height ~/ 2) * _width + x) * 4;
    return ui.Color.fromARGB(
      255,
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
  }

  return (left: at(_width ~/ 4), right: at(_width * 3 ~/ 4));
}

bool _backdrop(ui.Color color) => color.r > 0.5 && color.g < 0.2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a point is clipped when it lies in front of every plane', () {
    final box = ClipVolume([
      Vector4(1, 0, 0, 0),
      Vector4(-1, 0, 0, 2),
      Vector4(0, 1, 0, 1),
    ]);

    expect(box.contains(Vector3(1, 0, 0)), isTrue);
    expect(box.contains(Vector3(-1, 0, 0)), isFalse);
    expect(box.contains(Vector3(3, 0, 0)), isFalse);
    expect(box.contains(Vector3(1, -2, 0)), isFalse);
    expect(box.contains(Vector3.zero()), isFalse);
  });

  test('a clip volume holds one to six planes and keeps its own copies', () {
    final plane = Vector4(1, 0, 0, 0);
    final volume = ClipVolume([plane]);
    plane.x = -1;

    expect(volume.planes.single, Vector4(1, 0, 0, 0));
    expect(() => volume.planes.add(plane), throwsUnsupportedError);
    expect(() => ClipVolume(const []), throwsArgumentError);
    expect(
      () => ClipVolume(List.filled(ClipVolume.maxPlanes + 1, plane)),
      throwsArgumentError,
    );
  });

  test('a material has no clip volume until one is set', () {
    expect(PhysicallyBasedMaterial().clipVolume, isNull);
    expect(UnlitMaterial().clipVolume, isNull);
  });

  if (!_gpuAvailable()) {
    test(
      'clip volume draw (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(Scene.preload);

  for (final MapEntry(key: name, value: material) in _materials.entries) {
    test('a $name material draws its fragments outside its clip volume '
        'and none inside it', () async {
      final drawn = await _draw(material()..clipVolume = _rightHalf);

      expect(
        (_backdrop(drawn.left), _backdrop(drawn.right)),
        (false, true),
        reason: '$drawn',
      );
    });

    test(
      'a $name material without a clip volume draws every fragment',
      () async {
        final drawn = await _draw(material());

        expect(_backdrop(drawn.left), isFalse, reason: '${drawn.left}');
        expect(_backdrop(drawn.right), isFalse, reason: '${drawn.right}');
      },
    );
  }
}
