// A frame that only moves the camera refreshes no render item, scans no item
// for what the scene's materials ask of it, and culls each view once.

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
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
  _StubMaterial({this.inputs = const {}, this.displayReferred = false});

  final Set<RenderInput> inputs;

  @override
  final bool displayReferred;

  @override
  Set<RenderInput> get sceneInputs => inputs;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    throw UnsupportedError('Stub material is not renderable');
  }
}

Frustum _viewAt(double x) =>
    Frustum.matrix(makeOrthographicMatrix(x - 5, x + 5, -5, 5, -5, 5));

void main() {
  late RenderScene scene;
  late Node root;
  late List<Node> meshes;
  late Node instanced;
  late Node depthReader;

  // What a frame does before its passes encode: the pre-pass, the spatial
  // structure, and per view the material summary and the one cull.
  ({int refreshed, int scanned, ViewVisibleItems kept}) frame(Frustum view) {
    final counters = activeRenderCounters;
    final nodesBefore = counters.prePassNodes;
    final scannedBefore = counters.materialSummaryItems;
    scene.runPrePass(1 / 60);
    scene.rebuildIfDirty();
    final summary = scene.materialSummary;
    final kept = scene.collectVisible(
      view,
      ViewVisibleItems(),
      gatherInputs: summary.inputs.isNotEmpty,
    );
    return (
      refreshed: counters.prePassNodes - nodesBefore,
      scanned: counters.materialSummaryItems - scannedBefore,
      kept: kept,
    );
  }

  setUp(() {
    scene = RenderScene();
    root = Node()..debugMountInto(scene);
    meshes = [
      for (var m = 0; m < 200; m++)
        Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
          ..localTransform = Matrix4.translation(Vector3(m * 4.0, 0, 0)),
    ];
    root.addAll(meshes);
    instanced = Node()
      ..addComponent(
        InstancedMeshComponent(
          InstancedMesh(geometry: _StubGeometry(), material: _StubMaterial())
            ..addInstance(Matrix4.identity()),
        ),
      );
    root.add(instanced);
    depthReader = Node(
      mesh: Mesh(
        _StubGeometry(),
        _StubMaterial(inputs: const {RenderInput.depth}),
      ),
    )..localTransform = Matrix4.translation(Vector3(400, 0, 0));
    root.add(depthReader);
    frame(_viewAt(0));
  });

  test('a camera-only frame refreshes no node and scans no item', () {
    final at = frame(_viewAt(400));
    expect(at.refreshed, 0);
    expect(at.scanned, 0);
    expect(at.kept.inputs, const {RenderInput.depth});

    final away = frame(_viewAt(0));
    expect(away.refreshed, 0);
    expect(away.scanned, 0);
    expect(away.kept.inputs, isEmpty);
    expect(scene.materialSummary.displayReferredItems, isEmpty);
    expect(scene.materialSummary.shadowCatcherItems, isEmpty);
    expect(scene.hasVisibleDisplayReferred, isFalse);
  });

  test('the cull that gathers the inputs is the one the pass draws from', () {
    final kept = frame(_viewAt(400)).kept;
    final culled = <RenderItem>[];
    final rejected = scene.cull(_viewAt(400), culled.add);
    expect(kept.items, culled);
    expect(kept.rejected, rejected);
    expect(kept.isCurrentFor(scene), isTrue);

    meshes.first.detach();
    expect(kept.isCurrentFor(scene), isFalse);
  });

  test('a moved node refreshes only itself and leaves the summary', () {
    meshes[7].localTransform = Matrix4.translation(Vector3(0, 3, 0));
    final moved = frame(_viewAt(0));
    expect(moved.refreshed, 1);
    expect(moved.scanned, 0);

    instanced.localTransform = Matrix4.translation(Vector3(0, -3, 0));
    final movedInstances = frame(_viewAt(0));
    expect(movedInstances.refreshed, 1);
    expect(movedInstances.scanned, 0);
  });

  test('a material change scans the items once', () {
    final node = meshes[3];
    node.mesh = Mesh(_StubGeometry(), _StubMaterial(displayReferred: true));
    final swapped = frame(_viewAt(0));
    expect(swapped.scanned, scene.items.length);
    expect(scene.hasVisibleDisplayReferred, isTrue);
    expect(frame(_viewAt(0)).scanned, 0);

    node.visible = false;
    final hidden = frame(_viewAt(0));
    expect(hidden.scanned, 0);
    expect(scene.hasVisibleDisplayReferred, isFalse);

    final unlit = UnlitMaterial();
    meshes[4].mesh = Mesh(_StubGeometry(), unlit);
    frame(_viewAt(0));
    expect(scene.hasVisibleDisplayReferred, isFalse);
    unlit.displayReferred = true;
    expect(frame(_viewAt(0)).scanned, scene.items.length);
    expect(scene.hasVisibleDisplayReferred, isTrue);

    final catcher = ShadowCatcherMaterial();
    meshes[5].mesh = Mesh(_StubGeometry(), catcher);
    frame(_viewAt(0));
    expect(scene.materialSummary.shadowCatcherItems.single.material, catcher);
  });
}
