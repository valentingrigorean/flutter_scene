// FFI bindings to the presenter half of flutter_scene_wgpu_native
// (native/src/present).
@DefaultAsset('package:flutter_scene_wgpu/flutter_scene_wgpu_native')
library;

import 'dart:ffi';

/// One frame's inputs, mirrored by `FswPresentFrame` in Rust.
final class FswPresentFrame extends Struct {
  @Array(16)
  external Array<Float> viewProj;
  @Array(16)
  external Array<Float> model;
  @Uint32()
  external int frameIndex;
  @Uint32()
  external int markerX;
  @Uint32()
  external int markerY;
  @Uint32()
  external int markerBlock;
}

@Native<Pointer<Char> Function()>(symbol: 'fsw_present_last_error')
external Pointer<Char> fswPresentLastError();

@Native<Pointer<Char> Function()>(symbol: 'fsw_present_backend')
external Pointer<Char> fswPresentBackend();

@Native<
  Uint64 Function(Pointer<Pointer<Void>>, Uint32, Uint32, Uint32, Uint32,
      Pointer<Void>, Pointer<Void>)
>(symbol: 'fsw_present_create_apple')
external int fswPresentCreateApple(
  Pointer<Pointer<Void>> surfaces,
  int count,
  int width,
  int height,
  int generation,
  Pointer<Void> onReady,
  Pointer<Void> context,
);

@Native<
  Int32 Function(Uint64, Pointer<Pointer<Void>>, Uint32, Uint32, Uint32,
      Uint32, Pointer<Void>, Pointer<Void>)
>(symbol: 'fsw_present_resize_apple')
external int fswPresentResizeApple(
  int handle,
  Pointer<Pointer<Void>> surfaces,
  int count,
  int width,
  int height,
  int generation,
  Pointer<Void> onReady,
  Pointer<Void> context,
);

@Native<Uint64 Function(Int64, Uint32, Uint32, Uint32)>(
  symbol: 'fsw_present_create_android',
)
external int fswPresentCreateAndroid(
  int textureId,
  int width,
  int height,
  int preferGl,
);

@Native<Int32 Function(Uint64, Uint32, Uint32)>(symbol: 'fsw_present_resize')
external int fswPresentResize(int handle, int width, int height);

@Native<Int32 Function(Uint64, Pointer<FswPresentFrame>)>(
  symbol: 'fsw_present_render',
)
external int fswPresentRender(int handle, Pointer<FswPresentFrame> frame);

@Native<Void Function(Uint64)>(symbol: 'fsw_present_dispose')
external void fswPresentDispose(int handle);
