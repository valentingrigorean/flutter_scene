// VertexSpin and JointPalette: a mesh that turns and a skin that plays from
// Scene.animationTime in the vertex stage, with no transform and no texture
// written between frames. The Dart mirrors are the ones the shaders compute
// (shaders/vertex_spin.glsl, shaders/flutter_scene_skinned_body.glsl). The
// draws need a GPU device: flutter test --enable-impeller --enable-flutter-gpu.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/vertex_spin.dart'
    show foldedAnimationTime, kAnimationTimeFold;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

const int _width = 128;
const int _height = 64;

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

PerspectiveCamera _camera() => PerspectiveCamera(
  position: Vector3(0, 0, 10),
  target: Vector3.zero(),
  fovRadiansY: math.pi / 4,
);

Material _green() => UnlitMaterial()..baseColorFactor = Vector4(0, 1, 0, 1);

// Whether the quarter and three-quarter points of the middle row are green.
Future<({bool first, bool second})> _draw(Scene scene) async {
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera(),
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, _width + 0.0, _height + 0.0),
    pixelRatio: 1.0,
  );
  final image = await recorder.endRecording().toImage(_width, _height);
  final ByteData bytes = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  image.dispose();
  bool green(int x) {
    final offset = ((_height ~/ 2) * _width + x) * 4;
    return bytes.getUint8(offset + 1) > 128 && bytes.getUint8(offset) < 64;
  }

  return (first: green(_width ~/ 4), second: green(_width * 3 ~/ 4));
}

RenderItem _itemOf(Scene scene, Node node) => scene.renderScene.items
    .singleWhere((item) => identical(item.sourceNode, node));

// A quad of both windings over x in [-5.5, -2.5], bound wholly to joint 0.
SkinnedGeometry _skinnedQuad() {
  const corners = [
    [-5.5, -1.5],
    [-2.5, -1.5],
    [-2.5, 1.5],
    [-5.5, 1.5],
  ];
  final vertices = Float32List(4 * 26);
  for (var index = 0; index < 4; index++) {
    final at = index * 26;
    vertices
      ..[at] = corners[index][0]
      ..[at + 1] = corners[index][1]
      ..[at + 5] = 1
      ..[at + 10] = 1
      ..[at + 11] = 1
      ..[at + 12] = 1
      ..[at + 13] = 1
      ..[at + 22] = 1;
  }
  return SkinnedGeometry()..uploadVertexData(
    vertices,
    4,
    Uint16List.fromList([0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a spin is a function of the animation time', () {
    final spin = VertexSpin([
      SpinTurn(
        axis: Vector3(0, 0, 2),
        pivot: Vector3(1, 0, 0),
        turnsPerSecond: 0.5,
      ),
    ]);

    test('a turn is its rate times the seconds about its line', () {
      final quarter = spin.transformAt(0.5).transformed3(Vector3(2, 0, 0));
      expect(quarter.x, closeTo(1, 1e-9));
      expect(quarter.y, closeTo(1, 1e-9));
      final whole = spin.transformAt(2).transformed3(Vector3(2, 0, 0));
      expect(whole.x, closeTo(2, 1e-9));
      expect(whole.y, closeTo(0, 1e-9));
    });

    test('the turns apply from the last to the first, inside the space', () {
      final space = Matrix4.translation(Vector3(0, 3, 0));
      final nested = VertexSpin([
        SpinTurn(axis: Vector3(0, 0, 1), turnsPerSecond: 0.25),
        SpinTurn(
          axis: Vector3(1, 0, 0),
          pivot: Vector3(0, 3, 0),
          turnsPerSecond: 0.5,
        ),
      ], space: space);
      final expected =
          Matrix4.inverted(space) *
                  Matrix4.rotationZ(math.pi / 2) *
                  (Matrix4.translation(Vector3(0, 3, 0))
                    ..rotateX(math.pi)
                    ..translateByVector3(Vector3(0, -3, 0))) *
                  space
              as Matrix4;
      final actual = nested.transformAt(1);
      for (var index = 0; index < 16; index++) {
        expect(actual.storage[index], closeTo(expected.storage[index], 1e-9));
      }
    });

    test('the uniform folds the time and keeps the turns the whole spans '
        'before it add up to in the phase', () {
      final floats = Float32List(VertexSpin.floatCount);
      const time = 3 * kAnimationTimeFold + 0.75;
      spin.writeTo(floats, 0, time);
      expect(floats[32], closeTo(0.75, 1e-6));
      expect(floats[33], 1);
      expect(foldedAnimationTime(time), closeTo(0.75, 1e-9));
      final turns = floats[23] + floats[19] * floats[32];
      expect(
        turns - turns.floorToDouble(),
        closeTo(spin.turns.single.turnsAt(time), 1e-6),
      );
      expect(floats.sublist(24, 32), everyElement(0));
    });

    test('the cover holds the mesh at every time', () {
      final bounds = Aabb3.minMax(Vector3(2, -0.5, -0.5), Vector3(4, 0.5, 0.5));
      final cover = spin.cover(bounds);
      for (var step = 0; step < 16; step++) {
        final turned = Aabb3.copy(bounds)
          ..transform(spin.transformAt(step / 8));
        expect(
          cover.containsAabb3(turned) || cover.intersectsWithAabb3(turned),
          isTrue,
        );
        expect(cover.min.x <= turned.min.x + 1e-6, isTrue);
        expect(cover.max.x >= turned.max.x - 1e-6, isTrue);
        expect(cover.min.y <= turned.min.y + 1e-6, isTrue);
        expect(cover.max.y >= turned.max.y - 1e-6, isTrue);
      }
    });
  });

  group('a palette holds the joints of an animation by row', () {
    final palette = JointPalette(
      jointCount: 1,
      rowCount: 3,
      rowsPerSecond: 2,
      matrices: Float32List.fromList([
        ...Matrix4.identity().storage,
        ...Matrix4.translation(Vector3(8, 0, 0)).storage,
        ...Matrix4.translation(Vector3(8, 4, 0)).storage,
      ]),
    );

    test('a clip time reads the two rows either side of it', () {
      expect(palette.duration, 1);
      expect(palette.matrixAt(0, 0.25).getTranslation().x, closeTo(4, 1e-6));
      expect(palette.matrixAt(0, 0.75).getTranslation().y, closeTo(2, 1e-6));
      expect(palette.matrixAt(0, 9).getTranslation().y, closeTo(4, 1e-6));
    });

    test('a playback wraps a looping clip and holds the ends of one that '
        'does not', () {
      final root = Node();
      final looping = JointPalettePlayback(palette, root: root, offset: 0.25);
      expect(looping.clipSecondsAt(1), closeTo(0.25, 1e-9));
      expect(looping.clipSecondsAt(1.5), closeTo(0.75, 1e-9));
      final once = JointPalettePlayback(
        palette,
        root: root,
        speed: 2,
        loop: false,
      );
      expect(once.clipSecondsAt(0.25), closeTo(0.5, 1e-9));
      expect(once.clipSecondsAt(3), 1);
      final held = JointPalettePlayback(
        palette,
        root: root,
        offset: 0.5,
        speed: 0,
      );
      expect(held.clipSecondsAt(100), closeTo(0.5, 1e-9));
    });

    test('the uniform keeps the clip time of the whole spans before the '
        'folded time', () {
      final floats = Float32List(8);
      const time = 2 * kAnimationTimeFold + 0.125;
      final playback = JointPalettePlayback(
        palette,
        root: Node(),
        offset: 0.5,
        speed: 0.5,
      );
      playback.writeTo(floats, 0, time);
      final clip = floats[0] + floats[1] * floats[4];
      expect(
        clip - (clip / floats[2]).floorToDouble() * floats[2],
        closeTo(playback.clipSecondsAt(time), 1e-6),
      );
      expect(floats[3], 1);
    });
  });

  group('the vertex stage animates from the time alone', () {
    if (_gpuAvailable()) setUpAll(Scene.preload);

    test(
      'a node that spins turns its mesh with no transform written',
      () async {
        if (!_gpuAvailable()) {
          markTestSkipped('Flutter GPU is unavailable.');
          return;
        }
        final scene = Scene();
        addTearDown(scene.dispose);
        final slab = Node(
          mesh: Mesh(CuboidGeometry(Vector3(3, 2, 0.2)), _green()),
        )..position = Vector3(-4, 0, 0);
        slab.spin = VertexSpin([
          SpinTurn(axis: Vector3(0, 0, 1), turnsPerSecond: 0.5),
        ], space: slab.localTransform);
        scene.add(slab);

        final rest = await _draw(scene);
        expect(rest.first != rest.second, isTrue);
        final item = _itemOf(scene, slab);
        final revision = item.worldTransformRevision;
        final transform = slab.worldTransformVersion;

        scene.animationTime = 1;
        final turned = await _draw(scene);
        expect(turned.first, rest.second);
        expect(turned.second, rest.first);
        scene.animationTime = 2;
        expect(await _draw(scene), rest);
        expect(item.worldTransformRevision, revision);
        expect(slab.worldTransformVersion, transform);
      },
    );

    test('an instanced mesh that spins turns every row after its local '
        'transform, about a line stated in the space of the spin', () async {
      if (!_gpuAvailable()) {
        markTestSkipped('Flutter GPU is unavailable.');
        return;
      }
      final scene = Scene();
      addTearDown(scene.dispose);
      final mesh =
          InstancedMesh(
              geometry: CuboidGeometry(Vector3(3, 2, 0.2)),
              material: _green(),
              nodeSpaceInstances: true,
            )
            ..instanceLocal = Matrix4.translation(Vector3(-4, 0, 0))
            ..spin = VertexSpin([
              SpinTurn(
                axis: Vector3(0, 0, 1),
                pivot: Vector3(1, 0, 0),
                turnsPerSecond: 0.5,
              ),
            ], space: Matrix4.translation(Vector3(1, 0, 0)))
            ..addInstance(Matrix4.identity());
      scene.add(Node()..addComponent(InstancedMeshComponent(mesh)));

      final rest = await _draw(scene);
      expect(rest.first != rest.second, isTrue);
      final revision = mesh.revision;
      scene.animationTime = 1;
      final turned = await _draw(scene);
      expect(turned.first, rest.second);
      expect(turned.second, rest.first);
      expect(mesh.revision, revision);
    });

    test('a skin uploads its joints when one moved and at no other frame, and '
        'a skin that plays a palette uploads none', () async {
      if (!_gpuAvailable()) {
        markTestSkipped('Flutter GPU is unavailable.');
        return;
      }
      final scene = Scene();
      addTearDown(scene.dispose);
      final joint = Node(name: 'joint');
      final skinned = Node(
        name: 'skinned',
        mesh: Mesh(_skinnedQuad(), _green()),
      )..add(joint);
      final skin = Skin()
        ..joints.add(joint)
        ..inverseBindMatrices.add(Matrix4.identity());
      skinned.skin = skin;
      scene.add(skinned);

      final rest = await _draw(scene);
      expect(rest.first != rest.second, isTrue);
      final posed = Skin.debugUploads;
      await _draw(scene);
      scene.animationTime = 0.5;
      await _draw(scene);
      expect(Skin.debugUploads, posed);

      joint.position = Vector3(8, 0, 0);
      final moved = await _draw(scene);
      expect(Skin.debugUploads, posed + 1);
      expect(moved.first, rest.second);
      expect(moved.second, rest.first);
      joint.position = Vector3.zero();
      expect(await _draw(scene), rest);
      expect(Skin.debugUploads, posed + 2);

      final palette = JointPalette(
        jointCount: 1,
        rowCount: 2,
        rowsPerSecond: 1,
        matrices: Float32List.fromList([
          ...Matrix4.identity().storage,
          ...Matrix4.translation(Vector3(8, 0, 0)).storage,
        ]),
      );
      final baked = JointPalette.debugUploads;
      skin.play(JointPalettePlayback(palette, root: skinned, loop: false));
      scene.animationTime = 0;
      expect(await _draw(scene), rest);
      scene.animationTime = 1;
      final played = await _draw(scene);
      expect(played.first, rest.second);
      expect(played.second, rest.first);
      scene.animationTime = 7;
      expect(await _draw(scene), played);
      expect(Skin.debugUploads, posed + 2);
      expect(JointPalette.debugUploads, baked + 1);

      skin.play(null);
      expect(await _draw(scene), rest);
    });
  });
}
