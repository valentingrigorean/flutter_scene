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
  // Whether the pass drew since its pipeline or state last changed, so a run
  // of draws in one state records once.
  bool recorded = false;
  Object? _key;
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

  void changed() {
    recorded = false;
    _key = null;
  }

  Object get key => _key ??= _keyOf();

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

final Set<Object> _drawnStates = {};

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

/// Records a draw on [pass] with the state its tracked setters set, and
/// returns the description of that state when it is the first draw of a
/// render pipeline drawn before in another state, so the backend builds
/// another native pipeline for it; null otherwise. A pipeline's first state
/// is part of the pipeline's own build.
@internal
String? recordPassDraw(gpu.RenderPass pass) {
  final state = _stateOf(pass);
  if (state.recorded) return null;
  state.recorded = true;
  final pipeline = state.pipeline;
  if (pipeline == null || !_drawnStates.add((pipeline, state.key))) {
    return null;
  }
  if (_drawnPipelines[pipeline] == null) {
    _drawnPipelines[pipeline] = true;
    return null;
  }
  return state.description;
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
    _stateOf(this)
      ..pipeline = pipeline
      ..recorded = false;
  }

  void setTrackedColorBlendEnable(bool enable, {int colorAttachmentIndex = 0}) {
    setColorBlendEnable(enable, colorAttachmentIndex: colorAttachmentIndex);
    _stateOf(this)
      ..blends[colorAttachmentIndex] = enable
      ..changed();
  }

  void setTrackedColorBlendEquation(
    gpu.ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  }) {
    setColorBlendEquation(equation, colorAttachmentIndex: colorAttachmentIndex);
    _stateOf(this)
      ..equations[colorAttachmentIndex] = (
        equation.colorBlendOperation,
        equation.sourceColorBlendFactor,
        equation.destinationColorBlendFactor,
        equation.alphaBlendOperation,
        equation.sourceAlphaBlendFactor,
        equation.destinationAlphaBlendFactor,
      )
      ..changed();
  }

  void setTrackedDepthWriteEnable(bool enable) {
    setDepthWriteEnable(enable);
    _stateOf(this)
      ..depthWrite = enable
      ..changed();
  }

  void setTrackedDepthCompareOperation(gpu.CompareFunction compareFunction) {
    setDepthCompareOperation(compareFunction);
    _stateOf(this)
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
    if (targetFace != gpu.StencilFace.back) state.front = stencil;
    if (targetFace != gpu.StencilFace.front) state.back = stencil;
    state.changed();
  }

  void setTrackedCullMode(gpu.CullMode cullMode) {
    setCullMode(cullMode);
    _stateOf(this)
      ..cull = cullMode
      ..changed();
  }

  void setTrackedWindingOrder(gpu.WindingOrder windingOrder) {
    setWindingOrder(windingOrder);
    _stateOf(this)
      ..winding = windingOrder
      ..changed();
  }

  void setTrackedPrimitiveType(gpu.PrimitiveType primitiveType) {
    setPrimitiveType(primitiveType);
    _stateOf(this)
      ..primitive = primitiveType
      ..changed();
  }

  void setTrackedPolygonMode(gpu.PolygonMode polygonMode) {
    setPolygonMode(polygonMode);
    _stateOf(this)
      ..polygon = polygonMode
      ..changed();
  }
}
