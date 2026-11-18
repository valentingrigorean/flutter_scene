// An app's translucent draws ([ForeignDraws]) take their place by depth
// among the scene's translucent draws of their render order: sorted with
// the scene's kept draws in one draw ([ForeignSite.merge]), drawn in ranges
// of depth between the draws the scene encodes ([ForeignSite.fartherThan]),
// and replayed for another camera as the one merged pass. Each frame is
// compared with the frame of a scene that holds the app's draws as nodes.
//
// Its own file: it reads frames back, which crashes the software GPU of the
// tester after the frames of foreign_draws_test.dart's scenes.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/pass_pipeline_state.dart';
import 'package:flutter_scene/src/render/viewport_camera.dart';
import 'package:flutter_scene/src/scene_encoder.dart'
    show SceneEncoder, itemSortKeyAtDepth;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'support/gpu_available.dart';
import 'support/sheet_material.dart';

// The app's pass index: the last of the scene's item set.
const _pass = ForeignDraws.firstPass + ForeignDraws.passes - 1;
const _size = ui.Size(64, 64);

PerspectiveCamera _cameraAt(double x) => PerspectiveCamera(
  position: Vector3(x, 0, 0),
  target: Vector3(x, 0, -1),
  up: Vector3(0, 1, 0),
  fovNear: 0.1,
  fovFar: 1000,
);

final _camera = _cameraAt(0);

final _red = Vector4(1, 0, 0, 0.5);
final _green = Vector4(0, 1, 0, 0.5);
final _blue = Vector4(0, 0, 1, 0.5);

final _geometry = CuboidGeometry(Vector3(100, 100, 0.01));

Node _node(double z, Material material) => Node(
  mesh: Mesh(_geometry, material),
  localTransform: Matrix4.translationValues(0, 0, z),
);

// Emplaces each block in a buffer of its own.
class _Writer implements TransientWriter {
  @override
  gpu.BufferView emplace(ByteData bytes) => gpu.BufferView(
    gpu.gpuContext.createDeviceBufferWithCopy(bytes),
    offsetInBytes: 0,
    lengthInBytes: bytes.lengthInBytes,
  );
}

// An app's translucent sheets, kept as items of [_pass] of the scene's item
// set and drawn at the translucent site of render order 0.
class _App {
  _App(this.sheets);

  // The colour of each sheet by its place along z.
  final Map<double, Vector4> sheets;

  // Whether the site draws; false as an app with nothing to show.
  bool shown = true;

  // What each call of the site in the frame was handed.
  final sites = <ForeignSite>[];

  gpu.ItemSet? _kept;

  late final draws = ForeignDraws(draw: _draw, translucentOrders: [0]);

  int? _draw(ForeignSite site) {
    sites.add(site);
    if (!shown) return null;
    if (!identical(_kept, site.items)) {
      _kept = site.items;
      _keep(site);
    }
    site.items.draw(
      site.pass,
      _pass,
      clip: site.clip,
      fartherThan: site.fartherThan,
      merge: site.merge,
      notFartherThan: site.notFartherThan,
      sort: site.sort,
      viewBlocks: site.viewBlocks,
      viewTextures: site.viewTextures,
    );
    return _pass;
  }

  // Records each sheet as the scene records a translucent draw it keeps,
  // and keeps it in the app's pass.
  void _keep(ForeignSite site) {
    final reversed = site.sort == gpu.ItemSort.farthestFirstReversedDepth;
    final raster = DepthRaster(reversed: reversed, floatDepth: reversed);
    final recorder = createTrackedRecorder(site.items, site.target);
    for (final MapEntry(key: z, value: color) in sheets.entries) {
      // An encoder for each: a keep drops the recorder's bindings, which an
      // encoder that bound them would take to stand.
      final encoder = SceneEncoder(
        recorder,
        _Writer(),
        ViewportBoundCamera(_camera, _size, raster: raster),
        _size,
        site.lighting!,
        site.layerMask,
        const [],
        false,
        cameraTransform: Matrix4.fromFloat32List(site.clip),
      );
      final material = SheetMaterial(color);
      final item = RenderItem(geometry: _geometry, material: material)
        ..worldTransform.setTranslationRaw(0, 0, z);
      recorder
        ..setTrackedColorBlendEnable(true)
        ..setTrackedColorBlendEquation(
          gpu.ColorBlendEquation(
            colorBlendOperation: gpu.BlendOperation.add,
            sourceColorBlendFactor: gpu.BlendFactor.one,
            destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
            alphaBlendOperation: gpu.BlendOperation.add,
            sourceAlphaBlendFactor: gpu.BlendFactor.one,
            destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
          ),
        )
        ..setTrackedDepthWriteEnable(false)
        ..setTrackedDepthCompareOperation(
          raster.compare(material.depthCompare),
        );
      material.drawsAs();
      encoder.encodeForKeep(item, geometry: _geometry, material: material);
      final id = site.items.keep(
        recorder,
        passes: 1 << _pass,
        bounds: Float32List.fromList([-50, -50, z, 50, 50, z]),
      );
      expect(id, isNotNull, reason: 'the sheet at $z is kept');
    }
  }
}

// The colour of the centre pixel of a frame of [scene].
Future<List<int>> _centre(Scene scene) async {
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
  final at = (32 * _size.width.round() + 32) * 4;
  return Uint8List.sublistView(bytes!).sublist(at, at + 4);
}

// A scene of a sheet of each colour of [sheets] at its place along z.
Scene _scene(Map<double, Vector4> sheets, {required bool kept}) {
  // Every frame renders: none waits on the GPU's pacing.
  final scene = Scene()..maxGpuFramesInFlight = 0;
  for (final MapEntry(key: z, value: color) in sheets.entries) {
    scene.add(_node(z, SheetMaterial(color, kept: kept)));
  }
  addTearDown(scene.dispose);
  return scene;
}

// The centre of a frame of a scene that draws [sheets] itself, in the order
// it gives its own translucent draws.
Future<List<int>> _reference(Map<double, Vector4> sheets) async {
  final scene = _scene(sheets, kept: true);
  var centre = <int>[];
  for (var frame = 0; frame < 3; frame++) {
    centre = await _centre(scene);
  }
  return centre;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the key of an encoded draw\'s sort depth is the key an item with '
      'that centre sorts by', () {
    // ItemSort.farthestFirst: the clip-space w of the centre, or its z
    // where the clip matrix gives every point one w, negated for reversed
    // depth.
    double keyOf(Float32List clip, Vector3 centre, {required bool reversed}) {
      final row = clip[3] == 0.0 && clip[7] == 0.0 && clip[11] == 0.0 ? 2 : 3;
      final key =
          clip[row] * centre.x +
          clip[4 + row] * centre.y +
          clip[8 + row] * centre.z +
          clip[12 + row];
      return row == 2 && reversed ? -key : key;
    }

    final random = math.Random(7);
    final eye = Vector3(3, 40, 10);
    final target = Vector3(-20, 0, -120);
    final up = Vector3(0, 1, 0);
    for (final Camera inner in [
      PerspectiveCamera(position: eye, target: target, up: up),
      OrthographicCamera(position: eye, target: target, up: up),
    ]) {
      for (final raster in const [
        DepthRaster.standard,
        DepthRaster(reversed: true, floatDepth: true),
        DepthRaster(reversed: true, floatDepth: true, near: 2.5),
      ]) {
        final camera = ViewportBoundCamera(inner, _size, raster: raster);
        final transform = rasterViewTransformOf(camera, _size);
        final clip = Float32List.fromList(transform.storage);
        final keys = <(double, double)>[];
        for (var draw = 0; draw < 500; draw++) {
          final centre = Vector3(
            random.nextDouble() * 200 - 100,
            random.nextDouble() * 60 - 30,
            random.nextDouble() * -300,
          );
          final depth = sceneSortDepth(
            Matrix4.translation(centre),
            null,
            camera.position,
            camera.forward,
          );
          final key = itemSortKeyAtDepth(
            transform,
            camera.position,
            camera.forward,
            depth,
            reversed: raster.reversed,
          );
          final item = keyOf(clip, centre, reversed: raster.reversed);
          expect(
            key,
            closeTo(item, 1e-5 * math.max(1, item.abs())),
            reason: '${inner.runtimeType}, reversed ${raster.reversed}',
          );
          keys.add((depth, key));
        }
        // A farther draw has the greater key.
        keys.sort((a, b) => a.$1.compareTo(b.$1));
        for (var at = 1; at < keys.length; at++) {
          expect(keys[at].$2, greaterThanOrEqualTo(keys[at - 1].$2));
        }
      }
    }
  });

  if (!gpuAvailable()) return;

  setUpAll(() async {
    await Scene.initializeStaticResources();
    // The first frames of a process build their pipelines, and a scene
    // keeps no draw meanwhile.
    final warmUp = Scene()..add(_node(-50, SheetMaterial(_red)));
    for (var frame = 0; frame < 2; frame++) {
      await _centre(warmUp);
    }
    warmUp.dispose();
  });

  test('the app\'s translucent draws sort by depth among the kept '
      'translucent draws of the scene, in one draw of both', () async {
    // Back to front: blue, green, blue, red.
    final scenes = {-30.0: _red, -70.0: _green};
    final apps = {-50.0: _blue, -90.0: _blue};
    final want = await _reference({...scenes, ...apps});
    // Half of each layer shows through the next: the nearest, red, weighs
    // most, and the blue next to it more than the green behind that.
    expect(want[0], greaterThan(want[2]));
    expect(want[2], greaterThan(want[1]));

    final app = _App(apps);
    final scene = _scene(scenes, kept: true)..foreignDraws = app.draws;
    for (var frame = 0; frame < 3; frame++) {
      app.sites.clear();
      expect(await _centre(scene), want, reason: 'frame $frame');
      expect(app.sites, hasLength(1), reason: 'frame $frame');
      final site = app.sites.single;
      expect(site.merge, isNotNull, reason: 'frame $frame');
      expect(site.fartherThan, isNull);
      expect(site.notFartherThan, isNull);
      expect(
        () => site.items.draw(
          site.pass,
          _pass,
          clip: site.clip,
          fartherThan: 1,
          viewBlocks: site.viewBlocks,
        ),
        throwsArgumentError,
        reason: 'a range of depth of a pass sorted by key',
      );
    }
  });

  for (final (z, name) in const [(-40.0, 'nearer'), (-60.0, 'farther')]) {
    test('a kept translucent draw of the scene $name than the app\'s draws '
        '${z > -50 ? 'after' : 'before'} it', () async {
      final want = await _reference({z: _red, -50.0: _blue});
      // The later draw shows more.
      expect(want[z > -50 ? 0 : 2], greaterThan(want[z > -50 ? 2 : 0]));

      final app = _App({-50.0: _blue});
      final scene = _scene({z: _red}, kept: true)..foreignDraws = app.draws;
      for (var frame = 0; frame < 3; frame++) {
        app.sites.clear();
        expect(await _centre(scene), want, reason: 'frame $frame');
        expect(app.sites.single.merge, isNotNull, reason: 'frame $frame');
      }
    });

    test('a translucent draw the scene encodes $name than the app\'s draws '
        '${z > -50 ? 'after' : 'before'} it', () async {
      final want = await _reference({z: _red, -50.0: _blue});

      final app = _App({-50.0: _blue});
      final scene = _scene({z: _red}, kept: false)..foreignDraws = app.draws;
      for (var frame = 0; frame < 3; frame++) {
        app.sites.clear();
        expect(await _centre(scene), want, reason: 'frame $frame');
        expect(
          [for (final site in app.sites) site.merge],
          [null, null],
          reason: 'frame $frame',
        );
        // The app draws what lies behind the scene's draw, then the rest.
        expect(app.sites[0].fartherThan, closeTo(-z, 1e-3));
        expect(app.sites[0].notFartherThan, isNull);
        expect(app.sites[1].fartherThan, isNull);
        expect(app.sites[1].notFartherThan, app.sites[0].fartherThan);
      }
    });
  }

  test('the app\'s translucent draws draw in the ranges of depth between '
      'the draws the scene encodes, which bind again after each', () async {
    final apps = {-50.0: _blue, -90.0: _green};
    final want = await _reference({-30.0: _red, -70.0: _red, ...apps});

    // The scene's two draws share a material, so the second binds only what
    // it takes the pass to have lost to the app's draws between them.
    final red = SheetMaterial(_red, kept: false);
    final app = _App(apps);
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..add(_node(-30, red))
      ..add(_node(-70, red))
      ..foreignDraws = app.draws;
    addTearDown(scene.dispose);
    for (var frame = 0; frame < 3; frame++) {
      app.sites.clear();
      expect(await _centre(scene), want, reason: 'frame $frame');
      expect(
        [for (final site in app.sites) site.fartherThan],
        [closeTo(70, 1e-3), closeTo(30, 1e-3), null],
        reason: 'frame $frame',
      );
      expect(
        [for (final site in app.sites) site.notFartherThan],
        [null, app.sites[0].fartherThan, app.sites[1].fartherThan],
        reason: 'frame $frame',
      );
    }
  });

  test('a sheet of the scene that moves through the app\'s draw is drawn on '
      'its side of it each frame: kept at rest, encoded while its material '
      'changes', () async {
    final near = await _reference({-40.0: _red, -50.0: _blue});
    final far = await _reference({-60.0: _red, -50.0: _blue});
    expect(near, isNot(far));

    final app = _App({-50.0: _blue});
    final sheet = _node(-40, SheetMaterial(_red));
    final scene = Scene()
      ..maxGpuFramesInFlight = 0
      ..add(sheet)
      ..foreignDraws = app.draws;
    addTearDown(scene.dispose);
    final merged = <double>{};
    final ranged = <double>{};
    // At rest, then a step a frame through the app's draw, then at rest.
    final places = [
      for (var frame = 0; frame < 3; frame++) -40.0,
      for (var z = -41.5; z > -59; z -= 1) z,
      for (var frame = 0; frame < 8; frame++) -60.0,
    ];
    for (final z in places) {
      if (z != -40 && z != -60) {
        // A draw that changes frame after frame is encoded.
        sheet.mesh = Mesh(_geometry, SheetMaterial(_red));
      }
      sheet.localTransform = Matrix4.translationValues(0, 0, z);
      app.sites.clear();
      expect(await _centre(scene), z > -50 ? near : far, reason: 'at $z');
      final first = app.sites.first;
      expect(first.merge == null, first.fartherThan != null, reason: 'at $z');
      (first.merge != null ? merged : ranged).add(z);
    }
    expect(merged, containsAll([-40.0, -60.0]), reason: 'kept at rest');
    expect(
      ranged,
      containsAll([-49.5, -50.5]),
      reason: 'encoded on both sides of the app\'s draw',
    );
  });

  test('a site that draws nothing leaves the scene its kept draws of the '
      'order', () async {
    final want = await _reference({-40.0: _red});
    final app = _App({-50.0: _blue})..shown = false;
    final scene = _scene({-40.0: _red}, kept: true)..foreignDraws = app.draws;
    for (var frame = 0; frame < 3; frame++) {
      app.sites.clear();
      expect(await _centre(scene), want, reason: 'frame $frame');
      expect(app.sites.single.merge, isNotNull, reason: 'frame $frame');
    }
  });

  test('a camera replays a frame of the app\'s draws merged with the '
      'scene\'s kept draws as the one pass the app drew, and no frame whose '
      'encoded draws cut the app\'s', () async {
    final target = RenderTexture(width: 32, height: 32, presents: true);
    RenderView view(double x) =>
        RenderView(camera: _cameraAt(x), target: target);
    void render(Scene scene) {
      final recorder = ui.PictureRecorder();
      scene.renderViews([view(0)], ui.Canvas(recorder));
      recorder.endRecording().dispose();
    }

    final app = _App({-50.0: _blue});
    final scene = _scene({-40.0: _red}, kept: true)..foreignDraws = app.draws;
    for (var frame = 0; frame < 3; frame++) {
      app.sites.clear();
      render(scene);
    }
    final site = app.sites.single;
    final replay = scene.cameraFrame([view(1)]);
    expect(replay, isNotNull, reason: 'replays');
    // The app drew the scene's kept pass in its own: the frame for another
    // camera states the view of that one pass, by which both sort again.
    expect(replay!.keys, contains(_pass));
    expect(replay.keys, isNot(contains(site.merge)));
    // The camera one unit along x: the clip matrix the site drew with, its
    // translation less its x column.
    final was = site.clip;
    expect(replay[_pass]!.clip, [
      for (var at = 0; at < 12; at++) closeTo(was[at], 1e-6),
      for (var at = 0; at < 4; at++) closeTo(was[12 + at] - was[at], 1e-6),
    ]);
    expect(was[0], isNot(closeTo(0, 1e-3)));
    scene.dispose();

    final cutApp = _App({-50.0: _blue});
    final cut = _scene({-40.0: _red}, kept: false)..foreignDraws = cutApp.draws;
    for (var frame = 0; frame < 3; frame++) {
      cutApp.sites.clear();
      render(cut);
    }
    expect(cutApp.sites.first.fartherThan, isNotNull);
    expect(cut.cameraFrame([view(1)]), isNull);
  });
}
