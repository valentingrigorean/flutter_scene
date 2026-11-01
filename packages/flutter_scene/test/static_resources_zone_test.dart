// Covers the zone of the static resource load every scene of a process
// awaits: a load first asked for in a zone that runs no more microtasks, as a
// finished widget test's, still completes for a later caller.
// GPU-gated; the load builds textures on the device.

import 'dart:async';

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
      'static resources zone suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  test('the static resources first asked for in a zone that runs no more '
      'complete for a later caller', () async {
    runZoned(
      () => Scene.initializeStaticResources().ignore(),
      zoneSpecification: ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, task) {},
      ),
    );
    final outcome = await Scene.initializeStaticResources()
        .then((_) => 'completed', onError: (Object e) => 'error $e')
        .timeout(const Duration(seconds: 10), onTimeout: () => 'pending');
    expect(outcome, 'completed');
  });
}
