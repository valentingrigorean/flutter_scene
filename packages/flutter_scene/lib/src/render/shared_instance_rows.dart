import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/instanced_mesh.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';

/// Floats of one shared record: the row's transform, then its color.
const int kSharedRecordFloats = 20;

const int _recordBytes = kSharedRecordFloats * Float32List.bytesPerElement;

/// The records of the rows of one [InstancedMesh] on the device, drawn by
/// every mesh that shares those rows (see [InstancedMesh.sharing]).
///
/// A record is the row's own transform and color, in the space of whichever
/// node draws it, so it holds for every sharing mesh. The records are packed
/// and uploaded when the rows change, the changed rows alone when no row
/// moved, and bound by range without packing on a frame.
final class SharedInstanceRows {
  SharedInstanceRows._(this._rows);

  final InstancedMesh _rows;
  Float32List _store = Float32List(0);
  gpu.DeviceBuffer? _buffer;
  int _revision = -1;
  int _count = 0;

  /// Whether the rows mirror, which they do all or none.
  bool get flipped => _flipped;
  bool _flipped = false;

  /// The row count the device holds.
  int get count => _count;

  void _sync() {
    final revision = _rows.revision;
    if (revision == _revision) return;
    final transforms = _rows.instances;
    final colors = _rows.colors;
    final count = transforms.length;
    final changed = _buffer == null ? null : _rows.rowsChangedSince(_revision);
    _revision = revision;
    _count = count;
    final winding = _rows.windingFlipped;
    _flipped = count > 0 && winding[0];
    assert(
      !winding.contains(!_flipped),
      'The rows of a shared instance set have one winding.',
    );
    final floats = count * kSharedRecordFloats;
    final grows = _store.length < floats;
    if (grows) {
      final grown = Float32List(
        floats > _store.length * 2 ? floats : _store.length * 2,
      );
      if (changed != null) grown.setRange(0, _store.length, _store);
      _store = grown;
    }
    void pack(int row) {
      final offset = row * kSharedRecordFloats;
      _store
        ..setAll(offset, transforms[row].storage)
        ..setAll(offset + 16, colors[row].storage);
    }

    var packed = 0;
    if (changed == null) {
      for (var row = 0; row < count; row++) {
        pack(row);
      }
      packed = count;
    } else {
      for (final row in changed) {
        if (row >= count) continue;
        pack(row);
        packed++;
      }
    }
    activeRenderCounters.instanceBytesPacked += packed * _recordBytes;
    if (count == 0) {
      _buffer = null;
      return;
    }
    final buffer = _buffer;
    // A frame still on the GPU may read the buffer, so it is written in place
    // only once every submission completed.
    if (buffer == null ||
        changed == null ||
        grows ||
        rendererSubmissions.completedThrough <
            rendererSubmissions.latestSubmission) {
      _buffer = gpu.gpuContext.createDeviceBufferWithCopy(
        _store.buffer.asByteData(),
      );
      activeRenderCounters.instanceBytesUploaded += _store.lengthInBytes;
      return;
    }
    var low = buffer.sizeInBytes;
    var high = 0;
    for (final row in changed) {
      if (row >= count) continue;
      final offset = row * _recordBytes;
      buffer.overwrite(
        _store.buffer.asByteData(offset, _recordBytes),
        destinationOffsetInBytes: offset,
      );
      activeRenderCounters.instanceBytesUploaded += _recordBytes;
      if (offset < low) low = offset;
      if (offset + _recordBytes > high) high = offset + _recordBytes;
    }
    if (high > low) buffer.flush(offsetInBytes: low, lengthInBytes: high - low);
  }

  /// The count of draws [ranges] asks for: one per pair, or one for null.
  int drawCountOf(Uint32List? ranges) =>
      ranges == null ? 1 : ranges.length >> 1;

  /// Binds the records of draw [index] of [ranges] to the instance-rate
  /// [slot] and returns its row count, zero when the draw holds no row.
  int bind(gpu.RenderPass pass, Uint32List? ranges, int index, int slot) {
    final buffer = _buffer;
    if (buffer == null) return 0;
    var first = 0;
    var count = _count;
    if (ranges != null) {
      first = ranges[index * 2];
      if (first >= _count) return 0;
      final asked = ranges[index * 2 + 1];
      count = first + asked > _count ? _count - first : asked;
    }
    if (count == 0) return 0;
    pass.bindVertexBuffer(
      gpu.BufferView(
        buffer,
        offsetInBytes: first * _recordBytes,
        lengthInBytes: count * _recordBytes,
      ),
      slot: slot,
    );
    return count;
  }
}

final Expando<SharedInstanceRows> _sharedRows = Expando();

/// The device records of the rows of [rows], up to date with its rows.
SharedInstanceRows sharedInstanceRowsOf(InstancedMesh rows) {
  final shared = _sharedRows[rows] ??= SharedInstanceRows._(rows);
  shared._sync();
  return shared;
}
