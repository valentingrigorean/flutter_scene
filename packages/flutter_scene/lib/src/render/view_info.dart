/// The two blocks an engine vertex stage reads in place of one block per
/// draw: `ViewInfo` (`view_info.glsl`), the view a pass draws, emplaced once
/// per pass and shared by every draw and by the fragment stage; and
/// `ItemInfo` (`item_info.glsl`), what one render item draws with that no
/// view changes, held at an offset of its own from frame to frame and written
/// only when it changes. A still item then writes no uniform bytes while the
/// camera moves.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/instance_band.dart';
import 'package:flutter_scene/src/render/depth_raster.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/held_slots.dart';
import 'package:flutter_scene/src/render/uniform_slots.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/vertex_spin.dart';
import 'package:vector_math/vector_math.dart';

/// The floats of the `ViewInfo` block.
const int kViewInfoFloats = 36;

/// The floats of the `ItemInfo` block.
const int kItemInfoFloats = 88;

/// The camera axis and projection kind of the view the draws bound next
/// draw, stated by a color pass for the fragment stage's view direction.
/// Null for a pass whose fragments read no view direction.
@internal
Vector3? currentViewForward;

/// Whether the camera [currentViewForward] belongs to is orthographic.
@internal
bool currentViewOrthographic = false;

/// The `ItemInfo` blocks of the render item whose draw is bound next, for a
/// geometry's `bind`; null for a draw of no item, whose block is emplaced.
@internal
HeldItemInfo? currentDrawItemInfo;

/// The `ViewInfo` block the vertex stage of the last draw bound, which the
/// fragment stage of the same draw binds as well, when it was stated for the
/// camera axis [forward] (a `Lighting`'s) in the current submission; null
/// otherwise.
@internal
gpu.BufferView? currentViewInfoFor(Vector3? forward) =>
    _views.submission == rendererSubmissions.latestSubmission &&
        forward != null &&
        identical(_views.lastForward, forward)
    ? _views.last
    : null;

final _ViewBlocks _views = _ViewBlocks();

final class _ViewBlocks {
  static const int _kept = 8;

  final Float32List scratch = Float32List(kViewInfoFloats);
  late final ByteData bytes = ByteData.sublistView(scratch);
  final List<Float32List> held = [];
  final List<gpu.BufferView> views = [];
  TransientWriter? writer;
  int submission = -1;
  gpu.BufferView? last;
  Vector3? lastForward;

  gpu.BufferView emplace(TransientWriter target) {
    final latest = rendererSubmissions.latestSubmission;
    if (!identical(target, writer) || latest != submission) {
      writer = target;
      submission = latest;
      held.clear();
      views.clear();
      last = null;
    }
    lastForward = currentViewForward;
    for (var index = views.length - 1; index >= 0; index--) {
      if (_same(held[index], scratch)) return last = views[index];
    }
    final key = transientDrawKey;
    transientDrawKey = null;
    final view = target.emplace(bytes);
    transientDrawKey = key;
    if (views.length == _kept) {
      held.removeAt(0);
      views.removeAt(0);
    }
    held.add(Float32List.fromList(scratch));
    views.add(view);
    return last = view;
  }
}

bool _same(Float32List a, Float32List b) {
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// The `ViewInfo` block of a pass drawing through [cameraTransform] from
/// [cameraPosition], with the depth raster and pixel slope the pass states
/// its draws' offsets under ([currentDrawDepthRaster],
/// [currentDrawPixelSlope]), the view a band test reads
/// ([currentViewInstanceBand]) and the animation time.
///
/// Every draw of a view gets the one block, emplaced on the first; a pass
/// that draws several views (shadow cascades) gets one each.
@internal
gpu.BufferView viewInfoOf(
  TransientWriter writer,
  Matrix4 cameraTransform,
  Vector3 cameraPosition,
) {
  final raster = currentDrawDepthRaster;
  final forward = currentViewForward;
  final band = currentViewInstanceBand;
  final scratch = _views.scratch
    ..setAll(0, cameraTransform.storage)
    ..[16] = cameraPosition.x
    ..[17] = cameraPosition.y
    ..[18] = cameraPosition.z
    ..[19] = foldedAnimationTime(currentAnimationTime)
    ..[20] = forward?.x ?? 0.0
    ..[21] = forward?.y ?? 0.0
    ..[22] = forward?.z ?? 0.0
    ..[23] = currentViewOrthographic && forward != null ? 1.0 : 0.0
    ..[24] = band[0]
    ..[25] = band[1]
    ..[26] = band[2]
    ..[27] = band[8]
    ..[28] = band[4]
    ..[29] = band[5]
    ..[30] = band[6]
    ..[31] = band[9]
    ..[32] = raster.stepScale
    ..[33] = raster.stepClip
    ..[34] = (raster.reversed ? 1.0 : -1.0) * currentDrawPixelSlope
    ..[35] = 0.0;
  assert(scratch.length == kViewInfoFloats);
  return _views.emplace(writer);
}

/// Binds the `ViewInfo` block [viewInfoOf] returns, and the `ItemInfo` block
/// of the draw bound next, to [shader] where it declares them.
///
/// With [frameInfo], a material's vertex shader for an engine mesh written
/// against the one `FrameInfo` block per draw (camera and item values
/// together) gets it emplaced for each draw; a geometry with a `FrameInfo` of
/// its own binds that itself. Moving
/// it to `view_info.glsl` and `item_info.glsl` makes its draws write nothing
/// while they stand still.
///
/// [held] (else [currentDrawItemInfo]) keeps the item's block from frame to
/// frame; without one the block is emplaced for this draw. [depthBias] is the material's.
@internal
void bindViewAndItemInfo(
  gpu.RenderPass pass,
  TransientWriter writer,
  gpu.Shader shader,
  Matrix4 cameraTransform,
  Vector3 cameraPosition, {
  HeldItemInfo? held,
  double depthBias = 0.0,
  bool frameInfo = false,
}) {
  final viewSlot = shader.cachedUniformSlot('ViewInfo');
  if (viewSlot.sizeInBytes != null) {
    pass.bindUniform(
      viewSlot,
      viewInfoOf(writer, cameraTransform, cameraPosition),
    );
  }
  final frameSlot = frameInfo ? shader.cachedUniformSlot('FrameInfo') : null;
  if (frameSlot != null && frameSlot.sizeInBytes != null) {
    pass.bindUniform(
      frameSlot,
      writer.emplace(
        scratchBytesOf(
          _packFrameInfo(cameraTransform, cameraPosition, depthBias),
        ),
      ),
    );
  }
  final itemSlot = shader.cachedUniformSlot('ItemInfo');
  if (itemSlot.sizeInBytes == null) return;
  pass.bindUniform(itemSlot, switch (held ?? currentDrawItemInfo) {
    null => writer.emplace(_itemBytes(_packItemInfo(depthBias))),
    final held => held.bound(depthBias),
  });
}

final Float32List _frameScratch = Float32List(80 + VertexSpin.floatCount);

// The one block per draw of a vertex shader that declares `FrameInfo`: the
// camera, the depth bias and offsets, the instance frame and local
// transform, the band with its view, and the turns.
Float32List _packFrameInfo(
  Matrix4 cameraTransform,
  Vector3 cameraPosition,
  double depthBias,
) {
  final band = currentDrawInstanceBand;
  final view = currentViewInstanceBand;
  final scratch = _frameScratch
    ..setAll(0, cameraTransform.storage)
    ..[16] = cameraPosition.x
    ..[17] = cameraPosition.y
    ..[18] = cameraPosition.z
    ..[19] = depthBias
    ..setAll(20, currentDrawDepthOffset)
    ..setAll(24, currentDrawDepthSlope)
    ..setAll(28, (currentDrawInstanceFrame ?? _identity).storage)
    ..setAll(44, (currentDrawInstanceLocal ?? _identity).storage)
    ..[60] = view[0]
    ..[61] = view[1]
    ..[62] = view[2]
    ..[63] = band == null ? 0.0 : 1.0
    ..[64] = view[4]
    ..[65] = view[5]
    ..[66] = view[6]
    ..[67] = 0.0;
  if (band == null) {
    scratch.fillRange(68, 80, 0.0);
  } else {
    band.writeTo(scratch, 68);
    scratch
      ..[78] = view[8]
      ..[79] = view[9];
  }
  final spin = currentDrawSpin;
  if (spin == null) {
    VertexSpin.writeNone(scratch, 80);
  } else {
    spin.writeTo(scratch, 80, currentAnimationTime);
  }
  return scratch;
}

final Float32List _itemScratch = Float32List(kItemInfoFloats);
final Matrix4 _identity = Matrix4.identity();

ByteData _itemBytes(Float32List values) => scratchBytesOf(values);

// Packs the ItemInfo block of the draw bound next from the current-draw
// state its encoder stated.
Float32List _packItemInfo(double depthBias) {
  final scratch = _itemScratch
    ..[0] = currentDrawDepthSteps[0]
    ..[1] = currentDrawDepthSteps[1]
    ..[2] = depthBias
    ..[3] = 0.0
    ..[4] = currentDrawDepthPixels[0]
    ..[5] = currentDrawDepthPixels[1]
    ..[6] = currentDrawDepthPixels[2]
    ..[7] = 0.0
    ..setAll(8, (currentDrawInstanceFrame ?? _identity).storage)
    ..setAll(24, (currentDrawInstanceLocal ?? _identity).storage);
  final band = currentDrawInstanceBand;
  if (band == null) {
    scratch.fillRange(40, 52, 0.0);
  } else {
    band.writeTo(scratch, 40);
    scratch
      ..[50] = 1.0
      ..[51] = 0.0;
  }
  final spin = currentDrawSpin;
  if (spin == null) {
    VertexSpin.writeNone(scratch, 52);
  } else {
    spin.writeTo(scratch, 52, currentAnimationTime);
  }
  // writeTo ends with the folded time and the turn count; the time is the
  // view's, so the count moves first.
  scratch
    ..[84] = scratch[85]
    ..[85] = 0.0;
  return scratch;
}

/// The `ItemInfo` blocks one render item holds, one for each distinct set of
/// values its passes draw it with (a camera pass and a shadow pass differ in
/// their depth raster).
///
/// A block is written when the item first draws with its values and kept
/// while they hold, compared field by field against the current-draw state,
/// so a frame that moves only the camera writes none. Values that change
/// take a fresh slot, so a frame still on the GPU keeps reading the block it
/// drew with.
final class HeldItemInfo {
  static const int _kept = 4;

  final List<_HeldItem> _entries = [];

  /// Gives every slot back as the item leaves its render scene.
  void release() {
    for (final entry in _entries) {
      entry.slots.release(entry.slot);
    }
    _entries.clear();
  }

  /// The block of the draw bound next, written if no held one matches.
  gpu.BufferView bound(double depthBias) {
    final generation = gpu.gpuContextGeneration;
    final epoch = currentDrawSpin == null
        ? 0.0
        : (currentAnimationTime / kAnimationTimeFold).floorToDouble();
    final frame = rendererSubmissions.latestSubmission;
    for (final entry in _entries) {
      if (entry.slots.generation == generation &&
          entry.holds(depthBias, epoch)) {
        entry.used = frame;
        return entry.view;
      }
    }
    _HeldItem? entry;
    if (_entries.length == _kept) {
      entry = _entries.reduce((a, b) => a.used <= b.used ? a : b);
      _entries.remove(entry);
      entry.slots.release(entry.slot);
    }
    final slots = HeldSlots.of(
      kItemInfoFloats * Float32List.bytesPerElement,
      alignment: gpu.gpuContext.minimumUniformByteAlignment,
    );
    final slot = slots.take();
    activeRenderCounters.itemInfoBytesWritten +=
        kItemInfoFloats * Float32List.bytesPerElement;
    entry = _HeldItem(
      slots,
      slot,
      slots.write(slot, _itemBytes(_packItemInfo(depthBias))),
    )..take(depthBias, epoch);
    entry.used = frame;
    _entries.add(entry);
    return entry.view;
  }
}

final class _HeldItem {
  _HeldItem(this.slots, this.slot, this.view);

  final HeldSlots slots;
  final int slot;
  final gpu.BufferView view;
  int used = 0;

  // The current-draw state the block was packed from.
  final Float32List _depth = Float32List(6);
  final Float32List _frame = Float32List(16);
  final Float32List _local = Float32List(16);
  final Float32List _band = Float32List(10);
  bool _hasFrame = false;
  bool _hasLocal = false;
  bool _hasBand = false;
  VertexSpin? _spin;
  double _epoch = 0.0;

  void take(double depthBias, double epoch) {
    _depth
      ..[0] = currentDrawDepthSteps[0]
      ..[1] = currentDrawDepthSteps[1]
      ..[2] = currentDrawDepthPixels[0]
      ..[3] = currentDrawDepthPixels[1]
      ..[4] = currentDrawDepthPixels[2]
      ..[5] = depthBias;
    final frame = currentDrawInstanceFrame;
    _hasFrame = frame != null;
    if (frame != null) _frame.setAll(0, frame.storage);
    final local = currentDrawInstanceLocal;
    _hasLocal = local != null;
    if (local != null) _local.setAll(0, local.storage);
    final band = currentDrawInstanceBand;
    _hasBand = band != null;
    if (band != null) band.writeTo(_band, 0);
    _spin = currentDrawSpin;
    _epoch = epoch;
  }

  bool holds(double depthBias, double epoch) {
    if (!identical(_spin, currentDrawSpin) || _epoch != epoch) return false;
    final depth = _depth;
    if (depth[0] != currentDrawDepthSteps[0] ||
        depth[1] != currentDrawDepthSteps[1] ||
        depth[2] != currentDrawDepthPixels[0] ||
        depth[3] != currentDrawDepthPixels[1] ||
        depth[4] != currentDrawDepthPixels[2] ||
        depth[5] != depthBias) {
      return false;
    }
    final frame = currentDrawInstanceFrame;
    if ((frame != null) != _hasFrame ||
        (frame != null && !_sameStorage(_frame, frame.storage))) {
      return false;
    }
    final local = currentDrawInstanceLocal;
    if ((local != null) != _hasLocal ||
        (local != null && !_sameStorage(_local, local.storage))) {
      return false;
    }
    final band = currentDrawInstanceBand;
    if ((band != null) != _hasBand) return false;
    return band == null || _sameBand(band);
  }

  bool _sameBand(InstanceBand band) {
    band.writeTo(_bandScratch, 0);
    return _same(_band, _bandScratch);
  }

  static final Float32List _bandScratch = Float32List(10);
}

bool _sameStorage(Float32List held, Float32List storage) {
  for (var index = 0; index < 16; index++) {
    if (held[index] != storage[index]) return false;
  }
  return true;
}
