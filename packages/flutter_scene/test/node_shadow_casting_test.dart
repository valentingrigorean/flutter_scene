import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
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

void main() {
  test('mesh nodes cast shadows by default', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    root.add(Node(mesh: Mesh(_StubGeometry(), _StubMaterial())));

    runPrePass(root, 0);

    expect(renderScene.items.single.castsShadows, isTrue);
  });

  test('the deprecated castsShadows flag maps onto the mode', () {
    final node = Node();
    expect(node.shadowCastingMode, ShadowCastingMode.on);
    // ignore: deprecated_member_use_from_same_package
    expect(node.castsShadows, isTrue);
    // ignore: deprecated_member_use_from_same_package
    node.castsShadows = false;
    expect(node.shadowCastingMode, ShadowCastingMode.off);
    node.shadowCastingMode = ShadowCastingMode.shadowsOnly;
    // ignore: deprecated_member_use_from_same_package
    expect(node.castsShadows, isTrue);
  });

  test('shadow casting modes split the color and shadow gates', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    Node meshNode(ShadowCastingMode mode) =>
        Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
          ..shadowCastingMode = mode;
    final on = meshNode(ShadowCastingMode.on);
    final off = meshNode(ShadowCastingMode.off);
    final doubleSided = meshNode(ShadowCastingMode.doubleSided);
    final shadowsOnly = meshNode(ShadowCastingMode.shadowsOnly);
    root
      ..add(on)
      ..add(off)
      ..add(doubleSided)
      ..add(shadowsOnly);

    runPrePass(root, 0);

    RenderItem itemOf(Node node) => renderScene.items.firstWhere(
      (item) => identical(item.sourceNode, node),
    );
    // Casting and drawing are independent: only `off` stops casting, and only
    // `shadowsOnly` stops drawing.
    expect(itemOf(on).castsShadows, isTrue);
    expect(itemOf(on).drawsColor, isTrue);
    expect(itemOf(off).castsShadows, isFalse);
    expect(itemOf(off).drawsColor, isTrue);
    expect(itemOf(doubleSided).castsShadows, isTrue);
    expect(itemOf(doubleSided).shadowDoubleSided, isTrue);
    expect(itemOf(doubleSided).drawsColor, isTrue);
    expect(itemOf(shadowsOnly).castsShadows, isTrue);
    expect(itemOf(shadowsOnly).drawsColor, isFalse);
    // A hidden node draws nothing whatever its mode says.
    shadowsOnly.visible = false;
    on.visible = false;
    runPrePass(root, 0);
    expect(itemOf(on).drawsColor, isFalse);
    expect(itemOf(shadowsOnly).castsShadows, isTrue);
  });

  test('a primitive opting out subtracts casting without restoring color', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final mesh = Mesh(_StubGeometry(), _StubMaterial());
    mesh.primitives.single.castsShadow = false;
    root.add(
      Node(mesh: mesh)..shadowCastingMode = ShadowCastingMode.shadowsOnly,
    );

    runPrePass(root, 0);

    final item = renderScene.items.single;
    // The primitive's opt-out only ever subtracts casting. Folding it into the
    // node's mode would read as `off` and pull the node back into the color
    // image, which is the opposite of what a shadows-only node asked for.
    expect(item.shadowCastingMode, ShadowCastingMode.shadowsOnly);
    expect(item.castsShadows, isFalse);
    expect(item.drawsColor, isFalse);
  });

  test('a primitive opting out under a drawing node still draws', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final mesh = Mesh(_StubGeometry(), _StubMaterial());
    mesh.primitives.single.castsShadow = false;
    root.add(Node(mesh: mesh));

    runPrePass(root, 0);

    final item = renderScene.items.single;
    expect(item.castsShadows, isFalse);
    expect(item.drawsColor, isTrue);
  });

  test('castsShadows reaches mesh and instanced render items', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final meshNode = Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
      ..shadowCastingMode = ShadowCastingMode.off;
    final instancedNode = Node()..shadowCastingMode = ShadowCastingMode.off;
    instancedNode.addComponent(
      InstancedMeshComponent(
        InstancedMesh(geometry: _StubGeometry(), material: _StubMaterial())
          ..addInstance(Matrix4.identity()),
      ),
    );
    root
      ..add(meshNode)
      ..add(instancedNode);

    runPrePass(root, 0);

    expect(renderScene.items, hasLength(2));
    expect(renderScene.items.where((item) => !item.castsShadows), hasLength(2));
  });

  test('static shadow revision changes only when a static caster changes', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final caster = Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
      ..shadowStatic = true;
    root.add(caster);

    runPrePass(root, 0);
    final initial = renderScene.staticShadowRevision;
    runPrePass(root, 0);
    expect(renderScene.staticShadowRevision, initial);

    caster.localTransform = Matrix4.translationValues(1, 0, 0);
    runPrePass(root, 0);
    expect(renderScene.staticShadowRevision, greaterThan(initial));
    final moved = renderScene.staticShadowRevision;

    caster.visible = false;
    runPrePass(root, 0);
    expect(renderScene.staticShadowRevision, greaterThan(moved));
  });

  test('static render items still refresh changed node settings', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final caster = Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
      ..shadowStatic = true;
    root.add(caster);
    runPrePass(root, 0);

    caster
      ..shadowCastingMode = ShadowCastingMode.off
      ..frustumCulled = false
      ..layers = 4
      ..highlightColor = Vector4(1, 0, 1, 1);
    runPrePass(root, 0);

    final item = renderScene.items.single;
    expect(item.castsShadows, isFalse);
    expect(item.frustumCulled, isFalse);
    expect(item.layers, 4);
    expect(item.highlightColor, Vector4(1, 0, 1, 1));
  });

  test('shadowCasterFaces reaches mesh and instanced render items', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final meshNode = Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
      ..shadowCasterFaces = ShadowCasterFaces.back;
    final instancedNode = Node()..shadowCasterFaces = ShadowCasterFaces.both;
    instancedNode.addComponent(
      InstancedMeshComponent(
        InstancedMesh(geometry: _StubGeometry(), material: _StubMaterial())
          ..addInstance(Matrix4.identity()),
      ),
    );
    root
      ..add(Node(mesh: Mesh(_StubGeometry(), _StubMaterial())))
      ..add(meshNode)
      ..add(instancedNode);

    runPrePass(root, 0);

    expect(
      renderScene.items.map((item) => item.shadowCasterFaces),
      containsAll(<ShadowCasterFaces?>[
        null,
        ShadowCasterFaces.back,
        ShadowCasterFaces.both,
      ]),
    );
  });

  test('a static caster that changes its faces changes the cached shadow', () {
    final renderScene = RenderScene();
    final root = Node()..debugMountInto(renderScene);
    final caster = Node(mesh: Mesh(_StubGeometry(), _StubMaterial()))
      ..shadowStatic = true;
    final instanced = Node()..shadowStatic = true;
    instanced.addComponent(
      InstancedMeshComponent(
        InstancedMesh(geometry: _StubGeometry(), material: _StubMaterial())
          ..addInstance(Matrix4.identity()),
      ),
    );
    root
      ..add(caster)
      ..add(instanced);
    runPrePass(root, 0);
    final initial = renderScene.staticShadowRevision;

    caster.shadowCasterFaces = ShadowCasterFaces.back;
    runPrePass(root, 0);
    final meshChanged = renderScene.staticShadowRevision;
    instanced.shadowCasterFaces = ShadowCasterFaces.back;
    runPrePass(root, 0);

    expect(meshChanged, greaterThan(initial));
    expect(renderScene.staticShadowRevision, greaterThan(meshChanged));
  });

  test("a node's caster faces take the place of the light's", () {
    RenderItem caster([ShadowCasterFaces? faces]) =>
        RenderItem(geometry: _StubGeometry(), material: _StubMaterial())
          ..shadowCasterFaces = faces;

    expect(
      shadowCasterCullMode(caster(), ShadowCasterFaces.front),
      gpu.CullMode.backFace,
    );
    expect(
      shadowCasterCullMode(caster(), ShadowCasterFaces.back),
      gpu.CullMode.frontFace,
    );
    expect(
      shadowCasterCullMode(
        caster(ShadowCasterFaces.back),
        ShadowCasterFaces.front,
      ),
      gpu.CullMode.frontFace,
    );
    expect(
      shadowCasterCullMode(
        caster(ShadowCasterFaces.front),
        ShadowCasterFaces.back,
      ),
      gpu.CullMode.backFace,
    );
    expect(
      shadowCasterCullMode(
        caster(ShadowCasterFaces.both),
        ShadowCasterFaces.front,
      ),
      gpu.CullMode.none,
    );
  });
}
