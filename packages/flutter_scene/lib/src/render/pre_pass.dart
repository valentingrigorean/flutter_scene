import 'package:flutter_scene/src/render/render_stats.dart';

/// A node the [ScenePrePass] of its render scene visits.
abstract interface class PrePassNode {
  /// The node's place in the per-frame list, or -1 while it is not in it.
  abstract int prePassFrameIndex;

  /// Whether the node waits in the changed list.
  abstract bool prePassChanged;

  /// Ticks the node's components and its animation player.
  void prePassTick(double deltaSeconds);

  /// Refreshes the node's render items from its current state.
  void prePassRefresh({required bool uploadSkin});
}

/// The work a render scene does on its nodes before a frame draws.
///
/// It keeps two lists and never walks the node tree. The per-frame list holds
/// the nodes that state they need every frame: a component that ticks, an
/// animation player, a skin or morph targets. The changed list holds the
/// mesh-bearing nodes whose state a render item mirrors and that changed
/// since the last run: a transform, a visibility, a layer or shadow setting.
/// A change that names no node (see `renderSourceRevision`) queues the node
/// of every render item once. A frame that changes nothing and holds no
/// per-frame node visits no node, which [RenderCounters.prePassNodes]
/// counts.

final class ScenePrePass {
  final List<PrePassNode?> _frame = [];
  int _frameHoles = 0;
  final List<PrePassNode> _changed = [];

  /// The nodes in the per-frame list.
  int get frameNodeCount => _frame.length - _frameHoles;

  /// Puts [node] in the per-frame list, after the nodes already in it.
  void addFrameNode(PrePassNode node) {
    if (node.prePassFrameIndex >= 0) return;
    node.prePassFrameIndex = _frame.length;
    _frame.add(node);
  }

  /// Takes [node] out of the per-frame list.
  void removeFrameNode(PrePassNode node) {
    final index = node.prePassFrameIndex;
    if (index < 0) return;
    _frame[index] = null;
    _frameHoles++;
    node.prePassFrameIndex = -1;
  }

  /// Queues [node] for the next refresh.
  void markChanged(PrePassNode node) {
    if (node.prePassChanged) return;
    node.prePassChanged = true;
    _changed.add(node);
  }

  /// Drops [node] from both lists as it leaves the render scene.
  void forget(PrePassNode node) {
    removeFrameNode(node);
    node.prePassChanged = false;
  }

  /// Ticks the per-frame nodes in the order they joined and returns how many
  /// it ticked. A node that joins the list during the run ticks in this run.
  int tick(double deltaSeconds) {
    _compactFrame();
    var visited = 0;
    for (var index = 0; index < _frame.length; index++) {
      final node = _frame[index];
      if (node == null) continue;
      node.prePassTick(deltaSeconds);
      visited++;
    }
    activeRenderCounters.prePassNodes += visited;
    return visited;
  }

  /// Refreshes the render items of the changed nodes and returns how many it
  /// refreshed.
  int refresh({required bool uploadSkin}) {
    var visited = 0;
    for (var index = 0; index < _changed.length; index++) {
      final node = _changed[index];
      if (!node.prePassChanged) continue;
      node.prePassChanged = false;
      node.prePassRefresh(uploadSkin: uploadSkin);
      visited++;
    }
    _changed.clear();
    activeRenderCounters.prePassNodes += visited;
    return visited;
  }

  void _compactFrame() {
    if (_frameHoles == 0 || _frameHoles * 2 < _frame.length) return;
    var kept = 0;
    for (final node in _frame) {
      if (node == null) continue;
      node.prePassFrameIndex = kept;
      _frame[kept++] = node;
    }
    _frame.length = kept;
    _frameHoles = 0;
  }
}
