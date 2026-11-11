/// The check a debug build makes where a kept draw is taken as current: the
/// draw is recorded again and compared with what its item holds.
library;

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_stats.dart';

/// Runs the record of a kept draw's check. An owner whose record counts
/// work wraps it to leave its counts as they stood.
void Function(void Function() record) debugRecordKeptDrawAgain = _run;

void _run(void Function() record) => record();

/// Thrown by a debug build where a kept draw differs from the same draw
/// recorded again, so the draw on screen is stale.
final class KeptDrawError extends Error {
  /// A draw of [kind] that differs in [field].
  KeptDrawError(this.kind, this.field);

  /// The draw, and what took it as current.
  final String kind;

  /// The first field of the draw that differs.
  final String field;

  @override
  String toString() =>
      'A kept draw differs from its recording in "$field": $kind.';
}

/// Runs [record], which records a kept draw again, and leaves the render
/// counters as they stood.
void recordKeptDrawAgain(void Function() record) {
  final counters = RenderCounters()..copyFrom(activeRenderCounters);
  try {
    debugRecordKeptDrawAgain(record);
  } finally {
    activeRenderCounters.copyFrom(counters);
  }
}

/// Whether item [id] of [items] holds the draw [record] records, for a
/// caller that takes the item as current without keeping it again: call it
/// in an `assert`. [record] returns the recorder it recorded the one draw
/// on, and the rest is what an `ItemSet.keep` of it would pass.
///
/// Throws a [KeptDrawError] naming [kind] where the two differ. True
/// wherever the item is not checked (`debugChecksKeptDraws`).
bool keptDrawHolds(
  gpu.ItemSet items,
  int id,
  gpu.RenderPass Function() record, {
  required String kind,
  required int passes,
  Float32List? bounds,
  gpu.ItemInstances? instances,
  int? order,
}) {
  final held = items.kept(id);
  if (held == null) return true;
  late gpu.RenderPass recorder;
  recordKeptDrawAgain(() => recorder = record());
  final now = items.recorded(
    recorder,
    passes: passes,
    bounds: bounds,
    instances: instances,
    order: order,
  );
  final field = now == null ? null : held.differs(now);
  if (field != null) throw KeptDrawError(kind, field);
  return true;
}
