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
import 'package:flutter_scene/src/render/instance_record_ring.dart';
import 'package:flutter_scene/src/vertex_spin.dart';
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
  }) : rows = null,
       _ring = null;

  /// A mesh whose rows are instance records the caller packs, in the layout
  /// the vertex stage reads: sixteen floats of the row's transform, column
  /// major, four of its linear RGBA multiplier, then the floats of the
  /// material's `instance_attributes` in declaration order.
  ///
  /// Write rows with [setInstanceRecords] and drop the last ones with
  /// [truncateInstanceRecords]. The mesh keeps the floats and no object per
  /// row, and a write reaches the device as the rows it names, so a set that
  /// a worker packs costs the calling isolate one copy of what changed. The
  /// records are node-space (see [nodeSpaceInstances]), the rows are neither
  /// culled nor sorted per instance, and all of them have one winding, which
  /// [recordsMirrored] states. Other meshes draw the same rows through
  /// [InstancedMesh.sharing].
  InstancedMesh.records({required this.geometry, required this.material})
    : rows = null,
      cullInstances = false,
      sortTransparentInstances = false,
      nodeSpaceInstances = true,
      _ring = InstanceRecordRing();

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
       _ring = null,
       assert(rows.rows == null, 'Share the mesh that holds the rows.'),
       assert(
         material.instanceAttributes == null,
         'A shared record carries no instance attribute.',
       ),
       assert(
         rows.instanceAttributeFloats == 0,
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
    _spunLocal = _spunLocalOf(value, _spin);
    _boundsRevision = -1;
    _drawStateChanged();
  }

  /// The transform the vertex stage applies before a row's record and the
  /// turns of [spin]: [instanceLocal], taken into the spin's space when it
  /// states one.
  @internal
  Matrix4? get drawLocal => _spunLocal ?? _instanceLocal;
  Matrix4? _spunLocal;

  static Matrix4? _spunLocalOf(Matrix4? local, VertexSpin? spin) {
    final space = spin?.space;
    if (space == null) return null;
    return local == null ? space : space.multiplied(local);
  }

  /// The turns every row takes from the scene's animation time, between
  /// [instanceLocal] and the row's record, or null for none. See
  /// [VertexSpin], whose `space` here is the transform from the record's
  /// space to the one the lines are stated in.
  VertexSpin? get spin => _spin;
  VertexSpin? _spin;
  set spin(VertexSpin? value) {
    _spin = value;
    _spunLocal = _spunLocalOf(_instanceLocal, value);
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
    _tellRowListeners();
    markSceneDrawChanged();
  }

  StateError _sharedRows() =>
      StateError('This mesh draws the rows of another mesh; write them there.');

  void _checkListRows() {
    if (rows != null) throw _sharedRows();
    if (_ring != null) {
      throw StateError(
        'This mesh holds instance records; write them with '
        'setInstanceRecords.',
      );
    }
  }

  // The device copies of the records of a mesh that holds records, else null.
  final InstanceRecordRing? _ring;

  /// The mesh whose records the device holds for the draws of this mesh: the
  /// mesh whose rows it shares, itself when it holds records, or null when
  /// its render item packs the rows of its lists.
  @internal
  InstancedMesh? get recordSource => rows ?? (_ring == null ? null : this);

  /// Whether the rows this mesh draws are records (see
  /// [InstancedMesh.records]).
  bool get holdsRecords => (rows ?? this)._ring != null;

  /// The device copies of the records of a mesh that holds them.
  @internal
  InstanceRecordRing get recordRing => _ring!;

  /// The floats of one record: twenty, then those of the material's
  /// `instance_attributes`.
  int get instanceRecordFloats => 20 + instanceAttributeFloats;

  /// Whether the rows of a mesh that holds records mirror, which reverses the
  /// winding of every row. Rows of both windings need a mesh each.
  bool get recordsMirrored => (rows ?? this)._recordsMirrored;
  bool _recordsMirrored = false;
  set recordsMirrored(bool value) {
    _checkRecords();
    if (_recordsMirrored == value) return;
    _recordsMirrored = value;
    _revision++;
    _tellRowListeners();
  }

  void _checkRecords() {
    if (rows != null) throw _sharedRows();
    if (_ring == null) {
      throw StateError(
        'This mesh holds a list of instances; create it with '
        'InstancedMesh.records to write records.',
      );
    }
  }

  Float32List _recordStore = Float32List(0);
  Float32List _recordBounds = Float32List(0);
  ByteData? _recordStoreBytes;
  int _recordCount = 0;

  // The hull of the row bounds, which a row that leaves one of its faces
  // makes loose until it is read again.
  final Aabb3 _recordHull = Aabb3();
  bool _recordHullLoose = false;

  /// The whole record store of a mesh that holds records, past its rows too.
  @internal
  ByteData get recordStoreBytes =>
      _recordStoreBytes ??= ByteData.sublistView(_recordStore);

  /// Writes the rows from [first] on from [records], which holds whole
  /// records of [instanceRecordFloats] floats, and their bounds from
  /// [bounds]: six floats per row, the minimum then the maximum corner of
  /// the box the row's geometry fills in the space of the node.
  ///
  /// [first] is at most [instanceCount]; rows past the count are appended.
  /// The floats are copied. The mesh is culled by the hull of the row
  /// bounds, so a box that holds every mesh sharing the row keeps each of
  /// them drawn.
  void setInstanceRecords(
    int first,
    Float32List records, {
    required Float32List bounds,
  }) {
    _checkRecords();
    final width = instanceRecordFloats;
    final count = records.length ~/ width;
    if (count * width != records.length) {
      throw ArgumentError(
        'A record of this mesh is $width floats; ${records.length} do not '
        'hold whole records.',
      );
    }
    if (bounds.length != count * 6) {
      throw ArgumentError(
        '$count rows need ${count * 6} bounds floats, not ${bounds.length}.',
      );
    }
    RangeError.checkValueInInterval(first, 0, _recordCount, 'first');
    if (count == 0) return;
    final end = first + count;
    if (_recordStore.length < end * width) {
      final capacity = math.max(end, (_recordStore.length ~/ width) * 2);
      _recordStore = Float32List(capacity * width)
        ..setRange(0, _recordCount * width, _recordStore);
      _recordBounds = Float32List(capacity * 6)
        ..setRange(0, _recordCount * 6, _recordBounds);
      _recordStoreBytes = null;
    }
    final replaced = math.min(end, _recordCount);
    for (var row = first; row < replaced && !_recordHullLoose; row++) {
      _recordHullLoose = _touchesHull(row);
    }
    _recordStore.setRange(first * width, end * width, records);
    _recordBounds.setRange(first * 6, end * 6, bounds);
    if (_recordCount == 0) {
      _recordHull
        ..min.setValues(bounds[0], bounds[1], bounds[2])
        ..max.setValues(bounds[3], bounds[4], bounds[5]);
    }
    if (end > _recordCount) _recordCount = end;
    if (!_recordHullLoose) _growHull(first, end);
    _ring!.changed(first, count);
    _revision++;
    _tellRowListeners();
  }

  /// Drops the rows from [count] on of a mesh that holds records.
  void truncateInstanceRecords(int count) {
    _checkRecords();
    RangeError.checkValueInInterval(count, 0, _recordCount, 'count');
    if (count == _recordCount) return;
    for (var row = count; row < _recordCount && !_recordHullLoose; row++) {
      _recordHullLoose = _touchesHull(row);
    }
    _recordCount = count;
    if (count == 0) _recordHullLoose = false;
    _revision++;
    _tellRowListeners();
  }

  bool _touchesHull(int row) {
    final bounds = _recordBounds;
    final at = row * 6;
    final min = _recordHull.min;
    final max = _recordHull.max;
    return bounds[at] <= min.x ||
        bounds[at + 1] <= min.y ||
        bounds[at + 2] <= min.z ||
        bounds[at + 3] >= max.x ||
        bounds[at + 4] >= max.y ||
        bounds[at + 5] >= max.z;
  }

  void _growHull(int first, int end) {
    final bounds = _recordBounds;
    final min = _recordHull.min;
    final max = _recordHull.max;
    var minX = min.x, minY = min.y, minZ = min.z;
    var maxX = max.x, maxY = max.y, maxZ = max.z;
    for (var at = first * 6; at < end * 6; at += 6) {
      if (bounds[at] < minX) minX = bounds[at];
      if (bounds[at + 1] < minY) minY = bounds[at + 1];
      if (bounds[at + 2] < minZ) minZ = bounds[at + 2];
      if (bounds[at + 3] > maxX) maxX = bounds[at + 3];
      if (bounds[at + 4] > maxY) maxY = bounds[at + 4];
      if (bounds[at + 5] > maxZ) maxZ = bounds[at + 5];
    }
    min.setValues(minX, minY, minZ);
    max.setValues(maxX, maxY, maxZ);
  }

  /// How far the hull of the row bounds of a mesh that holds records is
  /// widened on every side, in the space of the node, for rows a vertex
  /// stage moves by up to that much. Zero widens nothing.
  double get recordBoundsPad => (rows ?? this)._recordBoundsPad;
  double _recordBoundsPad = 0;
  set recordBoundsPad(double value) {
    _checkRecords();
    if (_recordBoundsPad == value) return;
    _recordBoundsPad = value;
    _revision++;
    _tellRowListeners();
  }

  final Aabb3 _recordPaddedHull = Aabb3();

  // The hull of the row bounds, widened by the pad, or null for no row. The
  // box is the mesh's own and holds until the next row write.
  Aabb3? _recordBoundsHull() {
    final hull = _recordRowHull();
    final pad = _recordBoundsPad;
    if (hull == null || pad == 0) return hull;
    return _recordPaddedHull
      ..min.setValues(hull.min.x - pad, hull.min.y - pad, hull.min.z - pad)
      ..max.setValues(hull.max.x + pad, hull.max.y + pad, hull.max.z + pad);
  }

  Aabb3? _recordRowHull() {
    if (_recordCount == 0) return null;
    if (_recordHullLoose) {
      _recordHullLoose = false;
      final bounds = _recordBounds;
      _recordHull
        ..min.setValues(bounds[0], bounds[1], bounds[2])
        ..max.setValues(bounds[3], bounds[4], bounds[5]);
      _growHull(1, _recordCount);
    }
    return _recordHull;
  }

  /// The geometry drawn for every instance.
  final Geometry geometry;

  /// The material every instance is shaded with.
  final Material material;

  /// Whether the renderer culls the instances by cell after the aggregate
  /// bounds pass: runs of consecutive instances, each tested by one box and
  /// drawn as a range of the instance buffer the mesh keeps on the device. No
  /// frame tests or packs an instance.
  ///
  /// Enable this for large spatial groups whose instances can enter the view
  /// at different times, and order the instances so neighbours in the list
  /// are neighbours in space. Small compact groups are usually cheaper to
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
  /// cell. The renderer culls such a mesh by its aggregate bounds only,
  /// whatever [cullInstances] states. The geometry needs an instanced
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

  final List<void Function()> _rowListeners = [];

  /// Calls [listener] after each change to the rows and to [instanceRanges],
  /// [instanceLocal] and [band], so the node that draws them refreshes its
  /// render item and no other node does.
  @internal
  void addRowListener(void Function() listener) => _rowListeners.add(listener);

  /// Removes a listener [addRowListener] added.
  @internal
  void removeRowListener(void Function() listener) =>
      _rowListeners.remove(listener);

  void _tellRowListeners() {
    for (var index = 0; index < _rowListeners.length; index++) {
      _rowListeners[index]();
    }
  }

  void _rowChanged(int index) {
    _revision++;
    _tellRowListeners();
    if (_changedRows.length < _instances.length + 64) {
      _changedRows.add(index);
    } else {
      _changedRows.clear();
      _changedFrom = _revision;
    }
  }

  void _rowsMoved() {
    _revision++;
    _tellRowListeners();
    _changedRows.clear();
    _changedFrom = _revision;
  }

  /// The rows changed after [revision], oldest first and possibly repeated,
  /// or null when a change since then moved rows, so every row must be read
  /// again. A row at or past [instanceCount] was removed from the end. Null
  /// for a mesh that holds records, whose changes go to its [recordRing].
  @internal
  List<int>? rowsChangedSince(int revision) {
    final shared = rows;
    if (shared != null) return shared.rowsChangedSince(revision);
    if (_ring != null) return null;
    if (revision < _changedFrom || revision > _revision) return null;
    return _changedRows.sublist(revision - _changedFrom);
  }

  /// The number of instances.
  int get instanceCount {
    final held = rows ?? this;
    return held._ring == null ? held._instances.length : held._recordCount;
  }

  /// A copy of the transform of the instance at [index], whichever way the
  /// mesh holds its rows: its own list, the rows it shares or records.
  Matrix4 instanceTransformAt(int index) => instances[index].clone();

  /// Adds an instance placed by [transform] and returns its index.
  ///
  /// The matrix is copied, so later mutating [transform] does not affect
  /// the instance; use [setInstanceTransform] to move it.
  int addInstance(Matrix4 transform, {Vector4? color}) {
    _checkListRows();
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
    _checkListRows();
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
    _checkListRows();
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
    _checkListRows();
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
    _checkListRows();
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
    _checkListRows();
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
    _checkListRows();
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
    _checkListRows();
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
  List<Matrix4> get instances {
    final held = rows ?? this;
    return held._ring == null
        ? held._instances
        : held._recordTransforms ??= _RecordTransforms(held);
  }

  List<Matrix4>? _recordTransforms;
  List<Vector4>? _recordColors;
  List<bool>? _recordWinding;

  /// Live per-instance linear RGBA multipliers.
  @internal
  List<Vector4> get colors {
    final held = rows ?? this;
    return held._ring == null
        ? held._colors
        : held._recordColors ??= _RecordColors(held);
  }

  /// Per-instance local winding parity matching [instances].
  @internal
  List<bool> get windingFlipped {
    final held = rows ?? this;
    return held._ring == null
        ? held._windingFlipped
        : held._recordWinding ??= _RecordWinding(held);
  }

  /// Changes whenever instance data changes.
  @internal
  int get revision => (rows ?? this)._revision;

  /// Aggregate AABB over every instance, in the instanced mesh's local
  /// space, or `null` when [geometry] has no computable bounds or there
  /// are no instances. Cached; after a change only the changed rows'
  /// bounds are transformed again before the hull. For rows that are records
  /// it is the hull of the bounds [setInstanceRecords] took.
  @internal
  Aabb3? get aggregateBounds {
    final held = rows ?? this;
    if (held._ring != null) return held._recordBoundsHull();
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
    final spin = _spin;
    if (spin != null) base = spin.cover(base);
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

// The rows of a mesh that holds records, read as the lists a mesh of
// instances holds. A read builds its value from the record.
abstract base class _RecordRows<T> extends ListBase<T> {
  _RecordRows(this._mesh);

  final InstancedMesh _mesh;

  @override
  int get length => _mesh._recordCount;

  @override
  set length(int value) => throw UnsupportedError('The rows are records.');

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('The rows are records.');

  int _offsetOf(int index) {
    RangeError.checkValidIndex(index, this);
    return index * _mesh.instanceRecordFloats;
  }
}

final class _RecordTransforms extends _RecordRows<Matrix4> {
  _RecordTransforms(super.mesh);

  @override
  Matrix4 operator [](int index) {
    final offset = _offsetOf(index);
    return Matrix4.fromFloat32List(
      Float32List.fromList(
        Float32List.sublistView(_mesh._recordStore, offset, offset + 16),
      ),
    );
  }
}

final class _RecordColors extends _RecordRows<Vector4> {
  _RecordColors(super.mesh);

  @override
  Vector4 operator [](int index) {
    final store = _mesh._recordStore;
    final offset = _offsetOf(index) + 16;
    return Vector4(
      store[offset],
      store[offset + 1],
      store[offset + 2],
      store[offset + 3],
    );
  }
}

final class _RecordWinding extends _RecordRows<bool> {
  _RecordWinding(super.mesh);

  @override
  bool operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _mesh._recordsMirrored;
  }
}
