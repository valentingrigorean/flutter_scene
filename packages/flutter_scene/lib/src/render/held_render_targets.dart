import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_graph.dart';

/// An owner of render targets it keeps across frames, which the memory
/// report counts while the owner lives.
@internal
abstract interface class HeldRenderTargets {
  /// Every render target the owner holds now.
  Iterable<gpu.Texture> get heldRenderTargets;
}

final List<WeakReference<HeldRenderTargets>> _live = [];
int _pruneAt = 16;

/// Adds [owner] to the owners [renderTargetFootprint] walks, until it is
/// collected.
@internal
void registerHeldRenderTargets(HeldRenderTargets owner) {
  _live.add(WeakReference(owner));
  if (_live.length >= _pruneAt) {
    _live.removeWhere((reference) => reference.target == null);
    _pruneAt = 2 * _live.length + 16;
  }
}

/// The render targets every live owner holds: the device-private textures
/// with their bytes, and the count of the transient attachments, whose bytes
/// the device decides. A texture two owners hold counts once.
@internal
({int bytes, int count, int transientCount}) renderTargetFootprint() {
  var bytes = 0;
  var count = 0;
  var transientCount = 0;
  _live.removeWhere((reference) => reference.target == null);
  final seen = Set<gpu.Texture>.identity();
  for (final reference in _live) {
    final owner = reference.target;
    if (owner == null) continue;
    for (final texture in owner.heldRenderTargets) {
      if (!seen.add(texture)) continue;
      if (texture.storageMode == gpu.StorageMode.deviceTransient) {
        transientCount++;
      } else {
        count++;
        bytes += renderTargetBytes(texture);
      }
    }
  }
  return (bytes: bytes, count: count, transientCount: transientCount);
}
