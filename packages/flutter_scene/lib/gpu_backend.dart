/// The seam a native GPU backend other than Impeller plugs into the GPU shim
/// through: the device-level contract it implements and the call an app makes
/// at start-up, before the first GPU object, to register it.
///
/// ```dart
/// registerGpuBackend(MyBackend());
/// selectGpuBackend(GpuBackendKind.wgpu);
/// ```
///
/// Native only. A shader bundle's entries, which a backend compiles its
/// shaders from, are read with `package:flutter_scene/shader_bundle_format.dart`.
@experimental
library;

import 'package:meta/meta.dart' show experimental;

export 'src/gpu/backend/gpu_backend.dart';
export 'src/gpu/impeller/_gpu.dart'
    show
        gpuBackendTextureOf,
        registerGpuBackend,
        registeredGpuBackend,
        selectGpuBackend,
        gpuBackend,
        gpuBackendDefine;
export 'src/gpu/shared/gpu_capabilities.dart'
    show GpuBackendKind, GpuCapabilities;
