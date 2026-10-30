/// Full-screen draws a pass keeps as the one item of its pass index in a
/// scene's item set, so a frame that draws the same one encodes none of it.
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/render/draw_recorder.dart';
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/retained_draws.dart';

/// The kept full-screen draw of one pass index of a scene's item set
/// ([SceneItems]).
///
/// The draw is recorded once and kept while its key stays equal: its
/// per-frame values are the pass's view blocks and the targets it samples
/// its view textures ([SceneItems.fullscreenTextureNames]), both re-supplied
/// at each [draw]. A draw the backend refuses to keep (one binding a
/// transient value under a name the set does not give) is encoded by the
/// caller, and recorded again only when its key changes.
final class KeptFullscreen {
  KeptFullscreen._(this._items, this._index);

  final gpu.ItemSet _items;
  final int _index;
  int _id = 0;
  Object? _key;
  bool _refused = false;

  static final Expando<Map<int, KeptFullscreen>> _bySet = Expando(
    'kept fullscreen',
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

  /// The kept draw of pass [index] of [renderScene]'s item set, or null where
  /// the backend keeps no items or the frame records its draws for a
  /// capture.
  static KeptFullscreen? of(RenderScene? renderScene, int index) {
    if (renderScene == null || activeDrawRecorder != null) return null;
    final items = SceneItems.of(renderScene);
    if (items == null) return null;
    return (_bySet[items] ??= {})[index] ??= KeptFullscreen._(items, index);
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
