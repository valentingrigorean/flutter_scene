import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

/// Two triangles of NDC positions covering the screen (6 vec2s), on the
/// device the context is open on.
gpu.BufferView get fullscreenQuadView => _fullscreenQuad.value;

final gpu.DeviceLocal<gpu.BufferView> _fullscreenQuad = gpu.DeviceLocal(
  () => gpu.BufferView(
    gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList(<double>[
          -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, //
          -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, //
        ]),
      ),
    ),
    offsetInBytes: 0,
    lengthInBytes: 6 * 2 * 4,
  ),
);
