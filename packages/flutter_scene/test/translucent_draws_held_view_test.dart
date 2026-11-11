// sceneTranslucentDraws keeps the culling frustum and forward axis of the
// last perspective camera it read while the camera's values and the size
// stay, and reads anew when one of them changes.

import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubGeometry extends Geometry {
  _StubGeometry(Aabb3 aabb) {
    setLocalBounds(
      aabb,
      Sphere.centerRadius(
        (aabb.min + aabb.max) * 0.5,
        ((aabb.max - aabb.min) * 0.5).length,
      ),
    );
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
  }) => throw UnsupportedError('Stub geometry is not renderable');
}

class _StubMaterial extends Material {
  @override
  bool isOpaque() => false;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) => throw UnsupportedError('Stub material is not renderable');
}

const _size = ui.Size(400, 300);

PerspectiveCamera _camera({double far = 1000, double z = 0}) =>
    PerspectiveCamera(
      position: Vector3(0, 0, z),
      target: Vector3(0, 0, z - 1),
      up: Vector3(0, 1, 0),
      fovNear: 0.1,
      fovFar: far,
    );

Node _root() => Node()
  ..add(
    Node(
      name: 'slab',
      mesh: Mesh(
        _StubGeometry(Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1))),
        _StubMaterial(),
      ),
      localTransform: Matrix4.translationValues(0, 0, -500),
    ),
  );

List<double> _depths(Node root, PerspectiveCamera camera, ui.Size size) => [
  for (final draw in sceneTranslucentDraws(root, camera, size)) draw.depth,
];

void main() {
  test('a camera with the same values reads what the held view reads', () {
    final root = _root();
    expect(_depths(root, _camera(), _size), [500]);
    expect(_depths(root, _camera(), _size), [500]);
  });

  test('a far plane changed alone culls by the new frustum', () {
    final root = _root();
    expect(_depths(root, _camera(), _size), [500]);
    expect(_depths(root, _camera(far: 100), _size), isEmpty);
    expect(_depths(root, _camera(), _size), [500]);
  });

  test('an eye moved alone sorts by the new view', () {
    final root = _root();
    expect(_depths(root, _camera(), _size), [500]);
    expect(_depths(root, _camera(z: -100), _size), [400]);
  });

  test('a size changed alone culls by the new frustum', () {
    final root = Node()
      ..add(
        Node(
          mesh: Mesh(
            _StubGeometry(Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1))),
            _StubMaterial(),
          ),
          localTransform: Matrix4.translationValues(300, 0, -500),
        ),
      );
    expect(_depths(root, _camera(), const ui.Size(400, 300)), isEmpty);
    expect(_depths(root, _camera(), const ui.Size(4000, 300)), [500]);
  });
}
