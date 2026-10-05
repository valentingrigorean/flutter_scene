import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/render_view.dart';

/// The pass of a scene's render graph a draw is recorded in.
enum ScenePipelinePass {
  /// The color pass, which shades each draw with its material.
  color,

  /// The depth prepass, which writes the opaque scene's linear depth (and
  /// normals) for the effects and materials that read it.
  depthPrepass,

  /// The shadow pass, which records each shadow caster's depth into the
  /// directional cascades and the shadow-casting spots of the view's shadow
  /// atlas.
  shadow,
}

/// A draw a render of a view would record with a render pipeline the process
/// has not built, so the frame that draws it links that pipeline first.
///
/// `Scene.unbuiltPipelines` lists them.
final class UnbuiltPipelineDraw {
  /// Creates a draw of [node] in [view]'s [pass].
  const UnbuiltPipelineDraw({
    required this.node,
    required this.view,
    required this.pass,
  });

  /// The node whose mesh, instanced mesh or level of detail draws.
  final Node node;

  /// The view the draw is culled into.
  final RenderView view;

  /// The pass that records the draw.
  final ScenePipelinePass pass;

  @override
  String toString() => 'UnbuiltPipelineDraw(${node.name}, ${pass.name})';
}
