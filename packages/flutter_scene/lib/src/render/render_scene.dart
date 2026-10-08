import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

import 'package:flutter/foundation.dart' show ValueNotifier, internal;
import 'package:flutter_scene/src/render/debug_view.dart';
import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/components/camera_component.dart';
import 'package:flutter_scene/src/components/directional_light_component.dart';
import 'package:flutter_scene/src/components/environment_volume_component.dart';
import 'package:flutter_scene/src/components/irradiance_volume_component.dart';
import 'package:flutter_scene/src/components/point_light_component.dart';
import 'package:flutter_scene/src/components/rect_area_light_component.dart';
import 'package:flutter_scene/src/components/planar_reflector_component.dart';
import 'package:flutter_scene/src/components/reflection_probe_component.dart';
import 'package:flutter_scene/src/components/semantics_component.dart';
import 'package:flutter_scene/src/components/spot_light_component.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/instance_band.dart';
import 'package:flutter_scene/src/instanced_mesh.dart';
import 'package:flutter_scene/src/light.dart' show ShadowCasterFaces;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart' show ShadowCastingMode;
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/render/bvh.dart';
import 'package:flutter_scene/src/render/custom_render_pass.dart';
import 'package:flutter_scene/src/render/instance_packing.dart'
    show invalidateRetainedInstanceData, updateRetainedInstanceRows;
import 'package:flutter_scene/src/render/instance_records.dart';
import 'package:flutter_scene/src/mesh_draw.dart';
import 'package:flutter_scene/src/draw_revision.dart';
import 'package:flutter_scene/src/render/lod.dart';
import 'package:flutter_scene/src/render/pre_pass.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/render_layers.dart';
import 'package:flutter_scene/src/render_view.dart';

/// One drawable primitive in the flat render layer.
///
/// A [RenderItem] is created when a mesh-bearing node is mounted into a
/// scene and lives until that node is unmounted or its mesh changes. The
/// scene pre-pass refreshes [visible], [frustumCulled], and
/// [worldTransform] each frame; the render passes iterate the flat
/// [RenderScene] and never walk the node tree.
class RenderItem {
  RenderItem({required this.geometry, required Material material})
    : _material = material,
      geometryIdentity = identityHashCode(geometry),
      materialIdentity = identityHashCode(material);

  /// Vertex and index data for this primitive.
  final Geometry geometry;

  /// The mesh part this item draws, for its [MeshDrawSelector].
  @internal
  MeshDrawSource? drawSource;

  /// Shader and per-material parameters.
  Material get material => _material;
  set material(Material value) {
    if (identical(_material, value)) return;
    _material = value;
    materialIdentity = identityHashCode(value);
  }

  Material _material;

  /// Identity sort keys for [geometry] and [material], cached so the batching
  /// sorts in the depth prepass and shadow encoder compare plain integers.
  /// Those comparators run O(n log n) times per pass per frame, and
  /// identityHashCode is a runtime call that installs a hash in the object
  /// header on first use. [materialIdentity] is refreshed by the setter above.
  final int geometryIdentity;
  int materialIdentity;

  /// Level-of-detail state, set by an [LodComponent] when the item is
  /// registered. When non-null the encoder picks one of its levels per view
  /// (or culls) from the item's projected screen size, instead of drawing
  /// [geometry] and [material]. Those serve as the highest-detail fallback
  /// and the source of [cullBounds].
  LodSelection? lod;

  /// The `Node` that owns this item, set once when the item is registered.
  ///
  /// Typed as `Object?` to keep the render layer free of a node import (the
  /// same reason [RenderScene.widgetComponents] is loosely typed). Consumers
  /// that need the node (the object-filtered draw's node predicate and
  /// per-node color) cast it back to `Node`.
  Object? sourceNode;

  /// Whether the owning node and all of its ancestors are visible.
  /// Refreshed each frame by the scene pre-pass.
  bool visible = false;

  /// Mirrors the owning `MeshPrimitive.visible`, refreshed each frame.
  /// Ands with [visible] to gate the color passes; independent of
  /// [castsShadows], so a primitive can be excluded from color while still
  /// casting a shadow.
  bool primitiveVisible = true;

  /// Mirrors the owning node's frustum-cull opt-in, refreshed each frame.
  bool frustumCulled = true;

  /// The owning node's render layers (a 32-bit bitmask), refreshed each
  /// frame. A render pass skips this item when its view's layer mask does
  /// not intersect (`layers & layerMask == 0`).
  int layers = kRenderLayerAll;

  /// The owning node's [Node.renderOrder], the first sort key of its pass.
  double renderOrder = 0.0;

  /// The owning node's sort-depth bias, refreshed each frame. The encoder
  /// takes it off the view-axis depth it sorts this item by.
  double sortDepthBias = 0.0;

  /// The owning node's light channels (an 8-bit bitmask), refreshed each
  /// frame. A light shades this item only when its own channel mask
  /// intersects (`light.channelMask & lightChannelMask != 0`), and a
  /// directional light's caster mask is tested against it the same way.
  int lightChannelMask = 0xFF;

  /// The owning node's effective surface debug view override, refreshed each
  /// frame (null inherits the scene's view). See `Node.debugView`.
  DebugView? debugView;

  /// Whether the owning node's world transform reverses triangle winding.
  bool nodeWindingFlipped = false;

  /// Whether this item's base geometry needs reversed native winding.
  bool get windingFlipped => windingFor(geometry);

  /// Stores the owning node's transform parity.
  @internal
  void refreshWinding(bool value) => nodeWindingFlipped = value;

  /// Returns the winding parity for [drawnGeometry].
  ///
  /// A selected level of detail can use a different source convention from
  /// the item's base geometry.
  @internal
  bool windingFor(Geometry drawnGeometry) =>
      nodeWindingFlipped != drawnGeometry.sourceWindingFlipped;

  /// Mirrors the owning node's `shadowStatic` promise, refreshed each frame.
  /// Static casters render into cached shadow tiles; dynamic casters render
  /// every frame (see the shadow cache).
  bool shadowStatic = false;

  /// Mirrors the owning node's `shadowCastingMode`, refreshed each frame.
  ShadowCastingMode shadowCastingMode = ShadowCastingMode.on;

  /// Mirrors the owning `MeshPrimitive.castsShadow`, refreshed each frame.
  /// Kept apart from [shadowCastingMode] rather than folded into it: a
  /// primitive opting out must stop the casting without also pulling a
  /// shadows-only node back into the color image.
  bool primitiveCastsShadow = true;

  /// Whether this item renders into shadow maps at all.
  bool get castsShadows =>
      primitiveCastsShadow && shadowCastingMode != ShadowCastingMode.off;

  /// Whether this item casts from every face, ignoring material culling.
  bool get shadowDoubleSided =>
      shadowCastingMode == ShadowCastingMode.doubleSided;

  /// Whether this item draws into the color image this frame: visible, its
  /// primitive shown, and not a shadows-only caster. The shadow passes test
  /// [castsShadows] instead, so the two are independent.
  bool get drawsColor =>
      visible &&
      primitiveVisible &&
      shadowCastingMode != ShadowCastingMode.shadowsOnly;

  /// Mirrors the owning node's `shadowCasterFaces`, refreshed each frame; null
  /// casts with the light's faces.
  ShadowCasterFaces? shadowCasterFaces;

  /// The owning node's joints texture and its edge length in texels, or
  /// null/0 for an unskinned node. Refreshed each frame from the node's
  /// [Skin]. Carried per item rather than on the geometry so nodes sharing
  /// one skinned geometry (clones of a skinned model) each draw with their
  /// own skeleton; every render pass applies it via [applyJointsTexture]
  /// just before binding a draw.
  gpu.Texture? jointsTexture;
  gpu.Texture? previousJointsTexture;
  int jointsTextureWidth = 0;

  /// Applies this item's joints texture to [drawnGeometry] (which differs
  /// from [geometry] when a level of detail was selected). No-op for
  /// unskinned items. Render passes call this immediately before the
  /// geometry's bind, so a geometry shared between skinned items holds the
  /// right skeleton for each draw.
  void applyJointsTexture(Geometry drawnGeometry) {
    final texture = jointsTexture;
    if (texture == null) return;
    drawnGeometry.setJointsTexture(texture, jointsTextureWidth);
  }

  /// The owning node's live morph target weights, or null for an unmorphed
  /// node. Refreshed each frame. Carried per item (like [jointsTexture]) so
  /// nodes sharing one morphed geometry each draw with their own weights.
  Float32List? morphWeights;

  /// Applies this item's morph weights to [drawnGeometry]. No-op for
  /// unmorphed items. Render passes call this immediately before the
  /// geometry's bind, next to [applyJointsTexture].
  void applyMorphWeights(Geometry drawnGeometry) {
    final weights = morphWeights;
    if (weights == null) return;
    drawnGeometry.setMorphWeights(weights);
  }

  /// The owning node's transform, refreshed each frame from it. It leaves
  /// out the node's anchor (see [anchored]); a draw binds [drawTransform].
  final Matrix4 worldTransform = Matrix4.identity();

  /// Whether the owning node is stated from an anchor (`Node.anchor`).
  @internal
  bool anchored = false;

  /// The anchor [worldTransform] is stated from, valid while [anchored].
  @internal
  final Float64List anchor = Float64List(3);

  /// The draw origin of the scene that holds this item, or null outside one.
  @internal
  DrawOrigin? drawOrigin;

  /// What a draw adds to a position in [worldTransform]'s space along
  /// [axis]: the anchor minus the draw origin, or 0 for an item with no
  /// anchor.
  @internal
  double drawShift(int axis) {
    final origin = drawOrigin;
    if (!anchored || origin == null) return 0.0;
    return anchor[axis] - origin.at[axis];
  }

  /// Takes the anchor of the owning node: [stated] where it has one on its
  /// chain. Returns whether the item's place among the scene's bounds
  /// changed.
  @internal
  bool takeAnchor(Float64List? stated) {
    final was = anchored;
    if (stated == null) {
      anchored = false;
      return was;
    }
    if (was &&
        anchor[0] == stated[0] &&
        anchor[1] == stated[1] &&
        anchor[2] == stated[2]) {
      return false;
    }
    anchored = true;
    anchor.setAll(0, stated);
    _drawTransformOrigin = -1;
    _drawnBoundsOrigin = -1;
    return true;
  }

  final Matrix4 _drawTransform = Matrix4.identity();
  int _drawTransformOrigin = -1;
  int _drawTransformRevision = -1;

  /// [worldTransform] as a draw binds it: moved by the anchor minus the
  /// scene's draw origin, which is [worldTransform] itself for an item with
  /// no anchor.
  @internal
  Matrix4 get drawTransform {
    final origin = drawOrigin;
    if (!anchored || origin == null) return worldTransform;
    if (_drawTransformOrigin != origin.revision ||
        _drawTransformRevision != worldTransformRevision) {
      _drawTransformOrigin = origin.revision;
      _drawTransformRevision = worldTransformRevision;
      _shifted(worldTransform, origin.at, _drawTransform);
    }
    return _drawTransform;
  }

  final Matrix4 _previousDrawTransform = Matrix4.identity();

  /// [previousWorldTransform] as the frame before drew it, from the draw
  /// origin of that frame.
  @internal
  Matrix4 get previousDrawTransform {
    final origin = drawOrigin;
    if (!anchored || origin == null) return previousWorldTransform;
    return _shifted(
      previousWorldTransform,
      origin.previous,
      _previousDrawTransform,
    );
  }

  Matrix4 _shifted(Matrix4 from, Float64List origin, Matrix4 into) {
    into.setFrom(from);
    final storage = into.storage;
    final placed = from.storage;
    storage[12] = placed[12] + (anchor[0] - origin[0]);
    storage[13] = placed[13] + (anchor[1] - origin[1]);
    storage[14] = placed[14] + (anchor[2] - origin[2]);
    return into;
  }

  static final Matrix4 _instanceFrameScratch = Matrix4.identity();

  /// The previous frame's world-space transform, for motion vector rendering.
  final Matrix4 previousWorldTransform = Matrix4.identity();

  /// Whether this item moved, deformed, or changed instances this frame.
  bool isMoving = false;

  /// Start index of this item's punctual-light list in the shared per-frame
  /// light-index buffer, and how many lights follow. Refreshed each frame by
  /// the light culler; the shader loops that slice so a fragment only shades
  /// the lights that reach this item. `count` 0 means no punctual lights.
  int lightListOffset = 0;
  int lightListCount = 0;

  /// Scratch accumulator the light culler appends this item's light indices to
  /// before flattening them into the shared buffer. Reused across frames to
  /// avoid per-item allocation; cleared at the start of each cull.
  final List<int> lightScratch = [];

  /// The owning node's highlight color (linear RGBA), or null when the node
  /// is not highlighted. Refreshed each frame; the selection-outline pass
  /// draws only highlighted items, using this as the mask color.
  Vector4? highlightColor;

  /// The leaf of the scene's [Bvh] that holds this item, or `-1` while it is
  /// in none. Maintained by the tree.
  @internal
  int bvhNode = -1;

  // Where the scene holds the item while it is in no tree, or `-1`.
  int _alwaysVisibleSlot = -1;

  // Whether the scene has placed the item since it was added or its
  // membership changed.
  bool _placed = false;

  // Whether the tree holds this item's box in its anchor's space.
  bool _treeAnchored = false;

  /// Whether this item casts into the cached static shadow tiles: a visible
  /// static caster.
  bool get isStaticShadowCaster => shadowStatic && castsShadows && visible;

  // Whether the scene counts the item among its static shadow casters.
  bool _countedStaticCaster = false;

  /// Index into [RenderScene.items] while registered, or `-1`. Maintained
  /// by [RenderScene.add] and [RenderScene.remove] so unregistering is a
  /// swap removal instead of a list scan.
  int sceneSlot = -1;

  /// Per-instance model transforms, or `null` for a non-instanced item.
  ///
  /// When set, this item draws [geometry] / [material] once per entry,
  /// each at `worldTransform * transform`. Refreshed each frame from the
  /// owning [InstancedMeshComponent].
  List<Matrix4>? instanceTransforms;

  /// Per-instance linear RGBA multipliers matching [instanceTransforms].
  List<Vector4>? instanceColors;

  /// Packed custom per-instance attribute floats, [instanceAttributeFloats]
  /// per instance in declaration order, or null when none are supplied.
  Float32List? instanceAttributeData;

  /// Custom attribute floats each instance carries, zero unless the material
  /// declares `instance_attributes`.
  int instanceAttributeFloats = 0;

  /// Per-instance local winding parity matching [instanceTransforms].
  List<bool>? instanceWindingFlipped;

  /// Whether the cells of this item's instances are culled after its
  /// aggregate BVH test (see [instanceCellRows]).
  bool cullInstances = false;

  /// Whether translucent instances are sorted back to front within this item.
  bool sortTransparentInstances = true;

  /// Whether [instanceWorldData] holds each record relative to the node, with
  /// [worldTransform] reaching the vertex stage as the instance frame (see
  /// [InstancedMesh.nodeSpaceInstances]).
  bool nodeSpaceInstances = false;

  static final Matrix4 _identityTransform = Matrix4.identity();

  /// The transform every instance record of this item is packed under: the
  /// identity for node-space records, [worldTransform] otherwise.
  @internal
  Matrix4 get instancePackTransform =>
      nodeSpaceInstances ? _identityTransform : worldTransform;

  /// The transform the vertex stage applies after each instance record, or
  /// null when the records already hold world transforms.
  @internal
  Matrix4? get instanceFrame => nodeSpaceInstances ? worldTransform : null;

  /// The row ranges the current view draws, or null when it draws every
  /// range of [instanceRowRanges]. Three entries per range, as there.
  List<int>? visibleInstanceRanges;

  /// The mesh whose rows this item draws from the records they share, or
  /// null when the item packs its own (see [InstancedMesh.sharing]).
  @internal
  InstancedMesh? sharedRows;

  /// The instanced mesh this item draws, read at each draw for what a frame
  /// may set without a change to the node: [instanceRanges], [instanceLocal]
  /// and [instanceBand].
  @internal
  InstancedMesh? instanceSource;

  /// The rows a draw of [sharedRows] takes, as pairs of a first row and a
  /// row count, or null for every row.
  @internal
  Uint32List? get instanceRanges => instanceSource?.instanceRanges;

  /// The transform a vertex takes before its row's record, or null for none.
  @internal
  Matrix4? get instanceLocal => instanceSource?.instanceLocal;

  /// The band each row is tested against, or null for none.
  @internal
  InstanceBand? get instanceBand => instanceSource?.band;

  /// States this item's instance frame, local transform and band for the
  /// unskinned `FrameInfo` of the draws bound next. Pair with
  /// [endInstanceDraw].
  @internal
  void beginInstanceDraw() {
    if (anchored && drawOrigin != null) {
      _currentDrawAnchor = anchor;
      _currentDrawOrigin = drawOrigin!.at;
    }
    if (!nodeSpaceInstances) {
      // Packed records hold [worldTransform], so the frame adds the shift
      // alone.
      if (anchored && drawOrigin != null) {
        currentDrawInstanceFrame = _instanceFrameScratch
          ..setTranslationRaw(drawShift(0), drawShift(1), drawShift(2));
      }
      return;
    }
    currentDrawInstanceFrame = drawTransform;
    currentDrawInstanceLocal = instanceLocal;
    currentDrawInstanceBand = instanceBand;
  }

  /// Clears what [beginInstanceDraw] stated.
  @internal
  static void endInstanceDraw() {
    _currentDrawAnchor = null;
    _currentDrawOrigin = null;
    currentDrawInstanceFrame = null;
    currentDrawInstanceLocal = null;
    currentDrawInstanceBand = null;
  }

  final List<int> _visibleRangeScratch = [];

  /// The row ranges the shadow map being drawn takes, or null when it takes
  /// every range. Valid from [cullShadowInstances] until the next call.
  @internal
  List<int>? shadowInstanceRanges;

  List<int>? _shadowRangeScratch;

  /// Packed world transform and color records, twenty floats per instance plus
  /// [instanceAttributeFloats] custom attribute floats.
  @internal
  Float32List? instanceWorldData;

  /// Combined node/instance winding parity matching [instanceWorldData].
  @internal
  Uint8List? instanceWorldWindingFlipped;

  /// The floats of one record of [instanceWorldData].
  @internal
  int get instanceRecordFloats => _instanceRecordFloats;

  /// How many consecutive rows one cell holds at most. A cell is the unit an
  /// instanced item is culled by and the smallest range a pass draws.
  int instanceCellRows = 64;

  /// How many ranges a cull leaves an item of one winding at most. A cull that
  /// finds more draws the one range from its first visible row to its last,
  /// so an item whose rows follow no order in space costs a bounded number of
  /// draws.
  int instanceRangeLimit = 8;

  /// Every row of this item as ranges a pass draws with one instanced call
  /// each: the first row, the row count and 1 where the rows reverse the
  /// winding, three entries per range. Rows that share a winding form one
  /// range, so a set that mirrors no instance is one range.
  List<int> get instanceRowRanges => _allRanges;

  List<int> _allRanges = const [];

  // The first row of each cell, with the row count as a last entry, the
  // winding the rows of a cell share, and the bounds of a cell in the space
  // the records are packed in, six floats per cell, or null where the
  // geometry states no bounds.
  Int32List _cellFirst = Int32List(1);
  Uint8List _cellFlipped = Uint8List(0);
  Float32List? _cellBounds;

  // [_cellBounds] in world space for node-space records, built on demand and
  // dropped when the node moves or the records change.
  Float32List? _cellWorldBounds;

  static final Matrix4 _instanceWorldScratch = Matrix4.zero();
  static final Aabb3 _instanceAabbScratch = Aabb3();

  // The stores behind [instanceWorldData] and [instanceWorldWindingFlipped],
  // which are views of their first rows. A store grows geometrically, so rows
  // appended one at a time pack only themselves.
  Float32List _instanceDataStore = Float32List(0);
  Uint8List _instanceWindingStore = Uint8List(0);
  int _instanceRecordFloats = 0;

  /// The record this item binds when it draws one instance.
  @internal
  final HeldInstanceRecord heldInstanceRecord = HeldInstanceRecord();

  /// Counts the changes of [worldTransform].
  @internal
  int worldTransformRevision = 0;

  /// Rebuilds cached world-space bounds and draw data after a node, geometry,
  /// or instance change. Static groups pay this once during setup.
  @internal
  void refreshInstanceData() => _packInstances(null);

  /// Rebuilds the cached bounds and draw data of [rows] only, after an
  /// instance change that moved no other row (see
  /// [InstancedMesh.rowsChangedSince]). A row at or past the instance count
  /// was removed from the end. Falls back to [refreshInstanceData] when the
  /// record layout changed since the last pack.
  @internal
  void refreshInstanceRows(List<int> rows) => _packInstances(rows);

  /// Drops what was derived from [worldTransform] after the node of
  /// node-space records moved, which leaves every record as packed.
  @internal
  void instanceFrameMoved() => _cellWorldBounds = null;

  void _packInstances(List<int>? rows) {
    _cellWorldBounds = null;
    final instances = sharedRows == null ? instanceTransforms : null;
    final colors = instanceColors;
    if (instances == null) {
      instanceWorldData = null;
      instanceWorldWindingFlipped = null;
      _allRanges = const [];
      _cellFirst = Int32List(1);
      _cellFlipped = Uint8List(0);
      _cellBounds = null;
      return;
    }
    final count = instances.length;
    final attributes = instanceAttributeData;
    final attributeFloats = attributes == null ? 0 : instanceAttributeFloats;
    final recordFloats = 20 + attributeFloats;
    final packsData = colors != null && colors.length == count;
    var changed = rows;
    if (changed != null &&
        (instanceWorldWindingFlipped == null ||
            (instanceWorldData != null) != packsData ||
            _instanceRecordFloats != recordFloats)) {
      changed = null;
    }
    if (changed != null && changed.length > 1) {
      changed = changed.toSet().toList();
    }
    final keep = changed != null;
    final countMoved = instanceWorldWindingFlipped?.length != count;
    final previousData = instanceWorldData;
    _instanceRecordFloats = recordFloats;
    if (packsData) {
      final floats = count * recordFloats;
      final store = _grownStore(_instanceDataStore, floats, keep);
      if (!identical(store, _instanceDataStore) ||
          instanceWorldData?.length != floats) {
        _instanceDataStore = store;
        instanceWorldData = Float32List.sublistView(store, 0, floats);
      }
    } else {
      instanceWorldData = null;
    }
    var windingStore = _instanceWindingStore;
    if (windingStore.length < count) {
      windingStore = Uint8List(math.max(count, windingStore.length * 2));
      if (keep) {
        windingStore.setRange(
          0,
          _instanceWindingStore.length,
          _instanceWindingStore,
        );
      }
    }
    if (!identical(windingStore, _instanceWindingStore) ||
        instanceWorldWindingFlipped?.length != count) {
      _instanceWindingStore = windingStore;
      instanceWorldWindingFlipped = Uint8List.sublistView(
        windingStore,
        0,
        count,
      );
    }
    final packedData = instanceWorldData;
    final packedWinding = instanceWorldWindingFlipped!;
    final retainedWinding = instanceWindingFlipped;
    final packTransform = instancePackTransform;
    var packedRows = 0;
    var windingMoved = false;
    void packRow(int i) {
      if (packedData != null) {
        _instanceWorldScratch
          ..setFrom(packTransform)
          ..multiply(instances[i]);
        final offset = i * recordFloats;
        packedData.setAll(offset, _instanceWorldScratch.storage);
        packedData.setAll(offset + 16, colors![i].storage);
        if (attributeFloats > 0) {
          packedData.setRange(
            offset + 20,
            offset + recordFloats,
            attributes!,
            i * attributeFloats,
          );
        }
        packedRows++;
      }
      final instanceFlipped =
          retainedWinding?[i] ?? (instances[i].determinant() < 0);
      final flipped = windingFlipped != instanceFlipped ? 1 : 0;
      if (packedWinding[i] != flipped) windingMoved = true;
      packedWinding[i] = flipped;
    }

    if (changed == null) {
      for (var i = 0; i < count; i++) {
        packRow(i);
      }
      _buildCells(instances, packedWinding);
    } else {
      for (final i in changed) {
        if (i < count) packRow(i);
      }
      if (windingMoved || countMoved) {
        _buildCells(instances, packedWinding);
      } else {
        _refreshCellsOf(changed, instances);
      }
    }
    activeRenderCounters.instanceBytesPacked +=
        packedRows * recordFloats * Float32List.bytesPerElement;
    if (packedData == null) {
      if (previousData != null) invalidateRetainedInstanceData(previousData);
    } else if (changed == null) {
      if (previousData != null) invalidateRetainedInstanceData(previousData);
      invalidateRetainedInstanceData(packedData);
    } else {
      updateRetainedInstanceRows(previousData, packedData, count, changed);
    }
  }

  static Float32List _grownStore(Float32List store, int floats, bool keep) {
    if (store.length >= floats) return store;
    final grown = Float32List(math.max(floats, store.length * 2));
    if (keep) grown.setRange(0, store.length, store);
    return grown;
  }

  // Cuts the rows into cells of at most [instanceCellRows] consecutive rows
  // of one winding, and states the ranges that draw every row.
  void _buildCells(List<Matrix4> instances, Uint8List winding) {
    final count = instances.length;
    final cellRows = math.max(1, instanceCellRows);
    final first = <int>[];
    final flipped = <int>[];
    final ranges = <int>[];
    for (var row = 0; row < count; row++) {
      final rowFlipped = winding[row];
      if (first.isEmpty ||
          flipped.last != rowFlipped ||
          row - first.last == cellRows) {
        if (ranges.isNotEmpty && ranges.last == rowFlipped) {
          ranges[ranges.length - 2]++;
        } else {
          ranges
            ..add(row)
            ..add(1)
            ..add(rowFlipped);
        }
        first.add(row);
        flipped.add(rowFlipped);
      } else {
        ranges[ranges.length - 2]++;
      }
    }
    first.add(count);
    _cellFirst = Int32List.fromList(first);
    _cellFlipped = Uint8List.fromList(flipped);
    _allRanges = ranges;
    final cells = flipped.length;
    if (geometry.localBounds == null) {
      _cellBounds = null;
      return;
    }
    final bounds = _cellBounds?.length == cells * 6
        ? _cellBounds!
        : Float32List(cells * 6);
    _cellBounds = bounds;
    for (var cell = 0; cell < cells; cell++) {
      _boundCell(cell, instances, bounds);
    }
  }

  // Bounds again the cells that hold [rows], whose winding did not change.
  void _refreshCellsOf(List<int> rows, List<Matrix4> instances) {
    final bounds = _cellBounds;
    if (bounds == null) return;
    final cellFirst = _cellFirst;
    var bounded = -1;
    for (final row in rows) {
      if (row >= instances.length) continue;
      var low = 0;
      var high = cellFirst.length - 2;
      while (low < high) {
        final middle = (low + high + 1) >> 1;
        if (cellFirst[middle] <= row) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      if (low == bounded) continue;
      bounded = low;
      _boundCell(low, instances, bounds);
    }
  }

  void _boundCell(int cell, List<Matrix4> instances, Float32List into) {
    final local = geometry.localBounds!;
    final packTransform = instancePackTransform;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    final end = _cellFirst[cell + 1];
    for (var row = _cellFirst[cell]; row < end; row++) {
      _instanceWorldScratch
        ..setFrom(packTransform)
        ..multiply(instances[row]);
      _instanceAabbScratch
        ..copyFrom(local)
        ..transform(_instanceWorldScratch);
      final min = _instanceAabbScratch.min;
      final max = _instanceAabbScratch.max;
      if (min.x < minX) minX = min.x;
      if (min.y < minY) minY = min.y;
      if (min.z < minZ) minZ = min.z;
      if (max.x > maxX) maxX = max.x;
      if (max.y > maxY) maxY = max.y;
      if (max.z > maxZ) maxZ = max.z;
    }
    final offset = cell * 6;
    into[offset] = minX;
    into[offset + 1] = minY;
    into[offset + 2] = minZ;
    into[offset + 3] = maxX;
    into[offset + 4] = maxY;
    into[offset + 5] = maxZ;
  }

  /// Refreshes [visibleInstanceRanges] and returns whether anything remains.
  @internal
  bool cullVisibleCells(Frustum frustum, List<Plane> additionalPlanes) {
    final visible = _cellsInside(
      frustum,
      additionalPlanes,
      _visibleRangeScratch,
    );
    visibleInstanceRanges = visible;
    return visible == null || visible.isNotEmpty;
  }

  /// Refreshes [shadowInstanceRanges] for a shadow map drawn through
  /// [frustum] and [additionalPlanes], and returns whether anything remains.
  ///
  /// Kept apart from [cullVisibleCells], whose result the color pass reads
  /// after the shadow maps of the frame are drawn.
  @internal
  bool cullShadowInstances(Frustum frustum, List<Plane> additionalPlanes) {
    final visible = _cellsInside(
      frustum,
      additionalPlanes,
      _shadowRangeScratch ??= [],
    );
    shadowInstanceRanges = visible;
    return visible == null || visible.isNotEmpty;
  }

  // The ranges of the cells whose bounds meet [frustum] and
  // [additionalPlanes], ascending in [scratch] with neighbouring cells of one
  // winding joined, or null when every cell does or the item does not cull
  // its instances. The test runs once per cell, never per instance.
  List<int>? _cellsInside(
    Frustum frustum,
    List<Plane> additionalPlanes,
    List<int> scratch,
  ) {
    if (!cullInstances || instanceTransforms == null) return null;
    final cellBounds = _worldCellBounds();
    if (cellBounds == null) return null;
    _loadCellShift();

    final aggregate = worldBounds;
    if (aggregate != null &&
        _insidePlane(aggregate, frustum.plane0) &&
        _insidePlane(aggregate, frustum.plane1) &&
        _insidePlane(aggregate, frustum.plane2) &&
        _insidePlane(aggregate, frustum.plane3) &&
        _insidePlane(aggregate, frustum.plane4) &&
        _insidePlane(aggregate, frustum.plane5)) {
      var insideAdditionalPlanes = true;
      for (final plane in additionalPlanes) {
        if (!_insidePlane(aggregate, plane)) {
          insideAdditionalPlanes = false;
          break;
        }
      }
      if (insideAdditionalPlanes) return null;
    }

    final cellFirst = _cellFirst;
    final cellFlipped = _cellFlipped;
    final cells = cellFlipped.length;
    final visible = scratch..clear();
    var kept = 0;
    for (var cell = 0; cell < cells; cell++) {
      final offset = cell * 6;
      if (_outsidePlane(cellBounds, offset, frustum.plane0) ||
          _outsidePlane(cellBounds, offset, frustum.plane1) ||
          _outsidePlane(cellBounds, offset, frustum.plane2) ||
          _outsidePlane(cellBounds, offset, frustum.plane3) ||
          _outsidePlane(cellBounds, offset, frustum.plane4) ||
          _outsidePlane(cellBounds, offset, frustum.plane5)) {
        continue;
      }
      var outside = false;
      for (final plane in additionalPlanes) {
        if (_outsidePlane(cellBounds, offset, plane)) {
          outside = true;
          break;
        }
      }
      if (outside) continue;
      kept++;
      final first = cellFirst[cell];
      final rows = cellFirst[cell + 1] - first;
      final last = visible.length - 3;
      if (last >= 0 &&
          visible[last + 2] == cellFlipped[cell] &&
          visible[last] + visible[last + 1] == first) {
        visible[last + 1] += rows;
      } else {
        visible
          ..add(first)
          ..add(rows)
          ..add(cellFlipped[cell]);
      }
    }
    if (kept == cells) return null;
    final ranges = visible.length ~/ 3;
    if (ranges > instanceRangeLimit && _allRanges.length == 3) {
      final first = visible[0];
      final end = visible[visible.length - 3] + visible[visible.length - 2];
      visible
        ..length = 3
        ..[1] = end - first;
    }
    return visible;
  }

  // The world-space bounds of the cells, six floats each, or null where the
  // geometry states none.
  Float32List? _worldCellBounds() {
    final packed = _cellBounds;
    if (packed == null || !nodeSpaceInstances) return packed;
    final cached = _cellWorldBounds;
    if (cached != null && cached.length == packed.length) return cached;
    final world = Float32List(packed.length);
    for (var offset = 0; offset < packed.length; offset += 6) {
      _instanceAabbScratch
        ..min.setValues(packed[offset], packed[offset + 1], packed[offset + 2])
        ..max.setValues(
          packed[offset + 3],
          packed[offset + 4],
          packed[offset + 5],
        )
        ..transform(worldTransform);
      world[offset] = _instanceAabbScratch.min.x;
      world[offset + 1] = _instanceAabbScratch.min.y;
      world[offset + 2] = _instanceAabbScratch.min.z;
      world[offset + 3] = _instanceAabbScratch.max.x;
      world[offset + 4] = _instanceAabbScratch.max.y;
      world[offset + 5] = _instanceAabbScratch.max.z;
    }
    return _cellWorldBounds = world;
  }

  /// A lower bound on the planar view depth of any of this item's visible
  /// points (see [aabbDepthLowerBound]). An instanced item whose aggregate
  /// bounds could set a new [best] is refined per cell, since a spread set
  /// (a skyline ring around the camera) has aggregate bounds far nearer than
  /// any instance. Infinity when the item draws nothing in [frustum]; the
  /// search stops early once a bound reaches [floor].
  @internal
  double depthLowerBound(
    Frustum frustum,
    Vector3 eye,
    Vector3 forward,
    double cosHalfAngle,
    double best, {
    double floor = 0.0,
  }) {
    final aggregate = worldBounds;
    if (aggregate == null) return 0.0;
    final whole = aggregate.depthLowerBound(eye, forward, cosHalfAngle);
    if (whole >= best || instanceTransforms == null) return whole;
    final packed = _worldCellBounds();
    if (packed == null) return whole;
    _loadCellShift();
    final eyeX = eye.x - _cellShiftX;
    final eyeY = eye.y - _cellShiftY;
    final eyeZ = eye.z - _cellShiftZ;
    var nearest = double.infinity;
    for (var offset = 0; offset < packed.length; offset += 6) {
      if (_outsidePlane(packed, offset, frustum.plane0) ||
          _outsidePlane(packed, offset, frustum.plane1) ||
          _outsidePlane(packed, offset, frustum.plane2) ||
          _outsidePlane(packed, offset, frustum.plane3) ||
          _outsidePlane(packed, offset, frustum.plane4) ||
          _outsidePlane(packed, offset, frustum.plane5)) {
        continue;
      }
      final bound = aabbDepthLowerBound(
        packed[offset],
        packed[offset + 1],
        packed[offset + 2],
        packed[offset + 3],
        packed[offset + 4],
        packed[offset + 5],
        eyeX,
        eyeY,
        eyeZ,
        forward.x,
        forward.y,
        forward.z,
        cosHalfAngle,
      );
      if (bound < nearest) {
        nearest = bound;
        if (nearest <= floor) break;
      }
    }
    return nearest;
  }

  /// How far along the ray from [origin] in unit [direction] this item's
  /// bounds start (each cell's for an instanced item), zero from inside, or
  /// null when the ray misses them. For diagnostics that name where on
  /// screen something happens.
  @internal
  double? rayBoundsDistance(Vector3 origin, Vector3 direction) {
    final aggregate = worldBounds;
    if (aggregate == null) return null;
    final cells = instanceTransforms == null ? null : _worldCellBounds();
    final packed =
        cells ??
        Float32List.fromList([
          aggregate.min.x,
          aggregate.min.y,
          aggregate.min.z,
          aggregate.max.x,
          aggregate.max.y,
          aggregate.max.z,
        ]);
    var nearest = double.infinity;
    for (var offset = 0; offset < packed.length; offset += 6) {
      var near = 0.0;
      var far = double.infinity;
      for (var axis = 0; axis < 3 && near <= far; axis++) {
        // The cells sit in the space of [worldTransform], which leaves the
        // anchor out.
        final o = origin[axis] - (cells == null ? 0.0 : drawShift(axis));
        final d = direction[axis];
        final lo = packed[offset + axis];
        final hi = packed[offset + axis + 3];
        if (d.abs() < 1e-12) {
          if (o < lo || o > hi) far = -1.0;
          continue;
        }
        final t0 = (lo - o) / d;
        final t1 = (hi - o) / d;
        near = math.max(near, math.min(t0, t1));
        far = math.min(far, math.max(t0, t1));
      }
      if (near <= far && near < nearest) nearest = near;
    }
    return nearest.isFinite ? nearest : null;
  }

  // What a draw adds to a cell's bounds, which sit in the space of
  // [worldTransform]: the planes of a test move by it, so no cell does.
  static double _cellShiftX = 0.0;
  static double _cellShiftY = 0.0;
  static double _cellShiftZ = 0.0;

  void _loadCellShift() {
    _cellShiftX = drawShift(0);
    _cellShiftY = drawShift(1);
    _cellShiftZ = drawShift(2);
  }

  static bool _outsidePlane(Float32List bounds, int offset, Plane plane) {
    final normal = plane.normal;
    final x = bounds[offset + (normal.x < 0 ? 0 : 3)] + _cellShiftX;
    final y = bounds[offset + (normal.y < 0 ? 1 : 4)] + _cellShiftY;
    final z = bounds[offset + (normal.z < 0 ? 2 : 5)] + _cellShiftZ;
    return normal.x * x + normal.y * y + normal.z * z + plane.constant < 0;
  }

  static bool _insidePlane(Aabb3 bounds, Plane plane) {
    final normal = plane.normal;
    final x = normal.x < 0 ? bounds.max.x : bounds.min.x;
    final y = normal.y < 0 ? bounds.max.y : bounds.min.y;
    final z = normal.z < 0 ? bounds.max.z : bounds.min.z;
    return normal.x * x + normal.y * y + normal.z * z + plane.constant >= 0;
  }

  /// Node-local aggregate AABB covering every instance, used to
  /// frustum-cull an instanced item as a single unit.
  ///
  /// `null` means the instanced item is unbounded and always drawn.
  /// Ignored for non-instanced items.
  Aabb3? instanceBounds;

  /// The local-space AABB this item is frustum-culled against, or `null`
  /// when it should be treated as always visible.
  ///
  /// An instanced item uses its [instanceBounds]; a regular item uses its
  /// geometry's local bounds.
  Aabb3? get cullBounds =>
      instanceTransforms != null ? instanceBounds : geometry.localBounds;

  /// The AABB of [cullBounds] as this item draws it, or `null` when the item
  /// is unbounded: [cullBounds] transformed by [worldTransform], moved by
  /// the anchor minus the scene's draw origin for an anchored item.
  ///
  /// Refreshed by [refreshWorldBounds]. A move of the draw origin writes no
  /// bound: an anchored item restates this box when it is next read.
  Aabb3? get worldBounds {
    final placed = _placedBounds;
    final origin = drawOrigin;
    if (placed == null || !anchored || origin == null) return placed;
    final drawn = _drawnBounds ??= Aabb3();
    if (_drawnBoundsOrigin != origin.revision ||
        _drawnBoundsRevision != _placedBoundsRevision) {
      _drawnBoundsOrigin = origin.revision;
      _drawnBoundsRevision = _placedBoundsRevision;
      final x = anchor[0] - origin.at[0];
      final y = anchor[1] - origin.at[1];
      final z = anchor[2] - origin.at[2];
      drawn.min.setValues(
        placed.min.x + x,
        placed.min.y + y,
        placed.min.z + z,
      );
      drawn.max.setValues(
        placed.max.x + x,
        placed.max.y + y,
        placed.max.z + z,
      );
    }
    return drawn;
  }

  /// States the box [refreshWorldBounds] computes, in the space of
  /// [worldTransform].
  set worldBounds(Aabb3? value) {
    _placedBounds = value;
    _placedBoundsRevision++;
  }

  // [cullBounds] transformed by [worldTransform], which leaves an anchor
  // out.
  Aabb3? _placedBounds;
  int _placedBoundsRevision = 0;
  Aabb3? _drawnBounds;
  int _drawnBoundsOrigin = -1;
  int _drawnBoundsRevision = -1;

  /// Writes the box the scene's spatial structure holds for this item into
  /// [into], six floats from [offset]: [worldBounds] in the space no draw
  /// origin moves, which is the anchor's for an anchored item and the draw
  /// origin's own otherwise. The box grows by the 32-bit rounding of a
  /// coordinate that far from zero, so it never leaves out a point of the
  /// item.
  @internal
  void writeTreeBounds(Float32List into, int offset) {
    final placed = _placedBounds!;
    final origin = drawOrigin;
    var x = 0.0, y = 0.0, z = 0.0;
    if (anchored) {
      x = anchor[0];
      y = anchor[1];
      z = anchor[2];
    } else if (origin != null) {
      x = origin.at[0];
      y = origin.at[1];
      z = origin.at[2];
    }
    if (x == 0.0 && y == 0.0 && z == 0.0) {
      into[offset] = placed.min.x;
      into[offset + 1] = placed.min.y;
      into[offset + 2] = placed.min.z;
      into[offset + 3] = placed.max.x;
      into[offset + 4] = placed.max.y;
      into[offset + 5] = placed.max.z;
      return;
    }
    _writePadded(into, offset, placed.min.x + x, -1);
    _writePadded(into, offset + 1, placed.min.y + y, -1);
    _writePadded(into, offset + 2, placed.min.z + z, -1);
    _writePadded(into, offset + 3, placed.max.x + x, 1);
    _writePadded(into, offset + 4, placed.max.y + y, 1);
    _writePadded(into, offset + 5, placed.max.z + z, 1);
  }

  // Four steps of a 32-bit float at [value], outward.
  static void _writePadded(Float32List into, int at, double value, int side) {
    into[at] = value + side * (value.abs() * 4.8e-7 + 1e-30);
  }

  // Reused across [refreshWorldBounds] calls so a steady-state refresh
  // allocates nothing.
  static final Aabb3 _worldBoundsScratch = Aabb3();

  /// Recomputes [worldBounds] from [cullBounds] and [worldTransform], and
  /// returns whether the value changed since the previous call.
  ///
  /// Call after refreshing [worldTransform]. The owning component uses
  /// the return value to know when the spatial structure is stale.
  bool refreshWorldBounds() {
    final local = cullBounds;
    if (local == null) {
      if (_placedBounds == null) return false;
      _placedBounds = null;
      return true;
    }
    _worldBoundsScratch
      ..copyFrom(local)
      ..transform(worldTransform);
    final current = _placedBounds;
    if (current == null) {
      _placedBounds = Aabb3.copy(_worldBoundsScratch);
      _placedBoundsRevision++;
      return true;
    }
    if (current.min == _worldBoundsScratch.min &&
        current.max == _worldBoundsScratch.max) {
      return false;
    }
    current.copyFrom(_worldBoundsScratch);
    _placedBoundsRevision++;
    return true;
  }
}

/// The anchor of the item being bound, as `[x, y, z]`, or null for an item
/// with no anchor (see `Node.setAnchor`).
///
/// A [Geometry] that binds its own uniforms reads this and
/// [currentDrawOrigin] in `bind` to keep a retained block: it holds the
/// anchor in the block of the draw and the origin in a block every draw of
/// the frame shares, and its vertex stage adds their difference to a position
/// placed by the item's held record. The model transform `bind` receives
/// holds that difference already, for a geometry that writes it per draw.
Float64List? get currentDrawAnchor => _currentDrawAnchor;
Float64List? _currentDrawAnchor;

/// The draw origin of the scene whose item is being bound, as `[x, y, z]`,
/// or null for an item with no anchor. See [currentDrawAnchor].
Float64List? get currentDrawOrigin => _currentDrawOrigin;
Float64List? _currentDrawOrigin;

/// The point a scene draws from, see `Scene.drawOrigin`.
@internal
class DrawOrigin {
  /// The origin of the frame being drawn.
  final Float64List at = Float64List(3);

  /// The origin of the frame drawn before.
  final Float64List previous = Float64List(3);

  /// Counts the moves of [at].
  int revision = 0;

  /// Moves [at], and returns whether it changed.
  bool moveTo(double x, double y, double z) {
    if (at[0] == x && at[1] == y && at[2] == z) return false;
    at
      ..[0] = x
      ..[1] = y
      ..[2] = z;
    revision++;
    return true;
  }

  /// Whether the frame drawn before drew from another point.
  bool get moved =>
      at[0] != previous[0] || at[1] != previous[1] || at[2] != previous[2];

  /// States that a frame drew from [at].
  void frameDrawn() => previous.setAll(0, at);
}

/// The retained render layer for a `Scene`: every [RenderItem], plus a
/// spatial structure the render passes cull against.
///
/// The node graph registers and unregisters items as mesh-bearing nodes
/// are mounted into and out of the scene. Bounded items are placed in a
/// [Bvh]; unbounded items (no [RenderItem.worldBounds], or
/// [RenderItem.frustumCulled] off) are always visited.
class RenderScene {
  /// Every registered render item, in no particular order.
  final List<RenderItem> items = [];

  /// The nodes this scene ticks and refreshes before a frame.
  @internal
  final ScenePrePass prePass = ScenePrePass();

  int _renderSourceRevision = renderSourceRevision;

  /// Ticks the nodes that need every frame, then refreshes the render items
  /// of the nodes that changed, and returns how many nodes it visited. Called
  /// by the scene once per frame; it walks no node tree.
  int runPrePass(double deltaSeconds) =>
      prePass.tick(deltaSeconds) + refreshChangedNodes(uploadSkin: true);

  /// Refreshes the render items of the nodes that changed without ticking
  /// any, so a query between frames reads the items the next frame draws.
  /// Without [uploadSkin] a skinned node keeps the joints its last frame
  /// uploaded. Returns how many nodes it refreshed.
  int refreshChangedNodes({bool uploadSkin = false}) {
    final revision = renderSourceRevision;
    if (revision != _renderSourceRevision) {
      _renderSourceRevision = revision;
      for (final item in items) {
        final node = item.sourceNode;
        if (node is PrePassNode) prePass.markChanged(node);
      }
    }
    return prePass.refresh(uploadSkin: uploadSkin);
  }

  /// The directional lights contributed by mounted
  /// [DirectionalLightComponent]s, in registration order.
  final List<DirectionalLightComponent> directionalLights = [];

  /// Selects the directional light used by features that currently accept one
  /// light, including cascaded shadows and sun scattering.
  ///
  /// Higher explicit priority wins. Equal priorities use emitted luminance,
  /// matching the usual dominant-light fallback. Registration order is only
  /// the final tie breaker for otherwise equivalent lights.
  // TODO(directional-shadows): allocate cascade atlas slots per light so more
  // than one directional light can cast shadows in the same view.
  DirectionalLightComponent? get primaryDirectionalLight {
    DirectionalLightComponent? best;
    var bestPriority = 0;
    var bestStrength = 0.0;
    for (final component in directionalLights) {
      // A hidden node's light does not contribute.
      if (!component.node.internalEffectiveVisible) continue;
      final light = component.light;
      final strength =
          light.intensity *
          (light.color.x * 0.2126 +
              light.color.y * 0.7152 +
              light.color.z * 0.0722);
      if (best == null ||
          light.priority > bestPriority ||
          (light.priority == bestPriority && strength > bestStrength)) {
        best = component;
        bestPriority = light.priority;
        bestStrength = strength;
      }
    }
    return best;
  }

  /// Registers [light] as an active directional light. Called by a
  /// [DirectionalLightComponent] when its owning node mounts.
  void addDirectionalLight(DirectionalLightComponent light) {
    directionalLights.add(light);
  }

  /// The mounted widget components, in registration order. `SceneView`
  /// listens to [widgetComponentsChanged] and hosts each component's widget
  /// subtree invisibly.
  final List<Object> widgetComponents = [];

  /// Bumped whenever [widgetComponents] changes.
  final ValueNotifier<int> widgetComponentsChanged = ValueNotifier<int>(0);

  /// Registers a mounted widget component (typed as Object to keep this
  /// render-layer file free of a widgets dependency).
  void addWidgetComponent(Object component) {
    widgetComponents.add(component);
    widgetComponentsChanged.value++;
  }

  /// Unregisters an unmounted widget component.
  void removeWidgetComponent(Object component) {
    widgetComponents.remove(component);
    widgetComponentsChanged.value++;
  }

  /// The mounted [SemanticsComponent]s, in registration order. `SceneView`
  /// projects each one's node bounds into its semantics tree while
  /// assistive technology is active.
  final List<SemanticsComponent> semanticsComponents = [];

  /// Bumped whenever [semanticsComponents] changes.
  final ValueNotifier<int> semanticsComponentsChanged = ValueNotifier<int>(0);

  /// Registers a mounted semantics component. Called by a
  /// [SemanticsComponent] when its owning node mounts.
  void addSemanticsComponent(SemanticsComponent component) {
    semanticsComponents.add(component);
    semanticsComponentsChanged.value++;
  }

  /// Unregisters an unmounted semantics component.
  void removeSemanticsComponent(SemanticsComponent component) {
    semanticsComponents.remove(component);
    semanticsComponentsChanged.value++;
  }

  /// Unregisters [light]. Called when its owning node unmounts.
  void removeDirectionalLight(DirectionalLightComponent light) {
    directionalLights.remove(light);
  }

  /// The point lights contributed by mounted [PointLightComponent]s, in
  /// registration order. Collected into the per-frame punctual light buffer.
  final List<PointLightComponent> pointLights = [];

  /// Registers [light] as an active point light. Called by a
  /// [PointLightComponent] when its owning node mounts.
  void addPointLight(PointLightComponent light) {
    pointLights.add(light);
  }

  /// Unregisters [light]. Called when its owning node unmounts.
  void removePointLight(PointLightComponent light) {
    pointLights.remove(light);
  }

  /// The rect area lights contributed by mounted [RectAreaLightComponent]s,
  /// in registration order. Collected into the per-frame punctual light
  /// buffer.
  final List<RectAreaLightComponent> rectAreaLights = [];

  /// Registers [light] as an active rect area light. Called by a
  /// [RectAreaLightComponent] when its owning node mounts.
  void addRectAreaLight(RectAreaLightComponent light) {
    rectAreaLights.add(light);
  }

  /// Unregisters [light]. Called when its owning node unmounts.
  void removeRectAreaLight(RectAreaLightComponent light) {
    rectAreaLights.remove(light);
  }

  /// The spot lights contributed by mounted [SpotLightComponent]s, in
  /// registration order. Collected into the per-frame punctual light buffer.
  final List<SpotLightComponent> spotLights = [];

  /// Registers [light] as an active spot light. Called by a
  /// [SpotLightComponent] when its owning node mounts.
  void addSpotLight(SpotLightComponent light) {
    spotLights.add(light);
  }

  /// Unregisters [light]. Called when its owning node unmounts.
  void removeSpotLight(SpotLightComponent light) {
    spotLights.remove(light);
  }

  /// The environment volumes contributed by mounted
  /// [EnvironmentVolumeComponent]s, in registration order. Folded into the
  /// scene's environment blend by camera position each frame.
  final List<EnvironmentVolumeComponent> environmentVolumeComponents = [];

  /// Registers [volume] as an active environment volume. Called by an
  /// [EnvironmentVolumeComponent] when its owning node mounts.
  void addEnvironmentVolumeComponent(EnvironmentVolumeComponent volume) {
    environmentVolumeComponents.add(volume);
  }

  /// Unregisters [volume]. Called when its owning node unmounts.
  void removeEnvironmentVolumeComponent(EnvironmentVolumeComponent volume) {
    environmentVolumeComponents.remove(volume);
  }

  /// The irradiance volumes contributed by mounted
  /// [IrradianceVolumeComponent]s, in registration order. At most one is
  /// active per frame, chosen by priority among those containing the camera.
  final List<IrradianceVolumeComponent> irradianceVolumeComponents = [];

  /// Registers [volume] as an active irradiance volume. Called by an
  /// [IrradianceVolumeComponent] when its owning node mounts.
  void addIrradianceVolumeComponent(IrradianceVolumeComponent volume) {
    irradianceVolumeComponents.add(volume);
  }

  /// Unregisters [volume]. Called when its owning node unmounts.
  void removeIrradianceVolumeComponent(IrradianceVolumeComponent volume) {
    irradianceVolumeComponents.remove(volume);
  }

  /// The reflection probes contributed by mounted
  /// [ReflectionProbeComponent]s, in registration order. Each contributes
  /// its captured environment to the image-based-lighting cross-fade by
  /// camera position, and pending captures render before the frame's views.
  final List<ReflectionProbeComponent> reflectionProbeComponents = [];

  /// Registers [probe] as an active reflection probe. Called by a
  /// [ReflectionProbeComponent] when its owning node mounts.
  void addReflectionProbeComponent(ReflectionProbeComponent probe) {
    reflectionProbeComponents.add(probe);
  }

  /// Unregisters [probe]. Called when its owning node unmounts.
  void removeReflectionProbeComponent(ReflectionProbeComponent probe) {
    reflectionProbeComponents.remove(probe);
  }

  /// The planar reflectors contributed by mounted
  /// [PlanarReflectorComponent]s, in registration order. Each visible one
  /// renders a per-frame mirrored scene capture before the primary view's
  /// scene pass.
  final List<PlanarReflectorComponent> planarReflectorComponents = [];

  /// Registers [reflector] as an active planar reflector. Called by a
  /// [PlanarReflectorComponent] when its owning node mounts.
  void addPlanarReflectorComponent(PlanarReflectorComponent reflector) {
    planarReflectorComponents.add(reflector);
  }

  /// Unregisters [reflector]. Called when its owning node unmounts.
  void removePlanarReflectorComponent(PlanarReflectorComponent reflector) {
    planarReflectorComponents.remove(reflector);
  }

  /// The mounted [CameraComponent]s, in mount order. The first is the
  /// auto-promoted primary when no [cameraOverride] is set.
  final List<CameraComponent> cameras = [];

  /// An explicit primary-camera override, set through `Scene.camera`. When
  /// non-null it wins over auto-promotion; when null the primary resolves to
  /// the first mounted [CameraComponent], or null when there are none.
  Camera? cameraOverride;

  /// Registers [camera] as a mounted camera. Called by a [CameraComponent]
  /// when its owning node mounts.
  void addCamera(CameraComponent camera) {
    cameras.add(camera);
  }

  /// Unregisters [camera]. Called when its owning node unmounts.
  void removeCamera(CameraComponent camera) {
    cameras.remove(camera);
  }

  /// The scene's primary camera: the explicit [cameraOverride] if set, else
  /// the first mounted [CameraComponent]'s camera, else null.
  Camera? get primaryCamera =>
      cameraOverride ?? (cameras.isEmpty ? null : cameras.first.toCamera());

  Camera? _lastViewCamera;

  /// The camera of the first on-screen view the last frame rendered (or of
  /// its first view when all render offscreen), or null before a frame.
  Camera? get lastViewCamera => _lastViewCamera;

  /// Records the views a frame renders, so [listenerCamera] can follow the
  /// first on-screen one (or the first view when all render offscreen).
  void recordRenderedViews(List<RenderView> views) {
    if (views.isEmpty) return;
    _lastViewCamera = views
        .firstWhere((view) => view.target == null, orElse: () => views.first)
        .camera;
  }

  /// The camera the audio listener follows when no `AudioListener` is
  /// mounted: [primaryCamera], else the camera of the last recorded on-screen
  /// view (a `SceneView`'s camera or camera builder). A tick that runs before
  /// render sees the previous frame's view, so the ears trail a moving view
  /// camera by one frame.
  Camera? get listenerCamera => primaryCamera ?? _lastViewCamera;

  late Bvh _bvh = Bvh.build([])..origin = drawOrigin.at;
  int _structureRevision = 0;
  int _staticShadowRevision = 0;

  /// Changes when render items are added or removed.
  int get structureRevision => _structureRevision;

  /// Changes when a retained static shadow caster changes.
  int get staticShadowRevision => _staticShadowRevision;

  /// Invalidates the cached static-caster fingerprint after [item] became,
  /// stopped being or changed as a static shadow caster. Without an item
  /// every item is read again.
  void markStaticShadowDirty([RenderItem? item]) {
    _staticShadowRevision++;
    if (item == null) {
      _staticCastersUnknown = true;
    } else {
      _staticCasterChanges.add(item);
    }
  }

  int _staticCasters = 0;
  bool _staticCastersUnknown = false;
  final List<RenderItem> _staticCasterChanges = [];

  /// Whether any item is a visible static shadow caster. Kept as a count the
  /// items named to [markStaticShadowDirty] and the removed items change, so
  /// no frame reads every item for it.
  bool get hasStaticShadowCasters {
    if (_staticCastersUnknown) {
      _staticCastersUnknown = false;
      _staticCasters = 0;
      for (final item in items) {
        item._countedStaticCaster = item.isStaticShadowCaster;
        if (item._countedStaticCaster) _staticCasters++;
      }
    } else {
      for (final item in _staticCasterChanges) {
        if (item.sceneSlot < 0) continue;
        final casts = item.isStaticShadowCaster;
        if (casts == item._countedStaticCaster) continue;
        item._countedStaticCaster = casts;
        _staticCasters += casts ? 1 : -1;
      }
    }
    _staticCasterChanges.clear();
    return _staticCasters > 0;
  }

  /// The spatial structure over the bounded items, current after
  /// [rebuildIfDirty]. Used by the light culler to scatter each light onto the
  /// items it reaches.
  Bvh get bvh => _bvh;

  final List<RenderItem> _alwaysVisible = [];

  // The items to place in the tree or among the always visible: those added
  // and those whose membership changed.
  final List<RenderItem> _unplaced = [];

  // Every item is placed again: the membership of an unnamed item changed.
  bool _structureDirty = false;

  // A bounded item moved; the BVH refits.
  bool _boundsDirty = false;

  /// The point this scene draws from, see `Scene.drawOrigin`.
  final DrawOrigin drawOrigin = DrawOrigin();

  // The draw origin the tree's boxes of items with no anchor were written
  // from, and how many such items the tree holds.
  int _treeOrigin = 0;
  int _unanchoredInTree = 0;

  void add(RenderItem item) {
    item.drawOrigin = drawOrigin;
    item.sceneSlot = items.length;
    items.add(item);
    _unplaced.add(item);
    _structureRevision++;
  }

  void remove(RenderItem item) {
    final slot = item.sceneSlot;
    if (slot < 0) return;
    final last = items.removeLast();
    if (!identical(last, item)) {
      items[slot] = last;
      last.sceneSlot = slot;
    }
    item.sceneSlot = -1;
    item.heldInstanceRecord.release();
    _displace(item);
    if (item._countedStaticCaster) {
      item._countedStaticCaster = false;
      _staticCasters--;
      _staticShadowRevision++;
    } else if (item.isStaticShadowCaster) {
      _staticShadowRevision++;
    }
    _structureRevision++;
  }

  // Takes [item] out of the tree or of the always visible.
  void _displace(RenderItem item) {
    item._placed = false;
    if (item.bvhNode >= 0 && !item._treeAnchored) _unanchoredInTree--;
    _bvh.remove(item);
    final slot = item._alwaysVisibleSlot;
    if (slot < 0) return;
    final last = _alwaysVisible.removeLast();
    if (!identical(last, item)) {
      _alwaysVisible[slot] = last;
      last._alwaysVisibleSlot = slot;
    }
    item._alwaysVisibleSlot = -1;
  }

  void _place(RenderItem item) {
    if (item._placed || item.sceneSlot < 0) return;
    item._placed = true;
    if (item.frustumCulled && item.worldBounds != null) {
      item._treeAnchored = item.anchored;
      if (!item.anchored) _unanchoredInTree++;
      _bvh.insert(item);
    } else {
      item._alwaysVisibleSlot = _alwaysVisible.length;
      _alwaysVisible.add(item);
    }
  }

  /// States that the BVH membership of [item] changed (its `frustumCulled`
  /// flag toggled, or it became bounded or unbounded), so it is placed
  /// again. Without an item every item is.
  void markBvhStructureDirty([RenderItem? item]) {
    if (item == null) {
      _structureDirty = true;
    } else if (item._placed) {
      _displace(item);
      _unplaced.add(item);
    }
  }

  /// Flags the BVH for a refit. Called when a bounded item moved but the
  /// item set and membership are unchanged.
  void markBvhBoundsDirty() {
    _boundsDirty = true;
  }

  /// Brings the spatial structure up to date with the current items.
  /// Call once per frame, after the pre-pass and before the render
  /// passes. Places the items added since and those whose membership
  /// changed, each by one insert, and refits when an item moved. The tree
  /// is built in one sort only where it holds no item yet, as on the first
  /// frame of a scene.
  void rebuildIfDirty() {
    if (_structureDirty || (_bvh.itemCount == 0 && _unplaced.length > 1)) {
      _structureDirty = false;
      _boundsDirty = false;
      _unplaced.clear();
      _alwaysVisible.clear();
      _unanchoredInTree = 0;
      _treeOrigin = drawOrigin.revision;
      final bounded = <RenderItem>[];
      for (final item in items) {
        item
          .._placed = true
          ..bvhNode = -1
          .._alwaysVisibleSlot = -1;
        if (item.frustumCulled && item.worldBounds != null) {
          item._treeAnchored = item.anchored;
          if (!item.anchored) _unanchoredInTree++;
          bounded.add(item);
        } else {
          item._alwaysVisibleSlot = _alwaysVisible.length;
          _alwaysVisible.add(item);
        }
      }
      _bvh = Bvh.build(bounded)..origin = drawOrigin.at;
      return;
    }
    if (_unplaced.isNotEmpty) {
      for (final item in _unplaced) {
        _place(item);
      }
      _unplaced.clear();
    }
    // A box of an item with no anchor is stated from the draw origin, so it
    // is written again once the origin moves. An anchored item's holds.
    if (_treeOrigin != drawOrigin.revision) {
      _treeOrigin = drawOrigin.revision;
      if (_unanchoredInTree > 0) _boundsDirty = true;
    }
    if (_boundsDirty) {
      _boundsDirty = false;
      _bvh.refit();
    }
  }

  /// Visits every item potentially visible to [frustum]: the bounded
  /// items whose world AABB intersects it, plus every always-visible
  /// item.
  ///
  /// Returns how many bounded items the BVH rejected without ever visiting
  /// them. Every pass culls against its own frustum, so the count is
  /// returned rather than recorded here; only the color pass charges it to
  /// the render stats.
  int cull(
    Frustum frustum,
    void Function(RenderItem) visit, {
    List<Plane> additionalPlanes = const [],
  }) {
    final visited = _bvh.query(
      frustum,
      visit,
      additionalPlanes: additionalPlanes,
    );
    for (final item in _alwaysVisible) {
      visit(item);
    }
    return _bvh.itemCount - visited;
  }

  /// The smallest lower bound on planar view depth, along [forward] from
  /// [eye], over the items drawn into a perspective view (layers in
  /// [layerMask]) through [frustum], whose corner ray makes an angle with
  /// forward of cosine [cosHalfAngle]. A view can raise its near plane to
  /// this without clipping anything it draws.
  ///
  /// [nearest] is the item that set the bound, so a caller can name what
  /// pins the plane (an unbounded item, or one whose bounds hold the eye).
  ///
  /// The search stops as soon as the bound reaches [floor] (a depth below
  /// which the caller cannot use it), which keeps it cheap when something is
  /// close to the camera.
  ({double depth, RenderItem? nearest}) nearestVisibleDepth({
    required Frustum frustum,
    required Vector3 eye,
    required Vector3 forward,
    required double cosHalfAngle,
    int layerMask = kRenderLayerAll,
    List<Plane> additionalPlanes = const [],
    double floor = 0.0,
  }) {
    RenderItem? nearest;
    var best = double.infinity;
    for (final item in _alwaysVisible) {
      if (!item.drawsColor || (item.layers & layerMask) == 0) continue;
      final bound = item.depthLowerBound(
        frustum,
        eye,
        forward,
        cosHalfAngle,
        best,
        floor: floor,
      );
      if (bound < best) {
        best = bound;
        nearest = item;
        if (best <= floor) return (depth: best, nearest: nearest);
      }
    }
    best = _bvh.nearestBound(
      frustum,
      eye,
      forward,
      cosHalfAngle,
      (item, currentBest) {
        if (!item.drawsColor || (item.layers & layerMask) == 0) {
          return double.infinity;
        }
        final bound = item.depthLowerBound(
          frustum,
          eye,
          forward,
          cosHalfAngle,
          currentBest,
          floor: floor,
        );
        if (bound < currentBest) nearest = item;
        return bound;
      },
      additionalPlanes: additionalPlanes,
      best: best,
      floor: floor,
    );
    return (depth: best, nearest: nearest);
  }

  /// Collects material inputs requested by this view's frustum candidates.
  Set<RenderInput> collectMaterialInputs(
    Frustum frustum, {
    int layerMask = kRenderLayerAll,
    List<Plane> additionalPlanes = const [],
    bool includeOffscreen = false,
  }) {
    final inputs = <RenderInput>{};
    void collect(RenderItem item) {
      if (!item.drawsColor || (item.layers & layerMask) == 0) {
        return;
      }
      inputs.addAll(item.material.sceneInputs);
      final lod = item.lod;
      if (lod != null) {
        for (final level in lod.levels) {
          inputs.addAll(level.material.sceneInputs);
        }
      }
    }

    if (includeOffscreen) {
      for (final item in items) {
        collect(item);
      }
    } else {
      cull(frustum, collect, additionalPlanes: additionalPlanes);
    }
    return inputs;
  }

  /// Whether any registered item's material (or LOD level's) satisfies [test],
  /// visible or not.
  bool anyMaterial(bool Function(Material material) test) {
    for (final item in items) {
      if (test(item.material)) return true;
      final lod = item.lod;
      if (lod == null) continue;
      for (final level in lod.levels) {
        if (test(level.material)) return true;
      }
    }
    return false;
  }

  /// Collects material inputs without view-dependent culling.
  Set<RenderInput> collectAllMaterialInputs() {
    final inputs = <RenderInput>{};
    for (final item in items) {
      inputs.addAll(item.material.sceneInputs);
      final lod = item.lod;
      if (lod != null) {
        for (final level in lod.levels) {
          inputs.addAll(level.material.sceneInputs);
        }
      }
    }
    return inputs;
  }
}

extension on Aabb3 {
  double depthLowerBound(Vector3 eye, Vector3 forward, double cosHalfAngle) =>
      aabbDepthLowerBound(
        min.x,
        min.y,
        min.z,
        max.x,
        max.y,
        max.z,
        eye.x,
        eye.y,
        eye.z,
        forward.x,
        forward.y,
        forward.z,
        cosHalfAngle,
      );
}
