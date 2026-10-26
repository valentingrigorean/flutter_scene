import 'dart:typed_data';

import '../generated_assets/generated_assets.dart' show ShaderBundleBackend;

enum TargetShaderBundleAssetMode {
  generatedTree,
  dataAssetsRequired,

  @Deprecated(
    'Removed in 0.21.0. Use generatedTree, then run `dart run flutter_scene:init`.',
  )
  legacyOnly,
  @Deprecated(
    'Removed in 0.21.0. Use generatedTree, then run `dart run flutter_scene:init`.',
  )
  dataAssetsIfAvailable,
}

Never buildTargetShaderBundleJson({
  required Object buildInput,
  required Object buildOutput,
  required String manifestFileName,
  List<Uri> includeDirectories = const [],
  TargetShaderBundleAssetMode assetMode =
      TargetShaderBundleAssetMode.generatedTree,
  String? dataAssetName,
  int? glesLanguageVersion,
  bool copyToGeneratedTree = true,
  bool pruneGeneratedTree = true,
  String? owner,
  String? stamp,
  String? fileVariant,
}) => throw UnsupportedError(
  'buildTargetShaderBundleJson runs at build time on native hosts only.',
);

Never shaderBundleBackendsForBuild(Object buildInput) => throw UnsupportedError(
  'shaderBundleBackendsForBuild runs at build time on native hosts only.',
);

Never trimShaderBundle(
  Uint8List bytes,
  Set<ShaderBundleBackend> backends, {
  bool Function(String name)? keep,
}) => throw UnsupportedError(
  'trimShaderBundle runs at build time on native hosts only.',
);

Never wgslSidecarsForBuild(Object buildInput) => throw UnsupportedError(
  'wgslSidecarsForBuild runs at build time on native hosts only.',
);
