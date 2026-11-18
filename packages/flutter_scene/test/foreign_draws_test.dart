// The app's own draws into the scene's item set ([ForeignDraws]): the scene
// calls them in the depth prepass, at each cached static shadow tile it
// renders, and among its color draws at the app's render orders, after
// every draw of the scene of that order or a lower one, on the plain path
// and on the path that splits the color pass. The view blocks of the
// prepass and of a static tile refresh are packed under the state of the
// pass's own kept draw.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

// Logs its name each time the color pass encodes a draw of it, which it
// does every frame: the material is never kept.
class _Logged extends UnlitMaterial {
  _Logged(this.name, this.log, Vector4 color) {
    baseColorFactor = color;
    if (color.w < 1) alphaMode = AlphaMode.blend;
  }

  final String name;
  final List<String> log;

  @override
  bool get colorRetainable => false;

  @override
  bool get participatesInDebugViews => false;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    log.add(name);
    super.bind(pass, transientsBuffer, lighting);
  }
}

class _Split extends CustomRenderPass {
  @override
  String get name => 'split';

  @override
  double get beforeRenderOrder => 1;

  @override
  RenderStage get stage => RenderStage.afterOpaqueScene;

  @override
  bool get drawsInPlace => true;

  @override
  void execute(RenderPassContext context) {}
}

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);

Node _slab(String name, List<String> log, double order, {double alpha = 1}) =>
    Node(
      mesh: Mesh(
        CuboidGeometry(Vector3(100, 100, 0.01)),
        _Logged(name, log, Vector4(0, 1, 0, alpha)),
      ),
      localTransform: Matrix4.translationValues(0, 0, -50 - order),
    )..renderOrder = order;

void _frame(Scene scene, {Camera? camera}) {
  final recorder = ui.PictureRecorder();
  scene.render(
    camera ?? _camera,
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
    pixelRatio: 1.0,
  );
  recorder.endRecording().dispose();
}

// Draws nothing and logs each site it is called at.
ForeignDraws _logging(
  List<String> log, {
  bool Function()? castsStaticShadows,
  int Function(Matrix4)? staticSignatureIn,
}) => ForeignDraws(
  draw: (site) {
    log.add(switch (site.kind) {
      ForeignSiteKind.opaque ||
      ForeignSiteKind.translucent => '${site.kind.name} ${site.order}',
      ForeignSiteKind.cascade ||
      ForeignSiteKind.staticTile => '${site.kind.name} ${site.cascade}',
      ForeignSiteKind.prepass => site.kind.name,
    });
    expect(
      ForeignDraws.firstPass + ForeignDraws.passes,
      64,
      reason: 'the last indices of the set',
    );
    return null;
  },
  opaqueOrders: [2, -3],
  translucentOrders: [0],
  castsStaticShadows: castsStaticShadows,
  staticSignatureIn: staticSignatureIn,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the app draws in the prepass and at each of its color orders, after '
      'every draw of the scene of that order or a lower one', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final log = <String>[];
    // Every frame renders: none waits on the GPU's pacing.
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..add(_slab('cover', log, -4))
      ..add(_slab('wall', log, 0))
      ..add(_slab('glass', log, 0, alpha: 0.5));
    scene.ambientOcclusion.enabled = true;
    scene.foreignDraws = _logging(log);
    addTearDown(scene.dispose);

    _frame(scene);
    expect(log, [
      'prepass',
      'cover',
      'opaque -3.0',
      'wall',
      'opaque 2.0',
      'glass',
      'translucent 0.0',
    ]);

    // Kept draws of the same orders: each order of the app's still draws
    // once a frame.
    final kept = Scene()
      ..maxGpuFramesInFlight = 0
      ..add(
        Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial()))
          ..renderOrder = -4,
      )
      ..add(Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial())));
    kept.ambientOcclusion.enabled = true;
    kept.foreignDraws = _logging(log);
    addTearDown(kept.dispose);
    for (var frame = 0; frame < 3; frame++) {
      log.clear();
      _frame(kept);
      expect(log, [
        'prepass',
        'opaque -3.0',
        'opaque 2.0',
        'translucent 0.0',
      ], reason: 'frame $frame');
    }
  });

  test('a split color pass draws the app\'s translucent order left after '
      'its last translucent batch', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final log = <String>[];
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..add(_slab('wall', log, 0))
      ..add(_slab('glass', log, 0, alpha: 0.5))
      ..addRenderPass(_Split());
    scene.foreignDraws = _logging(log);
    addTearDown(scene.dispose);

    _frame(scene);
    expect(log, [
      'opaque -3.0',
      'wall',
      'opaque 2.0',
      'glass',
      'translucent 0.0',
    ]);
  });

  test('the static shadow cache holds the app\'s static casters: a cascade '
      'is drawn only when its cached tile is rendered, and again once the '
      'app\'s fingerprint in it changes', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final log = <String>[];
    var signature = 1;
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..directionalLight = DirectionalLight(castsShadow: true)
      ..add(_slab('wall', [], 0));
    scene.foreignDraws = _logging(
      log,
      castsStaticShadows: () => true,
      staticSignatureIn: (_) => signature,
    );
    addTearDown(scene.dispose);

    _frame(scene);
    final tiles = log.where((site) => site.startsWith('staticTile')).toList();
    expect(tiles, isNotEmpty);
    expect(log.where((site) => site.startsWith('cascade')), isEmpty);

    log.clear();
    _frame(scene);
    expect(log.where((site) => site.startsWith('staticTile')), isEmpty);

    signature = 2;
    scene.markForeignShadowCastersChanged();
    log.clear();
    _frame(scene);
    expect(log.where((site) => site.startsWith('staticTile')), isNotEmpty);

    // With no static caster of its own or the app's, no cache: every
    // cascade draws every frame.
    scene.foreignDraws = _logging(log);
    log.clear();
    _frame(scene);
    expect(log.where((site) => site.startsWith('cascade')).toList(), [
      for (var c = 0; c < tiles.length; c++) 'cascade $c',
    ]);
  });

  test('the prepass of a view that keeps no draw and a static tile refresh '
      'with no static caster of the scene\'s hand the app the ViewInfo of '
      'their own kept draw, not the last color draw\'s', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final camera = PerspectiveCamera(
      position: Vector3(3, 4, 10),
      target: Vector3(3, 4, 0),
      up: Vector3(0, 1, 0),
      fovNear: 0.1,
      fovFar: 1000,
    );
    final views = <ForeignSiteKind, Float32List>{};
    var signature = 1;
    final wall = _slab('wall', [], 0);
    wall.castsShadows = false;
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..directionalLight = DirectionalLight(castsShadow: true)
      ..add(wall);
    // The prepass writes normals for reflections, so it keeps no draw.
    scene.screenSpaceReflections.enabled = true;
    scene.foreignDraws = ForeignDraws(
      draw: (site) {
        views[site.kind] = Float32List.fromList(
          Float32List.sublistView(site.viewBlocks[0]),
        );
        return null;
      },
      castsStaticShadows: () => true,
      staticSignatureIn: (_) => signature,
    );
    addTearDown(scene.dispose);

    // The second frame's sites follow the first frame's color draws.
    _frame(scene, camera: camera);
    signature = 2;
    scene.markForeignShadowCastersChanged();
    views.clear();
    _frame(scene, camera: camera);

    void expectView(ForeignSiteKind kind, DepthRaster raster) {
      final view = views[kind];
      expect(view, isNotNull, reason: '$kind');
      expect(view!.sublist(16, 19), [3, 4, 10], reason: '$kind position');
      expect(view.sublist(20, 24), [0, 0, 0, 0], reason: '$kind forward');
      expect(view.sublist(32, 35), [
        raster.stepScale,
        raster.stepClip,
        0,
      ], reason: '$kind depth unit');
    }

    // The view rasterizes reversed float depth, as the frame's log states.
    expectView(
      ForeignSiteKind.prepass,
      const DepthRaster(reversed: true, floatDepth: true),
    );
    expectView(ForeignSiteKind.staticTile, DepthRaster.standard);
  });
}
