import 'package:meta/meta.dart';

int _sceneDrawRevision = 0;

/// The number of changes in this process to what a scene draws, or to the
/// pipelines it draws with, that add or remove no render item: a node's
/// `visible`, `layers`, `shadowCastingMode` or `lightChannelMask`, a mesh
/// primitive's `visible`, `material` or `castsShadow`, or an unlit material's
/// `alphaMode`, each set to a different value; a material a `MeshComponent`'s
/// new mesh swaps in over the same geometry; a physically based material
/// whose opacity, alpha masking or shader variant changes; and a cached
/// pipeline dropped by a shader reload or a draw the backend refused.
///
/// A query of `Scene.unbuiltPipelines` reads the render items that draw, so a
/// node hidden at the query and shown in place later was not checked. While
/// this count, the render scene's structure revision and the lighting hold,
/// the scene draws the items and materials an earlier query read, with the
/// pipelines that query found built.
/// {@category Assets and loading}
int get sceneDrawRevision => _sceneDrawRevision;

@internal
void markSceneDrawChanged() => _sceneDrawRevision++;
