/// Which browser GPU backend the web shim runs, kept free of browser APIs so
/// a VM test can pin it.
library;

/// A browser GPU backend of the web shim.
enum WebBackendKind {
  /// WebGPU, the default where the browser hands out a device.
  webGpu,

  /// WebGL2, where the browser has no WebGPU or the build forces it.
  webGl2,
}

/// The `FLUTTER_SCENE_GPU_BACKEND` value that forces WebGL2 on web.
const String webGl2BackendDefine = 'webgl2';

/// The backend the web shim runs: WebGL2 where [define], the
/// `FLUTTER_SCENE_GPU_BACKEND` value, forces it or where the browser handed
/// out no WebGPU device, else WebGPU.
WebBackendKind chooseWebBackend({
  required String define,
  required bool webGpuDevice,
}) => define != webGl2BackendDefine && webGpuDevice
    ? WebBackendKind.webGpu
    : WebBackendKind.webGl2;
