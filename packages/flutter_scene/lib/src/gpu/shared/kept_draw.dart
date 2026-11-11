import 'dart:typed_data';

import 'item_instances.dart';

/// Whether a debug build records a kept draw again where its owner takes it
/// as current and fails where the two differ (`ItemSet.kept`,
/// `ItemSet.recorded`). While set, a debug build mirrors the bytes written
/// to each device buffer, and those a buffer of at most 64 KiB is made with;
/// a uniform block written while it is off compares as zeros.
bool debugChecksKeptDraws = true;

/// Whether `GpuContext.createItemSet` makes no set in a debug build, so
/// every draw is encoded.
bool debugKeepsNoItems = false;

/// What one draw of an `ItemSet` binds, in a debug build: `ItemSet.kept` for
/// an item as it stands, `ItemSet.recorded` for the draw a recorder holds.
final class KeptDraw {
  /// A draw of [pipeline] in [state] issuing [call].
  KeptDraw({
    required this.pipeline,
    required this.state,
    required this.call,
    required this.vertices,
    required this.indices,
    required this.blocks,
    required this.textures,
    required this.prologue,
    required this.transient,
    required this.passes,
    required this.order,
    required this.bounds,
    required this.instances,
  });

  /// The render pipeline.
  final Object? pipeline;

  /// The fixed-function state, by name.
  final Map<String, Object?> state;

  /// The draw call's arguments; null where the recorder holds no draw or
  /// several.
  final List<Object?>? call;

  /// The buffer, offset and length bound at each vertex slot.
  final Map<int, List<Object?>> vertices;

  /// The index buffer, offset, length and type.
  final List<Object?>? indices;

  /// The bytes of each uniform block by shader and name, read when this was
  /// made; null for a view block.
  final Map<(Object, String), Uint8List?> blocks;

  /// The texture and sampler values by shader and name; a null texture for
  /// a view texture.
  final Map<(Object, String), List<Object?>> textures;

  /// The prologue the draw runs once kept.
  final Object? prologue;

  /// Whether the draw reads a transient buffer or texture, which no item
  /// holds.
  final bool transient;

  /// The passes the item draws in.
  final int passes;

  /// The item's order in its passes.
  final int? order;

  /// The item's bounds.
  final Float32List? bounds;

  /// The item's instances.
  final ItemInstances? instances;

  /// The bytes of the block [name], of the first shader that binds one.
  Uint8List? block(String name) {
    for (final MapEntry(:key, :value) in blocks.entries) {
      if (key.$2 == name) return value;
    }
    return null;
  }

  /// The first field in which [now] differs from this draw that [but] does
  /// not name, or null where none does. With instances, the vertex slot
  /// they replace and the instance count are not compared.
  String? differs(KeptDraw now, {bool Function(String field)? but}) {
    for (final (field, same) in _fields(now)) {
      if (!same && !(but?.call(field) ?? false)) return field;
    }
    return null;
  }

  Iterable<(String, bool)> _fields(KeptDraw now) sync* {
    yield ('transient', transient == now.transient);
    yield ('pipeline', identical(pipeline, now.pipeline));
    for (final name in {...state.keys, ...now.state.keys}) {
      yield ('state $name', state[name] == now.state[name]);
    }
    final placed = instances != null && now.instances != null;
    final drawn = call;
    final redrawn = now.call;
    yield (
      'draw',
      drawn != null &&
          redrawn != null &&
          _same(
            placed ? ([...drawn]..[1] = null) : drawn,
            placed ? ([...redrawn]..[1] = null) : redrawn,
          ),
    );
    for (final slot in {...vertices.keys, ...now.vertices.keys}) {
      if (placed && slot == instances!.slot) continue;
      yield ('vertices $slot', _same(vertices[slot], now.vertices[slot]));
    }
    yield ('indices', _same(indices, now.indices));
    for (final key in {...blocks.keys, ...now.blocks.keys}) {
      yield (
        'block ${key.$2}',
        blocks.containsKey(key) &&
            now.blocks.containsKey(key) &&
            _same(blocks[key], now.blocks[key]),
      );
    }
    for (final key in {...textures.keys, ...now.textures.keys}) {
      yield ('texture ${key.$2}', _same(textures[key], now.textures[key]));
    }
    yield ('prologue', identical(prologue, now.prologue));
    yield ('passes', passes == now.passes);
    yield ('order', order == now.order);
    yield ('bounds', _same(bounds, now.bounds));
    final held = instances;
    final fresh = now.instances;
    yield (
      'instances',
      (held == null) == (fresh == null) &&
          (held == null ||
              held.slot == fresh!.slot &&
                  held.stride == fresh.stride &&
                  held.count == fresh.count),
    );
    if (held == null || fresh == null) return;
    yield ('instance records', _same(held.records, fresh.records));
    yield ('instance bounds', _same(held.bounds, fresh.bounds));
  }

  static bool _same(List<Object?>? a, List<Object?>? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (var at = 0; at < a.length; at++) {
      if (a[at] != b[at]) return false;
    }
    return true;
  }
}
