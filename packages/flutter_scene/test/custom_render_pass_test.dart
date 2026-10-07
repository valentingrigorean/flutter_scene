import 'dart:ui' as ui;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/custom_render_pass.dart'
    show packPostShadowInfo;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

class _NoopPass extends CustomRenderPass {
  @override
  String get name => 'noop';
  @override
  RenderStage get stage => RenderStage.afterScene;
  @override
  void execute(RenderPassContext context) {}
}

class _DepthPass extends CustomRenderPass {
  @override
  String get name => 'depth';
  @override
  RenderStage get stage => RenderStage.beforeToneMapping;
  @override
  Set<RenderInput> get inputs => const {
    RenderInput.depth,
    RenderInput.shadowMap,
  };
  @override
  void execute(RenderPassContext context) {}
}

class _ViewCameraPass extends CustomRenderPass {
  final List<Camera> cameras = [];
  @override
  String get name => 'view camera';
  @override
  RenderStage get stage => RenderStage.afterScene;
  @override
  void execute(RenderPassContext context) => cameras.add(context.viewCamera);
}

class _AttachmentPass extends CustomRenderPass {
  _AttachmentPass(this.inputs);
  @override
  final Set<RenderInput> inputs;
  final List<(gpu.Texture?, Matrix4?)> seen = [];
  @override
  String get name => 'attachment';
  @override
  RenderStage get stage => RenderStage.afterScene;
  @override
  void execute(RenderPassContext context) =>
      seen.add((context.sceneDepthAttachment, context.sceneViewTransform));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a pass reads the camera of each view it runs for', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final pass = _ViewCameraPass();
    final scene = Scene()
      ..add(
        Node(
          mesh: Mesh(CuboidGeometry(Vector3.all(1)), PhysicallyBasedMaterial()),
        ),
      )
      ..addRenderPass(pass);
    final far = PerspectiveCamera(position: Vector3(0, 2, 5));
    final near = PerspectiveCamera(position: Vector3(0, 2, 5), fovNear: 0.5);
    final recorder = ui.PictureRecorder();
    scene.renderViews(
      [RenderView(camera: far), RenderView(camera: near, order: 1)],
      ui.Canvas(recorder),
      region: const ui.Rect.fromLTWH(0, 0, 64, 64),
      pixelRatio: 1.0,
    );
    recorder.endRecording().dispose();
    expect(pass.cameras, hasLength(2));
    expect(pass.cameras.first, same(far));
    expect(pass.cameras.last, same(near));
  });

  test('a pass that requests the depth attachment reads the scene depth '
      'and the transform the scene drew it with', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final asks = _AttachmentPass(const {RenderInput.depthAttachment});
    final skips = _AttachmentPass(const {});
    final camera = PerspectiveCamera(position: Vector3(0, 2, 5));
    for (final pass in [asks, skips]) {
      final scene = Scene()
        ..add(
          Node(
            mesh: Mesh(
              CuboidGeometry(Vector3.all(1)),
              PhysicallyBasedMaterial(),
            ),
          ),
        )
        ..addRenderPass(pass);
      final recorder = ui.PictureRecorder();
      scene.render(
        camera,
        ui.Canvas(recorder),
        viewport: const ui.Rect.fromLTWH(0, 0, 64, 32),
        pixelRatio: 1.0,
      );
      recorder.endRecording().dispose();
    }
    final (depth, transform) = asks.seen.single;
    expect(depth, isNotNull);
    expect(depth!.width, 64);
    expect(depth.height, 32);
    expect(transform, isNotNull);
    final centre = transform!.transform(Vector4(0, 0, 0, 1));
    expect((centre.x / centre.w).abs(), lessThan(1e-4));
    expect(skips.seen.single, (null, null));
  });

  test(
    'CustomRenderPass.inputs defaults to empty; declared inputs surface',
    () {
      expect(_NoopPass().inputs, isEmpty);
      expect(_DepthPass().inputs, {RenderInput.depth, RenderInput.shadowMap});
    },
  );

  test('packPostShadowInfo matches the PostShadowInfo std140 layout', () {
    final c0 = ShadowCascade(
      lightSpaceMatrix: Matrix4.identity()..scaleByDouble(2.0, 3.0, 4.0, 1.0),
      splitDistance: 10.0,
      boxSize: 5.0,
    );
    final c1 = ShadowCascade(
      lightSpaceMatrix: Matrix4.zero(),
      splitDistance: 40.0,
      boxSize: 20.0,
    );
    final bytes = packPostShadowInfo(
      [c0, c1],
      Vector3(0.0, -1.0, 0.0),
      Vector3(1.0, 0.9, 0.8),
    );
    final f = bytes.buffer.asFloat32List(bytes.offsetInBytes, 76);

    // mat4 light_space_matrix[4] at [0..63]: cascades 0 and 1, rest zero.
    expect(f.sublist(0, 16), c0.lightSpaceMatrix.storage);
    expect(f.sublist(16, 32), c1.lightSpaceMatrix.storage);
    expect(f.sublist(32, 64).every((v) => v == 0.0), isTrue);
    // vec4 cascade_splits at [64..67].
    expect(f[64], 10.0);
    expect(f[65], 40.0);
    // vec4 light_direction (xyz + count) at [68..71].
    expect([f[68], f[69], f[70], f[71]], [0.0, -1.0, 0.0, 2.0]);
    // vec4 light_color at [72..75].
    expect(f[72], closeTo(1.0, 1e-6));
    expect(f[73], closeTo(0.9, 1e-6));
    expect(f[74], closeTo(0.8, 1e-6));
  });
}
