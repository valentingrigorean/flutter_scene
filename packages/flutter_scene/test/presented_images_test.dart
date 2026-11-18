// Covers the images a screen view hands to a canvas: the scene keeps the
// newest few of each view, and a frame a presenting target shows in place of
// the screen views ages them as a canvas frame does.
// GPU-gated; rendering a frame needs a device.

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

const _region = ui.Rect.fromLTWH(0, 0, 32, 32);

Node _cube() =>
    Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial()));

ui.Image _image() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint());
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  return image;
}

void _render(Scene scene, {RenderTexture? into}) {
  final recorder = ui.PictureRecorder();
  try {
    scene.renderViews(
      [
        RenderView(
          camera: PerspectiveCamera(position: Vector3(0, 0, 5)),
          target: into,
        ),
      ],
      ui.Canvas(recorder),
      region: _region,
      pixelRatio: 1.0,
    );
  } finally {
    recorder.endRecording().dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!gpuAvailable()) {
    test(
      'presented images suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  // A scene that hands the canvas an image of its own for each frame, the
  // images in the order it made them.
  Future<(Scene, List<ui.Image>)> sceneOnCanvas(WidgetTester tester) async {
    await tester.runAsync(Scene.initializeStaticResources);
    final handed = <ui.Image>[];
    final scene = Scene()
      ..add(_cube())
      // Every frame renders, so each hands the canvas a new image.
      ..maxGpuFramesInFlight = 0
      ..frameImageOf = (frame, viewIndex) {
        final image = _image();
        handed.add(image);
        return image;
      };
    addTearDown(scene.dispose);
    return (scene, handed);
  }

  List<bool> disposed(List<ui.Image> images) => [
    for (final image in images) image.debugDisposed,
  ];

  testWidgets('a screen view keeps the three newest images it handed to the '
      'canvas', (tester) async {
    final (scene, handed) = await sceneOnCanvas(tester);
    for (var frame = 0; frame < 5; frame++) {
      _render(scene);
    }
    expect(disposed(handed), [true, true, false, false, false]);
  });

  testWidgets('each frame a presenting target shows in place of the screen '
      'view disposes the oldest image the view kept', (tester) async {
    final (scene, handed) = await sceneOnCanvas(tester);
    for (var frame = 0; frame < 3; frame++) {
      _render(scene);
    }
    expect(disposed(handed), [false, false, false]);

    final presenter = RenderTexture(width: 32, height: 32, presents: true);
    _render(scene, into: presenter);
    expect(disposed(handed), [true, false, false]);
    _render(scene, into: presenter);
    expect(disposed(handed), [true, true, false]);
    _render(scene, into: presenter);
    expect(disposed(handed), [true, true, true]);
    // The view keeps none, so a further frame disposes nothing twice.
    _render(scene, into: presenter);
    expect(handed, hasLength(3));

    // A frame back on the canvas keeps its image.
    _render(scene);
    expect(disposed(handed), [true, true, true, false]);
  });

  testWidgets('a frame into a target that presents nothing leaves the images '
      'a screen view kept', (tester) async {
    final (scene, handed) = await sceneOnCanvas(tester);
    for (var frame = 0; frame < 3; frame++) {
      _render(scene);
    }
    final capture = RenderTexture(width: 32, height: 32);
    for (var frame = 0; frame < 3; frame++) {
      _render(scene, into: capture);
    }
    expect(disposed(handed), [false, false, false]);
  });
}
