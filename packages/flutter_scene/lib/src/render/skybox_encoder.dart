import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/viewport_camera.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/fullscreen_quad.dart';
import 'package:flutter_scene/src/render/kept_pass_draw.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/retained_draws.dart';
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/material/engine_lighting.dart';
import 'package:flutter_scene/src/material/environment.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene/src/skybox.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/uniform_slots.dart';

/// Draws [skybox] into [renderPass] as the scene background.
///
/// Issued before the scene geometry, into the same HDR color target: the sky
/// covers the screen, writes no depth (so opaque geometry, depth-tested
/// against the cleared far value, draws over it) and does not blend. Exposure
/// and tone mapping are applied later by the resolve pass, so the sky is
/// emitted as linear HDR radiance with premultiplied alpha.
///
/// With [renderScene] and the [target] of [renderPass], an environment sky
/// is kept as the [SceneItems.skyPass] item of the scene's item set, so a
/// frame encodes none of it; the pass then keeps its own fixed-function
/// state. An encoded sky leaves the pass with the skybox's (no depth write,
/// `lessEqual` depth compare, no cull, no blend); the scene encoder
/// re-asserts the opaque-phase state when it is constructed afterward.
void encodeSkybox(
  gpu.RenderPass renderPass,
  TransientWriter transientsBuffer,
  Skybox skybox,
  EnvironmentMap environment,
  double environmentIntensity,
  Matrix3? environmentTransform,
  Camera camera,
  ui.Size dimensions, {
  EnvironmentMap? environmentMapB,
  double environmentBlend = 0.0,
  RenderScene? renderScene,
  gpu.RenderTarget? target,
}) {
  final source = skybox.source;
  final vertexShader = baseShaderLibrary['SkyboxVertex']!;
  final gpu.Shader fragmentShader;
  if (source is EnvironmentSkySource) {
    // The variant declaring the sampler type of the bound radiance layout.
    fragmentShader = environment.usesCubeRadianceLayout
        ? baseShaderLibrary['SkyboxEnvironmentCubeFragment']!
        : baseShaderLibrary['SkyboxEnvironmentFragment']!;
  } else if (source is ShaderSkySource) {
    fragmentShader = source.shaderForEnvironment(environment);
  } else {
    return;
  }

  // Share the scene encoder's pipeline cache so a hot-reloaded sky fragment is
  // rebuilt (the cache is evicted by shader identity on reload).
  final pipeline = resolvePipeline(vertexShader, fragmentShader);
  final raster = depthRasterOf(camera);
  // Reconstruct the world view ray from inverse projection and camera
  // rotation, then apply the environment transform.
  final frameInfo = ByteData.sublistView(
    skyboxFrameInfoOf(
      skyboxInverseViewProjection(camera, dimensions),
      camera.position,
      environmentTransform,
      farClipDepth: raster.farClipDepth,
    ),
  );
  // Only a static secondary environment cross-fades the visible sky; with no
  // cross-fade the primary is bound to the `_b` samplers (a no-op, since the
  // blend factor is 0).
  final environmentB = environmentMapB ?? environment;
  final skyboxInfo = source is EnvironmentSkySource
      ? ByteData.sublistView(
          _skyboxInfoOf(
            source,
            environment,
            environmentIntensity * skybox.intensity,
            environmentBlend,
          ),
        )
      : null;

  void record(gpu.RenderPass pass) {
    pass.clearBindings();
    pass.bindTrackedPipeline(pipeline);
    pass.setTrackedColorBlendEnable(false);
    // Draw at the far plane behind everything: pass where nothing has been
    // drawn (depth still at the cleared far value) and never write depth, so
    // opaque geometry draws in front.
    pass.setTrackedDepthWriteEnable(false);
    pass.setTrackedDepthCompareOperation(raster.nearerOrEqual);
    pass.setTrackedCullMode(gpu.CullMode.none);
    pass.setTrackedPrimitiveType(gpu.PrimitiveType.triangle);
    bindVertexBufferCompat(pass, fullscreenQuadView, 6);
    pass.bindUniform(
      vertexShader.cachedUniformSlot('SkyboxFrameInfo'),
      transientsBuffer.emplace(frameInfo),
    );
    // Fragment bindings depend on the source.
    if (source is EnvironmentSkySource) {
      _bindEnvironmentSource(
        pass,
        transientsBuffer,
        fragmentShader,
        skyboxInfo!,
        environment,
        environmentB,
      );
    } else if (source is ShaderSkySource) {
      source.bind(pass, transientsBuffer, environment);
    }
    drawCompat(pass, 6);
  }

  // The environment sky reads only the view blocks and the environment's
  // textures, so the scene's item set keeps it; a shader sky binds what its
  // source chooses and is encoded.
  if (source is EnvironmentSkySource && target != null) {
    final kept = KeptPassDraw.of(renderScene, SceneItems.skyPass);
    if (kept != null &&
        kept.draw(
          renderPass,
          target,
          key: (
            pipeline,
            raster.nearerOrEqual,
            environment.prefilteredRadiance,
            environment.backgroundTexture,
            environment.usesMipRadianceLayout,
            environmentB.prefilteredRadiance,
          ),
          record: record,
          viewBlocks: [frameInfo, skyboxInfo!],
          replay: (view) {
            final seen = view.camera;
            return [
              ByteData.sublistView(
                skyboxFrameInfoOf(
                  skyboxInverseViewProjection(seen, view.dimensions),
                  seen.position,
                  environmentTransform,
                  farClipDepth: depthRasterOf(seen).farClipDepth,
                ),
              ),
              skyboxInfo,
            ];
          },
        )) {
      // The kept sky bound its own pipeline and blocks on the pass.
      renderPass.clearBindings();
      return;
    }
  }
  record(renderPass);
}

/// Builds the skybox transform without camera translation.
///
/// A skybox depends only on camera orientation. Removing translation before
/// inversion avoids subtracting two large float32 world positions in the
/// vertex shader.
@visibleForTesting
Matrix4 skyboxInverseViewProjection(Camera camera, ui.Size dimensions) {
  final viewRotation = camera.getViewMatrix().clone()
    ..setTranslationRaw(0.0, 0.0, 0.0);
  final projection = camera.projection.getProjectionMatrix(
    dimensions.width / dimensions.height,
  );
  final viewProjection = projection * viewRotation;
  return viewProjection..invert();
}

/// The sky vertex shader's `SkyboxFrameInfo` for an explicit
/// [inverseViewProjection] and [cameraPosition].
Float32List skyboxFrameInfoOf(
  Matrix4 inverseViewProjection,
  Vector3 cameraPosition,
  Matrix3? environmentTransform, {
  // The clip depth the sky draws at, the far plane of the pass's depth
  // mapping (see DepthRaster.farClipDepth).
  double farClipDepth = 1.0,
}) {
  final transform = (environmentTransform ?? Matrix3.identity()).storage;
  final frameInfo = Float32List(36);
  frameInfo.setRange(0, 16, inverseViewProjection.storage);
  // environment_transform: a mat4 carrying the 3x3 rotation; std140 mat4
  // columns are 16 bytes (4 floats) each, starting at float 16.
  for (var col = 0; col < 3; col++) {
    frameInfo[16 + col * 4] = transform[col * 3];
    frameInfo[16 + col * 4 + 1] = transform[col * 3 + 1];
    frameInfo[16 + col * 4 + 2] = transform[col * 3 + 2];
  }
  frameInfo[31] = 1.0; // mat4 column 3 = (0, 0, 0, 1)
  frameInfo[32] = cameraPosition.x;
  frameInfo[33] = cameraPosition.y;
  frameInfo[34] = cameraPosition.z;
  frameInfo[35] = farClipDepth;
  return frameInfo;
}

/// Binds the sky vertex shader's `SkyboxFrameInfo` from an explicit
/// [inverseViewProjection] and [cameraPosition]. The offscreen bake binds it
/// once per cube face.
void bindSkyboxFrameInfo(
  gpu.RenderPass renderPass,
  TransientWriter transientsBuffer,
  gpu.Shader vertexShader,
  Matrix4 inverseViewProjection,
  Vector3 cameraPosition,
  Matrix3? environmentTransform, {
  double farClipDepth = 1.0,
}) {
  final frameInfo = skyboxFrameInfoOf(
    inverseViewProjection,
    cameraPosition,
    environmentTransform,
    farClipDepth: farClipDepth,
  );
  renderPass.bindUniform(
    vertexShader.cachedUniformSlot('SkyboxFrameInfo'),
    transientsBuffer.emplace(ByteData.sublistView(frameInfo)),
  );
}

// The built-in environment sky fragment's SkyboxInfo: blurriness, combined
// intensity and the IBL cross-fade blend.
Float32List _skyboxInfoOf(
  EnvironmentSkySource source,
  EnvironmentMap environment,
  double intensity,
  double blend,
) {
  // std140: blurriness/intensity/has_background/source_is_linear fill the first
  // vec4; radiance_blend starts the second, so the block rounds up to 8 floats.
  return Float32List(8)
    ..[0] = source.blurriness
    ..[1] = intensity
    ..[2] = environment.hasBackgroundTexture ? 1.0 : 0.0
    ..[3] = environment.backgroundIsLinear ? 1.0 : 0.0
    ..[4] = blend.clamp(0.0, 1.0);
}

// Binds the built-in environment sky fragment: [skyboxInfo] as SkyboxInfo
// and the prefiltered-radiance atlases (primary plus the secondary
// cross-fade pair).
void _bindEnvironmentSource(
  gpu.RenderPass renderPass,
  TransientWriter transientsBuffer,
  gpu.Shader fragmentShader,
  ByteData skyboxInfo,
  EnvironmentMap environment,
  EnvironmentMap environmentB,
) {
  renderPass.bindUniform(
    fragmentShader.cachedUniformSlot('SkyboxInfo'),
    transientsBuffer.emplace(skyboxInfo),
  );

  // The prefiltered radiance, bound through the shared helper so the sky
  // and reflections sample identically (including the layout flag).
  EngineLightingUniforms.bindPrefilteredRadiance(
    renderPass,
    fragmentShader,
    environment,
    cubeShader: environment.usesCubeRadianceLayout,
  );
  // The secondary cross-fade environment (the `_b` specular pair). The visible
  // sky mixes toward it by radiance_blend, matching the lit IBL cross-fade.
  EngineLightingUniforms.bindSecondaryRadiance(
    renderPass,
    fragmentShader,
    environmentB,
    primary: environment,
  );
  // The full-res source equirect for a sharp background (a dummy when the
  // environment has none; the SkyboxInfo flag gates its use).
  renderPass.bindTexture(
    fragmentShader.cachedUniformSlot('environment_background'),
    environment.backgroundTexture,
    sampler: gpu.SamplerOptions(
      minFilter: gpu.MinMagFilter.linear,
      magFilter: gpu.MinMagFilter.linear,
      widthAddressMode: gpu.SamplerAddressMode.repeat,
      heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
    ),
  );
}
