// Scene.unbuiltPipelines names the draws a render of the views would record
// with a pipeline the process has not built, culled and keyed as the encoders
// cull and key them, and Scene.warmUp with the same views and size builds
// every pipeline it names. Needs a GPU device:
// flutter test --enable-impeller --enable-flutter-gpu.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/render/render_scene.dart' show RenderItem;
import 'package:flutter_scene/src/scene_encoder.dart'
    show evictPipelinesForShaders;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

const _square = ui.Size(100, 100);
const _wide = ui.Size(400, 100);

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

final class _DepthReading extends UnlitMaterial {
  @override
  Set<RenderInput> get sceneInputs => const {RenderInput.depth};
}

PerspectiveCamera _camera() => PerspectiveCamera(
  position: Vector3(0, 0, 10),
  target: Vector3.zero(),
  fovRadiansY: math.pi / 4,
);

Node _box(String name, {Vector3? at, Material? material}) => Node(
  name: name,
  localTransform: Matrix4.translation(at ?? Vector3.zero()),
  mesh: Mesh(
    CuboidGeometry(Vector3.all(1)),
    material ?? PhysicallyBasedMaterial(),
  ),
);

// Drops every pipeline the standard mesh vertex shaders key, so a test starts
// from a process that has drawn none of its draws.
void _forgetMeshPipelines() {
  final geometry = CuboidGeometry(Vector3.all(1));
  evictPipelinesForShaders({
    geometry.vertexShader,
    ?geometry.depthOnlyVertex?.shader,
  });
}

Future<Scene> _scene() async {
  await Scene.initializeStaticResources();
  final scene = Scene();
  addTearDown(scene.dispose);
  _forgetMeshPipelines();
  return scene;
}

RenderItem _itemOf(Scene scene, Node node) => scene.renderScene.items
    .singleWhere((item) => identical(item.sourceNode, node));

List<(String, ScenePipelinePass)> _unbuilt(
  Scene scene,
  List<RenderView> views,
  ui.Size size,
) => [
  for (final draw in scene.unbuiltPipelines(views, size: size))
    (draw.node.name, draw.pass),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'unbuilt pipelines (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.',
    );
    return;
  }

  test('a draw in view is listed until a warm-up of the same views '
      'builds its pipeline, and the query itself builds nothing', () async {
    final scene = await _scene();
    scene.add(_box('box'));
    final views = [RenderView(camera: _camera())];

    expect(_unbuilt(scene, views, _square), [('box', ScenePipelinePass.color)]);
    expect(_unbuilt(scene, views, _square), [('box', ScenePipelinePass.color)]);
    final before = scenePipelinesBuilt;
    await scene.warmUp(views, size: _square);
    expect(scenePipelinesBuilt, greaterThan(before));
    expect(_unbuilt(scene, views, _square), isEmpty);
    final built = scenePipelinesBuilt;
    await scene.warmUp(views, size: _square);
    expect(scenePipelinesBuilt, built);
  });

  test(
    'a hidden node, a node behind the camera and a node on a layer '
    'the view masks out are not listed; a view of that layer lists it',
    () async {
      final scene = await _scene();
      final hidden = _box('hidden')..visible = false;
      final layered = _box('layered')..layers = 2;
      scene
        ..add(hidden)
        ..add(_box('behind', at: Vector3(0, 0, 40)))
        ..add(layered);

      expect(
        _unbuilt(scene, [RenderView(camera: _camera(), layerMask: 1)], _square),
        isEmpty,
      );
      expect(
        _unbuilt(scene, [RenderView(camera: _camera(), layerMask: 2)], _square),
        [('layered', ScenePipelinePass.color)],
      );
    },
  );

  test('a culled instanced draw is listed once an instance comes into '
      'view', () async {
    final scene = await _scene();
    final instances = InstancedMesh(
      geometry: CuboidGeometry(Vector3.all(1)),
      material: PhysicallyBasedMaterial(),
      cullInstances: true,
    )..addInstance(Matrix4.translation(Vector3(0, 0, 40)));
    scene.add(
      Node(name: 'instances')..addComponent(InstancedMeshComponent(instances)),
    );
    final views = [RenderView(camera: _camera())];

    expect(_unbuilt(scene, views, _square), isEmpty);
    instances.addInstance(Matrix4.identity());
    expect(_unbuilt(scene, views, _square), [
      ('instances', ScenePipelinePass.color),
    ]);
  });

  test('turning a sun\'s shadows on lists the lit draws, whose shadow '
      'variant is another pipeline, and a warm-up builds it', () async {
    final scene = await _scene();
    final sun = DirectionalLight(direction: Vector3(0, -1, -0.2));
    scene.directionalLight = sun;
    scene.add(_box('lit'));
    final views = [RenderView(camera: _camera())];
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);

    sun.castsShadow = true;
    expect(_unbuilt(scene, views, _square), [('lit', ScenePipelinePass.color)]);
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);

    sun.castsShadow = false;
    expect(_unbuilt(scene, views, _square), isEmpty);
  });

  test('a node at the side of a wide view is listed, and only a '
      'warm-up at the view\'s size builds it', () async {
    final scene = await _scene();
    scene.add(_box('side', at: Vector3(10, 0, 0)));
    final views = [RenderView(camera: _camera())];

    expect(_unbuilt(scene, views, _square), isEmpty);
    expect(_unbuilt(scene, views, _wide), [('side', ScenePipelinePass.color)]);
    await scene.warmUp(views);
    expect(_unbuilt(scene, views, _wide), [('side', ScenePipelinePass.color)]);
    await scene.warmUp(views, size: _wide);
    expect(_unbuilt(scene, views, _wide), isEmpty);
  });

  test('a material that reads scene depth runs the depth prepass, so '
      'the opaque draws drawn without it are listed for that pass', () async {
    final scene = await _scene();
    scene.add(_box('ground'));
    final views = [RenderView(camera: _camera())];
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);

    scene.add(_box('reader', at: Vector3(0, 1, 0), material: _DepthReading()));
    expect(
      _unbuilt(scene, views, _square),
      unorderedEquals([
        ('ground', ScenePipelinePass.depthPrepass),
        ('reader', ScenePipelinePass.color),
        ('reader', ScenePipelinePass.depthPrepass),
      ]),
    );
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);
  });

  test('a query refreshes a skinned node without uploading its joints, so '
      'the joints ring advances once per frame', () async {
    final scene = await _scene();
    final joint = Node(name: 'joint');
    final skinned = _box('skinned')..add(joint);
    final skin = Skin()
      ..joints.add(joint)
      ..inverseBindMatrices.add(Matrix4.identity());
    skinned.skin = skin;
    scene.add(skinned);
    final views = [RenderView(camera: _camera())];
    await scene.warmUp(views, size: _square);
    final item = _itemOf(scene, skinned);
    final joints = item.jointsTexture;
    final previousJoints = skin.getPreviousJointsTexture();

    _unbuilt(scene, views, _square);
    _unbuilt(scene, views, _square);
    expect(item.jointsTexture, same(joints));
    expect(skin.getPreviousJointsTexture(), same(previousJoints));
  });

  test('a draw whose pipelines are built is not culled per instance by '
      'the query', () async {
    final scene = await _scene();
    final instances =
        InstancedMesh(
            geometry: CuboidGeometry(Vector3.all(1)),
            material: PhysicallyBasedMaterial(),
            cullInstances: true,
          )
          ..addInstance(Matrix4.identity())
          ..addInstance(Matrix4.translation(Vector3(0, 0, 40)));
    final node = Node(name: 'instances')
      ..addComponent(InstancedMeshComponent(instances));
    scene.add(node);
    final views = [RenderView(camera: _camera())];
    await scene.warmUp(views, size: _square);
    final item = _itemOf(scene, node);
    const untouched = [7];
    item.visibleInstanceIndices = untouched;

    expect(_unbuilt(scene, views, _square), isEmpty);
    expect(item.visibleInstanceIndices, same(untouched));
  });
}
