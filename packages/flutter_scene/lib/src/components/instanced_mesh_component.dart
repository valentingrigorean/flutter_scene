import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/components/component.dart';
import 'package:flutter_scene/src/light.dart' show ShadowCastingMode;
import 'package:flutter_scene/src/instanced_mesh.dart';
import 'package:flutter_scene/src/render/render_scene.dart';

/// An engine [Component] that draws an [InstancedMesh].
///
/// While the owning node is part of a live scene, this component
/// registers a single [RenderItem] for the whole instanced mesh and
/// refreshes it each frame. The render passes draw every instance from
/// that one item.
/// {@category Scene graph}
class InstancedMeshComponent extends Component {
  @override
  bool get ticks => false;

  /// Creates a component that draws [instancedMesh].
  InstancedMeshComponent(this.instancedMesh);

  /// The instanced mesh this component draws.
  final InstancedMesh instancedMesh;

  RenderItem? _renderItem;

  /// The render item this component registered, while mounted.
  @visibleForTesting
  RenderItem? get debugRenderItem => _renderItem;

  int _worldTransformVersion = -1;
  int _instanceRevision = -1;
  int _geometryBoundsVersion = -1;

  @override
  void onMount() {
    final renderScene = node.internalRenderScene;
    if (renderScene == null) return;
    final item =
        RenderItem(
            geometry: instancedMesh.geometry,
            material: instancedMesh.material,
          )
          ..sourceNode = node
          ..drawSource = instancedMesh
          ..instanceSource = instancedMesh;
    _renderItem = item;
    renderScene.add(item);
    (instancedMesh.rows ?? instancedMesh).addRowListener(
      node.internalRenderSourcesChanged,
    );
  }

  @override
  void onUnmount() {
    final item = _renderItem;
    if (item != null) {
      (instancedMesh.rows ?? instancedMesh).removeRowListener(
        node.internalRenderSourcesChanged,
      );
      node.internalRenderScene?.remove(item);
      _renderItem = null;
      _worldTransformVersion = -1;
      _instanceRevision = -1;
      _geometryBoundsVersion = -1;
    }
  }

  /// Refreshes this component's render item from the owning node's
  /// transform and cull state and the current instance list. Called once
  /// per frame by the scene pre-pass while the node is visible.
  @internal
  void refreshRenderItem() {
    final item = _renderItem;
    if (item == null) return;
    item.sharedRows = instancedMesh.rows;
    item.debugView = Node.debugViewOverrideCount == 0
        ? null
        : node.effectiveDebugView;
    // A material can declare itself draw-less for the frame (the shadow
    // catcher at zero intensity); its item then joins no pass at all.
    final visible = !item.material.drawsNothing;
    final frustumCulled = node.frustumCulled;
    final lightChannelMask = node.lightChannelMask;
    final worldTransformVersion = node.worldTransformVersion;
    final instanceRevision = instancedMesh.revision;
    final geometryBoundsVersion = instancedMesh.geometry.localBoundsVersion;
    if (node.shadowStatic &&
        worldTransformVersion == _worldTransformVersion &&
        instanceRevision == _instanceRevision &&
        geometryBoundsVersion == _geometryBoundsVersion &&
        item.visible == visible &&
        item.frustumCulled == frustumCulled &&
        item.layers == node.layers &&
        item.sortDepthBias == node.sortDepthBias &&
        item.shadowStatic == node.shadowStatic &&
        item.shadowCastingMode == node.shadowCastingMode &&
        item.shadowCasterFaces == node.shadowCasterFaces &&
        item.lightChannelMask == lightChannelMask) {
      return;
    }
    final frustumCulledChanged = item.frustumCulled != frustumCulled;
    item.frustumCulled = frustumCulled;
    item.layers = node.layers;
    item.renderOrder = node.renderOrder;
    item.sortDepthBias = node.sortDepthBias;
    final worldTransform = node.globalTransform;
    final boundsChangedByInput =
        worldTransformVersion != _worldTransformVersion ||
        instanceRevision != _instanceRevision ||
        geometryBoundsVersion != _geometryBoundsVersion;
    final staticShadowChanged =
        (item.visible != visible ||
            item.shadowStatic != node.shadowStatic ||
            item.shadowCastingMode != node.shadowCastingMode ||
            item.shadowCasterFaces != node.shadowCasterFaces ||
            item.lightChannelMask != lightChannelMask ||
            boundsChangedByInput) &&
        (item.shadowStatic || node.shadowStatic) &&
        (item.castsShadows || node.shadowCastingMode != ShadowCastingMode.off);
    item.visible = visible;
    if (worldTransformVersion != _worldTransformVersion) {
      item.worldTransform.setFrom(worldTransform);
      item.worldTransformRevision++;
    }
    final windingWas = item.windingFlipped;
    item.refreshWinding(node.windingFlipped);
    item.shadowStatic = node.shadowStatic;
    item.shadowCastingMode = node.shadowCastingMode;
    item.shadowCasterFaces = node.shadowCasterFaces;
    item.lightChannelMask = lightChannelMask;
    item.instanceTransforms = instancedMesh.instances;
    item.instanceColors = instancedMesh.colors;
    item.instanceAttributeData = instancedMesh.instanceAttributeData;
    item.instanceAttributeFloats = instancedMesh.instanceAttributeFloats;
    item.instanceWindingFlipped = instancedMesh.windingFlipped;
    final nodeSpace =
        instancedMesh.nodeSpaceInstances &&
        instancedMesh.geometry.instancedVertexLayout != null;
    final recordSpaceChanged = item.nodeSpaceInstances != nodeSpace;
    item.nodeSpaceInstances = nodeSpace;
    item.cullInstances = instancedMesh.cullInstances && !nodeSpace;
    item.sortTransparentInstances = instancedMesh.sortTransparentInstances;
    if (staticShadowChanged) {
      node.internalRenderScene?.markStaticShadowDirty();
    }
    if (instanceRevision != _instanceRevision ||
        geometryBoundsVersion != _geometryBoundsVersion) {
      item.instanceBounds = instancedMesh.aggregateBounds;
    }
    if (boundsChangedByInput || recordSpaceChanged) {
      final recordsHold =
          worldTransformVersion == _worldTransformVersion ||
          (nodeSpace && windingWas == item.windingFlipped);
      final rows =
          recordsHold &&
              !recordSpaceChanged &&
              geometryBoundsVersion == _geometryBoundsVersion
          ? instancedMesh.rowsChangedSince(_instanceRevision)
          : null;
      if (rows == null) {
        item.refreshInstanceData();
      } else if (rows.isNotEmpty) {
        item.refreshInstanceRows(rows);
      } else {
        item.instanceFrameMoved();
      }
    }

    final wasBounded = item.worldBounds != null;
    final boundsChanged = boundsChangedByInput
        ? item.refreshWorldBounds()
        : false;
    final isBounded = item.worldBounds != null;

    // A toggled cull flag or a bounded/unbounded transition changes the
    // BVH membership and needs a rebuild; a plain move only needs a
    // refit.
    final renderScene = node.internalRenderScene;
    if (frustumCulledChanged || wasBounded != isBounded) {
      renderScene?.markBvhStructureDirty();
    } else if (boundsChanged && item.frustumCulled) {
      renderScene?.markBvhBoundsDirty();
    }
    _worldTransformVersion = worldTransformVersion;
    _instanceRevision = instanceRevision;
    _geometryBoundsVersion = geometryBoundsVersion;
  }

  /// Keeps this component's render item out of the render passes. Called
  /// by the scene pre-pass while the owning node is hidden.
  @internal
  void hideRenderItem() {
    final item = _renderItem;
    if (item == null) return;
    if (item.visible && item.shadowStatic && item.castsShadows) {
      node.internalRenderScene?.markStaticShadowDirty();
    }
    item.visible = false;
  }
}
