/// The directional shadow casters of a render scene that the GPU backend
/// keeps as render items, drawn by each cascade without encoding them.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/draw_revision.dart';
import 'package:flutter_scene/src/geometry/geometry.dart'
    show UnskinnedGeometry, setCurrentViewInstanceBand;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart' show ShadowCasterFaces;
import 'package:flutter_scene/src/render/depth_raster.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/mesh_draw_selection.dart';
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
import 'package:flutter_scene/src/render/view_info.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show cachedRenderPipeline;

// The cascades a kept caster draws in, one bit each; a frame names at most
// four.
const int _cascadePasses = 0xF;

// The syncs an item that changed in two syncs in a row stays encoded each
// frame before it is kept again.
const int _coolSyncs = 30;

/// What a kept caster's draw was recorded from; a change records it again.
final class _Kept {
  int id = 0;
  gpu.BufferView? pinned;
  int changedAt = -1;
  bool encoded = false;

  Object? material;
  Object? geometry;
  Object? pipeline;
  int buffers = -1;
  int transform = -1;
  int cull = -1;
  bool flipped = false;
  int primitive = -1;
  final Float32List bounds = Float32List(6);
  bool bounded = false;
}

/// The directional shadow casters of one [RenderScene] that the backend
/// keeps as render items ([gpu.ItemSet]), so a cascade of a frame that moves
/// only the camera or the light encodes none of them.
///
/// A caster is kept when its draw binds only what it holds from frame to
/// frame: an unskinned, unmorphed, non-instanced mesh with no turns, level
/// of detail or draw selection, drawn through the position-only depth path
/// of an opaque material without a vertex stage or a mask. Each sync reads
/// the items the scene logged as joining, leaving or refreshed since the
/// last ([RenderScene.changeLog]), and every item once after the casters'
/// faces or channels, the shadow target, the draw origin, the scene's draw
/// revision or the GPU context changed; it records again only the items
/// whose draw changed. An item that changes in two syncs in a row is
/// encoded each frame like every caster that cannot be kept, until it rests
/// for a while. Each cascade then draws the kept casters natively, culled
/// by its light-space matrix, and encodes the rest.
final class RetainedShadowCasters {
  RetainedShadowCasters._(this._renderScene, this._items);

  static final Expando<RetainedShadowCasters> _byScene = Expando(
    'retained shadow casters',
  );

  /// The kept casters of [renderScene], or null where the backend keeps no
  /// items.
  static RetainedShadowCasters? of(RenderScene renderScene) {
    final held = _byScene[renderScene];
    if (held != null && held._generation == gpu.gpuContextGeneration) {
      return held;
    }
    held?._items.dispose();
    final items = gpu.gpuContext.createItemSet(
      viewBlockName: 'ViewInfo',
      viewBlockLength: kViewInfoFloats * Float32List.bytesPerElement,
    );
    if (items == null) return null;
    return _byScene[renderScene] = RetainedShadowCasters._(renderScene, items);
  }

  final RenderScene _renderScene;
  final gpu.ItemSet _items;
  final int _generation = gpu.gpuContextGeneration;

  final Map<RenderItem, _Kept> _kept = Map.identity();

  /// The casters each cascade encodes: those that cannot be kept, and those
  /// that changed in two syncs in a row.
  final List<RenderItem> encoded = [];

  gpu.RenderPass? _recorder;
  Object? _key;
  int _epoch = -1;
  int _read = 0;
  int _syncs = 0;

  ShadowEncoder? _encoder;

  static final Matrix4 _noLight = Matrix4.identity();
  static final Vector3 _noViewDirection = Vector3.zero();

  /// The number of casters kept as render items.
  @visibleForTesting
  int get keptCount => _kept.values.where((kept) => kept.id != 0).length;

  /// Brings the kept casters up to date with the scene for a shadow map
  /// drawn into [target] with [casterFaces] and [casterChannelMask].
  void sync({
    required gpu.RenderTarget target,
    required ShadowCasterFaces casterFaces,
    required int casterChannelMask,
    required TransientWriter transients,
    required Vector3 cameraPosition,
  }) {
    _syncs++;
    final scene = _renderScene;
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment;
    final key = (
      casterFaces,
      casterChannelMask,
      colors.isEmpty ? null : colors.first.texture.format,
      colors.isEmpty ? 1 : colors.first.texture.sampleCount,
      depth?.texture.format,
      scene.drawOrigin.revision,
      sceneDrawRevision,
    );
    _encoder = null;
    if (key != _key) {
      _recorder = null;
    }
    final recorder = _recorder ??= createTrackedRecorder(_items, target);
    ShadowEncoder encoder() => _encoder ??= ShadowEncoder(
      recorder,
      transients,
      _noLight,
      cameraPosition,
      casterFaces,
      casterChannelMask: casterChannelMask,
    );
    final log = scene.changeLog;
    if (key != _key || _epoch != scene.changeLogEpoch) {
      _key = key;
      _epoch = scene.changeLogEpoch;
      for (final item in [..._kept.keys]) {
        if (item.sceneSlot < 0) _drop(item);
      }
      for (final item in scene.items) {
        _visit(item, casterChannelMask, casterFaces, encoder);
      }
    } else {
      for (var index = _read; index < log.length; index++) {
        final item = log[index];
        if (item.sceneSlot < 0) {
          _drop(item);
        } else {
          _visit(item, casterChannelMask, casterFaces, encoder);
        }
      }
    }
    _read = log.length;
    for (var index = encoded.length - 1; index >= 0; index--) {
      final item = encoded[index];
      final kept = _kept[item];
      if (kept == null ||
          item.sceneSlot < 0 ||
          kept.changedAt < 0 ||
          _syncs - kept.changedAt <= _coolSyncs) {
        continue;
      }
      kept.changedAt = -1;
      _visit(item, casterChannelMask, casterFaces, encoder);
    }
  }

  /// Draws the kept casters of cascade [cascade] into [pass], which an
  /// encoder of the cascade's light-space [lightSpaceMatrix] draws the rest
  /// of the casters into, from [cameraPosition].
  void draw(
    gpu.RenderPass pass,
    int cascade,
    Matrix4 lightSpaceMatrix,
    Vector3 cameraPosition,
  ) {
    setCurrentViewInstanceBand(cameraPosition, _noViewDirection);
    currentViewForward = null;
    clearCurrentDrawDepthOffset();
    _items.draw(
      pass,
      cascade,
      viewBlock: viewInfoBytesOf(lightSpaceMatrix, cameraPosition),
      clip: lightSpaceMatrix.storage,
    );
  }

  void _visit(
    RenderItem item,
    int casterChannelMask,
    ShadowCasterFaces casterFaces,
    ShadowEncoder Function() encoder,
  ) {
    final kept = _kept[item] ??= _Kept();
    if (!shadowCasterDraws(item, ShadowCasterFilter.all, casterChannelMask)) {
      _forget(item, kept);
      _encode(item, kept, false);
      return;
    }
    if (!_keepable(item)) {
      _forget(item, kept);
      _encode(item, kept, true);
      return;
    }
    final draw = shadowCasterDraw(item.geometry, item.material);
    final inputs = draw.pipelineInputsFor(item);
    final pipeline = cachedRenderPipeline(
      inputs.vertexShader,
      inputs.fragmentShader,
      inputs.vertexLayout,
    );
    final materialCull = item.material.renderCullMode;
    final cull = item.shadowDoubleSided || materialCull == gpu.CullMode.none
        ? gpu.CullMode.none
        : shadowCasterCullMode(item, casterFaces);
    final bounds = item.frustumCulled ? item.worldBounds : null;
    if (kept.id != 0 &&
        identical(kept.material, item.material) &&
        identical(kept.geometry, item.geometry) &&
        identical(kept.pipeline, pipeline) &&
        kept.buffers == item.geometry.buffersRevision &&
        kept.transform == item.worldTransformRevision &&
        kept.cull == cull.index &&
        kept.flipped == item.windingFlipped &&
        kept.primitive == item.geometry.primitiveType.index &&
        _sameBounds(kept, bounds)) {
      return;
    }
    final hot = kept.changedAt >= 0 && _syncs - kept.changedAt <= 1;
    kept
      ..changedAt = _syncs
      ..material = item.material
      ..geometry = item.geometry
      ..pipeline = pipeline
      ..buffers = item.geometry.buffersRevision
      ..transform = item.worldTransformRevision
      ..cull = cull.index
      ..flipped = item.windingFlipped
      ..primitive = item.geometry.primitiveType.index;
    _takeBounds(kept, bounds);
    if (hot || pipeline == null) {
      _forget(item, kept);
      _encode(item, kept, true);
      return;
    }
    encoder().encodeItem(item);
    final id = _items.keep(
      _recorder!,
      id: kept.id,
      passes: _cascadePasses,
      bounds: bounds == null ? null : kept.bounds,
    );
    _unpin(item, kept);
    if (id == null) {
      kept.id = 0;
      _encode(item, kept, true);
      return;
    }
    kept.id = id;
    final view = item.heldItemInfo.lastBound;
    if (view != null && item.heldItemInfo.pin(view)) kept.pinned = view;
    _encode(item, kept, false);
    activeRenderCounters.shadowCastersKept++;
  }

  // Whether [item]'s caster draw binds only what it holds from frame to
  // frame, so the backend can keep it.
  static bool _keepable(RenderItem item) {
    final geometry = item.geometry;
    if (geometry is! UnskinnedGeometry ||
        geometry.morphTargets != null ||
        item.jointsTexture != null ||
        item.morphWeights != null ||
        item.instanceTransforms != null ||
        item.sharedRows != null ||
        item.instanceSource != null ||
        item.spin != null ||
        item.lod != null ||
        hasMeshDrawSelector(item) ||
        geometry.instancedVertexLayout == null ||
        !geometry.bindsModelTransformInstance) {
      return false;
    }
    final draw = shadowCasterDraw(geometry, item.material);
    return draw.positionOnly && !draw.masked && draw.materialVertex == null;
  }

  void _encode(RenderItem item, _Kept kept, bool encodes) {
    if (kept.encoded == encodes) return;
    kept.encoded = encodes;
    if (encodes) {
      encoded.add(item);
    } else {
      encoded.remove(item);
    }
  }

  void _forget(RenderItem item, _Kept kept) {
    if (kept.id != 0) {
      _items.remove(kept.id);
      kept.id = 0;
    }
    _unpin(item, kept);
  }

  void _unpin(RenderItem item, _Kept kept) {
    final pinned = kept.pinned;
    if (pinned == null) return;
    item.heldItemInfo.unpin(pinned);
    kept.pinned = null;
  }

  void _drop(RenderItem item) {
    final kept = _kept.remove(item);
    if (kept == null) return;
    _forget(item, kept);
    if (kept.encoded) encoded.remove(item);
  }

  static bool _sameBounds(_Kept kept, Aabb3? bounds) {
    if (bounds == null) return !kept.bounded;
    if (!kept.bounded) return false;
    final b = kept.bounds;
    final min = bounds.min;
    final max = bounds.max;
    return b[0] == min.x &&
        b[1] == min.y &&
        b[2] == min.z &&
        b[3] == max.x &&
        b[4] == max.y &&
        b[5] == max.z;
  }

  static void _takeBounds(_Kept kept, Aabb3? bounds) {
    kept.bounded = bounds != null;
    if (bounds == null) return;
    kept.bounds
      ..[0] = bounds.min.x
      ..[1] = bounds.min.y
      ..[2] = bounds.min.z
      ..[3] = bounds.max.x
      ..[4] = bounds.max.y
      ..[5] = bounds.max.z;
  }
}
