@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gpu_shaders/environment.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resource index impellerc reports for a sampler the SPIR-V optimizer pruned.
///
/// A shader that declares a sampler and then stops reading it keeps the
/// sampler in the reflection but loses its binding, and the engine's
/// `bindTexture` hands that index straight to the backend. Metal takes it
/// unchecked and dies inside `setFragmentTexture:atIndex:`, which is a crash
/// rather than a rendering artifact, and the shader edit that caused it can be
/// several passes away from the draw that dies.
const int _prunedResourceIndex = 0xFFFFFFFF;

Future<Map<String, Object?>> _reflect(
  Uri impellerc,
  Directory temp,
  String entry,
  String path,
  String type,
) async {
  final reflection = File.fromUri(temp.uri.resolve('$entry.json'));
  final result = await Process.run(impellerc.toFilePath(), [
    '--metal-desktop',
    '--input-type=$type',
    '--input=$path',
    '--sl=${temp.uri.resolve('$entry.out').toFilePath()}',
    '--spirv=${temp.uri.resolve('$entry.spirv').toFilePath()}',
    '--reflection-json=${reflection.path}',
    '--include=${Directory.current.uri.resolve('shaders/').toFilePath()}',
    '--include=${Directory.current.uri.toFilePath()}',
    '--include=${impellerc.resolve('./shader_lib').toFilePath()}',
  ]);
  expect(
    result.exitCode,
    0,
    reason: '$entry: ${result.stdout}${result.stderr}',
  );
  return (jsonDecode(reflection.readAsStringSync()) as Map).cast();
}

void main() {
  test('every bundled shader keeps all of its declared samplers', () async {
    final manifest =
        jsonDecode(File('shaders/base.shaderbundle.json').readAsStringSync())
            as Map<String, dynamic>;
    final impellerc = await findImpellerC();
    final temp = Directory.systemTemp.createTempSync('bundle_bindings');
    try {
      final pruned = <String>[];
      for (final entry in manifest.entries) {
        final spec = entry.value as Map<String, dynamic>;
        final reflection = await _reflect(
          impellerc,
          temp,
          entry.key,
          spec['file'] as String,
          spec['type'] == 'vertex' ? 'vert' : 'frag',
        );
        final samplers =
            (reflection['sampled_images'] as List<Object?>? ?? const [])
                .cast<Map<String, Object?>>();
        for (final sampler in samplers) {
          if ((sampler['ext_res_0'] as num?)?.toInt() == _prunedResourceIndex) {
            pruned.add('${entry.key}.${sampler['name']}');
          }
        }
      }
      expect(
        pruned,
        isEmpty,
        reason:
            'these samplers are declared but never read, so the optimizer '
            'pruned their binding while the reflection still lists them; '
            'binding one crashes the Metal backend. Either read the sampler '
            'or stop declaring it: $pruned',
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a variant that predefines the base colour sample of the standard '
      'shader compiles and binds the samplers its sample reads', () async {
    final impellerc = await findImpellerC();
    final temp = Directory.systemTemp.createTempSync('bundle_bindings');
    try {
      final variant = File.fromUri(temp.uri.resolve('variant.frag'))
        ..writeAsStringSync('''
uniform sampler2D variant_texture;

#define FLUTTER_SCENE_BASE_COLOR_SAMPLE(uv) (texture(base_color_texture, uv) * texture(variant_texture, uv))
#include <flutter_scene_standard.frag>
''');
      final reflection = await _reflect(
        impellerc,
        temp,
        'variant',
        variant.path,
        'frag',
      );
      final bound = {
        for (final sampler
            in (reflection['sampled_images'] as List<Object?>? ?? const [])
                .cast<Map<String, Object?>>())
          if ((sampler['ext_res_0'] as num?)?.toInt() != _prunedResourceIndex)
            sampler['name'],
      };
      expect(bound, containsAll(['base_color_texture', 'variant_texture']));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('a variant that predefines the base colour of the standard shader '
      'compiles and binds the block its colour reads', () async {
    final impellerc = await findImpellerC();
    final temp = Directory.systemTemp.createTempSync('bundle_bindings');
    try {
      final variant = File.fromUri(temp.uri.resolve('variant.frag'))
        ..writeAsStringSync('''
uniform VariantInfo {
  vec4 symbol;
}
variant_info;

vec3 VariantAlbedo(vec3 internal, vec3 vertex, vec4 symbol) {
  float brightness = max(internal.r, max(internal.g, internal.b));
  return brightness * vertex * symbol.rgb;
}

#define FLUTTER_SCENE_BASE_COLOR(base_srgb, vertex_color, factor) \\
  vec4(VariantAlbedo(SRGBToLinear((base_srgb).rgb) * (factor).rgb, \\
                     (vertex_color).rgb, variant_info.symbol), \\
       (base_srgb).a * (factor).a)
#include <flutter_scene_standard.frag>
''');
      final reflection = await _reflect(
        impellerc,
        temp,
        'variant',
        variant.path,
        'frag',
      );
      final blocks = {
        for (final block
            in (reflection['buffers'] as List<Object?>? ?? const [])
                .cast<Map<String, Object?>>())
          block['name'],
      };
      expect(blocks, contains('VariantInfo'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
