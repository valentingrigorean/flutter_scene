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
    final impeller = _impeller;
    if (impeller != null) {
      return RenderPass._recording(impeller.recorder()).._records = this;
    }
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment;
    return RenderPass._backend(
      _backend!.recorder(
        colorFormats: [for (final color in colors) color.texture.format],
        depthStencilFormat: depth?.texture.format,
        sampleCount: (colors.isNotEmpty ? colors.first.texture : depth!.texture)
            .sampleCount,
      ),
    ).._records = this;
  }

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
  /// order. Without it the backend orders a pass's items as it draws them
  /// fastest.
  int? keep(
    RenderPass recorder, {
    int id = 0,
    required int passes,
    Float32List? bounds,
    ItemInstances? instances,
    int? order,
  }) {
    assert(identical(recorder._records, this));
    if (recorder._readsTransient) {
      recorder._readsTransient = false;
      recorder.clearBindings();
      if (id != 0) remove(id);
      return null;
    }
    final impeller = _impeller;
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
    );
  }

  /// Drops the draws [recorder] recorded since its last keep without keeping
  /// them.
  void discard(RenderPass recorder) {
    assert(identical(recorder._records, this));
    recorder._readsTransient = false;
    recorder.clearBindings();
  }

  /// Removes item [id].
  void remove(int id) {
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
