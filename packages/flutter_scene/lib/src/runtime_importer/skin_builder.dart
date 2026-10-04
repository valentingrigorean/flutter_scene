import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';
import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/importer/src/gltf/bounds_baker.dart';

import '../node.dart';
import '../skin.dart';

/// Builds an engine [Skin] from a glTF skin definition. Joints are resolved
/// against the engine's full node list, and inverse-bind matrices are read
/// from the referenced accessor.
Skin buildSkin({
  required GltfSkin gltfSkin,
  required List<GltfAccessor> accessors,
  required List<GltfBufferView> bufferViews,
  required Uint8List bufferData,
  required List<Node> engineNodes,
  required GltfCoordinatePolicy coordinatePolicy,
}) {
  final skin = Skin();

  for (final jointIndex in gltfSkin.joints) {
    if (jointIndex < 0 || jointIndex >= engineNodes.length) {
      throw FormatException('glTF skin joint index $jointIndex out of range');
    }
    final node = engineNodes[jointIndex];
    node.isJoint = true;
    skin.joints.add(node);
  }

  if (gltfSkin.inverseBindMatrices != null) {
    final accessor = accessors[gltfSkin.inverseBindMatrices!];
    if (accessor.type != GltfAccessorType.mat4) {
      throw FormatException(
        'glTF skin inverseBindMatrices accessor must be MAT4, '
        'got ${accessor.type}',
      );
    }
    final floats = coordinatePolicy.convertMatrices(
      readAccessorAsFloat32(accessor, bufferViews, bufferData),
    );
    if (floats.length != gltfSkin.joints.length * 16) {
      throw FormatException(
        'glTF skin has ${gltfSkin.joints.length} joints but the inverse-bind '
        'matrices accessor only provides ${floats.length ~/ 16}',
      );
    }
    for (int i = 0; i < gltfSkin.joints.length; i++) {
      // Matrix4.fromFloat32List expects a 16-float column-major buffer; glTF
      // stores matrices in column-major order, so this is a direct copy.
      skin.inverseBindMatrices.add(
        Matrix4.fromFloat32List(
          Float32List.fromList(floats.sublist(i * 16, i * 16 + 16)),
        ),
      );
    }
  } else {
    // Spec default: identity matrices.
    for (int i = 0; i < gltfSkin.joints.length; i++) {
      skin.inverseBindMatrices.add(Matrix4.identity());
    }
  }

  return skin;
}

/// The bounds of each skinned node's triangle primitives across the poses its
/// skin takes: the rest pose, with no animation applied, and each keyframe of
/// each animation, posed by that animation's channels alone.
///
/// The poses place the vertices in the space of the skeleton's parent (the
/// first ancestor of its joints that is no joint), ignoring the skinned
/// node's own transform as glTF requires, while culling places the bounds
/// through that node; so each box moves by the skeleton parent's rest
/// transform and then by the inverse of the node's. A node whose rest
/// transform does not invert, or whose joints hang under different parents,
/// carries no bounds.
///
/// Keyed by glTF node index, with one entry per triangle-mode primitive in
/// source order. An entry is null for a primitive with morph targets, whose
/// deltas the poses leave out, or whose union came up empty; such a primitive
/// carries no bounds and is never culled.
///
/// The union holds the vertices only where the skinned node and the skeleton
/// parent keep their rest transforms and a clip plays alone, at its keyframes.
/// An app widens a primitive's bounds, or clears them with
/// `Geometry.setLocalBounds(null, null)` so it is never culled, when:
///
/// * the skinned node hangs under an animated joint, or a channel or the app
///   moves only the skinned node or only the skeleton;
/// * a rotation interpolates between sparse keyframes, whose slerp arc can
///   reach past every keyframe;
/// * two clips crossfade, or code poses a joint.
Map<int, List<Aabb3?>> skinnedPoseBounds(
  GltfDocument doc,
  Uint8List bufferData,
) {
  final unions = bakeSkinnedPoseUnionAabbs(doc, bufferData);
  final parents = List<int>.filled(doc.nodes.length, -1);
  for (var parent = 0; parent < doc.nodes.length; parent++) {
    for (final child in doc.nodes[parent].children) {
      if (child >= 0 && child < parents.length) parents[child] = parent;
    }
  }
  Matrix4 restOf(int node) {
    final rest = Matrix4.identity();
    final seen = <int>{};
    for (var at = node; at >= 0 && seen.add(at); at = parents[at]) {
      final gltf = doc.nodes[at];
      rest.setFrom(
        (gltf.matrix?.clone() ??
                Matrix4.compose(
                  gltf.translation ?? Vector3.zero(),
                  gltf.rotation ?? Quaternion.identity(),
                  gltf.scale ?? Vector3.all(1),
                ))
            .multiplied(rest),
      );
    }
    return rest;
  }

  int? skeletonParentOf(int skin) {
    final joints = doc.skins[skin].joints.toSet();
    int? shared;
    for (final joint in joints) {
      var at = joint;
      final seen = <int>{};
      while (at >= 0 && joints.contains(at) && seen.add(at)) {
        at = parents[at];
      }
      if (shared != null && shared != at) return null;
      shared = at;
    }
    return shared;
  }

  List<Aabb3?> boundsOf(int node, List<AabbBounds?> boxes) {
    final skeleton = skeletonParentOf(doc.nodes[node].skin!);
    final inverse = restOf(node);
    final invertible = skeleton != null && inverse.invert() != 0;
    if (invertible && skeleton >= 0) inverse.multiply(restOf(skeleton));
    return [
      for (final (index, primitive)
          in doc.meshes[doc.nodes[node].mesh!].primitives
              .where((primitive) => primitive.mode == 4)
              .indexed)
        switch (boxes[index]) {
          final box?
              when invertible && !box.isEmpty && primitive.targets.isEmpty =>
            Aabb3.minMax(
              Vector3(box.minX, box.minY, box.minZ),
              Vector3(box.maxX, box.maxY, box.maxZ),
            )..transform(inverse),
          _ => null,
        },
    ];
  }

  return {
    for (final MapEntry(key: node, value: boxes) in unions.entries)
      node: boundsOf(node, boxes),
  };
}
