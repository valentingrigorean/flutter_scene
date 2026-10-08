// Covers the stored depth input: the probe reads back the depth a depth
// attachment stored in both camera depth formats, a pass that asks for the
// stored depth samples the attachment of the scene pass with no depth
// prepass in the frame, its terms turn a window depth into the planar view
// depth it was rasterized from, and a view that cannot sample it gets the
// linear depth in its place. GPU-gated like the other render suites.

import 'dart:ui' as ui;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/stored_depth_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

class _StoredDepthPass extends CustomRenderPass {
  gpu.Texture? stored;
  gpu.Texture? linear;
  Vector4? terms;
  Matrix4? transform;
  int runs = 0;

  @override
  String get name => 'stored depth';

  @override
  RenderStage get stage => RenderStage.afterToneMapping;

  @override
  Set<RenderInput> get inputs => const {RenderInput.depthStored};

  @override
  void execute(RenderPassContext context) {
    runs++;
    stored = context.sceneDepthStored;
    linear = context.sceneDepthLinear;
    terms = context.sceneDepthStoredTerms;
    transform = context.displayViewTransform;
  }
}

List<String> _draw(Scene scene, Camera camera) {
  final recorder = ui.PictureRecorder();
  scene.render(
    camera,
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, 64, 32),
    pixelRatio: 1.0,
  );
  recorder.endRecording().dispose();
  return [
    for (final view in scene.renderStats.latest!.views)
      for (final pass in view.passes) pass.name,
  ];
}

Scene _scene(_StoredDepthPass pass, AntiAliasingMode mode) => Scene()
  ..antiAliasingMode = mode
  ..add(
    Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), PhysicallyBasedMaterial())),
  )
  ..addRenderPass(pass);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugStoredDepthUnsampled = false);

  test('the probe reads back the depth a depth attachment stored, in both '
      'camera depth formats', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    for (final reversed in [false, true]) {
      expect(
        await measureStoredDepthRead(
          format: DepthRaster.depthStencilFormatFor(reversed: reversed),
        ),
        isTrue,
        reason: 'reversed $reversed',
      );
    }
    expect(storedDepthIsSampled, isTrue);
  });

  test('a pass that asks for the stored depth samples the depth of the scene '
      'pass, and the frame draws no depth prepass and no depth patch; its '
      'terms turn a window depth into the view depth it came from', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final pass = _StoredDepthPass();
    final camera = PerspectiveCamera(position: Vector3(0, 2, 5));
    final passes = _draw(_scene(pass, AntiAliasingMode.none), camera);

    expect(pass.runs, 1);
    expect(pass.stored, isNotNull);
    expect(pass.stored!.width, 64);
    expect(pass.stored!.height, 32);
    expect(pass.linear, isNull);
    expect(passes, isNot(contains('DepthPrepass')));
    expect(passes, isNot(contains('TranslucentDepthPatchPass')));
    final forward = camera.forward.normalized();
    for (final depth in [0.5, 3.0, 40.0, 900.0]) {
      final at = camera.position + forward * depth;
      final clip = pass.transform!.transform(Vector4(at.x, at.y, at.z, 1));
      final window = clip.z / clip.w;
      final terms = pass.terms!;
      expect(
        (terms.y - window * terms.w) / (window * terms.z - terms.x),
        closeTo(depth, depth * 2e-3),
        reason: 'view depth $depth',
      );
    }
  });

  test('a view that cannot sample the stored depth, multisampled or on a '
      'device that samples no depth attachment, gets the linear depth of '
      'the depth prepass in its place', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final camera = PerspectiveCamera(position: Vector3(0, 2, 5));

    if (gpu.gpuContext.doesSupportOffscreenMSAA) {
      final multisampled = _StoredDepthPass();
      final passes = _draw(_scene(multisampled, AntiAliasingMode.msaa), camera);
      expect(multisampled.stored, isNull);
      expect(multisampled.linear, isNotNull);
      expect(passes, contains('DepthPrepass'));
      expect(passes, contains('TranslucentDepthPatchPass'));
    }

    debugStoredDepthUnsampled = true;
    final unsampled = _StoredDepthPass();
    final passes = _draw(_scene(unsampled, AntiAliasingMode.none), camera);
    expect(unsampled.stored, isNull);
    expect(unsampled.linear, isNotNull);
    expect(passes, contains('DepthPrepass'));
  });
}
