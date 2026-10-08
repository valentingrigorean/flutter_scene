import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/instanced_mesh.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/instance_record_ring.dart';

/// Floats of one shared record: the row's transform, then its color.
const int kSharedRecordFloats = 20;

const int _sharedRecordBytes =
    kSharedRecordFloats * Float32List.bytesPerElement;

/// The records of the rows of one [InstancedMesh] on the device, drawn by
/// every mesh that shares those rows (see [InstancedMesh.sharing]).
///
/// A record is the row's own transform and color, in the space of whichever
/// node draws it, so it holds for every sharing mesh. A mesh that holds
/// records hands its store over as it is; the rows of a mesh of instances
/// are packed when they change, the changed rows alone when no row moved.
/// Either way the changed rows alone are written to the device, through an
/// [InstanceRecordRing], and bound by range without packing on a frame.
final class SharedInstanceRows {
  SharedInstanceRows._(this._rows);

  final InstancedMesh _rows;
  Float32List _store = Float32List(0);
  ByteData? _storeBytes;
  final InstanceRecordRing _packedRing = InstanceRecordRing();
  gpu.DeviceBuffer? _buffer;
  int _revision = -1;
  int _count = 0;
  int _recordBytes = _sharedRecordBytes;

  /// Whether the rows mirror, which they do all or none.
  bool get flipped => _flipped;
  bool _flipped = false;

  /// The row count the device holds.
  int get count => _count;

  void _sync() {
    if (_rows.holdsRecords) {
      _count = _rows.instanceCount;
      _flipped = _rows.recordsMirrored;
      _recordBytes = _rows.instanceRecordFloats * Float32List.bytesPerElement;
      _bind(_rows.recordRing, _rows.recordStoreBytes);
      return;
    }
    _pack();
    _bind(_packedRing, _storeBytes ??= ByteData.sublistView(_store));
  }

  // The ring is asked on every frame that draws, so it knows which frame
  // last bound each of its buffers.
  void _bind(InstanceRecordRing ring, ByteData store) {
    final synced = ring.sync(store, _count, _recordBytes);
    _buffer = synced is GpuInstanceRecordBuffer ? synced.buffer : null;
  }

  void _pack() {
    final revision = _rows.revision;
    if (revision == _revision) return;
    final transforms = _rows.instances;
    final colors = _rows.colors;
    final count = transforms.length;
    final changed = _revision < 0 ? null : _rows.rowsChangedSince(_revision);
    _revision = revision;
    _count = count;
    final winding = _rows.windingFlipped;
    _flipped = count > 0 && winding[0];
    assert(
      !winding.contains(!_flipped),
      'The rows of a shared instance set have one winding.',
    );
    final floats = count * kSharedRecordFloats;
    if (_store.length < floats) {
      final grown = Float32List(
        floats > _store.length * 2 ? floats : _store.length * 2,
      );
      if (changed != null) grown.setRange(0, _store.length, _store);
      _store = grown;
      _storeBytes = null;
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
      _packedRing.changed(0, count);
    } else {
      for (final row in changed) {
        if (row >= count) continue;
        pack(row);
        packed++;
        _packedRing.changed(row, 1);
      }
    }
    activeRenderCounters.instanceBytesPacked += packed * _sharedRecordBytes;
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

/// What one frame did to the instance records of the meshes it drew, as
/// [debugDrawInstanceRecords] answers it.
final class InstanceRecordFrame {
  const InstanceRecordFrame._({
    required this.submission,
    required this.bytesUploaded,
    required this.bytesReplayed,
  });

  /// The id of the frame's submission, in flight until
  /// [debugCompleteInstanceRecordFrame] takes it.
  final int submission;

  /// The frame's share of `RenderCounters.instanceBytesUploaded`.
  final int bytesUploaded;

  /// The frame's share of `RenderCounters.instanceBytesReplayed`.
  final int bytesReplayed;
}

/// Runs what a frame that draws [meshes] does to their instance records,
/// for a test without a GPU (see [debugInstanceRecordDevice]): starts the
/// frame, has each mesh's records written and bound as a pass does, and
/// submits the frame, which stays on the GPU until
/// [debugCompleteInstanceRecordFrame].
@visibleForTesting
InstanceRecordFrame debugDrawInstanceRecords(Iterable<InstancedMesh> meshes) {
  final uploaded = activeRenderCounters.instanceBytesUploaded;
  final replayed = activeRenderCounters.instanceBytesReplayed;
  beginInstanceRecordFrame();
  for (final mesh in meshes) {
    final source = mesh.recordSource;
    if (source != null) sharedInstanceRowsOf(source);
  }
  return InstanceRecordFrame._(
    submission: debugRecordSubmission(),
    bytesUploaded: activeRenderCounters.instanceBytesUploaded - uploaded,
    bytesReplayed: activeRenderCounters.instanceBytesReplayed - replayed,
  );
}

/// Marks the frame of [debugDrawInstanceRecords] as finished by the GPU.
@visibleForTesting
void debugCompleteInstanceRecordFrame(InstanceRecordFrame frame) =>
    debugCompleteSubmission(frame.submission);
