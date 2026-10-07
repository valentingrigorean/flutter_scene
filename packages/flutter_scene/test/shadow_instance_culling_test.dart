// Covers the per-instance cull of a shadow map: an instanced caster draws
// into a cascade only the instances whose bounds meet that cascade's
// light-space box, and the color pass's own instance cull is left alone.

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubGeometry extends Geometry {
  _StubGeometry() {
    setVertexLayout(const VertexLayoutDescriptor(buffers: []));
    setLocalBounds(Aabb3.minMax(Vector3.all(-5), Vector3.all(5)), null);
  }

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Matrix4 modelTransform,
    Matrix4 cameraTransform,
    Vector3 cameraPosition, {
    gpu.Shader? shaderOverride,
    double depthBias = 0.0,
  }) {
    throw UnsupportedError('Stub geometry is not renderable');
  }
}

class _StubMaterial extends Material {
  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    throw UnsupportedError('Stub material is not renderable');
  }
}

// A 100 by 100 grid of instances 50 m apart, spread over about 5 km.
RenderItem _grid({bool cullInstances = true}) {
  final item = RenderItem(geometry: _StubGeometry(), material: _StubMaterial())
    ..cullInstances = cullInstances
    ..instanceTransforms = [
      for (var row = 0; row < 100; row++)
        for (var column = 0; column < 100; column++)
          Matrix4.translationValues((column - 49.5) * 50, (row - 49.5) * 50, 0),
    ];
  item.instanceBounds = Aabb3.minMax(
    Vector3(-2480, -2480, -5),
    Vector3(2480, 2480, 5),
  );
  item.refreshInstanceData();
  return item;
}

// A light looking down -Z whose map covers a box [width] across, centered on
// [x], [y].
Frustum _cascade(double width, {double x = 0, double y = 0}) => Frustum.matrix(
  makeOrthographicMatrix(
    x - width / 2,
    x + width / 2,
    y - width / 2,
    y + width / 2,
    -1000,
    1000,
  ),
);

void main() {
  test('a cascade 300 m across draws only the instances that meet it', () {
    final item = _grid();
    final records = [item];

    cullShadowCasterInstances(records, _cascade(300), const []);

    // Six instances a side stand within 150 m of the center; the next one
    // out ends 20 m short of the box.
    expect(records, [item]);
    expect(item.shadowInstanceIndices, hasLength(36));
    for (final index in item.shadowInstanceIndices!) {
      final center = item.instanceTransforms![index].getTranslation();
      expect(center.x.abs(), lessThan(150));
      expect(center.y.abs(), lessThan(150));
    }
  });

  test('an instance whose bounds cross the cascade edge is kept', () {
    final item = _grid();

    cullShadowCasterInstances([item], _cascade(342), const []);

    // The box ends at 171 m and the seventh instance a side starts at 170 m.
    expect(item.shadowInstanceIndices, hasLength(64));
  });

  test('a cascade that holds every instance draws them all unculled', () {
    final item = _grid();

    cullShadowCasterInstances([item], _cascade(6000), const []);

    expect(item.shadowInstanceIndices, isNull);
  });

  test('a caster with no instance in the cascade leaves the records', () {
    final item = _grid();
    final other = _grid();
    final records = [item, other];

    cullShadowCasterInstances(records, _cascade(30, x: 50, y: 50), const []);

    expect(records, isEmpty);
  });

  test('a receiver plane rejects the instances behind it', () {
    final item = _grid();

    cullShadowCasterInstances(
      [item],
      _cascade(300),
      [Plane.normalconstant(Vector3(1, 0, 0), 0)],
    );

    expect(item.shadowInstanceIndices, hasLength(18));
  });

  test('a caster that does not cull its instances draws them all', () {
    final item = _grid(cullInstances: false);
    final records = [item];

    cullShadowCasterInstances(records, _cascade(300), const []);

    expect(records, [item]);
    expect(item.shadowInstanceIndices, isNull);
  });

  test('the shadow cull leaves the instances of the color pass alone', () {
    final item = _grid();
    expect(item.cullVisibleInstances(_cascade(100), const []), isTrue);
    final colorVisible = [...item.visibleInstanceIndices!];

    cullShadowCasterInstances([item], _cascade(300), const []);

    expect(item.visibleInstanceIndices, colorVisible);
    expect(colorVisible, hasLength(4));
  });
}
