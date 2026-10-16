// The backend builds a native pipeline at the first draw that meets a render
// pipeline in a state it has not drawn in, so a budgeted warm-up frame counts
// that draw against its build budget and skips the next such draw once the
// budget is spent, as it skips a pipeline it would build.
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
    show deferredPipelineBuilds, resolvePipeline, withPipelineBuildBudget;

const _spent = Duration(microseconds: 1);

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
      'warm-up state slices (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.',
    );
    return;
  }

  test('a budgeted frame that spent its budget skips a draw in a pipeline '
      'state no draw met before', () async {
    await Scene.initializeStaticResources();
    final vertex = baseShaderLibrary['FullscreenVertex']!;
    final fragment = baseShaderLibrary['LinearDepthProbeFragment']!;
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
    void draw(gpu.CullMode cull, gpu.WindingOrder winding) {
      pass
        ..clearBindings()
        ..bindTrackedPipeline(resolvePipeline(vertex, fragment))
        ..setTrackedColorBlendEnable(false)
        ..setTrackedCullMode(cull)
        ..setTrackedWindingOrder(winding);
      bindVertexBufferCompat(
        pass,
        gpu.BufferView(quad, offsetInBytes: 0, lengthInBytes: quad.sizeInBytes),
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
    }

    draw(gpu.CullMode.none, gpu.WindingOrder.clockwise);
    withPipelineBuildBudget(_spent, () {
      draw(gpu.CullMode.backFace, gpu.WindingOrder.clockwise);
      draw(gpu.CullMode.frontFace, gpu.WindingOrder.counterClockwise);
    });
    commandBuffer.submit();

    expect(deferredPipelineBuilds, 1);
  });
}
