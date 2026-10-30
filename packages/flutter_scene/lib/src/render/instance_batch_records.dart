/// The instance records of the opaque draws that join one instanced draw
/// (see `Geometry.instanceBatchKey`), kept on the device by the batch from
/// frame to frame.
///
/// A frame packs its members' records as before and the batch writes only
/// the records that differ from the ones it holds, through an
/// [InstanceRecordRing], so a batch whose members stand still writes
/// nothing while the camera moves.
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/instance_record_ring.dart';

final class _BatchRecords {
  Float32List held = Float32List(0);
  int count = 0;
  final InstanceRecordRing ring = InstanceRecordRing();
  int used = 0;
}

final Map<Object, _BatchRecords> _batches = {};
int _sweepAt = 0;

/// How many submissions a batch is kept after it last drew.
const int _idleSubmissions = 240;

/// The device copy of the first [count] records of [records] for the batch
/// [key] (its view and its instance batch key), written where they differ
/// from the copy the batch held; null where the records live on no GPU
/// buffer (a test without a GPU).
gpu.BufferView? instanceBatchRecords(
  Object key,
  Float32List records,
  int count,
) {
  final latest = rendererSubmissions.latestSubmission;
  final batch = _batches[key] ??= _BatchRecords();
  batch.used = latest;
  if (latest >= _sweepAt) {
    _sweepAt = latest + _idleSubmissions;
    _batches.removeWhere((_, held) => latest - held.used > _idleSubmissions);
  }
  const stride = kInstanceRecordFloats;
  final floats = count * stride;
  var held = batch.held;
  if (held.length < floats) {
    final grown = Float32List(floats * 2)..setAll(0, held);
    batch
      ..held = grown
      ..ring.reset();
    held = grown;
    batch.ring.changed(0, count);
  } else {
    for (var row = 0; row < count; row++) {
      final at = row * stride;
      if (row >= batch.count || !_sameRecord(held, records, at)) {
        batch.ring.changed(row, 1);
      }
    }
  }
  held.setRange(0, floats, records);
  batch.count = count;
  final buffer = batch.ring.sync(ByteData.sublistView(held), count, stride * 4);
  if (buffer is! GpuInstanceRecordBuffer) return null;
  return gpu.BufferView(
    buffer.buffer,
    offsetInBytes: 0,
    lengthInBytes: floats * Float32List.bytesPerElement,
  );
}

bool _sameRecord(Float32List held, Float32List records, int at) {
  for (var index = at; index < at + kInstanceRecordFloats; index++) {
    if (held[index] != records[index]) return false;
  }
  return true;
}
