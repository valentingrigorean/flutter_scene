// Scene.viewDraws visits the nodes a view's color pass draws with the draws
// their items submit, culled as the encoder culls them.

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

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
const _size = ui.Size(64, 64);

class _Encoded extends UnlitMaterial {
  @override
  bool get colorRetainable => false;

  @override
  bool get participatesInDebugViews => false;
}

Node _box(String name, Vector3 at) => Node(
  name: name,
  mesh: Mesh(CuboidGeometry(Vector3.all(2)), _Encoded()),
  localTransform: Matrix4.translation(at),
);

Node _instances(String name, Vector3 at) => Node(name: name)
  ..addComponent(
    InstancedMeshComponent(
      InstancedMesh(
        geometry: CuboidGeometry(Vector3.all(2)),
        material: _Encoded(),
        cullInstances: true,
      )..addInstance(Matrix4.translation(at)),
    ),
  );

Map<String, int> _viewDraws(Scene scene, List<RenderView> views) {
  final draws = <String, int>{};
  scene.viewDraws(
    views,
    size: _size,
    visit: (node, count) => draws[node.name] = (draws[node.name] ?? 0) + count,
  );
  return draws;
}

Future<RenderCounters> _colorPass(Scene scene, List<RenderView> views) async {
  final recorder = ui.PictureRecorder();
  scene.renderViews(views, ui.Canvas(recorder), region: ui.Offset.zero & _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.round(),
    _size.height.round(),
  );
  picture.dispose();
  await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final passes = scene.renderStats.latest!.views.single.passes;
  return passes.singleWhere((pass) => pass.name == 'ScenePass').counters;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test(
      'view draws (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device: --enable-impeller --enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(Scene.initializeStaticResources);

  test('a view counts the nodes its color pass draws, leaving out a node '
      'behind it, an instanced set whose cells it does not see and a node '
      'outside its layer mask, as many as the pass submits', () async {
    final scene = Scene()
      ..add(_box('ahead', Vector3(0, 0, -10)))
      ..add(_box('behind', Vector3(0, 0, 10)))
      ..add(_instances('seen', Vector3(0, 0, -10)))
      ..add(_instances('unseen', Vector3(0, 0, 10)))
      ..add(_box('masked', Vector3(0, 0, -12))..layers = 2);
    addTearDown(scene.dispose);
    final views = [RenderView(camera: _camera, layerMask: 1)];

    final draws = _viewDraws(scene, views);
    expect(draws, {'ahead': 1, 'seen': 1});

    final counters = await _colorPass(scene, views);
    expect(
      counters.submitted - counters.culled - counters.layerMasked,
      draws.values.fold(0, (sum, count) => sum + count),
    );
  });
}
