// An app's draw into the scene's item set at each site of a frame
// ([ForeignDraws]): the scene's draws after it bind again and draw as in a
// frame with no foreign draw, and a material the app binds at a colour site
// after [Material.drawsAs] packs its `ItemFragInfo` as the scene's own draw
// of it does.
//
// Its own file: a frame of foreign_draws_test.dart's scenes, run on the GPU
// by a later image read in the same process, crashes the SwiftShader
// tester.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/view_info.dart'
    show HeldBlock, currentDrawFragItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';

final _camera = PerspectiveCamera(
  position: Vector3.zero(),
  target: Vector3(0, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);

// Logs its name each time a pass encodes a draw of it. It takes part in
// the debug views the test shader bundle compiles in, so the color pass
// encodes it every frame.
class _Seen extends UnlitMaterial {
  _Seen(this.label, this.log, Vector4 color) {
    baseColorFactor = color;
    if (color.w < 1) alphaMode = AlphaMode.blend;
  }

  final String label;
  final List<String> log;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    log.add(label);
    lightings.add(lighting);
    super.bind(pass, transientsBuffer, lighting);
  }
}

Node _seen(String name, List<String> log, double order, Vector4 color) => Node(
  mesh: Mesh(CuboidGeometry(Vector3(100, 100, 0.01)), _Seen(name, log, color)),
  localTransform: Matrix4.translationValues(0, 0, -50 - order),
)..renderOrder = order;

// Records, at each bind by the scene, the item's held `ItemFragInfo` block
// and what the scene stated on the material for the draw.
class _Stated extends PhysicallyBasedMaterial {
  bool recording = true;
  HeldBlock? held;
  List<num> stated = const [];

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    if (recording) {
      held = currentDrawFragItem;
      stated = [
        lightChannelMask,
        lightListCount,
        lightListOffset,
        lodFade,
        modelScaleX,
        modelScaleY,
        modelScaleZ,
      ];
    }
    super.bind(pass, transientsBuffer, lighting);
  }
}

// Emplaces each block in a buffer of its own.
class _Writer implements TransientWriter {
  @override
  gpu.BufferView emplace(ByteData bytes) => gpu.BufferView(
    gpu.gpuContext.createDeviceBufferWithCopy(bytes),
    offsetInBytes: 0,
    lengthInBytes: bytes.lengthInBytes,
  );
}

// The lighting each draw of a [_Seen] bound with.
final lightings = <Lighting>{};

void _frame(Scene scene) {
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera,
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, 32, 32),
    pixelRatio: 1.0,
  );
  recorder.endRecording().dispose();
}

// The colour of the centre pixel of a frame of [scene].
Future<List<int>> _centre(Scene scene) async {
  final recorder = ui.PictureRecorder();
  scene.render(
    _camera,
    ui.Canvas(recorder),
    viewport: const ui.Rect.fromLTWH(0, 0, 200, 200),
    pixelRatio: 1.0,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 200);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final at = (100 * 200 + 100) * 4;
  return Uint8List.sublistView(bytes!).sublist(at, at + 4);
}

String _siteName(ForeignSite site) => switch (site.kind) {
  ForeignSiteKind.opaque ||
  ForeignSiteKind.translucent => '${site.kind.name} ${site.order}',
  ForeignSiteKind.cascade ||
  ForeignSiteKind.staticTile => '${site.kind.name} ${site.cascade}',
  ForeignSiteKind.prepass => site.kind.name,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a site that draws its index completes the frame, and the scene\'s '
      'next draws after it draw as with no foreign draw', () async {
    if (!gpuAvailable()) return;
    await Scene.initializeStaticResources();
    final log = <String>[];
    Scene make() {
      final scene = Scene()
        ..maxGpuFramesInFlight = 0
        ..directionalLight = DirectionalLight(castsShadow: true)
        ..add(_seen('wall', log, 1, Vector4(1, 0, 0, 1)))
        ..add(_seen('glass', log, 1, Vector4(0, 0, 1, 0.5)));
      scene.ambientOcclusion.enabled = true;
      addTearDown(scene.dispose);
      return scene;
    }

    final plain = await _centre(make());

    final scene = make();
    final sitesLighting = <String, Lighting?>{};
    scene.foreignDraws = ForeignDraws(
      draw: (site) {
        log.add(_siteName(site));
        sitesLighting[_siteName(site)] = site.lighting;
        const index = ForeignDraws.firstPass;
        site.items.draw(
          site.pass,
          index,
          viewBlocks: site.viewBlocks,
          clip: site.clip,
          viewTextures: site.viewTextures,
          sort: site.sort,
        );
        return index;
      },
      opaqueOrders: [0],
      translucentOrders: [0],
    );
    for (var frame = 0; frame < 3; frame++) {
      log.clear();
      lightings.clear();
      sitesLighting.clear();
      final got = await _centre(scene);
      expect(got, plain, reason: "frame $frame");
      expect(log, contains('prepass'), reason: 'frame $frame');
      // The colour sites hand the app the lighting the scene's materials
      // bind with; the depth and shadow sites hand it none.
      expect(lightings, hasLength(1), reason: 'frame $frame');
      for (final MapEntry(key: site, value: lighting)
          in sitesLighting.entries) {
        final colour =
            site.startsWith('opaque') || site.startsWith('translucent');
        expect(
          lighting,
          colour ? same(lightings.single) : isNull,
          reason: 'frame $frame, $site',
        );
      }
      expect(log.sublist(log.indexOf('opaque 0.0')), [
        'opaque 0.0',
        'wall',
        'translucent 0.0',
        'glass',
      ], reason: 'frame $frame');
    }
  });

  test(
    'a material bound at a colour site after drawsAs with what the '
    'scene\'s draw of it stated packs the ItemFragInfo that draw did',
    () async {
      if (!gpuAvailable()) return;
      await Scene.initializeStaticResources();
      final material = _Stated();
      final lamp = Node(localTransform: Matrix4.translationValues(0, 0, -45))
        ..addComponent(PointLightComponent(PointLight(range: 20)));
      final scene = Scene()
        ..maxGpuFramesInFlight = 0
        ..directionalLight = DirectionalLight(channelMask: 0x01)
        ..add(
          Node(
              mesh: Mesh(CuboidGeometry(Vector3(10, 10, 0.01)), material),
              localTransform: Matrix4.translationValues(0, 0, -50)
                ..scaleByVector3(Vector3(2, 3, 4)),
            )
            ..renderOrder = -1
            ..lightChannelMask = 0x02,
        )
        ..add(lamp);
      addTearDown(scene.dispose);
      final writer = _Writer();
      bool? sameAsScene;
      bool? defaultsDiffer;
      scene.foreignDraws = ForeignDraws(
        draw: (site) {
          if (site.kind != ForeignSiteKind.opaque) return null;
          final held = material.held!;
          final scenes = held.lastBound;
          final stated = material.stated;
          material.recording = false;
          currentDrawFragItem = held;
          // A held block hands back the slot of bytes it already holds.
          material
            ..drawsAs(
              lightChannelMask: stated[0] as int,
              lightListCount: stated[1] as int,
              lightListOffset: stated[2] as int,
              lodFade: stated[3] as double,
              modelScaleX: stated[4] as double,
              modelScaleY: stated[5] as double,
              modelScaleZ: stated[6] as double,
            )
            ..bind(site.pass, writer, site.lighting!);
          sameAsScene = identical(held.lastBound, scenes);
          material
            ..drawsAs()
            ..bind(site.pass, writer, site.lighting!);
          defaultsDiffer = !identical(held.lastBound, scenes);
          currentDrawFragItem = null;
          material.recording = true;
          const index = ForeignDraws.firstPass;
          site.items.draw(
            site.pass,
            index,
            viewBlocks: site.viewBlocks,
            clip: site.clip,
            viewTextures: site.viewTextures,
            sort: site.sort,
          );
          return index;
        },
        opaqueOrders: [0],
      );

      _frame(scene);

      expect(material.stated.sublist(0, 2), [0x02, 1]);
      expect(material.stated.sublist(4), [
        closeTo(2, 1e-6),
        closeTo(3, 1e-6),
        closeTo(4, 1e-6),
      ]);
      expect(sameAsScene, isTrue);
      expect(defaultsDiffer, isTrue);
    },
  );
}
