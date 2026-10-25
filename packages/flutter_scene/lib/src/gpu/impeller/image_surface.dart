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
  GpuImageSurface._impeller(fg.GpuImageSurface this._impeller) : _wgpu = null;
  GpuImageSurface._wgpu(WgpuImageSurface this._wgpu) : _impeller = null;

  final fg.GpuImageSurface? _impeller;
  final WgpuImageSurface? _wgpu;

  int get width => _impeller?.width ?? _wgpu!.width;
  int get height => _impeller?.height ?? _wgpu!.height;
  PixelFormat get format => _impeller?.format ?? _wgpu!.format;

  /// How many textures back the surface.
  int get debugBackingTextureCount =>
      _impeller?.debugBackingTextureCount ?? _wgpu!.debugBackingTextureCount;

  /// The most recently presented frame, or null before the first.
  ui.Image? get currentImage {
    final impeller = _impeller;
    if (impeller != null) return impeller.currentImage;
    return _wgpu!.currentImage;
  }

  void resize(int width, int height) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.resize(width, height);
    } else {
      _wgpu!.resize(width, height);
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
    final wgpu = _wgpu!;
    final texture = wgpu.acquireNextFrame();
    return GpuImageSurfaceFrame._wgpu(wgpu, texture, Texture._wgpu(texture));
  }
}

/// One frame of a [GpuImageSurface].
final class GpuImageSurfaceFrame implements GpuSurfaceFrame {
  GpuImageSurfaceFrame._impeller(
    fg.GpuImageSurfaceFrame this._impeller,
    this.colorTexture,
  ) : _wgpuSurface = null,
      _wgpuTexture = null;
  GpuImageSurfaceFrame._wgpu(
    WgpuImageSurface this._wgpuSurface,
    WgpuTexture this._wgpuTexture,
    this.colorTexture,
  ) : _impeller = null;

  final fg.GpuImageSurfaceFrame? _impeller;
  final WgpuImageSurface? _wgpuSurface;
  final WgpuTexture? _wgpuTexture;

  @override
  final Texture colorTexture;

  @override
  GpuPresentStatus present(CommandBuffer commandBuffer) {
    final impeller = _impeller;
    if (impeller != null) return impeller.present(commandBuffer._impeller!);
    return _wgpuSurface!.present(_wgpuTexture!, commandBuffer._wgpu!);
  }

  @override
  void discard() {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.discard();
    } else {
      _wgpuSurface!.discard(_wgpuTexture!);
    }
  }
}
