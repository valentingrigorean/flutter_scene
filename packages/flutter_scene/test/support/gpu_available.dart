import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';

/// Whether this run can render scenes.
///
/// False on the web, where the WebGL2 shim exists but `flutter test` serves
/// no built shader bundles, so `Scene.initializeStaticResources` never
/// completes.
bool gpuAvailable() {
  if (kIsWeb) return false;
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

/// Whether this run has a GPU context, read without constructing a [Scene],
/// which would start the static resource load and its GPU submissions in the
/// background. False on the web, as [gpuAvailable] is.
bool gpuContextAvailable() {
  if (kIsWeb) return false;
  try {
    gpu.gpuContext;
    return true;
  } catch (_) {
    return false;
  }
}
