// Covers the raw path's vertex-stage surface: which variant a vertex shader is
// registered for, and that the two stages keep separate uniform and texture
// bindings. The GPU-side binding is covered by the raw_shader_pair smoke scene.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/material/shader_material.dart'
    show missingVertexVariantMessage;
import 'package:flutter_test/flutter_test.dart';

class _OverridingMaterial extends ShaderMaterial {
  final List<String> calls = [];

  @override
  gpu.Shader fragmentShaderForLighting(Lighting lighting) {
    calls.add('fragmentShaderForLighting');
    return super.fragmentShaderForLighting(lighting);
  }

  @override
  gpu.Shader? materialVertexShader(String variant) {
    calls.add('materialVertexShader:$variant');
    return null;
  }

  @override
  void bindVertexStage(
    gpu.RenderPass pass,
    gpu.Shader vertexShader,
    TransientWriter transientsBuffer,
  ) {
    calls.add('bindVertexStage');
  }

  @override
  bool get depthAlphaMasked => true;

  @override
  void bindDepthAlphaMask(
    gpu.RenderPass pass,
    gpu.Shader shader,
    TransientWriter transientsBuffer,
  ) {
    calls.add('bindDepthAlphaMask');
  }
}

void main() {
  group('material hooks outside src/', () {
    test('a subclass overrides every hook a custom pass hands it', () {
      final material = _OverridingMaterial();

      expect(material.materialVertexShader('depth'), isNull);
      expect(material.depthAlphaMasked, isTrue);
      expect(material.calls, ['materialVertexShader:depth']);
    });

    test('no hook is marked internal', () {
      const hooks = [
        'fragmentShaderForLighting',
        'materialVertexShader',
        'vertexShaderForGeometry',
        'bindVertexStage',
        'depthAlphaMasked',
        'bindDepthAlphaMask',
      ];
      final internal = <String>[];
      for (final path in [
        'lib/src/material/material.dart',
        'lib/src/material/preprocessed_material.dart',
      ]) {
        final lines = File(path).readAsLinesSync();
        final declared = <String>{};
        for (final hook in hooks) {
          final declaration = RegExp('^  [^/@ ].*\\b$hook\\b');
          for (var i = 0; i < lines.length; i++) {
            if (!declaration.hasMatch(lines[i])) continue;
            declared.add(hook);
            for (var j = i - 1; j >= 0; j--) {
              final text = lines[j].trim();
              if (text == '@internal') internal.add('$path $hook');
              if (!text.startsWith('@') && !text.startsWith('///')) break;
            }
          }
        }
        if (path.endsWith('/material.dart')) {
          expect(declared, hooks.toSet());
        }
      }
      expect(internal, isEmpty);
    });
  });

  test('no vertex shader means the engine drives the vertex stage', () {
    final material = ShaderMaterial();
    for (final variant in MeshVariant.values) {
      expect(material.vertexShaderFor(variant), isNull);
    }
  });

  test('the missing-variant warning names both sides', () {
    final message = missingVertexVariantMessage([
      MeshVariant.unskinned,
    ], MeshVariant.skinned);
    // The author needs to know which variant to add and why the engine's
    // fallback may not link, so both variant names have to appear.
    expect(message, contains('unskinned'));
    expect(message, contains('skinned'));
    expect(message, contains('varying'));
  });

  test('MeshVariant maps the names the geometry and sidecar use', () {
    expect(MeshVariant.fromName('unskinned'), MeshVariant.unskinned);
    expect(MeshVariant.fromName('skinned'), MeshVariant.skinned);
    expect(MeshVariant.fromName('depth'), MeshVariant.depth);
    // An unknown variant falls back rather than throwing mid-draw.
    expect(MeshVariant.fromName('something-else'), MeshVariant.unskinned);
    expect(MeshVariant.unskinned.name, 'unskinned');
  });

  group('stage-addressed bindings', () {
    test('a block set on one stage does not appear on the other', () {
      final material = ShaderMaterial();
      final bytes = ByteData.sublistView(Float32List.fromList([1, 2, 3, 4]));

      material.setUniformBlock('RippleInfo', bytes, stage: ShaderStage.vertex);
      expect(
        material.getUniformBlock('RippleInfo', stage: ShaderStage.vertex),
        same(bytes),
      );
      expect(material.getUniformBlock('RippleInfo'), isNull);
      expect(material.vertexUniformBlockNames, contains('RippleInfo'));
      expect(material.uniformBlockNames, isNot(contains('RippleInfo')));
    });

    test('the same block name can hold different bytes per stage', () {
      final material = ShaderMaterial();
      final vertexBytes = ByteData(16);
      final fragmentBytes = ByteData(16);

      material.setUniformBlock(
        'Shared',
        vertexBytes,
        stage: ShaderStage.vertex,
      );
      material.setUniformBlock('Shared', fragmentBytes);
      expect(
        material.getUniformBlock('Shared', stage: ShaderStage.vertex),
        same(vertexBytes),
      );
      expect(material.getUniformBlock('Shared'), same(fragmentBytes));
    });

    test('the fragment stage stays the default', () {
      final material = ShaderMaterial();
      material.setUniformBlockFromFloats('FragInfo', [1, 0, 0, 1]);
      expect(material.uniformBlockNames, contains('FragInfo'));
      expect(material.vertexUniformBlockNames, isEmpty);
    });

    test('clearing a binding only clears its own stage', () {
      final material = ShaderMaterial();
      material.setUniformBlock(
        'Shared',
        ByteData(16),
        stage: ShaderStage.vertex,
      );
      material.setUniformBlock('Shared', ByteData(16));

      material.setUniformBlock('Shared', null, stage: ShaderStage.vertex);
      expect(material.vertexUniformBlockNames, isEmpty);
      expect(material.uniformBlockNames, contains('Shared'));
    });

    test('textures are addressed per stage too', () {
      final material = ShaderMaterial();
      expect(material.vertexTextureNames, isEmpty);
      expect(material.textureNames, isEmpty);
      expect(
        () => material.setTexture(
          'displacement',
          Object(),
          stage: ShaderStage.vertex,
        ),
        throwsArgumentError,
      );
    });
  });
}
