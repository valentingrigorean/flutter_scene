// Covers the geometry hooks a subclass overrides to drive its own vertex
// stage: a geometry whose materialVertexVariant is null owns its vertex
// shader, so no material vertex variant runs on it in any pass.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/geometry/splat_geometry.dart';
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

class _RecordingMaterial extends UnlitMaterial {
  final List<String> requested = [];

  @override
  gpu.Shader? materialVertexShader(String variant) {
    requested.add(variant);
    return null;
  }
}

class _OwnVertexGeometry extends UnskinnedGeometry {
  @override
  String? get materialVertexVariant => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the base geometries name the material variant they take', () {
    expect(UnskinnedGeometry().materialVertexVariant, 'unskinned');
    expect(SkinnedGeometry().materialVertexVariant, 'skinned');
    expect(_OwnVertexGeometry().materialVertexVariant, isNull);
  });

  test('a splat batch owns its vertex shader', () {
    final geometry = SplatGeometry(
      GaussianSplats.fromData(SplatData.zeroed(4)),
    );
    final material = _RecordingMaterial();
    expect(geometry.materialVertexVariant, isNull);
    expect(material.vertexShaderForGeometry(geometry), isNull);
    expect(material.requested, isEmpty);
  });

  test('a geometry that owns its vertex shader asks no material', () {
    final material = _RecordingMaterial();
    final geometry = _OwnVertexGeometry();
    expect(material.vertexShaderForGeometry(geometry), isNull);
    expect(material.vertexShaderForGeometry(geometry, depth: true), isNull);
    expect(material.requested, isEmpty);
  });

  test('a geometry with a variant asks the material for it', () {
    final material = _RecordingMaterial();
    final geometry = UnskinnedGeometry();
    material.vertexShaderForGeometry(geometry);
    material.vertexShaderForGeometry(geometry, depth: true);
    expect(material.requested, ['unskinned', 'depth']);
  });

  if (!_gpuAvailable()) {
    test(
      'own-vertex draw (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  test('a billboard batch owns its vertex shader', () async {
    await Scene.initializeStaticResources();

    final geometry = BillboardGeometry();
    final material = _RecordingMaterial();
    expect(geometry.materialVertexVariant, isNull);
    expect(material.vertexShaderForGeometry(geometry), isNull);
    expect(material.requested, isEmpty);
  });

  test('line segments draw with no material vertex variant', () async {
    await Scene.initializeStaticResources();

    final segments = _RecordingMaterial();
    final control = _RecordingMaterial();
    final scene = Scene();
    scene.add(
      Node(
        mesh: Mesh(
          LineSegmentsGeometry(
            LineSegmentData(
              positions: Float32List.fromList([-1, 0, 0, 1, 0, 0]),
            ),
            width: 0.2,
          ),
          segments,
        ),
      ),
    );
    scene.add(Node(mesh: Mesh(CuboidGeometry(Vector3.all(0.5)), control)));

    final recorder = ui.PictureRecorder();
    scene.render(
      PerspectiveCamera(position: Vector3(0, 0, 5)),
      ui.Canvas(recorder),
      viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
      pixelRatio: 1.0,
    );
    recorder.endRecording();

    expect(control.requested, contains('unskinned'));
    expect(segments.requested, isEmpty);
  });
}
