// Covers Scene.initializeStaticResources: the default studio environment is
// built while the engine loads, so the first frame does not pay for it, and a
// failing build ends the load and lets a later call retry. The failing build
// runs first, while no load has completed in this isolate.
// GPU-gated; building the environment needs a device.

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'scene static resources suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  testWidgets('a failing default environment build ends the load and retries', (
    tester,
  ) async {
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    final previousSize = EnvironmentMap.radianceCubeSize;
    FlutterError.onError = reported.add;
    EnvironmentMap.radianceCubeSize = 1 << 20;
    final String outcome;
    try {
      outcome = (await tester.runAsync(
        () => Scene.initializeStaticResources()
            .then((_) => 'completed', onError: (Object e) => 'error $e')
            .timeout(const Duration(seconds: 10), onTimeout: () => 'pending'),
      ))!;
    } finally {
      FlutterError.onError = previousOnError;
      EnvironmentMap.radianceCubeSize = previousSize;
    }
    expect(outcome, 'completed');
    expect(reported, isEmpty);
    expect(Scene.isReadyToRender, isFalse);
    expect(Material.debugDefaultEnvironmentMap, isNull);

    await tester.runAsync(Scene.initializeStaticResources);
    expect(Scene.isReadyToRender, isTrue);
    expect(Material.debugDefaultEnvironmentMap, isNotNull);
  });

  testWidgets('the default environment exists once the static resources load', (
    tester,
  ) async {
    await tester.runAsync(Scene.initializeStaticResources);
    expect(Scene.isReadyToRender, isTrue);
    final built = Material.debugDefaultEnvironmentMap;
    expect(built, isNotNull);
    expect(Material.getDefaultEnvironmentMap(), same(built));
  });
}
