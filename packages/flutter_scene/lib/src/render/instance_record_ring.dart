/// The device copies of one store of instance records.
///
/// A frame the GPU has not finished may still read the buffer it bound, so a
/// record that changes meanwhile is written into another buffer of the ring,
/// and into the first again once it comes free. Only the changed ranges are
/// written: no change copies the store.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/render_stats.dart';

/// One buffer of an [InstanceRecordRing] on the device.
abstract interface class InstanceRecordBuffer {
  /// Writes [records] at [offsetInBytes].
  void write(ByteData records, int offsetInBytes);
}

/// Creates the buffers an [InstanceRecordRing] writes.
abstract interface class InstanceRecordDevice {
  /// A buffer of [sizeInBytes] whose contents are not yet written.
  InstanceRecordBuffer create(int sizeInBytes);
}

/// An [InstanceRecordBuffer] over a buffer of the GPU context.
final class GpuInstanceRecordBuffer implements InstanceRecordBuffer {
  GpuInstanceRecordBuffer._(this.buffer);

  /// The buffer a pass binds.
  final gpu.DeviceBuffer buffer;

  @override
  void write(ByteData records, int offsetInBytes) {
    buffer
      ..overwrite(records, destinationOffsetInBytes: offsetInBytes)
      ..flush(
        offsetInBytes: offsetInBytes,
        lengthInBytes: records.lengthInBytes,
      );
  }
}

final class _GpuInstanceRecordDevice implements InstanceRecordDevice {
  const _GpuInstanceRecordDevice();

  @override
  InstanceRecordBuffer create(int sizeInBytes) => GpuInstanceRecordBuffer._(
    gpu.gpuContext.createDeviceBuffer(gpu.StorageMode.hostVisible, sizeInBytes),
  );
}

/// The device every [InstanceRecordRing] creates its buffers on.
InstanceRecordDevice get instanceRecordDevice => _device;
InstanceRecordDevice _device = const _GpuInstanceRecordDevice();

/// Replaces the device of every ring for a test that runs without a GPU, or
/// restores the GPU context with null.
@visibleForTesting
set debugInstanceRecordDevice(InstanceRecordDevice? device) =>
    _device = device ?? const _GpuInstanceRecordDevice();

const int _frameHistory = 8;
final Int64List _frameStarts = Int64List(_frameHistory);
int _frame = 0;

/// Starts a frame: a buffer a ring bound in an earlier frame comes free once
/// the submissions of that frame completed.
void beginInstanceRecordFrame() {
  _frame++;
  _frameStarts[_frame % _frameHistory] = rendererSubmissions.latestSubmission;
}

// The last submission that may read a buffer bound in [frame], which is over.
int _lastSubmissionOf(int frame) => _frame - frame < _frameHistory
    ? _frameStarts[(frame + 1) % _frameHistory]
    : _frameStarts[_frame % _frameHistory];

const int _rangeLimit = 256;

// Row ranges as pairs of a first row and an end row. Ranges that [collapse]
// join into one span while they number more than the limit, which names rows
// that did not change; the others keep every range, so their rows count the
// changed rows exactly.
final class _Ranges {
  _Ranges({this.collapse = true});

  final bool collapse;
  final List<int> pairs = [];
  int _normalizeAt = _rangeLimit * 2;

  bool get isEmpty => pairs.isEmpty;

  void add(int first, int end) {
    final last = pairs.length - 2;
    if (last >= 0 && first <= pairs[last + 1] && end >= pairs[last]) {
      if (first < pairs[last]) pairs[last] = first;
      if (end > pairs[last + 1]) pairs[last + 1] = end;
      return;
    }
    pairs
      ..add(first)
      ..add(end);
    if (pairs.length > _normalizeAt) {
      normalize();
      _normalizeAt = pairs.length > _rangeLimit
          ? pairs.length * 2
          : _rangeLimit * 2;
    }
  }

  void addAll(_Ranges other) {
    for (var index = 0; index < other.pairs.length; index += 2) {
      add(other.pairs[index], other.pairs[index + 1]);
    }
  }

  // Sorts the ranges and joins those that touch, then, where the ranges
  // collapse, joins them all into one while they number more than the limit.
  void normalize() {
    if (pairs.length <= 2) return;
    final order = List<int>.generate(pairs.length >> 1, (index) => index * 2)
      ..sort((a, b) => pairs[a].compareTo(pairs[b]));
    final merged = <int>[];
    for (final at in order) {
      final last = merged.length - 2;
      if (last >= 0 && pairs[at] <= merged[last + 1]) {
        if (pairs[at + 1] > merged[last + 1]) merged[last + 1] = pairs[at + 1];
      } else {
        merged
          ..add(pairs[at])
          ..add(pairs[at + 1]);
      }
    }
    if (collapse && merged.length > _rangeLimit * 2) {
      final end = merged.last;
      merged
        ..length = 2
        ..[1] = end;
    }
    pairs
      ..clear()
      ..addAll(merged);
  }

  // The rows below [count] the ranges hold.
  int rowsBelow(int count) {
    var rows = 0;
    for (var index = 0; index < pairs.length; index += 2) {
      final end = pairs[index + 1] < count ? pairs[index + 1] : count;
      if (end > pairs[index]) rows += end - pairs[index];
    }
    return rows;
  }

  int get firstRow {
    var first = pairs[0];
    for (var index = 2; index < pairs.length; index += 2) {
      if (pairs[index] < first) first = pairs[index];
    }
    return first;
  }

  void clear() {
    pairs.clear();
    _normalizeAt = _rangeLimit * 2;
  }
}

final class _RingBuffer {
  _RingBuffer(this.buffer, this.sizeInBytes);

  final InstanceRecordBuffer buffer;
  final int sizeInBytes;
  final _Ranges pending = _Ranges();

  // The frame that last bound the buffer, and the most rows a frame that may
  // still read it draws.
  int boundFrame = -1;
  int boundRows = 0;

  bool get free =>
      boundFrame < 0 ||
      (boundFrame != _frame &&
          rendererSubmissions.completedThrough >=
              _lastSubmissionOf(boundFrame));
}

const int _idleFrames = 120;

/// The device copies of one record store: see the library comment.
final class InstanceRecordRing {
  final List<_RingBuffer> _buffers = [];
  final _Ranges _landed = _Ranges(collapse: false);
  _RingBuffer? _current;

  /// The buffers the ring holds on the device.
  @visibleForTesting
  int get bufferCount => _buffers.length;

  /// States that rows `[first, first + count)` of the store changed.
  void changed(int first, int count) {
    if (count <= 0) return;
    _landed.add(first, first + count);
  }

  // Gives back a buffer no frame bound for a while.
  void _dropIdle() {
    final current = _current;
    _buffers.removeWhere(
      (buffer) =>
          !identical(buffer, current) &&
          _frame - buffer.boundFrame > _idleFrames,
    );
  }

  /// Drops every device copy, after a change of the record layout.
  void reset() {
    _buffers.clear();
    _landed.clear();
    _current = null;
  }

  /// The buffer that holds the first [count] records of [store], each of
  /// [recordBytes], for the passes of this frame, or null for no record.
  ///
  /// [store] is the whole store, whose length is the size of each buffer, so
  /// a row appended within it is written in place. The changed ranges are
  /// written here: into the bound buffer where no frame in flight reads
  /// them, into the next free buffer otherwise.
  InstanceRecordBuffer? sync(ByteData store, int count, int recordBytes) {
    if (count == 0) {
      _landed.clear();
      for (final buffer in _buffers) {
        buffer.pending.clear();
      }
      return null;
    }
    final size = store.lengthInBytes;
    if (_buffers.isNotEmpty && _buffers.first.sizeInBytes != size) {
      _buffers.clear();
      _current = null;
    }
    var landedBytes = 0;
    if (!_landed.isEmpty) {
      _landed.normalize();
      landedBytes = _landed.rowsBelow(count) * recordBytes;
      for (final buffer in _buffers) {
        buffer.pending.addAll(_landed);
      }
    }
    var current = _current;
    if (_buffers.length > 1) _dropIdle();
    if (current != null && !current.pending.isEmpty) {
      if (current.free) {
        current.boundRows = 0;
      } else if (current.pending.firstRow < current.boundRows) {
        current = null;
        for (final buffer in _buffers) {
          if (buffer.free) {
            current = buffer..boundRows = 0;
            break;
          }
        }
      }
    }
    var written = 0;
    if (current == null) {
      current = _RingBuffer(instanceRecordDevice.create(size), size);
      _buffers.add(current);
      final bytes = count * recordBytes;
      current.buffer.write(ByteData.sublistView(store, 0, bytes), 0);
      written = bytes;
    } else if (!current.pending.isEmpty) {
      final pending = current.pending..normalize();
      for (var index = 0; index < pending.pairs.length; index += 2) {
        final first = pending.pairs[index];
        final end = pending.pairs[index + 1] < count
            ? pending.pairs[index + 1]
            : count;
        if (end <= first) continue;
        final offset = first * recordBytes;
        final bytes = (end - first) * recordBytes;
        current.buffer.write(
          ByteData.sublistView(store, offset, offset + bytes),
          offset,
        );
        written += bytes;
      }
      pending.clear();
    }
    _landed.clear();
    _current = current
      ..boundFrame = _frame
      ..boundRows = count > current.boundRows ? count : current.boundRows;
    activeRenderCounters
      ..instanceBytesUploaded += landedBytes
      ..instanceBytesReplayed += written - landedBytes;
    return current.buffer;
  }
}
