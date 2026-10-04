// Covers the masked depth override: a material that supplies its own masked
// depth fragment shader is the shader the coverage pre-draw, the depth
// prepass and the shadow pass draw it with and bind its mask against, a
// material that supplies none keeps the engine's masked shaders, and a
// fragment that defines DEPTH_MASK_COVERAGE over each engine masked fragment
// compiles.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_gpu_shaders/environment.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

class _OwnMaskMaterial extends PhysicallyBasedMaterial {
  _OwnMaskMaterial(this.own) {
    alphaMode = AlphaMode.mask;
  }

  final Map<MaskedDepthPass, gpu.Shader> own;
  final List<MaskedDepthPass> asked = [];
  final List<gpu.Shader> bound = [];

  @override
  gpu.Shader? maskedDepthFragmentShader(MaskedDepthPass pass) {
    asked.add(pass);
    return own[pass];
  }

  @override
  void bindDepthAlphaMask(
    gpu.RenderPass pass,
    gpu.Shader shader,
    TransientWriter transientsBuffer,
  ) {
    bound.add(shader);
    if (own.containsValue(shader)) return;
    super.bindDepthAlphaMask(pass, shader, transientsBuffer);
  }
}

Set<gpu.Shader> _drawn(_OwnMaskMaterial material, {bool reflections = false}) {
  final scene = Scene()
    ..directionalLight = DirectionalLight(castsShadow: true)
    ..add(Node(mesh: Mesh(PlaneGeometry(width: 4, depth: 4), material)));
  scene.ambientOcclusion.enabled = !reflections;
  scene.screenSpaceReflections.enabled = reflections;
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(position: Vector3(0, 3, 3), target: Vector3.zero()),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
    pixelRatio: 1.0,
  );
  recorder.endRecording();
  return material.bound.toSet();
}

bool _hasNamedResource(Object? value, String name) {
  if (value is Map) {
    if (value['name'] == name) return true;
    return value.values.any((entry) => _hasNamedResource(entry, name));
  }
  if (value is List) {
    return value.any((entry) => _hasNamedResource(entry, name));
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a material supplies no masked depth fragment by default', () {
    for (final pass in MaskedDepthPass.values) {
      expect(PhysicallyBasedMaterial().maskedDepthFragmentShader(pass), isNull);
    }
  });

  test('a fragment that defines DEPTH_MASK_COVERAGE compiles over each '
      'engine masked fragment on every impellerc backend', () async {
    final temp = Directory.systemTemp.createTempSync('masked_depth_coverage');
    try {
      final impellerc = await findImpellerC();
      final passes = {
        'linear_depth': (define: null, block: 'DepthInfo'),
        'linear_depth_normal': (
          define: 'MASKED_DEPTH_NORMAL',
          block: 'DepthNormalInfo',
        ),
        'shadow': (define: 'MASKED_DEPTH_SHADOW', block: null),
        'coverage': (define: 'MASKED_DEPTH_COVERAGE', block: 'CoverageInfo'),
      };
      for (final MapEntry(key: pass, value: (:define, :block))
          in passes.entries) {
        for (final backend in ['opengl-es', 'metal-desktop', 'vulkan']) {
          final reflection = File.fromUri(
            temp.uri.resolve('$pass.$backend.json'),
          );
          final result = await Process.run(impellerc.toFilePath(), [
            '--$backend',
            '--input-type=frag',
            '--input=test/shaders/masked_depth_coverage.frag',
            '--sl=${temp.uri.resolve('$pass.$backend.sl').toFilePath()}',
            '--spirv=${temp.uri.resolve('$pass.$backend.spirv').toFilePath()}',
            '--reflection-json=${reflection.path}',
            '--include=${Directory.current.uri.resolve('shaders/').toFilePath()}',
            '--include=${impellerc.resolve('./shader_lib').toFilePath()}',
            if (define != null) '--define=$define',
            if (backend == 'opengl-es') '--gles-language-version=300',
          ]);
          expect(
            result.exitCode,
            0,
            reason: '$pass $backend: ${result.stdout}\n${result.stderr}',
          );
          final parsed = jsonDecode(reflection.readAsStringSync());
          for (final name in ['MaskInfo', 'mask_texture', ?block]) {
            expect(
              _hasNamedResource(parsed, name),
              isTrue,
              reason: '$pass $backend should reflect $name',
            );
          }
        }
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  if (!_gpuAvailable()) {
    test(
      'masked depth override draw (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  test('the coverage pre-draw, the prepass and the shadow pass draw a masked '
      'material through its own masked depth fragments', () async {
    await Scene.initializeStaticResources();
    final own = {
      MaskedDepthPass.coverage: baseShaderLibrary['CoverageFragment']!,
      MaskedDepthPass.linearDepth: baseShaderLibrary['LinearDepthFragment']!,
      MaskedDepthPass.linearDepthNormal:
          baseShaderLibrary['LinearDepthNormalFragment']!,
      MaskedDepthPass.shadow: baseShaderLibrary['DepthOnlyFragment']!,
    };
    final depth = _OwnMaskMaterial(own);
    final normals = _OwnMaskMaterial(own);

    expect(_drawn(depth), {
      own[MaskedDepthPass.coverage],
      own[MaskedDepthPass.linearDepth],
      own[MaskedDepthPass.shadow],
    });
    expect(depth.asked.toSet(), {
      MaskedDepthPass.coverage,
      MaskedDepthPass.linearDepth,
      MaskedDepthPass.shadow,
    });
    expect(_drawn(normals, reflections: true), {
      own[MaskedDepthPass.coverage],
      own[MaskedDepthPass.linearDepthNormal],
      own[MaskedDepthPass.shadow],
    });
    expect(normals.asked.toSet(), {
      MaskedDepthPass.coverage,
      MaskedDepthPass.linearDepthNormal,
      MaskedDepthPass.shadow,
    });
  });

  test('a masked material that supplies no fragment draws through the '
      "engine's masked depth fragments", () async {
    await Scene.initializeStaticResources();
    final material = _OwnMaskMaterial(const {});

    expect(_drawn(material), {
      baseShaderLibrary['CoverageFragment'],
      baseShaderLibrary['LinearDepthMaskedFragment'],
      baseShaderLibrary['DepthOnlyMaskedFragment'],
    });
    expect(material.asked.toSet(), {
      MaskedDepthPass.coverage,
      MaskedDepthPass.linearDepth,
      MaskedDepthPass.shadow,
    });
  });

  test('a material that writes full geometry is asked for no masked '
      'fragment', () async {
    await Scene.initializeStaticResources();
    final material = _OwnMaskMaterial(const {})..alphaMode = AlphaMode.opaque;

    expect(_drawn(material), isEmpty);
    expect(material.asked, isEmpty);
  });
}
