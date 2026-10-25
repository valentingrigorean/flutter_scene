import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

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
/// once per Flutter frame. On macOS and iOS the frames land in
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
    final status = fswPresentRender(_handle, _frame);
    return switch (status) {
      0 => PresentResult.rendered,
      1 => PresentResult.skipped,
      2 => PresentResult.noSurface,
      _ => throw StateError('Render failed: ${_lastError()}'),
    };
  }

  /// Releases the presenter and its texture.
  Future<void> dispose() async {
    if (_handle == 0) return;
    fswPresentDispose(_handle);
    _handle = 0;
    calloc.free(_frame);
    await _channel.invokeMethod('dispose', {'textureId': textureId});
  }

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
