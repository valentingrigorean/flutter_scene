part of '../impeller/_gpu.dart';

/// Presents the GPU shim's textures through a [WgpuPresenter], for an app
/// that runs flutter_scene on the wgpu backend and shows its frames in the
/// presenter's Flutter `Texture`.
@experimental
extension WgpuPresenterTextures on WgpuPresenter {
  /// Draws [texture] over the presenter's next free buffer, scaled to the
  /// presenter size, and submits it synchronously; see
  /// [WgpuPresenter.presentWgpuTexture] for the formats it takes.
  ///
  /// [texture] must come from the wgpu backend (`selectGpuBackend` with
  /// [GpuBackendKind.wgpu]); an Impeller texture throws an [ArgumentError].
  PresentResult presentTexture(Texture texture) {
    final wgpu = texture._wgpu;
    if (wgpu == null) {
      throw ArgumentError.value(
        texture,
        'texture',
        'is an Impeller texture; a WgpuPresenter presents only textures of '
            'the wgpu GPU backend (selectGpuBackend(GpuBackendKind.wgpu))',
      );
    }
    return presentWgpuTexture(wgpu.native);
  }
}
