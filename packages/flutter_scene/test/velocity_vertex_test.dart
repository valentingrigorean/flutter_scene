import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gpu_available.dart';

const _packed = VertexBufferDescriptor(
  strideInBytes: 8,
  attributes: [
    VertexAttributeDescriptor(
      name: 'packed',
      format: gpu.VertexFormat.uint32x2,
    ),
  ],
);

void main() {
  test('a geometry that supplies no velocity vertex shader has none', () {
    expect(UnskinnedGeometry().velocityVertex, isNull);
  });

  if (!gpuAvailable()) {
    test('a supplied velocity vertex shader requires a GPU context', () {
      markTestSkipped('No Impeller GPU context');
    });
    return;
  }

  test('a supplied velocity vertex shader draws over the declared first '
      'stream and the instance-rate model transform', () async {
    await Scene.initializeStaticResources();
    final shader = baseShaderLibrary['VelocityUnskinnedVertex']!;
    final geometry = UnskinnedGeometry()
      ..setVelocityVertex(shader, positionStream: _packed);

    final supplied = geometry.velocityVertex!;
    expect(identical(supplied.shader, shader), isTrue);
    expect(supplied.layout.buffers, hasLength(2));
    expect(supplied.layout.buffers.first, _packed);
    expect(supplied.layout.buffers.last.stepMode, gpu.VertexStepMode.instance);
    expect(supplied.layout.buffers.last.attributes.map((a) => a.name), [
      'model_transform_0',
      'model_transform_1',
      'model_transform_2',
      'model_transform_3',
    ]);

    geometry.setVelocityVertex(null);
    expect(geometry.velocityVertex, isNull);
  });

  test(
    'a velocity vertex shader without its first stream is refused',
    () async {
      await Scene.initializeStaticResources();
      final shader = baseShaderLibrary['VelocityUnskinnedVertex']!;

      expect(
        () => UnskinnedGeometry().setVelocityVertex(shader),
        throwsArgumentError,
      );
    },
  );
}
