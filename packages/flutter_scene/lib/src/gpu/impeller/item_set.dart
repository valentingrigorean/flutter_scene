part of '_gpu.dart';

/// Render items the backend keeps from frame to frame and draws inside a
/// render pass, so an unchanged item costs no encoding; made by
/// [GpuContext.createItemSet].
///
/// A draw is recorded on a [recorder] as it would be encoded into a pass,
/// then kept as an item by [keep]. An item draws in every [draw] of a pass
/// it names until it is kept again or removed, with the resources it bound:
/// a change to what it draws keeps it again.
final class ItemSet {
  ItemSet._(
    GpuBackendItemSet this._backend,
    this._viewBlocks,
    this._viewTextureNames,
  ) : _impeller = null;
  ItemSet._impeller(
    _ItemSet this._impeller,
    this._viewBlocks,
    this._viewTextureNames,
  ) : _backend = null;

  final GpuBackendItemSet? _backend;
  final _ItemSet? _impeller;
  final Map<String, int> _viewBlocks;
  final List<String> _viewTextureNames;

  /// The backend's set, which a backend reaches to draw the items outside a
  /// pass it encodes, such as from a render thread of its own; null on
  /// Impeller, which keeps its items itself.
  GpuBackendItemSet? get backend => _backend;

  /// A pass that records draws for [keep], for attachments shaped like
  /// [target]'s.
  RenderPass recorder(RenderTarget target) {
    final pass = _recorder(target).._records = this;
    assert(() {
      if (debugChecksKeptDraws) RenderPass._logs[pass] = _DrawLog(this);
      return true;
    }());
    return pass;
  }

  RenderPass _recorder(RenderTarget target) {
    final impeller = _impeller;
    if (impeller != null) return RenderPass._recording(impeller.recorder());
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment;
    return RenderPass._backend(
      _backend!.recorder(
        colorFormats: [for (final color in colors) color.texture.format],
        depthStencilFormat: depth?.texture.format,
        sampleCount: (colors.isNotEmpty ? colors.first.texture : depth!.texture)
            .sampleCount,
      ),
    );
  }

  // The draw each item was kept from and its instances and bounds as last
  // placed, in a debug build that checks kept draws.
  static final Expando<Map<int, _DrawLog>> _held = Expando('kept draws');

  /// What item [id] binds as it stands, with the bytes its uniform blocks
  /// hold now, in a debug build that checks kept draws
  /// ([debugChecksKeptDraws]); null otherwise, and for an item kept while
  /// the check was off.
  ///
  /// A caller that takes item [id] as current without keeping it again
  /// reads this, records the draw again and compares it with [recorded]:
  /// the record may write a held block in place, so this is read first.
  KeptDraw? kept(int id) {
    KeptDraw? draw;
    assert(() {
      draw = _held[this]?[id]?.read();
      return true;
    }());
    return draw;
  }

  /// What the one draw [recorder] recorded since its last keep binds, as a
  /// [keep] with the same arguments would keep it, in a debug build that
  /// checks kept draws; null otherwise. The recorder's bindings are cleared
  /// as by [discard].
  KeptDraw? recorded(
    RenderPass recorder, {
    required int passes,
    Float32List? bounds,
    ItemInstances? instances,
    int? order,
  }) {
    KeptDraw? draw;
    assert(() {
      draw = _taken(recorder, passes, bounds, instances, order)?.read();
      return true;
    }());
    discard(recorder);
    return draw;
  }

  _DrawLog? _taken(
    RenderPass recorder,
    int passes,
    Float32List? bounds,
    ItemInstances? instances,
    int? order,
  ) => RenderPass._logs[recorder]?.taken(
    prologue: recorder._prologue,
    transient: recorder._readsTransient,
    passes: passes,
    order: order,
    bounds: bounds,
    instances: instances,
  );

  /// Keeps the one draw [recorder] recorded since its last keep as item
  /// [id] (0: a new one), drawn in the passes of [passes] (bit n: pass n)
  /// and culled by [bounds] (min x, y, z, max x, y, z), and returns its id;
  /// null when it recorded no draw or several, or a draw that reads a
  /// buffer [markTransientBuffer] names, which removes [id].
  ///
  /// With [instances], the item draws as one instanced draw of the instances
  /// a [draw] does not cull, each by its own bounds; [bounds] then holds
  /// them all.
  ///
  /// With [order], a pass draws its items in ascending [order], so a set
  /// that states one for every item draws them in that order, such as paint
  /// order. Among items of one order, or of none, the backend orders those
  /// that blend nothing as it draws them fastest, and keeps an item that
  /// blends where it was kept.
  ///
  /// A draw the recorder recorded with a prologue ([RenderPass.keepPrologue])
  /// draws in the one pass of [passes]; Impeller and a backend that runs no
  /// prologue keep none.
  int? keep(
    RenderPass recorder, {
    int id = 0,
    required int passes,
    Float32List? bounds,
    ItemInstances? instances,
    int? order,
  }) {
    assert(identical(recorder._records, this));
    _DrawLog? draw;
    assert(() {
      draw = _taken(recorder, passes, bounds, instances, order);
      RenderPass._logs[recorder]?.clear();
      return true;
    }());
    final kept = _keep(
      recorder,
      id: id,
      passes: passes,
      bounds: bounds,
      instances: instances,
      order: order,
    );
    assert(() {
      final held = _held[this] ??= {};
      if (kept != id) held.remove(id);
      if (kept != null && draw != null) held[kept] = draw!;
      return true;
    }());
    return kept;
  }

  int? _keep(
    RenderPass recorder, {
    required int id,
    required int passes,
    Float32List? bounds,
    ItemInstances? instances,
    int? order,
  }) {
    final prologue = recorder._prologue;
    recorder._prologue = null;
    final impeller = _impeller;
    if (recorder._readsTransient || (prologue != null && impeller != null)) {
      recorder._readsTransient = false;
      recorder.clearBindings();
      if (id != 0) remove(id);
      return null;
    }
    if (impeller != null) {
      return impeller.keep(
        recorder._recording!,
        id: id,
        passes: passes,
        bounds: bounds,
        instances: instances,
        order: order,
      );
    }
    return _backend!.keep(
      recorder._backend!,
      id: id,
      passes: passes,
      bounds: bounds,
      instances: instances,
      order: order,
      prologue: prologue == null
          ? null
          : GpuBackendItemPrologue([
              for (final dispatch in prologue.dispatches) dispatch._backend,
            ], watchedBytes: prologue.watchedBytes),
    );
  }

  /// Drops the draws [recorder] recorded since its last keep without keeping
  /// them.
  void discard(RenderPass recorder) {
    assert(identical(recorder._records, this));
    recorder._readsTransient = false;
    recorder.clearBindings();
  }

  /// Replaces the records and [bounds] of item [id], kept with instances of
  /// the same slot, stride and count, each culled by its own bounds where it
  /// was kept so, without recording its draw again: a kept draw that only
  /// moved draws from where it now stands. Returns false, changing nothing,
  /// where [id] was kept otherwise.
  bool place(int id, {Float32List? bounds, required ItemInstances instances}) {
    final placed =
        _impeller?.place(id, bounds: bounds, instances: instances) ??
        _backend!.place(id, bounds: bounds, instances: instances);
    assert(() {
      if (placed) _held[this]?[id]?.place(bounds, instances);
      return true;
    }());
    return placed;
  }

  /// Removes item [id].
  void remove(int id) {
    assert(() {
      _held[this]?.remove(id);
      return true;
    }());
    final impeller = _impeller;
    if (impeller != null) {
      impeller.remove(id);
      return;
    }
    _backend!.remove(id);
  }

  /// Draws the items of pass [index] into [pass] where it stands, under its
  /// viewport and scissor and leaving its fixed-function state as it stood,
  /// with [viewBlocks] as the pass's view blocks and [viewTextures] as its
  /// view textures, each at the index [GpuContext.createItemSet] gave it,
  /// culled by [clip] and drawn in the order [sort] names.
  ///
  /// The items bind what they draw with on [pass], so the caller binds its
  /// own pipeline and blocks again for the draws it encodes afterwards.
  void draw(
    RenderPass pass,
    int index, {
    required List<ByteData> viewBlocks,
    required Float32List clip,
    List<Texture> viewTextures = const [],
    ItemSort sort = ItemSort.key,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.draw(
        pass._impeller!,
        pass._commands!,
        pass._state!,
        index,
        viewBlocks: viewBlocks,
        clip: clip,
        viewTextures: [for (final texture in viewTextures) texture._impeller!],
        sort: sort,
      );
      return;
    }
    _backend!.draw(
      pass._backend!,
      index,
      viewBlocks: viewBlocks,
      clip: clip,
      viewTextures: [for (final texture in viewTextures) texture._backend!],
      sort: sort,
    );
  }

  /// Releases every item.
  void dispose() {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.destroy();
      return;
    }
    _backend!.destroy();
  }
}

// What the draws of a recorder bind, and once kept the passes, order, bounds
// and instances their item was kept or placed with.
final class _DrawLog {
  _DrawLog(this._set);

  final ItemSet _set;
  final _ItemDrawState state = _ItemDrawState();
  RenderPipeline? pipeline;
  final Map<int, BufferView> vertices = {};
  (BufferView, IndexType)? indices;
  final Map<(Shader, String), BufferView> blocks = {};
  final Map<(Shader, String), (Texture, SamplerOptions)> textures = {};
  List<Object?>? call;
  int draws = 0;

  Map<String, Object?> _state = const {};
  ItemPrologue? _prologue;
  bool _transient = false;
  int _passes = 0;
  int? _order;
  Float32List? _bounds;
  ItemInstances? _instances;

  void draw(List<Object?> call) {
    draws++;
    this.call = call;
  }

  // The pipeline and the fixed-function state hold from draw to draw, as on
  // a pass.
  void clear() {
    vertices.clear();
    indices = null;
    blocks.clear();
    textures.clear();
    call = null;
    draws = 0;
  }

  _DrawLog taken({
    required ItemPrologue? prologue,
    required bool transient,
    required int passes,
    required int? order,
    required Float32List? bounds,
    required ItemInstances? instances,
  }) => _DrawLog(_set)
    ..pipeline = pipeline
    ..vertices.addAll(vertices)
    ..indices = indices
    ..blocks.addAll(blocks)
    ..textures.addAll(textures)
    ..call = draws == 1 ? call : null
    .._state = state.values()
    .._prologue = prologue
    .._transient = transient
    .._passes = passes
    .._order = order
    ..place(bounds, instances);

  void place(Float32List? bounds, ItemInstances? instances) {
    final each = instances?.bounds;
    _bounds = bounds == null ? null : Float32List.fromList(bounds);
    _instances = instances == null
        ? null
        : ItemInstances(
            slot: instances.slot,
            stride: instances.stride,
            records: Uint8List.fromList(instances.records),
            bounds: each == null ? null : Float32List.fromList(each),
          );
  }

  // The draw with the bytes its blocks hold now; a view block and a view
  // texture are the pass's, so they hold none.
  KeptDraw read() {
    return KeptDraw(
      pipeline: pipeline,
      state: _state,
      call: call,
      vertices: {
        for (final MapEntry(key: slot, value: view) in vertices.entries)
          slot: [view.buffer, view.offsetInBytes, view.lengthInBytes],
      },
      indices: switch (indices) {
        null => null,
        (final view, final type) => [
          view.buffer,
          view.offsetInBytes,
          view.lengthInBytes,
          type,
        ],
      },
      blocks: {
        for (final MapEntry(:key, value: view) in blocks.entries)
          key: _set._viewBlocks.containsKey(key.$2)
              ? null
              : DeviceBuffer._mirrored(view),
      },
      textures: {
        for (final MapEntry(:key, value: (texture, sampler))
            in textures.entries)
          key: [
            _set._viewTextureNames.contains(key.$2) ? null : texture,
            sampler.minFilter,
            sampler.magFilter,
            sampler.mipFilter,
            sampler.widthAddressMode,
            sampler.heightAddressMode,
            sampler.maxAnisotropy,
          ],
      },
      prologue: _prologue,
      transient: _transient,
      passes: _passes,
      order: _order,
      bounds: _bounds,
      instances: _instances,
    );
  }
}
