import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// A region of world space whose fragments a material discards.
///
/// The cut region is the intersection of up to [maxPlanes] open half-spaces:
/// a world point `p` is inside when `dot(plane, vec4(p, 1)) > 0` for every
/// plane of [planes]. A single plane clips a half-space; six planes bound a
/// box. The [keep] planes, up to [maxKeepPlanes], bound the region the
/// material draws at all: a point behind any of them,
/// `dot(plane, vec4(p, 1)) < 0`, is discarded too. A volume of keep planes
/// alone draws only what lies inside them, the slab or box a section view
/// shows.
///
/// Set it on [Material.clipVolume]. The built-in lit and unlit materials,
/// every physical variant of [PhysicallyBasedMaterial] and lit `.fmat`
/// materials honor it in their color pass, and every object mask (the
/// selection outline's, `RenderPassContext.drawObjects` and
/// `Scene.probeDepthConflicts`) honors it for any material; a material
/// without one draws every fragment.
/// {@category Materials}
final class ClipVolume {
  /// A clip volume that cuts the region bounded by [planes] and keeps only
  /// the region in front of every plane of [keep], each `(a, b, c, d)` naming
  /// the half-space `a*x + b*y + c*z + d > 0`. The planes are copied.
  ///
  /// Throws an [ArgumentError] for no plane in either list, more than
  /// [maxPlanes] cut planes or more than [maxKeepPlanes] keep planes.
  ClipVolume(Iterable<Vector4> planes, {Iterable<Vector4> keep = const []})
    : planes = List.unmodifiable([for (final plane in planes) plane.clone()]),
      keep = List.unmodifiable([for (final plane in keep) plane.clone()]) {
    if (this.planes.length > maxPlanes) {
      throw ArgumentError.value(
        this.planes.length,
        'planes',
        'A clip volume takes at most $maxPlanes planes',
      );
    }
    if (this.keep.length > maxKeepPlanes) {
      throw ArgumentError.value(
        this.keep.length,
        'keep',
        'A clip volume takes at most $maxKeepPlanes keep planes',
      );
    }
    if (this.planes.isEmpty && this.keep.isEmpty) {
      throw ArgumentError.value(
        this.planes.length,
        'planes',
        'A clip volume takes a cut or a keep plane',
      );
    }
  }

  /// The most planes a clip volume cuts by, the length of the shader's
  /// `ClipInfo.planes` array.
  static const int maxPlanes = 6;

  /// The most planes a clip volume keeps by, the length of the shader's
  /// `ClipInfo.keep` array.
  static const int maxKeepPlanes = 4;

  /// The size of the std140 `ClipInfo` block.
  @internal
  static const int uniformByteSize = (maxPlanes + maxKeepPlanes) * 16;

  /// The planes bounding the cut region, in the order given; empty when the
  /// volume only keeps.
  final List<Vector4> planes;

  /// The planes bounding the kept region, in the order given; empty when the
  /// volume only cuts.
  final List<Vector4> keep;

  /// Whether [point] lies inside the cut region bounded by [planes]. A volume
  /// with no cut plane contains no point.
  bool contains(Vector3 point) =>
      planes.isNotEmpty && planes.every((plane) => _distance(plane, point) > 0);

  /// Whether a fragment at [point] is discarded: it lies behind a [keep]
  /// plane or inside the cut region.
  bool discards(Vector3 point) =>
      keep.any((plane) => _distance(plane, point) < 0) || contains(point);

  static double _distance(Vector4 plane, Vector3 point) =>
      plane.x * point.x + plane.y * point.y + plane.z * point.z + plane.w;

  /// The std140 `ClipInfo` block: the cut planes, padded up to [maxPlanes]
  /// with planes every point lies in front of, then the keep planes, padded
  /// up to [maxKeepPlanes] with zero planes, which keep every point. A volume
  /// with no cut plane writes zero cut planes, whose first one cuts nothing.
  @internal
  late final ByteData uniformBytes = () {
    final floats = Float32List(uniformByteSize ~/ 4);
    if (planes.isNotEmpty) {
      for (var index = 0; index < maxPlanes; index++) {
        if (index < planes.length) {
          planes[index].copyIntoArray(floats, index * 4);
        } else {
          floats[index * 4 + 3] = 1;
        }
      }
    }
    for (var index = 0; index < keep.length; index++) {
      keep[index].copyIntoArray(floats, (maxPlanes + index) * 4);
    }
    return ByteData.sublistView(floats);
  }();
}
