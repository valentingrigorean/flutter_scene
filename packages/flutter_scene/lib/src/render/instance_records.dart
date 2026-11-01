/// The instance records the passes of a frame bind without packing.
///
/// An item that draws one instance holds its record, the world transform and
/// a white colour, in a slot of a device buffer the items of the process
/// share. The slot is written when the item's transform changes and bound by
/// every draw until then. An instanced item draws ranges of the rows of its
/// record store, see [bindInstanceRows].
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/held_slots.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:meta/meta.dart' show internal;

/// The record an item that draws one instance holds on the device.
final class HeldInstanceRecord {
  HeldSlots? _slots;
  int _slot = -1;
  int _transformRevision = -1;
  gpu.BufferView? _view;

  /// Gives the slot back as the item leaves its render scene.
  void release() {
    _slots?.release(_slot);
    _slots = null;
    _slot = -1;
    _view = null;
  }
}

/// Binds [item]'s one record to the instance-rate [slot]: its world
/// transform, a white colour multiplier, then [attributeFloats] zeros for a
/// material that declares `instance_attributes`.
///
/// The record is written when the item first draws, when its world transform
/// changed since, and when a draw asks for a wider record. A change takes a
/// fresh slot, so a frame still on the GPU keeps reading the record it drew
/// with.
void bindHeldInstanceRecord(
  gpu.RenderPass pass,
  RenderItem item, {
  required int slot,
  int attributeFloats = 0,
}) {
  final held = item.heldInstanceRecord;
  final bytes =
      (kInstanceRecordFloats + attributeFloats) * Float32List.bytesPerElement;
  var slots = held._slots;
  var view = held._view;
  if (view == null ||
      slots == null ||
      slots.slotBytes < bytes ||
      slots.generation != gpu.gpuContextGeneration ||
      held._transformRevision != item.worldTransformRevision) {
    final width = slots == null || slots.slotBytes < bytes
        ? bytes
        : slots.slotBytes;
    // Taken before the old slot goes back, so a moving item that is alone
    // in its block keeps the block.
    slots = HeldSlots.of(width);
    final taken = slots.take();
    held
      ..release()
      .._slots = slots
      .._slot = taken
      .._transformRevision = item.worldTransformRevision;
    activeRenderCounters.instanceBytesUploaded += width;
    view = held._view = slots.write(
      held._slot,
      ByteData.sublistView(
        packSingleInstanceData(
          item.worldTransform,
          attributeFloats:
              width ~/ Float32List.bytesPerElement - kInstanceRecordFloats,
        ),
      ),
    );
  }
  heldInstanceBinding = (
    slot: slot,
    floats: kInstanceRecordFloats + attributeFloats,
  );
  pass.bindVertexBuffer(view, slot: slot);
}

/// The instance-rate slot and record floats of the last
/// [bindHeldInstanceRecord], for a pass that keeps the draw it records as
/// one of a run of instances (see `RetainedDraws`); null once read.
@internal
({int slot, int floats})? heldInstanceBinding;

/// Binds rows `[first, first + count)` of [item]'s instance records to the
/// instance-rate [slot], from the device copy the item keeps while its
/// instances rest, or from one copy of the whole store in the transient
/// arena on a frame that changed them.
///
/// No record is packed: a pass draws the ranges [RenderItem.instanceRowRanges]
/// or a cull of its cells names, one instanced draw per range.
void bindInstanceRows(
  gpu.RenderPass pass,
  RenderItem item,
  int first,
  int count, {
  required int slot,
}) {
  final records = item.instanceWorldData!;
  final recordBytes = item.instanceRecordFloats * Float32List.bytesPerElement;
  final base = instanceRecordBase(records, recordBytes);
  pass.bindVertexBuffer(
    first == 0 && count * recordBytes == base.lengthInBytes
        ? base
        : gpu.BufferView(
            base.buffer,
            offsetInBytes: base.offsetInBytes + first * recordBytes,
            lengthInBytes: count * recordBytes,
          ),
    slot: slot,
  );
}
