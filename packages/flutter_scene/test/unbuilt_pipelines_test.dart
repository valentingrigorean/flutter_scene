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

void _frame(Scene scene, List<RenderView> views, ui.Size size) {
  final recorder = ui.PictureRecorder();
  scene.renderViews(views, ui.Canvas(recorder), region: ui.Offset.zero & size);
  recorder.endRecording().dispose();
}

// Drops the masked shadow caster pipelines, so an alpha-masked caster added
// next has a shadow pipeline no draw has built.
void _forgetMaskedShadowPipelines() =>
    evictPipelinesForShaders({baseShaderLibrary['DepthOnlyMaskedFragment']!});

PerspectiveCamera _distanceCamera() => PerspectiveCamera(
  position: Vector3(0, 3, 10),
  target: Vector3(0, 0, -20),
  fovRadiansY: math.pi / 4,
);

List<(String, ScenePipelinePass)> _unbuilt(
  Scene scene,
  List<RenderView> views,
  ui.Size size,
) => [
  for (final draw in scene.unbuiltPipelines(views, size: size))
    (draw.node.name, draw.pass),
];

List<(String, ScenePipelinePass)> _unbuiltEveryLevel(
  Scene scene,
  List<RenderView> views,
  ui.Size size,
) => [
  for (final draw in scene.unbuiltPipelines(
    views,
    size: size,
    everyLevel: true,
  ))
    (draw.node.name, draw.pass),
];

List<RenderView> _wholeScene() => [
  RenderView(
    camera: OrthographicCamera(
      projection: OrthographicProjection.bounds(
        left: -1e6,
        right: 1e6,
        bottom: -1e6,
        top: 1e6,
        near: -1e6,
        far: 1e6,
      ),
      position: Vector3.zero(),
      target: Vector3(0, 0, 1),
    ),
  ),
];

List<RenderView> _viewFrom(double distance) => [
  RenderView(
    camera: PerspectiveCamera(
      position: Vector3(0, 0, distance),
      target: Vector3.zero(),
      fovRadiansY: math.pi / 4,
    ),
  ),
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

  test('a node hidden at a query is not listed, and showing it in place, '
      'showing a primitive, moving its layers or swapping a material moves '
      'sceneDrawRevision while a set to the same value does not', () async {
    final scene = await _scene();
    final box = _box('box')..visible = false;
    scene.add(box);
    final views = [RenderView(camera: _camera())];
    expect(_unbuilt(scene, views, _square), isEmpty);

    var at = sceneDrawRevision;
    box.visible = false;
    expect(sceneDrawRevision, at);
    box.visible = true;
    expect(sceneDrawRevision, greaterThan(at));
    expect(_unbuilt(scene, views, _square), [('box', ScenePipelinePass.color)]);

    final primitive = box.mesh!.primitives.single;
    at = sceneDrawRevision;
    primitive
      ..visible = true
      ..material = primitive.material;
    box.layers = box.layers;
    expect(sceneDrawRevision, at);
    primitive.visible = false;
    expect(sceneDrawRevision, greaterThan(at));
    at = sceneDrawRevision;
    primitive.material = UnlitMaterial();
    expect(sceneDrawRevision, greaterThan(at));
    at = sceneDrawRevision;
    box.layers = 2;
    expect(sceneDrawRevision, greaterThan(at));
  });

  test('a node\'s shadow mode or light channels, a primitive\'s shadow '
      'opt-out, a material a new mesh swaps in, an alpha mode, an opacity and '
      'a dropped pipeline each move sceneDrawRevision, while a set to the '
      'same value or a colour that keeps the opacity does not', () async {
    final scene = await _scene();
    final lit = PhysicallyBasedMaterial();
    final box = _box('box', material: lit);
    scene.add(box);
    final primitive = box.mesh!.primitives.single;
    final unlit = UnlitMaterial();

    var at = sceneDrawRevision;
    box
      ..shadowCastingMode = box.shadowCastingMode
      ..lightChannelMask = box.lightChannelMask;
    primitive.castsShadow = primitive.castsShadow;
    unlit.alphaMode = unlit.alphaMode;
    lit
      ..alphaMode = lit.alphaMode
      ..baseColorFactor = Vector4(0.2, 0.4, 0.6, 1);
    box.mesh = Mesh.primitives(primitives: [primitive]);
    expect(sceneDrawRevision, at);

    void moves(String change, void Function() apply) {
      final before = sceneDrawRevision;
      apply();
      expect(sceneDrawRevision, greaterThan(before), reason: change);
    }

    moves('shadow mode', () => box.shadowCastingMode = ShadowCastingMode.off);
    moves('light channels', () => box.lightChannelMask = 1);
    moves('primitive shadow', () => primitive.castsShadow = false);
    moves('unlit alpha mode', () => unlit.alphaMode = AlphaMode.blend);
    moves('lit alpha mode', () => lit.alphaMode = AlphaMode.mask);
    moves('lit opacity', () {
      lit
        ..alphaMode = AlphaMode.opaque
        ..baseColorFactor = Vector4(1, 1, 1, 0.5);
    });
    moves(
      'swapped material',
      () => box.mesh = Mesh.primitives(
        primitives: [MeshPrimitive(primitive.geometry, unlit)],
      ),
    );
    moves('dropped pipeline', _forgetMeshPipelines);
    at = sceneDrawRevision;
    lit.baseColorFactor = Vector4(1, 0, 0, 0.25);
    expect(sceneDrawRevision, at);
  });

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
    expect(
      _unbuilt(scene, views, _square),
      unorderedEquals([
        ('lit', ScenePipelinePass.color),
        ('lit', ScenePipelinePass.shadow),
      ]),
    );
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);

    sun.castsShadow = false;
    expect(_unbuilt(scene, views, _square), isEmpty);
  });

  test('turning a sun\'s shadows on lists a caster whose color pipeline '
      'stays the same for the shadow pass, and a warm-up builds it', () async {
    final scene = await _scene();
    final sun = DirectionalLight(direction: Vector3(0, -1, -0.2));
    scene.directionalLight = sun;
    scene.add(_box('ground', material: UnlitMaterial()));
    final views = [RenderView(camera: _camera())];
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);

    sun.castsShadow = true;
    expect(_unbuilt(scene, views, _square), [
      ('ground', ScenePipelinePass.shadow),
    ]);
    final before = scenePipelinesBuilt;
    await scene.warmUp(views, size: _square);
    expect(scenePipelinesBuilt, greaterThan(before));
    expect(_unbuilt(scene, views, _square), isEmpty);
  });

  test('only a caster the shadow pass draws is listed for it, not one that '
      'casts no shadow, a translucent one, one on a channel the sun does '
      'not cast for or one outside every cascade', () async {
    final scene = await _scene();
    final sun = DirectionalLight(direction: Vector3(0, -1, -0.2))
      ..castsShadow = true
      ..shadowCasterChannelMask = 1;
    scene.directionalLight = sun;
    final unlit = UnlitMaterial();
    final translucent = UnlitMaterial()..alphaMode = AlphaMode.blend;
    scene
      ..add(_box('caster', material: unlit))
      ..add(_box('silent', material: unlit)..castsShadows = false)
      ..add(_box('glass', material: translucent))
      ..add(_box('channel', material: unlit)..lightChannelMask = 2)
      ..add(_box('far', at: Vector3(0, 0, -4000), material: unlit));
    final views = [RenderView(camera: _camera())];

    expect(
      _unbuilt(
        scene,
        views,
        _square,
      ).where((draw) => draw.$2 == ScenePipelinePass.shadow),
      [('caster', ScenePipelinePass.shadow)],
    );
  });

  test('a shadow-casting spot lists the casters in its cone for the shadow '
      'pass', () async {
    final scene = await _scene();
    scene.add(_box('ground', material: UnlitMaterial()));
    final views = [RenderView(camera: _camera())];
    await scene.warmUp(views, size: _square);
    expect(_unbuilt(scene, views, _square), isEmpty);

    scene.add(
      Node(name: 'spot', localTransform: Matrix4.translation(Vector3(0, 5, 0)))
        ..addComponent(
          SpotLightComponent(
            SpotLight(direction: Vector3(0, -1, 0), castsShadow: true),
          ),
        ),
    );
    expect(_unbuilt(scene, views, _square), [
      ('ground', ScenePipelinePass.shadow),
    ]);
  });

  test('a level a closer camera selects is listed through a view of the '
      'whole scene with every level, and that query keeps the level the '
      'node selected last', () async {
    final scene = await _scene();
    scene.add(
      Node(name: 'lod')..addComponent(
        LodComponent([
          LodLevel(
            geometry: CuboidGeometry(Vector3.all(1)),
            material: UnlitMaterial(),
            screenSize: 0.5,
          ),
          LodLevel(
            geometry: CuboidGeometry(Vector3.all(1)),
            material: PhysicallyBasedMaterial(),
            screenSize: 0,
          ),
        ]),
      ),
    );
    final whole = _wholeScene();
    await scene.warmUp(whole, size: _square);
    expect(_unbuilt(scene, whole, _square), isEmpty);
    expect(_unbuiltEveryLevel(scene, whole, _square), [
      ('lod', ScenePipelinePass.color),
    ]);

    final near = _viewFrom(3);
    final edge = _viewFrom(4.45);
    expect(_unbuilt(scene, near, _square), [('lod', ScenePipelinePass.color)]);
    _unbuiltEveryLevel(scene, whole, _square);
    expect(_unbuilt(scene, edge, _square), [('lod', ScenePipelinePass.color)]);
    _unbuilt(scene, whole, _square);
    expect(_unbuilt(scene, edge, _square), isEmpty);
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

  test('a draw whose pipelines are built is not culled per cell by '
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
    const untouched = [1, 1, 0];
    item.visibleInstanceRanges = untouched;

    expect(_unbuilt(scene, views, _square), isEmpty);
    expect(item.visibleInstanceRanges, same(untouched));
  });

  test('a static caster only a far cascade takes, added while the cached '
      'static tiles refresh one cascade a frame, is built by the warm-up, '
      'so no later frame builds a pipeline', () async {
    final scene = await _scene();
    final sun = DirectionalLight(direction: Vector3(0, -1, -0.2))
      ..castsShadow = true
      ..cacheStaticShadows = true;
    scene.directionalLight = sun;
    scene.add(_box('near', at: Vector3(0, 0, 5))..shadowStatic = true);
    final views = [RenderView(camera: _distanceCamera())];
    await scene.warmUp(views, size: _wide);
    for (var i = 0; i < 4; i++) {
      _frame(scene, views, _wide);
    }
    _forgetMaskedShadowPipelines();
    scene.add(
      Node(
        name: 'far',
        localTransform: Matrix4.translation(Vector3(0, 0, -80)),
        mesh: Mesh(
          CuboidGeometry(Vector3.all(4)),
          PhysicallyBasedMaterial()..alphaMode = AlphaMode.mask,
        ),
      )..shadowStatic = true,
    );
    expect(
      _unbuilt(scene, views, _wide),
      contains(('far', ScenePipelinePass.shadow)),
    );

    await scene.warmUp(views, size: _wide);
    expect(_unbuilt(scene, views, _wide), isEmpty);
    final built = <int>[];
    for (var i = 0; i < 4; i++) {
      final before = scenePipelinesBuilt;
      _frame(scene, views, _wide);
      built.add(scenePipelinesBuilt - before);
    }
    expect(built, everyElement(0));
  });

  test('a caster beyond every cascade is listed only while cached static '
      'tiles may cover it, and a warm-up builds it', () async {
    final scene = await _scene();
    final direction = Vector3(0, -1, -0.2)..normalize();
    final sun = DirectionalLight(direction: direction)
      ..castsShadow = true
      ..cacheStaticShadows = true;
    scene.directionalLight = sun;
    final camera = _distanceCamera();
    scene.add(_box('near', at: Vector3(0, 0, 5)));
    final views = [RenderView(camera: camera)];
    await scene.warmUp(views, size: _wide);
    final last = sun
        .computeCascades(camera, _wide.width / _wide.height, direction)
        .last;
    _forgetMaskedShadowPipelines();
    scene.add(
      Node(
        name: 'band',
        localTransform: Matrix4.translation(
          last.center! + Vector3(1.2 * last.radius, 0, 0),
        ),
        mesh: Mesh(
          CuboidGeometry(Vector3.all(0.5)),
          PhysicallyBasedMaterial()..alphaMode = AlphaMode.mask,
        ),
      ),
    );
    expect(
      _unbuilt(
        scene,
        views,
        _wide,
      ).where((draw) => draw.$2 == ScenePipelinePass.shadow),
      isEmpty,
    );

    scene.add(_box('static', at: Vector3(0, 0, 4))..shadowStatic = true);
    expect(
      _unbuilt(scene, views, _wide),
      contains(('band', ScenePipelinePass.shadow)),
    );
    await scene.warmUp(views, size: _wide);
    expect(_unbuilt(scene, views, _wide), isEmpty);
  });
}
