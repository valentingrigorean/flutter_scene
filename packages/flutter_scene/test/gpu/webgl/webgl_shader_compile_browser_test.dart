// The WebGL2 backend compiles a shader where it is first looked up, not
// every shader of its bundle at load, reads no link status of a program
// before the browser reports it complete, and a hot reload of its asset
// reaches a shader first looked up after it.
//
//   flutter test --platform chrome --dart-define=FLUTTER_SCENE_GPU_BACKEND=webgl2 \
//     test/gpu/webgl/webgl_shader_compile_browser_test.dart
//
// ignore_for_file: implementation_imports
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/web/_gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/web/shader_bundle_generated.dart' as fb;
import 'package:flutter_scene/src/gpu/web/webgl/_webgl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

const int _completionStatus = 0x91B1;

Uint8List _bundle({String color = '1.0'}) {
  fb.ShaderObjectBuilder shader(
    String name,
    fb.ShaderStage stage,
    String source,
  ) => fb.ShaderObjectBuilder(
    name: name,
    openglEs: fb.BackendShaderObjectBuilder(
      stage: stage,
      entrypoint: 'main',
      inputs: [
        if (stage == fb.ShaderStage.kVertex)
          fb.ShaderInputObjectBuilder(name: 'position'),
      ],
      uniformStructs: const [],
      uniformTextures: const [],
      shader: utf8.encode(source),
    ),
  );
  const vertex =
      '#version 100\nattribute vec2 position;\n'
      'void main() { gl_Position = vec4(position, 0.0, 1.0); }\n';
  final fragment =
      '#version 100\nprecision mediump float;\n'
      'void main() { gl_FragColor = vec4($color); }\n';
  return fb.ShaderBundleObjectBuilder(
    formatVersion: 2,
    shaders: [
      shader('PointVertex', fb.ShaderStage.kVertex, vertex),
      shader('WhiteFragment', fb.ShaderStage.kFragment, fragment),
      shader('UnusedFragment', fb.ShaderStage.kFragment, fragment),
    ],
  ).toBytes();
}

Future<gpu.ShaderLibrary> _library() async => (await gpu
    .loadShaderLibraryFromBytesAsync(ByteData.sublistView(_bundle())))!;

void main() {
  if (!gpu.webGl2Forced) {
    test('needs FLUTTER_SCENE_GPU_BACKEND=webgl2', () {
      markTestSkipped('The build does not force the WebGL2 shim.');
    });
    return;
  }

  setUpAll(gpu.initializeGpuBackend);

  test('a library compiles only the shaders looked up', () async {
    final gl = (gpu.gpuContext as WebGlContext).gl as JSObject;
    final compileShader = gl['compileShader']! as JSFunction;
    var compiles = 0;
    gl['compileShader'] = ((JSAny? shader) {
      compiles++;
      compileShader.callAsFunction(gl, shader);
    }).toJS;
    final library = await _library();
    expect(compiles, 0);
    library['PointVertex'];
    library['PointVertex'];
    expect(compiles, 1);
    gl.delete('compileShader'.toJS);
  });

  test(
    'a pipeline reads no link status before its program completes',
    () async {
      final context = gpu.gpuContext as WebGlContext;
      if (context.gl.getExtension('KHR_parallel_shader_compile') == null) {
        markTestSkipped('The browser lacks KHR_parallel_shader_compile.');
        return;
      }
      final gl = context.gl as JSObject;
      var complete = false;
      final asked = <int>[];
      final getProgramParameter = gl['getProgramParameter']! as JSFunction;
      gl['getProgramParameter'] = ((JSAny? program, JSNumber name) {
        final parameter = name.toDartInt;
        if (parameter == _completionStatus && !complete) return false.toJS;
        asked.add(parameter);
        return getProgramParameter.callAsFunction(gl, program, name);
      }).toJS;
      final library = await _library();
      final pipeline = gpu.gpuContext.createRenderPipeline(
        library['PointVertex']!,
        library['WhiteFragment']!,
      );
      final color = gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        4,
        4,
      );
      final vertices = gpu.gpuContext.createDeviceBufferWithCopy(
        ByteData.sublistView(Float32List.fromList([0, 0, 1, 0, 0, 1])),
      );
      int drawSkipped() => gpu.gpuHost.skipCompilingDraws(() {
        final commands = gpu.gpuContext.createCommandBuffer();
        commands.createRenderPass(
            gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: color)),
          )
          ..bindPipeline(pipeline)
          ..bindVertexBuffer(
            gpu.BufferView(vertices, offsetInBytes: 0, lengthInBytes: 24),
          )
          ..draw(3);
        commands.submit();
      });

      expect(drawSkipped(), 1);
      expect(asked, isNot(contains(web.WebGL2RenderingContext.LINK_STATUS)));
      complete = true;
      await gpu.gpuHost.pipelinesReady();
      expect(drawSkipped(), 0);
      expect(asked, contains(web.WebGL2RenderingContext.LINK_STATUS));
      gl.delete('getProgramParameter'.toJS);
    },
  );

  test('a shader that fails to compile throws on every lookup', () async {
    final context = gpu.gpuContext as WebGlContext;
    if (context.gl.getExtension('KHR_parallel_shader_compile') != null) {
      markTestSkipped(
        'Where compiles run in parallel, a failed compile throws when its '
        'program links.',
      );
      return;
    }
    final library = (await gpu.loadShaderLibraryFromBytesAsync(
      ByteData.sublistView(_bundle(color: 'missing')),
    ))!;
    expect(() => library['WhiteFragment'], throwsException);
    expect(() => library['WhiteFragment'], throwsException);
    expect(library['NoSuchShader'], isNull);
  });

  test(
    'a shader first looked up after a reload compiles the new source',
    () async {
      final window = web.window as JSObject;
      final fetch = window['fetch']! as JSFunction;
      var bundle = _bundle(color: '0.25');
      window['fetch'] = ((JSAny? _, JSAny? _) => Future<JSAny?>.value(
        web.Response(bundle.toJS),
      ).toJS).toJS;
      final gl = (gpu.gpuContext as WebGlContext).gl as JSObject;
      final shaderSource = gl['shaderSource']! as JSFunction;
      final sources = <String>[];
      gl['shaderSource'] = ((JSAny? shader, JSString source) {
        sources.add(source.toDart);
        shaderSource.callAsFunction(gl, shader, source);
      }).toJS;
      try {
        final first = (await gpu.loadShaderLibraryAsync(
          'reload_test.shaderbundle',
        ))!;
        final second = (await gpu.loadShaderLibraryAsync(
          'reload_test.shaderbundle',
        ))!;
        bundle = _bundle(color: '0.75');
        await gpu.reinitializeShaderLibraryAsync('reload_test.shaderbundle');
        first['UnusedFragment'];
        second['UnusedFragment'];
        expect(sources, hasLength(2));
        expect(sources, everyElement(contains('0.75')));
      } finally {
        window['fetch'] = fetch;
        gl.delete('shaderSource'.toJS);
      }
    },
  );
}
