/// A build-time check of an impellerc `.shaderbundle` against what the WebGL2
/// backend loads: pure Dart, so a build hook runs it on the host.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../web/shader_bundle_generated.dart' as fb;
import 'glsl_transpile.dart';

final RegExp _version300 = RegExp(r'^#version\s+300\s+es\b', multiLine: true);

final RegExp _output = RegExp(
  r'^\s*(?:layout\s*\([^)]*\)\s*)?out\s+[^;]+;',
  multiLine: true,
);

/// What keeps the shaders of [bundle] from loading on the WebGL2 backend, one
/// line per defect, empty when every shader loads.
///
/// The backend compiles every shader of a bundle when it loads the library,
/// so one defect fails them all. It reads each entry's `opengl_es` variant,
/// runs it through [transpileGlslEs100To300] and compiles the result as GLSL
/// ES 3.00, and a render pass binds one colour attachment, so a fragment
/// shader writes one output.
List<String> webShaderBundleDefects(Uint8List bundle) {
  final defects = <String>[];
  for (final entry in fb.ShaderBundle(bundle).shaders ?? const <fb.Shader>[]) {
    final name = entry.name ?? '<unnamed>';
    final backend = entry.openglEs;
    final bytes = backend?.shader;
    if (backend == null || bytes == null || bytes.isEmpty) {
      defects.add('$name has no opengl_es variant');
      continue;
    }
    final isFragment = backend.stage == fb.ShaderStage.kFragment;
    final source = transpileGlslEs100To300(
      utf8.decode(bytes),
      isFragment: isFragment,
    );
    if (!_version300.hasMatch(source)) {
      defects.add('$name does not transpile to GLSL ES 3.00');
      continue;
    }
    if (!isFragment) continue;
    final outputs = _output.allMatches(source).length;
    if (outputs != 1) {
      defects.add(
        '$name writes $outputs colour outputs; a pass binds one attachment',
      );
    }
  }
  return defects;
}
