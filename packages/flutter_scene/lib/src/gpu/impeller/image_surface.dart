part of '_gpu.dart';

/// A source of frames to render into and present.
sealed class GpuSurface {
  /// The next frame to render into, or null when none is available.
  GpuSurfaceFrame? acquireNextFrame();
}

/// One frame of a [GpuSurface].
sealed class GpuSurfaceFrame {
  /// The texture to render the frame into.
  Texture get colorTexture;

  /// Presents the frame once [commandBuffer], which renders it, is submitted.
  GpuPresentStatus present(CommandBuffer commandBuffer);

  /// Drops the frame without presenting it.
  void discard();
}

/// A surface whose frames Flutter draws as `ui.Image`s; created by
/// [GpuContext.createImageSurface].
final class GpuImageSurface implements GpuSurface {
  GpuImageSurface._impeller(fg.GpuImageSurface this._impeller)
    : _backend = null;
  GpuImageSurface._backend(GpuBackendImageSurface this._backend)
    : _impeller = null;

  final fg.GpuImageSurface? _impeller;
  final GpuBackendImageSurface? _backend;

  int get width => _impeller?.width ?? _backend!.width;
  int get height => _impeller?.height ?? _backend!.height;
  PixelFormat get format => _impeller?.format ?? _backend!.format;

  /// How many textures back the surface.
  int get debugBackingTextureCount =>
      _impeller?.debugBackingTextureCount ?? _backend!.debugBackingTextureCount;

  /// The most recently presented frame, or null before the first.
  ui.Image? get currentImage {
    final impeller = _impeller;
    if (impeller != null) return impeller.currentImage;
    return _backend!.currentImage;
  }

  void resize(int width, int height) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.resize(width, height);
    } else {
      _backend!.resize(width, height);
    }
  }

  @override
  GpuImageSurfaceFrame acquireNextFrame() {
    final impeller = _impeller;
    if (impeller != null) {
      final frame = impeller.acquireNextFrame();
      return GpuImageSurfaceFrame._impeller(
        frame,
        Texture._impeller(frame.colorTexture),
      );
    }
    final backend = _backend!;
    final texture = backend.acquireNextFrame();
    return GpuImageSurfaceFrame._backend(
      backend,
      texture,
      Texture._backend(texture),
    );
  }
}

/// One frame of a [GpuImageSurface].
final class GpuImageSurfaceFrame implements GpuSurfaceFrame {
  GpuImageSurfaceFrame._impeller(
    fg.GpuImageSurfaceFrame this._impeller,
    this.colorTexture,
  ) : _backendSurface = null,
      _backendTexture = null;
  GpuImageSurfaceFrame._backend(
    GpuBackendImageSurface this._backendSurface,
    GpuBackendTexture this._backendTexture,
    this.colorTexture,
  ) : _impeller = null;

  final fg.GpuImageSurfaceFrame? _impeller;
  final GpuBackendImageSurface? _backendSurface;
  final GpuBackendTexture? _backendTexture;

  @override
  final Texture colorTexture;

  @override
  GpuPresentStatus present(CommandBuffer commandBuffer) {
    final impeller = _impeller;
    if (impeller != null) return impeller.present(commandBuffer._impeller!);
    return _backendSurface!.present(_backendTexture!, commandBuffer._backend!);
  }

  @override
  void discard() {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.discard();
    } else {
      _backendSurface!.discard(_backendTexture!);
    }
  }
}
