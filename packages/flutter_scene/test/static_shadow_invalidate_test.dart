// Covers DirectionalLight.invalidateStaticShadows on a drawn scene: the
// static shadow tiles re-render into the textures they hold, while a caster
// channel change rebuilds the cache with new ones.
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

void _render(Scene scene) {
  final recorder = ui.PictureRecorder();
  try {
    scene.render(
      PerspectiveCamera(position: Vector3(0, 4, 6)),
      ui.Canvas(recorder),
      viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
    );
  } finally {
    recorder.endRecording().dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_gpuAvailable()) {
    test(
      'static shadow invalidate suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  testWidgets('invalidating the static shadows keeps the tile textures', (
    tester,
  ) async {
    await tester.runAsync(Scene.initializeStaticResources);
    final light = DirectionalLight(castsShadow: true);
    final scene = Scene()
      ..directionalLight = light
      ..add(
        Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial()))
          ..shadowStatic = true,
      );
    addTearDown(scene.dispose);
    _render(scene);
    final tiles = scene.debugStaticShadowTiles;
    expect(tiles, isNotEmpty);
    expect(tiles, everyElement(isNotNull));

    light.invalidateStaticShadows();
    _render(scene);
    expect(scene.debugStaticShadowTiles, orderedEquals(tiles));

    light.shadowCasterChannelMask ^= 0x100;
    _render(scene);
    final rebuilt = scene.debugStaticShadowTiles;
    expect(rebuilt, hasLength(tiles.length));
    for (final (index, tile) in rebuilt.indexed) {
      expect(identical(tile, tiles[index]), isFalse);
    }
  });
}
