part of '_gpu.dart';

/// Render items a registered backend keeps from frame to frame and draws
/// inside a render pass, so an unchanged item costs no encoding; made by
/// [GpuContext.createItemSet].
///
/// A draw is recorded on a [recorder] as it would be encoded into a pass,
/// then kept as an item by [keep]. An item draws in every [draw] of a pass
/// it names until it is kept again or removed, with the resources it bound:
/// a change to what it draws keeps it again.
final class ItemSet {
  ItemSet._(this._backend, this._viewBlockName);

  final GpuBackendItemSet _backend;
  final String _viewBlockName;

  /// A pass that records draws for [keep], for attachments shaped like
  /// [target]'s.
  RenderPass recorder(RenderTarget target) {
    final colors = target.colorAttachments;
    final depth = target.depthStencilAttachment;
    return RenderPass._backend(
      _backend.recorder(
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
  int? keep(
    RenderPass recorder, {
    int id = 0,
    required int passes,
    Float32List? bounds,
  }) {
    assert(identical(recorder._records, this));
    if (recorder._readsTransient) {
      recorder._readsTransient = false;
      recorder._backend!.clearBindings();
      if (id != 0) _backend.remove(id);
      return null;
    }
    return _backend.keep(
      recorder._backend!,
      id: id,
      passes: passes,
      bounds: bounds,
    );
  }

  /// Removes item [id].
  void remove(int id) => _backend.remove(id);

  /// Draws the items of pass [index] into [pass] where it stands, with
  /// [viewBlock] as the pass's view block, culled by [clip].
  void draw(
    RenderPass pass,
    int index, {
    required ByteData viewBlock,
    required Float32List clip,
  }) => _backend.draw(pass._backend!, index, viewBlock: viewBlock, clip: clip);

  /// Releases every item.
  void dispose() => _backend.destroy();
}
