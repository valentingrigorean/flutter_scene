import 'package:flutter_scene/src/node.dart';

/// The view-axis depth the draws of a node sort at, in place of the depth of
/// their bounds centre (see [Node.sortDepth]).
///
/// Its owner writes [depth] whenever the depth it wants changes, as often as
/// every frame; the encoder reads it at each sort. Writing it changes no
/// node, so a draw whose sort place follows the camera, as a screen-space
/// overlay placed among the translucent draws, costs the scene's pre-pass
/// nothing on a frame that only moves the camera.
///
/// {@category Rendering}
final class SortDepth {
  /// A sort depth of [depth] world units along the view axis.
  SortDepth([this.depth = 0.0]);

  /// The view-axis depth from the eye, in world units, before the node's
  /// [Node.sortDepthBias] is taken off.
  double depth;
}
