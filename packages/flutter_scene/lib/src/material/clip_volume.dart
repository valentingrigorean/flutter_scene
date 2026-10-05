import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// A convex region of world space whose fragments a material discards.
///
/// The region is the intersection of up to [maxPlanes] open half-spaces: a
/// world point `p` is inside when `dot(plane, vec4(p, 1)) > 0` for every
/// plane. A single plane clips a half-space; six planes bound a box.
///
/// Set it on [Material.clipVolume]. The built-in lit and unlit materials,
/// every physical variant of [PhysicallyBasedMaterial] and lit `.fmat`
/// materials honor it in their color pass; a material without one draws every
/// fragment.
/// {@category Materials}
final class ClipVolume {
  /// A clip volume bounded by [planes], each `(a, b, c, d)` naming the
  /// half-space `a*x + b*y + c*z + d > 0`. The planes are copied.
  ///
  /// Throws an [ArgumentError] for no plane or more than [maxPlanes].
  ClipVolume(Iterable<Vector4> planes)
    : planes = List.unmodifiable([for (final plane in planes) plane.clone()]) {
    if (this.planes.isEmpty || this.planes.length > maxPlanes) {
      throw ArgumentError.value(
        this.planes.length,
        'planes',
        'A clip volume takes 1 to $maxPlanes planes',
      );
    }
  }

  /// The most planes a clip volume takes, the length of the shader's
  /// `ClipInfo.planes` array.
  static const int maxPlanes = 6;

  /// The bounding planes, in the order given.
  final List<Vector4> planes;

  /// Whether [point] lies inside the volume, so a fragment there is
  /// discarded.
  bool contains(Vector3 point) => planes.every(
    (plane) =>
        plane.x * point.x + plane.y * point.y + plane.z * point.z + plane.w > 0,
  );

  /// The std140 `ClipInfo` block: the planes, then planes every point lies
  /// in front of up to [maxPlanes].
  @internal
  late final ByteData uniformBytes = () {
    final floats = Float32List(maxPlanes * 4);
    for (var index = 0; index < maxPlanes; index++) {
      if (index < planes.length) {
        planes[index].copyIntoArray(floats, index * 4);
      } else {
        floats[index * 4 + 3] = 1;
      }
    }
    return ByteData.sublistView(floats);
  }();
}
