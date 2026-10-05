import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/components/instanced_mesh_component.dart';
import 'package:flutter_scene/src/components/mesh_component.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/geometry/vertex_layout.dart';
import 'package:flutter_scene/src/light.dart';
import 'package:flutter_scene/src/material/instance_attributes.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/material/engine_lighting.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/render/custom_render_pass.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/lod.dart';
import 'package:flutter_scene/src/render/render_layers.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_profile.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/instance_batching.dart';

/// A deferred opaque draw. Holds the [RenderItem] (instanced or not), its
/// resolved pipeline, a per-pipeline grouping key, and the camera
/// distance, all captured when [SceneEncoder.submit] is called.
base class _OpaqueRecord implements OpaqueBatchRecord {
  _OpaqueRecord(
    RenderItem item,
    Geometry geometry,
    Material material,
    this.fade,
    gpu.RenderPipeline pipeline,
    this.pipelineKey,
    this.depth,
    this.windingFlipped,
  ) : _item = item,
      _geometry = geometry,
      _material = material,
      _pipeline = pipeline;
  RenderItem? _item;
  RenderItem get item => _item!;
  // The geometry and material to draw, which differ from the item's own when
  // a level of detail was selected.
  Geometry? _geometry;
  @override
  Geometry get geometry => _geometry!;
  Material? _material;
  @override
  Material get material => _material!;
  // LOD cross-fade coverage for this draw (1 when not fading); see
  // [Material.lodFade].
  @override
  late double fade;
  gpu.RenderPipeline? _pipeline;
  @override
  gpu.RenderPipeline get pipeline => _pipeline!;
  late int pipelineKey;
  late double depth;
  late bool windingFlipped;

  void reset(
    RenderItem item,
    Geometry geometry,
    Material material,
    double fade,
    gpu.RenderPipeline pipeline,
    int pipelineKey,
    double depth,
    bool windingFlipped,
  ) {
    _item = item;
    _geometry = geometry;
    _material = material;
    this.fade = fade;
    _pipeline = pipeline;
    this.pipelineKey = pipelineKey;
    this.depth = depth;
    this.windingFlipped = windingFlipped;
  }

  int get geometryKey => identityHashCode(geometry);
  int get materialKey => identityHashCode(material);
  @override
  int get lightListOffset => item.lightListOffset;
  @override
  int get lightListCount => item.lightListCount;
  @override
  int get lightChannelMask => item.lightChannelMask;
  @override
  Object? get jointsTexture => item.jointsTexture;
  @override
  Object? get morphWeights => item.morphWeights;

  void release() {
    _item = null;
    _geometry = null;
    _material = null;
    _pipeline = null;
  }
}

/// A deferred translucent draw. Instanced draws retain their item so their
/// transforms can be sorted while the instance buffer is packed.
base class _TranslucentRecord {
  _TranslucentRecord(
    RenderItem item,
    Matrix4 worldTransform,
    Geometry geometry,
    Material material,
    this.fade,
    gpu.RenderPipeline pipeline,
    this.depth,
    this.windingFlipped,
    this.lightListOffset,
    this.lightListCount,
    this.jointsTexture,
    this.jointsTextureWidth,
  ) : _item = item,
      _worldTransform = worldTransform,
      _geometry = geometry,
      _material = material,
      _pipeline = pipeline;
  RenderItem? _item;
  RenderItem get item => _item!;
  Matrix4? _worldTransform;
  Matrix4 get worldTransform => _worldTransform!;
  Geometry? _geometry;
  Geometry get geometry => _geometry!;
  Material? _material;
  Material get material => _material!;
  late double fade;
  gpu.RenderPipeline? _pipeline;
  gpu.RenderPipeline get pipeline => _pipeline!;
  late double depth;
  late bool windingFlipped;
  // The owning item's punctual-light slice, captured at submit time.
  late int lightListOffset;
  late int lightListCount;
  // The owning item's joints texture, applied to the geometry right before
  // this draw so skinned items sharing one geometry keep their own skeleton.
  late gpu.Texture? jointsTexture;
  late int jointsTextureWidth;
  ui.Rect? screenBounds;
  ui.Rect? sceneColorSampleBounds;

  void reset(
    RenderItem item,
    Matrix4 worldTransform,
    Geometry geometry,
    Material material,
    double fade,
    gpu.RenderPipeline pipeline,
    double depth,
    bool windingFlipped,
    int lightListOffset,
    int lightListCount,
    gpu.Texture? jointsTexture,
    int jointsTextureWidth,
  ) {
    _item = item;
    _worldTransform = worldTransform;
    _geometry = geometry;
    _material = material;
    this.fade = fade;
    _pipeline = pipeline;
    this.depth = depth;
    this.windingFlipped = windingFlipped;
    this.lightListOffset = lightListOffset;
    this.lightListCount = lightListCount;
    this.jointsTexture = jointsTexture;
    this.jointsTextureWidth = jointsTextureWidth;
  }

  void release() {
    _item = null;
    _worldTransform = null;
    _geometry = null;
    _material = null;
    _pipeline = null;
    jointsTexture = null;
    screenBounds = null;
    sceneColorSampleBounds = null;
  }
}

const int _transmissionCoverageColumns = 32;
const int _transmissionCoverageRows = 32;

/// Maximum accumulated scene-color batches emitted in one frame.
const int maxSceneColorCaptureBatches = 8;

base class _ScreenCoverage {
  _ScreenCoverage(this.viewport);

  final ui.Size viewport;
  final Uint32List _rows = Uint32List(_transmissionCoverageRows);

  bool overlaps(ui.Rect bounds) {
    final cells = _cells(bounds);
    final mask = _columnMask(cells.left, cells.right);
    for (var row = cells.top; row <= cells.bottom; row++) {
      if ((_rows[row] & mask) != 0) return true;
    }
    return false;
  }

  void add(ui.Rect bounds) {
    final cells = _cells(bounds);
    final left = cells.left > 0 ? cells.left - 1 : 0;
    final right = cells.right + 1 < _transmissionCoverageColumns
        ? cells.right + 1
        : _transmissionCoverageColumns - 1;
    final top = cells.top > 0 ? cells.top - 1 : 0;
    final bottom = cells.bottom + 1 < _transmissionCoverageRows
        ? cells.bottom + 1
        : _transmissionCoverageRows - 1;
    final mask = _columnMask(left, right);
    for (var row = top; row <= bottom; row++) {
      _rows[row] |= mask;
    }
  }

  ({int left, int top, int right, int bottom}) _cells(ui.Rect bounds) {
    if (viewport.isEmpty || !bounds.isFinite || bounds.isEmpty) {
      return (
        left: 0,
        top: 0,
        right: _transmissionCoverageColumns - 1,
        bottom: _transmissionCoverageRows - 1,
      );
    }
    final left = (bounds.left / viewport.width * _transmissionCoverageColumns)
        .floor();
    final right =
        (bounds.right / viewport.width * _transmissionCoverageColumns).ceil() -
        1;
    final top = (bounds.top / viewport.height * _transmissionCoverageRows)
        .floor();
    final bottom =
        (bounds.bottom / viewport.height * _transmissionCoverageRows).ceil() -
        1;
    return (
      left: left.clamp(0, _transmissionCoverageColumns - 1),
      top: top.clamp(0, _transmissionCoverageRows - 1),
      right: right.clamp(0, _transmissionCoverageColumns - 1),
      bottom: bottom.clamp(0, _transmissionCoverageRows - 1),
    );
  }

  static int _columnMask(int left, int right) {
    final width = right - left + 1;
    if (width >= 32) return 0xffffffff;
    return ((1 << width) - 1) << left;
  }
}

int _sceneColorBatchEnd<T>(
  List<T> records,
  int cursor,
  ui.Size viewport, {
  required bool Function(T record) readsSceneColor,
  required ui.Rect Function(T record) outputBounds,
  required ui.Rect Function(T record) sampleBounds,
}) {
  final coverage = _ScreenCoverage(viewport);
  var end = cursor;
  while (end < records.length) {
    final record = records[end];
    if (end > cursor &&
        readsSceneColor(record) &&
        coverage.overlaps(sampleBounds(record))) {
      break;
    }
    coverage.add(outputBounds(record));
    end++;
  }
  return end;
}

/// Counts accumulated scene-color captures for sorted translucent draws.
@visibleForTesting
int sceneColorCaptureBatchCount(
  List<({ui.Rect bounds, bool readsSceneColor})> records,
  ui.Size viewport,
) {
  var cursor = 0;
  var batches = 0;
  while (cursor < records.length) {
    while (cursor < records.length && !records[cursor].readsSceneColor) {
      cursor++;
    }
    if (cursor == records.length) break;
    batches++;
    if (batches == maxSceneColorCaptureBatches) break;
    cursor = _sceneColorBatchEnd(
      records,
      cursor,
      viewport,
      readsSceneColor: (record) => record.readsSceneColor,
      outputBounds: (record) => record.bounds,
      sampleBounds: (record) => record.bounds,
    );
  }
  return batches;
}

/// The viewport size of the scene color pass currently being encoded.
///
/// Set by [SceneEncoder] at construction and read by geometry whose
/// projection math needs the pixel scale (splat footprints). Encoding is
/// single-threaded, so a frame-scoped module value is safe.
/// TODO(splats): thread the viewport through `Geometry.bind` instead once
/// another consumer appears.
ui.Size currentSceneEncoderViewport = ui.Size.zero;

/// Computes the view-axis depth used to order deferred scene draws: the
/// depth of the centre of [localBounds] placed by [worldTransform], less a
/// sort-depth [bias] (see [Node.sortDepthBias]).
double sceneSortDepth(
  Matrix4 worldTransform,
  Aabb3? localBounds,
  Vector3 cameraPosition,
  Vector3 cameraForward, {
  double bias = 0.0,
}) {
  final localCenter = localBounds?.center ?? Vector3.zero();
  final worldCenter = worldTransform.transformed3(localCenter);
  return (worldCenter - cameraPosition).dot(cameraForward) - bias;
}

/// One translucent draw of a scene, as [sceneTranslucentDraws] reads it.
final class SceneTranslucentDraw {
  SceneTranslucentDraw._(
    this.node,
    this.geometry,
    this.material,
    this.bounds,
    this.depth,
  );

  /// The node that draws it.
  final Node node;

  /// The geometry it draws.
  final Geometry geometry;

  /// The material it draws with.
  final Material material;

  /// The bounds the encoder culls and sorts it by, in the space of [node]:
  /// the geometry's, or those of every instance for an instanced mesh. Null
  /// when it has none.
  final Aabb3? bounds;

  /// The view-axis depth it sorts at, its node's sort-depth bias taken off.
  final double depth;
}

/// The translucent draws of the subtree of [root] that a view of [camera] at
/// [dimensions] through [layerMask] holds, farthest first: the order
/// [SceneEncoder] draws them in.
///
/// It reads the nodes as they stand, so it orders a frame before the frame
/// draws, as a pass that places its own translucent draws among the others
/// needs. It holds each visible translucent mesh primitive and instanced
/// mesh of a visible node whose layers meet [layerMask], whose material
/// draws, and whose bounds meet the view or whose node opts out of the
/// frustum cull. Each sorts at [sceneSortDepth] of its bounds less its
/// node's [Node.sortDepthBias]; an instanced mesh at the centre of its
/// instances. A level-of-detail node sorts by its base level.
///
/// It leaves out the encoder's level-of-detail selection and its
/// per-instance cull, so it may list more draws than the encoder makes: a
/// level-of-detail node is listed by its base level even when the encoder
/// draws another level or none, and an instanced mesh is listed even when
/// the encoder culls every instance.
List<SceneTranslucentDraw> sceneTranslucentDraws(
  Node root,
  Camera camera,
  ui.Size dimensions, {
  int layerMask = kRenderLayerAll,
}) {
  final eye = camera.position;
  final forward = camera.forward;
  final frustum = Frustum.matrix(camera.getViewTransform(dimensions));
  final draws = <SceneTranslucentDraw>[];
  final world = Aabb3();

  bool placed(Node node, Aabb3? bounds) {
    if (bounds == null) return true;
    world
      ..copyFrom(bounds)
      ..transform(node.globalTransform);
    return !node.frustumCulled || frustum.intersectsWithAabb3(world);
  }

  void visit(Node node) {
    if (!node.visible) return;
    if (node.layers & layerMask != 0) {
      final transform = node.globalTransform;
      final bias = node.sortDepthBias;
      for (final component in node.getComponents<MeshComponent>()) {
        for (final primitive in component.mesh.primitives) {
          final material = primitive.material;
          if (!primitive.visible ||
              material.drawsNothing ||
              material.isOpaque()) {
            continue;
          }
          final bounds = primitive.geometry.localBounds;
          if (!placed(node, bounds)) continue;
          draws.add(
            SceneTranslucentDraw._(
              node,
              primitive.geometry,
              material,
              bounds,
              sceneSortDepth(transform, bounds, eye, forward, bias: bias),
            ),
          );
        }
      }
      for (final component in node.getComponents<InstancedMeshComponent>()) {
        final instanced = component.instancedMesh;
        final material = instanced.material;
        if (instanced.instanceCount == 0 ||
            material.drawsNothing ||
            material.isOpaque()) {
          continue;
        }
        final bounds = instanced.aggregateBounds;
        if (!placed(node, bounds)) continue;
        draws.add(
          SceneTranslucentDraw._(
            node,
            instanced.geometry,
            material,
            bounds,
            bounds == null
                ? sceneSortDepth(transform, null, eye, forward, bias: bias)
                : (world.center - eye).dot(forward) - bias,
          ),
        );
      }
    }
    node.children.forEach(visit);
  }

  visit(root);
  return draws..sort((a, b) => _farthestFirst(a.depth, b.depth));
}

int _farthestFirst(double a, double b) => b.compareTo(a);

/// Render pipelines keyed by their (vertex shader, fragment shader, vertex
/// layout) triple.
///
/// A pipeline depends on its two shaders and its vertex layout (blend,
/// depth, and cull state are set on the render pass, not baked into the
/// pipeline). Shaders are loaded once and reused and layouts are interned to
/// a small stable id, so pipelines are cached for the process lifetime
/// instead of being rebuilt per draw call. The layout is part of the key
/// because one vertex shader can be drawn with more than one layout (for
/// example the same shader fed a single-buffer or a position-split layout);
/// keying on the shader pair alone would serve the wrong pipeline.
final Map<(gpu.Shader, gpu.Shader, int), gpu.RenderPipeline> _pipelineCache =
    {};

/// Returns the cached render pipeline for ([vertexShader], [fragmentShader],
/// [vertexLayout]), building and caching it on first use.
///
/// A `null` [vertexLayout] uses the shader bundle's reflection-derived
/// default layout (the skinned path); a described layout is lowered to the
/// flutter_gpu layout once, on the cache miss.
gpu.RenderPipeline resolvePipeline(
  gpu.Shader vertexShader,
  gpu.Shader fragmentShader, {
  VertexLayoutDescriptor? vertexLayout,
}) {
  final key = (vertexShader, fragmentShader, vertexLayoutId(vertexLayout));
  return _pipelineCache[key] ??= _buildPipeline(
    vertexShader,
    fragmentShader,
    vertexLayout,
  );
}

gpu.RenderPipeline _buildPipeline(
  gpu.Shader vertexShader,
  gpu.Shader fragmentShader,
  VertexLayoutDescriptor? vertexLayout,
) {
  _scenePipelinesBuilt++;
  return gpu.gpuContext.createRenderPipeline(
    vertexShader,
    fragmentShader,
    vertexLayout: vertexLayout?.toGpuLayout(),
  );
}

int _scenePipelinesBuilt = 0;

/// The number of render pipelines the scene's passes have built in this
/// process: the color, depth prepass and shadow caster draws and the
/// full-screen passes that share their pipeline cache. A render that leaves it unchanged built
/// none of them, so a frame after `Scene.unbuiltPipelines` listed nothing
/// keeps it.
int get scenePipelinesBuilt => _scenePipelinesBuilt;

/// What keys a render pipeline: the vertex shader, the fragment shader, and
/// the vertex layout a draw binds.
typedef PipelineInputs = ({
  gpu.Shader vertexShader,
  gpu.Shader fragmentShader,
  VertexLayoutDescriptor? vertexLayout,
});

/// The pipeline inputs of a color-pass draw of [geometry] with [material]
/// under [lighting], as [SceneEncoder] resolves them.
///
/// A material with a `vertex { }` block supplies its own vertex shader for
/// the geometry's mesh type, otherwise the geometry's standard one runs. The
/// fragment shader is the material's variant for the lighting (its shadow and
/// radiance layout twins). A material declaring `instance_attributes` widens
/// the instance-rate slot, so the layout depends on the material as well as
/// the geometry.
PipelineInputs colorPipelineInputs(
  Geometry geometry,
  Material material,
  Lighting lighting,
) => (
  vertexShader:
      material.vertexShaderForGeometry(geometry) ?? geometry.vertexShader,
  fragmentShader: material.fragmentShaderForLighting(lighting),
  vertexLayout: geometry.instancedVertexLayoutFor(material.instanceAttributes),
);

/// Returns the cached render pipeline for [inputs], building it on first use.
gpu.RenderPipeline resolvePipelineFor(PipelineInputs inputs) => resolvePipeline(
  inputs.vertexShader,
  inputs.fragmentShader,
  vertexLayout: inputs.vertexLayout,
);

/// Whether the process holds the render pipeline for [inputs], so a draw that
/// binds it builds none.
bool isPipelineBuilt(PipelineInputs inputs) => _pipelineCache.containsKey((
  inputs.vertexShader,
  inputs.fragmentShader,
  vertexLayoutId(inputs.vertexLayout),
));

/// Whether the process holds the color-pass pipeline of every geometry and
/// material [item] can draw with under [lighting]: its own, or each level of
/// its level of detail. A view then records no unbuilt draw of [item],
/// whatever its culling selects.
bool colorPipelinesBuilt(RenderItem item, Lighting lighting) {
  final lod = item.lod;
  if (lod == null) {
    return isPipelineBuilt(
      colorPipelineInputs(item.geometry, item.material, lighting),
    );
  }
  for (final level in lod.levels) {
    if (!isPipelineBuilt(
      colorPipelineInputs(level.geometry, level.material, lighting),
    )) {
      return false;
    }
  }
  return true;
}

/// Calls [draw] with each geometry and material the color pass records for
/// [item], and the cross-fade coverage of each, in a view culled by
/// [frustum]: nothing when the item is hidden, its layers miss [layerMask], or
/// (with [cullInstances]) none of its instances is inside the frustum and
/// [cullingPlanes]; each selected level of a level-of-detail item, by its
/// projected size from [cameraPosition] at [lodFovRadiansY] (the highest
/// level without a perspective field of view); else the item's own geometry
/// and material.
///
/// [SceneEncoder.submit] selects its draws here, and so does
/// `Scene.unbuiltPipelines`.
void selectColorDraws(
  RenderItem item, {
  required Frustum frustum,
  required int layerMask,
  required List<Plane> cullingPlanes,
  required bool cullInstances,
  required Vector3 cameraPosition,
  required double? lodFovRadiansY,
  required void Function(
    RenderItem item,
    Geometry geometry,
    Material material,
    double fade,
  )
  draw,
}) {
  if (!item.visible || !item.primitiveVisible) return;
  if ((item.layers & layerMask) == 0) return;
  if (cullInstances) {
    if (!item.cullVisibleInstances(frustum, cullingPlanes)) return;
  } else {
    item.visibleInstanceIndices = null;
  }

  // The render scene already rejected this item through its BVH. Reuse its
  // retained world bounds for the LOD metric instead of transforming again.
  final lod = item.lod;
  if (lod == null) {
    draw(item, item.geometry, item.material, 1.0);
    return;
  }
  // Queue the level(s) of detail to draw (or cull). A cross-fading node
  // returns its two adjacent levels with complementary dither coverage.
  final worldBounds = item.worldBounds;
  final List<({int level, double fade})> selections;
  if (worldBounds == null || lodFovRadiansY == null) {
    selections = const [(level: 0, fade: 1.0)];
  } else {
    // The circumscribed sphere of the world AABB (conservative, so detail is
    // kept slightly longer than a tight sphere would).
    selections = lod.resolve(
      lodScreenSize(
        center: worldBounds.center,
        radius: worldBounds.max.distanceTo(worldBounds.min) * 0.5,
        cameraPosition: cameraPosition,
        fovRadiansY: lodFovRadiansY,
      ),
    );
  }
  for (final selection in selections) {
    final level = lod.levels[selection.level];
    draw(item, level.geometry, level.material, selection.fade);
  }
}

/// Drops cached pipelines that use any of [shaders] (as vertex or fragment) so
/// the next draw rebuilds them.
///
/// Used after an in-place shader hot reload: `ShaderLibrary.reinitialize`
/// reloads a [gpu.Shader]'s code while keeping its Dart identity, so the
/// pipeline cache (keyed by the shader pair) would otherwise keep serving a
/// pipeline built from the old code. Hidden from the public surface; called by
/// the hot-reload coordinator.
void evictPipelinesForShaders(Set<gpu.Shader> shaders) {
  if (shaders.isEmpty) return;
  _pipelineCache.removeWhere(
    (key, _) => shaders.contains(key.$1) || shaders.contains(key.$2),
  );
}

/// Records draw calls for one frame's color pass into a single
/// `gpu.RenderPass`.
///
/// A render-graph pass (see `ScenePass`) creates a `gpu.RenderPass`,
/// constructs an encoder against it, calls [submit] for every
/// [RenderItem] the scene's spatial structure reports visible, then calls
/// [flush] to sort and emit the deferred draws.
///
/// The encoder splits draws into two phases within the one render pass:
///
/// 1. **Opaque**, with depth writes enabled and color blending disabled,
///    sorted by pipeline (to reduce state changes) and then front-to-back
///    (so the depth test can reject occluded fragments early).
/// 2. **Translucent**, depth-sorted back to front from the camera, drawn
///    with premultiplied source-over blending.
///
/// Applications typically do not construct `SceneEncoder` directly;
/// custom [Geometry] or [Material] subclasses interact with it through
/// their `bind` callbacks, which receive the `gpu.RenderPass` and
/// `TransientWriter` directly.
base class SceneEncoder {
  static final RenderProfileAccumulator _profile = RenderProfileAccumulator();
  int _instancePackMicros = 0;
  int _instanceBindMicros = 0;
  int _instanceBytes = 0;
  int _opaqueSortMicros = 0;
  int _opaqueEncodeMicros = 0;

  /// Creates an encoder that records into [renderPass], allocating
  /// transient uniforms from [transientsBuffer].
  ///
  /// `dimensions` is the viewport size used to derive the camera's view
  /// transform; [lighting] is the scene's IBL environment and analytic
  /// lights, passed to each material's `bind`. The render pass is
  /// configured for the opaque phase (depth writes on, blending off).
  SceneEncoder(
    gpu.RenderPass renderPass,
    TransientWriter transientsBuffer,
    this._camera,
    this._dimensions,
    this._lighting,
    this._layerMask,
    this._cullingPlanes,
    this._cullInstances, {
    Matrix4? cameraTransform,
  }) : _renderPass = renderPass,
       _transientsBuffer = transientsBuffer {
    currentSceneEncoderViewport = _dimensions;
    _cameraTransform = cameraTransform ?? _camera.getViewTransform(_dimensions);
    frustum = Frustum.matrix(_cameraTransform);
    // The screen-size LOD metric is perspective-specific; with any other
    // projection LOD nodes draw their highest-detail level.
    final camera = _camera;
    _lodFovRadiansY = camera is PerspectiveCamera ? camera.fovRadiansY : null;

    // Begin the opaque phase.
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(false);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
  }

  final Camera _camera;
  final ui.Size _dimensions;
  final Lighting _lighting;
  final int _layerMask;
  final List<Plane> _cullingPlanes;
  final bool _cullInstances;
  // Not final because opaque and translucent draws can use separate passes.
  gpu.RenderPass _renderPass;
  final TransientWriter _transientsBuffer;
  late final Matrix4 _cameraTransform;
  // The camera's vertical field of view in radians, or null for a
  // non-perspective camera (which disables screen-size LOD).
  late final double? _lodFovRadiansY;
  final List<_OpaqueRecord> _opaqueRecords = [];
  final List<_TranslucentRecord> _translucentRecords = [];
  static final List<_OpaqueRecord> _opaqueRecordPool = [];
  static final List<_TranslucentRecord> _translucentRecordPool = [];
  static const int _recordPoolLimit = 8192;

  /// View frustum derived from the camera's view-projection matrix at
  /// the start of this frame. Used by [submit] for per-item culling.
  late final Frustum frustum;

  // The pipeline currently bound on the render pass, or null before the
  // first bind. `clearBindings` does not clear the pipeline, so a draw
  // that reuses it can skip the rebind. Opaque draws are pipeline-sorted,
  // so reuse runs are common.
  gpu.RenderPipeline? _boundPipeline;
  Material? _boundMaterial;
  gpu.Shader? _boundMaterialVertex;
  gpu.Shader? _boundFrameInfoShader;
  double _boundFrameInfoDepthBias = double.nan;
  double _boundMaterialFade = double.nan;
  int _boundMaterialLightOffset = -1;
  int _boundMaterialLightCount = -1;
  int _boundMaterialLightChannelMask = -1;
  gpu.WindingOrder? _boundWindingOrder;
  gpu.PrimitiveType? _boundPrimitiveType;
  int _encodedDraws = 0;
  int _encodedInstances = 0;

  /// Queues a draw call for [item], unless it is hidden or frustum
  /// culled.
  ///
  /// Both opaque and translucent draws are deferred; [flush] sorts and
  /// emits them. A translucent instanced item is queued as one draw per
  /// instance so each can be depth-sorted independently.
  void submit(RenderItem item) => selectColorDraws(
    item,
    frustum: frustum,
    layerMask: _layerMask,
    cullingPlanes: _cullingPlanes,
    cullInstances: _cullInstances,
    cameraPosition: _camera.position,
    lodFovRadiansY: _lodFovRadiansY,
    draw: _recordDraw,
  );

  late final _recordDraw = _record;

  // Queues a single draw for [item] using the already-LOD-resolved [geometry]
  // and [material] at cross-fade coverage [fade].
  void _record(
    RenderItem item,
    Geometry geometry,
    Material material,
    double fade,
  ) {
    final pipeline = resolvePipelineFor(
      colorPipelineInputs(geometry, material, _lighting),
    );

    if (material.isOpaque()) {
      _opaqueRecords.add(
        _obtainOpaqueRecord(
          item,
          geometry,
          material,
          fade,
          pipeline,
          identityHashCode(pipeline),
          _depthOf(item, geometry),
          item.windingFor(geometry),
        ),
      );
      return;
    }

    // Keep instanced translucency in one record. The instances are sorted
    // back to front while their transform buffer is packed at draw time.
    final instances = item.instanceTransforms;
    if (instances != null) {
      final bounds = item.worldBounds;
      _translucentRecords.add(
        _obtainTranslucentRecord(
          item,
          item.worldTransform,
          geometry,
          material,
          fade,
          pipeline,
          bounds == null
              ? _depthOf(item)
              : _depthOfPoint(
                      (bounds.min.x + bounds.max.x) * 0.5,
                      (bounds.min.y + bounds.max.y) * 0.5,
                      (bounds.min.z + bounds.max.z) * 0.5,
                    ) -
                    item.sortDepthBias,
          item.windingFor(geometry),
          item.lightListOffset,
          item.lightListCount,
          item.jointsTexture,
          item.jointsTextureWidth,
        ),
      );
    } else {
      _translucentRecords.add(
        _obtainTranslucentRecord(
          item,
          item.worldTransform,
          geometry,
          material,
          fade,
          pipeline,
          _depthOf(item, geometry),
          item.windingFor(geometry),
          item.lightListOffset,
          item.lightListCount,
          item.jointsTexture,
          item.jointsTextureWidth,
        ),
      );
    }
  }

  _OpaqueRecord _obtainOpaqueRecord(
    RenderItem item,
    Geometry geometry,
    Material material,
    double fade,
    gpu.RenderPipeline pipeline,
    int pipelineKey,
    double depth,
    bool windingFlipped,
  ) {
    if (_opaqueRecordPool.isEmpty) {
      return _OpaqueRecord(
        item,
        geometry,
        material,
        fade,
        pipeline,
        pipelineKey,
        depth,
        windingFlipped,
      );
    }
    return _opaqueRecordPool.removeLast()..reset(
      item,
      geometry,
      material,
      fade,
      pipeline,
      pipelineKey,
      depth,
      windingFlipped,
    );
  }

  _TranslucentRecord _obtainTranslucentRecord(
    RenderItem item,
    Matrix4 worldTransform,
    Geometry geometry,
    Material material,
    double fade,
    gpu.RenderPipeline pipeline,
    double depth,
    bool windingFlipped,
    int lightListOffset,
    int lightListCount,
    gpu.Texture? jointsTexture,
    int jointsTextureWidth,
  ) {
    if (_translucentRecordPool.isEmpty) {
      return _TranslucentRecord(
        item,
        worldTransform,
        geometry,
        material,
        fade,
        pipeline,
        depth,
        windingFlipped,
        lightListOffset,
        lightListCount,
        jointsTexture,
        jointsTextureWidth,
      );
    }
    return _translucentRecordPool.removeLast()..reset(
      item,
      worldTransform,
      geometry,
      material,
      fade,
      pipeline,
      depth,
      windingFlipped,
      lightListOffset,
      lightListCount,
      jointsTexture,
      jointsTextureWidth,
    );
  }

  double _depthOf(RenderItem item, [Geometry? geometry]) {
    return sceneSortDepth(
      item.worldTransform,
      geometry?.localBounds,
      _camera.position,
      _camera.forward,
      bias: item.sortDepthBias,
    );
  }

  double _depthOfPoint(double x, double y, double z) {
    return (Vector3(x, y, z) - _camera.position).dot(_camera.forward);
  }

  // Binds [pipeline] unless it is already the bound one. `clearBindings`
  // leaves the pipeline in place, so consecutive draws that share a
  // pipeline only need to bind it once.
  void _bindPipeline(gpu.RenderPipeline pipeline) {
    if (identical(_boundPipeline, pipeline)) return;
    _renderPass.bindPipeline(pipeline);
    _boundPipeline = pipeline;
  }

  // Drops the pass's bindings. The engine-lighting memo tracks what is
  // already bound on the pass, so it has to be forgotten here or the next
  // draw skips rebinding slots that were just wiped; never call
  // `clearBindings` directly.
  void _clearBindings() {
    _renderPass.clearBindings();
    EngineLightingUniforms.invalidateBindMemo();
    _boundMaterial = null;
    _boundMaterialVertex = null;
    _boundFrameInfoShader = null;
    _boundFrameInfoDepthBias = double.nan;
    _boundMaterialFade = double.nan;
    _boundMaterialLightOffset = -1;
    _boundMaterialLightCount = -1;
    _boundMaterialLightChannelMask = -1;
    _boundWindingOrder = null;
    _boundPrimitiveType = null;
  }

  void _bindMaterial(
    Material material,
    gpu.Shader? materialVertex,
    double fade,
  ) {
    final lightOffset = material.lightListOffset;
    final lightCount = material.lightListCount;
    final lightChannelMask = material.lightChannelMask;
    if (identical(_boundMaterial, material) &&
        identical(_boundMaterialVertex, materialVertex) &&
        _boundMaterialFade == fade &&
        _boundMaterialLightOffset == lightOffset &&
        _boundMaterialLightCount == lightCount &&
        _boundMaterialLightChannelMask == lightChannelMask) {
      return;
    }
    material.lodFade = fade;
    material.bind(_renderPass, _transientsBuffer, _lighting);
    _boundWindingOrder = null;
    if (materialVertex != null) {
      material.bindVertexStage(_renderPass, materialVertex, _transientsBuffer);
    }
    _boundMaterial = material;
    _boundMaterialVertex = materialVertex;
    _boundMaterialFade = fade;
    _boundMaterialLightOffset = lightOffset;
    _boundMaterialLightCount = lightCount;
    _boundMaterialLightChannelMask = lightChannelMask;
  }

  void _setWindingOrder(gpu.WindingOrder windingOrder) {
    if (_boundWindingOrder == windingOrder) return;
    _renderPass.setWindingOrder(windingOrder);
    _boundWindingOrder = windingOrder;
  }

  void _setPrimitiveType(gpu.PrimitiveType primitiveType) {
    if (_boundPrimitiveType == primitiveType) return;
    _renderPass.setPrimitiveType(primitiveType);
    _boundPrimitiveType = primitiveType;
  }

  void _bindGeometry(
    Geometry geometry,
    Matrix4 worldTransform,
    gpu.Shader? materialVertex,
    double depthBias,
  ) {
    // Morphed geometry takes the full bind, which also binds its morph stage.
    if (geometry is UnskinnedGeometry && geometry.morphTargets == null) {
      geometry.bindGeometryBuffers(_renderPass);
      final shader = materialVertex ?? geometry.vertexShader;
      if (!identical(_boundFrameInfoShader, shader) ||
          _boundFrameInfoDepthBias != depthBias) {
        bindUnskinnedFrameInfo(
          _renderPass,
          _transientsBuffer,
          shader,
          _cameraTransform,
          _camera.position,
          depthBias: depthBias,
        );
        _boundFrameInfoShader = shader;
        _boundFrameInfoDepthBias = depthBias;
      }
    } else {
      geometry.bind(
        _renderPass,
        _transientsBuffer,
        worldTransform,
        _cameraTransform,
        _camera.position,
        shaderOverride: materialVertex,
        depthBias: depthBias,
      );
    }
  }

  void _bindPackedInstances(Float32List packed, int slot) {
    final watch = profileRendering ? (Stopwatch()..start()) : null;
    bindInstanceData(_renderPass, packed, slot: slot);
    if (profileRendering) {
      watch!.stop();
      _instanceBindMicros += watch.elapsedMicroseconds;
      _instanceBytes += packed.lengthInBytes;
    }
  }

  void _drawGeometry(Geometry geometry, {int instanceCount = 1}) {
    if (profileRendering) {
      _encodedDraws++;
      _encodedInstances += instanceCount;
    }
    geometry.draw(_renderPass, instanceCount: instanceCount);
  }

  void _encode(
    gpu.RenderPipeline pipeline,
    Matrix4 worldTransform,
    Geometry geometry,
    Material material,
    bool windingFlipped,
    double fade,
  ) {
    // Bindings persist across draws within a pass, and every draw binds its
    // full slot set, so clearing is only needed when the pipeline (and with
    // it the shaders' slot layouts) changes; a stale entry from a different
    // layout could otherwise leak into the next command. Opaque draws are
    // pipeline-sorted, so same-pipeline runs skip the clear, which lets the
    // per-draw engine-lighting rebind be skipped too (see
    // EngineLightingUniforms); each bind marshals its slot name across the
    // FFI, and re-issuing the full set per item dominated main-thread frame
    // time in draw-heavy scenes.
    if (!identical(_boundPipeline, pipeline)) {
      _clearBindings();
    }
    _bindPipeline(pipeline);
    // A `vertex { }` material supplies its own vertex shader for this mesh
    // type; the geometry must bind FrameInfo (and skinned's joints texture)
    // against it, since its uniform slots can differ from the engine default.
    final materialVertex = material.vertexShaderForGeometry(geometry);
    _bindGeometry(geometry, worldTransform, materialVertex, material.depthBias);
    if (geometry.bindsModelTransformInstance) {
      // The model matrix arrives through the instance-rate vertex buffer,
      // bound to the slot after the geometry's vertex streams.
      bindSingleInstanceData(
        _renderPass,
        worldTransform,
        slot: geometry.vertexStreamCount,
        // A single draw has no per-instance source, so declared attributes
        // read zero.
        attributeFloats: material.instanceAttributes?.floatCount ?? 0,
      );
    }
    _bindMaterial(material, materialVertex, fade);
    // A mirrored transform reverses triangle winding. Set both cases because
    // a cached material bind no longer resets it between compatible draws.
    _setWindingOrder(
      windingFlipped
          ? gpu.WindingOrder.counterClockwise
          : gpu.WindingOrder.clockwise,
    );
    _setPrimitiveType(geometry.primitiveType);
    _drawGeometry(geometry);
  }

  /// Draws an opaque instanced item with hardware instancing: the instance
  /// world transforms are packed into an instance-rate vertex buffer and the
  /// whole set draws with one call per winding-parity group (mirrored
  /// instances reverse triangle winding, so they draw as a second group
  /// under the flipped winding order).
  ///
  /// Geometry without an instanced vertex layout (skinned) falls back to a
  /// per-instance loop through the per-draw uniform path.
  void _encodeInstanced(
    gpu.RenderPipeline pipeline,
    Matrix4 nodeTransform,
    Geometry geometry,
    Material material,
    List<Matrix4> instances,
    List<Vector4> colors,
    bool windingFlipped,
    double fade, {
    List<bool>? instanceWindingFlipped,
    List<int>? instanceIndices,
    Vector3? sortBackToFrontFrom,
    Float32List? packedWorldData,
    Uint8List? packedWorldWindingFlipped,
    Float32List? attributeData,
    int attributeFloats = 0,
  }) {
    checkInstanceRecordWidth(material.instanceAttributes, attributeFloats);
    if (!identical(_boundPipeline, pipeline)) {
      _clearBindings();
    }
    _bindPipeline(pipeline);
    final materialVertex = material.vertexShaderForGeometry(geometry);
    _bindMaterial(material, materialVertex, fade);
    _setPrimitiveType(geometry.primitiveType);

    if (geometry.instancedVertexLayout == null) {
      final count = instanceIndices?.length ?? instances.length;
      for (var slot = 0; slot < count; slot++) {
        final instanceIndex = instanceIndices?[slot] ?? slot;
        final instanceTransform = instances[instanceIndex];
        _bindGeometry(
          geometry,
          nodeTransform * instanceTransform,
          materialVertex,
          material.depthBias,
        );
        // Each instance can itself mirror; combine with the node's parity.
        final flip = windingFlipped != (instanceTransform.determinant() < 0);
        _setWindingOrder(
          flip ? gpu.WindingOrder.counterClockwise : gpu.WindingOrder.clockwise,
        );
        _drawGeometry(geometry);
      }
      return;
    }

    _bindGeometry(geometry, nodeTransform, materialVertex, material.depthBias);
    final packWatch = profileRendering ? (Stopwatch()..start()) : null;
    final packed =
        sortBackToFrontFrom == null &&
            packedWorldData != null &&
            packedWorldWindingFlipped != null
        ? packInstanceDataBatches(
            [
              InstanceDataBatch.cached(
                packedWorldData: packedWorldData,
                packedWindingFlipped: packedWorldWindingFlipped,
                indices: instanceIndices,
                attributeFloats: attributeFloats,
              ),
            ],
            attributeFloats: attributeFloats,
            scratch: transientInstancePackingScratch,
          )
        : packInstanceData(
            nodeTransform,
            instances,
            colors,
            nodeWindingFlipped: windingFlipped,
            instanceWindingFlipped: instanceWindingFlipped,
            indices: instanceIndices,
            sortBackToFrontFrom: sortBackToFrontFrom,
            attributeData: attributeData,
            attributeFloats: attributeFloats,
            scratch: transientInstancePackingScratch,
          );
    if (profileRendering) {
      packWatch!.stop();
      _instancePackMicros += packWatch.elapsedMicroseconds;
    }
    final instanceSlot = geometry.vertexStreamCount;
    if (packed.ccwCount > 0) {
      _bindPackedInstances(packed.ccw, instanceSlot);
      _setWindingOrder(gpu.WindingOrder.clockwise);
      _drawGeometry(geometry, instanceCount: packed.ccwCount);
    }
    if (packed.cwCount > 0) {
      _bindPackedInstances(packed.cw, instanceSlot);
      _setWindingOrder(gpu.WindingOrder.counterClockwise);
      _drawGeometry(geometry, instanceCount: packed.cwCount);
    }
  }

  void _encodeInstancedBatches(
    gpu.RenderPipeline pipeline,
    Geometry geometry,
    Material material,
    List<InstanceDataBatch> batches,
    double fade,
  ) {
    // Cross-node batching synthesizes instances, so a material declaring
    // per-instance attributes is kept out of it (see opaqueBatchEnd).
    assert(material.instanceAttributes == null);
    if (!identical(_boundPipeline, pipeline)) {
      _clearBindings();
    }
    _bindPipeline(pipeline);
    final materialVertex = material.vertexShaderForGeometry(geometry);
    _bindMaterial(material, materialVertex, fade);
    _setPrimitiveType(geometry.primitiveType);
    _bindGeometry(
      geometry,
      _identityTransform,
      materialVertex,
      material.depthBias,
    );
    final packWatch = profileRendering ? (Stopwatch()..start()) : null;
    final packed = packInstanceDataBatches(
      batches,
      scratch: transientInstancePackingScratch,
    );
    if (profileRendering) {
      packWatch!.stop();
      _instancePackMicros += packWatch.elapsedMicroseconds;
    }
    final instanceSlot = geometry.vertexStreamCount;
    if (packed.ccwCount > 0) {
      _bindPackedInstances(packed.ccw, instanceSlot);
      _setWindingOrder(gpu.WindingOrder.clockwise);
      _drawGeometry(geometry, instanceCount: packed.ccwCount);
    }
    if (packed.cwCount > 0) {
      _bindPackedInstances(packed.cw, instanceSlot);
      _setWindingOrder(gpu.WindingOrder.counterClockwise);
      _drawGeometry(geometry, instanceCount: packed.cwCount);
    }
  }

  static final Matrix4 _identityTransform = Matrix4.identity();

  /// Sorts and emits every deferred draw, then finishes recording.
  ///
  /// Opaque draws are sorted by pipeline (state-change grouping) and then
  /// front-to-back (early-Z), and drawn first. Translucent draws are then
  /// sorted back-to-front and drawn with premultiplied source-over
  /// blending and depth writes disabled. After this returns the encoder
  /// has finished recording into its render pass; the caller submits the
  /// owning command buffer.
  void flush() {
    flushOpaque();
    flushTranslucent();
  }

  /// Emits only the opaque phase (see [flush]). Used with [flushTranslucent]
  /// when the scene pass snapshots the opaque color between them.
  void flushOpaque() {
    final sortWatch = profileRendering ? (Stopwatch()..start()) : null;
    _opaqueRecords.sort((a, b) {
      final byPipeline = a.pipelineKey.compareTo(b.pipelineKey);
      if (byPipeline != 0) return byPipeline;
      final byMaterial = a.materialKey.compareTo(b.materialKey);
      if (byMaterial != 0) return byMaterial;
      final byGeometry = a.geometryKey.compareTo(b.geometryKey);
      if (byGeometry != 0) return byGeometry;
      final byLightOffset = a.item.lightListOffset.compareTo(
        b.item.lightListOffset,
      );
      if (byLightOffset != 0) return byLightOffset;
      final byLightCount = a.item.lightListCount.compareTo(
        b.item.lightListCount,
      );
      if (byLightCount != 0) return byLightCount;
      final byChannels = a.item.lightChannelMask.compareTo(
        b.item.lightChannelMask,
      );
      if (byChannels != 0) return byChannels;
      final byFade = a.fade.compareTo(b.fade);
      if (byFade != 0) return byFade;
      return a.depth.compareTo(b.depth);
    });
    sortWatch?.stop();
    final encodeWatch = profileRendering ? (Stopwatch()..start()) : null;
    var index = 0;
    while (index < _opaqueRecords.length) {
      final record = _opaqueRecords[index];
      final item = record.item;
      record.material.lightListOffset = item.lightListOffset;
      record.material.lightListCount = item.lightListCount;
      record.material.lightChannelMask = item.lightChannelMask;
      record.material.setModelScaleFromTransform(item.worldTransform);
      item.applyJointsTexture(record.geometry);
      item.applyMorphWeights(record.geometry);

      final end = opaqueBatchEnd(_opaqueRecords, index);
      if (end > index + 1) {
        final batches = <InstanceDataBatch>[];
        for (var batchIndex = index; batchIndex < end; batchIndex++) {
          final item = _opaqueRecords[batchIndex].item;
          batches.add(
            instanceDataBatchFor(
              item,
              indices: item.visibleInstanceIndices,
              windingFlipped: _opaqueRecords[batchIndex].windingFlipped,
            ),
          );
        }
        _encodeInstancedBatches(
          record.pipeline,
          record.geometry,
          record.material,
          batches,
          record.fade,
        );
        index = end;
        continue;
      }

      final instances = item.instanceTransforms;
      if (instances != null) {
        _encodeInstanced(
          record.pipeline,
          item.worldTransform,
          record.geometry,
          record.material,
          instances,
          item.instanceColors!,
          record.windingFlipped,
          record.fade,
          instanceWindingFlipped: item.instanceWindingFlipped,
          instanceIndices: item.visibleInstanceIndices,
          packedWorldData: record.windingFlipped == item.windingFlipped
              ? item.instanceWorldData
              : null,
          packedWorldWindingFlipped:
              record.windingFlipped == item.windingFlipped
              ? item.instanceWorldWindingFlipped
              : null,
          attributeData: item.instanceAttributeData,
          attributeFloats: item.instanceAttributeFloats,
        );
      } else {
        _encode(
          record.pipeline,
          item.worldTransform,
          record.geometry,
          record.material,
          record.windingFlipped,
          record.fade,
        );
      }
      index++;
    }
    encodeWatch?.stop();
    if (profileRendering) {
      _opaqueSortMicros = sortWatch!.elapsedMicroseconds;
      _opaqueEncodeMicros = encodeWatch!.elapsedMicroseconds;
    }
    for (final record in _opaqueRecords) {
      if (_opaqueRecordPool.length == _recordPoolLimit) break;
      record.release();
      _opaqueRecordPool.add(record);
    }
    _opaqueRecords.clear();
  }

  void _recordProfile(
    int sortMicros,
    int encodeMicros,
    int draws,
    int instances,
  ) {
    _profile.add('sort', sortMicros);
    _profile.add('encode', encodeMicros);
    _profile.add('instance_pack', _instancePackMicros, trackMax: true);
    _profile.add('instance_bind', _instanceBindMicros);
    _profile.add('instance_bytes', _instanceBytes);
    _profile.add('draws', draws);
    _profile.add('instances', instances);
    final snapshot = _profile.endSample();
    _instancePackMicros = 0;
    _instanceBindMicros = 0;
    _instanceBytes = 0;
    _opaqueSortMicros = 0;
    _opaqueEncodeMicros = 0;
    if (snapshot == null) return;
    // ignore: avoid_print
    print(
      'FLUTTER_SCENE_PROFILE_ENCODER '
      'sort_mean_us=${snapshot.mean('sort')} '
      'encode_mean_us=${snapshot.mean('encode')} '
      'instance_pack_mean_us=${snapshot.mean('instance_pack')} '
      'instance_pack_max_us=${snapshot.max('instance_pack')} '
      'instance_bind_mean_us=${snapshot.mean('instance_bind')} '
      'instance_kib_mean=${snapshot.mean('instance_bytes') ~/ 1024} '
      'draws_mean=${snapshot.mean('draws')} '
      'instances_mean=${snapshot.mean('instances')}',
    );
  }

  bool _translucentPrepared = false;
  int _translucentCursor = 0;
  int _translucentSortMicros = 0;
  int _translucentEncodeMicros = 0;

  ui.Rect _screenBoundsOf(_TranslucentRecord record) {
    final cached = record.screenBounds;
    if (cached != null) return cached;
    final bounds = record.item.worldBounds;
    if (bounds == null || _dimensions.isEmpty || record.item.lod != null) {
      return record.screenBounds = ui.Offset.zero & _dimensions;
    }
    return record.screenBounds = _projectBounds(bounds);
  }

  ui.Rect _sceneColorSampleBoundsOf(_TranslucentRecord record) {
    final cached = record.sceneColorSampleBounds;
    if (cached != null) return cached;
    final expansion = record.material.sceneColorSampleBoundsExpansion;
    final bounds = record.item.worldBounds;
    if (expansion == null || bounds == null || record.item.lod != null) {
      return record.sceneColorSampleBounds = ui.Offset.zero & _dimensions;
    }
    var projected = _screenBoundsOf(record);
    if (expansion > 0) {
      final transform = record.worldTransform.storage;
      final scaleX = math.sqrt(
        transform[0] * transform[0] +
            transform[1] * transform[1] +
            transform[2] * transform[2],
      );
      final scaleY = math.sqrt(
        transform[4] * transform[4] +
            transform[5] * transform[5] +
            transform[6] * transform[6],
      );
      final scaleZ = math.sqrt(
        transform[8] * transform[8] +
            transform[9] * transform[9] +
            transform[10] * transform[10],
      );
      final worldExpansion =
          expansion * math.max(scaleX, math.max(scaleY, scaleZ));
      final expanded = Aabb3.copy(bounds)
        ..min.sub(Vector3.all(worldExpansion))
        ..max.add(Vector3.all(worldExpansion));
      projected = _projectBounds(expanded);
    }
    final filterFraction = record.material.sceneColorSampleFilterLodFraction;
    if (filterFraction > 0 && !projected.isEmpty) {
      final maxDimension = math.max(_dimensions.width, _dimensions.height);
      final lod = math.log(maxDimension) / math.ln2 * filterFraction;
      final filterRadius = 4.0 * math.pow(2.0, lod.ceil()).toDouble();
      projected = projected.inflate(filterRadius);
    }
    final viewport = ui.Offset.zero & _dimensions;
    return record.sceneColorSampleBounds = projected.intersect(viewport);
  }

  ui.Rect _projectBounds(Aabb3 bounds) {
    if (_dimensions.isEmpty) return ui.Offset.zero & _dimensions;

    final min = bounds.min;
    final max = bounds.max;
    var anyBehind = false;
    var anyInFront = false;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var i = 0; i < 8; i++) {
      final corner = Vector4(
        (i & 1) == 0 ? min.x : max.x,
        (i & 2) == 0 ? min.y : max.y,
        (i & 4) == 0 ? min.z : max.z,
        1,
      );
      final clip = _cameraTransform.transform(corner);
      if (clip.w <= 0) {
        anyBehind = true;
        continue;
      }
      anyInFront = true;
      final x = (clip.x / clip.w + 1) * 0.5 * _dimensions.width;
      final y = (1 - clip.y / clip.w) * 0.5 * _dimensions.height;
      if (x < left) left = x;
      if (y < top) top = y;
      if (x > right) right = x;
      if (y > bottom) bottom = y;
    }
    final viewport = ui.Offset.zero & _dimensions;
    if (!anyInFront || anyBehind) return viewport;
    return ui.Rect.fromLTRB(
      left.clamp(0.0, _dimensions.width),
      top.clamp(0.0, _dimensions.height),
      right.clamp(0.0, _dimensions.width),
      bottom.clamp(0.0, _dimensions.height),
    );
  }

  int _nextSceneColorBatchEnd() {
    _prepareTranslucent();
    assert(_translucentCursor < _translucentRecords.length);
    assert(_readsSceneColor(_translucentRecords[_translucentCursor].material));
    return _sceneColorBatchEnd(
      _translucentRecords,
      _translucentCursor,
      _dimensions,
      readsSceneColor: (record) => _readsSceneColor(record.material),
      outputBounds: _screenBoundsOf,
      sampleBounds: _sceneColorSampleBoundsOf,
    );
  }

  void _prepareTranslucent() {
    if (_translucentPrepared) return;
    final sortWatch = profileRendering ? (Stopwatch()..start()) : null;
    _translucentRecords.sort((a, b) => _farthestFirst(a.depth, b.depth));
    sortWatch?.stop();
    _translucentSortMicros = sortWatch?.elapsedMicroseconds ?? 0;
    _translucentPrepared = true;
  }

  /// Whether a deferred translucent draw remains.
  bool get hasPendingTranslucent {
    _prepareTranslucent();
    return _translucentCursor < _translucentRecords.length;
  }

  /// Whether a pending translucent draw samples scene color.
  bool get hasPendingSceneColorReaders {
    _prepareTranslucent();
    for (var i = _translucentCursor; i < _translucentRecords.length; i++) {
      if (_readsSceneColor(_translucentRecords[i].material)) return true;
    }
    return false;
  }

  /// Whether the next translucent batch needs opaque scene color.
  bool get nextTranslucentBatchReadsSceneColor {
    _prepareTranslucent();
    if (_translucentCursor >= _translucentRecords.length) return false;
    return _readsSceneColor(_translucentRecords[_translucentCursor].material);
  }

  /// Whether the next translucent batch needs roughness-filtered scene color.
  bool get nextTranslucentBatchReadsFilteredSceneColor {
    _prepareTranslucent();
    if (_translucentCursor >= _translucentRecords.length) return false;
    return _translucentRecords[_translucentCursor].material.sceneInputs
        .contains(RenderInput.filteredSceneColor);
  }

  /// Number of pending translucent draws that read opaque scene color.
  int get pendingSceneColorReaderCount {
    _prepareTranslucent();
    var count = 0;
    for (var i = _translucentCursor; i < _translucentRecords.length; i++) {
      if (_readsSceneColor(_translucentRecords[i].material)) count++;
    }
    return count;
  }

  /// Whether the next overlap-safe scene-color batch needs filtered color.
  bool get nextSceneColorBatchReadsFilteredSceneColor {
    _prepareTranslucent();
    final end = _nextSceneColorBatchEnd();
    for (var i = _translucentCursor; i < end; i++) {
      if (_translucentRecords[i].material.sceneInputs.contains(
        RenderInput.filteredSceneColor,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Whether any pending translucent draw needs filtered scene color.
  bool get pendingTranslucentReadsFilteredSceneColor {
    _prepareTranslucent();
    for (var i = _translucentCursor; i < _translucentRecords.length; i++) {
      if (_translucentRecords[i].material.sceneInputs.contains(
        RenderInput.filteredSceneColor,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Emits one translucent batch in global back-to-front order.
  ///
  /// A batch ends immediately before the next material that reads scene
  /// color. Batching preserves global back-to-front order while letting the
  /// scene pass replace the render target between batches when needed.
  void flushNextTranslucentBatch({gpu.RenderPass? translucentPass}) {
    _prepareTranslucent();
    var end = _translucentCursor + 1;
    while (end < _translucentRecords.length &&
        !_readsSceneColor(_translucentRecords[end].material)) {
      end++;
    }
    _flushTranslucentThrough(end, translucentPass: translucentPass);
  }

  /// Emits one scene-color batch, grouping readers that cannot overlap.
  void flushNextSceneColorBatch({gpu.RenderPass? translucentPass}) {
    _flushTranslucentThrough(
      _nextSceneColorBatchEnd(),
      translucentPass: translucentPass,
    );
  }

  void _flushTranslucentThrough(int end, {gpu.RenderPass? translucentPass}) {
    _prepareTranslucent();
    if (_translucentCursor >= _translucentRecords.length) return;

    if (translucentPass != null) {
      _renderPass = translucentPass;
      _boundPipeline = null;
      _boundMaterial = null;
      _boundMaterialVertex = null;
      _boundFrameInfoShader = null;
      _boundFrameInfoDepthBias = double.nan;
      _boundMaterialFade = double.nan;
      _boundMaterialLightOffset = -1;
      _boundMaterialLightCount = -1;
      _boundMaterialLightChannelMask = -1;
      _boundWindingOrder = null;
      _boundPrimitiveType = null;
      EngineLightingUniforms.invalidateBindMemo();
    }
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    final encodeWatch = profileRendering ? (Stopwatch()..start()) : null;
    _renderPass.setDepthWriteEnable(false);
    _renderPass.setColorBlendEnable(true);
    _renderPass.setColorBlendEquation(
      gpu.ColorBlendEquation(
        colorBlendOperation: gpu.BlendOperation.add,
        sourceColorBlendFactor: gpu.BlendFactor.one,
        destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
        alphaBlendOperation: gpu.BlendOperation.add,
        sourceAlphaBlendFactor: gpu.BlendFactor.one,
        destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
      ),
    );

    while (_translucentCursor < end) {
      final record = _translucentRecords[_translucentCursor++];
      _renderPass.setDepthWriteEnable(record.material.translucentDepthWrite);
      record.material.lightListOffset = record.lightListOffset;
      record.material.lightListCount = record.lightListCount;
      record.material.lightChannelMask = record.item.lightChannelMask;
      record.material.setModelScaleFromTransform(record.item.worldTransform);
      final joints = record.jointsTexture;
      if (joints != null) {
        record.geometry.setJointsTexture(joints, record.jointsTextureWidth);
      }
      record.item.applyMorphWeights(record.geometry);
      final instances = record.item.instanceTransforms;
      if (instances != null) {
        _encodeInstanced(
          record.pipeline,
          record.worldTransform,
          record.geometry,
          record.material,
          instances,
          record.item.instanceColors!,
          record.windingFlipped,
          record.fade,
          instanceWindingFlipped: record.item.instanceWindingFlipped,
          instanceIndices: record.item.visibleInstanceIndices,
          sortBackToFrontFrom: record.item.sortTransparentInstances
              ? _camera.position
              : null,
          packedWorldData: record.windingFlipped == record.item.windingFlipped
              ? record.item.instanceWorldData
              : null,
          packedWorldWindingFlipped:
              record.windingFlipped == record.item.windingFlipped
              ? record.item.instanceWorldWindingFlipped
              : null,
          attributeData: record.item.instanceAttributeData,
          attributeFloats: record.item.instanceAttributeFloats,
        );
      } else {
        _encode(
          record.pipeline,
          record.worldTransform,
          record.geometry,
          record.material,
          record.windingFlipped,
          record.fade,
        );
      }
    }
    encodeWatch?.stop();
    _translucentEncodeMicros += encodeWatch?.elapsedMicroseconds ?? 0;

    if (_translucentCursor == _translucentRecords.length) {
      if (profileRendering) {
        _recordProfile(
          _opaqueSortMicros + _translucentSortMicros,
          _opaqueEncodeMicros + _translucentEncodeMicros,
          _encodedDraws,
          _encodedInstances,
        );
      }
      for (final record in _translucentRecords) {
        if (_translucentRecordPool.length == _recordPoolLimit) break;
        record.release();
        _translucentRecordPool.add(record);
      }
      _translucentRecords.clear();
      _translucentCursor = 0;
      _translucentPrepared = false;
      _translucentSortMicros = 0;
      _translucentEncodeMicros = 0;
    }
  }

  /// Emits only the translucent phase (see [flush]).
  void flushTranslucent({gpu.RenderPass? translucentPass}) {
    var pass = translucentPass;
    while (hasPendingTranslucent) {
      flushNextTranslucentBatch(translucentPass: pass);
      pass = null;
    }
  }

  static bool _readsSceneColor(Material material) {
    final inputs = material.sceneInputs;
    return inputs.contains(RenderInput.opaqueSceneColor) ||
        inputs.contains(RenderInput.filteredSceneColor);
  }
}
