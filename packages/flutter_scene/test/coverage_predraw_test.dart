@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/lod.dart' show lodScreenSize;
// ignore: implementation_imports
import 'package:flutter_scene/src/scene_encoder.dart'
    show
        coveragePipelineInputs,
        drawsCoverage,
        evictPipelinesForShaders,
        isPipelineBuilt;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

// The source with `//` comments removed, so prose mentioning discard does not
// count.
String _code(String source) =>
    source.split('\n').map((line) => line.split('//').first).join('\n');

const _size = ui.Size(100, 100);
const _eye = 10.0;
const _fov = math.pi / 4;

Future<bool> _encoderTakesCoverage(
  Material material, {
  required bool crossFading,
}) async {
  await Scene.initializeStaticResources();
  final scene = Scene();
  addTearDown(scene.dispose);
  final geometry = CuboidGeometry(Vector3.all(1));
  evictPipelinesForShaders({baseShaderLibrary['CoverageFragment']!});
  final node = Node(name: 'subject');
  if (crossFading) {
    final boundary = lodScreenSize(
      center: Vector3.zero(),
      radius: math.sqrt(3) / 2,
      cameraPosition: Vector3(0, 0, _eye),
      fovRadiansY: _fov,
    );
    node.addComponent(
      LodComponent([
        LodLevel(geometry: geometry, material: material, screenSize: boundary),
        LodLevel(
          geometry: geometry,
          material: material,
          screenSize: boundary / 4,
        ),
      ], blendRange: 0.1),
    );
  } else {
    node.mesh = Mesh(geometry, material);
  }
  scene.add(node);
  final recorder = ui.PictureRecorder();
  scene.renderViews(
    [
      RenderView(
        camera: PerspectiveCamera(
          position: Vector3(0, 0, _eye),
          target: Vector3.zero(),
          fovRadiansY: _fov,
        ),
      ),
    ],
    ui.Canvas(recorder),
    region: ui.Offset.zero & _size,
  );
  recorder.endRecording().dispose();
  return isPipelineBuilt(coveragePipelineInputs(geometry, material));
}

// Draws one mesh of two overlapping quads in [alphaMode]: the far quad comes
// first in the index order, so in the coverage color draw its fragments fail
// the equal depth test before the near quad's fragments shade.
Future<List<int>> _overlappingQuadsCentre(AlphaMode alphaMode) async {
  await Scene.initializeStaticResources();
  final scene = Scene();
  addTearDown(scene.dispose);
  final positions = <double>[
    for (final z in const [1.0, -1.0]) ...[
      -1, -1, z, 1, -1, z, 1, 1, z, -1, 1, z, //
    ],
  ];
  scene.add(
    Node(
      mesh: Mesh(
        MeshGeometry.fromArrays(
          positions: Float32List.fromList(positions),
          indices: const [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
        ),
        PhysicallyBasedMaterial()
          ..baseColorFactor = Vector4(0.1, 0.8, 0.2, 1)
          ..alphaMode = alphaMode
          ..doubleSided = true,
      ),
    ),
  );
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(),
    ui.Canvas(recorder),
    viewport: ui.Offset.zero & _size,
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  final offset =
      ((_size.height ~/ 2) * _size.width.toInt() + _size.width ~/ 2) * 4;
  return [
    for (var channel = 0; channel < 4; channel++)
      bytes.getUint8(offset + channel),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final noGpu = gpuAvailable()
      ? null
      : 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.';

  test('the opaque material shaders never discard', () {
    // A discard anywhere in a shader turns off early depth testing and
    // hidden-surface removal for its every draw on tiled GPUs; cutouts go
    // through the coverage pre-draw instead.
    for (final path in [
      'shaders/flutter_scene_standard.frag',
      'shaders/flutter_scene_unlit.frag',
    ]) {
      final code = _code(File(path).readAsStringSync());
      expect(code, isNot(contains('discard')), reason: path);
      expect(code, isNot(contains('ApplyLodFade')), reason: path);
    }
    const physical = 'assets/materials/physical_opaque.fmat';
    final compiled = compileFmat(
      File(physical).readAsStringSync(),
      fileName: physical,
    );
    expect(_code(compiled.glsl), isNot(contains('discard')));
  });

  test('the coverage pre-draw applies the cross-fade and the mask', () {
    final code = _code(
      File('shaders/flutter_scene_coverage.frag').readAsStringSync(),
    );
    expect(code, contains('ApplyLodFade(coverage_info.fade)'));
    expect(code, contains('ApplyDepthAlphaMask()'));
    final bundle =
        jsonDecode(File('shaders/base.shaderbundle.json').readAsStringSync())
            as Map<String, Object?>;
    expect(bundle['CoverageFragment'], {
      'type': 'fragment',
      'file': 'shaders/flutter_scene_coverage.frag',
    });
  });

  test('the built-in lit and unlit materials cross-fade', () {
    expect(PhysicallyBasedMaterial().lodCrossFades, isTrue);
    expect(UnlitMaterial().lodCrossFades, isTrue);
  });

  test('an alpha-masked material cuts out through its depth mask', () {
    final material = PhysicallyBasedMaterial();
    expect(material.depthAlphaMasked, isFalse);
    material.alphaMode = AlphaMode.mask;
    expect(material.depthAlphaMasked, isTrue);
  });

  test('a material that masks its depth passes but cuts its own color out '
      'draws its color without the coverage pre-draw', () {
    final masked = PhysicallyBasedMaterial()..alphaMode = AlphaMode.mask;
    expect(masked.colorAlphaMasked, isTrue);
    expect(drawsCoverage(masked, 1.0), isTrue);
    final cutting = _ColorCuttingMaterial();
    expect(cutting.depthAlphaMasked, isTrue);
    expect(cutting.colorAlphaMasked, isFalse);
    expect(drawsCoverage(cutting, 1.0), isFalse);
    expect(drawsCoverage(cutting, 0.5), isTrue);
  });

  test('an alpha-masked mesh whose far triangles come first in its index '
      'order draws its near triangles where they are kept, as the opaque '
      'mesh does', () async {
    final opaque = await _overlappingQuadsCentre(AlphaMode.opaque);
    final masked = await _overlappingQuadsCentre(AlphaMode.mask);
    expect(opaque[3], 255);
    for (var channel = 0; channel < 4; channel++) {
      expect(
        (masked[channel] - opaque[channel]).abs(),
        lessThanOrEqualTo(2),
        reason: 'masked $masked against opaque $opaque',
      );
    }
  }, skip: noGpu);

  group('the encoder takes the coverage pre-draw exactly where drawsCoverage '
      'says', () {
    final cases = <String, ({Material material, bool crossFading, bool takes})>{
      'an alpha-masked material': (
        material: PhysicallyBasedMaterial()..alphaMode = AlphaMode.mask,
        crossFading: false,
        takes: true,
      ),
      'a material that masks only its depth passes': (
        material: _ColorCuttingMaterial(),
        crossFading: false,
        takes: false,
      ),
      'an opaque material': (
        material: PhysicallyBasedMaterial(),
        crossFading: false,
        takes: false,
      ),
      'a cross-fading level of a material that cross-fades': (
        material: PhysicallyBasedMaterial(),
        crossFading: true,
        takes: true,
      ),
      'a cross-fading level of a material that does not cross-fade': (
        material: _SteadyMaterial(),
        crossFading: true,
        takes: false,
      ),
    };
    for (final MapEntry(key: name, value: example) in cases.entries) {
      test(name, () async {
        final fade = example.crossFading ? 0.5 : 1.0;
        expect(drawsCoverage(example.material, fade), example.takes);
        expect(
          await _encoderTakesCoverage(
            example.material,
            crossFading: example.crossFading,
          ),
          example.takes,
        );
      }, skip: noGpu);
    }
  });
}

class _SteadyMaterial extends UnlitMaterial {
  @override
  bool get lodCrossFades => false;
}

class _ColorCuttingMaterial extends UnlitMaterial {
  @override
  bool get depthAlphaMasked => true;

  @override
  bool get colorAlphaMasked => false;
}
