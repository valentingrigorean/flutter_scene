import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter_scene/src/render/viewport_camera.dart';
import 'package:flutter_scene/src/render/depth_raster.dart';
import 'package:flutter_scene/src/fmat/fmat_ast.dart' show DepthSurfaceKind;
import 'package:flutter_scene/src/mesh_draw.dart';
import 'package:flutter_scene/src/render/instance_records.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/mesh_draw_selection.dart';

import 'dart:ui' as ui;

import 'package:flutter_scene/src/geometry/vertex_layout.dart'
    show VertexLayoutDescriptor;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/geometry/geometry.dart'
    show
        Geometry,
        bindUnskinnedFrameInfo,
        currentDrawInstanceFrame,
        positionOnlyLayoutOverRecords;
import 'package:flutter_scene/src/material/material.dart'
    show MaskedDepthPass, Material;
import 'package:flutter_scene/src/render/draw_recorder.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/render_layers.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/scene_encoder.dart'
    show
        PipelineInputs,
        cachedRenderPipeline,
        drawOrRejectPipeline,
        tryResolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/linear_depth_probe.dart';
import 'package:flutter_scene/src/material/instance_attributes.dart'
    show InstanceAttributeSchema;
import 'package:flutter_scene/src/material/vertex_attributes.dart';
import 'package:flutter_scene/src/render/uniform_slots.dart';

/// Render-graph blackboard key under which [DepthPrepass] publishes the
/// camera linear-depth texture: planar view-space depth (world units) in a
/// layout of `shaders/linear_depth.glsl`, which every reader decodes through
/// its `LinearDepthOf`, with the far value where no geometry was drawn.
const String kLinearDepthBlackboardKey = 'linear_depth';

/// Render-graph blackboard key under which [DepthPrepass] publishes its
/// hardware depth-stencil attachment, only when constructed with
/// `keepDepthStencil`. [TranslucentDepthPatchPass] loads it to depth-test
/// translucent surfaces against the opaque scene.
const String kPrepassDepthStencilBlackboardKey = 'prepass_depth_stencil';

/// Renders the opaque scene's depth from the camera into a linear-depth
/// color target and publishes it on the render-graph blackboard.
///
/// Screen-space effects (ambient occlusion today, and depth-aware effects
/// later) read this to reconstruct view-space positions. The prepass also
/// primes early-Z for the following color pass.
///
/// Planar view-space depth is written into a floating-point color target
/// (rather than relying on a shader-readable depth-stencil texture),
/// mirroring how the shadow pass stores depth in a color attachment. That
/// keeps the texture sampleable identically on every backend. The target is
/// 32-bit float, or half float in the split layout of
/// `shaders/linear_depth.glsl` where the device renders no 32-bit float color
/// target ([linearDepthIsSplit]).
class DepthPrepass extends RenderGraphPass {
  DepthPrepass({
    required Camera camera,
    required RenderScene renderScene,
    required ui.Size dimensions,
    required Vector3 cameraForward,
    required double farDepth,
    int layerMask = kRenderLayerAll,
    bool writeNormals = false,
    bool keepDepthStencil = false,
    Vector3? cameraRight,
    Vector3? cameraUp,
    List<Plane> cullingPlanes = const [],
    Matrix4? cameraTransform,
    bool primaryView = false,
  }) : _primaryView = primaryView,
       _camera = camera,
       _renderScene = renderScene,
       _dimensions = dimensions,
       _cameraForward = cameraForward,
       _farDepth = farDepth,
       _layerMask = layerMask,
       _cullingPlanes = cullingPlanes,
       _writeNormals = writeNormals,
       _keepDepthStencil = keepDepthStencil,
       _cameraRight = cameraRight ?? Vector3.zero(),
       _cameraUp = cameraUp ?? Vector3.zero(),
       _cameraTransform = cameraTransform;

  final Matrix4? _cameraTransform;
  final bool _primaryView;

  final Camera _camera;
  final RenderScene _renderScene;
  final ui.Size _dimensions;
  final Vector3 _cameraForward;
  final double _farDepth;
  final int _layerMask;
  final List<Plane> _cullingPlanes;

  // When set, the prepass also writes the interpolated view-space normal and
  // the roughness into the linear-depth target, for screen-space reflections. This forces the full vertex
  // shader (the depth-only position path carries no normal), so it is left
  // off when only ambient occlusion needs the prepass.
  final bool _writeNormals;

  // When set, the depth-stencil attachment is stored (instead of the default
  // discard) and published, so [TranslucentDepthPatchPass] can test against
  // it later in the frame. Off unless a patch will actually run; the extra
  // store costs bandwidth on tiled GPUs.
  final bool _keepDepthStencil;
  final Vector3 _cameraRight;
  final Vector3 _cameraUp;

  @override
  String get name => 'DepthPrepass';

  @override
  void execute(RenderGraphContext context) {
    final width = _dimensions.width.toInt();
    final height = _dimensions.height.toInt();

    // fp32, or two fp16 channels split across the depth (not one fp16): the
    // occlusion pass reconstructs view-space positions and normals from this
    // depth, and fp16's ~11-bit mantissa quantizes it into visibly banded
    // steps (the same reason the shadow map is fp32).
    final linearDepth = context.texturePool.acquire(
      TransientTextureDescriptor.color(
        width: width,
        height: height,
        format: linearDepthFormat(normals: _writeNormals),
        debugName: 'linear_depth',
        // The kept and transient depth attachments below are different
        // textures, so the color target gets a ring per setup.
        attachmentKey: _keepDepthStencil ? 'depth_stored' : 'depth_transient',
      ),
    );
    // A kept depth-stencil cannot live in transient tile memory (storing a
    // deviceTransient attachment is invalid); allocate it device-private so
    // the patch pass can reload it later in the frame.
    final depth = context.texturePool.acquire(
      _keepDepthStencil
          ? TransientTextureDescriptor(
              width: width,
              height: height,
              format: depthRasterOf(_camera).depthStencilFormat,
              enableShaderReadUsage: false,
              debugName: 'depth_prepass_depth',
            )
          : TransientTextureDescriptor.depth(
              width: width,
              height: height,
              format: depthRasterOf(_camera).depthStencilFormat,
              debugName: 'depth_prepass_depth',
            ),
    );
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: linearDepth,
        // Background texels (no geometry) read as the far plane, i.e. fully
        // unoccluded for any consumer.
        clearValue: linearDepthClearValue(_farDepth),
      ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depth,
        depthClearValue: depthRasterOf(_camera).clearDepth,
        depthStoreAction: _keepDepthStencil
            ? gpu.StoreAction.store
            : gpu.StoreAction.dontCare,
      ),
    );

    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(target);
    final encoder = _DepthPrepassEncoder(
      renderPass,
      context.transientsBuffer,
      _cameraTransform ?? rasterViewTransformOf(_camera, _dimensions),
      cullingFrustumOf(_camera, _dimensions),
      depthRasterOf(_camera),
      _camera.position,
      _cameraForward,
      _layerMask,
      _cullingPlanes,
      writeNormals: _writeNormals,
      cameraRight: _cameraRight,
      cameraUp: _cameraUp,
      primaryView: _primaryView,
    );
    _renderScene.cull(
      encoder.frustum,
      encoder.submit,
      additionalPlanes: _cullingPlanes,
    );
    encoder.flush();
    rendererSubmissions.submit(commandBuffer);

    context.blackboard.set(kLinearDepthBlackboardKey, linearDepth);
    if (_keepDepthStencil) {
      context.blackboard.set(kPrepassDepthStencilBlackboardKey, depth);
    }
  }
}

/// Patches translucent depth-carrying surfaces into the prepass linear
/// depth, after the passes that need opaque-only depth (ambient occlusion,
/// reflections) and before the ones that want the visible surface (depth of
/// field).
///
/// Draws items whose material is translucent but declares
/// [Material.translucentEffectsDepth] (fmat `depth_write: true` or
/// `effects_depth: true`, or a transmissive [PhysicallyBasedMaterial]), cut
/// by the material's own alpha where it supplies a depth fragment,
/// depth-tested against the opaque
/// scene through the prepass depth-stencil. Without this, depth of field
/// reads the backdrop's depth at a glass surface's pixels and smears the
/// backdrop's blur across it. Content seen through the surface inherits the
/// surface's depth, the same tradeoff every depth-writing translucency
/// scheme accepts.
///
/// Requires [DepthPrepass] to have run with `keepDepthStencil`; does
/// nothing when either blackboard texture is absent or no visible item
/// qualifies. The patch overwrites the target's green/blue/alpha channels
/// (view-space normals when reflections requested them), so it runs after
/// the built-in consumers of those channels (ambient occlusion,
/// reflections). Custom render passes from [RenderStage.afterScene] on read
/// the same blackboard texture and therefore see patched depth and normals
/// at depth-writing translucent pixels; that is the visible-surface
/// semantics depth of field and depth-fogging passes want, and the accepted
/// tradeoff for any pass wanting opaque-only geometry.
class TranslucentDepthPatchPass extends RenderGraphPass {
  TranslucentDepthPatchPass({
    required Camera camera,
    required RenderScene renderScene,
    required Vector3 cameraForward,
    int layerMask = kRenderLayerAll,
    List<Plane> cullingPlanes = const [],
    bool primaryView = false,
  }) : _camera = camera,
       _renderScene = renderScene,
       _cameraForward = cameraForward,
       _layerMask = layerMask,
       _cullingPlanes = cullingPlanes,
       _primaryView = primaryView;

  final Camera _camera;
  final RenderScene _renderScene;
  final Vector3 _cameraForward;
  final int _layerMask;
  final List<Plane> _cullingPlanes;
  // Whether this is a screen view, for mesh draw selectors, so the patch
  // draws what the color pass drew.
  final bool _primaryView;

  @override
  String get name => 'TranslucentDepthPatchPass';

  static bool _qualifies(RenderItem item) =>
      !item.material.isOpaque() && item.material.translucentEffectsDepth;

  @override
  void execute(RenderGraphContext context) {
    final linearDepth = context.blackboard.get<gpu.Texture>(
      kLinearDepthBlackboardKey,
    );
    final depthStencil = context.blackboard.get<gpu.Texture>(
      kPrepassDepthStencilBlackboardKey,
    );
    if (linearDepth == null || depthStencil == null) return;

    // Collect qualifying items before opening a render pass, so a scene with
    // no depth-carrying translucents pays only this walk.
    final dimensions = ui.Size(
      linearDepth.width.toDouble(),
      linearDepth.height.toDouble(),
    );
    final frustum = cullingFrustumOf(_camera, dimensions);
    final records = <RenderItem>[];
    _renderScene.cull(frustum, (item) {
      if (!item.drawsColor) return;
      if ((item.layers & _layerMask) == 0) return;
      if (!_qualifies(item)) return;
      if (!item.cullVisibleCells(frustum, _cullingPlanes)) return;
      records.add(item);
    }, additionalPlanes: _cullingPlanes);
    if (records.isEmpty) return;

    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: linearDepth,
        loadAction: gpu.LoadAction.load,
      ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depthStencil,
        depthLoadAction: gpu.LoadAction.load,
      ),
    );
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(target);
    final encoder = _DepthPrepassEncoder(
      renderPass,
      context.transientsBuffer,
      rasterViewTransformOf(_camera, dimensions),
      frustum,
      depthRasterOf(_camera),
      _camera.position,
      _cameraForward,
      _layerMask,
      _cullingPlanes,
      writeNormals: false,
      cameraRight: Vector3.zero(),
      cameraUp: Vector3.zero(),
      translucentPatch: true,
      primaryView: _primaryView,
    );
    for (final item in records) {
      encoder.submit(item);
    }
    encoder.flush();
    rendererSubmissions.submit(commandBuffer);
  }
}

/// Whether the depth prepass records [item] in a view culled by [frustum]:
/// drawn, on a layer of [layerMask], in the pass's set (the prepass
/// participants, or with [translucentPatch] the translucent depth writers),
/// and with an instance inside the frustum and [cullingPlanes].
bool depthPrepassAccepts(
  RenderItem item, {
  required Frustum frustum,
  required int layerMask,
  required List<Plane> cullingPlanes,
  bool translucentPatch = false,
}) {
  if (!item.drawsColor) return false;
  if ((item.layers & layerMask) == 0) return false;
  if (translucentPatch
      ? (item.material.isOpaque() || !item.material.translucentEffectsDepth)
      : !item.material.depthPrepassParticipates) {
    return false;
  }
  return item.cullVisibleCells(frustum, cullingPlanes);
}

/// How the depth prepass draws [geometry] with [material]: its shaders, its
/// vertex layout, and the vertex inputs the draw binds.
///
/// A cutout `.fmat` supplies its own depth fragment, cut by its surface
/// alpha; an explicitly configured alpha mask wins over that automatic
/// variant and draws through the masked linear-depth shader, which the
/// material may supply. Either reads the full-vertex varyings, so it skips
/// the position-only path. Unskinned geometry otherwise draws depth through a
/// position-only shader and layout (fetching only position); skinned
/// geometry has no such variant, so it falls back to its full vertex shader.
/// The normal-writing path ([writeNormals]) always uses the full vertex
/// shader, since the position-only path carries no normal.
///
/// A `vertex { }` material displaces geometry in the color pass, so the
/// prepass applies the same displacement or its depth mismatches: it prefers
/// the material's vertex variant (its position-only `depth` variant when the
/// geometry has one, else the mesh-type variant). Without a position-only
/// path the pass runs the material's color vertex variant, which declares its
/// per-instance attribute inputs and custom attributes, so the instance
/// record is as wide as in the color pass.
DepthPrepassDraw depthPrepassDraw(
  Geometry geometry,
  Material material, {
  required bool writeNormals,
}) {
  final surfaceShader = material.depthAlphaMasked
      ? null
      : material.depthSurfaceShader(
          writeNormals
              ? DepthSurfaceKind.linearDepthNormal
              : DepthSurfaceKind.linearDepth,
        );
  final masked = surfaceShader != null || material.depthAlphaMasked;
  final fragmentShader =
      surfaceShader ??
      (!masked
          ? (writeNormals ? _depthNormalShader : _depthShader)
          : material.maskedDepthFragmentShader(
                  writeNormals
                      ? MaskedDepthPass.linearDepthNormal
                      : MaskedDepthPass.linearDepth,
                ) ??
                (writeNormals ? _maskedDepthNormalShader : _maskedDepthShader));
  final depthVertex =
      (writeNormals || masked || material.needsFullVertexForDepth(geometry))
      ? null
      : geometry.depthOnlyVertex;
  final materialVertex = material.vertexShaderForGeometry(
    geometry,
    depth: depthVertex != null,
  );
  final instanceSchema = depthVertex == null
      ? material.instanceAttributes
      : null;
  final attributes = depthVertex == null
      ? material.vertexAttributesFor(materialVertex)
      : VertexAttributeSchema.none;
  return DepthPrepassDraw._(
    vertexShader:
        materialVertex ?? depthVertex?.shader ?? geometry.vertexShader,
    fragmentShader: fragmentShader,
    vertexLayout:
        depthVertex?.layout ??
        geometry.instancedVertexLayoutFor(instanceSchema, attributes),
    materialVertex: materialVertex,
    positionOnly: depthVertex != null,
    surface: surfaceShader != null,
    masked: masked,
    instanceSchema: instanceSchema,
    attributes: attributes,
  );
}

/// The pipeline inputs of the depth prepass draw of [item].
PipelineInputs depthPrepassPipelineInputs(
  RenderItem item, {
  required bool writeNormals,
}) => depthPrepassDraw(
  item.geometry,
  item.material,
  writeNormals: writeNormals,
).pipelineInputsFor(item);

/// One depth prepass draw; see [depthPrepassDraw].
final class DepthPrepassDraw {
  DepthPrepassDraw._({
    required this.vertexShader,
    required this.fragmentShader,
    required this.vertexLayout,
    required this.materialVertex,
    required this.positionOnly,
    required this.surface,
    required this.masked,
    required this.instanceSchema,
    required this.attributes,
  });

  final gpu.Shader vertexShader;
  final gpu.Shader fragmentShader;
  final VertexLayoutDescriptor? vertexLayout;

  /// The material's vertex variant, when it supplies one.
  final gpu.Shader? materialVertex;

  /// Whether the draw runs the position-only vertex path.
  final bool positionOnly;

  /// Whether [fragmentShader] is the material's own cutout surface fragment.
  final bool surface;

  /// Whether the fragment cuts the surface, by its surface alpha or by an
  /// alpha mask.
  final bool masked;

  /// The per-instance attributes the full-vertex path reads.
  final InstanceAttributeSchema? instanceSchema;

  /// The custom vertex attributes the draw fetches.
  final VertexAttributeSchema? attributes;

  /// Whether the draw of [item] reads its model transforms from the instance
  /// records the color pass retains, which a position-only draw of
  /// node-space records does.
  bool retainsRecordsOf(RenderItem item) =>
      positionOnly && vertexLayout != null;

  /// The pipeline inputs of the draw of [item].
  PipelineInputs pipelineInputsFor(RenderItem item) => (
    vertexShader: vertexShader,
    fragmentShader: fragmentShader,
    vertexLayout: retainsRecordsOf(item)
        ? positionOnlyLayoutOverRecords(
            vertexLayout!,
            kInstanceRecordFloats + item.instanceAttributeFloats,
          )
        : vertexLayout,
  );
}

final gpu.Shader _depthShader = baseShaderLibrary['LinearDepthFragment']!;
final gpu.Shader _depthNormalShader =
    baseShaderLibrary['LinearDepthNormalFragment']!;
final gpu.Shader _maskedDepthShader =
    baseShaderLibrary['LinearDepthMaskedFragment']!;
final gpu.Shader _maskedDepthNormalShader =
    baseShaderLibrary['LinearDepthNormalMaskedFragment']!;

/// Records each opaque object's planar view-space depth into the prepass
/// render pass, from the camera's point of view.
///
/// Mirrors `ShadowEncoder`: it reuses the engine's standard vertex shaders
/// (so unskinned and skinned geometry are both covered) paired with the
/// `LinearDepthFragment` shader, and supplies the camera view-projection in
/// place of the light-space matrix. Translucent objects do not write depth.
class _DepthPrepassEncoder {
  _DepthPrepassEncoder(
    this._renderPass,
    this._transientsBuffer,
    this._cameraTransform,
    this.frustum,
    this._raster,
    this._cameraPosition,
    this._cameraForward,
    this._layerMask,
    this._cullingPlanes, {
    required bool writeNormals,
    required Vector3 cameraRight,
    required Vector3 cameraUp,
    bool translucentPatch = false,
    bool primaryView = false,
  }) : _writeNormals = writeNormals,
       _translucentPatch = translucentPatch,
       _primaryView = primaryView {
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(false);
    _renderPass.setDepthCompareOperation(_raster.nearerOrEqual);
    // Winding and culling are matched to each material per draw in [submit]
    // (winding follows the node/instance parity, culling follows the material's
    // own mode), so the same faces the color pass draws contribute depth.
    _renderPass.setWindingOrder(gpu.WindingOrder.clockwise);
    // The camera axes are constant across the pass. Pack them once and
    // rebind per draw (clearBindings drops the binding between draws). The
    // normal-writing path also needs the right/up axes to rotate the world
    // normal into view space; the depth-only path uses just forward.
    // The w the shaders leave free carries the layout of linear_depth.glsl.
    final split = linearDepthIsSplit ? 1.0 : 0.0;
    if (writeNormals) {
      _depthInfo = Float32List(20)
        ..[0] = _cameraForward.x
        ..[1] = _cameraForward.y
        ..[2] = _cameraForward.z
        ..[4] = cameraRight.x
        ..[5] = cameraRight.y
        ..[6] = cameraRight.z
        ..[7] = split
        ..[8] = cameraUp.x
        ..[9] = cameraUp.y
        ..[10] = cameraUp.z;
    } else {
      _depthInfo = Float32List(4)
        ..[0] = _cameraForward.x
        ..[1] = _cameraForward.y
        ..[2] = _cameraForward.z
        ..[3] = split;
    }
  }

  final gpu.RenderPass _renderPass;
  final TransientWriter _transientsBuffer;
  // The view-projection draws rasterize with (see DepthRaster).
  final Matrix4 _cameraTransform;
  final DepthRaster _raster;
  final Vector3 _cameraPosition;
  final Vector3 _cameraForward;
  final int _layerMask;
  final List<Plane> _cullingPlanes;
  final bool _writeNormals;

  // Whether this encodes a screen view's camera, for [MeshDrawSelector]s.
  final bool _primaryView;

  // Flips the item filter from the prepass's opaque set to the translucent
  // depth-carrying set drawn by [TranslucentDepthPatchPass].
  final bool _translucentPatch;
  late final Float32List _depthInfo;

  // The roughness map is a tiled material texture; sample it with repeat.
  static final gpu.SamplerOptions _roughnessSampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    widthAddressMode: gpu.SamplerAddressMode.repeat,
    heightAddressMode: gpu.SamplerAddressMode.repeat,
  );

  String get _infoBlockName => _writeNormals ? 'DepthNormalInfo' : 'DepthInfo';

  /// Frustum of the camera view-projection, used for per-item culling.
  final Frustum frustum;

  /// The pipeline currently bound on the render pass, or null before the
  /// first draw. `clearBindings` leaves the pipeline in place, so
  /// consecutive objects that share one only bind it once.
  gpu.RenderPipeline? _boundPipeline;
  final List<RenderItem> _records = [];

  /// Records [item]'s depth, unless it is hidden, rejected by its layer
  /// mask, or outside this encoder's set (prepass-participating items
  /// normally, which is the opaque scene plus opt-ins like the shadow
  /// catcher; translucent depth-writing items in the patch mode).
  void submit(RenderItem item) {
    if (!depthPrepassAccepts(
      item,
      frustum: frustum,
      layerMask: _layerMask,
      cullingPlanes: _cullingPlanes,
      translucentPatch: _translucentPatch,
    )) {
      return;
    }
    _records.add(item);
  }

  void flush() {
    _records.sort((a, b) {
      final byMaterial = a.materialIdentity.compareTo(b.materialIdentity);
      if (byMaterial != 0) return byMaterial;
      return a.geometryIdentity.compareTo(b.geometryIdentity);
    });
    for (final item in _records) {
      _encode(item);
    }
    _records.clear();
  }

  void _encode(RenderItem item) {
    final geometry = item.geometry;
    final selection = beginMeshDraw(
      item,
      geometry,
      MeshDrawPass.depth,
      _cameraPosition,
      _primaryView,
    );
    try {
      if (selection.instanceCount == 0) return;
      _encodeBody(item, instanceLimit: selection.instanceCount);
    } finally {
      endMeshDraw(geometry);
    }
  }

  void _encodeBody(RenderItem item, {int? instanceLimit}) {
    // Cull the same faces as the color pass; a double-sided (culling: none)
    // material must stay double-sided here, or its camera-facing back faces are
    // absent from the prepass and SSAO/SSR read the farther surface behind them.
    _renderPass.setCullMode(item.material.renderCullMode);
    final geometry = item.geometry;
    // Skinned items draw through the full bind path below; apply this item's
    // skeleton to the (possibly shared) geometry first.
    item.applyJointsTexture(geometry);
    item.applyMorphWeights(geometry);
    final draw = depthPrepassDraw(
      geometry,
      item.material,
      writeNormals: _writeNormals,
    );
    final fragmentShader = draw.fragmentShader;
    final activeVertex = draw.vertexShader;
    final materialVertex = draw.materialVertex;
    final instanceSchema = draw.instanceSchema;
    final attributeFloats = instanceSchema?.floatCount ?? 0;
    geometry.useVertexAttributes(draw.attributes);
    final retainsRecords = draw.retainsRecordsOf(item);
    final vertexLayout = retainsRecords
        ? draw.pipelineInputsFor(item).vertexLayout
        : draw.vertexLayout;
    final surface = draw.surface;
    final positionOnly = draw.positionOnly;
    final pipeline =
        cachedRenderPipeline(activeVertex, fragmentShader, vertexLayout) ??
        _resolvePipeline(activeVertex, fragmentShader, vertexLayout, geometry);
    // A sliced warm-up builds this pipeline in a later slice.
    if (pipeline == null) return;
    if (!identical(_boundPipeline, pipeline)) {
      _renderPass.clearBindings();
      _renderPass.bindPipeline(pipeline);
      _boundPipeline = pipeline;
    }
    _renderPass.setPrimitiveType(geometry.primitiveType);
    activeDrawRecorder?.setContext(
      DrawContext(
        phase: DrawPhase.depth,
        item: item,
        geometry: geometry,
        material: item.material,
        vertexShader: activeVertex,
        fragmentShader: fragmentShader,
        pipeline: pipeline,
      ),
    );
    if (_writeNormals) {
      // Carry this material's roughness so the reflection trace can fade out
      // on rough surfaces. camera_forward.w holds the roughness factor; the
      // map (a white placeholder when the material has none) supplies the
      // per-pixel roughness in its green channel.
      _depthInfo[3] = item.material.reflectionRoughnessFactor;
      final roughnessTransform =
          item.material.reflectionRoughnessTextureTransform;
      _depthInfo
        ..[12] = roughnessTransform.offset.x
        ..[13] = roughnessTransform.offset.y
        ..[14] = roughnessTransform.scale.x
        ..[15] = roughnessTransform.scale.y
        ..[16] = math.cos(roughnessTransform.rotation)
        ..[17] = math.sin(roughnessTransform.rotation)
        ..[18] = item.material.reflectionRoughnessTextureTexCoord
            .clamp(0, 1)
            .toDouble();
      // A surface fragment takes its roughness from Surface() instead.
      if (!surface) {
        _renderPass.bindTexture(
          fragmentShader.cachedUniformSlot('metallic_roughness_texture'),
          Material.whitePlaceholder(item.material.reflectionRoughnessTexture),
          sampler:
              item.material.reflectionRoughnessTextureSampler ??
              _roughnessSampler,
        );
      }
    }
    _renderPass.bindUniform(
      fragmentShader.cachedUniformSlot(_infoBlockName),
      _transientsBuffer.emplace(scratchBytesOf(_depthInfo)),
    );
    if (surface) {
      item.material.bindDepthSurface(
        _renderPass,
        fragmentShader,
        _transientsBuffer,
        cameraPosition: _cameraPosition,
        cameraForward: _cameraForward,
      );
    } else if (draw.masked) {
      item.material.bindDepthAlphaMask(
        _renderPass,
        fragmentShader,
        _transientsBuffer,
      );
    }

    // Binds the vertex/index buffers and the per-frame uniform for one draw.
    // The position-only path resolves FrameInfo against the depth shader; the
    // skinned fallback uses the geometry's own bind (which ignores the model
    // transform passed here, since skinned uses joint matrices).
    setCurrentDrawDepthOffset(
      _raster,
      item.material.depthLayer,
      item.material.tieBreakRank,
    );
    _drawItem = item;
    _drawGeometry = geometry;
    _drawDepthPath = positionOnly;
    _drawVertex = activeVertex;
    _drawMaterialVertex = materialVertex;

    // The instance-rate model transform sits in the slot after the bound
    // vertex streams. The depth-only path binds just the position stream
    // (slot 0), so its instance is slot 1; the normal-writing path binds the
    // full stream set, so the instance follows them (slot
    // [vertexStreamCount]), matching the color encoder.
    final instanceSlot = positionOnly ? 1 : geometry.vertexStreamCount;

    final instances = item.instanceTransforms;
    if (instances != null) {
      final ranges = item.visibleInstanceRanges ?? item.instanceRanges;
      final limit = instanceLimit == null || instanceLimit >= instances.length
          ? null
          : instanceLimit;
      if (geometry.instancedVertexLayout == null) {
        // Skinned geometry has no instance-attribute path; loop.
        for (var range = 0; range < ranges.length; range += 3) {
          var end = ranges[range] + ranges[range + 1];
          if (limit != null && end > limit) end = limit;
          for (var row = ranges[range]; row < end; row++) {
            final instanceTransform = instances[row];
            _bindDraw(item.worldTransform * instanceTransform);
            final flip =
                item.windingFlipped != (instanceTransform.determinant() < 0);
            _renderPass.setWindingOrder(
              flip
                  ? gpu.WindingOrder.counterClockwise
                  : gpu.WindingOrder.clockwise,
            );
            drawOrRejectPipeline(_renderPass, geometry, _boundPipeline);
          }
        }
        return;
      }
      if (item.instanceWorldData == null) return;
      currentDrawInstanceFrame = item.instanceFrame;
      _bindDraw(item.worldTransform);
      currentDrawInstanceFrame = null;
      // One instanced draw per range of the records the item keeps; a frame
      // packs none.
      for (var range = 0; range < ranges.length; range += 3) {
        final first = ranges[range];
        var count = ranges[range + 1];
        if (limit != null) {
          if (first >= limit) break;
          if (first + count > limit) count = limit - first;
        }
        bindInstanceRows(_renderPass, item, first, count, slot: instanceSlot);
        _renderPass.setWindingOrder(
          ranges[range + 2] != 0
              ? gpu.WindingOrder.counterClockwise
              : gpu.WindingOrder.clockwise,
        );
        drawOrRejectPipeline(
          _renderPass,
          geometry,
          _boundPipeline,
          instanceCount: count,
        );
      }
      return;
    }

    _bindDraw(item.worldTransform);
    // Skip the model-transform instance buffer for geometry that supplies its
    // own per-instance buffer (see the color encoder), or it clobbers the
    // stream slot.
    if (geometry.instancedVertexLayout != null &&
        geometry.bindsModelTransformInstance) {
      bindHeldInstanceRecord(
        _renderPass,
        item,
        slot: instanceSlot,
        attributeFloats: attributeFloats,
      );
    }
    _renderPass.setWindingOrder(
      item.windingFlipped
          ? gpu.WindingOrder.counterClockwise
          : gpu.WindingOrder.clockwise,
    );
    drawOrRejectPipeline(_renderPass, geometry, _boundPipeline);
  }

  // Per-draw state for [_bindDraw], set by the encode path. Fields rather
  // than a local closure, which would allocate on every draw.
  RenderItem? _drawItem;
  Geometry? _drawGeometry;
  bool _drawDepthPath = false;
  gpu.Shader? _drawVertex;
  gpu.Shader? _drawMaterialVertex;

  // Binds the vertex/index buffers and the per-frame uniforms for one draw.
  void _bindDraw(Matrix4 worldTransform) {
    final item = _drawItem!;
    final geometry = _drawGeometry!;
    final activeVertex = _drawVertex!;
    final materialVertex = _drawMaterialVertex;
    if (_drawDepthPath) {
      geometry.bindPositionStream(_renderPass);
      bindUnskinnedFrameInfo(
        _renderPass,
        _transientsBuffer,
        activeVertex,
        _cameraTransform,
        _cameraPosition,
        depthBias: item.material.depthBias,
      );
    } else {
      geometry.bind(
        _renderPass,
        _transientsBuffer,
        worldTransform,
        _cameraTransform,
        _cameraPosition,
        shaderOverride: materialVertex,
        depthBias: item.material.depthBias,
      );
    }
    // Feed the material's parameters to its vertex variant so the same
    // displacement runs here as in the color pass.
    if (materialVertex != null) {
      item.material.bindVertexStage(
        _renderPass,
        materialVertex,
        _transientsBuffer,
      );
    }
  }

  // The pipeline-cache miss path. Its debug closure lives here so the
  // per-draw path does not allocate a capture context.
  gpu.RenderPipeline? _resolvePipeline(
    gpu.Shader vertexShader,
    gpu.Shader fragmentShader,
    VertexLayoutDescriptor? vertexLayout,
    Geometry geometry,
  ) => tryResolvePipeline(
    vertexShader,
    fragmentShader,
    vertexLayout: vertexLayout,
    debugContext: () => 'depth prepass ${geometry.runtimeType}',
  );
}
