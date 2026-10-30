/// The draws a pass keeps as the items of its pass index in a scene's item
/// set, so a frame that draws the same ones encodes none of them.
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/render/draw_recorder.dart';
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/retained_draws.dart';

/// The kept draw of one pass index of a scene's item set ([SceneItems]): a
/// full-screen pass's, or a custom render pass's
/// (`RenderPassContext.drawKept`).
///
/// The draw is recorded once and kept while its key stays equal: its
/// per-frame values are the pass's view blocks and the targets it samples
/// its view textures ([SceneItems.fullscreenTextureNames]), both re-supplied
/// at each [draw]. A draw the backend refuses to keep (one binding a
/// transient value under a name the set does not give) is encoded by the
/// caller, and recorded again only when its key changes.
final class KeptPassDraw {
  KeptPassDraw._(this._items, this._index);

  final gpu.ItemSet _items;
  final int _index;
  int _id = 0;
  Object? _key;
  bool _refused = false;

  static final Expando<Map<int, KeptPassDraw>> _bySet = Expando(
    'kept pass draw',
  );
  static final Float32List _clip = Float32List(16)
    ..[0] = 1
    ..[5] = 1
    ..[10] = 1
    ..[15] = 1;

  /// A pass's view textures for a full-screen draw sampling [sceneColor],
  /// and [bloom] and [exposureFactor] where it reads them: placeholders for
  /// the color pass's own ([SceneItems.colorViewTextureNames]), then
  /// [SceneItems.fullscreenTextureNames] in order.
  static List<gpu.Texture> viewTextures({
    required gpu.Texture sceneColor,
    gpu.Texture? bloom,
    gpu.Texture? exposureFactor,
  }) {
    final placeholder = Material.getWhitePlaceholderTexture();
    return [
      for (final _ in SceneItems.colorViewTextureNames) placeholder,
      sceneColor,
      bloom ?? placeholder,
      exposureFactor ?? placeholder,
    ];
  }

  /// Removes the items kept at pass [index] of [renderScene]'s item set, for
  /// a pass that gave the index up.
  static void drop(RenderScene renderScene, int index) {
    final items = SceneItems.of(renderScene);
    if (items == null) return;
    final draw = _bySet[items]?.remove(index);
    if (draw != null && draw._id != 0) items.remove(draw._id);
    KeptPassItems._bySet[items]?.remove(index)?._clear();
  }

  /// The kept draw of pass [index] of [renderScene]'s item set, or null where
  /// the backend keeps no items or the frame records its draws for a
  /// capture.
  static KeptPassDraw? of(RenderScene? renderScene, int index) {
    if (renderScene == null || activeDrawRecorder != null) return null;
    final items = SceneItems.of(renderScene);
    if (items == null) return null;
    return (_bySet[items] ??= {})[index] ??= KeptPassDraw._(items, index);
  }

  /// Draws into [pass], whose attachments [target] describes, the one draw
  /// [record] makes on a recorder, keeping it while [key] and the target's
  /// shape stay equal, with [viewBlocks] and [viewTextures] as the pass's
  /// view blocks and view textures. Returns false, drawing nothing, where
  /// the backend refused to keep the draw.
  ///
  /// The draw binds what it draws with on [pass].
  bool draw(
    gpu.RenderPass pass,
    gpu.RenderTarget target, {
    required Object key,
    required void Function(gpu.RenderPass recorder) record,
    required List<ByteData> viewBlocks,
    List<gpu.Texture> viewTextures = const [],
  }) {
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment?.texture;
    final shaped = (
      key,
      colors.length,
      colors.firstOrNull?.texture.format,
      (colors.firstOrNull?.texture ?? depth)?.sampleCount,
      depth?.format,
    );
    if (shaped != _key) {
      _key = shaped;
      final recorder = createTrackedRecorder(_items, target);
      record(recorder);
      final id = _items.keep(recorder, id: _id, passes: 1 << _index);
      _id = id ?? 0;
      _refused = id == null;
    }
    if (_refused) return false;
    _items.draw(
      pass,
      _index,
      viewBlocks: viewBlocks,
      clip: _clip,
      viewTextures: viewTextures,
    );
    return true;
  }
}

/// A draw a pass states for [KeptPassItems.keep]: [record] makes it on the
/// pass it is given, binding all it reads, and is called again only when
/// [key] changes. [key] states everything [record] binds but the pass's view
/// blocks and view textures.
typedef KeptItem = ({Object key, void Function(gpu.RenderPass pass) record});

/// The draws a custom render pass keeps at one pass index of a scene's item
/// set (`RenderPassContext.keptItems`), drawn in the order the pass states
/// them, ahead of any order the backend would pick.
///
/// Each [keep] states the frame's draws; a draw whose key and place in the
/// list match one already kept is kept as it is, the others are recorded,
/// and the kept draws the frame no longer states are removed. A draw the
/// backend refuses to keep (one binding a transient value under a name the
/// set does not give) makes [keep] return false, and the pass encodes the
/// frame's draws itself; a later list of the same keys is not offered again.
final class KeptPassItems {
  KeptPassItems._(this._items, this._index);

  final gpu.ItemSet _items;
  final int _index;
  Map<Object, ({int id, int order})> _held = {};
  final Set<Object> _refused = {};
  Object? _shape;

  static final Expando<Map<int, KeptPassItems>> _bySet = Expando(
    'kept pass items',
  );
  static final Float32List _clip = Float32List(16)
    ..[0] = 1
    ..[5] = 1
    ..[10] = 1
    ..[15] = 1;

  /// The kept draws of pass [index] of [renderScene]'s item set, or null
  /// where the backend keeps no items or the frame records its draws for a
  /// capture.
  static KeptPassItems? of(RenderScene renderScene, int index) {
    if (activeDrawRecorder != null) return null;
    final items = SceneItems.of(renderScene);
    if (items == null) return null;
    return (_bySet[items] ??= {})[index] ??= KeptPassItems._(items, index);
  }

  /// A pass's view textures with [sceneDepth] as its `scene_depth`, and a
  /// placeholder for each other ([SceneItems.colorViewTextureNames], then
  /// [SceneItems.fullscreenTextureNames]).
  static List<gpu.Texture> viewTextures({gpu.Texture? sceneDepth}) {
    final placeholder = Material.getWhitePlaceholderTexture();
    return [
      for (final name in SceneItems.colorViewTextureNames)
        name == 'scene_depth' ? sceneDepth ?? placeholder : placeholder,
      for (final _ in SceneItems.fullscreenTextureNames) placeholder,
    ];
  }

  /// Keeps [draws] as the items of the pass index, in their order, for a pass
  /// whose attachments [target] describes. Returns false, keeping none,
  /// where the backend refused one of them.
  bool keep(gpu.RenderTarget target, List<KeptItem> draws) {
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment?.texture;
    final shape = (
      colors.length,
      colors.firstOrNull?.texture.format,
      (colors.firstOrNull?.texture ?? depth)?.sampleCount,
      depth?.format,
    );
    if (shape != _shape) {
      _clear();
      _shape = shape;
    }
    for (final draw in draws) {
      if (_refused.contains(draw.key)) return false;
    }
    final held = <Object, ({int id, int order})>{};
    gpu.RenderPass? recorder;
    for (final (order, draw) in draws.indexed) {
      final key = held.containsKey(draw.key) ? (draw.key, order) : draw.key;
      final was = _held.remove(key);
      if (was != null && was.order == order) {
        held[key] = was;
        continue;
      }
      recorder ??= createTrackedRecorder(_items, target);
      draw.record(recorder);
      final id = _items.keep(
        recorder,
        id: was?.id ?? 0,
        passes: 1 << _index,
        order: order,
      );
      if (id == null) {
        _refused.add(draw.key);
        _held.addAll(held);
        _clear();
        return false;
      }
      held[key] = (id: id, order: order);
    }
    for (final gone in _held.values) {
      _items.remove(gone.id);
    }
    _held = held;
    _refused.clear();
    return true;
  }

  /// Draws the kept items into [pass] where it stands, with [viewBlocks] and
  /// [viewTextures] as the pass's view blocks and view textures.
  void draw(
    gpu.RenderPass pass, {
    List<ByteData> viewBlocks = const [],
    List<gpu.Texture> viewTextures = const [],
  }) => _items.draw(
    pass,
    _index,
    viewBlocks: viewBlocks,
    clip: _clip,
    viewTextures: viewTextures,
  );

  void _clear() {
    for (final held in _held.values) {
      _items.remove(held.id);
    }
    _held = {};
  }
}
