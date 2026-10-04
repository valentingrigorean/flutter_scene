// A material override names the GPU types of the Material contract
// (`bind(gpu.RenderPass, ...)`) and reaches the context to create its own
// textures, so every one of them must come from the public libraries. This
// file imports no `src/` library: a type missing from `gpu.dart` fails to
// compile here.

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

class _OverridingMaterial extends PhysicallyBasedMaterial {
  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    final gpu.GpuContext context = gpu.gpuContext;
    context.createTexture(gpu.StorageMode.hostVisible, 1, 1);
  }
}

void main() {
  test('the GPU types a material override names come from gpu.dart', () {
    final Material Function() create = _OverridingMaterial.new;

    expect(create, isNotNull);
    expect(gpu.StorageMode.values, contains(gpu.StorageMode.hostVisible));
  });
}
