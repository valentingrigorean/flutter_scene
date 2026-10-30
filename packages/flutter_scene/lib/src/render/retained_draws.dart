/// The draws of a render scene that the GPU backend keeps as render items,
/// which a pass then draws natively instead of encoding each.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/geometry/geometry.dart'
    show Geometry, UnskinnedGeometry;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/material/engine_lighting.dart';
import 'package:flutter_scene/src/material/material.dart' show Material;
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/instance_records.dart';
import 'package:flutter_scene/src/render/mesh_draw_selection.dart';
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/view_info.dart';
import 'package:flutter_scene/src/vertex_spin.dart';

// The syncs an item that changed in two syncs in a row stays encoded each
// frame before it is kept again.
const int _coolSyncs = 30;

/// What a kept draw was recorded from; a change records it again.
final class _Kept {
  int id = 0;
  int changedAt = -1;
  bool encoded = false;

  // The level of detail the pass draws ([RetainedDraws.levelOf]).
  int level = RetainedDraws.wholeItem;

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

  // The turns the recorded draw's held `ItemInfo` carries, and the fold of
  // the animation time their phases were written for.
  Object? spin;
  double spinEpoch = 0.0;

  // What the recorded draw read that its transform reaches: the instance
  // record's slot and floats (no slot: it binds none), the model scale and
  // the punctual light slice.
  int slot = -1;
  int floats = 0;
  final Float64List scale = Float64List(3);
  int lightCount = -1;
  int lightOffset = -1;

  // Whether the item moved since it was first kept: a draw kept alone then
  // draws its one instance record from the set ([placed]), which a later move
  // replaces without recording the draw again.
  bool moves = false;
  bool placed = false;

  // The pack of the rows a kept instanced draw holds as its instances
  // ([RenderItem.instanceDataRevision]), and whether they reverse the
  // winding; -1 for a draw of no rows.
  int rows = -1;
  bool rowsFlipped = false;

  // The run the kept draw belongs to, and the translation its instance frame
  // adds (see [_Run]); [origin] is the translation the frame of its recorded
  // draw added.
  _Run? run;
  final Float64List shift = Float64List(3);
  final Float64List origin = Float64List(3);
}

/// Kept draws that differ only in their instance record and their bounds,
/// kept as one item that draws them as instances ([gpu.ItemInstances]).
///
/// Members share the pipeline, material, geometry, pass state and the values
/// of every block their item holds; an anchored member's instance frame may
/// differ from another's by a translation, which its record then carries
/// relative to the frame of [ref], the member nearest the draw origin. A run
/// of one member keeps that member's own item.
final class _Run {
  _Run(this.key);

  final _RunKey key;
  final Set<RenderItem> members = LinkedHashSet.identity();

  // The run's item while it has two members or more, and the member whose
  // draw it was recorded from, with the held blocks that draw reads pinned.
  int id = 0;
  RenderItem? ref;
  List<void Function()>? pins;

  // The translation the instance frame of [ref]'s recorded draw adds, which
  // each record is relative to.
  final Float64List origin = Float64List(3);
}

/// What the members of a [_Run] share.
final class _RunKey {
  _RunKey(this.material, this.geometry, this.pipeline, this.rest, this.values)
    : hashCode = Object.hash(
        identityHashCode(material),
        identityHashCode(geometry),
        identityHashCode(pipeline),
        rest,
        Object.hashAll(values),
      );

  final Object material;
  final Object geometry;
  final Object pipeline;
  final ({
    Object? state,
    bool flipped,
    int primitive,
    int buffers,
    bool bounded,
    int slot,
    int floats,
  })
  rest;
  final Float32List values;

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) {
    if (other is! _RunKey ||
        other.hashCode != hashCode ||
        !identical(other.material, material) ||
        !identical(other.geometry, geometry) ||
        !identical(other.pipeline, pipeline) ||
        other.rest != rest ||
        other.values.length != values.length) {
      return false;
    }
    for (var index = 0; index < values.length; index++) {
      if (other.values[index] != values[index]) return false;
    }
    return true;
  }
}

/// The one item set every kept draw of a [RenderScene] lives in, so the
/// backend holds the scene's shadow casters, depth prepass and color draws
/// in one native view and each pass draws its own pass index of it.
///
/// Pass [casterPass] and the three after it are the directional shadow
/// cascades, [depthPass] the primary view's depth prepass, [colorPass] its
/// color pass, [skyPass] the sky behind it, [resolvePass] the resolve and
/// tone map, [postPass] the anti-aliasing after it, [customPass] and the
/// [customPasses] after it the draws of custom render passes, and
/// [translucentPass] onwards the color pass's translucent draws. A walk names
/// the passes in the order they draw, so an index does not order them.
///
/// Each pass states its own view blocks: `ViewInfo` first, then `DepthInfo`
/// for the prepass, or `FragInfo`, `FogInfo` and the app's blocks
/// (`Scene.setViewBlock`) for the color pass and its translucent draws;
/// `SkyboxFrameInfo` and `SkyboxInfo` for the sky, `ResolveInfo` for the
/// resolve, `FxaaInfo` for the anti-aliasing, and a custom render pass's
/// `CustomRenderPass.keptViewBlocks` for its draw.
final class SceneItems {
  SceneItems._(this.items, this._blocksRevision);

  /// The first of the four shadow cascades' pass indices.
  static const int casterPass = 0;

  /// The depth prepass's pass index.
  static const int depthPass = 4;

  /// The color pass's pass index.
  static const int colorPass = 5;

  /// The sky's pass index, drawn in the color pass's render pass.
  static const int skyPass = 6;

  /// The resolve and tone map's pass index.
  static const int resolvePass = 7;

  /// The anti-aliasing pass's index, after the resolve.
  static const int postPass = 8;

  /// The first of the custom render passes' pass indices.
  static const int customPass = 9;

  /// The number of custom render pass indices.
  static const int customPasses = 7;

  /// The first of the color pass's translucent pass indices, one per render
  /// order whose draws it keeps, [translucentPasses] at most.
  static const int translucentPass = customPass + customPasses;

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
        'SkyboxFrameInfo': 0,
        'SkyboxInfo': 1,
        'ResolveInfo': 0,
        'FxaaInfo': 0,
        ...renderScene.passViewBlocks,
      },
      viewBlockLength:
          EngineLightingUniforms.fragInfoFloatCount *
          Float32List.bytesPerElement,
      viewTextureNames: [...colorViewTextureNames, ...fullscreenTextureNames],
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

  /// The frame-transient targets a kept full-screen draw samples, after
  /// [colorViewTextureNames] among a pass's view textures: the scene or
  /// display color it reads, and the bloom and auto exposure the resolve
  /// adds.
  static const fullscreenTextureNames = [
    'scene_color',
    'bloom_color',
    'exposure_factor',
  ];
}

/// The draws one pass makes of a [RenderScene]'s items that the backend
/// keeps as render items ([gpu.ItemSet]), so a frame that moves only the
/// camera encodes none of them.
///
/// A draw is kept when it binds only what its item holds from frame to
/// frame: an unskinned, unmorphed, non-instanced mesh with no draw
/// selection, at one level of detail a pass selects ([levelOf]), through a
/// position-only depth path, or the vertex stage of a geometry that keeps
/// its draw, whose material has no vertex stage, mask or surface, and whose
/// every block but the pass's own ([gpu.ItemSet.draw]) is
/// held. Each [sync] reads the items
/// the scene logged as joining, leaving or refreshed since the last
/// ([RenderScene.changeLog]), and every item once after the pass's key
/// changed or the log was dropped; it records again only the items whose
/// draw changed. An item that only moves, through its instance record, keeps
/// its draw: the set holds that record from its first move, and each move
/// places it again ([gpu.ItemSet.place]) without recording the draw. Any
/// other item that changes in two syncs in a row is encoded each frame like
/// every draw that cannot be kept, until it rests for a while. A mesh that
/// turns ([VertexSpin]) reads the animation time from the pass's view
/// block, so its kept draw holds until the time leaves the fold its phases
/// were written for ([animationTimeEpoch]), and is then recorded again.
/// The pass then draws the kept items natively and encodes [encoded].
///
/// An item with levels of detail is checked each [sync] for the level the
/// pass selects, and recorded again only when that level changed.
///
/// Kept draws that differ only in their instance record and bounds (the
/// same mesh drawn by several nodes) are kept as one item that draws them as
/// instances, culled one by one ([gpu.ItemInstances]), so the pass issues
/// one draw for the run instead of one per member. The item is recorded
/// again only when the run's members change; a member's move places its
/// records again.
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

  final Map<_RunKey, _Run> _runs = {};

  // The items with levels of detail the pass draws, checked each sync for a
  // change of level.
  final Set<RenderItem> _leveled = LinkedHashSet.identity();
  final Set<_Run> _changedRuns = LinkedHashSet.identity();

  // The kept runs a member of moved in this sync.
  final Set<_Run> _movedRuns = LinkedHashSet.identity();

  // The items the pass draws that turn, checked again when the animation
  // time enters a new fold, and the fold of the last sync.
  final Set<RenderItem> _spun = LinkedHashSet.identity();
  double _spinEpoch = 0.0;

  /// The items the pass encodes each frame: those it draws that cannot be
  /// kept, and those that changed in two syncs in a row.
  final List<RenderItem> encoded = [];

  /// Whether the pass's draws for another camera are its kept draws as they
  /// stand ([CameraReplay]): it encodes none, and none draws at a level of
  /// detail the camera selects.
  bool get keepsForAnyCamera => encoded.isEmpty && _leveled.isEmpty;

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

  /// Whether kept draws that differ only in their instance record may join
  /// one run of instances, which draws its members in no particular order.
  @protected
  bool get joinsRuns => true;

  /// Whether the pass keeps a draw of an instanced item that packs its own
  /// rows, as one item that holds every row as an instance culled by its
  /// own bounds ([gpu.ItemInstances]). A change of the rows alone places
  /// them again without recording the draw.
  @protected
  bool get keepsInstances => false;

  /// Whether the pass's draw of [item] is kept as a render item, alone or in
  /// a run.
  @protected
  bool keeps(RenderItem item) {
    final kept = _kept[item];
    return kept != null && (kept.id != 0 || kept.run != null);
  }

  /// Whether the pass draws [item] at all.
  @protected
  bool draws(RenderItem item);

  /// [levelOf] for an item drawn as itself, with no levels of detail.
  static const int wholeItem = -1;

  /// [levelOf] for an item whose levels of detail select none to draw.
  static const int culledLevel = -2;

  /// [levelOf] for an item whose levels of detail the pass does not keep.
  static const int refusedLevel = -3;

  /// The level of detail the pass draws [item] at this sync: the index of
  /// one of its levels, [wholeItem], [culledLevel] or [refusedLevel]. The
  /// default keeps no level of detail.
  @protected
  int levelOf(RenderItem item) => item.lod == null ? wholeItem : refusedLevel;

  /// The geometry the pass draws [item] with, at the level of its last
  /// [levelOf].
  @protected
  Geometry geometryOf(RenderItem item) {
    final level = _kept[item]?.level ?? wholeItem;
    return level >= 0 ? item.lod!.levels[level].geometry : item.geometry;
  }

  /// The material the pass draws [item] with, at the level of its last
  /// [levelOf].
  @protected
  Material materialOf(RenderItem item) {
    final level = _kept[item]?.level ?? wholeItem;
    return level >= 0 ? item.lod!.levels[level].material : item.material;
  }

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

  /// The fragment-stage blocks the pass's draw of [item] reads that [item]
  /// holds for itself, beside its vertex `ItemInfo`; two draws join one run
  /// only where these hold the same values.
  @protected
  Iterable<HeldBlock> heldBlocksOf(RenderItem item) => const [];

  /// Forgets what the pass's recording encoder holds of the bindings on
  /// [recorder], which [keep] drops at each kept draw, so the next [record]
  /// binds the full set its item holds instead of skipping a binding it
  /// believes is still there.
  @protected
  void forgetRecorded() {}

  /// The number of draws kept as render items, alone or in a run, counted
  /// again only after a sync that changed a kept draw.
  int get keptCount {
    if (_keptCountStale) {
      _keptCountStale = false;
      _keptCount = _kept.values
          .where((kept) => kept.id != 0 || kept.run != null)
          .length;
    }
    return _keptCount;
  }

  int _keptCount = 0;
  bool _keptCountStale = false;

  /// The number of items the backend draws for the kept draws: one per draw
  /// kept alone and one per run.
  @visibleForTesting
  int get keptItemCount =>
      _kept.values.where((kept) => kept.id != 0).length +
      _runs.values.where((run) => run.id != 0).length;

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
    final spinEpoch = animationTimeEpoch(currentAnimationTime);
    final newFold = spinEpoch != _spinEpoch;
    _spinEpoch = spinEpoch;
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
    if (_leveled.isNotEmpty) {
      List<(RenderItem, int)>? moved;
      for (final item in _leveled) {
        final level = levelOf(item);
        if (level != _kept[item]!.level) (moved ??= []).add((item, level));
      }
      if (moved != null) {
        for (final (item, level) in moved) {
          _visit(item, level);
        }
      }
    }
    if (newFold) {
      for (final item in [..._spun]) {
        _visit(item);
      }
    }
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
    _keepChangedRuns();
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

  void _visit(RenderItem item, [int? level]) {
    _keptCountStale = true;
    final kept = _kept[item] ??= _Kept();
    if (!draws(item)) {
      _leveled.remove(item);
      _spun.remove(item);
      kept.level = wholeItem;
      _forget(item, kept);
      _encode(item, kept, false);
      return;
    }
    kept.level = level ??= levelOf(item);
    if (item.lod == null) {
      _leveled.remove(item);
    } else {
      _leveled.add(item);
    }
    final spin = item.nodeSpin;
    if (spin == null) {
      _spun.remove(item);
    } else {
      _spun.add(item);
    }
    final spinEpoch = spin == null ? 0.0 : _spinEpoch;
    if (level == culledLevel) {
      _forget(item, kept);
      _encode(item, kept, false);
      return;
    }
    final geometry = geometryOf(item);
    final material = materialOf(item);
    if (level == refusedLevel ||
        !_holdsItsBuffers(item, geometry, keepsInstances) ||
        !keepable(item)) {
      _forget(item, kept);
      _encode(item, kept, true);
      return;
    }
    final pipeline = pipelineOf(item);
    final state = stateOf(item);
    final bounds = item.frustumCulled ? item.worldBounds : null;
    if ((kept.id != 0 || kept.run != null) &&
        identical(kept.material, material) &&
        kept.materialRevision == material.keptRevision &&
        identical(kept.geometry, geometry) &&
        identical(kept.pipeline, pipeline) &&
        kept.state == state &&
        kept.buffers == geometry.buffersRevision &&
        kept.transform == item.worldTransformRevision &&
        kept.flipped == item.windingFlipped &&
        kept.primitive == geometry.primitiveType.index &&
        identical(kept.spin, spin) &&
        kept.spinEpoch == spinEpoch &&
        _sameRows(item, kept) &&
        _sameBounds(kept, bounds)) {
      return;
    }
    if (kept.id != 0 &&
        kept.rows >= 0 &&
        kept.rows != item.instanceDataRevision &&
        _rowsOnly(item, kept, material, geometry, pipeline, state)) {
      kept.rows = item.instanceDataRevision;
      _takeBounds(kept, bounds);
      if (items.place(
        kept.id,
        bounds: kept.bounded ? kept.bounds : null,
        instances: _rowInstances(item, geometry),
      )) {
        return;
      }
    }
    final moved =
        identical(kept.spin, spin) &&
        kept.spinEpoch == spinEpoch &&
        _movedOnly(item, kept, material, geometry, pipeline, state, bounds);
    if (moved) {
      kept.moves = true;
      if ((kept.id != 0 || kept.run != null) && _place(item, kept, bounds)) {
        return;
      }
    }
    final hot = !moved && kept.changedAt >= 0 && _syncs - kept.changedAt <= 1;
    kept
      ..changedAt = _syncs
      ..material = material
      ..materialRevision = material.keptRevision
      ..geometry = geometry
      ..pipeline = pipeline
      ..state = state
      ..buffers = geometry.buffersRevision
      ..transform = item.worldTransformRevision
      ..flipped = item.windingFlipped
      ..primitive = geometry.primitiveType.index
      ..spin = spin
      ..spinEpoch = spinEpoch
      ..rows = item.instanceTransforms == null ? -1 : item.instanceDataRevision
      ..rowsFlipped = _rowsFlipped(item);
    _takeBounds(kept, bounds);
    if (hot || pipeline == null) {
      _forget(item, kept);
      _encode(item, kept, true);
      return;
    }
    forgetRecorded();
    heldInstanceBinding = null;
    recordKeptDraw(() => record(item));
    _takeRecorded(item, kept);
    _leaveRun(item, kept);
    final key = joinsRuns ? _runKeyOf(item, kept, pipeline, state) : null;
    heldInstanceBinding = null;
    final run = key == null ? null : _runs[key];
    if (run != null && run.members.isNotEmpty) {
      // It joins a run: the run's item is recorded again once this sync ends.
      items.discard(recorder);
      if (kept.id != 0) items.remove(kept.id);
      kept.id = 0;
      _unpin(item, kept);
      _join(item, kept, run);
      _encode(item, kept, false);
      return;
    }
    final id = _keepLone(item, kept, id: kept.id);
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
    if (key != null) _join(item, kept, _runs[key] ??= _Run(key));
  }

  // Whether the pass's draw of [item] changed only where it stands since it
  // was recorded: its transform and bounds, not its model scale or light
  // slice, through an instance record of a mesh whose bind holds no
  // transform of its own.
  bool _movedOnly(
    RenderItem item,
    _Kept kept,
    Material material,
    Geometry geometry,
    Object? pipeline,
    Object? state,
    Aabb3? bounds,
  ) =>
      kept.slot >= 0 &&
      pipeline != null &&
      !geometry.keepsItsDraw &&
      kept.transform != item.worldTransformRevision &&
      identical(kept.material, material) &&
      kept.materialRevision == material.keptRevision &&
      identical(kept.geometry, geometry) &&
      identical(kept.pipeline, pipeline) &&
      kept.state == state &&
      kept.buffers == geometry.buffersRevision &&
      kept.flipped == item.windingFlipped &&
      kept.primitive == geometry.primitiveType.index &&
      kept.bounded == (bounds != null) &&
      kept.lightCount == item.lightListCount &&
      kept.lightOffset == item.lightListOffset &&
      _sameScale(kept.scale, item.worldTransform);

  // Whether the pass's draw of [item] changed only in the rows it holds as
  // its instances: their records, their count and their bounds.
  bool _rowsOnly(
    RenderItem item,
    _Kept kept,
    Material material,
    Geometry geometry,
    Object? pipeline,
    Object? state,
  ) =>
      kept.placed &&
      pipeline != null &&
      identical(kept.material, material) &&
      kept.materialRevision == material.keptRevision &&
      identical(kept.geometry, geometry) &&
      identical(kept.pipeline, pipeline) &&
      kept.state == state &&
      kept.buffers == geometry.buffersRevision &&
      kept.transform == item.worldTransformRevision &&
      kept.flipped == item.windingFlipped &&
      kept.rowsFlipped == _rowsFlipped(item) &&
      kept.primitive == geometry.primitiveType.index &&
      kept.lightCount == item.lightListCount &&
      kept.lightOffset == item.lightListOffset;

  static bool _sameRows(RenderItem item, _Kept kept) =>
      item.instanceTransforms == null
      ? kept.rows < 0
      : kept.rows == item.instanceDataRevision;

  static bool _rowsFlipped(RenderItem item) {
    final ranges = item.instanceRowRanges;
    return ranges.length == 3 && ranges[2] != 0;
  }

  // Every row of the instanced [item] as the instances of its kept draw of
  // [geometry], each culled by its own bounds where the item culls its rows.
  static gpu.ItemInstances _rowInstances(RenderItem item, Geometry geometry) {
    final floats = item.instanceRecordFloats;
    return gpu.ItemInstances(
      slot: geometry.vertexStreamCount,
      stride: floats * Float32List.bytesPerElement,
      records: Uint8List.sublistView(item.instanceWorldData!),
      bounds: item.cullInstances && item.frustumCulled
          ? item.instanceRowBounds()
          : null,
    );
  }

  // Places the kept draw of [item], which only moved, where it now stands:
  // a lone draw kept with its instance record at once, a run's at the end of
  // the sync. False where it was kept otherwise, to be recorded again.
  bool _place(RenderItem item, _Kept kept, Aabb3? bounds) {
    final run = kept.run;
    final inRun = run != null && run.id != 0;
    if (!inRun && (kept.id == 0 || !kept.placed)) return false;
    kept.transform = item.worldTransformRevision;
    _takeBounds(kept, bounds);
    for (var axis = 0; axis < 3; axis++) {
      kept.shift[axis] = item.drawShift(axis);
    }
    if (inRun) {
      _movedRuns.add(run);
      return true;
    }
    return items.place(
      kept.id,
      bounds: kept.bounded ? kept.bounds : null,
      instances: _loneInstances(item, kept),
    );
  }

  // Takes what the draw of [item] just recorded read that a move reaches.
  void _takeRecorded(RenderItem item, _Kept kept) {
    final binding = heldInstanceBinding;
    kept
      ..slot = binding?.slot ?? -1
      ..floats = binding?.floats ?? 0
      ..lightCount = item.lightListCount
      ..lightOffset = item.lightListOffset;
    _scaleOf(item.worldTransform, kept.scale);
    for (var axis = 0; axis < 3; axis++) {
      kept.origin[axis] = item.drawShift(axis);
    }
  }

  // Keeps the draw [recorder] just recorded of [item] as its own item [id],
  // from its one instance record held by the set once it has moved.
  int? _keepLone(RenderItem item, _Kept kept, {int id = 0}) {
    final instances = item.instanceTransforms != null
        ? _rowInstances(item, geometryOf(item))
        : kept.moves && kept.slot >= 0
        ? _loneInstances(item, kept)
        : null;
    kept.placed = instances != null;
    return items.keep(
      recorder,
      id: id,
      passes: passesOf(item),
      bounds: kept.bounded ? kept.bounds : null,
      instances: instances,
    );
  }

  // The one instance record of [item]'s lone kept draw, relative to the
  // instance frame its recorded draw adds.
  static gpu.ItemInstances _loneInstances(RenderItem item, _Kept kept) {
    final record = packSingleInstanceData(
      item.worldTransform,
      attributeFloats: kept.floats - kInstanceRecordFloats,
    );
    for (var axis = 0; axis < 3; axis++) {
      final delta = item.drawShift(axis) - kept.origin[axis];
      if (delta != 0) record[12 + axis] += delta;
    }
    return gpu.ItemInstances(
      slot: kept.slot,
      stride: kept.floats * Float32List.bytesPerElement,
      records: Uint8List.fromList(Uint8List.sublistView(record)),
    );
  }

  static void _scaleOf(Matrix4 transform, Float64List scale) {
    final s = transform.storage;
    for (var axis = 0; axis < 3; axis++) {
      final at = axis * 4;
      scale[axis] = math.sqrt(
        s[at] * s[at] + s[at + 1] * s[at + 1] + s[at + 2] * s[at + 2],
      );
    }
  }

  // Whether [transform] scales as [scale] does, to the rounding a rotation
  // leaves in its basis lengths.
  static bool _sameScale(Float64List scale, Matrix4 transform) {
    final s = transform.storage;
    for (var axis = 0; axis < 3; axis++) {
      final at = axis * 4;
      final length = math.sqrt(
        s[at] * s[at] + s[at + 1] * s[at + 1] + s[at + 2] * s[at + 2],
      );
      if ((length - scale[axis]).abs() > 1e-6 * scale[axis]) return false;
    }
    return true;
  }

  // The key of the run the draw of [item] just recorded may join, with
  // [kept]'s shift set, or null when it binds no held instance record or
  // a held block whose values it cannot tell.
  _RunKey? _runKeyOf(
    RenderItem item,
    _Kept kept,
    Object pipeline,
    Object? state,
  ) {
    final stream = heldInstanceBinding;
    heldInstanceBinding = null;
    final info = item.heldItemInfo.lastBound;
    if (stream == null || info == null) return null;
    final vertex = item.heldItemInfo.drawValuesOf(info);
    if (vertex == null) return null;
    final blocks = [...heldBlocksOf(item)];
    final values = <double>[...vertex];
    for (final block in blocks) {
      final view = block.lastBound;
      final held = view == null ? null : block.valuesOf(view);
      if (held == null) return null;
      values.addAll(held);
    }
    // An instance frame that only translates (an anchored item's) may
    // differ between members: the translation moves into each record.
    const frame = 6;
    final shift = kept.shift..fillRange(0, 3, 0.0);
    if (_translatesOnly(vertex, frame)) {
      for (var axis = 0; axis < 3; axis++) {
        shift[axis] = vertex[frame + 12 + axis];
        values[frame + 12 + axis] = 0.0;
      }
    }
    final geometry = geometryOf(item);
    return _RunKey(materialOf(item), geometry, pipeline, (
      state: state,
      flipped: item.windingFlipped,
      primitive: geometry.primitiveType.index,
      buffers: geometry.buffersRevision,
      bounded: kept.bounded,
      slot: stream.slot,
      floats: stream.floats,
    ), Float32List.fromList(values));
  }

  static bool _translatesOnly(Float32List values, int at) {
    for (var index = 0; index < 12; index++) {
      if (values[at + index] != (index % 5 == 0 ? 1.0 : 0.0)) return false;
    }
    return values[at + 15] == 1.0;
  }

  void _join(RenderItem item, _Kept kept, _Run run) {
    run.members.add(item);
    kept.run = run;
    if (run.members.length > 1) _changedRuns.add(run);
  }

  void _leaveRun(RenderItem item, _Kept kept) {
    final run = kept.run;
    if (run == null) return;
    kept.run = null;
    run.members.remove(item);
    _changedRuns.add(run);
  }

  // Keeps each run whose members changed in this sync again: a run of two
  // or more as one item of instances, a run of one as its member's own
  // item, and an empty run not at all.
  // A run whose members only moved has its records placed instead.
  void _keepChangedRuns() {
    if (_movedRuns.isNotEmpty) {
      for (final run in _movedRuns) {
        if (!_changedRuns.contains(run) && run.id != 0) _placeRun(run);
      }
      _movedRuns.clear();
    }
    if (_changedRuns.isEmpty) return;
    _keptCountStale = true;
    final changed = [..._changedRuns];
    _changedRuns.clear();
    for (final run in changed) {
      _unpinRun(run);
      final members = run.members;
      if (members.length < 2) {
        if (run.id != 0) items.remove(run.id);
        run.id = 0;
        if (members.isEmpty) {
          if (identical(_runs[run.key], run)) _runs.remove(run.key);
          continue;
        }
        final item = members.first;
        final kept = _kept[item]!;
        if (kept.id == 0) _keepAlone(run, item, kept);
        continue;
      }
      _keepRun(run);
    }
  }

  // Keeps the lone member of a run as its own item again.
  void _keepAlone(_Run run, RenderItem item, _Kept kept) {
    forgetRecorded();
    heldInstanceBinding = null;
    recordKeptDraw(() => record(item));
    _takeRecorded(item, kept);
    heldInstanceBinding = null;
    final id = _keepLone(item, kept);
    if (id == null) {
      kept.run = null;
      run.members.clear();
      _runs.remove(run.key);
      _encode(item, kept, true);
      return;
    }
    kept.id = id;
    pinHeld(item);
    activeRenderCounters.drawsKept++;
  }

  void _keepRun(_Run run) {
    final members = run.members;
    RenderItem? ref;
    var nearest = double.infinity;
    for (final item in members) {
      final kept = _kept[item]!;
      if (kept.id != 0) {
        items.remove(kept.id);
        kept.id = 0;
        _unpin(item, kept);
      }
      final shift = kept.shift;
      final reach =
          shift[0] * shift[0] + shift[1] * shift[1] + shift[2] * shift[2];
      if (reach < nearest) {
        nearest = reach;
        ref = item;
      }
    }
    ref!;
    run.origin.setAll(0, _kept[ref]!.shift);
    final (instances, all) = _runInstances(run);
    forgetRecorded();
    recordKeptDraw(() => record(ref!));
    final id = items.keep(
      recorder,
      id: run.id,
      passes: passes,
      bounds: all,
      instances: instances,
    );
    if (id == null) {
      // The backend refused the run's draw: every member is encoded.
      run.id = 0;
      for (final item in [...members]) {
        final kept = _kept[item]!;
        kept.run = null;
        _encode(item, kept, true);
      }
      members.clear();
      if (identical(_runs[run.key], run)) _runs.remove(run.key);
      return;
    }
    run
      ..id = id
      ..ref = ref;
    pinHeld(ref);
    run.pins = _pins.remove(ref);
    activeRenderCounters.drawsKept++;
  }

  // Places the records of a kept run whose members only moved, or keeps it
  // again where the backend cannot.
  void _placeRun(_Run run) {
    final (instances, all) = _runInstances(run);
    if (items.place(run.id, bounds: all, instances: instances)) return;
    _unpinRun(run);
    _keepRun(run);
  }

  // The instance records of [run]'s members, relative to the instance frame
  // of its reference draw, with each member's bounds and the bounds of all.
  (gpu.ItemInstances, Float32List?) _runInstances(_Run run) {
    final members = run.members;
    final origin = run.origin;
    final floats = run.key.rest.floats;
    final count = members.length;
    final records = Float32List(count * floats);
    final bounded = run.key.rest.bounded;
    final each = bounded ? Float32List(count * 6) : null;
    final all = bounded ? Float32List(6) : null;
    var at = 0;
    for (final item in members) {
      final kept = _kept[item]!;
      final record = at * floats;
      records.setAll(
        record,
        packSingleInstanceData(
          item.worldTransform,
          attributeFloats: floats - kInstanceRecordFloats,
        ),
      );
      final shift = kept.shift;
      for (var axis = 0; axis < 3; axis++) {
        final delta = shift[axis] - origin[axis];
        if (delta != 0) records[record + 12 + axis] += delta;
      }
      if (each != null) {
        final bounds = kept.bounds;
        each.setAll(at * 6, bounds);
        for (var axis = 0; axis < 3; axis++) {
          if (at == 0 || bounds[axis] < all![axis]) all![axis] = bounds[axis];
          if (at == 0 || bounds[axis + 3] > all[axis + 3]) {
            all[axis + 3] = bounds[axis + 3];
          }
        }
      }
      at++;
    }
    return (
      gpu.ItemInstances(
        slot: run.key.rest.slot,
        stride: floats * Float32List.bytesPerElement,
        records: Uint8List.sublistView(records),
        bounds: each,
      ),
      all,
    );
  }

  void _unpinRun(_Run run) {
    final pins = run.pins;
    run
      ..pins = null
      ..ref = null;
    if (pins == null) return;
    for (final unpin in pins) {
      unpin();
    }
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

  // Whether [item] draws one mesh, [geometry], from buffers it holds, or one
  // draw of a geometry that keeps its draw, with no skin, morph, instances or
  // draw selection. A mesh may turn; a geometry that keeps its draw may not.
  // Where [instances], an instanced mesh that packs its own rows in one
  // winding, with no row ranges, local transform, band or turns, holds its
  // buffers too.
  static bool _holdsItsBuffers(
    RenderItem item,
    Geometry geometry,
    bool instances,
  ) {
    if (instances && item.instanceTransforms != null) {
      final source = item.instanceSource;
      return geometry is UnskinnedGeometry &&
          geometry.morphTargets == null &&
          item.jointsTexture == null &&
          item.morphWeights == null &&
          item.sharedRows == null &&
          source?.instanceRanges == null &&
          source?.drawLocal == null &&
          source?.band == null &&
          item.spin == null &&
          item.instanceWorldData != null &&
          item.instanceRowRanges.length == 3 &&
          !hasMeshDrawSelector(item) &&
          geometry.instancedVertexLayout != null &&
          geometry.bindsModelTransformInstance;
    }
    if (geometry.keepsItsDraw) {
      return item.instanceTransforms == null &&
          item.sharedRows == null &&
          item.instanceSource == null &&
          item.spin == null &&
          !hasMeshDrawSelector(item);
    }
    return geometry is UnskinnedGeometry &&
        geometry.morphTargets == null &&
        item.jointsTexture == null &&
        item.morphWeights == null &&
        item.instanceTransforms == null &&
        item.sharedRows == null &&
        item.instanceSource == null &&
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
    _leaveRun(item, kept);
  }

  void _unpin(RenderItem item, _Kept kept) {
    final pins = _pins.remove(item);
    if (pins == null) return;
    for (final unpin in pins) {
      unpin();
    }
  }

  void _drop(RenderItem item) {
    _leveled.remove(item);
    _spun.remove(item);
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
    for (final run in _runs.values) {
      _unpinRun(run);
    }
    _runs.clear();
    _changedRuns.clear();
    _movedRuns.clear();
    _leveled.clear();
    _spun.clear();
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
