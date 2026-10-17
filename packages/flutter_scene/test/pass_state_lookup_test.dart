// A pass looks the pipeline state a draw meets up once each time that state
// changes: the draws of a run in one state, each binding its pipeline and
// setting its state again, and the count of the pipelines it builds read what
// that one lookup found.
// Needs a GPU device: flutter test --enable-impeller --enable-flutter-gpu.

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/frame_transients.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/scene_encoder.dart'
    show countPipelineState, resolvePipeline;

const _states = [
  (gpu.CullMode.none, gpu.WindingOrder.clockwise),
  (gpu.CullMode.backFace, gpu.WindingOrder.clockwise),
  (gpu.CullMode.frontFace, gpu.WindingOrder.counterClockwise),
  (gpu.CullMode.none, gpu.WindingOrder.clockwise),
];
const _drawsPerState = 5;

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

gpu.Texture _texture({bool target = false}) => gpu.gpuContext.createTexture(
  gpu.StorageMode.devicePrivate,
  4,
  4,
  format: gpu.PixelFormat.r8g8b8a8UNormInt,
  enableRenderTargetUsage: target,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'pass state lookups (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.',
    );
    return;
  }

  test('a run of draws looks its pipeline state up once per state '
      'change', () async {
    await Scene.initializeStaticResources();
    final vertex = baseShaderLibrary['FullscreenVertex']!;
    final fragment = baseShaderLibrary['LinearDepthProbeFragment']!;
    final pipeline = resolvePipeline(vertex, fragment);
    final source = _texture();
    final quad = gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
      ),
    );
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final pass = createTrackedRenderPass(
      commandBuffer,
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: _texture(target: true)),
      ),
    );
    passStateLookups = 0;
    for (final (cull, winding) in _states) {
      for (var draw = 0; draw < _drawsPerState; draw++) {
        pass
          ..clearBindings()
          ..bindTrackedPipeline(pipeline)
          ..setTrackedCullMode(cull)
          ..setTrackedWindingOrder(winding);
        bindVertexBufferCompat(
          pass,
          gpu.BufferView(
            quad,
            offsetInBytes: 0,
            lengthInBytes: quad.sizeInBytes,
          ),
          6,
        );
        pass
          ..bindUniform(
            fragment.getUniformSlot('ProbeInfo'),
            uniformTransients.emplace(
              ByteData.sublistView(Float32List.fromList([0, 2, 0, 0])),
            ),
          )
          ..bindTexture(fragment.getUniformSlot('written'), source);
        drawCompat(pass, 6);
        countPipelineState(pass, pipeline);
      }
    }
    commandBuffer.submit();

    expect(passStateLookups, _states.length);
  });
}
