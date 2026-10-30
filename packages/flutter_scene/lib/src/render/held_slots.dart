/// Slots of device buffers that the draws of the process share, each held by
/// one draw from frame to frame and written only when what it holds changes.
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/frame_transients.dart';

const int _slotsPerBlock = 256;

/// Slots of [slotBytes] each, in blocks of device buffers.
///
/// A slot a draw gives back with [release] may still be read by a frame on
/// the GPU, so it is handed out again only once every submission made before
/// it was released completed. A holder whose contents change takes a fresh
/// slot and releases the old one, so a frame in flight keeps reading what it
/// drew with on every backend.
final class HeldSlots {
  HeldSlots._(this.slotBytes);

  /// The slots of [bytes] each on the context the GPU is open on, starting
  /// at multiples of [alignment]; those of another context are dropped.
  factory HeldSlots.of(int bytes, {int alignment = 1}) {
    final width = (bytes + alignment - 1) ~/ alignment * alignment;
    final held = _byBytes[width];
    if (held != null && held.holdsCurrentContext) return held;
    return _byBytes[width] = HeldSlots._(width);
  }

  static final Map<int, HeldSlots> _byBytes = {};

  /// The bytes of each slot.
  final int slotBytes;

  /// The context the blocks were made on.
  final Object context = gpu.gpuContext;

  /// Whether the blocks were made on the context the GPU is open on.
  bool get holdsCurrentContext => identical(context, gpu.gpuContext);

  final List<gpu.DeviceBuffer> _blocks = [];
  final List<int> _free = [];
  final List<int> _cooling = [];
  final List<int> _coolingAfter = [];
  int _next = 0;

  /// A free slot.
  int take() {
    final done = rendererSubmissions.completedThrough;
    var cooled = 0;
    while (cooled < _cooling.length && _coolingAfter[cooled] <= done) {
      _free.add(_cooling[cooled++]);
    }
    if (cooled > 0) {
      _cooling.removeRange(0, cooled);
      _coolingAfter.removeRange(0, cooled);
    }
    if (_free.isNotEmpty) return _free.removeLast();
    final slot = _next++;
    if (slot ~/ _slotsPerBlock == _blocks.length) {
      _blocks.add(
        gpu.gpuContext.createDeviceBuffer(
          gpu.StorageMode.hostVisible,
          _slotsPerBlock * slotBytes,
        ),
      );
    }
    return slot;
  }

  /// Gives [slot] back once the submissions made so far complete.
  void release(int slot) {
    _cooling.add(slot);
    _coolingAfter.add(rendererSubmissions.latestSubmission);
  }

  /// Writes [bytes] at the start of [slot] and returns a view of them.
  gpu.BufferView write(int slot, ByteData bytes) {
    final buffer = _blocks[slot ~/ _slotsPerBlock];
    final offset = (slot % _slotsPerBlock) * slotBytes;
    buffer
      ..overwrite(bytes, destinationOffsetInBytes: offset)
      ..flush(offsetInBytes: offset, lengthInBytes: bytes.lengthInBytes);
    return gpu.BufferView(
      buffer,
      offsetInBytes: offset,
      lengthInBytes: bytes.lengthInBytes,
    );
  }
}
