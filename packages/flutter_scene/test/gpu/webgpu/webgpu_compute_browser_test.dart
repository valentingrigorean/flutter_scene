// Runs compute passes and an indirect draw through the WebGPU backend's shim
// API: one dispatch writes the workgroup counts of a second, which writes
// the draw arguments the indirect draw reads.
//
//   flutter test --platform chrome \
//     test/gpu/webgpu/webgpu_compute_browser_test.dart
//
// ignore_for_file: implementation_imports
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/shared/sidecar_hash.dart';
import 'package:flutter_scene/src/gpu/web/_gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/webgpu/webgpu_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

final Uint8List _bundle = Uint8List.fromList(utf8.encode('compute bundle'));

Map<String, Object?> _shader(String stage, String wgsl, List<Object?> inputs) =>
    {
      'stage': stage,
      'entryPoint': 'main',
      'wgsl': wgsl,
      'inputs': inputs,
      'uniforms': <Object?>[],
      'textures': <Object?>[],
    };

String _sidecar() => jsonEncode({
  'format': 2,
  'translator': 'test',
  'bundle': sidecarBundleHash(_bundle),
  'shaders': {
    'CornerVertex': _shader(
      'vertex',
      '''
@vertex
fn main(@location(0u) corner : vec2<f32>) -> @builtin(position) vec4<f32> {
  return vec4<f32>(corner * 2.0 - 1.0, 0.5, 1.0);
}
''',
      [
        {'name': 'corner', 'location': 0, 'vecSize': 2, 'offset': 0},
      ],
    ),
    'RedFragment': _shader('fragment', '''
@fragment
fn main() -> @location(0u) vec4<f32> {
  return vec4<f32>(1.0, 0.0, 0.0, 1.0);
}
''', const []),
  },
});

// Two entry points, so each pipeline binds both of the module's buffers.
const _computeWgsl = '''
@group(0) @binding(0) var<storage, read_write> workgroups : array<u32, 3>;
@group(0) @binding(1) var<storage, read_write> draw : array<u32, 5>;

@compute @workgroup_size(1)
fn size() {
  workgroups = array<u32, 3>(1u, 1u, 1u);
}

@compute @workgroup_size(1)
fn arguments() {
  draw = array<u32, 5>(6u, 1u, 0u, 0u, 0u);
}
''';

const _copyWgsl = '''
@group(0) @binding(0) var<storage, read_write> copiedFrom : array<u32, 4>;
@group(0) @binding(1) var<storage, read_write> copiedTo : array<u32, 4>;

@compute @workgroup_size(1)
fn main() {
  copiedTo = copiedFrom;
}
''';

gpu.BufferView _view(gpu.DeviceBuffer buffer) =>
    gpu.BufferView(buffer, offsetInBytes: 0, lengthInBytes: buffer.sizeInBytes);

void main() {
  if (gpu.webGl2Forced) {
    test('needs a build without FLUTTER_SCENE_GPU_BACKEND=webgl2', () {
      markTestSkipped('The build forces the WebGL2 shim.');
    });
    return;
  }

  test('a dispatch writes the arguments an indirect draw reads', () async {
    await gpu.initializeGpuBackend();
    expect(gpu.gpuHost.capabilities.compute, isTrue);
    expect(gpu.gpuHost.capabilities.indirectDraw, isTrue);
    final context = gpu.gpuContext;
    final library = await webGpuShaderLibraryFromSidecar(_sidecar());
    final render = context.createRenderPipeline(
      library['CornerVertex']!,
      library['RedFragment']!,
    );
    final size = context.createComputePipeline(
      _computeWgsl,
      entryPoint: 'size',
    );
    final arguments = context.createComputePipeline(
      _computeWgsl,
      entryPoint: 'arguments',
    );
    final workgroups = context.createDeviceBuffer(
      gpu.StorageMode.devicePrivate,
      12,
    );
    final draw = context.createDeviceBuffer(gpu.StorageMode.devicePrivate, 20);
    // The dispatch reading its counts from workgroups binds another buffer
    // there, since one dispatch cannot write what it reads its counts from.
    final spare = context.createDeviceBuffer(gpu.StorageMode.devicePrivate, 12);
    final corners = context.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([0, 0, 1, 0, 0, 1, 1, 1])),
    );
    final indices = context.createDeviceBufferWithCopy(
      ByteData.sublistView(Uint16List.fromList([0, 1, 2, 2, 1, 3])),
    );
    final color = context.createTexture(gpu.StorageMode.devicePrivate, 4, 4);

    final commands = context.createCommandBuffer();
    commands.createComputePass()
      ..bindPipeline(size)
      ..bindBuffer(0, 0, _view(workgroups))
      ..bindBuffer(0, 1, _view(draw))
      ..dispatch(1)
      ..bindPipeline(arguments)
      ..bindBuffer(0, 0, _view(spare))
      ..dispatchIndirect(_view(workgroups));
    commands.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(
            texture: color,
            clearValue: vm.Vector4(0, 1, 0, 1),
          ),
        ),
      )
      ..bindPipeline(render)
      ..bindVertexBuffer(_view(corners))
      ..bindIndexBuffer(_view(indices), gpu.IndexType.int16)
      ..drawIndexedIndirect(_view(draw));
    commands.submit();

    expect(Uint32List.sublistView(await webGpuReadBuffer(draw, length: 20)), [
      6,
      1,
      0,
      0,
      0,
    ]);
    final pixels = await webGpuReadTexture(color);
    expect(pixels.sublist(0, 4), [255, 0, 0, 255]);
  });
  test('a buffer released while an unsubmitted command buffer names it is '
      'still read by that submit', () async {
    await gpu.initializeGpuBackend();
    final context = gpu.gpuContext;
    final copy = context.createComputePipeline(_copyWgsl);
    final source = context.createDeviceBufferWithCopy(
      ByteData.sublistView(Uint32List.fromList([3, 5, 7, 9])),
    );
    final target = context.createDeviceBuffer(
      gpu.StorageMode.devicePrivate,
      16,
    );

    final commands = context.createCommandBuffer();
    commands.createComputePass()
      ..bindPipeline(copy)
      ..bindBuffer(0, 0, _view(source))
      ..bindBuffer(0, 1, _view(target))
      ..dispatch(1);
    gpu.gpuHost.releaseBuffer(source);
    commands.submit();

    expect(Uint32List.sublistView(await webGpuReadBuffer(target, length: 16)), [
      3,
      5,
      7,
      9,
    ]);
  });
}
