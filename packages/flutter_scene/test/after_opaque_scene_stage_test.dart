// A custom pass of RenderStage.afterOpaqueScene runs on the scene color
// after the opaque draws below its render order, those that blend in the
// opaque pass among them, and before the opaque draws of its order and above
// and the translucent draws, which then draw over what it composed.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

class _RecordingMaterial extends UnlitMaterial {
  _RecordingMaterial(this.label, this.drawn, Vector4 color) {
    baseColorFactor = color;
    if (color.w < 1) alphaMode = AlphaMode.blend;
  }

  final String label;
  final List<String> drawn;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    drawn.add(label);
    super.bind(pass, transientsBuffer, lighting);
  }
}

class _FillPass extends CustomRenderPass {
  _FillPass(this.label, this.drawn, {this.fill, this.order = double.infinity});

  final String label;
  final List<String> drawn;
  final Vector4? fill;
  final double order;
  final List<gpu.PixelFormat> formats = [];

  @override
  String get name => label;

  @override
  double get beforeRenderOrder => order;

  @override
  RenderStage get stage => RenderStage.afterOpaqueScene;

  @override
  bool get drawsInPlace => true;

  @override
  void execute(RenderPassContext context) {
    drawn.add(label);
    final color = context.currentColor;
    formats.add(color.format);
    final fill = this.fill;
    if (fill == null) return;
    final commands = gpu.gpuContext.createCommandBuffer();
    commands.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: color,
          loadAction: gpu.LoadAction.clear,
          clearValue: fill,
        ),
      ),
    );
    commands.submit();
  }
}

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);
const _size = ui.Size(200, 200);

Node _slab(
  String name,
  double distance,
  Material material, {
  double x = 0,
  double order = 0,
}) => Node(
  name: name,
  mesh: Mesh(CuboidGeometry(Vector3(100, 200, 0.01)), material),
  localTransform: Matrix4.translationValues(x, 0, -distance),
)..renderOrder = order;

Future<Uint8List> _frame(Scene scene) async {
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera,
    ui.Canvas(recorder),
    viewport: ui.Offset.zero & _size,
    pixelRatio: 1.0,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.round(),
    _size.height.round(),
  );
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

List<int> _pixel(Uint8List rgba, int x, int y) {
  final at = (y * _size.width.round() + x) * 4;
  return rgba.sublist(at, at + 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a pass after the opaque scene runs on the HDR scene color before the '
      'opaque draws of its render order and above, which blend over what it '
      'drew as the translucent draws do, and a pass of no order runs after '
      'every opaque draw', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final drawn = <String>[];
    final pass = _FillPass('fill', drawn, fill: Vector4(1, 0, 0, 1), order: 1);
    final last = _FillPass('last', drawn);
    final scene = Scene()
      ..toneMapping = ToneMappingMode.linear
      ..add(
        _slab(
          'wall',
          50,
          _RecordingMaterial('wall', drawn, Vector4(0, 1, 0, 1)),
          x: 50,
        ),
      )
      ..add(
        _slab(
          'overlay',
          49,
          _RecordingMaterial('overlay', drawn, Vector4(0, 0, 1, 0.5))
            ..blendsInOpaquePass = true,
          x: 50,
          order: 1,
        ),
      )
      ..add(
        _slab(
          'glass',
          40,
          _RecordingMaterial('glass', drawn, Vector4(0, 0, 1, 0.5)),
          x: -50,
        ),
      )
      ..addRenderPass(last)
      ..addRenderPass(pass);

    final rgba = await _frame(scene);
    scene.dispose();

    expect(drawn, ['wall', 'fill', 'overlay', 'last', 'glass']);
    expect(pass.formats.single, gpu.PixelFormat.r16g16b16a16Float);
    for (final x in [50, 150]) {
      final over = _pixel(rgba, x, 100);
      expect(over[0], greaterThan(100), reason: 'the fill under $over');
      expect(over[1], lessThan(16), reason: 'no wall over the fill at $over');
      expect(over[2], greaterThan(100), reason: 'the blend over $over');
    }
  });
}
