// A debug build records a kept draw again where its owner takes it as
// current, and fails where the two differ.

import 'dart:ui' as ui;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/render/render_stats.dart'
    show RenderCounters, activeRenderCounters;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);
const _size = ui.Size(64, 64);

class _Flat extends UnlitMaterial {
  @override
  bool get participatesInDebugViews => false;
}

// Changes its color without saying so.
class _Silent extends _Flat {
  @override
  int get keptRevision => 0;
}

Node _slab(Material material) => Node(
  mesh: Mesh(CuboidGeometry(Vector3(20, 20, 0.01)), material),
  localTransform: Matrix4.translationValues(0, 0, -50),
);

Future<void> _render(Scene scene) async {
  activeRenderCounters.reset();
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera,
    ui.Canvas(recorder),
    viewport: ui.Offset.zero & _size,
    pixelRatio: 1.0,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.round(),
    _size.height.round(),
  );
  picture.dispose();
  await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!gpuAvailable()) {
    test(
      'kept draws are checked (skipped: no GPU device)',
      () {},
      skip:
          'Requires a GPU device: run with --enable-impeller '
          '--enable-flutter-gpu.',
    );
    return;
  }

  setUpAll(() async {
    await Scene.initializeStaticResources();
    final warmUp = Scene()..add(_slab(_Flat()));
    for (var frame = 0; frame < 2; frame++) {
      await _render(warmUp);
    }
    warmUp.dispose();
  });

  test('a moved draw is recorded again and counts nothing', () async {
    Future<Map<String, int>> moved() async {
      final node = _slab(_Flat());
      final scene = Scene()..add(node);
      addTearDown(scene.dispose);
      await _render(scene);
      await _render(scene);
      // The first move records the draw again as one it can place.
      for (var x = 1.0; x < 3; x++) {
        node.localTransform = Matrix4.translationValues(x, 0, -50);
        await _render(scene);
      }
      return activeRenderCounters.toJson();
    }

    var records = 0;
    final record = gpu.debugRecordKeptDrawAgain;
    addTearDown(() {
      gpu.debugChecksKeptDraws = true;
      gpu.debugRecordKeptDrawAgain = record;
    });
    gpu.debugRecordKeptDrawAgain = (again) {
      records++;
      again();
    };
    gpu.debugChecksKeptDraws = false;
    final unchecked = await moved();
    expect(records, 0);
    gpu.debugChecksKeptDraws = true;
    final checked = await moved();

    expect(records, greaterThan(0));
    expect(checked, unchecked);
  });

  test('a draw taken as the same, a moved member of a run and the changed '
      'rows of an instanced draw are recorded again and hold', () async {
    final mesh = Mesh(CuboidGeometry(Vector3(2, 2, 0.01)), _Flat());
    final first = Node(
      mesh: mesh,
      localTransform: Matrix4.translationValues(-3, 0, -50),
    );
    final second = Node(
      mesh: mesh,
      localTransform: Matrix4.translationValues(3, 0, -50),
    );
    final rows = InstancedMesh(
      geometry: CuboidGeometry(Vector3(1, 1, 0.01)),
      material: _Flat(),
    );
    for (var row = 0; row < 3; row++) {
      rows.addInstance(Matrix4.translationValues(row * 2.0, 4, -50));
    }
    // The depth prepass joins the two slabs in one run.
    final scene = Scene()
      ..depthOfField.enabled = true
      ..add(first)
      ..add(second)
      ..add(Node()..addComponent(InstancedMeshComponent(rows)));
    addTearDown(scene.dispose);
    var records = 0;
    final record = gpu.debugRecordKeptDrawAgain;
    addTearDown(() => gpu.debugRecordKeptDrawAgain = record);
    gpu.debugRecordKeptDrawAgain = (again) {
      records++;
      again();
    };
    await _render(scene);
    await _render(scene);
    records = 0;
    await _render(scene);
    final still = records;

    records = 0;
    first.markMaterialsChanged();
    await _render(scene);
    expect(records, greaterThan(still));

    // The first move records a draw again as one it can place.
    for (var y = 1.0; y < 4; y++) {
      records = 0;
      second.localTransform = Matrix4.translationValues(3, y, -50);
      await _render(scene);
    }
    expect(records, greaterThan(still));

    for (var y = 5.0; y < 8; y++) {
      records = 0;
      rows.setInstanceTransform(1, Matrix4.translationValues(2, y, -50));
      await _render(scene);
    }
    expect(records, greaterThan(still));
  });

  test('a set that keeps no items encodes each draw', () async {
    Future<RenderCounters> still() async {
      final scene = Scene()..add(_slab(_Flat()));
      addTearDown(scene.dispose);
      await _render(scene);
      await _render(scene);
      return RenderCounters()..copyFrom(activeRenderCounters);
    }

    final kept = await still();
    gpu.debugKeepsNoItems = true;
    addTearDown(() => gpu.debugKeepsNoItems = false);
    final encoded = await still();

    expect(kept.colorItemsKept, 1);
    expect(kept.draws, 0);
    expect(encoded.colorItemsKept, 0);
    expect(encoded.draws, greaterThan(0));
  });

  test('a kept draw that changed under its signature fails', () async {
    final material = _Silent();
    final scene = Scene()..add(_slab(material));
    addTearDown(scene.dispose);
    await _render(scene);
    material.baseColorFactor = Vector4(1, 0, 0, 1);
    await expectLater(
      _render(scene),
      throwsA(
        isA<gpu.KeptDrawError>()
            .having((error) => error.field, 'field', 'block UnlitInfo')
            .having((error) => error.kind, 'kind', contains('the same')),
      ),
    );
  });
}
