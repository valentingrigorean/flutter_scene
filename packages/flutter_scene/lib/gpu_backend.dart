/// The seam a native GPU backend other than Impeller plugs into the GPU shim
/// through: the device-level contract it implements and the call an app makes
/// at start-up, before the first GPU object, to register it.
///
/// ```dart
/// useGpuBackend(MyBackend());
/// ```
///
/// On web the library holds the presenter half alone, and [useGpuBackend]
/// throws an [UnsupportedError]: the web shim picks its own backend. A shader
/// bundle's entries, which a backend compiles its shaders from, are read with
/// `package:flutter_scene/shader_bundle_format.dart`.
@experimental
library;

import 'package:meta/meta.dart' show experimental;

export 'src/gpu/backend/gpu_backend.dart'
    if (dart.library.js_interop) 'src/gpu/backend/gpu_backend_web.dart';
export 'src/gpu/impeller/_gpu.dart'
    if (dart.library.js_interop) 'src/gpu/backend/gpu_backend_web.dart'
    show
        gpuBackendTextureOf,
        gpuTextureOfBackend,
        registerGpuBackend,
        activeGpuBackend,
        useGpuBackend;
export 'src/gpu/shared/gpu_capabilities.dart'
    show GpuBackendKind, GpuCapabilities;
