/// The directional shadow casters of a render scene that the GPU backend
/// keeps as render items, drawn by each cascade without encoding them.
library;

import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/draw_revision.dart';
import 'package:flutter_scene/src/geometry/geometry.dart'
    show setCurrentViewInstanceBand;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart' show ShadowCasterFaces;
import 'package:flutter_scene/src/render/depth_raster.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/retained_draws.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
import 'package:flutter_scene/src/render/view_info.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show cachedRenderPipeline;

/// The directional shadow casters of one [RenderScene] that the backend
/// keeps as render items ([RetainedDraws]), so a cascade of a frame that
/// moves only the camera or the light encodes none of them. Each cascade
/// draws the kept casters natively, culled by its light-space matrix, with
/// a view block of its own, and encodes [encoded].
final class RetainedShadowCasters extends RetainedDraws {
  RetainedShadowCasters._(super.renderScene, super.items);

  static final Expando<RetainedShadowCasters> _byScene = Expando(
    'retained shadow casters',
  );

  /// The kept casters of [renderScene], or null where the backend keeps no
  /// items.
  static RetainedShadowCasters? of(RenderScene renderScene) {
    final held = _byScene[renderScene];
    if (held != null && held.generation == gpu.gpuContextGeneration) {
      return held;
    }
    held?.dispose();
    final items = gpu.gpuContext.createItemSet(
      viewBlockNames: const ['ViewInfo'],
      viewBlockLength: kViewInfoFloats * Float32List.bytesPerElement,
    );
    if (items == null) return null;
    return _byScene[renderScene] = RetainedShadowCasters._(renderScene, items);
  }

  static final Matrix4 _noLight = Matrix4.identity();
  static final Vector3 _noViewDirection = Vector3.zero();

  ShadowCasterFaces _faces = ShadowCasterFaces.front;
  int _channels = 0xFF;
  late TransientWriter _transients;
  late Vector3 _cameraPosition;
  ShadowEncoder? _encoder;

  // Every cascade a frame names, one bit each.
  @override
  int get passes => 0xF;

  /// Brings the kept casters up to date with the scene for a shadow map
  /// drawn into [target] with [casterFaces] and [casterChannelMask].
  void syncCasters({
    required gpu.RenderTarget target,
    required ShadowCasterFaces casterFaces,
    required int casterChannelMask,
    required TransientWriter transients,
    required Vector3 cameraPosition,
  }) {
    _faces = casterFaces;
    _channels = casterChannelMask;
    _transients = transients;
    _cameraPosition = cameraPosition;
    sync(
      target: target,
      key: (casterFaces, casterChannelMask, sceneDrawRevision),
    );
  }

  @override
  void beginSync() => _encoder = null;

  @override
  void forgetRecorded() => _encoder?.forgetBindings();

  @override
  bool draws(RenderItem item) =>
      shadowCasterDraws(item, ShadowCasterFilter.all, _channels);

  @override
  bool keepable(RenderItem item) {
    final draw = shadowCasterDraw(item.geometry, item.material);
    return draw.positionOnly && !draw.masked && draw.materialVertex == null;
  }

  @override
  Object? pipelineOf(RenderItem item) {
    final inputs = shadowCasterPipelineInputs(item);
    return cachedRenderPipeline(
      inputs.vertexShader,
      inputs.fragmentShader,
      inputs.vertexLayout,
    );
  }

  @override
  Object? stateOf(RenderItem item) {
    final materialCull = item.material.renderCullMode;
    return item.shadowDoubleSided || materialCull == gpu.CullMode.none
        ? gpu.CullMode.none
        : shadowCasterCullMode(item, _faces);
  }

  @override
  void record(RenderItem item) {
    final encoder = _encoder ??= ShadowEncoder(
      recorder,
      _transients,
      _noLight,
      _cameraPosition,
      _faces,
      casterChannelMask: _channels,
    );
    encoder.encodeItem(item);
  }

  /// Draws the kept casters of cascade [cascade] into [pass], with the
  /// cascade's light-space [lightSpaceMatrix] seen from [cameraPosition].
  void draw(
    gpu.RenderPass pass,
    int cascade,
    Matrix4 lightSpaceMatrix,
    Vector3 cameraPosition,
  ) {
    setCurrentViewInstanceBand(cameraPosition, _noViewDirection);
    currentViewForward = null;
    clearCurrentDrawDepthOffset();
    countKeptDraws();
    items.draw(
      pass,
      cascade,
      viewBlocks: [viewInfoBytesOf(lightSpaceMatrix, cameraPosition)],
      clip: lightSpaceMatrix.storage,
    );
  }
}
