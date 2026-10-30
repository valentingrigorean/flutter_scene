import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/fullscreen_quad.dart';
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';

import 'package:flutter_scene/src/render/kept_fullscreen.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/resolve_pass.dart';
import 'package:flutter_scene/src/render/retained_draws.dart';
import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/render/uniform_slots.dart';

/// Anti-aliases the display-referred image as a single full-screen FXAA
/// pass. Reads the resolve output from the blackboard, writes [_output],
/// and republishes it so after-tone-mapping effects receive the
/// anti-aliased image.
class FxaaPass extends RenderGraphPass {
  FxaaPass({
    required gpu.Texture output,
    required ui.Size dimensions,
    RenderScene? renderScene,
  }) : _output = output,
       _dimensions = dimensions,
       _renderScene = renderScene;

  final gpu.Texture _output;
  final ui.Size _dimensions;
  // The scene whose item set keeps the draw, or null to encode it.
  final RenderScene? _renderScene;

  static final gpu.Shader _vertexShader =
      baseShaderLibrary['FullscreenVertex']!;
  static final gpu.Shader _fragmentShader = baseShaderLibrary['FxaaFragment']!;

  static final gpu.SamplerOptions _linearClamp = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  @override
  String get name => 'FxaaPass';

  @override
  void execute(RenderGraphContext context) {
    final input = context.blackboard.require<gpu.Texture>(
      kDisplayColorBlackboardKey,
    );

    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: _output),
    );
    final renderPass = commandBuffer.createRenderPass(target);
    final pipeline = resolvePipeline(_vertexShader, _fragmentShader);

    // FxaaInfo std140: { vec2 inv_target_size; vec2 pad; }, 16 bytes.
    final w = _dimensions.width;
    final h = _dimensions.height;
    final info = ByteData.sublistView(
      Float32List(4)
        ..[0] = w == 0 ? 0.0 : 1.0 / w
        ..[1] = h == 0 ? 0.0 : 1.0 / h,
    );

    void record(gpu.RenderPass pass) {
      pass.bindPipeline(pipeline);
      bindVertexBufferCompat(pass, fullscreenQuadView, 6);
      pass.bindTexture(
        _fragmentShader.cachedUniformSlot('scene_color'),
        input,
        sampler: _linearClamp,
      );
      pass.bindUniform(
        _fragmentShader.cachedUniformSlot('FxaaInfo'),
        context.transientsBuffer.emplace(info),
      );
      drawCompat(pass, 6);
    }

    final kept = KeptFullscreen.of(_renderScene, SceneItems.postPass);
    final drawn =
        kept != null &&
        kept.draw(
          renderPass,
          target,
          key: pipeline,
          record: record,
          viewBlocks: [info],
          viewTextures: KeptFullscreen.viewTextures(sceneColor: input),
        );
    if (!drawn) record(renderPass);
    rendererSubmissions.submit(commandBuffer);

    context.blackboard.set(kDisplayColorBlackboardKey, _output);
  }
}
