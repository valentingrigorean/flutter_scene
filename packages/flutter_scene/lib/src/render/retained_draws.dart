/// The draws of a render scene that the GPU backend keeps as render items,
/// which a pass then draws natively instead of encoding each.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/geometry/geometry.dart'
    show UnskinnedGeometry;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/material/engine_lighting.dart';
import 'package:flutter_scene/src/render/mesh_draw_selection.dart';
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';

// The syncs an item that changed in two syncs in a row stays encoded each
// frame before it is kept again.
const int _coolSyncs = 30;

/// What a kept draw was recorded from; a change records it again.
final class _Kept {
  int id = 0;
  int changedAt = -1;
  bool encoded = false;

  Object? material;
  int materialRevision = 0;
  Object? geometry;
  Object? pipeline;
  Object? state;
  int buffers = -1;
  int transform = -1;
  bool flipped = false;
  int primitive = -1;
  final Float32List bounds = Float32List(6);
  bool bounded = false;
}

/// The one item set every kept draw of a [RenderScene] lives in, so the
/// backend holds the scene's shadow casters, depth prepass and color draws
/// in one native view and each pass draws its own pass index of it.
///
/// Pass [casterPass] and the three after it are the directional shadow
/// cascades, [depthPass] the primary view's depth prepass, [colorPass] its
/// color pass, and [translucentPass] onwards the color pass's translucent
/// draws. A walk names the passes in the order they draw, so an index does
/// not order them.
///
/// Each pass states its own view blocks: `ViewInfo` first, then `DepthInfo`
/// for the prepass, or `FragInfo`, `FogInfo` and the app's blocks
/// (`Scene.setViewBlock`) for the color pass and its translucent draws.
final class SceneItems {
  SceneItems._(this.items, this._blocksRevision);

  /// The first of the four shadow cascades' pass indices.
  static const int casterPass = 0;

  /// The depth prepass's pass index.
  static const int depthPass = 4;

  /// The color pass's pass index.
  static const int colorPass = 5;

  /// The first of the color pass's translucent pass indices, one per render
  /// order whose draws it keeps, [translucentPasses] at most.
  static const int translucentPass = 6;

  /// The number of translucent pass indices, up to the 32 a set holds.
  static const int translucentPasses = 32 - translucentPass;

  /// The backend's item set.
  final gpu.ItemSet items;

  final int _blocksRevision;
  final int _generation = gpu.gpuContextGeneration;

  static final Expando<SceneItems> _byScene = Expando('scene items');

  /// The item set of [renderScene], made again when the GPU context is
  /// reopened or the app's view blocks change, or null where the backend
  /// keeps no items. The kept draws of a set that was replaced are dropped
  /// with it.
  static gpu.ItemSet? of(RenderScene renderScene) {
    final held = _byScene[renderScene];
    if (held != null &&
        held._generation == gpu.gpuContextGeneration &&
        held._blocksRevision == renderScene.viewBlocksRevision) {
      return held.items;
    }
    held?.items.dispose();
    _byScene[renderScene] = null;
    final appBlocks = renderScene.viewBlocks.keys;
    final items = gpu.gpuContext.createItemSet(
      viewBlocks: {
        'ViewInfo': 0,
        'DepthInfo': 1,
        'FragInfo': 1,
        'FogInfo': 2,
        for (final (index, name) in appBlocks.indexed) name: 3 + index,
      },
      viewBlockLength:
          EngineLightingUniforms.fragInfoFloatCount *
          Float32List.bytesPerElement,
      viewTextureNames: colorViewTextureNames,
    );
    if (items == null) return null;
    _byScene[renderScene] = SceneItems._(items, renderScene.viewBlocksRevision);
    return items;
  }

  /// The frame-transient engine textures a kept lit color draw samples,
  /// re-supplied each color pass so the backend keeps the draw instead of
  /// refusing it: the directional shadow atlas, ambient occlusion, the two
  /// punctual-light data textures, and the opaque linear depth a
  /// scene-input material samples. Any other transient texture a draw binds
  /// is still refused by the backend.
  static const colorViewTextureNames = [
    'shadow_map',
    'ssao_texture',
    'punctual_lights',
    'punctual_index',
    'scene_depth',
  ];
}

/// The draws one pass makes of a [RenderScene]'s items that the backend
/// keeps as render items ([gpu.ItemSet]), so a frame that moves only the
/// camera encodes none of them.
///
/// A draw is kept when it binds only what its item holds from frame to
/// frame: an unskinned, unmorphed, non-instanced mesh with no turns, level
/// of detail or draw selection, through a position-only depth path whose
/// material has no vertex stage, mask or surface, and whose every block but
/// the pass's own ([gpu.ItemSet.draw]) is held. Each [sync] reads the items
/// the scene logged as joining, leaving or refreshed since the last
/// ([RenderScene.changeLog]), and every item once after the pass's key
/// changed or the log was dropped; it records again only the items whose
/// draw changed. An item that changes in two syncs in a row is encoded each
/// frame like every draw that cannot be kept, until it rests for a while.
/// The pass then draws the kept items natively and encodes [encoded].
abstract base class RetainedDraws {
  /// Keeps the draws of [renderScene] in [items], the scene's
  /// [SceneItems].
  RetainedDraws(this.renderScene, this.items);

  /// The scene whose items are kept.
  final RenderScene renderScene;

  /// The backend's kept items, which every pass of the scene shares.
  final gpu.ItemSet items;

  final Map<RenderItem, _Kept> _kept = Map.identity();

  /// The held-block slots each kept item's draw reads, pinned so they are not
  /// taken back for other values while the backend still draws from them.
  /// Each is an unpin called when the draw is forgotten or re-recorded.
  final Map<RenderItem, List<void Function()>> _pins = Map.identity();

  /// The items the pass encodes each frame: those it draws that cannot be
  /// kept, and those that changed in two syncs in a row.
  final List<RenderItem> encoded = [];

  /// The pass's recorder, current after [sync] began.
  @protected
  late gpu.RenderPass recorder;

  gpu.RenderPass? _recorder;
  Object? _key;
  int _epoch = -1;
  int _read = 0;
  int _syncs = 0;

  /// The passes of [items] a kept draw draws in, one bit each
  /// ([SceneItems]).
  @protected
  int get passes;

  /// The passes of [items] the kept draw of [item] draws in; [passes] for
  /// every item unless a pass splits its draws over several.
  @protected
  int passesOf(RenderItem item) => passes;

  /// Whether the pass's draw of [item] is kept as a render item.
  @protected
  bool keeps(RenderItem item) => (_kept[item]?.id ?? 0) != 0;

  /// Whether the pass draws [item] at all.
  @protected
  bool draws(RenderItem item);

  /// Whether the pass's draw of [item] binds only what [item] holds from
  /// frame to frame, beside the structural checks [sync] makes.
  @protected
  bool keepable(RenderItem item);

  /// The pipeline the pass draws [item] with, or null while it is unbuilt.
  @protected
  Object? pipelineOf(RenderItem item);

  /// The rest of what the pass's draw of [item] depends on that its item
  /// does not count: its cull mode, depth offsets and the like, as one
  /// comparable value.
  @protected
  Object? stateOf(RenderItem item);

  /// Encodes the pass's draw of [item] onto [recorder].
  @protected
  void record(RenderItem item);

  /// Called at the start of each [sync], before any [record].
  @protected
  void beginSync() {}

  /// Forgets what the pass's recording encoder holds of the bindings on
  /// [recorder], which [keep] drops at each kept draw, so the next [record]
  /// binds the full set its item holds instead of skipping a binding it
  /// believes is still there.
  @protected
  void forgetRecorded() {}

  /// The number of draws kept as render items, counted again only after a
  /// sync that changed a kept draw.
  int get keptCount {
    if (_keptCountStale) {
      _keptCountStale = false;
      _keptCount = _kept.values.where((kept) => kept.id != 0).length;
    }
    return _keptCount;
  }

  int _keptCount = 0;
  bool _keptCountStale = false;

  /// Brings the kept draws up to date with the scene for the pass drawing
  /// into [target], whose own settings [key] states.
  void sync({required gpu.RenderTarget target, required Object? key}) {
    _syncs++;
    final scene = renderScene;
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment;
    final fullKey = (
      key,
      [for (final color in colors) color.texture.format],
      (colors.isEmpty ? depth!.texture : colors.first.texture).sampleCount,
      depth?.texture.format,
      scene.drawOrigin.revision,
    );
    final changed = !_sameKey(fullKey, _key);
    if (changed) _recorder = null;
    recorder = _recorder ??= createTrackedRecorder(items, target);
    beginSync();
    final log = scene.changeLog;
    if (changed || _epoch != scene.changeLogEpoch) {
      _key = fullKey;
      _epoch = scene.changeLogEpoch;
      for (final item in [..._kept.keys]) {
        if (item.sceneSlot < 0) _drop(item);
      }
      for (final item in scene.items) {
        _visit(item);
      }
    } else {
      for (var index = _read; index < log.length; index++) {
        final item = log[index];
        if (item.sceneSlot < 0) {
          _drop(item);
        } else {
          _visit(item);
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
      _visit(item);
    }
  }

  static bool _sameKey(
    (Object?, List<gpu.PixelFormat>, int, gpu.PixelFormat?, int) a,
    Object? b,
  ) {
    if (b is! (Object?, List<gpu.PixelFormat>, int, gpu.PixelFormat?, int)) {
      return false;
    }
    if (a.$1 != b.$1 || a.$3 != b.$3 || a.$4 != b.$4 || a.$5 != b.$5) {
      return false;
    }
    if (a.$2.length != b.$2.length) return false;
    for (var index = 0; index < a.$2.length; index++) {
      if (a.$2[index] != b.$2[index]) return false;
    }
    return true;
  }

  void _visit(RenderItem item) {
    _keptCountStale = true;
    final kept = _kept[item] ??= _Kept();
    if (!draws(item)) {
      _forget(item, kept);
      _encode(item, kept, false);
      return;
    }
    if (!_holdsItsBuffers(item) || !keepable(item)) {
      _forget(item, kept);
      _encode(item, kept, true);
      return;
    }
    final pipeline = pipelineOf(item);
    final state = stateOf(item);
    final bounds = item.frustumCulled ? item.worldBounds : null;
    if (kept.id != 0 &&
        identical(kept.material, item.material) &&
        kept.materialRevision == item.material.keptRevision &&
        identical(kept.geometry, item.geometry) &&
        identical(kept.pipeline, pipeline) &&
        kept.state == state &&
        kept.buffers == item.geometry.buffersRevision &&
        kept.transform == item.worldTransformRevision &&
        kept.flipped == item.windingFlipped &&
        kept.primitive == item.geometry.primitiveType.index &&
        _sameBounds(kept, bounds)) {
      return;
    }
    final hot = kept.changedAt >= 0 && _syncs - kept.changedAt <= 1;
    kept
      ..changedAt = _syncs
      ..material = item.material
      ..materialRevision = item.material.keptRevision
      ..geometry = item.geometry
      ..pipeline = pipeline
      ..state = state
      ..buffers = item.geometry.buffersRevision
      ..transform = item.worldTransformRevision
      ..flipped = item.windingFlipped
      ..primitive = item.geometry.primitiveType.index;
    _takeBounds(kept, bounds);
    if (hot || pipeline == null) {
      _forget(item, kept);
      _encode(item, kept, true);
      return;
    }
    forgetRecorded();
    record(item);
    final id = items.keep(
      recorder,
      id: kept.id,
      passes: passesOf(item),
      bounds: bounds == null ? null : kept.bounds,
    );
    _unpin(item, kept);
    if (id == null) {
      kept.id = 0;
      _encode(item, kept, true);
      return;
    }
    kept.id = id;
    pinHeld(item);
    _encode(item, kept, false);
    activeRenderCounters.drawsKept++;
  }

  /// Pins the held-block slots the backend's kept draw of [item] reads, so
  /// they are not handed back for other values while it still draws from
  /// them. The default pins the vertex `ItemInfo`; a pass with held fragment
  /// blocks overrides to pin those too, through [recordPin].
  @protected
  void pinHeld(RenderItem item) {
    final view = item.heldItemInfo.lastBound;
    if (view != null && item.heldItemInfo.pin(view)) {
      recordPin(item, () => item.heldItemInfo.unpin(view));
    }
  }

  /// Registers an [unpin] to run when [item]'s kept draw is forgotten or
  /// re-recorded, for a [pinHeld] override.
  @protected
  void recordPin(RenderItem item, void Function() unpin) {
    (_pins[item] ??= []).add(unpin);
  }

  // Whether [item] draws one mesh from buffers it holds, with no per-frame
  // turns, skin, morph, instances, level of detail or draw selection.
  static bool _holdsItsBuffers(RenderItem item) {
    final geometry = item.geometry;
    return geometry is UnskinnedGeometry &&
        geometry.morphTargets == null &&
        item.jointsTexture == null &&
        item.morphWeights == null &&
        item.instanceTransforms == null &&
        item.sharedRows == null &&
        item.instanceSource == null &&
        item.spin == null &&
        item.lod == null &&
        !hasMeshDrawSelector(item) &&
        geometry.instancedVertexLayout != null &&
        geometry.bindsModelTransformInstance;
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
      items.remove(kept.id);
      kept.id = 0;
    }
    _unpin(item, kept);
  }

  void _unpin(RenderItem item, _Kept kept) {
    final pins = _pins.remove(item);
    if (pins == null) return;
    for (final unpin in pins) {
      unpin();
    }
  }

  void _drop(RenderItem item) {
    final kept = _kept.remove(item);
    if (kept == null) return;
    _keptCountStale = true;
    _forget(item, kept);
    if (kept.encoded) encoded.remove(item);
  }

  /// Forgets every kept draw; the items leave with their [SceneItems] set.
  void dispose() {
    for (final MapEntry(key: item, value: kept) in _kept.entries) {
      _unpin(item, kept);
    }
    _kept.clear();
    _keptCount = 0;
    _keptCountStale = false;
    encoded.clear();
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
