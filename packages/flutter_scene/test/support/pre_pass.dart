import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/render/render_scene.dart';

/// Runs the scene pre-pass of the render scene [node] is mounted in, mounting
/// its tree into a bare one first when it is in none.
void runPrePass(Node node, double deltaSeconds) {
  var top = node;
  while (top.parent != null) {
    top = top.parent!;
  }
  if (top.internalRenderScene == null) top.debugMountInto(RenderScene());
  top.internalRenderScene!.runPrePass(deltaSeconds);
}
