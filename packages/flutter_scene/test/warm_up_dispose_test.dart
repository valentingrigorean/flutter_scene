// A sliced warm-up that its scene's dispose interrupts. Its own file, so its
// pipelines are new to the process and the warm-up pauses between slices.

import 'dart:async';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

Node _instanced(Material material) => Node()
  ..addComponent(
    InstancedMeshComponent(
      InstancedMesh(
        geometry: CuboidGeometry(Vector3.all(1)),
        material: material,
      )..addInstance(Matrix4.identity()),
    ),
  );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!gpuAvailable()) {
    test(
      'warm-up dispose (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  test('a warm-up disposed between slices leaves no timer pending', () async {
    await Scene.initializeStaticResources();
    final scene = Scene()
      ..add(_instanced(PhysicallyBasedMaterial()))
      ..add(_instanced(UnlitMaterial()));
    final view = RenderView(
      camera: PerspectiveCamera(
        position: Vector3(0, 0, 10),
        target: Vector3.zero(),
      ),
    );
    final timers = <Timer>[];
    final paused = Completer<void>();
    final warmUp = runZoned(
      () => scene.warmUp([view], sliceBudget: const Duration(hours: 1)),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          timers.add(timer);
          if (!paused.isCompleted) paused.complete();
          return timer;
        },
      ),
    );
    await Future.any([paused.future, warmUp]);
    expect(paused.isCompleted, isTrue, reason: 'the warm-up never paused');

    scene.dispose();

    expect([
      for (final timer in timers)
        if (timer.isActive) timer,
    ], isEmpty);
    await expectLater(warmUp, completes);
  });
}
