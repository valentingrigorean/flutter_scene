import 'dart:typed_data';

/// The parts of a kept indexed draw that a pass culls one by one: ranges of
/// its indices, each with bounds.
///
/// A pass draws the parts its clip reaches, consecutive ones as one draw,
/// and none of the others, so a part out of view costs no vertex work.
final class ItemParts {
  /// Parts at [ranges] of the draw's indices, culled by [bounds].
  ItemParts({required this.ranges, required this.bounds})
    : assert(ranges.length.isEven && bounds.length == ranges.length * 3);

  /// Each part's first index and index count, from the first index of the
  /// draw, in ascending order and within the draw's indices.
  final Int32List ranges;

  /// Each part's min x, y, z and max x, y, z in the space a draw's clip
  /// matrix maps, six floats per part.
  final Float32List bounds;

  /// The number of parts.
  int get count => ranges.length ~/ 2;
}
