/// Slots of device buffers that the draws of the process share, each held by
/// one draw from frame to frame and written only when what it holds changes.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
///
/// A block whose every slot was given back is destroyed at the release of its
/// last one: the backend keeps the buffer for the work already recorded or
/// submitted that reads it, and a later [take] makes the block again. No
/// empty block is kept warm, so the pool of a process that draws no more
/// scene holds no buffer. [take] fills the lowest block first, so the blocks
/// above it empty as their holders leave.
final class HeldSlots {
  HeldSlots._(this.slotBytes);

  /// The slots of [bytes] each at the context the GPU is open on, starting
  /// at multiples of [alignment]; those of a lost device are dropped.
  factory HeldSlots.of(int bytes, {int alignment = 1}) {
    final width = (bytes + alignment - 1) ~/ alignment * alignment;
    final held = _byBytes[width];
    if (held != null && held.generation == gpu.gpuContextGeneration) {
      return held;
    }
    return _byBytes[width] = HeldSlots._(width);
  }

  static final Map<int, HeldSlots> _byBytes = {};

  /// The bytes of each slot.
  final int slotBytes;

  /// The context generation the blocks were made on.
  final int generation = gpu.gpuContextGeneration;

  // The blocks by index, null where a block was destroyed; the slots of block
  // b are b * _slotsPerBlock onwards.
  final List<gpu.DeviceBuffer?> _blocks = [];
  // The slots of each block that are free to hand out, highest first.
  final List<List<int>> _free = [];
  // How many slots of each block are taken and not given back.
  final List<int> _taken = [];
  final List<int> _cooling = [];
  final List<int> _coolingAfter = [];

  /// A free slot.
  int take() {
    final done = rendererSubmissions.completedThrough;
    var cooled = 0;
    while (cooled < _cooling.length && _coolingAfter[cooled] <= done) {
      final slot = _cooling[cooled++];
      _free[slot ~/ _slotsPerBlock].add(slot);
    }
    if (cooled > 0) {
      _cooling.removeRange(0, cooled);
      _coolingAfter.removeRange(0, cooled);
    }
    var block = 0;
    while (block < _blocks.length &&
        (_blocks[block] == null || _free[block].isEmpty)) {
      block++;
    }
    if (block == _blocks.length) block = _open();
    _taken[block]++;
    _takenSlots++;
    return _free[block].removeLast();
  }

  static int _takenSlots = 0;

  /// The slots of every pool of the process that are taken and not given
  /// back.
  @visibleForTesting
  static int get takenSlots => _takenSlots;

  // Makes a block in the lowest destroyed place, or after the last, with
  // every slot free.
  int _open() {
    var block = _blocks.indexOf(null);
    if (block < 0) {
      block = _blocks.length;
      _blocks.add(null);
      _free.add([]);
      _taken.add(0);
    }
    _blocks[block] = gpu.gpuContext.createDeviceBuffer(
      gpu.StorageMode.hostVisible,
      _slotsPerBlock * slotBytes,
    );
    final first = block * _slotsPerBlock;
    _free[block] = [
      for (var slot = first + _slotsPerBlock - 1; slot >= first; slot--) slot,
    ];
    return block;
  }

  /// Gives [slot] back once the submissions made so far complete, and
  /// destroys its block when no other slot of it is taken.
  void release(int slot) {
    _takenSlots--;
    final block = slot ~/ _slotsPerBlock;
    _cooling.add(slot);
    _coolingAfter.add(rendererSubmissions.latestSubmission);
    if (--_taken[block] == 0) _destroy(block);
  }

  void _destroy(int block) {
    gpu.gpuHost.releaseBuffer(_blocks[block]!);
    _blocks[block] = null;
    _free[block] = [];
    for (var at = _cooling.length - 1; at >= 0; at--) {
      if (_cooling[at] ~/ _slotsPerBlock != block) continue;
      _cooling.removeAt(at);
      _coolingAfter.removeAt(at);
    }
    while (_blocks.isNotEmpty && _blocks.last == null) {
      _blocks.removeLast();
      _free.removeLast();
      _taken.removeLast();
    }
  }

  /// Writes [bytes] at the start of [slot] and returns a view of them.
  gpu.BufferView write(int slot, ByteData bytes) {
    final buffer = _blocks[slot ~/ _slotsPerBlock]!;
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
