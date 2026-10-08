import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// The seconds the vertex stage animates from: a spin's angle and a joint
/// palette's row are functions of this alone, so a frame that only advances
/// it writes no transform and no texture.
///
/// The scene states it before it draws (see `Scene.animationTime`).
@internal
double currentAnimationTime = 0.0;

/// The span the time handed to a shader is folded into, so a product with a
/// rate keeps its fraction in single precision however long the scene runs.
/// What the whole spans before it add up to goes into the phase, in double
/// precision, when the uniform is written.
@internal
const double kAnimationTimeFold = 64.0;

/// The part of [time] a shader multiplies by a rate, in
/// `[0, kAnimationTimeFold)`.
@internal
double foldedAnimationTime(double time) =>
    time - (time / kAnimationTimeFold).floorToDouble() * kAnimationTimeFold;

/// One turn about a line at a steady rate.
///
/// At a time of `t` seconds the turn is a rotation about [axis] through
/// [pivot] by `phase + turnsPerSecond * t` whole turns.
/// {@category Scene graph}
final class SpinTurn {
  /// Creates a turn about the line through [pivot] along [axis].
  SpinTurn({
    required Vector3 axis,
    Vector3? pivot,
    required this.turnsPerSecond,
    this.phase = 0.0,
  }) : axis = axis.normalized(),
       pivot = pivot ?? Vector3.zero();

  /// The unit direction of the line.
  final Vector3 axis;

  /// A point of the line.
  final Vector3 pivot;

  /// Whole turns per second, counter-clockwise seen against [axis].
  final double turnsPerSecond;

  /// The turns at a time of zero.
  final double phase;

  /// The turns at [time] seconds, in `[0, 1)`.
  double turnsAt(double time) {
    final turns = phase + turnsPerSecond * time;
    return turns - turns.floorToDouble();
  }

  /// The transform of the turn at [time] seconds.
  Matrix4 transformAt(double time) => Matrix4.translation(pivot)
    ..rotate(axis, turnsAt(time) * 2 * math.pi)
    ..translateByVector3(-pivot);
}

/// The turns the vertex stage applies to a mesh from the scene's animation
/// time, so a part that spins changes no transform between frames.
///
/// A vertex goes into [space], takes [turns] from the last to the first, and
/// leaves [space] again before the transform of its draw: a node's world
/// transform, or the row record of an instanced mesh, whose vertex first
/// takes `InstancedMesh.instanceLocal`.
///
/// Read by the unskinned vertex stage of the color, depth and shadow passes.
/// {@category Scene graph}
final class VertexSpin {
  /// Creates the spin of one mesh from one or two [turns], the outermost
  /// first.
  VertexSpin(List<SpinTurn> turns, {Matrix4? space})
    : assert(turns.isNotEmpty && turns.length <= maxTurns),
      turns = List.unmodifiable(turns),
      space = space?.clone(),
      spaceInverse = space == null ? null : Matrix4.inverted(space);

  /// The most turns one mesh takes.
  static const int maxTurns = 2;

  /// The turns, the outermost first: the last one is applied to a vertex
  /// first, and each one before it carries the line of the next.
  final List<SpinTurn> turns;

  /// The transform from the mesh to the space the lines of [turns] are
  /// stated in, or null when the mesh is already there.
  final Matrix4? space;

  /// The inverse of [space].
  final Matrix4? spaceInverse;

  /// The floats [writeTo] writes.
  static const int floatCount = 36;

  static final Matrix4 _identity = Matrix4.identity();

  /// Writes the spin at [time] seconds into [target] at [offset]: the
  /// transform out of [space], then per turn the axis with its rate and the
  /// pivot with its phase, then the folded time and the turn count.
  void writeTo(Float32List target, int offset, double time) {
    final folded = foldedAnimationTime(time);
    final whole = time - folded;
    target.setAll(offset, (spaceInverse ?? _identity).storage);
    for (var index = 0; index < maxTurns; index++) {
      final at = offset + 16 + index * 8;
      if (index >= turns.length) {
        target.fillRange(at, at + 8, 0.0);
        continue;
      }
      final turn = turns[index];
      final base = turn.phase + turn.turnsPerSecond * whole;
      target
        ..[at] = turn.axis.x
        ..[at + 1] = turn.axis.y
        ..[at + 2] = turn.axis.z
        ..[at + 3] = turn.turnsPerSecond
        ..[at + 4] = turn.pivot.x
        ..[at + 5] = turn.pivot.y
        ..[at + 6] = turn.pivot.z
        ..[at + 7] = base - base.floorToDouble();
    }
    target
      ..[offset + 32] = folded
      ..[offset + 33] = turns.length.toDouble()
      ..[offset + 34] = 0.0
      ..[offset + 35] = 0.0;
  }

  /// Writes no spin into [target] at [offset].
  static void writeNone(Float32List target, int offset) {
    target
      ..setAll(offset, _identity.storage)
      ..fillRange(offset + 16, offset + floatCount, 0.0);
  }

  /// The transform a vertex of the mesh takes at [time] seconds before the
  /// transform of its draw: what the vertex stage computes.
  Matrix4 transformAt(double time) {
    final result = spaceInverse?.clone() ?? Matrix4.identity();
    for (final turn in turns) {
      result.multiply(turn.transformAt(time));
    }
    final space = this.space;
    if (space != null) result.multiply(space);
    return result;
  }

  /// A box that holds [bounds] at every time, in the space [bounds] is in.
  Aabb3 cover(Aabb3 bounds) {
    final box = Aabb3.copy(bounds);
    final space = this.space;
    if (space != null) box.transform(space);
    // The innermost turn sweeps the box inside a sphere about its pivot, and
    // each turn before it sweeps that sphere inside one about its own.
    var center = turns.last.pivot;
    var radius = 0.0;
    final corner = Vector3.zero();
    for (var index = 0; index < 8; index++) {
      corner.setValues(
        index & 1 == 0 ? box.min.x : box.max.x,
        index & 2 == 0 ? box.min.y : box.max.y,
        index & 4 == 0 ? box.min.z : box.max.z,
      );
      radius = math.max(radius, corner.distanceTo(center));
    }
    for (var index = turns.length - 2; index >= 0; index--) {
      radius += turns[index].pivot.distanceTo(center);
      center = turns[index].pivot;
    }
    final swept = Aabb3.minMax(
      center - Vector3.all(radius),
      center + Vector3.all(radius),
    );
    final back = spaceInverse;
    if (back != null) swept.transform(back);
    return swept;
  }
}

/// The spin the unskinned vertex stage applies to the draws bound next, or
/// null for none.
@internal
VertexSpin? currentDrawSpin;
