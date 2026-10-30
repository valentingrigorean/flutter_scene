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
  // The shim's views, which a replay resolves, so a buffer with ordered
  // writes binds the copy current at the replay.
  final List<(int, BufferView)> vertices;
  final BufferView? index;
  final IndexType indexType;
  final List<(fg.UniformSlot, BufferView)> uniforms;
  final List<(fg.UniformSlot, int)> viewUniforms;
  final List<(fg.UniformSlot, fg.Texture, SamplerOptions)> textures;
  final List<(fg.UniformSlot, int, SamplerOptions)> viewTextures;
  final int count;
  final int instanceCount;
  final bool indexed;
  final _ItemDrawState state;

  int passes = 0;
  int? order;
  Float32List? bounds;
  _ItemInstances? instances;

  // What a pass sorts runs of its items that share an order and blend
  // nothing by, so items that share a pipeline and then textures draw next
  // to each other and skip binding them again.
  int pipelineKey = 0;
  List<int> textureKeys = const [];
  bool get blends => state.blends?.contains(true) ?? false;
}

// A kept item's instances ([ItemInstances]): every record on the device, and
// for each pass index the instances its draw last showed.
final class _ItemInstances {
  _ItemInstances(this.slot, this.stride, this.records, this.bounds, this.all);

  final int slot;
  final int stride;
  final Uint8List records;
  final Float32List? bounds;
  final fg.BufferView all;
  final Map<int, _ShownInstances> shown = {};

  int get count => records.lengthInBytes ~/ stride;
}

// The instances one pass index last showed of a kept item, compacted into a
// buffer of [_itemViewTurns] turns, so a draw still on the GPU keeps reading
// the turn it drew with while a later frame shows another subset.
final class _ShownInstances {
  _ShownInstances(this.buffer, int count) : at = Int32List(count);

  final fg.DeviceBuffer buffer;
  final Int32List at;
  int length = -1;
  int turn = -1;
  fg.BufferView? view;

  bool holds(Int32List shown, int length) {
    if (length != this.length) return false;
    for (var index = 0; index < length; index++) {
      if (at[index] != shown[index]) return false;
    }
    return true;
  }
}

// The pass an [ItemSet] hands out to record draws on Impeller: it binds
// nothing on the device and resolves the one draw it recorded into an
// [_ItemDraw] the set keeps.
final class _ItemRecorder {
  _ItemRecorder(this._viewBlocks, this._viewTextureNames);

  final Map<String, int> _viewBlocks;
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
    final uniforms = <(fg.UniformSlot, BufferView)>[];
    final viewUniforms = <(fg.UniformSlot, int)>[];
    for (final (slot, view) in _uniforms.values) {
      final at = _viewBlocks[slot.uniformName];
      if (at == null) {
        uniforms.add((slot._impeller!, view));
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
          (slot, view),
      ],
      index: _index,
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
    this._viewBlocks,
    int viewBlockLength,
    this._viewTextureNames,
  ) : _blockStride = _aligned(
        viewBlockLength,
        _context.minimumUniformByteAlignment,
      );

  final fg.GpuContext _context;
  final Map<String, int> _viewBlocks;
  final List<String> _viewTextureNames;
  final int _blockStride;

  final Map<int, _ItemDraw> _items = {};
  int _lastId = 0;

  // The items in the order a pass draws them, null after a keep or a remove.
  List<_ItemDraw>? _drawOrder;

  // A key per pipeline and texture an item binds, in the order they were
  // first kept, which sorts a pass's unordered items.
  final Expando<int> _keys = Expando();
  int _lastKey = 0;

  // What a [draw] last bound on its pass since it last cleared the bindings,
  // which hold on a flutter_gpu pass from draw to draw: a bind of the same
  // value again is skipped.
  final List<fg.BufferView?> _boundVertices = List.filled(16, null);
  final Map<fg.UniformSlot, fg.BufferView> _boundUniforms = {};
  final Map<fg.UniformSlot, (fg.Texture, SamplerOptions)> _boundTextures = {};

  // One buffer per pass index, holding [_itemViewTurns] turns of the pass's
  // view blocks, and the views onto each turn.
  final Map<int, fg.DeviceBuffer> _blocks = {};
  final Map<int, List<List<fg.BufferView>>> _blockViews = {};
  final Map<int, int> _turns = {};

  // The view blocks each pass index last wrote, so a [draw] given the same
  // ones again reads the turn that holds them and writes nothing.
  final Map<int, List<Uint8List>> _written = {};

  final Float32List _planes = Float32List(24);

  // The instances of the kept item being drawn that its pass shows, and the
  // records they are compacted from on the way to the device.
  Int32List _shown = Int32List(64);
  Float64List _depths = Float64List(64);
  Uint8List _staging = Uint8List(0);

  static int _aligned(int size, int alignment) =>
      (size + alignment - 1) ~/ alignment * alignment;

  _ItemRecorder recorder() => _ItemRecorder(_viewBlocks, _viewTextureNames);

  int? keep(
    _ItemRecorder recorder, {
    required int id,
    required int passes,
    Float32List? bounds,
    ItemInstances? instances,
    int? order,
  }) {
    final draw = recorder.take();
    if (draw == null) {
      if (id != 0) remove(id);
      return null;
    }
    _drawOrder = null;
    draw
      ..passes = passes
      ..order = order
      ..bounds = bounds == null ? null : Float32List.fromList(bounds)
      ..instances = instances == null ? null : _instancesOf(instances)
      ..pipelineKey = _keyOf(draw.pipeline)
      ..textureKeys = [
        for (final (_, texture, _) in draw.textures) _keyOf(texture),
      ];
    final at = id != 0 ? id : ++_lastId;
    _items[at] = draw;
    return at;
  }

  bool place(int id, {Float32List? bounds, required ItemInstances instances}) {
    final draw = _items[id];
    final held = draw?.instances;
    if (draw == null ||
        held == null ||
        held.slot != instances.slot ||
        held.stride != instances.stride ||
        held.count != instances.count ||
        (held.bounds == null) != (instances.bounds == null)) {
      return false;
    }
    // The shown turns carry over, written again on the next draw.
    final placed = _instancesOf(instances);
    for (final MapEntry(key: index, value: shown) in held.shown.entries) {
      placed.shown[index] = shown
        ..length = -1
        ..view = null;
    }
    draw
      ..bounds = bounds == null ? null : Float32List.fromList(bounds)
      ..instances = placed;
    return true;
  }

  void remove(int id) {
    if (_items.remove(id) != null) _drawOrder = null;
  }

  int _keyOf(Object object) => _keys[object] ??= ++_lastKey;

  // Items with an order draw in ascending order, the rest after them, each
  // in the order they were kept. Within a run of items that share an order
  // and blend nothing, the items sort by pipeline and then by the textures
  // they bind; an item that blends keeps its place, so translucent items
  // stay in the order they were given.
  List<_ItemDraw> _ordered() {
    final cached = _drawOrder;
    if (cached != null) return cached;
    final draws = <(_ItemDraw, int)>[];
    var at = 0;
    for (final draw in _items.values) {
      draws.add((draw, at++));
    }
    draws.sort((a, b) {
      final ao = a.$1.order;
      final bo = b.$1.order;
      final by = ao == bo
          ? 0
          : ao == null
          ? 1
          : bo == null
          ? -1
          : ao.compareTo(bo);
      return by != 0 ? by : a.$2.compareTo(b.$2);
    });
    var run = 0;
    for (var end = 0; end <= draws.length; end++) {
      if (end < draws.length &&
          !draws[end].$1.blends &&
          draws[end].$1.order == draws[run].$1.order) {
        continue;
      }
      if (end - run > 1) {
        draws.setRange(run, end, draws.sublist(run, end)..sort(_byBindings));
      }
      run = end < draws.length && draws[end].$1.blends ? end + 1 : end;
    }
    return _drawOrder = [for (final (draw, _) in draws) draw];
  }

  static int _byBindings((_ItemDraw, int) a, (_ItemDraw, int) b) {
    var by = a.$1.pipelineKey.compareTo(b.$1.pipelineKey);
    if (by == 0) by = _compareKeys(a.$1.textureKeys, b.$1.textureKeys);
    return by != 0 ? by : a.$2.compareTo(b.$2);
  }

  static int _compareKeys(List<int> a, List<int> b) {
    final length = a.length < b.length ? a.length : b.length;
    for (var at = 0; at < length; at++) {
      final by = a[at].compareTo(b[at]);
      if (by != 0) return by;
    }
    return a.length.compareTo(b.length);
  }

  _ItemInstances _instancesOf(ItemInstances instances) {
    final records = Uint8List.fromList(instances.records);
    final buffer = _context.createDeviceBufferWithCopy(
      ByteData.sublistView(records),
    );
    final bounds = instances.bounds;
    return _ItemInstances(
      instances.slot,
      instances.stride,
      records,
      bounds == null ? null : Float32List.fromList(bounds),
      fg.BufferView(
        buffer,
        offsetInBytes: 0,
        lengthInBytes: records.lengthInBytes,
      ),
    );
  }

  // The view of the records of [instances] that pass [index] shows, the
  // first [length] of [shown]: every record when none is culled and none is
  // [ordered], else the subset compacted into the pass index's next turn,
  // written only when it differs from the subset the pass index showed last.
  fg.BufferView _shownOf(
    _ItemInstances instances,
    int index,
    Int32List shown,
    int length, {
    required bool ordered,
  }) {
    final count = instances.count;
    if (length == count && !ordered) return instances.all;
    final stride = instances.stride;
    final held = instances.shown[index] ??= _ShownInstances(
      _context.createDeviceBuffer(
        StorageMode.hostVisible,
        stride * count * _itemViewTurns,
      ),
      count,
    );
    final view = held.view;
    if (view != null && held.holds(shown, length)) return view;
    var staging = _staging;
    if (staging.length < length * stride) {
      staging = _staging = Uint8List(length * stride * 2);
    }
    final records = instances.records;
    for (var at = 0; at < length; at++) {
      final from = shown[at] * stride;
      staging.setRange(at * stride, (at + 1) * stride, records, from);
    }
    held
      ..turn = (held.turn + 1) % _itemViewTurns
      ..length = length;
    held.at.setRange(0, length, shown);
    final offset = held.turn * count * stride;
    held.buffer.overwrite(
      ByteData.sublistView(staging, 0, length * stride),
      destinationOffsetInBytes: offset,
    );
    return held.view = fg.BufferView(
      held.buffer,
      offsetInBytes: offset,
      lengthInBytes: length * stride,
    );
  }

  void draw(
    fg.RenderPass pass,
    _ItemDrawState live,
    int index, {
    required List<ByteData> viewBlocks,
    required Float32List clip,
    required List<fg.Texture> viewTextures,
    required ItemSort sort,
  }) {
    if (_items.isEmpty) return;
    final mask = 1 << index;
    final planes = _planesOf(clip);
    List<fg.BufferView>? views;
    _ItemDrawState? saved;
    fg.RenderPipeline? bound;
    fg.BufferView? boundIndex;
    IndexType? boundIndexType;
    for (final draw
        in sort == ItemSort.key
            ? _ordered()
            : _farthestFirst(
                mask,
                clip,
                reversed: sort == ItemSort.farthestFirstReversedDepth,
              )) {
      if (draw.passes & mask == 0) continue;
      final bounds = draw.bounds;
      if (bounds != null && !_inside(planes, bounds, 0)) continue;
      final instances = draw.instances;
      fg.BufferView? shownView;
      var instanceCount = draw.instanceCount;
      if (instances != null) {
        final count = instances.count;
        final each = instances.bounds;
        var shown = _shown;
        if (shown.length < count) shown = _shown = Int32List(count * 2);
        var length = 0;
        for (var at = 0; at < count; at++) {
          if (each == null || _inside(planes, each, at * 6)) {
            shown[length++] = at;
          }
        }
        if (length == 0) continue;
        final ordered = each != null && sort != ItemSort.key;
        if (ordered) {
          _farthestInstancesFirst(
            shown,
            length,
            each,
            clip,
            reversed: sort == ItemSort.farthestFirstReversedDepth,
          );
        }
        shownView = _shownOf(instances, index, shown, length, ordered: ordered);
        instanceCount = length;
      }
      views ??= _viewsOf(index, viewBlocks);
      saved ??= live.copy();
      // A pass keeps one set of bindings for every shader, so another
      // pipeline starts from none, lest a slot the last one bound linger.
      if (!identical(bound, draw.pipeline)) {
        pass.clearBindings();
        pass.bindPipeline(draw.pipeline);
        bound = draw.pipeline;
        _boundVertices.fillRange(0, _boundVertices.length, null);
        boundIndex = null;
        _boundUniforms.clear();
        _boundTextures.clear();
      }
      draw.state.applyOnto(pass, live);
      for (final (slot, view) in draw.vertices) {
        if (shownView != null && slot == instances!.slot) continue;
        _bindVertices(pass, slot, view._impeller!);
      }
      if (shownView != null) _bindVertices(pass, instances!.slot, shownView);
      final indices = draw.index?._impeller;
      if (indices != null &&
          (draw.indexType != boundIndexType ||
              !_sameView(boundIndex, indices))) {
        pass.bindIndexBuffer(indices, draw.indexType);
        boundIndex = indices;
        boundIndexType = draw.indexType;
      }
      for (final (slot, view) in draw.uniforms) {
        _bindUniform(pass, slot, view._impeller!);
      }
      for (final (slot, at) in draw.viewUniforms) {
        if (at < views.length) _bindUniform(pass, slot, views[at]);
      }
      for (final (slot, texture, sampler) in draw.textures) {
        _bindTexture(pass, slot, texture, sampler);
      }
      for (final (slot, at, sampler) in draw.viewTextures) {
        if (at < viewTextures.length) {
          _bindTexture(pass, slot, viewTextures[at], sampler);
        }
      }
      if (draw.indexed) {
        pass.drawIndexed(draw.count, instanceCount: instanceCount);
      } else {
        pass.draw(draw.count, instanceCount: instanceCount);
      }
    }
    if (saved == null) return;
    saved.applyOnto(pass, live);
    pass.clearBindings();
  }

  void _bindVertices(fg.RenderPass pass, int slot, fg.BufferView view) {
    if (slot >= _boundVertices.length) {
      pass.bindVertexBuffer(view, slot: slot);
      return;
    }
    if (_sameView(_boundVertices[slot], view)) return;
    pass.bindVertexBuffer(view, slot: slot);
    _boundVertices[slot] = view;
  }

  void _bindUniform(
    fg.RenderPass pass,
    fg.UniformSlot slot,
    fg.BufferView view,
  ) {
    if (_sameView(_boundUniforms[slot], view)) return;
    pass.bindUniform(slot, view);
    _boundUniforms[slot] = view;
  }

  void _bindTexture(
    fg.RenderPass pass,
    fg.UniformSlot slot,
    fg.Texture texture,
    SamplerOptions sampler,
  ) {
    final bound = _boundTextures[slot];
    if (bound != null &&
        identical(bound.$1, texture) &&
        _sameSampler(bound.$2, sampler)) {
      return;
    }
    pass.bindTexture(slot, texture, sampler: sampler);
    _boundTextures[slot] = (texture, sampler);
  }

  static bool _sameView(fg.BufferView? a, fg.BufferView b) =>
      a != null &&
      (identical(a, b) ||
          identical(a.buffer, b.buffer) &&
              a.offsetInBytes == b.offsetInBytes &&
              a.lengthInBytes == b.lengthInBytes);

  static bool _sameSampler(SamplerOptions a, SamplerOptions b) =>
      identical(a, b) ||
      a.minFilter == b.minFilter &&
          a.magFilter == b.magFilter &&
          a.mipFilter == b.mipFilter &&
          a.widthAddressMode == b.widthAddressMode &&
          a.heightAddressMode == b.heightAddressMode &&
          a.maxAnisotropy == b.maxAnisotropy;

  void destroy() {
    _items.clear();
    _drawOrder = null;
    _blocks.clear();
    _blockViews.clear();
    _turns.clear();
    _written.clear();
    _boundUniforms.clear();
    _boundTextures.clear();
  }

  // Writes [viewBlocks] into this pass index's next turn and returns the
  // views onto it, built once per turn; the views onto the turn that holds
  // them already when the pass index last wrote the same blocks, such as a
  // second draw of the pass in a frame or a frame whose view did not move.
  List<fg.BufferView> _viewsOf(int index, List<ByteData> viewBlocks) {
    final count = _viewBlocks.values.fold(0, (a, b) => a > b ? a : b) + 1;
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
    final blocks = count < viewBlocks.length ? count : viewBlocks.length;
    final written = _written[index];
    final last = _turns[index];
    if (last != null && _holds(written!, viewBlocks, blocks)) {
      return turns[last];
    }
    final turn = ((last ?? -1) + 1) % _itemViewTurns;
    _turns[index] = turn;
    final views = turns[turn];
    for (var block = 0; block < blocks; block++) {
      assert(viewBlocks[block].lengthInBytes <= _blockStride);
      buffer.overwrite(
        viewBlocks[block],
        destinationOffsetInBytes: views[block].offsetInBytes,
      );
    }
    _keepWritten(index, viewBlocks, blocks);
    return views;
  }

  static bool _holds(
    List<Uint8List> written,
    List<ByteData> viewBlocks,
    int blocks,
  ) {
    if (written.length != blocks) return false;
    for (var block = 0; block < blocks; block++) {
      final held = written[block];
      final bytes = Uint8List.sublistView(viewBlocks[block]);
      if (held.length != bytes.length) return false;
      for (var at = 0; at < held.length; at++) {
        if (held[at] != bytes[at]) return false;
      }
    }
    return true;
  }

  // Copies [viewBlocks] as what pass [index] last wrote, into the copies it
  // holds where they fit.
  void _keepWritten(int index, List<ByteData> viewBlocks, int blocks) {
    final written = _written[index] ??= [];
    if (written.length > blocks) written.length = blocks;
    for (var block = 0; block < blocks; block++) {
      final bytes = Uint8List.sublistView(viewBlocks[block]);
      if (block < written.length && written[block].length == bytes.length) {
        written[block].setAll(0, bytes);
      } else if (block < written.length) {
        written[block] = Uint8List.fromList(bytes);
      } else {
        written.add(Uint8List.fromList(bytes));
      }
    }
  }

  // The items of the pass [mask] names, the farthest first by the clip-space
  // w of their bounds' centre, or by its z where every point has one w (an
  // orthographic clip), the lesser z farther with [reversed] depth; an item
  // with no bounds at 0.
  List<_ItemDraw> _farthestFirst(
    int mask,
    Float32List clip, {
    required bool reversed,
  }) {
    final draws = [
      for (final draw in _items.values)
        if (draw.passes & mask != 0)
          (
            draw.bounds == null
                ? 0.0
                : _depthOf(clip, draw.bounds!, 0, reversed: reversed),
            draw,
          ),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final (_, draw) in draws) draw];
  }

  // Orders the first [length] instances of [shown] the farthest first by
  // their [bounds], as [_farthestFirst] orders items; instances at one depth
  // keep their order.
  void _farthestInstancesFirst(
    Int32List shown,
    int length,
    Float32List bounds,
    Float32List clip, {
    required bool reversed,
  }) {
    var depths = _depths;
    final count = bounds.length ~/ 6;
    if (depths.length < count) depths = _depths = Float64List(count * 2);
    for (var at = 0; at < length; at++) {
      final instance = shown[at];
      depths[instance] = _depthOf(
        clip,
        bounds,
        instance * 6,
        reversed: reversed,
      );
    }
    Int32List.sublistView(shown, 0, length).sort((a, b) {
      final order = depths[b].compareTo(depths[a]);
      return order != 0 ? order : a.compareTo(b);
    });
  }

  // The depth [_farthestFirst] orders by of the bounds at [at] of [b].
  static double _depthOf(
    Float32List clip,
    Float32List b,
    int at, {
    required bool reversed,
  }) {
    final row = clip[3] == 0.0 && clip[7] == 0.0 && clip[11] == 0.0 ? 2 : 3;
    final sign = row == 2 && reversed ? -1.0 : 1.0;
    return sign *
        (clip[row] * (b[at] + b[at + 3]) * 0.5 +
            clip[4 + row] * (b[at + 1] + b[at + 4]) * 0.5 +
            clip[8 + row] * (b[at + 2] + b[at + 5]) * 0.5 +
            clip[12 + row]);
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

  // Whether the bounds at [at] of [bounds] reach inside [planes].
  static bool _inside(Float32List planes, Float32List bounds, int at) {
    for (var plane = 0; plane < 6; plane++) {
      final a = planes[plane * 4];
      final b = planes[plane * 4 + 1];
      final c = planes[plane * 4 + 2];
      final d = planes[plane * 4 + 3];
      final x = bounds[at + (a >= 0 ? 3 : 0)];
      final y = bounds[at + (b >= 0 ? 4 : 1)];
      final z = bounds[at + (c >= 0 ? 5 : 2)];
      if (a * x + b * y + c * z + d < 0) return false;
    }
    return true;
  }
}
