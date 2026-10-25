import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';
import 'package:flutter_scene_wgpu/flutter_scene_wgpu.dart';
import 'package:flutter_test/flutter_test.dart';

const size = 64;
const blue = [0, 0, 255, 255];

const triangleShader = '''
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var p = array<vec2<f32>, 3>(vec2(-0.5, -0.5), vec2(0.5, -0.5), vec2(0.0, 0.5));
  return vec4<f32>(p[i], 0.0, 1.0);
}
@fragment fn fs() -> @location(0) vec4<f32> { return vec4<f32>(1.0, 0.0, 0.0, 1.0); }
''';

const quadShader = '''
struct Params { color: vec4<f32>, scale: vec4<f32> };
@group(0) @binding(0) var<uniform> params: Params;
@vertex fn vs(@location(0) pos: vec2<f32>, @location(1) offset: vec2<f32>) -> @builtin(position) vec4<f32> {
  return vec4<f32>(pos * params.scale.xy + offset, 0.0, 1.0);
}
@fragment fn fs() -> @location(0) vec4<f32> { return params.color; }
''';

List<int> pixel(Uint8List rgba, int x, int y) {
  final i = (y * size + x) * 4;
  return rgba.sublist(i, i + 4);
}

Uint8List floats(List<double> values) =>
    Float32List.fromList(values).buffer.asUint8List();

void main() {
  late WgpuDevice device;
  late WgpuTexture target;

  setUpAll(() {
    device = WgpuDevice.createHeadless();
    // ignore: avoid_print
    print(
      'adapter: ${device.adapterName} (${device.backend.name}), '
      'compute ${device.features.compute}, '
      'timestamps ${device.features.timestampQueries}, '
      'max 2D texture ${device.limits.maxTextureDimension2D}',
    );
  });

  setUp(() => target = device.createTexture(size, size));
  tearDown(() => target.destroy());
  tearDownAll(() => device.destroy());

  WgpuColorAttachment clearToBlue() => WgpuColorAttachment(
    texture: target,
    clearColor: const WgpuColor(0, 0, 1, 1),
  );

  Uint8List readBack() =>
      target.read(width: size, height: size, bytesPerPixel: 4);

  test('a WGSL triangle over a clear colour reads back', () {
    final shader = device.createShaderFromWgsl(triangleShader);
    final pipeline = device.createPipeline(
      WgpuPipelineDescriptor(
        vertexShader: shader,
        vertexEntryPoint: 'vs',
        fragmentShader: shader,
        fragmentEntryPoint: 'fs',
        colorTargets: const [
          WgpuColorTarget(format: PixelFormat.r8g8b8a8UNormInt),
        ],
      ),
    );
    final commands = WgpuCommandStream()
      ..beginRenderPass([clearToBlue()])
      ..bindPipeline(pipeline)
      ..draw(3)
      ..endRenderPass();
    device.submit(commands);
    commands.dispose();

    final rgba = readBack();
    expect(pixel(rgba, size ~/ 2, size ~/ 2), [255, 0, 0, 255]);
    expect(pixel(rgba, 0, 0), blue);
    pipeline.destroy();
    shader.destroy();
  });

  test('an indexed, instanced draw with a uniform buffer reads back', () {
    final shader = device.createShaderFromWgsl(quadShader);
    final pipeline = device.createPipelineAsync(
      WgpuPipelineDescriptor(
        vertexShader: shader,
        fragmentShader: shader,
        vertexBuffers: const [
          WgpuVertexBufferLayout(
            strideInBytes: 8,
            attributes: [
              WgpuVertexAttribute(location: 0, format: VertexFormat.float32x2),
            ],
          ),
          WgpuVertexBufferLayout(
            strideInBytes: 8,
            stepMode: VertexStepMode.instance,
            attributes: [
              WgpuVertexAttribute(location: 1, format: VertexFormat.float32x2),
            ],
          ),
        ],
        colorTargets: const [
          WgpuColorTarget(format: PixelFormat.r8g8b8a8UNormInt),
        ],
      ),
    );
    final vertices = device.createBufferWithData(
      floats([-1, -1, 1, -1, 1, 1, -1, 1]),
      WgpuBufferUsage.vertex,
    );
    final instances = device.createBufferWithData(
      floats([-0.5, 0, 0.5, 0]),
      WgpuBufferUsage.vertex,
    );
    final indices = device.createBufferWithData(
      Uint16List.fromList([0, 1, 2, 0, 2, 3]).buffer.asUint8List(),
      WgpuBufferUsage.index,
    );
    final uniforms = device.createBufferWithData(
      floats([0, 1, 0, 1, 0.3, 0.3, 0, 0]),
      WgpuBufferUsage.uniform,
    );

    while (!pipeline.isReady) {}

    final commands = WgpuCommandStream()
      ..beginRenderPass([clearToBlue()])
      ..bindPipeline(pipeline)
      ..bindVertexBuffer(0, vertices)
      ..bindVertexBuffer(1, instances)
      ..bindIndexBuffer(indices, IndexType.int16)
      ..bindBuffer(0, 0, uniforms, size: 32)
      ..drawIndexed(6, instanceCount: 2)
      ..endRenderPass();
    device.submit(commands);
    commands.dispose();

    final rgba = readBack();
    const green = [0, 255, 0, 255];
    expect(pixel(rgba, size ~/ 4, size ~/ 2), green, reason: 'left instance');
    expect(pixel(rgba, 3 * size ~/ 4, size ~/ 2), green, reason: 'right one');
    expect(pixel(rgba, size ~/ 2, size ~/ 2), blue, reason: 'gap between');
    expect(pixel(rgba, 0, 0), blue, reason: 'corner');
    for (final o in [pipeline, vertices, instances, indices, uniforms, shader]) {
      o.destroy();
    }
  });

  test('MSAA resolve and mipmap generation', () {
    final shader = device.createShaderFromWgsl(triangleShader);
    final pipeline = device.createPipeline(
      WgpuPipelineDescriptor(
        vertexShader: shader,
        vertexEntryPoint: 'vs',
        fragmentShader: shader,
        fragmentEntryPoint: 'fs',
        sampleCount: 4,
        colorTargets: const [
          WgpuColorTarget(format: PixelFormat.r8g8b8a8UNormInt),
        ],
      ),
    );
    final msaa = device.createTexture(size, size, sampleCount: 4);
    final mipped = device.createTexture(size, size, mipLevelCount: 7);
    final commands = WgpuCommandStream()
      ..beginRenderPass([
        WgpuColorAttachment(
          texture: msaa,
          storeAction: StoreAction.multisampleResolve,
          clearColor: const WgpuColor(0, 0, 1, 1),
          resolveTexture: target,
        ),
      ])
      ..bindPipeline(pipeline)
      ..draw(3)
      ..endRenderPass()
      ..beginRenderPass([
        WgpuColorAttachment(
          texture: mipped,
          clearColor: const WgpuColor(1, 1, 0, 1),
        ),
      ])
      ..endRenderPass()
      ..generateMipmaps(mipped);
    device.submit(commands);
    commands.dispose();

    final rgba = readBack();
    expect(pixel(rgba, size ~/ 2, size ~/ 2), [255, 0, 0, 255]);
    expect(pixel(rgba, 0, 0), blue);
    expect(
      mipped.read(mipLevel: 6, width: 1, height: 1, bytesPerPixel: 4),
      [255, 255, 0, 255],
    );
    for (final o in [pipeline, msaa, mipped, shader]) {
      o.destroy();
    }
  });

  test('errors surface as exceptions with the native message', () {
    expect(
      () => device.createShaderFromWgsl('not wgsl'),
      throwsA(
        isA<WgpuException>().having(
          (e) => e.code,
          'code',
          WgpuErrorCode.shaderCompile,
        ),
      ),
    );
    final commands = WgpuCommandStream()..draw(3);
    expect(
      () => device.submit(commands),
      throwsA(
        isA<WgpuException>().having(
          (e) => e.message,
          'message',
          contains('render pass'),
        ),
      ),
    );
    commands.dispose();
  });
}
