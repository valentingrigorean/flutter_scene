import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:meta/meta.dart';

typedef _Blend = (
  gpu.BlendOperation,
  gpu.BlendFactor,
  gpu.BlendFactor,
  gpu.BlendOperation,
  gpu.BlendFactor,
  gpu.BlendFactor,
);

typedef _Stencil = (
  gpu.CompareFunction,
  gpu.StencilOperation,
  gpu.StencilOperation,
  gpu.StencilOperation,
  int,
  int,
);

// The backend's own defaults, which a pass draws with until a setter runs.
const _Blend _defaultBlend = (
  gpu.BlendOperation.add,
  gpu.BlendFactor.sourceAlpha,
  gpu.BlendFactor.oneMinusSourceAlpha,
  gpu.BlendOperation.add,
  gpu.BlendFactor.sourceAlpha,
  gpu.BlendFactor.oneMinusSourceAlpha,
);

const _Stencil _defaultStencil = (
  gpu.CompareFunction.always,
  gpu.StencilOperation.keep,
  gpu.StencilOperation.keep,
  gpu.StencilOperation.keep,
  0xFFFFFFFF,
  0xFFFFFFFF,
);

// What a backend keys a native pipeline by beside the render pipeline:
// the target's color attachments, sample count and depth stencil format, each
// color attachment's blend, the depth and stencil state where the target has
// a depth stencil attachment, and the cull mode, winding, primitive type and
// polygon mode. `flutter_gpu` builds that native pipeline at the first draw
// that meets it; on GLES that draw waits on the raster thread.
final class _PassState {
  _PassState(gpu.RenderTarget? target)
    : _target = target == null
          ? null
          : (
              target.colorAttachments.length,
              target.colorAttachments.firstOrNull?.texture.format,
              target.colorAttachments.firstOrNull?.texture.sampleCount ?? 1,
              target.depthStencilAttachment?.texture.format,
            ),
      _depth = target == null || target.depthStencilAttachment != null;

  final (int, gpu.PixelFormat?, int, gpu.PixelFormat?)? _target;
  final bool _depth;
  // What the draws met in the pipeline and state the pass holds, looked up
  // once each time they change, so a run of draws in one state reads it
  // without hashing the state again.
  _MetState? _met;
  gpu.RenderPipeline? pipeline;
  final Map<int, bool> blends = {};
  final Map<int, _Blend> equations = {};
  bool depthWrite = false;
  gpu.CompareFunction depthCompare = gpu.CompareFunction.always;
  _Stencil front = _defaultStencil;
  _Stencil back = _defaultStencil;
  gpu.CullMode cull = gpu.CullMode.none;
  gpu.WindingOrder winding = gpu.WindingOrder.clockwise;
  gpu.PrimitiveType primitive = gpu.PrimitiveType.triangle;
  gpu.PolygonMode polygon = gpu.PolygonMode.fill;

  void changed() => _met = null;

  void bind(gpu.RenderPipeline pipeline) {
    if (identical(pipeline, this.pipeline)) return;
    this.pipeline = pipeline;
    _met = null;
  }

  _MetState metOf(gpu.RenderPipeline pipeline) {
    final held = _met;
    if (held != null) return held;
    passStateLookups++;
    return _met = _metStates.putIfAbsent((pipeline, _keyOf()), _MetState.new);
  }

  Object _keyOf() {
    final attachments = _target?.$1 ?? 1;
    return (
      _target,
      [
        for (var index = 0; index < attachments; index++)
          (blends[index] ?? false, equations[index] ?? _defaultBlend),
      ].join(),
      _depth ? (depthWrite, depthCompare, front, back) : null,
      cull,
      winding,
      primitive,
      polygon,
    );
  }

  String get description => [
    if (_target case (final count, final format, final samples, final ds))
      '${count}x ${format?.name} ${samples}x${ds == null ? '' : ' ${ds.name}'}',
    if (blends.values.any((blend) => blend)) 'blend',
    if (_depth) ...[
      'depth ${depthCompare.name}${depthWrite ? ' write' : ''}',
      if (front != _defaultStencil || back != _defaultStencil) 'stencil',
    ],
    if (cull != gpu.CullMode.none) 'cull ${cull.name}',
    if (winding != gpu.WindingOrder.clockwise) winding.name,
    if (primitive != gpu.PrimitiveType.triangle) primitive.name,
    if (polygon != gpu.PolygonMode.fill) polygon.name,
  ].join(', ');
}

final Expando<_PassState> _passStates = Expando('pass pipeline state');

_PassState _stateOf(gpu.RenderPass pass) =>
    _passStates[pass] ??= _PassState(null);

// Whether a draw met a render pipeline in one native state, which builds the
// native pipeline, and whether a draw of it was recorded.
final class _MetState {
  bool met = false;
  bool recorded = false;
}

final Map<Object, _MetState> _metStates = {};

/// The times a pass looked the pipeline and state its draws meet up, once
/// each time one of them changed.
@visibleForTesting
int passStateLookups = 0;

final Expando<bool> _drawnPipelines = Expando('drawn pipeline');

/// Creates a render pass on [commandBuffer] into [target] whose draws through
/// [recordPassDraw] are keyed by [target]'s formats and sample count.
@internal
gpu.RenderPass createTrackedRenderPass(
  gpu.CommandBuffer commandBuffer,
  gpu.RenderTarget target,
) {
  final pass = commandBuffer.createRenderPass(target);
  _passStates[pass] = _PassState(target);
  return pass;
}

/// A pass that records draws for [items] in the shape of [target], whose
/// tracked setters work as on a pass [createTrackedRenderPass] creates.
gpu.RenderPass createTrackedRecorder(
  gpu.ItemSet items,
  gpu.RenderTarget target,
) {
  final pass = items.recorder(target);
  _passStates[pass] = _PassState(target);
  return pass;
}

/// Records a draw on [pass] with the state its tracked setters set, and
/// returns the description of that state when it is the first draw of a
/// render pipeline drawn before in another state, so the backend builds
/// another native pipeline for it; null otherwise. A pipeline's first state
/// is part of the pipeline's own build.
@internal
String? recordPassDraw(gpu.RenderPass pass) {
  final state = _stateOf(pass);
  final pipeline = state.pipeline;
  if (pipeline == null) return null;
  final met = state.metOf(pipeline);
  if (met.recorded) return null;
  met.recorded = true;
  if (_drawnPipelines[pipeline] == null) {
    _drawnPipelines[pipeline] = true;
    return null;
  }
  return state.description;
}

/// Whether the draw [pass] issues next meets its render pipeline in a state
/// no draw met before, so the backend builds a native pipeline inside that
/// draw. A pipeline's first state counts too, since the backend builds that
/// one at its first draw as well. A pass whose pipeline was not bound through
/// [TrackedPassState.bindTrackedPipeline] meets none.
@internal
bool meetsNewPassState(gpu.RenderPass pass) {
  final state = _stateOf(pass);
  final pipeline = state.pipeline;
  return pipeline != null && !state.metOf(pipeline).met;
}

/// Marks the state [meetsNewPassState] found for [pass] as met.
@internal
void meetPassState(gpu.RenderPass pass) {
  final state = _stateOf(pass);
  final pipeline = state.pipeline;
  if (pipeline != null) state.metOf(pipeline).met = true;
}

/// The render pass setters that also record the state the scene's pipeline
/// meter keys a draw by.
///
/// A `Geometry` whose `draw` sets its own blend, depth, stencil, cull,
/// winding or primitive state sets it through these, so a draw the scene
/// encodes counts each native pipeline state it meets in
/// `scenePipelinesBuilt`.
extension TrackedPassState on gpu.RenderPass {
  void bindTrackedPipeline(gpu.RenderPipeline pipeline) {
    bindPipeline(pipeline);
    _stateOf(this).bind(pipeline);
  }

  void setTrackedColorBlendEnable(bool enable, {int colorAttachmentIndex = 0}) {
    setColorBlendEnable(enable, colorAttachmentIndex: colorAttachmentIndex);
    final state = _stateOf(this);
    if (state.blends[colorAttachmentIndex] == enable) return;
    state
      ..blends[colorAttachmentIndex] = enable
      ..changed();
  }

  void setTrackedColorBlendEquation(
    gpu.ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  }) {
    setColorBlendEquation(equation, colorAttachmentIndex: colorAttachmentIndex);
    final blend = (
      equation.colorBlendOperation,
      equation.sourceColorBlendFactor,
      equation.destinationColorBlendFactor,
      equation.alphaBlendOperation,
      equation.sourceAlphaBlendFactor,
      equation.destinationAlphaBlendFactor,
    );
    final state = _stateOf(this);
    if (state.equations[colorAttachmentIndex] == blend) return;
    state
      ..equations[colorAttachmentIndex] = blend
      ..changed();
  }

  void setTrackedDepthWriteEnable(bool enable) {
    setDepthWriteEnable(enable);
    final state = _stateOf(this);
    if (state.depthWrite == enable) return;
    state
      ..depthWrite = enable
      ..changed();
  }

  void setTrackedDepthCompareOperation(gpu.CompareFunction compareFunction) {
    setDepthCompareOperation(compareFunction);
    final state = _stateOf(this);
    if (state.depthCompare == compareFunction) return;
    state
      ..depthCompare = compareFunction
      ..changed();
  }

  void setTrackedStencilConfig(
    gpu.StencilConfig configuration, {
    gpu.StencilFace targetFace = gpu.StencilFace.both,
  }) {
    setStencilConfig(configuration, targetFace: targetFace);
    final stencil = (
      configuration.compareFunction,
      configuration.stencilFailureOperation,
      configuration.depthFailureOperation,
      configuration.depthStencilPassOperation,
      configuration.readMask,
      configuration.writeMask,
    );
    final state = _stateOf(this);
    final front = targetFace != gpu.StencilFace.back ? stencil : state.front;
    final back = targetFace != gpu.StencilFace.front ? stencil : state.back;
    if (front == state.front && back == state.back) return;
    state
      ..front = front
      ..back = back
      ..changed();
  }

  void setTrackedCullMode(gpu.CullMode cullMode) {
    setCullMode(cullMode);
    final state = _stateOf(this);
    if (state.cull == cullMode) return;
    state
      ..cull = cullMode
      ..changed();
  }

  void setTrackedWindingOrder(gpu.WindingOrder windingOrder) {
    setWindingOrder(windingOrder);
    final state = _stateOf(this);
    if (state.winding == windingOrder) return;
    state
      ..winding = windingOrder
      ..changed();
  }

  void setTrackedPrimitiveType(gpu.PrimitiveType primitiveType) {
    setPrimitiveType(primitiveType);
    final state = _stateOf(this);
    if (state.primitive == primitiveType) return;
    state
      ..primitive = primitiveType
      ..changed();
  }

  void setTrackedPolygonMode(gpu.PolygonMode polygonMode) {
    setPolygonMode(polygonMode);
    final state = _stateOf(this);
    if (state.polygon == polygonMode) return;
    state
      ..polygon = polygonMode
      ..changed();
  }
}
