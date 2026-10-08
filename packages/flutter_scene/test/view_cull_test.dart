// A view culls its scene once: the depth prepass, the translucent depth patch
// and the color pass draw from that cull, with the instance cells it kept, and
// pack no instance record.

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a camera-only frame with the depth prepass and the patch culls the '
      'view once and its instance cells once', () async {
    if (!gpuAvailable()) {
      markTestSkipped('No Impeller GPU context');
      return;
    }
    await Scene.initializeStaticResources();
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..depthOfField.enabled = true;
    final instances = InstancedMesh(
      geometry: CuboidGeometry(Vector3.all(1)),
      material: UnlitMaterial(),
      cullInstances: true,
    );
    // A row of cells, the first of which the camera sees.
    for (var i = 0; i < 400; i++) {
      instances.addInstance(Matrix4.translation(Vector3(i * 2.0, 0, 0)));
    }
    scene.add(Node()..addComponent(InstancedMeshComponent(instances)));
    scene.add(
      Node(
        mesh: Mesh(
          CuboidGeometry(Vector3.all(1)),
          PhysicallyBasedMaterial()..transmission = 0.5,
        ),
      )..localTransform = Matrix4.translation(Vector3(0, 0, 2)),
    );

    Camera cameraAt(double x) =>
        PerspectiveCamera(position: Vector3(x, 0, 8), target: Vector3(x, 0, 0));

    RenderFrameStats frame(double x) {
      final recorder = ui.PictureRecorder();
      scene.render(
        cameraAt(x),
        ui.Canvas(recorder),
        viewport: const ui.Rect.fromLTWH(0, 0, 64, 64),
        pixelRatio: 1.0,
      );
      recorder.endRecording();
      return scene.renderStats.latest!;
    }

    await scene.warmUp([RenderView(camera: cameraAt(0))]);
    frame(0);
    final moved = frame(1);
    final view = moved.views.single;
    final passes = {for (final pass in view.passes) pass.name: pass};
    expect(
      passes.keys,
      containsAll(['DepthPrepass', 'TranslucentDepthPatchPass', 'ScenePass']),
    );
    expect(moved.counters.sceneCulls, 1);
    expect(moved.counters.instanceCellCulls, 1);
    for (final name in [
      'DepthPrepass',
      'TranslucentDepthPatchPass',
      'ScenePass',
    ]) {
      expect(passes[name]!.counters.sceneCulls, 0, reason: name);
      expect(passes[name]!.counters.instanceCellCulls, 0, reason: name);
    }
    expect(moved.counters.instanceBytesPacked, 0);
    expect(moved.counters.instanceBytesUploaded, 0);
    // The prepass and the color pass each drew the cells in view only, and
    // the patch drew the translucent cube.
    for (final name in ['DepthPrepass', 'ScenePass']) {
      expect(passes[name]!.counters.instances, inExclusiveRange(0, 400));
    }
    expect(passes['TranslucentDepthPatchPass']!.counters.draws, 1);
  });
}
