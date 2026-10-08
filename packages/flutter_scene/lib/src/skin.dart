import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/animation.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/vertex_spin.dart';
import 'package:vector_math/vector_math.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

int _getNextPowerOfTwoSize(int x) {
  if (x == 0) {
    return 1;
  }

  --x;

  x |= x >> 1;
  x |= x >> 2;
  x |= x >> 4;
  x |= x >> 8;
  x |= x >> 16;

  return x + 1;
}

/// The edge length of the square joints texture holding [jointCount] matrices.
///
/// One matrix spans four consecutive texels, and the vertex shader reads all
/// four from the same row, so the edge must be a multiple of four; the next
/// power of two at or above 4 satisfies both that and GPU sizing.
int _jointsTextureEdge(int jointCount) {
  // 1 matrix = 16 floats, 1 texel = 4 floats, so 4 texels per joint.
  final int requiredTexels = jointCount * 4;
  return max(4, _getNextPowerOfTwoSize(sqrt(requiredTexels).ceil()));
}

/// The joint matrices of one skin over one animation, sampled at a steady
/// rate and held in one texture: a row per sampled time, four texels per
/// joint. The skinned vertex stage reads the rows either side of a clip time
/// it derives from the scene's animation time, so a model that plays the
/// animation writes no joint and no texture between frames.
///
/// The matrices are relative to the node the animation was baked under, so
/// every clone of that subtree draws from the same palette under its own
/// root (see [Skin.play]).
/// {@category Geometry}
final class JointPalette {
  /// Creates a palette of [rowCount] rows of [jointCount] matrices from
  /// [matrices], sixteen floats per joint, row after row.
  JointPalette({
    required this.jointCount,
    required this.rowCount,
    required this.rowsPerSecond,
    required this.matrices,
  }) : assert(matrices.length == jointCount * rowCount * 16);

  /// Bakes [animation] for [skin] under [root], a subtree that holds every
  /// joint of the skin and every node the animation moves.
  ///
  /// The subtree is posed at each sampled time and left at the pose it had.
  /// The rows span the animation's whole length at [rowsPerSecond], fewer
  /// when that would exceed [maxRows].
  factory JointPalette.bake(
    Node root,
    Animation animation,
    Skin skin, {
    double rowsPerSecond = 30.0,
    int maxRows = 2048,
  }) {
    final duration = animation.endTime;
    var rowCount = duration <= 0 ? 1 : (duration * rowsPerSecond).ceil() + 1;
    if (rowCount > maxRows) rowCount = maxRows;
    final rate = rowCount <= 1 ? rowsPerSecond : (rowCount - 1) / duration;
    final jointCount = skin.joints.length;
    final matrices = Float32List(rowCount * jointCount * 16);
    final moved = <Node, Matrix4>{};
    final movedTrs = <Node, DecomposedTransform>{};
    for (final channel in animation.channels) {
      final target = resolveAnimationTarget(root, channel.bindTarget.nodeName);
      if (target == null) continue;
      moved[target] = target.localTransform.clone();
      final trs = target.localTransformTrs;
      if (trs != null) movedTrs[target] = trs.clone();
    }
    final player = AnimationPlayer();
    final clip = player.createAnimationClip(animation, root);
    final toRoot = Matrix4.zero();
    for (var row = 0; row < rowCount; row++) {
      clip.seek(rowCount <= 1 ? 0.0 : row / rate);
      player.update(0);
      toRoot.copyInverse(root.globalTransform);
      for (var joint = 0; joint < jointCount; joint++) {
        final node = skin.joints[joint];
        final at = (row * jointCount + joint) * 16;
        if (node == null) {
          matrices
            ..[at] = 1.0
            ..[at + 5] = 1.0
            ..[at + 10] = 1.0
            ..[at + 15] = 1.0;
          continue;
        }
        final matrix = toRoot.multiplied(node.globalTransform)
          ..multiply(skin.inverseBindMatrices[joint]);
        matrices.setRange(at, at + 16, matrix.storage);
      }
    }
    for (final MapEntry(key: node, value: rest) in moved.entries) {
      final trs = movedTrs[node];
      if (trs == null) {
        node.localTransform = rest;
      } else {
        node.setLocalTransformTrs(trs);
      }
    }
    return JointPalette(
      jointCount: jointCount,
      rowCount: rowCount,
      rowsPerSecond: rate,
      matrices: matrices,
    );
  }

  /// Whether a palette holds everything [animation] moves under [root]: no
  /// channel drives morph weights, and no mesh under a node it moves draws
  /// without a skin. An animation that turns a rigid part needs its nodes
  /// posed and is not covered.
  static bool covers(Node root, Animation animation) {
    bool rigid(Node node) {
      if (node.mesh != null && node.skin == null) return true;
      return node.children.any(rigid);
    }

    for (final channel in animation.channels) {
      if (channel.bindTarget.property == AnimationProperty.weights) {
        return false;
      }
      final target = resolveAnimationTarget(root, channel.bindTarget.nodeName);
      if (target != null && rigid(target)) return false;
    }
    return true;
  }

  /// The joints of a row.
  final int jointCount;

  /// The sampled times.
  final int rowCount;

  /// The rows per second of clip time.
  final double rowsPerSecond;

  /// The matrices, sixteen floats per joint, row after row.
  final Float32List matrices;

  /// The clip seconds the rows span.
  double get duration => rowCount <= 1 ? 0.0 : (rowCount - 1) / rowsPerSecond;

  /// The texels across the texture: four per joint.
  int get width => max(4, jointCount * 4);

  /// The palette textures created since the process started.
  @visibleForTesting
  static int debugUploads = 0;

  gpu.Texture? _texture;

  /// The texture, created and written on first use.
  gpu.Texture get texture => _texture ??= () {
    debugUploads++;
    final texture = gpu.gpuContext.createTexture(
      gpu.StorageMode.hostVisible,
      width,
      rowCount,
      format: gpu.PixelFormat.r32g32b32a32Float,
    );
    final texels = jointCount == 0
        ? Float32List(width * rowCount * 4)
        : matrices;
    texture.overwrite(texels.buffer.asByteData(texels.offsetInBytes));
    return texture;
  }();

  /// The matrix of [joint] at [clipSeconds], as the vertex stage blends it.
  Matrix4 matrixAt(int joint, double clipSeconds) {
    final row = clipSeconds.clamp(0.0, duration) * rowsPerSecond;
    final from = min(row.floor(), rowCount - 1);
    final to = min(from + 1, rowCount - 1);
    final blend = row - from;
    final result = Matrix4.zero();
    for (var index = 0; index < 16; index++) {
      final a = matrices[(from * jointCount + joint) * 16 + index];
      final b = matrices[(to * jointCount + joint) * 16 + index];
      result.storage[index] = a + (b - a) * blend;
    }
    return result;
  }
}

/// Where a skin reads a [JointPalette]: the clip time is
/// `offset + speed * t` at an animation time of `t` seconds, wrapped into
/// the palette's length when [loop] holds and held at its ends otherwise.
/// {@category Geometry}
final class JointPalettePlayback {
  /// Creates the playback of [palette] under [root].
  JointPalettePlayback(
    this.palette, {
    required this.root,
    this.offset = 0.0,
    this.speed = 1.0,
    this.loop = true,
  });

  /// The palette read.
  final JointPalette palette;

  /// The node the palette's matrices are relative to: an ancestor of the
  /// skinned mesh, the counterpart of the node the palette was baked under.
  final Node root;

  /// The clip seconds at an animation time of zero.
  final double offset;

  /// The clip seconds per second of animation time; zero holds a pose.
  final double speed;

  /// Whether the clip time wraps.
  final bool loop;

  /// The clip seconds at [time] seconds of animation time.
  double clipSecondsAt(double time) {
    final duration = palette.duration;
    final clip = offset + speed * time;
    if (duration <= 0) return 0.0;
    if (!loop) return clip.clamp(0.0, duration);
    return clip - (clip / duration).floorToDouble() * duration;
  }

  /// Writes the two `vec4` the skinned vertex stage reads after its palette
  /// size into [target] at [offset]: the clip seconds at the start of the
  /// folded time, the speed, the length and the loop flag, then the folded
  /// time.
  void writeTo(Float32List target, int offset, double time) {
    final folded = foldedAnimationTime(time);
    final duration = palette.duration;
    var base = this.offset + speed * (time - folded);
    if (loop && duration > 0) {
      base -= (base / duration).floorToDouble() * duration;
    } else {
      // Past either end by more than a fold reads the same end pose.
      final reach = duration + speed.abs() * kAnimationTimeFold;
      base = base.clamp(-reach, reach);
    }
    target
      ..[offset] = base
      ..[offset + 1] = speed
      ..[offset + 2] = duration
      ..[offset + 3] = loop ? 1.0 : 0.0
      ..[offset + 4] = folded
      ..[offset + 5] = 0.0
      ..[offset + 6] = 0.0
      ..[offset + 7] = 0.0;
  }
}

/// A skeletal binding used by skinned meshes for animation.
///
/// A `Skin` pairs an ordered list of [joints] (scene-graph [Node]s acting as
/// bones) with the [inverseBindMatrices] that transform a mesh from model
/// space into each joint's rest-pose local space. The vertex shader
/// combines these with the joints' current transforms to deform the mesh.
///
/// `Skin` instances are usually populated by an importer rather than
/// constructed directly. They are attached to the mesh-bearing [Node] via
/// [Node.skin].
/// {@category Geometry}
base class Skin {
  /// The bone nodes referenced by this skin, in shader-binding order.
  ///
  /// Entries may be `null` when [Node.clone] is unable to relocate a joint
  /// in the cloned subtree; the renderer treats null joints as identity
  /// transforms.
  final List<Node?> joints = [];

  /// The inverse bind matrix for each joint, transforming a vertex from
  /// model space into the joint's rest-pose local space.
  ///
  /// Parallel to [joints]: `inverseBindMatrices[i]` corresponds to
  /// `joints[i]`.
  final List<Matrix4> inverseBindMatrices = [];

  /// Ring of joints textures reused across frames by [getJointsTexture].
  ///
  /// Each frame writes the next slot so the GPU is never handed a texture
  /// it may still be sampling from a recent frame. The ring is allocated
  /// lazily and dropped if the joint count (and therefore the texture
  /// size) ever changes.
  static const int _jointsTextureRingSize = 3;
  final List<gpu.Texture?> _jointsTextureRing = List<gpu.Texture?>.filled(
    _jointsTextureRingSize,
    null,
  );
  int _jointsTextureRingCursor = 0;
  int _jointsTextureDimension = 0;

  /// The palette this skin draws from, or null when it draws the pose of its
  /// [joints]. Set by [play].
  JointPalettePlayback? get playback => _playback;
  JointPalettePlayback? _playback;

  /// Draws this skin from [playback] in place of the pose of its [joints],
  /// or from the joints again with null. Nothing is uploaded per frame while
  /// a playback holds.
  void play(JointPalettePlayback? playback) {
    assert(
      playback == null || playback.palette.jointCount == joints.length,
      'The palette was baked for another skin.',
    );
    _playback = playback;
  }

  /// Changes whenever the world transform of a joint is recomputed, so a
  /// pose that stands uploads nothing.
  @internal
  int get poseVersion {
    var version = 0;
    for (final joint in joints) {
      if (joint != null) version += joint.worldTransformVersion;
    }
    return version;
  }

  /// The joints textures [getJointsTexture] wrote since the process started.
  @visibleForTesting
  static int debugUploads = 0;

  /// Computes the joint matrices for the current frame and uploads them as
  /// a square `RGBA32F` GPU texture.
  ///
  /// Each joint occupies four texels (one matrix). The texture's edge
  /// length is rounded up to the next power of two, with a floor of four so
  /// a matrix never straddles a row; unused slots are initialized to identity.
  ///
  /// The companion [getTextureWidth] returns the same edge length so the
  /// vertex shader can index into the texture.
  gpu.Texture getJointsTexture() {
    final int dimensionSize = _jointsTextureEdge(joints.length);

    // Drop the ring if the texture size changed (joint count is fixed
    // after construction, so this normally never triggers).
    if (dimensionSize != _jointsTextureDimension) {
      _jointsTextureRing.fillRange(0, _jointsTextureRing.length, null);
      _jointsTextureDimension = dimensionSize;
    }

    // Advance to the next ring slot, allocating it on first use.
    _jointsTextureRingCursor =
        (_jointsTextureRingCursor + 1) % _jointsTextureRingSize;
    final gpu.Texture texture = _jointsTextureRing[_jointsTextureRingCursor] ??=
        gpu.gpuContext.createTexture(
          gpu.StorageMode.hostVisible,
          dimensionSize,
          dimensionSize,
          format: gpu.PixelFormat.r32g32b32a32Float,
        );
    // 64 bytes per matrix. 4 bytes per pixel.
    Float32List jointMatrixFloats = Float32List(
      dimensionSize * dimensionSize * 4,
    );
    // Initialize with identity matrices.
    for (int i = 0; i < jointMatrixFloats.length; i += 16) {
      jointMatrixFloats[i] = 1.0;
      jointMatrixFloats[i + 5] = 1.0;
      jointMatrixFloats[i + 10] = 1.0;
      jointMatrixFloats[i + 15] = 1.0;
    }

    for (int jointIndex = 0; jointIndex < joints.length; jointIndex++) {
      final Node? joint = joints[jointIndex];
      // A null joint (Node.clone couldn't relocate it) keeps the
      // pre-initialized identity slot.
      if (joint == null) continue;

      // glTF skinning: the joint matrix is the joint's full global
      // transform times its inverse bind matrix. globalTransform walks
      // every ancestor, so transforms on non-joint nodes between the
      // joints and the scene root (e.g. a skeleton root carrying the
      // model's Z-up-to-Y-up correction) are included, as is the
      // scene-root flip. The inverse bind matrix takes a vertex from
      // model space into the joint's rest-pose space; the global
      // transform then places it by the joint's current pose.
      //
      // The shader applies this matrix directly, so the mesh node's own
      // transform must not be applied again -- SkinnedGeometry.bind
      // passes an identity model transform.
      final Matrix4 matrix =
          joint.globalTransform * inverseBindMatrices[jointIndex];
      final floatOffset = jointIndex * 16;
      jointMatrixFloats.setRange(floatOffset, floatOffset + 16, matrix.storage);
    }

    texture.overwrite(jointMatrixFloats.buffer.asByteData());
    debugUploads++;
    return texture;
  }

  /// The edge length, in texels, of the joints texture produced by
  /// [getJointsTexture].
  int getTextureWidth() => _jointsTextureEdge(joints.length);

  /// The previous frame's joints texture from the ring, or the current texture
  /// on the first frame.
  gpu.Texture getPreviousJointsTexture() {
    final prevSlot =
        (_jointsTextureRingCursor - 1 + _jointsTextureRingSize) %
        _jointsTextureRingSize;
    return _jointsTextureRing[prevSlot] ??
        _jointsTextureRing[_jointsTextureRingCursor]!;
  }
}
