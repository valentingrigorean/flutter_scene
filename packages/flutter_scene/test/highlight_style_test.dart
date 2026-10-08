// The selection outline gate: a scene draws the outline passes only while
// HighlightStyle.outline is on and a visible item is highlighted, and with
// the outline off it does not look for highlighted items.

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/selection_outline_pass.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/pre_pass.dart';

class _StubGeometry extends Geometry {
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

// Counts the reads of its item list, the scan the outline gate makes.
class _CountingRenderScene extends RenderScene {
  int itemReads = 0;

  @override
  List<RenderItem> get items {
    itemReads++;
    return super.items;
  }
}

void main() {
  test('a highlighted scene draws the outline while it is on', () {
    final renderScene = _CountingRenderScene();
    final root = Node()..debugMountInto(renderScene);
    root.add(
      Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
        ..highlightColor = Vector4(1, 0.5, 0, 1),
    );
    runPrePass(root, 0);
    final style = HighlightStyle();

    expect(style.outline, isTrue);
    expect(drawsSelectionOutline(style, renderScene), isTrue);

    style.outline = false;
    renderScene.itemReads = 0;
    expect(drawsSelectionOutline(style, renderScene), isFalse);
    expect(renderScene.itemReads, 0);
  });

  test('a scene with no highlighted item draws no outline', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    root.add(Node(mesh: Mesh(_StubGeometry(), _StubMaterial())));
    runPrePass(root, 0);

    expect(drawsSelectionOutline(HighlightStyle(), renderScene), isFalse);
  });
}
