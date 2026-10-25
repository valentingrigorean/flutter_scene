// FFI bindings to flutter_scene_wgpu_native. The build hook bundles the
// library as a code asset under this package's asset id. Every call but
// fsw_abi_version and fsw_last_error_message returns a status code
// (WgpuErrorCode); results come back through out pointers.
@DefaultAsset('package:flutter_scene_wgpu/flutter_scene_wgpu_native')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The ABI version the native library reports.
@Native<Uint32 Function()>(symbol: 'fsw_abi_version')
external int fswAbiVersion();

@Native<Pointer<Utf8> Function()>(symbol: 'fsw_last_error_message')
external Pointer<Utf8> fswLastErrorMessage();

@Native<Int32 Function(Uint32, Pointer<Uint64>)>(symbol: 'fsw_device_create')
external int fswDeviceCreate(int backends, Pointer<Uint64> outDevice);

@Native<Int32 Function(Uint64, Pointer<Uint32>)>(symbol: 'fsw_device_backend')
external int fswDeviceBackend(int device, Pointer<Uint32> outBackend);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Size>)>(
  symbol: 'fsw_device_adapter_name',
)
external int fswDeviceAdapterName(
  int device,
  Pointer<Uint8> buf,
  int cap,
  Pointer<Size> outLen,
);

@Native<Int32 Function(Uint64, Pointer<Uint64>)>(symbol: 'fsw_device_features')
external int fswDeviceFeatures(int device, Pointer<Uint64> outFeatures);

@Native<Int32 Function(Uint64, Pointer<Uint64>, Uint32)>(
  symbol: 'fsw_device_limits',
)
external int fswDeviceLimits(int device, Pointer<Uint64> outLimits, int count);

@Native<Int32 Function(Uint64)>(symbol: 'fsw_device_wait_idle')
external int fswDeviceWaitIdle(int device);

@Native<Int32 Function(Uint64)>(symbol: 'fsw_destroy')
external int fswDestroy(int handle);

@Native<Int32 Function(Uint64, Uint64, Uint32, Pointer<Uint64>)>(
  symbol: 'fsw_buffer_create',
)
external int fswBufferCreate(
  int device,
  int size,
  int usage,
  Pointer<Uint64> outBuffer,
);

@Native<Int32 Function(Uint64, Uint64, Pointer<Uint8>, Size)>(
  symbol: 'fsw_buffer_write',
)
external int fswBufferWrite(
  int buffer,
  int offset,
  Pointer<Uint8> data,
  int len,
);

@Native<
  Int32 Function(
    Uint64,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Pointer<Uint64>,
  )
>(symbol: 'fsw_texture_create')
external int fswTextureCreate(
  int device,
  int textureType,
  int pixelFormat,
  int width,
  int height,
  int mipLevels,
  int sampleCount,
  int usage,
  Pointer<Uint64> outTexture,
);

@Native<
  Int32 Function(
    Uint64,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
    Uint32,
  )
>(symbol: 'fsw_texture_write')
external int fswTextureWrite(
  int texture,
  int mipLevel,
  int slice,
  int x,
  int y,
  int width,
  int height,
  Pointer<Uint8> data,
  int len,
  int bytesPerRow,
);

@Native<
  Int32 Function(
    Uint64,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'fsw_texture_read')
external int fswTextureRead(
  int texture,
  int mipLevel,
  int slice,
  int x,
  int y,
  int width,
  int height,
  Pointer<Uint8> dst,
  int dstLen,
);

@Native<
  Int32 Function(
    Uint64,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Float,
    Float,
    Uint32,
    Uint32,
    Pointer<Uint64>,
  )
>(symbol: 'fsw_sampler_create')
external int fswSamplerCreate(
  int device,
  int minFilter,
  int magFilter,
  int mipFilter,
  int addressU,
  int addressV,
  int addressW,
  double lodMin,
  double lodMax,
  int compare,
  int maxAnisotropy,
  Pointer<Uint64> outSampler,
);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint64>)>(
  symbol: 'fsw_shader_create_wgsl',
)
external int fswShaderCreateWgsl(
  int device,
  Pointer<Uint8> source,
  int len,
  Pointer<Uint64> outShader,
);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint64>)>(
  symbol: 'fsw_shader_create_spirv',
)
external int fswShaderCreateSpirv(
  int device,
  Pointer<Uint8> words,
  int len,
  Pointer<Uint64> outShader,
);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint64>)>(
  symbol: 'fsw_pipeline_create',
)
external int fswPipelineCreate(
  int device,
  Pointer<Uint8> desc,
  int len,
  Pointer<Uint64> outPipeline,
);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint64>)>(
  symbol: 'fsw_pipeline_create_async',
)
external int fswPipelineCreateAsync(
  int device,
  Pointer<Uint8> desc,
  int len,
  Pointer<Uint64> outPipeline,
);

@Native<Int32 Function(Uint64)>(symbol: 'fsw_pipeline_status')
external int fswPipelineStatus(int pipeline);

@Native<Int32 Function(Uint64)>(symbol: 'fsw_pipeline_wait')
external int fswPipelineWait(int pipeline);

@Native<Int32 Function(Uint64, Pointer<Uint8>, Size)>(symbol: 'fsw_submit')
external int fswSubmit(int device, Pointer<Uint8> stream, int len);
