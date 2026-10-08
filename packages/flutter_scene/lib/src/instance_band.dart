import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

/// The rows of an instanced mesh a draw keeps, tested per row in the vertex
/// stage of the color, depth and shadow passes.
///
/// A row is one instance record under its node. Its center is [center] under
/// that transform, its radius [radius] times the transform's largest axis
/// scale, and its eye distance the distance from the view's camera to the
/// center. A shadow pass reads the camera of the primary view. The row draws
/// when every test below holds; a row that fails collapses to no fragment.
///
/// Each edge of the two distance tests is scaled by
/// `1 + margin * (h - 0.5)`, where `h` is a hash of the record's translation
/// in `[0, 1)`. Two draws over the same rows that share an edge therefore
/// agree on every row, so a row draws in exactly one of them, and rows cross
/// an edge one by one over the margin instead of together. The hash reads no
/// frame state, so a still camera draws a still pattern.
final class InstanceBand {
  InstanceBand({
    Vector3? center,
    this.radius = 1.0,
    this.nearReach = 0.0,
    this.farReach = double.infinity,
    this.nearDistance = 0.0,
    this.farDistance = double.infinity,
    this.margin = 0.0,
    this.keep = 1.0,
  }) : center = center ?? Vector3.zero();

  /// The center of the bound sphere of what a row draws, in record space.
  final Vector3 center;

  /// The radius of that sphere, in record space.
  double radius;

  /// The row draws when its eye distance exceeds this many row radii.
  double nearReach;

  /// The row draws when its eye distance is at most this many row radii.
  double farReach;

  /// The row draws when its eye distance exceeds this.
  double nearDistance;

  /// The row draws when its eye distance is at most this.
  double farDistance;

  /// The width of the edge jitter as a fraction of an edge, see the class.
  double margin;

  /// The fraction of the rows drawn: a row draws when its hash is below this.
  double keep;

  static const double _unbounded = 3.0e38;

  static double _finite(double value) =>
      value.isFinite ? value : (value < 0 ? -_unbounded : _unbounded);

  /// Writes the band into [target] at [offset] as the three `vec4` the
  /// `instance_band.glsl` test reads after the eye and the view direction.
  void writeTo(Float32List target, int offset) {
    target
      ..[offset] = center.x
      ..[offset + 1] = center.y
      ..[offset + 2] = center.z
      ..[offset + 3] = radius
      ..[offset + 4] = nearReach
      ..[offset + 5] = _finite(farReach)
      ..[offset + 6] = nearDistance
      ..[offset + 7] = _finite(farDistance)
      ..[offset + 8] = margin
      ..[offset + 9] = keep;
  }

  static final Vector3 _centerScratch = Vector3.zero();
  static final Float32List _hashScratch = Float32List(5);

  /// The hash of a record whose translation is [translation], the one the
  /// vertex stage computes, in `[0, 1)`.
  static double hashOf(Vector3 translation) {
    final f = _hashScratch;
    f[0] = translation.x * 0.1031;
    f[1] = translation.y * 0.1030;
    f[2] = translation.z * 0.0973;
    f[0] = f[0] - f[0].floorToDouble();
    f[1] = f[1] - f[1].floorToDouble();
    f[2] = f[2] - f[2].floorToDouble();
    f[3] =
        f[0] * (f[1] + 33.33) + f[1] * (f[0] + 33.33) + f[2] * (f[2] + 33.33);
    f[4] = (f[0] + f[3] + f[1] + f[3]) * (f[2] + f[3]);
    return f[4] - f[4].floorToDouble();
  }

  /// Whether the row whose record under its node is [nodeRecord] draws for a
  /// camera at [eye], given the hash of the record's own translation.
  ///
  /// This is the test of the vertex stage without the view depth range, for a
  /// pick and for a test that runs without a device.
  bool holds(Matrix4 nodeRecord, Vector3 eye, {required double hash}) {
    if (hash >= keep) return false;
    final c = _centerScratch
      ..setFrom(center)
      ..applyMatrix4(nodeRecord);
    final rowRadius = radius * nodeRecord.getMaxScaleOnAxis();
    final distance = c.distanceTo(eye);
    final edge = 1.0 + margin * (hash - 0.5);
    final near = math.max(nearReach * rowRadius, nearDistance) * edge;
    final far = math.min(farReach * rowRadius, farDistance) * edge;
    return distance > near && distance <= far;
  }
}
