// A scene draws from a point that moves with the camera. An anchored node
// states its place from a point of its own, so a move of the draw origin
// writes no node transform, bound or cached shadow tile: each draw and each
// cull subtracts the origin.

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart';
import 'package:flutter_scene/src/render/bvh.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/shadow_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubGeometry extends Geometry {
  _StubGeometry() {
    final aabb = Aabb3.minMax(Vector3.all(-1), Vector3.all(1));
    setLocalBounds(aabb, Sphere.centerRadius(Vector3.zero(), 2));
  }

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Matrix4 modelTransform,
    Matrix4 cameraTransform,
    Vector3 cameraPosition, {
    gpu.Shader? shaderOverride,
    double depthBias = 0.0,
  }) {
    throw UnsupportedError('Stub geometry is not renderable');
  }
}

class _StubMaterial extends Material {
  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    throw UnsupportedError('Stub material is not renderable');
  }
}

Node _meshNode() => Node(mesh: Mesh(_StubGeometry(), _StubMaterial()));

// A box of ten units a side around the draw origin.
final Frustum _around = Frustum.matrix(
  makeOrthographicMatrix(-5, 5, -5, 5, -50, 50),
);

void main() {
  late RenderScene scene;
  late Node near;
  late Node far;
  late Node unanchored;

  RenderItem itemOf(Node node) =>
      scene.items.firstWhere((item) => item.sourceNode == node);

  Set<Node> seen() {
    scene.rebuildIfDirty();
    final nodes = <Node>{};
    scene.cull(_around, (item) => nodes.add(item.sourceNode! as Node));
    return nodes;
  }

  int visited() {
    final before = activeRenderCounters.prePassNodes;
    scene.runPrePass(1 / 60);
    return activeRenderCounters.prePassNodes - before;
  }

  setUp(() {
    scene = RenderScene();
    final root = Node()..debugMountInto(scene);
    near = _meshNode()
      ..localTransform = Matrix4.translation(Vector3(1, 0, 0))
      ..setAnchor(6371.123456789, 0.5, -1234.56789);
    far = _meshNode()..setAnchor(-6371, 0, 0);
    unanchored = _meshNode()
      ..localTransform = Matrix4.translation(Vector3(2, 0, 0));
    root
      ..add(near)
      ..add(far)
      ..add(unanchored);
    // More nodes than one leaf, so a cull walks a tree.
    for (var index = 0; index < 40; index++) {
      root.add(_meshNode()..setAnchor(index * 100.0, 3000, 0));
    }
  });

  test('an anchored node draws at its transform plus its anchor minus the '
      'draw origin, in 64-bit floats', () {
    scene.drawOrigin.moveTo(6371, 0, -1234);
    visited();
    final item = itemOf(near);
    expect(item.worldTransform.getTranslation(), Vector3(1, 0, 0));
    final drawn = item.drawTransform.getTranslation();
    expect(drawn.x, closeTo(1.123456789, 1e-7));
    expect(drawn.y, closeTo(0.5, 1e-7));
    expect(drawn.z, closeTo(-0.56789, 1e-7));
    expect(item.worldBounds!.min.x, closeTo(0.123456789, 1e-7));
    expect(item.worldBounds!.max.z, closeTo(0.43211, 1e-7));
    expect(itemOf(unanchored).drawTransform.getTranslation(), Vector3(2, 0, 0));
  });

  test('a move of the draw origin visits no node, writes no transform and '
      'sorts no tree, and each cull reads the new origin', () {
    scene.drawOrigin.moveTo(6371, 0, -1234);
    visited();
    expect(seen(), {near, unanchored});
    final builds = Bvh.debugBuildCount;
    final revisions = [for (final item in scene.items) item.worldTransformRevision];
    final transforms = [
      for (final item in scene.items) item.worldTransform.clone(),
    ];

    for (final origin in [
      (6371.1, 0.4, -1234.5),
      (6374.0, 2.0, -1232.0),
      (6471.0, 0.0, -1234.0),
      (-6371.0, 0.0, 0.0),
      (6371.0, 0.0, -1234.0),
    ]) {
      scene.drawOrigin.moveTo(origin.$1, origin.$2, origin.$3);
      expect(visited(), 0);
      final nodes = seen();
      // A node with no anchor is stated from the draw origin itself.
      expect(nodes.contains(unanchored), isTrue);
      expect(nodes.contains(near), origin.$1 < 6400 && origin.$1 > 0);
      expect(nodes.contains(far), origin.$1 < 0);
    }
    expect(Bvh.debugBuildCount, builds);
    expect([
      for (final item in scene.items) item.worldTransformRevision,
    ], revisions);
    expect([
      for (final item in scene.items) item.worldTransform,
    ], transforms);
  });

  test('a node that takes another anchor moves in the tree', () {
    scene.drawOrigin.moveTo(6371, 0, -1234);
    visited();
    expect(seen(), {near, unanchored});
    far.setAnchor(6372, 1, -1235);
    expect(visited(), 1);
    expect(seen(), {near, far, unanchored});
    near.setAnchor(null);
    expect(visited(), 1);
    expect(seen(), {near, far, unanchored});
    near.setAnchor(0, 0, 0);
    expect(visited(), 1);
    expect(seen(), {far, unanchored});
  });

  test('a cached directional shadow tile holds through a move of the draw '
      'origin: its matrix takes the move', () {
    final light = DirectionalLight()
      ..direction = Vector3(0.3, -1.0, 0.2).normalized()
      ..shadowMapResolution = 512;
    final cache = DirectionalShadowCache();
    ShadowCachePlan plan(Vector3 center, List<double> origin) => cache.plan(
      light: light,
      lightDirection: light.direction,
      idealCascades: [
        ShadowCascade(
          lightSpaceMatrix: Matrix4.identity(),
          splitDistance: 10,
          boxSize: 12,
          center: center,
          radius: 6,
        ),
      ],
      origin: Float64List.fromList(origin),
      contentRevision: 1,
      staticSignatureIn: (_) => 1,
    );

    final first = plan(Vector3(0, 0, 5), [6371, 0, -1234]);
    expect(first.refreshes, hasLength(1));
    final entry = first.entries.single;
    // A point one unit from the first origin, and where the tile draws it.
    final drawn = entry.matrix.transformed3(Vector3(1, 0, 0));

    // The origin moves two units, so the camera's cascade and the point both
    // read two units less.
    final second = plan(Vector3(-2, 0, 5), [6373, 0, -1234]);
    expect(second.refreshes, isEmpty);
    expect(entry.center.x, closeTo(-2, 1e-6));
    final moved = entry.matrix.transformed3(Vector3(-1, 0, 0));
    expect(moved.x, closeTo(drawn.x, 1e-5));
    expect(moved.y, closeTo(drawn.y, 1e-5));
    expect(moved.z, closeTo(drawn.z, 1e-5));
  });
}
