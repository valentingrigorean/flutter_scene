// The scene pre-pass visits the nodes that changed and the nodes that state
// they need every frame, never the node tree.

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
  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    throw UnsupportedError('Stub material is not renderable');
  }
}

class _Spinner extends Component {
  int updates = 0;

  @override
  void update(double deltaSeconds) => updates++;
}

Node _meshNode() => Node(mesh: Mesh(_StubGeometry(), _StubMaterial()));

int _visited(RenderScene scene) {
  final before = activeRenderCounters.prePassNodes;
  scene.runPrePass(1 / 60);
  return activeRenderCounters.prePassNodes - before;
}

void main() {
  late RenderScene scene;
  late Node root;
  late List<Node> groups;
  late List<Node> meshes;

  setUp(() {
    scene = RenderScene();
    root = Node()..debugMountInto(scene);
    groups = [for (var g = 0; g < 4; g++) Node()];
    meshes = [];
    for (final group in groups) {
      root.add(group);
      for (var m = 0; m < 25; m++) {
        final node = _meshNode()
          ..localTransform = Matrix4.translation(Vector3(m * 4.0, 0, 0));
        meshes.add(node);
        group.add(node);
      }
    }
  });

  test('the frame after a mount refreshes each mesh node once', () {
    expect(_visited(scene), meshes.length);
    expect(scene.items.every((item) => item.visible), isTrue);
  });

  test('a frame that changes no node visits no node', () {
    _visited(scene);
    expect(_visited(scene), 0);
    expect(_visited(scene), 0);
  });

  test('a moved node is the one node the next frame visits', () {
    _visited(scene);
    final moved = meshes[7]..position = Vector3(0, 9, 0);
    expect(_visited(scene), 1);
    final item = scene.items.firstWhere((item) => item.sourceNode == moved);
    expect(item.worldTransform.getTranslation(), Vector3(0, 9, 0));
    expect(_visited(scene), 0);
  });

  test('a moved parent refreshes the mesh nodes below it', () {
    _visited(scene);
    groups[1].position = Vector3(0, 0, 5);
    expect(_visited(scene), 25);
    for (final item in scene.items) {
      final node = item.sourceNode! as Node;
      expect(
        item.worldTransform.getTranslation().z,
        node.parent == groups[1] ? 5 : 0,
      );
    }
  });

  test('a hidden parent hides the items below it and showing it restores '
      'them', () {
    _visited(scene);
    groups[2].visible = false;
    expect(_visited(scene), 25);
    expect(scene.items.where((item) => !item.visible), hasLength(25));
    expect(_visited(scene), 0);
    groups[2].visible = true;
    expect(_visited(scene), 25);
    expect(scene.items.every((item) => item.visible), isTrue);
  });

  test('a node flag a render item mirrors queues its node', () {
    _visited(scene);
    meshes[3].layers = 2;
    meshes[4].renderOrder = 1;
    meshes[5].frustumCulled = false;
    meshes[6].shadowStatic = true;
    meshes[6].highlightColor = Vector4(1, 0, 0, 1);
    expect(_visited(scene), 4);
    RenderItem itemOf(Node node) =>
        scene.items.firstWhere((item) => item.sourceNode == node);
    expect(itemOf(meshes[3]).layers, 2);
    expect(itemOf(meshes[4]).renderOrder, 1);
    expect(itemOf(meshes[5]).frustumCulled, isFalse);
    expect(itemOf(meshes[6]).shadowStatic, isTrue);
    expect(itemOf(meshes[6]).highlightColor, Vector4(1, 0, 0, 1));
  });

  test('a change that names no node refreshes every item once', () {
    _visited(scene);
    final primitive = meshes[9].mesh!.primitives.single..visible = false;
    expect(_visited(scene), meshes.length);
    final item = scene.items.firstWhere((item) => item.drawSource == primitive);
    expect(item.primitiveVisible, isFalse);
    expect(_visited(scene), 0);
  });

  test('a node whose component ticks is visited on every frame, and stops '
      'when the component leaves', () async {
    _visited(scene);
    final spinner = _Spinner();
    final node = Node()..addComponent(spinner);
    root.add(node);
    await Future<void>.delayed(Duration.zero);
    expect(_visited(scene), 1);
    expect(_visited(scene), 1);
    expect(spinner.updates, 2);
    node.removeComponent(spinner);
    expect(_visited(scene), 0);
    expect(scene.prePass.frameNodeCount, 0);
  });

  test('a node that leaves the scene is not refreshed', () {
    _visited(scene);
    final gone = meshes[0]..position = Vector3(1, 1, 1);
    gone.parent!.remove(gone);
    expect(_visited(scene), 0);
    expect(scene.items, hasLength(meshes.length - 1));
  });
}
