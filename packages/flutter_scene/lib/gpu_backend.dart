/// The seam a GPU backend other than Impeller plugs into the GPU shim
/// through: the device-level contract it implements and the call an app makes
/// at start-up, before the first GPU object, to register it.
///
/// ```dart
/// useGpuBackend(MyBackend());
/// ```
///
/// On the web, where Impeller does not run, the registered backend is the
/// only one the shim draws through. A shader bundle's entries, which a
/// backend compiles its shaders from, are read with
/// `package:flutter_scene/shader_bundle_format.dart`.
@experimental
library;

import 'package:meta/meta.dart' show experimental;

export 'src/gpu/backend/gpu_backend.dart';
export 'src/gpu/impeller/_gpu.dart'
    show
        gpuBackendDeviceBufferOf,
        gpuBackendHostBufferOf,
        gpuBackendTextureOf,
        gpuDeviceBufferOfBackend,
        gpuTextureOfBackend,
        registerGpuBackend,
        reopenGpuContext,
        activeGpuBackend,
        useGpuBackend;
export 'src/gpu/shared/gpu_capabilities.dart'
    show GpuBackendKind, GpuCapabilities;
export 'src/gpu/shared/item_instances.dart';
export 'src/gpu/shared/item_parts.dart';
export 'src/gpu/shared/item_sort.dart';
