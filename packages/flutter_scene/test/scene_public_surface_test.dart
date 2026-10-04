// An app that uploads its own mip chain, paces its frames on the renderer's
// submissions, orders its own translucent draws like the encoder or expands a
// polyline off the GPU reaches each helper through the public library. This
// file imports no `src/` library: a symbol missing from `scene.dart` fails to
// compile here.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  test('a mip chain is built from scene.dart', () {
    final List<MipLevel> chain = generateMipChain(
      Uint8List(4 * 4 * 4),
      4,
      4,
      TextureContent.color,
    );

    expect(chain.map((level) => level.width), [4, 2, 1]);
    expect(MipLevel(1, 1, Uint8List(4)).pixels, hasLength(4));
    expect(mipChainsAreSampled, isA<bool>());
    final Texture2D Function(List<MipLevel>) upload = Texture2D.fromMipLevels;
    expect(upload, isNotNull);
  });

  test('the renderer submissions are read from scene.dart', () {
    final GpuSubmissions submissions = gpuSubmissions;

    expect(
      submissions.completedThrough,
      lessThanOrEqualTo(submissions.latestSubmission),
    );
  });

  test('the encoder sort depth is read from scene.dart', () {
    final depth = sceneSortDepth(
      Matrix4.translationValues(0, 0, -10),
      Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 3)),
      Vector3.zero(),
      Vector3(0, 0, -1),
    );

    expect(depth, 9);
  });

  test('a polyline is expanded from scene.dart', () {
    final expanded = expandPolyline(
      [Vector3.zero(), Vector3(1, 0, 0)],
      widths: const [2, 2],
      widthMode: PolylineWidthMode.screenPixels,
      diskPoints: const [],
      drawStart: 0,
      drawEnd: 1,
      viewProjection: Matrix4.identity(),
      cameraPosition: Vector3(0, 0, 5),
      viewportSize: const ui.Size(100, 100),
    );

    expect(expanded.positions, hasLength(4 * 3));
    expect(expanded.normals, hasLength(4 * 3));
  });
}
