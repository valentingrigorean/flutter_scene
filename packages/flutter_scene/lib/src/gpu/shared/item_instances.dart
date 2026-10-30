import 'dart:typed_data';

/// The instances a kept render item draws as one instanced draw: a run of
/// items that share everything but their instance records.
///
/// The item draws its recorded draw with the vertex buffer at [slot] replaced
/// by the records of the instances a pass does not cull, and its instance
/// count by their number. Each instance is culled by its own bounds, so an
/// instance out of view costs no draw and no vertex work.
final class ItemInstances {
  /// Instances of [records], [stride] bytes each, drawn from vertex buffer
  /// [slot] and culled by [bounds].
  ItemInstances({
    required this.slot,
    required this.stride,
    required this.records,
    this.bounds,
  }) : assert(stride > 0 && records.lengthInBytes % stride == 0),
       assert(
         bounds == null || bounds.length == records.lengthInBytes ~/ stride * 6,
       );

  /// The instance-rate vertex buffer slot the records replace.
  final int slot;

  /// The bytes of one record.
  final int stride;

  /// The records, one per instance in draw order.
  final Uint8List records;

  /// Each instance's min x, y, z and max x, y, z in the space a draw's clip
  /// matrix maps, six floats per instance; null when none is culled.
  final Float32List? bounds;

  /// The number of instances.
  int get count => records.lengthInBytes ~/ stride;
}
