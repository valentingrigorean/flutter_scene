// The WebGL2 backend compiles a shader where it is first looked up, and
// reads no link status of a program before the browser reports it complete.
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

Uint8List _bundle() {
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
  const fragment =
      '#version 100\nprecision mediump float;\n'
      'void main() { gl_FragColor = vec4(1.0); }\n';
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
}
