// Clip volume tests. A material's clip volume discards the fragments inside
// its cut planes and outside its keep planes in the built-in lit and unlit
// shaders and in every physical variant, and a material without one draws
// every fragment. GPU-gated like the other render suites.

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

// Keeps the same half through a keep plane alone.
final ClipVolume _keepLeftHalf = ClipVolume(
  const [],
  keep: [Vector4(-1, 0, 0, 0)],
);

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

  test('a clip volume holds up to six cut and four keep planes and keeps '
      'its own copies', () {
    final plane = Vector4(1, 0, 0, 0);
    final volume = ClipVolume([plane], keep: [plane]);
    plane.x = -1;

    expect(volume.planes.single, Vector4(1, 0, 0, 0));
    expect(volume.keep.single, Vector4(1, 0, 0, 0));
    expect(() => volume.planes.add(plane), throwsUnsupportedError);
    expect(() => volume.keep.add(plane), throwsUnsupportedError);
    expect(() => ClipVolume(const []), throwsArgumentError);
    expect(ClipVolume(const [], keep: [plane]).planes, isEmpty);
    expect(
      () => ClipVolume(List.filled(ClipVolume.maxPlanes + 1, plane)),
      throwsArgumentError,
    );
    expect(
      () => ClipVolume(
        const [],
        keep: List.filled(ClipVolume.maxKeepPlanes + 1, plane),
      ),
      throwsArgumentError,
    );
  });

  test('a point behind a keep plane is discarded, and so is one in the '
      'cut region', () {
    final slab = ClipVolume(
      const [],
      keep: [Vector4(0, 0, 1, 1), Vector4(0, 0, -1, 1)],
    );
    expect(slab.discards(Vector3(5, 5, 0)), isFalse);
    expect(slab.discards(Vector3(0, 0, 1)), isFalse);
    expect(slab.discards(Vector3(0, 0, 2)), isTrue);
    expect(slab.discards(Vector3(0, 0, -2)), isTrue);
    expect(slab.contains(Vector3.zero()), isFalse);

    final both = ClipVolume([Vector4(1, 0, 0, 0)], keep: [Vector4(0, 1, 0, 0)]);
    expect(both.discards(Vector3(-1, 1, 0)), isFalse);
    expect(both.discards(Vector3(1, 1, 0)), isTrue);
    expect(both.discards(Vector3(-1, -1, 0)), isTrue);
  });

  group('the ClipInfo block', () {
    // The block as floats: six cut planes, then four keep planes.
    List<double> floats(ClipVolume volume) {
      final bytes = volume.uniformBytes;
      expect(bytes.lengthInBytes, ClipVolume.uniformByteSize);
      expect(ClipVolume.uniformByteSize, 160);
      return bytes.buffer.asFloat32List(bytes.offsetInBytes, 40).toList();
    }

    const front = [0.0, 0.0, 0.0, 1.0];
    const zero = [0.0, 0.0, 0.0, 0.0];

    test('of a cut-only volume pads its cut planes to cut nothing more and '
        'writes zero keep planes', () {
      expect(floats(ClipVolume([Vector4(1, 2, 3, 4), Vector4(5, 6, 7, 8)])), [
        1, 2, 3, 4, //
        5, 6, 7, 8,
        ...front, ...front, ...front, ...front,
        ...zero, ...zero, ...zero, ...zero,
      ]);
    });

    test('of a keep-only volume writes zero cut planes, whose first cuts '
        'nothing, and pads its keep planes with zero planes', () {
      expect(floats(ClipVolume(const [], keep: [Vector4(1, 2, 3, 4)])), [
        ...zero, ...zero, ...zero, ...zero, ...zero, ...zero,
        1, 2, 3, 4, //
        ...zero, ...zero, ...zero,
      ]);
    });

    test('of a volume that cuts and keeps writes both lists', () {
      expect(
        floats(
          ClipVolume(
            [Vector4(1, 2, 3, 4)],
            keep: [Vector4(5, 6, 7, 8), Vector4(9, 10, 11, 12)],
          ),
        ),
        [
          1, 2, 3, 4, //
          ...front, ...front, ...front, ...front, ...front,
          5, 6, 7, 8, //
          9, 10, 11, 12,
          ...zero, ...zero,
        ],
      );
    });
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

    test('a $name material draws its fragments inside its keep planes '
        'and none outside them', () async {
      final drawn = await _draw(material()..clipVolume = _keepLeftHalf);

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
