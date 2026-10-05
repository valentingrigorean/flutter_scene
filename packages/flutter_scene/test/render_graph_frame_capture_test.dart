// Covers Scene.captureFrameRenderGraphs: one capture for each view a frame
// renders, texture views first, and its exclusion with captureRenderGraph;
// and the static shadow tiles a captured frame re-renders.
// GPU-gated; rendering a frame needs a device.

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

Scene _shadowedScene() => Scene()
  ..directionalLight = DirectionalLight(castsShadow: true)
  ..add(
    Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial()))
      ..shadowStatic = true,
  );

class _ThrowingPass extends CustomRenderPass {
  @override
  String get name => 'Throwing';

  @override
  RenderStage get stage => RenderStage.afterScene;

  @override
  void execute(RenderPassContext context) => throw StateError('view render');
}

void _renderViews(Scene scene, List<RenderView> views) {
  final recorder = ui.PictureRecorder();
  try {
    scene.renderViews(
      views,
      ui.Canvas(recorder),
      region: const ui.Rect.fromLTWH(0, 0, 32, 32),
      pixelRatio: 1,
    );
  } finally {
    recorder.endRecording().dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'frame render graph capture suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  setUp(() => Scene.debugAllowRenderGraphCapture = true);
  tearDown(() => Scene.debugAllowRenderGraphCapture = false);

  test('a frame capture holds every view the frame renders', () async {
    await Scene.initializeStaticResources();
    final scene = _shadowedScene();
    final texture = RenderTexture(width: 16, height: 8);
    addTearDown(() {
      scene.dispose();
      texture.dispose();
    });
    final camera = PerspectiveCamera(position: Vector3(0, 4, 6));
    final views = [
      RenderView(camera: camera),
      RenderView(
        camera: PerspectiveCamera(position: Vector3(0, 4, 6), fovNear: 0.01),
        order: 1,
      ),
      RenderView(camera: camera, target: texture),
    ];

    final capture = scene.captureFrameRenderGraphs(
      request: const RenderGraphCaptureRequest(captureImages: false),
    );
    _renderViews(scene, views);
    final captured = await capture;

    expect(
      [for (final view in captured) (view.pixelWidth, view.pixelHeight)],
      [(16, 8), (32, 32), (32, 32)],
    );
    for (final view in captured) {
      expect(view.passes.map((pass) => pass.name), contains('ShadowPass'));
    }
  });

  test(
    'a capture lists each static shadow tile its frame re-renders',
    () async {
      await Scene.initializeStaticResources();
      final scene = _shadowedScene();
      addTearDown(scene.dispose);
      final views = [
        RenderView(camera: PerspectiveCamera(position: Vector3(0, 4, 6))),
      ];
      Future<List<String>> refreshedTiles() async {
        final capture = scene.captureRenderGraph(
          request: const RenderGraphCaptureRequest(captureImages: false),
        );
        _renderViews(scene, views);
        return [
          for (final resource in (await capture).resources)
            if (resource.key.startsWith('static_shadow_tile_')) resource.key,
        ];
      }

      final first = await refreshedTiles();
      final cascades = scene.debugStaticShadowTiles.length;
      expect(cascades, greaterThan(0));
      expect(first, [
        for (var cascade = 0; cascade < cascades; cascade++)
          'static_shadow_tile_$cascade',
      ]);
      expect(await refreshedTiles(), isEmpty);

      scene.directionalLight!.invalidateStaticShadows();
      expect(await refreshedTiles(), first);
    },
  );

  test('a frame capture and a view capture supersede each other', () async {
    await Scene.initializeStaticResources();
    final scene = _shadowedScene();
    addTearDown(scene.dispose);
    final views = [
      RenderView(camera: PerspectiveCamera(position: Vector3(0, 4, 6))),
    ];

    final view = scene.captureRenderGraph();
    final frame = scene.captureFrameRenderGraphs();
    await expectLater(view, throwsStateError);
    final later = scene.captureRenderGraph();
    await expectLater(frame, throwsStateError);
    _renderViews(scene, views);
    expect((await later).passes, isNotEmpty);
  });

  test('a frame capture fails when a view render throws', () async {
    await Scene.initializeStaticResources();
    final scene = _shadowedScene()..addRenderPass(_ThrowingPass());
    addTearDown(scene.dispose);
    final views = [
      RenderView(camera: PerspectiveCamera(position: Vector3(0, 4, 6))),
    ];

    final capture = scene.captureFrameRenderGraphs(
      timeout: const Duration(milliseconds: 50),
    );
    expect(() => _renderViews(scene, views), throwsStateError);

    await expectLater(capture, throwsStateError);
  });

  test('dispose fails a pending frame capture', () async {
    final scene = _shadowedScene();
    final capture = scene.captureFrameRenderGraphs();

    scene.dispose();

    await expectLater(
      capture,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('disposed'),
        ),
      ),
    );
  });
}
