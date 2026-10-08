// Translucent draw order tests. A node's sortDepthBias moves its draws in the
// encoder's back-to-front sort and leaves its bounds, cull and picking alone;
// sceneTranslucentDraws reads that order before a frame draws, and a frame
// draws its translucent meshes in the order it reads.

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubGeometry extends Geometry {
  _StubGeometry(Aabb3 aabb) {
    setLocalBounds(
      aabb,
      Sphere.centerRadius(
        (aabb.min + aabb.max) * 0.5,
        ((aabb.max - aabb.min) * 0.5).length,
      ),
    );
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
  _StubMaterial({this.opaque = false, this.empty = false});

  final bool opaque;
  final bool empty;

  @override
  bool isOpaque() => opaque;

  @override
  bool get drawsNothing => empty;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    throw UnsupportedError('Stub material is not renderable');
  }
}

class _RecordingMaterial extends UnlitMaterial {
  _RecordingMaterial(this.label, this.drawn) {
    alphaMode = AlphaMode.blend;
    baseColorFactor = Vector4(1, 1, 1, 0.5);
  }

  final String label;
  final List<String> drawn;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    drawn.add(label);
    super.bind(pass, transientsBuffer, lighting);
  }
}

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);
const _size = ui.Size(400, 300);

Aabb3 _slab() => Aabb3.minMax(Vector3(-10, -10, -1), Vector3(10, 10, 1));

Node _at(double distance, {Material? material, String? name, double x = 0}) =>
    Node(
      name: name ?? '',
      mesh: Mesh(_StubGeometry(_slab()), material ?? _StubMaterial()),
      localTransform: Matrix4.translationValues(x, 0, -distance),
    );

List<SceneTranslucentDraw> _drawsOf(List<Node> nodes, {int? layerMask}) {
  final root = Node();
  nodes.forEach(root.add);
  return layerMask == null
      ? sceneTranslucentDraws(root, _camera, _size)
      : sceneTranslucentDraws(root, _camera, _size, layerMask: layerMask);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a sort-depth bias comes off the view-axis depth', () {
    final depth = sceneSortDepth(
      Matrix4.translationValues(0, 0, -10),
      _slab(),
      Vector3.zero(),
      Vector3(0, 0, -1),
      bias: 4,
    );

    expect(depth, 6);
  });

  test('the translucent draws of a scene come farthest first, without an '
      'opaque, empty, hidden or masked draw or one outside the view', () {
    final hiddenPrimitive = _at(70);
    hiddenPrimitive.mesh!.primitives.single.visible = false;
    final masked = _at(80)..layers = 2;
    final outside = _at(30, x: 500);
    final kept = _at(40, x: 500, name: 'kept')..frustumCulled = false;

    final draws = _drawsOf([
      _at(50, name: 'near'),
      _at(60, material: _StubMaterial(opaque: true)),
      _at(65, material: _StubMaterial(empty: true)),
      hiddenPrimitive,
      _at(75)..visible = false,
      masked,
      outside,
      kept,
      _at(90, name: 'far'),
    ], layerMask: 1);

    expect([for (final draw in draws) draw.depth], [90, 50, 40]);
    expect([for (final draw in draws) draw.node.name], ['far', 'near', 'kept']);
    expect(draws.first.bounds!.min, _slab().min);
  });

  test('a node under a hidden parent draws nothing', () {
    final parent = Node()..visible = false;
    parent.add(_at(50));

    expect(_drawsOf([parent]), isEmpty);
  });

  test('a sort-depth bias draws a node after a nearer translucent draw while '
      'its bounds, its cull and its picking stay its own', () {
    final line = _at(50, name: 'line');
    final fill = _at(45, name: 'fill');
    final root = Node()
      ..add(line)
      ..add(fill);
    final bounds = line.combinedLocalBounds!;
    final visible = line.isVisibleTo(_camera, _size);
    List<SceneTranslucentDraw> read() =>
        sceneTranslucentDraws(root, _camera, _size);

    expect([for (final draw in read()) draw.node.name], ['line', 'fill']);

    line.sortDepthBias = 10;
    final draws = read();

    expect([for (final draw in draws) draw.node.name], ['fill', 'line']);
    expect(draws.last.depth, 40);
    expect(line.combinedLocalBounds!.min, bounds.min);
    expect(line.combinedLocalBounds!.max, bounds.max);
    expect(draws.last.bounds!.center, Vector3.zero());
    expect(line.isVisibleTo(_camera, _size), visible);
  });

  test('a node with a sort depth sorts at that depth less its bias, and a '
      'depth written for a moved camera changes no node', () {
    final depth = SortDepth(30);
    final overlay = _at(80, name: 'overlay')..sortDepth = depth;
    final root = Node()
      ..add(_at(50, name: 'near'))
      ..add(_at(90, name: 'far'))
      ..add(overlay);
    List<String> read() => [
      for (final draw in sceneTranslucentDraws(root, _camera, _size))
        '${draw.node.name} ${draw.depth}',
    ];
    final drawn = RenderScene();
    root.debugMountInto(drawn);
    drawn.runPrePass(0.016);

    expect(read(), ['far 90.0', 'near 50.0', 'overlay 30.0']);
    expect(
      [
        for (final item in drawn.items)
          if (item.sortDepth != null) item.sortDepth,
      ],
      [same(depth)],
    );

    depth.depth = 70;

    expect(drawn.runPrePass(0.016), 0);
    expect(read(), ['far 90.0', 'overlay 70.0', 'near 50.0']);

    overlay.sortDepthBias = 25;

    expect(read(), ['far 90.0', 'near 50.0', 'overlay 45.0']);
  });

  test('an instanced mesh sorts at the centre of its instances', () {
    final instanced = InstancedMesh(
      geometry: _StubGeometry(_slab()),
      material: _StubMaterial(),
    )..addInstance(Matrix4.translationValues(0, 0, -70));
    final node = Node()..addComponent(InstancedMeshComponent(instanced));

    final draws = _drawsOf([_at(50), node]);

    expect([for (final draw in draws) draw.depth], [70, 50]);
    expect(draws.first.bounds!.center, Vector3(0, 0, -70));
  });

  if (!_gpuAvailable()) {
    test(
      'a frame draws in the read order (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  test('a frame draws its translucent meshes in the order '
      'sceneTranslucentDraws reads, a biased one included', () async {
    await Scene.initializeStaticResources();
    final drawn = <String>[];
    Node box(String name, double distance, {double bias = 0}) => Node(
      name: name,
      mesh: Mesh(
        CuboidGeometry(Vector3(4, 4, 1)),
        _RecordingMaterial(name, drawn),
      ),
      localTransform: Matrix4.translationValues(0, 0, -distance),
    )..sortDepthBias = bias;
    final scene = Scene();
    for (final node in [
      box('far', 90),
      box('line', 50, bias: 10),
      box('fill', 45),
      box('near', 20),
    ]) {
      scene.add(node);
    }

    final read = [
      for (final draw in sceneTranslucentDraws(scene.root, _camera, _size))
        draw.node.name,
    ];
    final recorder = ui.PictureRecorder();
    scene.render(
      _camera,
      ui.Canvas(recorder),
      viewport: ui.Offset.zero & _size,
      pixelRatio: 1.0,
    );
    recorder.endRecording().dispose();
    scene.dispose();

    expect(read, ['far', 'fill', 'line', 'near']);
    expect(drawn, read);
  });

  test('a sort-depth bias set after a static node first draws moves its '
      'draw in the next frame of a scene that encodes every frame', () async {
    await Scene.initializeStaticResources();
    final drawn = <String>[];
    Node box(String name, double distance) => Node(
      name: name,
      mesh: Mesh(
        CuboidGeometry(Vector3(4, 4, 1)),
        _RecordingMaterial(name, drawn),
      ),
      localTransform: Matrix4.translationValues(0, 0, -distance),
    );
    final line = box('line', 50);
    final scene = Scene()..maxGpuFramesInFlight = 0;
    for (final node in [
      box('far', 90),
      line,
      box('fill', 45),
      box('near', 20),
    ]) {
      scene.add(node);
    }
    void frame() {
      final recorder = ui.PictureRecorder();
      scene.render(
        _camera,
        ui.Canvas(recorder),
        viewport: ui.Offset.zero & _size,
        pixelRatio: 1.0,
      );
      recorder.endRecording().dispose();
    }

    frame();
    expect(drawn, ['far', 'line', 'fill', 'near']);

    line.sortDepthBias = 10;
    drawn.clear();
    final read = [
      for (final draw in sceneTranslucentDraws(scene.root, _camera, _size))
        draw.node.name,
    ];
    frame();
    scene.dispose();

    expect(read, ['far', 'fill', 'line', 'near']);
    expect(drawn, read);
  });
}
