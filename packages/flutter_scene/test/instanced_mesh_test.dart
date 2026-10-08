// InstancedMesh API tests. Uses stub Geometry and Material so the tests
// run without a Flutter GPU context.

import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

/// Geometry that skips shader-library access. Optionally carries a
/// local-space AABB so aggregate-bounds logic can be exercised.
class _StubGeometry extends Geometry {
  _StubGeometry({Aabb3? aabb}) {
    if (aabb != null) {
      setLocalBounds(
        aabb,
        Sphere.centerRadius(
          (aabb.min + aabb.max) * 0.5,
          ((aabb.max - aabb.min) * 0.5).length,
        ),
      );
    }
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

InstancedMesh _instancedMesh({
  Aabb3? aabb,
  bool sortTransparentInstances = true,
}) => InstancedMesh(
  geometry: _StubGeometry(aabb: aabb),
  material: _StubMaterial(),
  sortTransparentInstances: sortTransparentInstances,
);

void main() {
  group('InstancedMesh instances', () {
    test('a new instanced mesh has no instances', () {
      final mesh = _instancedMesh();
      expect(mesh.instanceCount, 0);
      expect(mesh.sortTransparentInstances, isTrue);
      expect(
        _instancedMesh(
          sortTransparentInstances: false,
        ).sortTransparentInstances,
        isFalse,
      );
    });

    test('addInstance appends and returns the new index', () {
      final mesh = _instancedMesh();
      expect(mesh.addInstance(Matrix4.identity()), 0);
      expect(mesh.addInstance(Matrix4.identity()), 1);
      expect(mesh.instanceCount, 2);
    });

    test('addInstance copies the transform', () {
      final mesh = _instancedMesh();
      final transform = Matrix4.identity();
      mesh.addInstance(transform);
      transform.setTranslationRaw(9, 9, 9);

      expect(mesh.instances[0], Matrix4.identity());
    });

    test('stores white by default and copies explicit colors', () {
      final mesh = _instancedMesh();
      mesh.addInstance(Matrix4.identity());
      final color = Vector4(0.2, 0.4, 0.6, 0.8);
      mesh.addInstance(Matrix4.identity(), color: color);
      color.setZero();

      expect(mesh.colors[0], Vector4(1, 1, 1, 1));
      expect(mesh.colors[1], Vector4(0.2, 0.4, 0.6, 0.8));
    });

    test('updates an instance color', () {
      final mesh = _instancedMesh()..addInstance(Matrix4.identity());
      mesh.setInstanceColor(0, Vector4(0.1, 0.2, 0.3, 1));
      expect(mesh.colors[0], Vector4(0.1, 0.2, 0.3, 1));
    });

    test('setInstanceTransform replaces an instance transform', () {
      final mesh = _instancedMesh();
      mesh.addInstance(Matrix4.identity());
      final moved = Matrix4.translation(Vector3(5, 0, 0));
      mesh.setInstanceTransform(0, moved);

      expect(mesh.instances[0], moved);
    });

    test('retains winding parity when transforms change', () {
      final mesh = _instancedMesh();
      final mirrored = Matrix4.identity()..scaleByVector3(Vector3(-1, 1, 1));
      mesh.addInstance(mirrored);
      expect(mesh.windingFlipped, [true]);

      mesh.setInstanceTransform(0, Matrix4.identity());
      expect(mesh.windingFlipped, [false]);
    });

    test('updates a transform batch with one revision', () {
      final mesh = _instancedMesh()
        ..addInstance(Matrix4.identity())
        ..addInstance(Matrix4.identity());
      final revision = mesh.revision;

      mesh.updateInstanceTransforms((transforms) {
        transforms[0].setTranslationRaw(2, 0, 0);
        transforms[1]
          ..setIdentity()
          ..scaleByVector3(Vector3(-1, 1, 1));
      });

      expect(mesh.instances[0].getTranslation().x, 2);
      expect(mesh.windingFlipped, [false, true]);
      expect(mesh.revision, revision + 1);
    });

    test('bulk transform view has a fixed structure', () {
      final mesh = _instancedMesh()..addInstance(Matrix4.identity());
      expect(
        () => mesh.updateInstanceTransforms((transforms) {
          transforms.add(Matrix4.identity());
        }),
        throwsUnsupportedError,
      );
      expect(mesh.instanceCount, 1);
    });

    test('bulk transform update can retain known winding parity', () {
      final mesh = _instancedMesh()..addInstance(Matrix4.identity());
      mesh.updateInstanceTransforms(
        (transforms) => transforms[0].scaleByVector3(Vector3(-1, 1, 1)),
        recomputeWinding: false,
      );
      expect(mesh.windingFlipped, [false]);
    });

    test('removeInstanceAt removes and shifts later instances', () {
      final mesh = _instancedMesh();
      final a = Matrix4.translation(Vector3(1, 0, 0));
      final b = Matrix4.translation(Vector3(2, 0, 0));
      final c = Matrix4.translation(Vector3(3, 0, 0));
      mesh.addInstance(a);
      mesh.addInstance(b);
      mesh.addInstance(c);

      mesh.removeInstanceAt(0);
      expect(mesh.instanceCount, 2);
      expect(mesh.instances[0], b);
      expect(mesh.colors, hasLength(2));
      expect(mesh.instances[1], c);
    });

    test('clearInstances removes every instance', () {
      final mesh = _instancedMesh();
      mesh.addInstance(Matrix4.identity());
      mesh.addInstance(Matrix4.identity());
      mesh.clearInstances();

      expect(mesh.instanceCount, 0);
      expect(mesh.colors, isEmpty);
    });
  });

  group('InstancedMesh aggregate bounds', () {
    test('bounds are null without a geometry bound', () {
      final mesh = _instancedMesh();
      mesh.addInstance(Matrix4.identity());
      expect(mesh.aggregateBounds, isNull);
    });

    test('bounds are null when there are no instances', () {
      final mesh = _instancedMesh(
        aabb: Aabb3.minMax(Vector3(-0.5, -0.5, -0.5), Vector3(0.5, 0.5, 0.5)),
      );
      expect(mesh.aggregateBounds, isNull);
    });

    test('bounds hull every instance and update after a change', () {
      final mesh = _instancedMesh(
        aabb: Aabb3.minMax(Vector3(-0.5, -0.5, -0.5), Vector3(0.5, 0.5, 0.5)),
      );
      mesh.addInstance(Matrix4.translation(Vector3(10, 0, 0)));
      mesh.addInstance(Matrix4.translation(Vector3(-10, 0, 0)));

      final bounds = mesh.aggregateBounds!;
      expect(bounds.min.x, closeTo(-10.5, 1e-6));
      expect(bounds.max.x, closeTo(10.5, 1e-6));

      mesh.clearInstances();
      expect(mesh.aggregateBounds, isNull);
    });

    test('bounds update when the geometry bounds change', () {
      final geometry = _StubGeometry(
        aabb: Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5)),
      );
      final mesh = InstancedMesh(geometry: geometry, material: _StubMaterial())
        ..addInstance(Matrix4.identity());
      expect(mesh.aggregateBounds!.max.x, 0.5);

      geometry.setLocalBounds(
        Aabb3.minMax(Vector3.all(-2), Vector3.all(2)),
        Sphere.centerRadius(Vector3.zero(), 4),
      );
      expect(mesh.aggregateBounds!.max.x, 2);
    });
  });

  group('InstancedMesh culling', () {
    test('selects one-row cells through frustum and custom planes', () {
      final geometry = _StubGeometry(
        aabb: Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5)),
      );
      final item = RenderItem(geometry: geometry, material: _StubMaterial())
        ..cullInstances = true
        ..instanceCellRows = 1
        ..instanceTransforms = [
          Matrix4.translation(Vector3(0, 0, 0)),
          Matrix4.translation(Vector3(4, 0, 0)),
          Matrix4.translation(Vector3(8, 0, 0)),
        ]
        ..worldBounds = Aabb3.minMax(
          Vector3(-0.5, -0.5, -0.5),
          Vector3(8.5, 0.5, 0.5),
        )
        ..refreshInstanceData();
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(-5, 5, -5, 5, -5, 5),
      );

      expect(
        item.cullVisibleCells(frustum, [Plane.components(1, 0, 0, -2)]),
        isTrue,
      );
      expect(item.visibleInstanceRanges, [1, 1, 0]);
    });

    test('leaves out the rows of a cell outside the frustum, joins '
        'neighbouring cells and starts a range at a mirrored row', () {
      final geometry = _StubGeometry(
        aabb: Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5)),
      );
      final item = RenderItem(geometry: geometry, material: _StubMaterial())
        ..cullInstances = true
        ..instanceCellRows = 2
        ..instanceTransforms = [
          for (final x in [0.0, 1.0, 2.0, 3.0, 20.0, 21.0])
            Matrix4.translation(Vector3(x, 0, 0)),
          Matrix4.translation(Vector3(4, 0, 0))
            ..scaleByVector3(Vector3(-1, 1, 1)),
          Matrix4.translation(Vector3(4, 0, 0)),
        ]
        ..refreshInstanceData();

      expect(item.instanceRowRanges, [0, 6, 0, 6, 1, 1, 7, 1, 0]);
      expect(
        item.cullVisibleCells(
          Frustum.matrix(makeOrthographicMatrix(-5, 5, -5, 5, -5, 5)),
          const [],
        ),
        isTrue,
      );
      expect(item.visibleInstanceRanges, [0, 4, 0, 6, 1, 1, 7, 1, 0]);
    });

    test('draws one range from the first visible row to the last where a '
        'cull leaves more ranges than the limit', () {
      final geometry = _StubGeometry(
        aabb: Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5)),
      );
      final item = RenderItem(geometry: geometry, material: _StubMaterial())
        ..cullInstances = true
        ..instanceCellRows = 1
        ..instanceRangeLimit = 2
        ..instanceTransforms = [
          for (final x in [20.0, 0.0, 21.0, 1.0, 22.0, 2.0, 23.0])
            Matrix4.translation(Vector3(x, 0, 0)),
        ]
        ..refreshInstanceData();

      expect(
        item.cullVisibleCells(
          Frustum.matrix(makeOrthographicMatrix(-5, 5, -5, 5, -5, 5)),
          const [],
        ),
        isTrue,
      );
      expect(item.visibleInstanceRanges, [1, 5, 0]);
    });

    test('uses null ranges when every cell passes', () {
      final geometry = _StubGeometry(
        aabb: Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5)),
      );
      final item = RenderItem(geometry: geometry, material: _StubMaterial())
        ..cullInstances = true
        ..instanceTransforms = [Matrix4.identity()]
        ..worldBounds = Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5))
        ..refreshInstanceData();

      expect(
        item.cullVisibleCells(
          Frustum.matrix(makeOrthographicMatrix(-5, 5, -5, 5, -5, 5)),
          const [],
        ),
        isTrue,
      );
      expect(item.visibleInstanceRanges, isNull);
    });

    test('refreshes cached world bounds after a transform change', () {
      final geometry = _StubGeometry(
        aabb: Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5)),
      );
      final item = RenderItem(geometry: geometry, material: _StubMaterial())
        ..cullInstances = true
        ..instanceTransforms = [Matrix4.identity()];
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(-5, 5, -5, 5, -5, 5),
      );

      item.refreshInstanceData();
      expect(item.cullVisibleCells(frustum, const []), isTrue);
      item.worldTransform.setTranslationRaw(20, 0, 0);
      item.refreshInstanceData();
      expect(item.cullVisibleCells(frustum, const []), isFalse);
    });
  });

  group('InstancedMesh row changes', () {
    test('lists the rows each change touched since a revision', () {
      final mesh = _instancedMesh();
      for (var i = 0; i < 4; i++) {
        mesh.addInstance(Matrix4.translation(Vector3(i * 2.0, 0, 0)));
      }
      final seen = mesh.revision;
      mesh
        ..setInstanceTransform(2, Matrix4.identity())
        ..setInstanceColor(1, Vector4(1, 0, 0, 1));
      expect(mesh.rowsChangedSince(seen), [2, 1]);
      expect(mesh.rowsChangedSince(mesh.revision), isEmpty);

      final beforeAppend = mesh.revision;
      mesh
        ..addInstance(Matrix4.identity())
        ..removeInstanceAt(4);
      expect(mesh.rowsChangedSince(beforeAppend), [4, 4]);
      expect(mesh.instanceCount, 4);
    });

    test('a removal before the last row, a clear or a bulk update moves '
        'rows, so no row list stands for it', () {
      InstancedMesh filled() {
        final mesh = _instancedMesh();
        for (var i = 0; i < 3; i++) {
          mesh.addInstance(Matrix4.identity());
        }
        return mesh;
      }

      final removed = filled();
      final seen = removed.revision;
      removed.removeInstanceAt(0);
      expect(removed.rowsChangedSince(seen), isNull);

      final cleared = filled();
      final clearedFrom = cleared.revision;
      cleared.clearInstances();
      expect(cleared.rowsChangedSince(clearedFrom), isNull);

      final bulk = filled();
      final bulkFrom = bulk.revision;
      bulk.updateInstanceTransforms((_) {});
      expect(bulk.rowsChangedSince(bulkFrom), isNull);
      expect(bulk.rowsChangedSince(bulk.revision), isEmpty);
    });

    test('a log longer than the instances restarts, so a revision before it '
        'reads every row again', () {
      final mesh = _instancedMesh()..addInstance(Matrix4.identity());
      final seen = mesh.revision;
      for (var i = 0; i < 80; i++) {
        mesh.setInstanceColor(0, Vector4(i / 80, 0, 0, 1));
      }
      expect(mesh.rowsChangedSince(seen), isNull);
      expect(mesh.rowsChangedSince(mesh.revision), isEmpty);
    });

    test('aggregate bounds after a row change match bounds read from every '
        'row', () {
      final aabb = Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5));
      final mesh = _instancedMesh(aabb: aabb);
      for (var i = 0; i < 100; i++) {
        mesh.addInstance(Matrix4.translation(Vector3(i * 1.0, 0, 0)));
      }
      expect(mesh.aggregateBounds!.max.x, closeTo(99.5, 1e-6));

      mesh.setInstanceTransform(99, Matrix4.translation(Vector3(10, 0, 0)));
      expect(mesh.aggregateBounds!.max.x, closeTo(98.5, 1e-6));
      mesh.setInstanceTransform(0, Matrix4.translation(Vector3(0, -7, 0)));
      expect(mesh.aggregateBounds!.min.y, closeTo(-7.5, 1e-6));
      mesh.removeInstanceAt(99);
      mesh.removeInstanceAt(98);
      expect(mesh.aggregateBounds!.max.x, closeTo(97.5, 1e-6));
    });
  });

  group('RenderItem instance records', () {
    const rows = 1000;
    const recordBytes = 20 * 4;
    final aabb = Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5));

    RenderItem itemOf(InstancedMesh mesh) =>
        RenderItem(geometry: mesh.geometry, material: mesh.material)
          ..cullInstances = true
          ..instanceTransforms = mesh.instances
          ..instanceColors = mesh.colors
          ..instanceWindingFlipped = mesh.windingFlipped;

    InstancedMesh meshOf(int count) {
      final mesh = _instancedMesh(aabb: aabb);
      for (var i = 0; i < count; i++) {
        mesh.addInstance(
          Matrix4.translation(Vector3(i * 2.0, 0, 0)),
          color: Vector4(i / count, 0, 0, 1),
        );
      }
      return mesh;
    }

    int packed(void Function() pack) {
      final before = activeRenderCounters.instanceBytesPacked;
      pack();
      return activeRenderCounters.instanceBytesPacked - before;
    }

    void expectSameRecords(RenderItem item, InstancedMesh mesh) {
      final fresh = itemOf(mesh)..refreshInstanceData();
      expect(item.instanceWorldData, fresh.instanceWorldData);
      expect(
        item.instanceWorldWindingFlipped,
        fresh.instanceWorldWindingFlipped,
      );
      final frustum = Frustum.matrix(
        makeOrthographicMatrix(-5, 5, -5, 5, -5, 5),
      );
      item
        ..worldBounds = Aabb3.minMax(Vector3.all(-1e6), Vector3.all(1e6))
        ..cullVisibleCells(frustum, const []);
      fresh
        ..worldBounds = Aabb3.minMax(Vector3.all(-1e6), Vector3.all(1e6))
        ..cullVisibleCells(frustum, const []);
      expect(item.visibleInstanceRanges, fresh.visibleInstanceRanges);
    }

    test('a change of one row of $rows packs only that row\'s record, '
        '$recordBytes bytes', () {
      final mesh = meshOf(rows);
      final item = itemOf(mesh);
      expect(packed(item.refreshInstanceData), rows * recordBytes);
      final seen = mesh.revision;

      mesh.setInstanceTransform(500, Matrix4.translation(Vector3(1, 0, 0)));
      expect(
        packed(() => item.refreshInstanceRows(mesh.rowsChangedSince(seen)!)),
        recordBytes,
      );
      expectSameRecords(item, mesh);

      final again = mesh.revision;
      mesh
        ..setInstanceColor(5, Vector4(0, 1, 0, 1))
        ..setInstanceColor(6, Vector4(0, 1, 0, 1))
        ..setInstanceTransform(5, Matrix4.translation(Vector3(0, 9, 0)));
      expect(
        packed(() => item.refreshInstanceRows(mesh.rowsChangedSince(again)!)),
        2 * recordBytes,
      );
      expectSameRecords(item, mesh);
    });

    test('rows appended one at a time and removed from the end pack only '
        'themselves', () {
      final mesh = meshOf(rows);
      final item = itemOf(mesh)..refreshInstanceData();
      var seen = mesh.revision;
      for (var i = 0; i < 300; i++) {
        mesh.addInstance(Matrix4.translation(Vector3(0, i * 2.0, 0)));
        expect(
          packed(() => item.refreshInstanceRows(mesh.rowsChangedSince(seen)!)),
          recordBytes,
        );
        seen = mesh.revision;
      }
      expectSameRecords(item, mesh);

      mesh
        ..setInstanceTransform(3, mesh.instances.last)
        ..removeInstanceAt(mesh.instanceCount - 1);
      expect(
        packed(() => item.refreshInstanceRows(mesh.rowsChangedSince(seen)!)),
        recordBytes,
      );
      expect(item.instanceWorldData, hasLength((rows + 299) * 20));
      expectSameRecords(item, mesh);
    });

    test('a mounted component packs only the rows its mesh changed, and '
        'every row after its node moves', () {
      final mesh = meshOf(rows);
      final component = InstancedMeshComponent(mesh);
      final node = Node()..addComponent(component);
      Node().add(node);
      node.parent!.debugMountInto(RenderScene());
      expect(packed(component.refreshRenderItem), rows * recordBytes);
      expect(packed(component.refreshRenderItem), 0);

      mesh
        ..setInstanceTransform(7, Matrix4.translation(Vector3(0, 3, 0)))
        ..setInstanceColor(7, Vector4(0, 0, 1, 1));
      expect(packed(component.refreshRenderItem), recordBytes);

      node.localTransform = Matrix4.translation(Vector3(0, 0, 5));
      expect(packed(component.refreshRenderItem), rows * recordBytes);
    });

    test('a mounted component of node-space records packs no row after its '
        'node moves, keeps each record relative to the node, and packs every '
        'row once the node mirrors', () {
      final mesh = InstancedMesh(
        geometry: _StubGeometry(aabb: aabb)
          ..setVertexLayout(const VertexLayoutDescriptor(buffers: [])),
        material: _StubMaterial(),
        cullInstances: true,
        nodeSpaceInstances: true,
      );
      for (var i = 0; i < rows; i++) {
        mesh.addInstance(Matrix4.translation(Vector3(i * 2.0, 0, 0)));
      }
      final component = InstancedMeshComponent(mesh);
      final node = Node(localTransform: Matrix4.translation(Vector3(0, 7, 0)))
        ..addComponent(component);
      Node().add(node);
      node.parent!.debugMountInto(RenderScene());
      expect(packed(component.refreshRenderItem), rows * recordBytes);
      final item = component.debugRenderItem!;
      expect(item.nodeSpaceInstances, isTrue);
      expect(item.cullInstances, isFalse);
      expect(item.instanceWorldData!.sublist(20 * 3 + 12, 20 * 3 + 15), [
        6,
        0,
        0,
      ]);
      final records = item.instanceWorldData;

      node.localTransform = Matrix4.translation(Vector3(0, 0, 5));
      expect(packed(component.refreshRenderItem), 0);
      expect(item.instanceWorldData, same(records));
      expect(item.instanceFrame!.getTranslation(), Vector3(0, 0, 5));
      expect(item.worldBounds!.min, Vector3(-0.5, -0.5, 4.5));

      mesh.setInstanceTransform(3, Matrix4.translation(Vector3(1, 0, 0)));
      node.localTransform = Matrix4.translation(Vector3(0, 0, 9));
      expect(packed(component.refreshRenderItem), recordBytes);

      node.localTransform = Matrix4.diagonal3Values(-1, 1, 1);
      expect(packed(component.refreshRenderItem), rows * recordBytes);
    });

    test(
      'a record layout that changed since the last pack packs every row',
      () {
        final mesh = meshOf(10);
        final item = itemOf(mesh)
          ..instanceColors = null
          ..refreshInstanceData();
        expect(item.instanceWorldData, isNull);
        final seen = mesh.revision;
        mesh.setInstanceColor(4, Vector4(0, 1, 0, 1));
        item.instanceColors = mesh.colors;
        expect(
          packed(() => item.refreshInstanceRows(mesh.rowsChangedSince(seen)!)),
          10 * recordBytes,
        );
        expectSameRecords(item, mesh);
      },
    );
  });

  group('InstancedMesh.sharing', () {
    final aabb = Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5));
    _StubGeometry geometry() =>
        _StubGeometry(aabb: aabb)
          ..setVertexLayout(const VertexLayoutDescriptor(buffers: []));

    InstancedMesh rowsOf(int count) {
      final rows = InstancedMesh(
        geometry: geometry(),
        material: _StubMaterial(),
        nodeSpaceInstances: true,
      );
      for (var i = 0; i < count; i++) {
        rows.addInstance(Matrix4.translation(Vector3(i * 2.0, 0, 0)));
      }
      return rows;
    }

    RenderItem mounted(InstancedMeshComponent component) {
      final node = Node()..addComponent(component);
      Node().add(node);
      node.parent!.debugMountInto(RenderScene());
      component.refreshRenderItem();
      return component.debugRenderItem!;
    }

    test('a sharing mesh draws the rows of its row set and packs no record '
        'of its own', () {
      final rows = rowsOf(100);
      final mesh = InstancedMesh.sharing(
        rows,
        geometry: geometry(),
        material: _StubMaterial(),
      )..instanceRanges = Uint32List.fromList([10, 20, 60, 5]);
      final component = InstancedMeshComponent(mesh);
      final before = activeRenderCounters.instanceBytesPacked;
      final item = mounted(component);
      expect(activeRenderCounters.instanceBytesPacked, before);
      expect(item.sharedRows, same(rows));
      expect(item.instanceWorldData, isNull);
      expect(item.nodeSpaceInstances, isTrue);
      expect(item.instanceRanges, [10, 20, 60, 5]);
      expect(mesh.instanceCount, 100);
      expect(item.worldBounds!.max.x, 198.5);

      rows.addInstance(Matrix4.translation(Vector3(500, 0, 0)));
      component.refreshRenderItem();
      expect(mesh.instanceCount, 101);
      expect(item.worldBounds!.max.x, 500.5);
      expect(activeRenderCounters.instanceBytesPacked, before);
    });

    test('a row write on a sharing mesh throws', () {
      final mesh = InstancedMesh.sharing(
        rowsOf(2),
        geometry: geometry(),
        material: _StubMaterial(),
      );
      expect(() => mesh.addInstance(Matrix4.identity()), throwsStateError);
      expect(
        () => mesh.setInstanceTransform(0, Matrix4.identity()),
        throwsStateError,
      );
      expect(mesh.clearInstances, throwsStateError);
    });

    test('the bounds of a mesh place its geometry by its instance local '
        'transform inside each row', () {
      final mesh = InstancedMesh.sharing(
        rowsOf(3),
        geometry: geometry(),
        material: _StubMaterial(),
      )..instanceLocal = Matrix4.translation(Vector3(0, 10, 0));
      final item = mounted(InstancedMeshComponent(mesh));
      expect(item.instanceLocal!.getTranslation(), Vector3(0, 10, 0));
      expect(item.worldBounds!.min, Vector3(-0.5, 9.5, -0.5));
      expect(item.worldBounds!.max, Vector3(4.5, 10.5, 0.5));
    });

    test('an instance local transform stated after the item rests moves its '
        'bounds', () {
      final mesh = InstancedMesh.sharing(
        rowsOf(3),
        geometry: geometry(),
        material: _StubMaterial(),
      );
      final component = InstancedMeshComponent(mesh);
      final item = mounted(component);
      component.node.shadowStatic = true;
      component.refreshRenderItem();
      mesh.instanceLocal = Matrix4.translation(Vector3(0, 1000, 0));
      component.refreshRenderItem();
      expect(item.worldBounds!.max.y, 1000.5);
    });

    test('ranges, a band, a band field and a local transform stated on a '
        'static shadow caster each redraw the cached shadows', () {
      final mesh = InstancedMesh.sharing(
        rowsOf(3),
        geometry: geometry(),
        material: _StubMaterial(),
      );
      final component = InstancedMeshComponent(mesh);
      final node = Node()..addComponent(component);
      Node().add(node);
      final renderScene = RenderScene();
      node.parent!.debugMountInto(renderScene);
      node.shadowStatic = true;
      component.refreshRenderItem();
      final band = InstanceBand();
      for (final change in <void Function()>[
        () => mesh.instanceRanges = Uint32List.fromList([0, 1]),
        () => mesh.band = band,
        () {
          band.farReach = 4;
          mesh.bandChanged();
        },
        () => mesh.instanceLocal = Matrix4.translation(Vector3(1, 0, 0)),
      ]) {
        final before = renderScene.staticShadowRevision;
        change();
        component.refreshRenderItem();
        expect(renderScene.staticShadowRevision, isNot(before));
      }
    });

    test('a band and ranges stated after the item rests reach it', () {
      final mesh = InstancedMesh.sharing(
        rowsOf(3),
        geometry: geometry(),
        material: _StubMaterial(),
      );
      final component = InstancedMeshComponent(mesh);
      final item = mounted(component);
      component.node.shadowStatic = true;
      component.refreshRenderItem();
      final band = InstanceBand(farReach: 4);
      mesh
        ..band = band
        ..instanceRanges = Uint32List.fromList([1, 1]);
      component.refreshRenderItem();
      expect(item.instanceBand, same(band));
      expect(item.instanceRanges, [1, 1]);
    });
  });
}
