part of '_gpu.dart';

/// The active backend's integration with the Flutter host.
///
/// Flutter GPU is a handle on Impeller's own context rather than an external
/// renderer, so textures cross in both directions without a copy.
class GpuHost {
  const GpuHost._();

  /// See [GpuCapabilities].
  GpuCapabilities get capabilities => switch (_kind) {
    GpuBackendKind.impeller => _impellerCapabilities,
    GpuBackendKind.wgpu => gpuContext._backend!.capabilities,
  };

  static const _impellerCapabilities = GpuCapabilities(
    textureToImage: true,
    imageToTexture: true,
    // Native uses Texture.asImage directly; the present path is a web concept.
    presentAsImage: false,
    // Impeller has a compute HAL, but flutter_gpu exposes no Dart surface for
    // it yet. Tracked upstream as flutter/flutter#188474.
    compute: false,
  );

  /// Completes once every render pipeline asked for so far has compiled.
  ///
  /// Impeller compiles a pipeline where it is first drawn, so this completes
  /// at once; on a registered backend it is
  /// `GpuBackendContext.pipelinesReady`.
  Future<void> pipelinesReady() => switch (_kind) {
    GpuBackendKind.impeller => Future.value(),
    GpuBackendKind.wgpu => gpuContext._backend!.pipelinesReady(),
  };

  /// Runs [record], during which a draw whose pipeline is still compiling
  /// records nothing, and returns how many draws it skipped.
  ///
  /// Impeller compiles a pipeline where it is first drawn, so every draw
  /// records and this returns 0; on a registered backend it is
  /// `GpuBackendContext.skipCompilingDraws`.
  int skipCompilingDraws(void Function() record) {
    if (_kind == GpuBackendKind.impeller) {
      record();
      return 0;
    }
    return gpuContext._backend!.skipCompilingDraws(record);
  }

  /// Hands [texture] to Flutter as a `ui.Image`, without a copy.
  ui.Image textureToImage(Texture texture) => texture.asImage();

  /// Wraps a Flutter-rendered [image]'s backing texture, or returns null when
  /// it is not backed by one this backend can adopt.
  ///
  /// Null rather than throwing, because "this image cannot be wrapped" is a
  /// routine answer callers are expected to handle by reading back instead.
  /// Resolving the context is part of that, since asking for one where Impeller
  /// is disabled throws.
  Texture? imageToTexture(ui.Image image) {
    try {
      return Texture.fromImage(gpuContext, image);
    } on Exception {
      // Deferred images from toImageSync have not rasterized yet, software
      // rendering produces no GPU texture at all, and a context is unavailable
      // entirely when Impeller is off.
      return null;
    }
  }

  /// Not supported here; native callers use [textureToImage].
  Future<ui.Image> present(Texture texture, {bool transferOwnership = false}) {
    throw UnimplementedError(
      'present is only implemented on web. On native, use '
      'gpuHost.textureToImage().',
    );
  }
}

/// Readies the GPU backend. Flutter GPU needs nothing beyond the engine.
Future<void> initializeGpuBackend() async {}

/// The active backend's host integration.
const GpuHost gpuHost = GpuHost._();
