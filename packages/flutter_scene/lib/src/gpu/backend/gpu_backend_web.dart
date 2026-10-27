/// The web half of the GPU backend seam: the presenter contract's types, so
/// code that names a backend compiles on web. The web shim picks its own
/// backend, so no backend can be registered here.
library;

import 'package:meta/meta.dart' show experimental;

import '../shared/gpu_capabilities.dart';
import '../web/_gpu.dart' show Texture;

/// A GPU backend the native shim can render through instead of Impeller; on
/// web it cannot be used.
@experimental
abstract interface class GpuBackend {
  /// The kind the native shim names this backend by.
  GpuBackendKind get kind;

  /// Opens the backend's device; never called on web.
  GpuBackendContext openContext();

  /// Whether [openPresenter] shows frames on this platform.
  bool get presents;

  /// Opens a presenter for frames of [width] by [height] physical pixels.
  Future<GpuBackendPresenter> openPresenter({
    required int width,
    required int height,
  });
}

/// The device of a registered backend; none exists on web.
@experimental
abstract interface class GpuBackendContext {}

/// A texture of a registered backend; none exists on web.
@experimental
abstract interface class GpuBackendTexture {}

/// Shows frames rendered on a [GpuBackend] in a Flutter external texture.
@experimental
abstract interface class GpuBackendPresenter {
  /// The id to pass to Flutter's `Texture` widget.
  int get textureId;

  /// The frame width in physical pixels.
  int get width;

  /// The frame height in physical pixels.
  int get height;

  /// The native graphics API the frames reach the screen through, or null.
  String? get deviceApi;

  /// Resizes later frames to [width] by [height] physical pixels.
  Future<void> resize(int width, int height);

  /// Lends the buffer the next frame shows in, or says why none is lent.
  GpuBackendAcquired acquireFrame();

  /// Draws [frame] into the Flutter texture.
  void present(GpuBackendTexture frame);

  /// Releases the Flutter texture and its buffers.
  Future<void> dispose();
}

/// A [GpuBackendLent] buffer or the [GpuBackendUnlent] reason none is lent.
@experimental
sealed class GpuBackendAcquired {}

/// A buffer lent for one frame.
@experimental
final class GpuBackendLent implements GpuBackendAcquired {
  /// Wraps the lent [frame].
  const GpuBackendLent(this.frame);

  /// The lent buffer.
  final GpuBackendPresenterFrame frame;
}

/// Why no buffer was lent.
@experimental
enum GpuBackendUnlent implements GpuBackendAcquired {
  /// The frame renders into a texture of its own that is copied.
  format,

  /// No buffer is free; the texture keeps the frame it shows.
  busy,
}

/// One buffer of a [GpuBackendPresenter], lent for one frame.
@experimental
abstract interface class GpuBackendPresenterFrame {
  /// The buffer to render the frame into.
  GpuBackendTexture get texture;

  /// Shows the buffer.
  void present();

  /// Returns the buffer unshown.
  void discard();
}

/// Throws an [UnsupportedError]: the web shim picks its own backend.
@experimental
void registerGpuBackend(GpuBackend backend) => throw UnsupportedError(
  'A GPU backend registers on native only; the web shim picks its own.',
);

/// Throws an [UnsupportedError]: the web shim picks its own backend.
@experimental
void useGpuBackend(GpuBackend backend) => registerGpuBackend(backend);

/// Always null on web, where the web shim renders through its own backend.
@experimental
GpuBackend? get activeGpuBackend => null;

/// Always null on web, where every texture is the web shim's own.
@experimental
GpuBackendTexture? gpuBackendTextureOf(Texture texture) => null;

/// Throws an [UnsupportedError]: no backend texture exists on web.
@experimental
Texture gpuTextureOfBackend(GpuBackendTexture texture) =>
    throw UnsupportedError('A GPU backend texture exists on native only.');
