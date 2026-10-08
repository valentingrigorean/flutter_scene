import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/draw_revision.dart';
import 'package:flutter_scene/src/instance_band.dart';
import 'package:flutter_scene/src/fmat/fmat_ast.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/material/instance_attributes.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/mesh_draw.dart';
import 'package:vector_math/vector_math.dart';

/// Many copies of one [Geometry] / [Material] pair, each placed by its
/// own model transform.
///
/// Use an `InstancedMesh` for foliage, crowds, debris, or any scene that
/// holds many copies of the same mesh. Attach it to a node with an
/// [InstancedMeshComponent]; the whole set is then one render item, one
/// pipeline, and one cull test rather than one node per copy.
///
/// Instances with different colors whose faces overlap in one plane flicker
/// against each other (z-fighting); place repeated pieces so they abut.
///
/// {@category Scene graph}
class InstancedMesh implements MeshDrawSource {
  /// Creates an instanced mesh that draws [geometry] shaded by
  /// [material]. It starts with no instances; add them with
  /// [addInstance].
  InstancedMesh({
    required this.geometry,
    required this.material,
    this.cullInstances = false,
    this.sortTransparentInstances = true,
    this.nodeSpaceInstances = false,
  }) : rows = null;

  /// A mesh that draws the rows of [rows] with its own [geometry] and
  /// [material].
  ///
  /// It holds no row: every row write goes to [rows] and reaches each mesh
  /// sharing it, and a row write on this mesh throws. The records are
  /// node-space (see [nodeSpaceInstances]), so one packed store and one
  /// device buffer serve [rows] and every mesh sharing it, under any node.
  /// The rows are neither culled nor sorted per instance, and all of them
  /// have one winding. [rows] itself needs no node.
  ///
  /// The meshes of the levels of detail of one model, of the parts of one
  /// file and of a second view share one row set this way, each with its
  /// [instanceRanges], [instanceLocal] and [band].
  InstancedMesh.sharing(
    InstancedMesh this.rows, {
    required this.geometry,
    required this.material,
  }) : cullInstances = false,
       sortTransparentInstances = false,
       nodeSpaceInstances = true,
       assert(rows.rows == null, 'Share the mesh that holds the rows.'),
       assert(
         material.instanceAttributes == null,
         'A shared record carries no instance attribute.',
       ),
       assert(
         rows.nodeSpaceInstances,
         'A shared row set holds node-space records.',
       );

  /// The mesh whose rows this mesh draws, or null when it draws its own.
  final InstancedMesh? rows;

  /// The rows this mesh draws, as pairs of a first row and a row count, or
  /// null for every row.
  ///
  /// Each pass issues one instanced draw per pair from the device buffer of
  /// the records, so stating other ranges uploads nothing. An empty list
  /// draws nothing. Ranges apply to a mesh of node-space records whose rows
  /// rest between frames and have one winding; such a mesh is neither culled
  /// nor sorted per instance.
  Uint32List? get instanceRanges => _instanceRanges;
  Uint32List? _instanceRanges;
  set instanceRanges(Uint32List? value) {
    assert(value == null || value.length.isEven);
    _instanceRanges = value;
    _drawStateChanged();
  }

  /// The transform applied to a vertex before its row's record, or null for
  /// none: a vertex lands at `node * record * instanceLocal * vertex`.
  ///
  /// The placement of one part of a model inside the model goes here, so the
  /// record is the row's transform alone and the parts share one row set.
  /// Read by the unskinned vertex stage of a mesh of node-space records.
  Matrix4? get instanceLocal => _instanceLocal;
  Matrix4? _instanceLocal;
  set instanceLocal(Matrix4? value) {
    _instanceLocal = value;
    _boundsRevision = -1;
    _drawStateChanged();
  }

  /// The rows the vertex stage keeps, or null to keep every row. See
  /// [InstanceBand].
  ///
  /// Call [bandChanged] after writing a field of the band this holds.
  InstanceBand? get band => _band;
  InstanceBand? _band;
  set band(InstanceBand? value) {
    _band = value;
    _drawStateChanged();
  }

  /// States that a field of [band] changed, so a frame held for an unchanged
  /// scene is drawn again.
  void bandChanged() => _drawStateChanged();

  /// Counts the changes of [instanceRanges], [instanceLocal] and [band], so
  /// the component refreshes the bounds and the cached shadows they decide.
  @internal
  int get drawStateRevision => _drawStateRevision;
  int _drawStateRevision = 0;

  void _drawStateChanged() {
    _drawStateRevision++;
    markSceneDrawChanged();
  }

  StateError _sharedRows() =>
      StateError('This mesh draws the rows of another mesh; write them there.');

  /// The geometry drawn for every instance.
  final Geometry geometry;

  /// The material every instance is shaded with.
  final Material material;

  /// Whether the renderer culls each instance after the aggregate bounds pass.
  ///
  /// Enable this for large spatial groups whose individual instances can enter
  /// the view at different times. Small compact groups are usually cheaper to
  /// draw after the single aggregate cull.
  final bool cullInstances;

  /// Whether translucent instances are sorted back to front before drawing.
  ///
  /// Disable this for dense particles or other order-independent batches when
  /// the sort costs more than the small blending difference it produces.
  final bool sortTransparentInstances;

  /// Whether the renderer keeps each instance record relative to the owning
  /// node and sends the node's world transform to the vertex stage as one
  /// uniform.
  ///
  /// Moving the node then rewrites no instance record, so the retained
  /// instance buffer of a large spatial cell survives a move of the whole
  /// cell. Such a mesh draws alone from its own buffer in every pass: it joins
  /// no cross-node batch, and the renderer culls it by its aggregate bounds
  /// only, whatever [cullInstances] states. The geometry needs an instanced
  /// vertex layout; other geometry draws as if this were false.
  final bool nodeSpaceInstances;

  /// Picks how many leading instances and which index range each draw uses,
  /// or null to draw everything. Order instances so the ones worth keeping
  /// come first. See [MeshDrawSelector].
  @override
  MeshDrawSelector? drawSelector;

  final List<Matrix4> _instances = [];
  final List<Vector4> _colors = [];
  final List<bool> _windingFlipped = [];
  List<Matrix4>? _instanceUpdateView;

  Aabb3? _boundsCache;
  int _boundsRevision = -1;
  int _boundsGeometryVersion = -1;
  Float32List _rowBounds = Float32List(0);
  int _revision = 0;

  // The rows each revision since [_changedFrom] changed, one entry per
  // revision, so a consumer that saw an earlier revision rebuilds only those
  // rows. A change that moves rows (a removal before the last, a clear, a bulk
  // update) restarts the log, as does a log longer than the instances.
  final List<int> _changedRows = [];
  int _changedFrom = 0;

  void _rowChanged(int index) {
    _revision++;
    if (_changedRows.length < _instances.length + 64) {
      _changedRows.add(index);
    } else {
      _changedRows.clear();
      _changedFrom = _revision;
    }
  }

  void _rowsMoved() {
    _revision++;
    _changedRows.clear();
    _changedFrom = _revision;
  }

  /// The rows changed after [revision], oldest first and possibly repeated,
  /// or null when a change since then moved rows, so every row must be read
  /// again. A row at or past [instanceCount] was removed from the end.
  @internal
  List<int>? rowsChangedSince(int revision) {
    final shared = rows;
    if (shared != null) return shared.rowsChangedSince(revision);
    if (revision < _changedFrom || revision > _revision) return null;
    return _changedRows.sublist(revision - _changedFrom);
  }

  /// The number of instances.
  int get instanceCount => (rows ?? this)._instances.length;

  /// Adds an instance placed by [transform] and returns its index.
  ///
  /// The matrix is copied, so later mutating [transform] does not affect
  /// the instance; use [setInstanceTransform] to move it.
  int addInstance(Matrix4 transform, {Vector4? color}) {
    if (rows != null) throw _sharedRows();
    _instances.add(transform.clone());
    _colors.add((color ?? _white).clone());
    _windingFlipped.add(transform.determinant() < 0);
    _growAttributeStorage();
    _rowChanged(_instances.length - 1);
    return _instances.length - 1;
  }

  static final Vector4 _white = Vector4(1, 1, 1, 1);

  /// Replaces the transform of the instance at [index].
  void setInstanceTransform(int index, Matrix4 transform) {
    if (rows != null) throw _sharedRows();
    _instances[index].setFrom(transform);
    _windingFlipped[index] = transform.determinant() < 0;
    _rowChanged(index);
  }

  /// Updates every instance transform in place and invalidates the batch once.
  ///
  /// [update] receives a fixed-length view. Mutate its matrices without adding,
  /// removing, or replacing entries. Set [recomputeWinding] to false only when
  /// the edits cannot change any transform's winding parity.
  void updateInstanceTransforms(
    void Function(List<Matrix4> transforms) update, {
    bool recomputeWinding = true,
  }) {
    if (rows != null) throw _sharedRows();
    try {
      update(_instanceUpdateView ??= UnmodifiableListView<Matrix4>(_instances));
    } finally {
      if (recomputeWinding) {
        for (var i = 0; i < _instances.length; i++) {
          _windingFlipped[i] = _instances[i].determinant() < 0;
        }
      }
      _rowsMoved();
    }
  }

  /// Replaces the color multiplier of the instance at [index].
  void setInstanceColor(int index, Vector4 color) {
    if (rows != null) throw _sharedRows();
    _colors[index].setFrom(color);
    _rowChanged(index);
  }

  /// Sets one declared per-instance attribute on the instance at [index].
  ///
  /// [name] must name an attribute in the bound material's
  /// `instance_attributes` list, and [value] must match its declared type: a
  /// `num` for `float`, or the matching [Vector2] / [Vector3] / [Vector4].
  /// An instance whose attributes are never set draws with zeros.
  /// {@category Scene graph}
  void setInstanceAttribute(int index, String name, Object value) {
    if (rows != null) throw _sharedRows();
    RangeError.checkValidIndex(index, _instances, 'index');
    final schema = _requireSchema(name);
    final slot = schema.slot(name);
    if (slot == null) {
      throw ArgumentError('Unknown instance attribute "$name".');
    }
    final offset = index * schema.floatCount + slot.floatOffset;
    switch ((slot.type, value)) {
      case (FmatType.float_, final num v):
        _attributeData[offset] = v.toDouble();
      case (FmatType.vec2, final Vector2 v):
        _attributeData.setAll(offset, v.storage);
      case (FmatType.vec3, final Vector3 v):
        _attributeData.setAll(offset, v.storage);
      case (FmatType.vec4, final Vector4 v):
        _attributeData.setAll(offset, v.storage);
      default:
        throw ArgumentError(
          'Instance attribute "$name" is ${slot.type.glslType}; cannot assign '
          'a ${value.runtimeType}.',
        );
    }
    _rowChanged(index);
  }

  /// Writes every declared per-instance attribute of the instance at [index]
  /// from [packed], in declaration order.
  ///
  /// This is the raw path for hot loops. [packed] is the instance's slice of
  /// the instance-rate record, so its length is the material's packed
  /// attribute width including the pad float a `vec3` carries; the throw names
  /// the expected length.
  /// {@category Scene graph}
  void setInstanceAttributes(int index, Float32List packed) {
    if (rows != null) throw _sharedRows();
    RangeError.checkValidIndex(index, _instances, 'index');
    final schema = _requireSchema(null);
    if (packed.length != schema.floatCount) {
      throw ArgumentError(
        'This material packs ${schema.floatCount} instance attribute float(s) '
        'per instance, but ${packed.length} were supplied.',
      );
    }
    _attributeData.setAll(index * schema.floatCount, packed);
    _rowChanged(index);
  }

  /// Removes the instance at [index]. Instances after it shift down by
  /// one, so their indices change.
  void removeInstanceAt(int index) {
    if (rows != null) throw _sharedRows();
    final schema = _syncAttributeStorage();
    if (schema != null) {
      final floats = schema.floatCount;
      final tail = (_instances.length - index - 1) * floats;
      if (tail > 0) {
        _attributeStore.setRange(
          index * floats,
          index * floats + tail,
          _attributeStore,
          (index + 1) * floats,
        );
      }
      _attributeUsed -= floats;
      _attributeView = null;
    }
    _instances.removeAt(index);
    _colors.removeAt(index);
    _windingFlipped.removeAt(index);
    if (index == _instances.length) {
      _rowChanged(index);
    } else {
      _rowsMoved();
    }
  }

  /// Removes every instance.
  void clearInstances() {
    if (rows != null) throw _sharedRows();
    _instances.clear();
    _colors.clear();
    _windingFlipped.clear();
    _attributeUsed = 0;
    _attributeView = null;
    _rowsMoved();
  }

  static final Float32List _noAttributes = Float32List(0);

  // The declaration comes from the bound material, so a hot reload that
  // changes it is picked up here and the stale packing is dropped. The store
  // grows geometrically and [_attributeUsed] is the live prefix, so filling a
  // large group one instance at a time stays linear.
  InstanceAttributeSchema? _attributeSchema;
  Float32List _attributeStore = _noAttributes;
  Float32List? _attributeView;
  int _attributeUsed = 0;

  Float32List get _attributeData => _attributeView ??= Float32List.sublistView(
    _attributeStore,
    0,
    _attributeUsed,
  );

  InstanceAttributeSchema? _syncAttributeStorage() {
    final schema = material.instanceAttributes;
    if (!identical(schema, _attributeSchema)) {
      _attributeSchema = schema;
      _attributeStore = _noAttributes;
      _attributeView = null;
      _attributeUsed = 0;
    }
    if (schema == null) return null;
    final needed = _instances.length * schema.floatCount;
    if (needed > _attributeStore.length) {
      var capacity = _attributeStore.isEmpty
          ? schema.floatCount
          : _attributeStore.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final grown = Float32List(capacity);
      grown.setRange(0, _attributeUsed, _attributeStore);
      _attributeStore = grown;
      _attributeView = null;
    } else if (needed > _attributeUsed) {
      // Capacity a removed instance left behind; a new instance starts zeroed.
      _attributeStore.fillRange(_attributeUsed, needed, 0);
    }
    if (needed != _attributeUsed) {
      _attributeUsed = needed;
      _attributeView = null;
    }
    return schema;
  }

  void _growAttributeStorage() {
    if (material.instanceAttributes != null) _syncAttributeStorage();
  }

  InstanceAttributeSchema _requireSchema(String? name) {
    final schema = _syncAttributeStorage();
    if (schema == null) {
      throw ArgumentError(
        name == null
            ? 'This mesh\'s material declares no instance attributes.'
            : 'Unknown instance attribute "$name".',
      );
    }
    return schema;
  }

  /// Packed per-instance attribute floats matching [instances], or null when
  /// the material declares none.
  @internal
  Float32List? get instanceAttributeData {
    final schema = _syncAttributeStorage();
    return schema == null ? null : _attributeData;
  }

  /// Attribute floats each instance record carries, zero when the material
  /// declares none.
  @internal
  int get instanceAttributeFloats =>
      material.instanceAttributes?.floatCount ?? 0;

  /// The live per-instance transform list the render item iterates.
  @internal
  List<Matrix4> get instances => (rows ?? this)._instances;

  /// Live per-instance linear RGBA multipliers.
  @internal
  List<Vector4> get colors => (rows ?? this)._colors;

  /// Per-instance local winding parity matching [instances].
  @internal
  List<bool> get windingFlipped => (rows ?? this)._windingFlipped;

  /// Changes whenever instance data changes.
  @internal
  int get revision => (rows ?? this)._revision;

  /// Aggregate AABB over every instance, in the instanced mesh's local
  /// space, or `null` when [geometry] has no computable bounds or there
  /// are no instances. Cached; after a change only the changed rows'
  /// bounds are transformed again before the hull.
  @internal
  Aabb3? get aggregateBounds {
    final geometryVersion = geometry.localBoundsVersion;
    if (_boundsRevision != revision ||
        _boundsGeometryVersion != geometryVersion) {
      final rows = _boundsGeometryVersion == geometryVersion
          ? rowsChangedSince(_boundsRevision)
          : null;
      _boundsCache = _computeAggregateBounds(rows);
      _boundsRevision = revision;
      _boundsGeometryVersion = geometryVersion;
    }
    return _boundsCache;
  }

  static final Aabb3 _rowScratch = Aabb3();

  Aabb3? _computeAggregateBounds(List<int>? rows) {
    final instances = this.instances;
    var base = geometry.localBounds;
    final count = instances.length;
    if (base == null || count == 0) return null;
    final local = _instanceLocal;
    if (local != null) base = Aabb3.copy(base)..transform(local);
    if (_rowBounds.length < count * 6) {
      final grown = Float32List(math.max(count, _rowBounds.length ~/ 3) * 6);
      if (rows != null) grown.setRange(0, _rowBounds.length, _rowBounds);
      _rowBounds = grown;
    }
    void boundRow(int row) {
      _rowScratch
        ..copyFrom(base!)
        ..transform(instances[row]);
      final offset = row * 6;
      _rowBounds
        ..[offset] = _rowScratch.min.x
        ..[offset + 1] = _rowScratch.min.y
        ..[offset + 2] = _rowScratch.min.z
        ..[offset + 3] = _rowScratch.max.x
        ..[offset + 4] = _rowScratch.max.y
        ..[offset + 5] = _rowScratch.max.z;
    }

    if (rows == null) {
      for (var row = 0; row < count; row++) {
        boundRow(row);
      }
    } else {
      for (final row in rows) {
        if (row < count) boundRow(row);
      }
    }
    final packed = _rowBounds;
    var minX = packed[0], minY = packed[1], minZ = packed[2];
    var maxX = packed[3], maxY = packed[4], maxZ = packed[5];
    for (var offset = 6; offset < count * 6; offset += 6) {
      minX = math.min(minX, packed[offset]);
      minY = math.min(minY, packed[offset + 1]);
      minZ = math.min(minZ, packed[offset + 2]);
      maxX = math.max(maxX, packed[offset + 3]);
      maxY = math.max(maxY, packed[offset + 4]);
      maxZ = math.max(maxZ, packed[offset + 5]);
    }
    return Aabb3.minMax(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ));
  }
}
