import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/fullscreen_quad.dart';
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';

import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/post_process/post_process.dart';
import 'package:flutter_scene/src/render/auto_exposure_pass.dart';
import 'package:flutter_scene/src/render/bloom_pass.dart';
import 'package:flutter_scene/src/render/kept_pass_draw.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/retained_draws.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/resolve_info.dart';
import 'package:flutter_scene/src/render/scene_pass.dart';
import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene/src/tone_mapping.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/render/uniform_slots.dart';

/// Render-graph blackboard key for the display-referred color the resolve
/// pass produces. After-tone-mapping custom effects read it and republish
/// their own output.
const String kDisplayColorBlackboardKey = 'display_color';

/// Resolves the linear HDR scene color (a floating-point render target
/// produced by [ScenePass], read from the blackboard) into the
/// display-referred image: applies exposure, optional color grading, the
/// tone mapping operator, and display encoding as a single full-screen
/// pass. Writes into [outputColor] and publishes it on the blackboard.
class ResolvePass extends RenderGraphPass {
  ResolvePass({
    required gpu.Texture outputColor,
    required double exposure,
    required ToneMappingMode toneMappingMode,
    required double agxWhite,
    required double agxContrast,
    required PostProcessSettings postProcess,
    bool debugViewActive = false,
    double debugViewSplit = -1.0,
    bool debugSkipsPost = false,
    RenderScene? renderScene,
  }) : _outputColor = outputColor,
       _exposure = exposure,
       _toneMappingMode = toneMappingMode,
       _agxWhite = agxWhite,
       _agxContrast = agxContrast,
       _postProcess = postProcess,
       _debugViewActive = debugViewActive,
       _debugViewSplit = debugViewSplit,
       _debugSkipsPost = debugSkipsPost,
       _renderScene = renderScene;

  final gpu.Texture _outputColor;
  final double _exposure;
  final ToneMappingMode _toneMappingMode;
  final double _agxWhite;
  final double _agxContrast;
  final PostProcessSettings _postProcess;
  // A surface debug view is active: its pixels copy through the resolve
  // untouched, right of the split (a width fraction, negative for all).
  final bool _debugViewActive;
  final double _debugViewSplit;
  // The frame skipped bloom for a debug view, so the resolve must not add
  // it back whatever the settings say.
  final bool _debugSkipsPost;
  // The scene whose item set keeps the resolve draw, or null to encode it.
  final RenderScene? _renderScene;

  static final gpu.Shader _vertexShader =
      baseShaderLibrary['FullscreenVertex']!;
  static final gpu.Shader _fragmentShader =
      baseShaderLibrary['ResolveFragment']!;

  static final gpu.SamplerOptions _linearClamp = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  static final gpu.SamplerOptions _nearestClamp = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.nearest,
    magFilter: gpu.MinMagFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  @override
  String get name => 'ResolvePass';

  @override
  void execute(RenderGraphContext context) {
    final hdrColor = context.blackboard.require<gpu.Texture>(
      kSceneColorBlackboardKey,
    );

    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: _outputColor),
    );
    final renderPass = commandBuffer.createRenderPass(target);
    final pipeline = resolvePipeline(_vertexShader, _fragmentShader);

    // Render-to-texture content is stored top-down on every backend, so the
    // resolve samples without a fragment-stage V-flip (flipY is always false).
    ByteData infoAt(double time) => ByteData.sublistView(
      packResolveInfo(
        exposure: _exposure,
        toneMappingMode: _toneMappingMode,
        agxWhite: _agxWhite,
        agxContrast: _agxContrast,
        flipY: false,
        time: time,
        settings: _postProcess,
        debugViewActive: _debugViewActive,
        debugViewSplit: _debugViewSplit,
        bloomEnabled: _postProcess.bloom.enabled && !_debugSkipsPost,
      ),
    );
    // Wall-clock seconds (wrapped to keep float precision) drive the
    // animated film grain.
    final info = infoAt(
      DateTime.now().millisecondsSinceEpoch.remainder(100000) / 1000.0,
    );
    // Bloom is present only when BloomPass ran this frame; otherwise a
    // placeholder fills the slot and the resolve skips it (flag off).
    final bloomTexture =
        context.blackboard.get<gpu.Texture>(kBloomTextureBlackboardKey) ??
        Material.getWhitePlaceholderTexture();
    // The adapted auto exposure factor is present only when
    // AutoExposurePass ran this frame; otherwise the white placeholder
    // supplies a neutral 1.0.
    final exposureFactor =
        context.blackboard.get<gpu.Texture>(kAutoExposureFactorBlackboardKey) ??
        Material.getWhitePlaceholderTexture();
    // The film-look grading LUT, or a neutral placeholder when no look is
    // set (lut_params.x stays 0 and the sample is skipped).
    final lut =
        _postProcess.colorGrading.lut?.texture ??
        Material.getWhitePlaceholderTexture();

    void record(gpu.RenderPass pass) {
      pass.bindPipeline(pipeline);
      bindVertexBufferCompat(pass, fullscreenQuadView, 6);
      pass.bindUniform(
        _fragmentShader.cachedUniformSlot('ResolveInfo'),
        context.transientsBuffer.emplace(info),
      );
      pass.bindTexture(
        _fragmentShader.cachedUniformSlot('scene_color'),
        hdrColor,
        sampler: _linearClamp,
      );
      pass.bindTexture(
        _fragmentShader.cachedUniformSlot('bloom_color'),
        bloomTexture,
        sampler: _linearClamp,
      );
      pass.bindTexture(
        _fragmentShader.cachedUniformSlot('exposure_factor'),
        exposureFactor,
        sampler: _nearestClamp,
      );
      pass.bindTexture(
        _fragmentShader.cachedUniformSlot('grading_lut'),
        lut,
        sampler: _linearClamp,
      );
      drawCompat(pass, 6);
    }

    final kept = KeptPassDraw.of(_renderScene, SceneItems.resolvePass);
    final drawn =
        kept != null &&
        kept.draw(
          renderPass,
          target,
          key: (pipeline, lut),
          record: record,
          viewBlocks: [info],
          viewTextures: KeptPassDraw.viewTextures(
            sceneColor: hdrColor,
            bloom: bloomTexture,
            exposureFactor: exposureFactor,
          ),
          replay: (view) => [infoAt(view.time)],
        );
    if (!drawn) record(renderPass);
    rendererSubmissions.submit(commandBuffer);

    context.blackboard.set(kDisplayColorBlackboardKey, _outputColor);
  }
}
