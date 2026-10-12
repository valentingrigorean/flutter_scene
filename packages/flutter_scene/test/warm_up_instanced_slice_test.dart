// A budgeted warm-up frame builds at most one new pipeline whose vertex
// layout reads a per-instance slot, whatever its time budget, and leaves the
// next for a later frame; pipelines without one build as the time allows.
// Needs a GPU device: flutter test --enable-impeller --enable-flutter-gpu.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/scene_encoder.dart'
    show deferredPipelineBuilds, withPipelineBuildBudget;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

const _size = ui.Size(100, 100);
const _ample = Duration(hours: 1);

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

List<RenderView> _views() => [
  RenderView(
    camera: PerspectiveCamera(
      position: Vector3(0, 0, 10),
      target: Vector3.zero(),
      fovRadiansY: math.pi / 4,
    ),
  ),
];

Node _instanced(String name, Material material) => Node(name: name)
  ..addComponent(
    InstancedMeshComponent(
      InstancedMesh(
        geometry: CuboidGeometry(Vector3.all(1)),
        material: material,
      )..addInstance(Matrix4.identity()),
    ),
  );

Node _box(String name, Material material) =>
    Node(name: name, mesh: Mesh(CuboidGeometry(Vector3.all(1)), material));

Future<Scene> _scene() async {
  await Scene.initializeStaticResources();
  final scene = Scene();
  addTearDown(scene.dispose);
  return scene;
}

int _budgetedFrame(Scene scene, List<RenderView> views) {
  withPipelineBuildBudget(_ample, () {
    final recorder = ui.PictureRecorder();
    scene.renderViews(
      views,
      ui.Canvas(recorder),
      region: ui.Offset.zero & _size,
    );
    recorder.endRecording().dispose();
  });
  return deferredPipelineBuilds;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'warm-up instanced slices (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.',
    );
    return;
  }

  test('a budgeted frame defers a second new instanced pipeline, and a '
      'sliced warm-up builds it', () async {
    final scene = await _scene();
    scene
      ..add(_instanced('lit', PhysicallyBasedMaterial()))
      ..add(_instanced('unlit', UnlitMaterial()));
    final views = _views();

    expect(_budgetedFrame(scene, views), greaterThan(0));
    await scene.warmUp(views, size: _size, sliceBudget: _ample);
    expect(scene.unbuiltPipelines(views, size: _size), isEmpty);
  });

  test('a budgeted frame with time left builds every new pipeline that reads '
      'no per-instance slot', () async {
    final scene = await _scene();
    scene
      ..add(_box('lit', PhysicallyBasedMaterial()))
      ..add(_box('unlit', UnlitMaterial()));
    final views = _views();

    expect(_budgetedFrame(scene, views), 0);
    expect(scene.unbuiltPipelines(views, size: _size), isEmpty);
  });
}
