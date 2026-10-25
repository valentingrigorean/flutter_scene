import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../device.dart';
import 'bindings.dart';

const _channel = MethodChannel('flutter_scene_wgpu/present');
const _bufferCount = 3;

/// What [WgpuPresenter.render] did with a frame.
enum PresentResult {
  /// The frame was submitted; the texture shows it once the GPU is done.
  rendered,

  /// No buffer or surface image was free; the frame was dropped.
  skipped,

  /// The platform has not handed over a surface (Android, while the
  /// SurfaceProducer is torn down).
  noSurface,
}

/// Renders wgpu frames into a Flutter external texture.
///
/// Show it with `Texture(textureId: presenter.textureId)` and call [render]
/// or [presentWgpuTexture] once per Flutter frame. flutter_scene's GPU shim
/// adds `presentTexture`, which takes the shim's own texture. On macOS and iOS the frames land in
/// IOSurface-backed pixel buffers with no copy; on Android they go to a
/// wgpu surface on the texture's SurfaceProducer.
class WgpuPresenter {
  WgpuPresenter._(this.textureId, this._handle, this.width, this.height);

  /// The id to pass to Flutter's `Texture` widget.
  final int textureId;

  /// The render target size in physical pixels.
  int width;

  /// The render target size in physical pixels.
  int height;

  int _handle;
  bool _busy = false;
  final Pointer<FswPresentFrame> _frame = calloc<FswPresentFrame>();

  /// The wgpu backend in use, once a presenter exists.
  static String? get backend {
    final p = fswPresentBackend();
    return p == nullptr ? null : p.cast<Utf8>().toDartString();
  }

  /// Creates a presenter for a `width` x `height` pixel target.
  ///
  /// [preferGl] opens the device on GLES instead of Vulkan on Android; it
  /// only takes effect for the first presenter in the process.
  static Future<WgpuPresenter> create({
    required int width,
    required int height,
    bool preferGl = false,
  }) async {
    final info = (await _channel.invokeMapMethod<String, Object?>('create', {
      'width': width,
      'height': height,
      'count': _bufferCount,
    }))!;
    final textureId = info['textureId']! as int;
    final int handle;
    if (Platform.isAndroid) {
      handle = fswPresentCreateAndroid(textureId, width, height, preferGl ? 1 : 0);
    } else {
      handle = _withSurfaces(
        info,
        (surfaces, count, generation, callback, context) => fswPresentCreateApple(
          surfaces, count, width, height, generation, callback, context),
      );
    }
    if (handle == 0) {
      await _channel.invokeMethod('dispose', {'textureId': textureId});
      throw StateError('Presenter creation failed: ${_lastError()}');
    }
    return WgpuPresenter._(textureId, handle, width, height);
  }

  /// Creates a presenter over IOSurfaces of its own with no Flutter texture
  /// ([textureId] is -1), whose buffers [readLatestFrame] reads back.
  /// macOS and iOS only.
  @visibleForTesting
  static WgpuPresenter createOffscreen({
    required int width,
    required int height,
  }) {
    final handle = fswPresentCreateOffscreen(width, height, _bufferCount);
    if (handle == 0) {
      throw StateError('Presenter creation failed: ${_lastError()}');
    }
    return WgpuPresenter._(-1, handle, width, height);
  }

  /// Waits for the GPU and returns the most recently finished buffer of an
  /// offscreen presenter as tightly packed BGRA bytes.
  @visibleForTesting
  Uint8List readLatestFrame() {
    final length = width * height * 4;
    final out = calloc<Uint8>(length);
    try {
      if (fswPresentReadLatest(_handle, out, length) < 0) {
        throw StateError('Readback failed: ${_lastError()}');
      }
      return Uint8List.fromList(out.asTypedList(length));
    } finally {
      calloc.free(out);
    }
  }

  /// Resizes the target; frames requested meanwhile are skipped.
  Future<void> resize(int width, int height) async {
    if (width == this.width && height == this.height) return;
    _busy = true;
    try {
      final info = (await _channel.invokeMapMethod<String, Object?>('resize', {
        'textureId': textureId,
        'width': width,
        'height': height,
        'count': _bufferCount,
      }))!;
      final status = Platform.isAndroid
          ? fswPresentResize(_handle, width, height)
          : _withSurfaces(
              info,
              (surfaces, count, generation, callback, context) =>
                  fswPresentResizeApple(_handle, surfaces, count, width,
                      height, generation, callback, context),
            );
      if (status != 0) throw StateError('Resize failed: ${_lastError()}');
      this.width = width;
      this.height = height;
    } finally {
      _busy = false;
    }
  }

  /// Renders one frame synchronously: the cube under [model] seen through
  /// [viewProj] (column-major, wgpu clip space with z in 0..1), with
  /// [frameIndex] encoded as a strip of [markerBlock]-pixel blocks whose top
  /// left is at ([markerX], [markerY]) pixels.
  PresentResult render({
    required Float32List viewProj,
    required Float32List model,
    required int frameIndex,
    int markerX = 0,
    int markerY = 0,
    int markerBlock = 8,
  }) {
    if (_busy || _handle == 0) return PresentResult.skipped;
    final f = _frame.ref;
    for (var i = 0; i < 16; i++) {
      f.viewProj[i] = viewProj[i];
      f.model[i] = model[i];
    }
    f
      ..frameIndex = frameIndex
      ..markerX = markerX
      ..markerY = markerY
      ..markerBlock = markerBlock;
    return _result(fswPresentRender(_handle, _frame));
  }

  /// Draws [texture] over the next free buffer, scaled to [width] by
  /// [height], and submits it synchronously.
  ///
  /// [texture] is a single-sampled 2D colour texture of the shared wgpu
  /// device: 8-bit UNorm (shown as stored), sRGB or 16-bit float (linear,
  /// sRGB-encoded for display). A frame the texture's pending GPU work
  /// writes is presented after that work, since both run on one queue.
  PresentResult presentWgpuTexture(WgpuTexture texture) {
    if (_busy || _handle == 0) return PresentResult.skipped;
    return _result(fswPresentTexture(_handle, texture.handle));
  }

  /// Releases the presenter and its texture.
  Future<void> dispose() async {
    if (_handle == 0) return;
    fswPresentDispose(_handle);
    _handle = 0;
    calloc.free(_frame);
    if (textureId < 0) return;
    await _channel.invokeMethod('dispose', {'textureId': textureId});
  }

  static PresentResult _result(int status) => switch (status) {
    0 => PresentResult.rendered,
    1 => PresentResult.skipped,
    2 => PresentResult.noSurface,
    _ => throw StateError('Present failed: ${_lastError()}'),
  };

  static int _withSurfaces(
    Map<String, Object?> info,
    int Function(Pointer<Pointer<Void>> surfaces, int count, int generation,
            Pointer<Void> callback, Pointer<Void> context)
        call,
  ) {
    final addresses = (info['surfaces']! as List).cast<int>();
    final surfaces = calloc<Pointer<Void>>(addresses.length);
    try {
      for (var i = 0; i < addresses.length; i++) {
        surfaces[i] = Pointer.fromAddress(addresses[i]);
      }
      return call(
        surfaces,
        addresses.length,
        info['generation']! as int,
        Pointer.fromAddress(info['callback']! as int),
        Pointer.fromAddress(info['context']! as int),
      );
    } finally {
      calloc.free(surfaces);
    }
  }

  static String _lastError() {
    final p = fswPresentLastError();
    return p == nullptr ? 'unknown error' : p.cast<Utf8>().toDartString();
  }
}
