part of '_gpu.dart';

// How many turns of view-block storage a pass index rotates through, so a
// block a frame wrote is not overwritten while the GPU still reads it. Matches
// the frames `fg.HostBuffer` rotates.
const int _itemViewTurns = 4;

// The fixed-function state a draw holds on Impeller, where the render pipeline
// bakes none of it and the pass keeps it until a setter changes it. A kept item
// carries the state its recorded draw was made in, and a pass replaying items
// restores the state it stood in afterwards.
final class _ItemDrawState {
  bool depthWrite = false;
  CompareFunction depthCompare = CompareFunction.always;
  CullMode cull = CullMode.none;
  WindingOrder winding = WindingOrder.clockwise;
  PrimitiveType primitive = PrimitiveType.triangle;
  PolygonMode polygon = PolygonMode.fill;
  int stencilReference = 0;
  StencilConfig? front;
  StencilConfig? back;
  List<bool>? blends;
  List<ColorBlendEquation?>? equations;

  void setBlend(int index, bool enable) {
    final blends = this.blends ??= [];
    while (blends.length <= index) {
      blends.add(false);
    }
    blends[index] = enable;
  }

  // A caller may reuse and rewrite the equation and stencil objects it
  // states, so what the pass keeps is a copy of their fields.
  void setEquation(int index, ColorBlendEquation equation) {
    final equations = this.equations ??= [];
    while (equations.length <= index) {
      equations.add(null);
    }
    equations[index] = ColorBlendEquation(
      colorBlendOperation: equation.colorBlendOperation,
      sourceColorBlendFactor: equation.sourceColorBlendFactor,
      destinationColorBlendFactor: equation.destinationColorBlendFactor,
      alphaBlendOperation: equation.alphaBlendOperation,
      sourceAlphaBlendFactor: equation.sourceAlphaBlendFactor,
      destinationAlphaBlendFactor: equation.destinationAlphaBlendFactor,
    );
  }

  void setStencil(StencilConfig config, StencilFace face) {
    final copy = StencilConfig(
      compareFunction: config.compareFunction,
      stencilFailureOperation: config.stencilFailureOperation,
      depthFailureOperation: config.depthFailureOperation,
      depthStencilPassOperation: config.depthStencilPassOperation,
      readMask: config.readMask,
      writeMask: config.writeMask,
    );
    if (face != StencilFace.back) front = copy;
    if (face != StencilFace.front) back = copy;
  }

  bool blendAt(int index) =>
      index < (blends?.length ?? 0) ? blends![index] : false;

  ColorBlendEquation? equationAt(int index) =>
      index < (equations?.length ?? 0) ? equations![index] : null;

  _ItemDrawState copy() {
    final copy = _ItemDrawState()
      ..depthWrite = depthWrite
      ..depthCompare = depthCompare
      ..cull = cull
      ..winding = winding
      ..primitive = primitive
      ..polygon = polygon
      ..stencilReference = stencilReference
      ..front = front
      ..back = back;
    final blends = this.blends;
    if (blends != null) copy.blends = [...blends];
    final equations = this.equations;
    if (equations != null) copy.equations = [...equations];
    return copy;
  }

  // Sets on [pass] what this state holds and [live] does not, and brings
  // [live] up to date. A blend equation this state never set is left as it
  // stands, since only a draw that blends reads one and the engine states an
  // equation whenever it turns blending on.
  void applyOnto(fg.RenderPass pass, _ItemDrawState live) {
    if (depthWrite != live.depthWrite) {
      pass.setDepthWriteEnable(depthWrite);
      live.depthWrite = depthWrite;
    }
    if (depthCompare != live.depthCompare) {
      pass.setDepthCompareOperation(depthCompare);
      live.depthCompare = depthCompare;
    }
    if (cull != live.cull) {
      pass.setCullMode(cull);
      live.cull = cull;
    }
    if (winding != live.winding) {
      pass.setWindingOrder(winding);
      live.winding = winding;
    }
    if (primitive != live.primitive) {
      pass.setPrimitiveType(primitive);
      live.primitive = primitive;
    }
    if (polygon != live.polygon) {
      pass.setPolygonMode(polygon);
      live.polygon = polygon;
    }
    if (stencilReference != live.stencilReference) {
      pass.setStencilReference(stencilReference);
      live.stencilReference = stencilReference;
    }
    _applyStencil(pass, live);
    _applyBlend(pass, live);
  }

  void _applyStencil(fg.RenderPass pass, _ItemDrawState live) {
    final front = this.front;
    final back = this.back;
    if (_sameStencil(front, live.front) && _sameStencil(back, live.back)) {
      return;
    }
    if (_sameStencil(front, back)) {
      pass.setStencilConfig(front ?? _defaultStencil);
    } else {
      pass.setStencilConfig(
        front ?? _defaultStencil,
        targetFace: StencilFace.front,
      );
      pass.setStencilConfig(
        back ?? _defaultStencil,
        targetFace: StencilFace.back,
      );
    }
    live
      ..front = front
      ..back = back;
  }

  void _applyBlend(fg.RenderPass pass, _ItemDrawState live) {
    final blends = this.blends;
    final equations = this.equations;
    final count = [
      blends?.length ?? 0,
      equations?.length ?? 0,
      live.blends?.length ?? 0,
      live.equations?.length ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    for (var index = 0; index < count; index++) {
      final enable = blendAt(index);
      if (enable != live.blendAt(index)) {
        pass.setColorBlendEnable(enable, colorAttachmentIndex: index);
        live.setBlend(index, enable);
      }
      final equation = equationAt(index);
      if (equation != null &&
          !_sameEquation(equation, live.equationAt(index))) {
        pass.setColorBlendEquation(equation, colorAttachmentIndex: index);
        live.setEquation(index, equation);
      }
    }
  }

  static bool _sameStencil(StencilConfig? a, StencilConfig? b) {
    a ??= _defaultStencil;
    b ??= _defaultStencil;
    return a.compareFunction == b.compareFunction &&
        a.stencilFailureOperation == b.stencilFailureOperation &&
        a.depthFailureOperation == b.depthFailureOperation &&
        a.depthStencilPassOperation == b.depthStencilPassOperation &&
        a.readMask == b.readMask &&
        a.writeMask == b.writeMask;
  }

  static bool _sameEquation(ColorBlendEquation a, ColorBlendEquation? b) =>
      b != null &&
      a.colorBlendOperation == b.colorBlendOperation &&
      a.sourceColorBlendFactor == b.sourceColorBlendFactor &&
      a.destinationColorBlendFactor == b.destinationColorBlendFactor &&
      a.alphaBlendOperation == b.alphaBlendOperation &&
      a.sourceAlphaBlendFactor == b.sourceAlphaBlendFactor &&
      a.destinationAlphaBlendFactor == b.destinationAlphaBlendFactor;
}

final StencilConfig _defaultStencil = StencilConfig();

// One kept draw, resolved to the flutter_gpu objects a replay binds.
final class _ItemDraw {
  _ItemDraw({
    required this.pipeline,
    required this.vertices,
    required this.index,
    required this.indexType,
    required this.uniforms,
    required this.viewUniforms,
    required this.textures,
    required this.viewTextures,
    required this.count,
    required this.instanceCount,
    required this.indexed,
    required this.state,
  });

  final fg.RenderPipeline pipeline;
  final List<(int, fg.BufferView)> vertices;
  final fg.BufferView? index;
  final IndexType indexType;
  final List<(fg.UniformSlot, fg.BufferView)> uniforms;
  final List<(fg.UniformSlot, int)> viewUniforms;
  final List<(fg.UniformSlot, fg.Texture, SamplerOptions)> textures;
  final List<(fg.UniformSlot, int, SamplerOptions)> viewTextures;
  final int count;
  final int instanceCount;
  final bool indexed;
  final _ItemDrawState state;

  int passes = 0;
  Float32List? bounds;
}

// The pass an [ItemSet] hands out to record draws on Impeller: it binds
// nothing on the device and resolves the one draw it recorded into an
// [_ItemDraw] the set keeps.
final class _ItemRecorder {
  _ItemRecorder(this._viewBlockNames, this._viewTextureNames);

  final List<String> _viewBlockNames;
  final List<String> _viewTextureNames;

  final _ItemDrawState state = _ItemDrawState();

  // The pipeline a draw is recorded with, which `clearBindings` leaves in
  // place as it does on a pass that encodes.
  RenderPipeline? _pipeline;

  final Map<int, BufferView> _vertices = {};
  BufferView? _index;
  IndexType _indexType = IndexType.int16;
  final Map<(Shader, String), (UniformSlot, BufferView)> _uniforms = {};
  final Map<(Shader, String), (UniformSlot, Texture, SamplerOptions)>
  _textures = {};

  int _drawn = 0;
  _ItemDraw? _recorded;

  void bindPipeline(RenderPipeline pipeline) => _pipeline = pipeline;

  void bindVertexBuffer(BufferView view, int slot) => _vertices[slot] = view;

  void bindIndexBuffer(BufferView view, IndexType indexType) {
    _index = view;
    _indexType = indexType;
  }

  void bindUniform(UniformSlot slot, BufferView view) =>
      _uniforms[(slot.shader, slot.uniformName)] = (slot, view);

  void bindTexture(UniformSlot slot, Texture texture, SamplerOptions sampler) =>
      _textures[(slot.shader, slot.uniformName)] = (slot, texture, sampler);

  void clearBindings() {
    _vertices.clear();
    _index = null;
    _uniforms.clear();
    _textures.clear();
    _drawn = 0;
    _recorded = null;
  }

  void record(int count, int instanceCount, {required bool indexed}) {
    _drawn++;
    if (_drawn > 1) {
      _recorded = null;
      return;
    }
    final pipeline = _pipeline?._impeller;
    if (pipeline == null) return;
    final uniforms = <(fg.UniformSlot, fg.BufferView)>[];
    final viewUniforms = <(fg.UniformSlot, int)>[];
    for (final (slot, view) in _uniforms.values) {
      final at = _viewBlockNames.indexOf(slot.uniformName);
      if (at < 0) {
        uniforms.add((slot._impeller!, view._impeller!));
      } else {
        viewUniforms.add((slot._impeller!, at));
      }
    }
    final textures = <(fg.UniformSlot, fg.Texture, SamplerOptions)>[];
    final viewTextures = <(fg.UniformSlot, int, SamplerOptions)>[];
    for (final (slot, texture, sampler) in _textures.values) {
      final at = _viewTextureNames.indexOf(slot.uniformName);
      if (at < 0) {
        textures.add((slot._impeller!, texture._impeller!, sampler));
      } else {
        viewTextures.add((slot._impeller!, at, sampler));
      }
    }
    _recorded = _ItemDraw(
      pipeline: pipeline,
      vertices: [
        for (final MapEntry(key: slot, value: view) in _vertices.entries)
          (slot, view._impeller!),
      ],
      index: _index?._impeller,
      indexType: _indexType,
      uniforms: uniforms,
      viewUniforms: viewUniforms,
      textures: textures,
      viewTextures: viewTextures,
      count: count,
      instanceCount: instanceCount,
      indexed: indexed,
      state: state.copy(),
    );
  }

  // The one draw recorded since the last keep, or null when there was none or
  // several.
  _ItemDraw? take() {
    final recorded = _drawn == 1 ? _recorded : null;
    clearBindings();
    return recorded;
  }
}

// The render items of one [ItemSet] on Impeller, kept as resolved draws and
// re-issued into a render pass. Flutter GPU records no render bundles and
// holds no secondary command buffers, so a replay costs the pass calls of
// each item it draws and nothing of the walk that built it.
final class _ItemSet {
  _ItemSet(
    this._context,
    this._viewBlockNames,
    int viewBlockLength,
    this._viewTextureNames,
  ) : _blockStride = _aligned(
        viewBlockLength,
        _context.minimumUniformByteAlignment,
      );

  final fg.GpuContext _context;
  final List<String> _viewBlockNames;
  final List<String> _viewTextureNames;
  final int _blockStride;

  final Map<int, _ItemDraw> _items = {};
  int _lastId = 0;

  // One buffer per pass index, holding [_itemViewTurns] turns of the pass's
  // view blocks, and the views onto each turn.
  final Map<int, fg.DeviceBuffer> _blocks = {};
  final Map<int, List<List<fg.BufferView>>> _blockViews = {};
  final Map<int, int> _turns = {};

  final Float32List _planes = Float32List(24);

  static int _aligned(int size, int alignment) =>
      (size + alignment - 1) ~/ alignment * alignment;

  _ItemRecorder recorder() => _ItemRecorder(_viewBlockNames, _viewTextureNames);

  int? keep(
    _ItemRecorder recorder, {
    required int id,
    required int passes,
    Float32List? bounds,
  }) {
    final draw = recorder.take();
    if (draw == null) {
      if (id != 0) remove(id);
      return null;
    }
    draw
      ..passes = passes
      ..bounds = bounds == null ? null : Float32List.fromList(bounds);
    final at = id != 0 ? id : ++_lastId;
    _items[at] = draw;
    return at;
  }

  void remove(int id) => _items.remove(id);

  void draw(
    fg.RenderPass pass,
    _ItemDrawState live,
    int index, {
    required List<ByteData> viewBlocks,
    required Float32List clip,
    required List<fg.Texture> viewTextures,
  }) {
    if (_items.isEmpty) return;
    final mask = 1 << index;
    final planes = _planesOf(clip);
    List<fg.BufferView>? views;
    _ItemDrawState? saved;
    fg.RenderPipeline? bound;
    for (final draw in _items.values) {
      if (draw.passes & mask == 0) continue;
      final bounds = draw.bounds;
      if (bounds != null && !_inside(planes, bounds)) continue;
      views ??= _viewsOf(index, viewBlocks);
      saved ??= live.copy();
      if (!identical(bound, draw.pipeline)) {
        pass.clearBindings();
        pass.bindPipeline(draw.pipeline);
        bound = draw.pipeline;
      }
      draw.state.applyOnto(pass, live);
      for (final (slot, view) in draw.vertices) {
        pass.bindVertexBuffer(view, slot: slot);
      }
      final indices = draw.index;
      if (indices != null) pass.bindIndexBuffer(indices, draw.indexType);
      for (final (slot, view) in draw.uniforms) {
        pass.bindUniform(slot, view);
      }
      for (final (slot, at) in draw.viewUniforms) {
        if (at < views.length) pass.bindUniform(slot, views[at]);
      }
      for (final (slot, texture, sampler) in draw.textures) {
        pass.bindTexture(slot, texture, sampler: sampler);
      }
      for (final (slot, at, sampler) in draw.viewTextures) {
        if (at < viewTextures.length) {
          pass.bindTexture(slot, viewTextures[at], sampler: sampler);
        }
      }
      if (draw.indexed) {
        pass.drawIndexed(draw.count, instanceCount: draw.instanceCount);
      } else {
        pass.draw(draw.count, instanceCount: draw.instanceCount);
      }
    }
    if (saved == null) return;
    saved.applyOnto(pass, live);
    pass.clearBindings();
  }

  void destroy() {
    _items.clear();
    _blocks.clear();
    _blockViews.clear();
    _turns.clear();
  }

  // Writes [viewBlocks] into this pass index's next turn and returns the
  // views onto it, built once per turn.
  List<fg.BufferView> _viewsOf(int index, List<ByteData> viewBlocks) {
    final count = _viewBlockNames.length;
    var buffer = _blocks[index];
    List<List<fg.BufferView>> turns;
    if (buffer == null) {
      buffer = _context.createDeviceBuffer(
        StorageMode.hostVisible,
        _blockStride * count * _itemViewTurns,
      );
      _blocks[index] = buffer;
      turns = _blockViews[index] = [
        for (var turn = 0; turn < _itemViewTurns; turn++)
          [
            for (var block = 0; block < count; block++)
              fg.BufferView(
                buffer,
                offsetInBytes: (turn * count + block) * _blockStride,
                lengthInBytes: _blockStride,
              ),
          ],
      ];
    } else {
      turns = _blockViews[index]!;
    }
    final turn = ((_turns[index] ?? -1) + 1) % _itemViewTurns;
    _turns[index] = turn;
    final views = turns[turn];
    for (var block = 0; block < count && block < viewBlocks.length; block++) {
      assert(viewBlocks[block].lengthInBytes <= _blockStride);
      buffer.overwrite(
        viewBlocks[block],
        destinationOffsetInBytes: views[block].offsetInBytes,
      );
    }
    return views;
  }

  // The six planes of the volume [clip] maps into clip space, each
  // (a, b, c, d) with a x + b y + c z + d >= 0 inside.
  Float32List _planesOf(Float32List clip) {
    final planes = _planes;
    for (var axis = 0; axis < 4; axis++) {
      final w = clip[axis * 4 + 3];
      final x = clip[axis * 4];
      final y = clip[axis * 4 + 1];
      final z = clip[axis * 4 + 2];
      planes[axis] = w + x;
      planes[4 + axis] = w - x;
      planes[8 + axis] = w + y;
      planes[12 + axis] = w - y;
      planes[16 + axis] = z;
      planes[20 + axis] = w - z;
    }
    return planes;
  }

  static bool _inside(Float32List planes, Float32List bounds) {
    for (var plane = 0; plane < 6; plane++) {
      final a = planes[plane * 4];
      final b = planes[plane * 4 + 1];
      final c = planes[plane * 4 + 2];
      final d = planes[plane * 4 + 3];
      final x = bounds[a >= 0 ? 3 : 0];
      final y = bounds[b >= 0 ? 4 : 1];
      final z = bounds[c >= 0 ? 5 : 2];
      if (a * x + b * y + c * z + d < 0) return false;
    }
    return true;
  }
}
