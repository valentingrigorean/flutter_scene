/// Web/wasm stub for the WGSL sidecar step. The real implementation uses
/// `dart:io` and `package:hooks` and only runs on the native build host.
library;

import 'dart:typed_data';

/// One shader to translate.
typedef WgslTranslationJob = ({
  String name,
  Uint8List spirv,
  Map<int, int> samplerBindings,
});

/// Translates SPIR-V to WGSL in a batch, one call per bundle.
abstract interface class WgslBatchTranslator {
  /// The translator build, recorded in the sidecar.
  String get revision;

  /// Returns WGSL keyed by job name.
  Future<Map<String, String>> translateAll(List<WgslTranslationJob> jobs);
}

/// A shader that could not be translated or whose bindings disagree with the
/// prediction.
final class WgslSidecarException implements Exception {
  WgslSidecarException(this.message);
  final String message;

  @override
  String toString() => 'WgslSidecarException: $message';
}

/// Throws on web/wasm; the native one runs the `flutter_scene_tint` binary.
final class TintProcessTranslator {
  TintProcessTranslator._();

  static Never resolve(Object buildInput) => throw UnsupportedError(
    'TintProcessTranslator runs at build time on native hosts only.',
  );
}

Never buildWgslSidecar(
  Uint8List untrimmedBundle,
  WgslBatchTranslator translator, {
  required String shippedBundleHash,
}) => throw UnsupportedError(
  'buildWgslSidecar runs at build time on native hosts only.',
);

/// The sidecar's path next to the bundle it describes.
String wgslSidecarPathFor(String bundlePath) => '$bundlePath.wgsl.json';
