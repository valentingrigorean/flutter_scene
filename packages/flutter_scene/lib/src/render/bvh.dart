import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:vector_math/vector_math.dart';

/// A bounding volume hierarchy over the bounded [RenderItem]s of a
/// [RenderScene].
///
/// Built from each item's world-space AABB. A render pass queries it with
/// its view frustum to collect potentially-visible items without testing
/// every item in the scene.
///
/// Nodes live in flat typed-data arrays rather than a pointer tree, so
/// build, refit, and query all stream contiguous memory. The build sorts
/// items along a Morton curve with a radix sort and splits ranges at the
/// median, which costs O(n) per level with no per-level sorting.
///
/// An item that joins or leaves the scene is put in with [insert] or taken
/// out with [remove], each a walk of one path of the tree, so a scene that
/// streams its content builds the tree once.
///
/// Engine-internal; kept by [RenderScene] as the scene changes.
class Bvh {
  Bvh._(
    this._bounds,
    this._children,
    this._parents,
    this._items,
    this._nodeCount,
    this._itemCount,
  ) : _root = _nodeCount - 1;

  /// The draw origin of the scene whose items the tree holds. A box of the
  /// tree is stated from a point no draw origin moves
  /// ([RenderItem.writeTreeBounds]) and a query from the draw origin, so
  /// each query moves by it.
  Float64List origin = Float64List(3);

  /// How many times [Bvh.build] sorted a set of items into a tree.
  @visibleForTesting
  static int debugBuildCount = 0;

  /// Builds a BVH over [items]. Every item must have a non-null
  /// [RenderItem.worldBounds].
  factory Bvh.build(List<RenderItem> items) {
    final n = items.length;
    if (n == 0) {
      return Bvh._(Float32List(0), Int32List(0), Int32List(0), [], 0, 0);
    }
    debugBuildCount++;

    // Quantize each item's centroid into a 30-bit Morton key.
    final centroids = Float32List(n * 3);
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    final box = Float32List(6);
    for (var i = 0; i < n; i++) {
      items[i].writeTreeBounds(box, 0);
      final cx = (box[0] + box[3]) * 0.5;
      final cy = (box[1] + box[4]) * 0.5;
      final cz = (box[2] + box[5]) * 0.5;
      centroids[i * 3] = cx;
      centroids[i * 3 + 1] = cy;
      centroids[i * 3 + 2] = cz;
      if (cx < minX) minX = cx;
      if (cy < minY) minY = cy;
      if (cz < minZ) minZ = cz;
      if (cx > maxX) maxX = cx;
      if (cy > maxY) maxY = cy;
      if (cz > maxZ) maxZ = cz;
    }
    final spanX = maxX - minX, spanY = maxY - minY, spanZ = maxZ - minZ;
    final scaleX = spanX > 0 ? 1023.0 / spanX : 0.0;
    final scaleY = spanY > 0 ? 1023.0 / spanY : 0.0;
    final scaleZ = spanZ > 0 ? 1023.0 / spanZ : 0.0;
    final keys = Uint32List(n);
    for (var i = 0; i < n; i++) {
      final qx = ((centroids[i * 3] - minX) * scaleX).toInt();
      final qy = ((centroids[i * 3 + 1] - minY) * scaleY).toInt();
      final qz = ((centroids[i * 3 + 2] - minZ) * scaleZ).toInt();
      keys[i] =
          _spreadBits(qx) | (_spreadBits(qy) << 1) | (_spreadBits(qz) << 2);
    }

    // Radix-sort item indices by Morton key, three 10-bit passes.
    var order = Uint32List(n);
    var scratch = Uint32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = i;
    }
    final histogram = Uint32List(1024);
    for (var shift = 0; shift < 30; shift += 10) {
      histogram.fillRange(0, 1024, 0);
      for (var i = 0; i < n; i++) {
        histogram[(keys[order[i]] >> shift) & 1023]++;
      }
      var sum = 0;
      for (var bucket = 0; bucket < 1024; bucket++) {
        final count = histogram[bucket];
        histogram[bucket] = sum;
        sum += count;
      }
      for (var i = 0; i < n; i++) {
        final index = order[i];
        scratch[histogram[(keys[index] >> shift) & 1023]++] = index;
      }
      final swap = order;
      order = scratch;
      scratch = swap;
    }

    // Emit nodes over the sorted order, splitting ranges at the median.
    // Post-order allocation, so both children of a node precede it.
    final nodeCap = 2 * n - 1;
    final bounds = Float32List(nodeCap * 6);
    final children = Int32List(nodeCap * 2);
    final parents = Int32List(nodeCap)..fillRange(0, nodeCap, -1);
    final nodeItems = List<RenderItem?>.filled(nodeCap, null, growable: true);
    var nodeCount = 0;

    int emit(int lo, int hi) {
      if (hi - lo == 1) {
        final item = items[order[lo]];
        final node = nodeCount++;
        nodeItems[node] = item;
        item.bvhNode = node;
        item.writeTreeBounds(bounds, node * 6);
        children[node * 2] = -1;
        return node;
      }
      final mid = (lo + hi) >> 1;
      final left = emit(lo, mid);
      final right = emit(mid, hi);
      final node = nodeCount++;
      final o = node * 6, l = left * 6, r = right * 6;
      for (var axis = 0; axis < 3; axis++) {
        final lMin = bounds[l + axis], rMin = bounds[r + axis];
        bounds[o + axis] = lMin < rMin ? lMin : rMin;
        final lMax = bounds[l + 3 + axis], rMax = bounds[r + 3 + axis];
        bounds[o + 3 + axis] = lMax > rMax ? lMax : rMax;
      }
      children[node * 2] = left;
      children[node * 2 + 1] = right;
      parents[left] = node;
      parents[right] = node;
      return node;
    }

    emit(0, n);
    return Bvh._(bounds, children, parents, nodeItems, nodeCount, n);
  }

  // Node storage. Node i owns bounds[i*6..i*6+6) as
  // (minX, minY, minZ, maxX, maxY, maxZ). children[i*2] is the left child
  // index, or -1 for a leaf, whose item is items[i] (children[i*2+1] then
  // unused). parents[i] is -1 for the root. A node an item left is kept on
  // the free list and reused.
  Float32List _bounds;
  Int32List _children;
  Int32List _parents;
  final List<RenderItem?> _items;
  final List<int> _freeNodes = [];
  int _nodeCount;
  int _itemCount;
  int _root;

  /// Items in this tree.
  int get itemCount => _itemCount;

  int _takeNode() {
    if (_freeNodes.isNotEmpty) return _freeNodes.removeLast();
    final node = _nodeCount++;
    if (node * 6 >= _bounds.length) {
      final capacity = math.max(16, node * 2);
      _bounds = Float32List(capacity * 6)..setRange(0, _bounds.length, _bounds);
      _children = Int32List(capacity * 2)
        ..setRange(0, _children.length, _children);
      _parents = Int32List(capacity)..setRange(0, _parents.length, _parents);
    }
    if (node == _items.length) _items.add(null);
    return node;
  }

  // The bounds of [node] from its two children.
  void _joinChildren(int node) {
    final bounds = _bounds;
    final o = node * 6;
    final l = _children[node * 2] * 6, r = _children[node * 2 + 1] * 6;
    for (var axis = 0; axis < 3; axis++) {
      final lMin = bounds[l + axis], rMin = bounds[r + axis];
      bounds[o + axis] = lMin < rMin ? lMin : rMin;
      final lMax = bounds[l + 3 + axis], rMax = bounds[r + 3 + axis];
      bounds[o + 3 + axis] = lMax > rMax ? lMax : rMax;
    }
  }

  // Half the surface area of the box of node [o] grown to hold the box of
  // node [b].
  double _grownArea(int o, int b) {
    final bounds = _bounds;
    final minX = math.min(bounds[o], bounds[b]);
    final minY = math.min(bounds[o + 1], bounds[b + 1]);
    final minZ = math.min(bounds[o + 2], bounds[b + 2]);
    final dx = math.max(bounds[o + 3], bounds[b + 3]) - minX;
    final dy = math.max(bounds[o + 4], bounds[b + 4]) - minY;
    final dz = math.max(bounds[o + 5], bounds[b + 5]) - minZ;
    return dx * dy + dy * dz + dz * dx;
  }

  double _area(int o) {
    final bounds = _bounds;
    final dx = bounds[o + 3] - bounds[o];
    final dy = bounds[o + 4] - bounds[o + 1];
    final dz = bounds[o + 5] - bounds[o + 2];
    return dx * dy + dy * dz + dz * dx;
  }

  /// Puts [item], which has a non-null [RenderItem.worldBounds] and is not
  /// in the tree, into it: beside the leaf reached by taking, at each node,
  /// the child whose box grows least to hold it.
  void insert(RenderItem item) {
    assert(item.bvhNode < 0);
    final leaf = _takeNode();
    _items[leaf] = item;
    item.bvhNode = leaf;
    _children[leaf * 2] = -1;
    item.writeTreeBounds(_bounds, leaf * 6);
    _itemCount++;
    if (_root < 0) {
      _root = leaf;
      _parents[leaf] = -1;
      return;
    }
    var sibling = _root;
    while (_children[sibling * 2] >= 0) {
      final left = _children[sibling * 2];
      final right = _children[sibling * 2 + 1];
      final leftGrowth = _grownArea(left * 6, leaf * 6) - _area(left * 6);
      final rightGrowth = _grownArea(right * 6, leaf * 6) - _area(right * 6);
      sibling = leftGrowth <= rightGrowth ? left : right;
    }
    final parent = _parents[sibling];
    final joined = _takeNode();
    _items[joined] = null;
    _parents[joined] = parent;
    _children[joined * 2] = sibling;
    _children[joined * 2 + 1] = leaf;
    _parents[sibling] = joined;
    _parents[leaf] = joined;
    if (parent < 0) {
      _root = joined;
    } else if (_children[parent * 2] == sibling) {
      _children[parent * 2] = joined;
    } else {
      _children[parent * 2 + 1] = joined;
    }
    _refitFrom(joined);
  }

  /// Takes [item] out of the tree, where its sibling takes the place of
  /// their parent.
  void remove(RenderItem item) {
    final leaf = item.bvhNode;
    if (leaf < 0) return;
    assert(identical(_items[leaf], item));
    item.bvhNode = -1;
    _items[leaf] = null;
    _freeNodes.add(leaf);
    _itemCount--;
    final parent = _parents[leaf];
    if (parent < 0) {
      _root = -1;
      return;
    }
    final sibling = _children[parent * 2] == leaf
        ? _children[parent * 2 + 1]
        : _children[parent * 2];
    final grandparent = _parents[parent];
    _parents[sibling] = grandparent;
    _freeNodes.add(parent);
    if (grandparent < 0) {
      _root = sibling;
      return;
    }
    if (_children[grandparent * 2] == parent) {
      _children[grandparent * 2] = sibling;
    } else {
      _children[grandparent * 2 + 1] = sibling;
    }
    _refitFrom(grandparent);
  }

  // Joins the boxes of [node] and of each node above it again, turning each
  // where that shrinks a child, so items that arrive in order along a line
  // leave a tree of logarithmic depth and not a chain.
  void _refitFrom(int node) {
    for (var at = node; at >= 0; at = _parents[at]) {
      _rotate(at);
      _joinChildren(at);
    }
  }

  // Half the surface area of the box that holds nodes [a] and [b].
  double _unionArea(int a, int b) {
    final bounds = _bounds;
    final p = a * 6, q = b * 6;
    final dx =
        math.max(bounds[p + 3], bounds[q + 3]) - math.min(bounds[p], bounds[q]);
    final dy =
        math.max(bounds[p + 4], bounds[q + 4]) -
        math.min(bounds[p + 1], bounds[q + 1]);
    final dz =
        math.max(bounds[p + 5], bounds[q + 5]) -
        math.min(bounds[p + 2], bounds[q + 2]);
    return dx * dy + dy * dz + dz * dx;
  }

  // Swaps a child of [node] with a child of its other child where that
  // makes the other child's box smaller.
  void _rotate(int node) {
    final children = _children;
    final left = children[node * 2];
    final right = children[node * 2 + 1];
    var gain = 0.0;
    var inner = -1;
    var slot = 0;
    if (children[left * 2] >= 0) {
      final area = _area(left * 6);
      for (var side = 0; side < 2; side++) {
        final kept = children[left * 2 + 1 - side];
        final change = _unionArea(right, kept) - area;
        if (change < gain) {
          gain = change;
          inner = left;
          slot = side;
        }
      }
    }
    if (children[right * 2] >= 0) {
      final area = _area(right * 6);
      for (var side = 0; side < 2; side++) {
        final kept = children[right * 2 + 1 - side];
        final change = _unionArea(left, kept) - area;
        if (change < gain) {
          gain = change;
          inner = right;
          slot = side;
        }
      }
    }
    if (inner < 0) return;
    final outerSlot = inner == left ? 1 : 0;
    final outer = children[node * 2 + outerSlot];
    final raised = children[inner * 2 + slot];
    children[inner * 2 + slot] = outer;
    _parents[outer] = inner;
    children[node * 2 + outerSlot] = raised;
    _parents[raised] = node;
    _joinChildren(inner);
  }

  /// The count of nodes on the longest path from the root to a leaf.
  @visibleForTesting
  int get debugDepth {
    if (_root < 0) return 0;
    var deepest = 0;
    final nodes = [_root];
    final depths = [1];
    while (nodes.isNotEmpty) {
      final node = nodes.removeLast();
      final depth = depths.removeLast();
      if (depth > deepest) deepest = depth;
      final left = _children[node * 2];
      if (left < 0) continue;
      nodes
        ..add(left)
        ..add(_children[node * 2 + 1]);
      depths
        ..add(depth + 1)
        ..add(depth + 1);
    }
    return deepest;
  }

  // Traversal stack. A traversal holds at most one node per level and one
  // more, and grows the stack for a tree deeper than it. Queries are
  // single-threaded and never nest (a visit callback must not query the
  // same Bvh).
  Int32List _stack = Int32List(64);

  Int32List _grownStack() =>
      _stack = Int32List(_stack.length * 2)..setRange(0, _stack.length, _stack);

  // Frustum planes then additional planes as (nx, ny, nz, constant) rows,
  // reloaded per query. Grows to fit the largest plane count seen.
  Float64List _planes = Float64List(24);

  /// Calls [visit] once for every item whose world AABB intersects
  /// [frustum]. Returns how many it visited; a rejected node's subtree is
  /// skipped whole, so [itemCount] minus this is the number rejected.
  int query(
    Frustum frustum,
    void Function(RenderItem) visit, {
    List<Plane> additionalPlanes = const [],
  }) {
    if (_root < 0) return 0;
    final planeCount = 6 + additionalPlanes.length;
    if (_planes.length < planeCount * 4) {
      _planes = Float64List(planeCount * 4);
    }
    for (var i = 0; i < additionalPlanes.length; i++) {
      _loadPlane(6 + i, additionalPlanes[i]);
    }
    _loadPlane(0, frustum.plane0);
    _loadPlane(1, frustum.plane1);
    _loadPlane(2, frustum.plane2);
    _loadPlane(3, frustum.plane3);
    _loadPlane(4, frustum.plane4);
    _loadPlane(5, frustum.plane5);
    final bounds = _bounds;
    final children = _children;
    final planes = _planes;
    final rowsEnd = planeCount * 4;
    var stack = _stack;
    var top = 0;
    stack[top++] = _root;
    var visited = 0;
    while (top > 0) {
      final node = stack[--top];
      final o = node * 6;
      // Outside when the corner farthest along a plane's normal is below
      // that plane, matching Frustum.intersectsWithAabb3.
      var outside = false;
      for (var p = 0; p < rowsEnd; p += 4) {
        final nx = planes[p], ny = planes[p + 1], nz = planes[p + 2];
        final px = nx < 0 ? bounds[o] : bounds[o + 3];
        final py = ny < 0 ? bounds[o + 1] : bounds[o + 4];
        final pz = nz < 0 ? bounds[o + 2] : bounds[o + 5];
        if (nx * px + ny * py + nz * pz + planes[p + 3] < 0) {
          outside = true;
          break;
        }
      }
      if (outside) continue;
      final left = children[node * 2];
      if (left < 0) {
        visit(_items[node]!);
        visited++;
        continue;
      }
      if (top + 2 > stack.length) stack = _grownStack();
      stack[top++] = left;
      stack[top++] = children[node * 2 + 1];
    }
    return visited;
  }

  /// The smallest [leafBound] over items whose world AABB intersects
  /// [frustum], searched nearest first and pruned by a lower bound on each
  /// node: the larger of its nearest corner's planar depth along [forward]
  /// from [eye] and its distance from [eye] times [cosHalfAngle] (no point in
  /// the frustum lies farther off-axis than the frustum's corner ray). Both
  /// bounds hold for every item inside a node, so a node that cannot beat
  /// [best] is skipped whole.
  ///
  /// [leafBound] returns an item's own bound, or infinity to ignore it. The
  /// search ends as soon as the best bound reaches [floor].
  double nearestBound(
    Frustum frustum,
    Vector3 eye,
    Vector3 forward,
    double cosHalfAngle,
    double Function(RenderItem item, double best) leafBound, {
    List<Plane> additionalPlanes = const [],
    double best = double.infinity,
    double floor = double.negativeInfinity,
  }) {
    if (_root < 0) return best;
    final planeCount = 6 + additionalPlanes.length;
    if (_planes.length < planeCount * 4) {
      _planes = Float64List(planeCount * 4);
    }
    for (var i = 0; i < additionalPlanes.length; i++) {
      _loadPlane(6 + i, additionalPlanes[i]);
    }
    _loadPlane(0, frustum.plane0);
    _loadPlane(1, frustum.plane1);
    _loadPlane(2, frustum.plane2);
    _loadPlane(3, frustum.plane3);
    _loadPlane(4, frustum.plane4);
    _loadPlane(5, frustum.plane5);
    final bounds = _bounds;
    final children = _children;
    final planes = _planes;
    final rowsEnd = planeCount * 4;
    var stack = _stack;
    final ex = eye.x + origin[0];
    final ey = eye.y + origin[1];
    final ez = eye.z + origin[2];
    final fx = forward.x, fy = forward.y, fz = forward.z;
    var top = 0;
    stack[top++] = _root;
    while (top > 0) {
      final node = stack[--top];
      final o = node * 6;
      final lower = aabbDepthLowerBound(
        bounds[o],
        bounds[o + 1],
        bounds[o + 2],
        bounds[o + 3],
        bounds[o + 4],
        bounds[o + 5],
        ex,
        ey,
        ez,
        fx,
        fy,
        fz,
        cosHalfAngle,
      );
      if (lower >= best) continue;
      var outside = false;
      for (var p = 0; p < rowsEnd; p += 4) {
        final nx = planes[p], ny = planes[p + 1], nz = planes[p + 2];
        final px = nx < 0 ? bounds[o] : bounds[o + 3];
        final py = ny < 0 ? bounds[o + 1] : bounds[o + 4];
        final pz = nz < 0 ? bounds[o + 2] : bounds[o + 5];
        if (nx * px + ny * py + nz * pz + planes[p + 3] < 0) {
          outside = true;
          break;
        }
      }
      if (outside) continue;
      final left = children[node * 2];
      if (left < 0) {
        final bound = leafBound(_items[node]!, best);
        if (bound < best) {
          best = bound;
          if (best <= floor) return best;
        }
        continue;
      }
      // Visit the nearer child first, so a tight bound prunes the other.
      final right = children[node * 2 + 1];
      final leftNear = _nodeDistance2(left * 6, ex, ey, ez);
      final rightNear = _nodeDistance2(right * 6, ex, ey, ez);
      if (top + 2 > stack.length) stack = _grownStack();
      if (leftNear <= rightNear) {
        stack[top++] = right;
        stack[top++] = left;
      } else {
        stack[top++] = left;
        stack[top++] = right;
      }
    }
    return best;
  }

  double _nodeDistance2(int o, double x, double y, double z) {
    final b = _bounds;
    final dx = x < b[o] ? b[o] - x : (x > b[o + 3] ? x - b[o + 3] : 0.0);
    final dy = y < b[o + 1]
        ? b[o + 1] - y
        : (y > b[o + 4] ? y - b[o + 4] : 0.0);
    final dz = z < b[o + 2]
        ? b[o + 2] - z
        : (z > b[o + 5] ? z - b[o + 5] : 0.0);
    return dx * dx + dy * dy + dz * dz;
  }

  void _loadPlane(int index, Plane plane) {
    final o = index * 4;
    _planes[o] = plane.normal.x;
    _planes[o + 1] = plane.normal.y;
    _planes[o + 2] = plane.normal.z;
    // A plane of the caller is stated from the draw origin and the boxes are
    // not, so the constant moves by the origin along the normal.
    _planes[o + 3] =
        plane.constant -
        (plane.normal.x * origin[0] +
            plane.normal.y * origin[1] +
            plane.normal.z * origin[2]);
  }

  /// Calls [visit] once for every item whose world AABB intersects [box].
  ///
  /// Used to scatter a light's influence volume onto the items it can reach,
  /// so each item collects only the lights near it.
  void queryAabb(Aabb3 box, void Function(RenderItem) visit) {
    if (_root < 0) return;
    final minX = box.min.x + origin[0];
    final minY = box.min.y + origin[1];
    final minZ = box.min.z + origin[2];
    final maxX = box.max.x + origin[0];
    final maxY = box.max.y + origin[1];
    final maxZ = box.max.z + origin[2];
    final bounds = _bounds;
    final children = _children;
    var stack = _stack;
    var top = 0;
    stack[top++] = _root;
    while (top > 0) {
      final node = stack[--top];
      final o = node * 6;
      if (bounds[o] > maxX ||
          bounds[o + 1] > maxY ||
          bounds[o + 2] > maxZ ||
          bounds[o + 3] < minX ||
          bounds[o + 4] < minY ||
          bounds[o + 5] < minZ) {
        continue;
      }
      final left = children[node * 2];
      if (left < 0) {
        visit(_items[node]!);
        continue;
      }
      if (top + 2 > stack.length) stack = _grownStack();
      stack[top++] = left;
      stack[top++] = children[node * 2 + 1];
    }
  }

  /// Recomputes every node's AABB from the leaves' current
  /// [RenderItem.worldBounds] without changing the tree topology.
  ///
  /// Valid while every item in the tree is bounded; a moved item is fine.
  /// Cheaper than a build (O(n), no sort), but tree quality degrades as
  /// items drift from the grouping they were placed in.
  void refit() {
    if (_root < 0) return;
    // Parents first into the order, so its reverse joins children first.
    var order = _refitOrder;
    if (order.length < _nodeCount) {
      order = _refitOrder = Int32List(math.max(_nodeCount, order.length * 2));
    }
    final children = _children;
    var listed = 0;
    order[listed++] = _root;
    for (var at = 0; at < listed; at++) {
      final node = order[at];
      final left = children[node * 2];
      if (left < 0) continue;
      order[listed++] = left;
      order[listed++] = children[node * 2 + 1];
    }
    for (var at = listed - 1; at >= 0; at--) {
      final node = order[at];
      if (children[node * 2] < 0) {
        _items[node]!.writeTreeBounds(_bounds, node * 6);
      } else {
        _joinChildren(node);
      }
    }
  }

  Int32List _refitOrder = Int32List(0);

  // Spreads the low 10 bits of [value] so consecutive bits land three
  // apart (Morton interleave).
  static int _spreadBits(int value) {
    var x = value & 0x3ff;
    x = (x | (x << 16)) & 0x030000ff;
    x = (x | (x << 8)) & 0x0300f00f;
    x = (x | (x << 4)) & 0x030c30c3;
    x = (x | (x << 2)) & 0x09249249;
    return x;
  }
}

/// A lower bound on the planar view depth, along unit [fx], [fy], [fz] from
/// the eye at [ex], [ey], [ez], of any point of the AABB `(minX..maxZ)` that
/// lies inside a perspective frustum whose corner ray makes an angle with
/// forward of cosine [cosHalfAngle]. Zero or negative when the box reaches
/// the eye's plane.
double aabbDepthLowerBound(
  double minX,
  double minY,
  double minZ,
  double maxX,
  double maxY,
  double maxZ,
  double ex,
  double ey,
  double ez,
  double fx,
  double fy,
  double fz,
  double cosHalfAngle,
) {
  // Planar depth is linear, so its minimum over the box is at the corner
  // farthest against forward.
  final cornerX = fx < 0 ? maxX : minX;
  final cornerY = fy < 0 ? maxY : minY;
  final cornerZ = fz < 0 ? maxZ : minZ;
  final planar =
      (cornerX - ex) * fx + (cornerY - ey) * fy + (cornerZ - ez) * fz;
  final dx = ex < minX ? minX - ex : (ex > maxX ? ex - maxX : 0.0);
  final dy = ey < minY ? minY - ey : (ey > maxY ? ey - maxY : 0.0);
  final dz = ez < minZ ? minZ - ez : (ez > maxZ ? ez - maxZ : 0.0);
  final radial = math.sqrt(dx * dx + dy * dy + dz * dz) * cosHalfAngle;
  return planar > radial ? planar : radial;
}
