// Covers Scene.initializeStaticResources started inside a testWidgets body:
// the first load in this isolate completes with pumps, though the body runs
// in fake async, and leaves no timer pending. The GPU gate reads the context
// rather than constructing a Scene, which would start the load outside the
// test body.
// GPU-gated; building the environment needs a device.

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

bool _gpuAvailable() {
  try {
    gpu.gpuContext;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'scene static resources fake async suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  testWidgets('a first load started in fake async completes with pumps', (
    tester,
  ) async {
    var done = false;
    Scene.initializeStaticResources().then((_) => done = true);
    var pumps = 0;
    while (!done && pumps < 20) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      pumps++;
    }
    expect(done, isTrue, reason: 'still loading after $pumps pumps');
    expect(Scene.isReadyToRender, isTrue);
    expect(Material.debugDefaultEnvironmentMap, isNotNull);
  });
}
