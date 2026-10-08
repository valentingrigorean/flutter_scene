// The fragment an object mask (the selection mask, RenderPassContext
// .drawObjects and the depth conflict probe) draws an item through: an item
// whose material has a clip volume takes the clipped fragment and the full
// vertex stage in every mask, so the mask covers it only where its color pass
// draws.

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/object_filter.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubMaterial extends Material {
  _StubMaterial({this.alphaMasked = false});

  final bool alphaMasked;

  @override
  bool get depthAlphaMasked => alphaMasked;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    throw UnsupportedError('Stub material is not renderable');
  }
}

void main() {
  final cut = ClipVolume([Vector4(1, 0, 0, 0)]);

  test('an item without a clip volume fills flat, or cut to its alpha mask '
      'under a full vertex draw', () {
    expect(
      ObjectMaskFragment.of(_StubMaterial(), fullVertex: false),
      ObjectMaskFragment.flat,
    );
    expect(
      ObjectMaskFragment.of(_StubMaterial(), fullVertex: true),
      ObjectMaskFragment.flat,
    );
    expect(
      ObjectMaskFragment.of(
        _StubMaterial(alphaMasked: true),
        fullVertex: false,
      ),
      ObjectMaskFragment.flat,
    );
    expect(
      ObjectMaskFragment.of(_StubMaterial(alphaMasked: true), fullVertex: true),
      ObjectMaskFragment.alphaMasked,
    );
  });

  test('an item with a clip volume takes the clipped fragment in every '
      'mask', () {
    for (final alphaMasked in [false, true]) {
      for (final fullVertex in [false, true]) {
        expect(
          ObjectMaskFragment.of(
            _StubMaterial(alphaMasked: alphaMasked)..clipVolume = cut,
            fullVertex: fullVertex,
          ),
          ObjectMaskFragment.clipped,
          reason: 'alphaMasked: $alphaMasked, fullVertex: $fullVertex',
        );
      }
    }
    expect(
      ObjectMaskFragment.of(
        _StubMaterial()
          ..clipVolume = ClipVolume(const [], keep: [Vector4(1, 0, 0, 0)]),
        fullVertex: false,
      ),
      ObjectMaskFragment.clipped,
    );
  });
}
