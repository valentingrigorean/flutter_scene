// BVH tests. Builds a Bvh over RenderItems with stub geometry/material
// and checks that query agrees with a brute-force frustum test.

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/render/bvh.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubGeometry extends Geometry {
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

class _InputMaterial extends _StubMaterial {
  _InputMaterial(this.inputs);

  final Set<RenderInput> inputs;

  @override
  Set<RenderInput> get sceneInputs => inputs;
}

RenderItem _renderItem() =>
    RenderItem(geometry: _StubGeometry(), material: _StubMaterial());

/// A render item with a unit world AABB centered at `(x, 0, 0)`.
RenderItem _itemAt(double x) {
  return _renderItem()
    ..worldBounds = Aabb3.minMax(
      Vector3(x - 0.5, -0.5, -0.5),
      Vector3(x + 0.5, 0.5, 0.5),
    );
}

void main() {
  group('Bvh', () {
    test('an empty BVH yields nothing', () {
      final hits = <RenderItem>[];
      Bvh.build([]).query(Frustum.matrix(Matrix4.identity()), hits.add);
      expect(hits, isEmpty);
    });

    test('a single-item BVH yields that item when it intersects', () {
      final item = _itemAt(0);
      final hits = <RenderItem>[];
      Bvh.build([item]).query(
        Frustum.matrix(makeOrthographicMatrix(-5, 5, -5, 5, -5, 5)),
        hits.add,
      );
      expect(hits, [item]);
    });

    test('query agrees with a brute-force frustum test', () {
      final items = [for (int i = 0; i < 8; i++) _itemAt(i * 4.0)];
      final bvh = Bvh.build(items);
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(-2, 14, -10, 10, -100, 100),
      );

      final expected = items
          .where((i) => frustum.intersectsWithAabb3(i.worldBounds!))
          .toSet();
      // The frustum must select a proper, non-empty subset, or the test
      // proves nothing.
      expect(expected, isNotEmpty);
      expect(expected.length, lessThan(items.length));

      final hits = <RenderItem>{};
      bvh.query(frustum, hits.add);
      expect(hits, expected);
    });

    test('a frustum containing every item returns them all', () {
      final items = [for (int i = 0; i < 8; i++) _itemAt(i * 4.0)];
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(-1000, 1000, -1000, 1000, -1000, 1000),
      );
      final hits = <RenderItem>{};
      Bvh.build(items).query(frustum, hits.add);
      expect(hits, items.toSet());
    });

    test('additional planes reject boxes outside their visible half-space', () {
      final items = [_itemAt(0), _itemAt(4), _itemAt(8)];
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(-100, 100, -100, 100, -100, 100),
      );
      final hits = <RenderItem>{};
      Bvh.build(items).query(
        frustum,
        hits.add,
        additionalPlanes: [Plane.components(1, 0, 0, -5)],
      );

      expect(hits, {items[2]});
    });

    test('refit tracks an item that moved', () {
      final mover = _itemAt(0);
      final bvh = Bvh.build([
        mover,
        for (int i = 1; i < 5; i++) _itemAt(i * 4.0),
      ]);

      final nearOrigin = Frustum.matrix(
        makeOrthographicMatrix(-2, 2, -2, 2, -100, 100),
      );
      var hits = <RenderItem>{};
      bvh.query(nearOrigin, hits.add);
      expect(hits, {mover}, reason: 'mover starts in the frustum');

      // Move the item far away and refit.
      mover.worldBounds = Aabb3.minMax(
        Vector3(99.5, -0.5, -0.5),
        Vector3(100.5, 0.5, 0.5),
      );
      bvh.refit();

      hits = <RenderItem>{};
      bvh.query(nearOrigin, hits.add);
      expect(hits, isEmpty, reason: 'the moved item left the frustum');

      hits = <RenderItem>{};
      bvh.query(
        Frustum.matrix(makeOrthographicMatrix(98, 102, -2, 2, -100, 100)),
        hits.add,
      );
      expect(hits, {mover}, reason: 'the moved item is found at its new spot');
    });

    test('queryAabb agrees with a brute-force overlap test', () {
      final items = [for (int i = 0; i < 8; i++) _itemAt(i * 4.0)];
      final bvh = Bvh.build(items);
      // Overlaps the items at x = 4, 8, 12 (each a unit box), none others.
      final box = Aabb3.minMax(Vector3(3, -1, -1), Vector3(13, 1, 1));

      final expected = items
          .where((i) => i.worldBounds!.intersectsWithAabb3(box))
          .toSet();
      expect(expected.length, 3);

      final hits = <RenderItem>{};
      bvh.queryAabb(box, hits.add);
      expect(hits, expected);
    });

    test('queryAabb on an empty BVH yields nothing', () {
      final hits = <RenderItem>[];
      Bvh.build(
        [],
      ).queryAabb(Aabb3.minMax(Vector3.zero(), Vector3.all(1)), hits.add);
      expect(hits, isEmpty);
    });
  });

  group('RenderScene.cull', () {
    test('always-visible items are returned regardless of the frustum', () {
      final scene = RenderScene();
      final bounded = _itemAt(0);
      final unbounded = _renderItem(); // worldBounds stays null
      final optedOut = _itemAt(1000)..frustumCulled = false;
      scene.add(bounded);
      scene.add(unbounded);
      scene.add(optedOut);
      scene.rebuildIfDirty();

      // A frustum far from every item's bounds.
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(500, 510, 500, 510, -1, 1),
      );
      final hits = <RenderItem>{};
      scene.cull(frustum, hits.add);

      expect(hits.contains(unbounded), isTrue);
      expect(hits.contains(optedOut), isTrue);
      expect(hits.contains(bounded), isFalse);
    });

    test('material inputs include only visible frustum candidates', () {
      final scene = RenderScene();
      final visible = _itemAt(0)
        ..visible = true
        ..material = _InputMaterial(const {RenderInput.opaqueSceneColor});
      final offscreen = _itemAt(1000)
        ..visible = true
        ..material = _InputMaterial(const {RenderInput.depth});
      final hidden = _itemAt(0)
        ..visible = false
        ..material = _InputMaterial(const {RenderInput.filteredSceneColor});
      scene.add(visible);
      scene.add(offscreen);
      scene.add(hidden);
      scene.rebuildIfDirty();

      final inputs = scene.collectMaterialInputs(
        Frustum.matrix(makeOrthographicMatrix(-5, 5, -5, 5, -5, 5)),
      );

      expect(inputs, const {RenderInput.opaqueSceneColor});
    });
  });

  group('RenderScene, a scene that streams its items', () {
    Set<RenderItem> culled(RenderScene scene, Frustum frustum) {
      final hits = <RenderItem>{};
      scene.cull(frustum, hits.add);
      return hits;
    }

    test('adding one item to a scene of many items runs no full tree '
        'build', () {
      final scene = RenderScene();
      final items = [for (var i = 0; i < 2000; i++) _itemAt(i * 4.0)];
      items.forEach(scene.add);
      scene.rebuildIfDirty();
      final builds = Bvh.debugBuildCount;

      final added = _itemAt(40002);
      scene
        ..add(added)
        ..rebuildIfDirty();
      expect(Bvh.debugBuildCount, builds);
      final near = Frustum.matrix(
        makeOrthographicMatrix(39990, 40010, -10, 10, -100, 100),
      );
      expect(culled(scene, near), {added});

      scene
        ..remove(added)
        ..rebuildIfDirty();
      expect(Bvh.debugBuildCount, builds);
      expect(culled(scene, near), isEmpty);
      expect(scene.bvh.itemCount, 2000);
    });

    test('a scene that adds and removes items one frame at a time culls as '
        'a brute-force frustum test does', () {
      final scene = RenderScene();
      final held = <RenderItem>[];
      for (var i = 0; i < 64; i++) {
        held.add(_itemAt(i * 3.0));
        scene.add(held.last);
      }
      scene.rebuildIfDirty();
      final builds = Bvh.debugBuildCount;
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(40, 400, -10, 10, -100, 100),
      );
      for (var step = 0; step < 300; step++) {
        if (step % 3 == 2) {
          scene.remove(held.removeAt((step * 7) % held.length));
        } else {
          held.add(_itemAt(((step * 37) % 211) * 3.0));
          scene.add(held.last);
        }
        scene.rebuildIfDirty();
        expect(
          culled(scene, frustum),
          held
              .where((item) => frustum.intersectsWithAabb3(item.worldBounds!))
              .toSet(),
        );
      }
      expect(Bvh.debugBuildCount, builds);
      expect(scene.bvh.itemCount, held.length);

      // An item that moved refits, and one that lost its bounds leaves the
      // tree for the always visible.
      held.first.worldBounds!
        ..min.setValues(99.5, -0.5, -0.5)
        ..max.setValues(100.5, 0.5, 0.5);
      held.last.worldBounds = null;
      scene
        ..markBvhBoundsDirty()
        ..markBvhStructureDirty(held.last)
        ..rebuildIfDirty();
      final hits = culled(scene, frustum);
      expect(hits, contains(held.first));
      expect(hits, contains(held.last));
      expect(Bvh.debugBuildCount, builds);
    });

    test('the static shadow casters are counted by the items that change, '
        'and an item that casts none leaves the cached shadows as they '
        'are', () {
      final scene = RenderScene();
      for (var i = 0; i < 100; i++) {
        scene.add(_itemAt(i * 4.0)..visible = true);
      }
      expect(scene.hasStaticShadowCasters, isFalse);
      final revision = scene.staticShadowRevision;

      final plain = _itemAt(500)..visible = true;
      scene.add(plain);
      expect(scene.staticShadowRevision, revision);

      final caster = _itemAt(600);
      scene.add(caster);
      caster
        ..visible = true
        ..shadowStatic = true;
      scene.markStaticShadowDirty(caster);
      expect(scene.staticShadowRevision, revision + 1);
      expect(scene.hasStaticShadowCasters, isTrue);

      scene.remove(plain);
      expect(scene.staticShadowRevision, revision + 1);
      scene.remove(caster);
      expect(scene.staticShadowRevision, revision + 2);
      expect(scene.hasStaticShadowCasters, isFalse);
    });
  });
}
