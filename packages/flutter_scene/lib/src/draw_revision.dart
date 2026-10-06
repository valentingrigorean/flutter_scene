import 'package:meta/meta.dart';

int _sceneDrawRevision = 0;

/// The number of changes in this process to what a scene draws that add or
/// remove no render item: a node's `visible` or `layers`, or a mesh
/// primitive's `visible` or `material`, each set to a different value.
///
/// A query of `Scene.unbuiltPipelines` reads the render items that draw, so a
/// node hidden at the query and shown in place later was not checked. While
/// this count, the render scene's structure revision and the lighting hold,
/// the scene draws the items and materials an earlier query read.
/// {@category Assets and loading}
int get sceneDrawRevision => _sceneDrawRevision;

@internal
void markSceneDrawChanged() => _sceneDrawRevision++;
