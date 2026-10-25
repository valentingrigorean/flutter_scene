// FFI bindings to flutter_scene_wgpu_native. The build hook bundles the
// library as a code asset under this package's asset id.
@DefaultAsset('package:flutter_scene_wgpu/flutter_scene_wgpu_native')
library;

import 'dart:ffi';

/// The ABI version the native library reports.
@Native<Uint32 Function()>(symbol: 'fsw_abi_version')
external int fswAbiVersion();
