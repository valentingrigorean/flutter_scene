// A geometry that binds no model-transform instance: its draws still join
// one instanced draw, and an anchored draw states the world transform its
// record would carry.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/instance_packing.dart'
    show kInstanceRecordFloats;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

const int _members = 3;

// Binds, with its streams, identity records for every member, as a geometry
// with its own record path binds what its vertex stage reads.
class _OwnRecordsQuad extends MeshGeometry {
  _OwnRecordsQuad({this.key})
    : super.fromArrays(
        positions: Float32List.fromList([
          -1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0, //
        ]),
        indices: const [0, 1, 2, 0, 2, 3],
      );

  final Object? key;
  int packed = 0;
  final List<Matrix4?> worldTransforms = [];

  late final gpu.BufferView _identity = () {
    final records = Float32List(kInstanceRecordFloats * _members);
    for (var member = 0; member < _members; member++) {
      final at = member * kInstanceRecordFloats;
      records
        ..setAll(at, Matrix4.identity().storage)
        ..fillRange(at + 16, at + kInstanceRecordFloats, 1);
    }
    final bytes = ByteData.sublistView(records);
    return gpu.BufferView(
      gpu.gpuContext.createDeviceBufferWithCopy(bytes),
      offsetInBytes: 0,
      lengthInBytes: bytes.lengthInBytes,
    );
  }();

  @override
  bool get bindsModelTransformInstance => false;

  @override
  ({gpu.Shader shader, VertexLayoutDescriptor layout})? get depthOnlyVertex =>
      null;

  @override
  Object? instanceBatchKey(Matrix4 modelTransform) => key;

  @override
  void packInstanceBatchMember(Float32List records, int at) => packed++;

  @override
  void bindGeometryBuffers(gpu.RenderPass pass) {
    super.bindGeometryBuffers(pass);
    worldTransforms.add(currentDrawWorldTransform?.clone());
    pass.bindVertexBuffer(_identity, slot: vertexStreamCount);
  }
}

Future<List<CapturedDraw>> _drawsOf(Scene scene) async {
  Scene.debugAllowRenderGraphCapture = true;
  final capture = scene.captureRenderGraph(
    request: const RenderGraphCaptureRequest(captureImages: false),
  );
  final recorder = ui.PictureRecorder();
  scene.render(
    PerspectiveCamera(position: Vector3(0, 0, 5)),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, 64, 64),
    pixelRatio: 1.0,
  );
  recorder.endRecording();
  final result = await capture;
  return result.passes
      .singleWhere((pass) => pass.name == 'ScenePass')
      .draws
      .where((draw) => draw.nodePath?.contains('quad') ?? false)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('draws of a geometry that binds no model-transform instance join one '
      'instanced draw', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final geometry = _OwnRecordsQuad(key: 'quad');
    final material = UnlitMaterial();
    final scene = Scene();
    for (var member = 0; member < _members; member++) {
      scene.add(
        Node(
          name: 'quad$member',
          localTransform: Matrix4.translation(Vector3(member - 1.0, 0, 0)),
          mesh: Mesh(geometry, material),
        ),
      );
    }
    final draws = await _drawsOf(scene);
    expect(draws.map((draw) => draw.instanceCount), [_members]);
    expect(geometry.packed, _members);
  });

  test(
    'an anchored draw states the world transform without the anchor',
    () async {
      if (!gpuAvailable()) return;
      await Scene.initializeStaticResources();
      final geometry = _OwnRecordsQuad();
      final node = Node(
        name: 'quad',
        localTransform: Matrix4.translation(Vector3(0, 0.25, 0)),
        mesh: Mesh(geometry, UnlitMaterial()),
      )..setAnchor(0.5);
      final scene = Scene()..add(node);
      expect(await _drawsOf(scene), isNotEmpty);
      expect(geometry.worldTransforms, isNotEmpty);
      for (final transform in geometry.worldTransforms) {
        expect(transform, node.globalTransform);
      }
    },
  );
}
