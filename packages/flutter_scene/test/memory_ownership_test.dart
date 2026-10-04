// Covers the ownership half of the GPU memory story: a ResourceGroup gives
// back the claims it took, the memory report's value types, and the render
// targets a scene and a render texture hold, which the report counts and the
// VM is told about. The registry refcounts are exercised through the loaders,
// which need an asset bundle and a GPU, so they are covered by the example
// app rather than here.

import 'dart:ui' as ui;

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/external_bytes.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

int _descriptorBytes(gpu.Texture texture) =>
    texture.storageMode == gpu.StorageMode.deviceTransient
    ? 0
    : texture.getBaseMipLevelSizeInBytes() * texture.sampleCount;

int _bytesPerPixel(gpu.PixelFormat format) => switch (format) {
  gpu.PixelFormat.a8UNormInt ||
  gpu.PixelFormat.r8UNormInt ||
  gpu.PixelFormat.s8UInt => 1,
  gpu.PixelFormat.r8g8UNormInt => 2,
  gpu.PixelFormat.r8g8b8a8UNormInt ||
  gpu.PixelFormat.r8g8b8a8UNormIntSRGB ||
  gpu.PixelFormat.b8g8r8a8UNormInt ||
  gpu.PixelFormat.b8g8r8a8UNormIntSRGB ||
  gpu.PixelFormat.r32Float ||
  gpu.PixelFormat.d24UnormS8Uint => 4,
  gpu.PixelFormat.r16g16b16a16Float || gpu.PixelFormat.d32FloatS8UInt => 8,
  gpu.PixelFormat.r32g32b32a32Float => 16,
  _ => throw ArgumentError.value(format, 'format', 'no test size'),
};

int _descriptorFigure(
  Surface surface, {
  required int views,
  required int ringBytes,
}) {
  var bytes = views * 2 * ringBytes;
  for (var view = 0; view < views; view++) {
    final pool = surface.transientTexturePool(view).heldDescriptors;
    for (final MapEntry(key: descriptor, value: count) in pool.entries) {
      if (descriptor.storageMode == gpu.StorageMode.deviceTransient) continue;
      bytes +=
          count *
          descriptor.width *
          descriptor.height *
          _bytesPerPixel(descriptor.format) *
          descriptor.sampleCount;
    }
  }
  return bytes;
}

const _multisampledPrivate = TransientTextureDescriptor(
  width: 32,
  height: 32,
  format: gpu.PixelFormat.r8g8b8a8UNormInt,
  sampleCount: 4,
  storageMode: gpu.StorageMode.devicePrivate,
  enableShaderReadUsage: false,
  debugName: 'memory ownership test',
);

MemoryCategory _category(String name) =>
    takeMemoryReport().categories.firstWhere((c) => c.name == name);

void _render(Scene scene, List<RenderView> views, ui.Rect region) {
  final recorder = ui.PictureRecorder();
  try {
    scene.renderViews(
      views,
      ui.Canvas(recorder),
      region: region,
      pixelRatio: 1,
    );
  } finally {
    recorder.endRecording().dispose();
  }
}

List<RenderView> _twoViews() => [
  RenderView(
    camera: PerspectiveCamera(position: Vector3(0, 0, 5)),
    viewport: const ui.Rect.fromLTWH(0, 0, 0.5, 1),
  ),
  RenderView(
    camera: PerspectiveCamera(position: Vector3(0, 5, 5)),
    viewport: const ui.Rect.fromLTWH(0.5, 0, 0.5, 1),
  ),
];

Node _cube() =>
    Node(mesh: Mesh(CuboidGeometry(Vector3.all(1)), UnlitMaterial()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final gpuSkip = _gpuAvailable() ? false : 'Requires a GPU device.';

  group('ResourceGroup ownership', () {
    test('dispose gives back every tracked claim', () async {
      final released = <String>[];
      final group = ResourceGroup();
      group.track(
        Future<int>.value(1),
        release: () async => released.add('terrain'),
      );
      group.track(
        Future<int>.value(2),
        release: () async => released.add('props'),
      );
      await group.ready;

      expect(released, isEmpty, reason: 'nothing is released before dispose');
      group.dispose();
      expect(released, ['terrain', 'props']);
    });

    test('release can be called without disposing, and is idempotent', () {
      var releases = 0;
      final group = ResourceGroup();
      group.track(Future<int>.value(1), release: () async => releases++);

      group.release();
      expect(releases, 1);
      // A second release must not hand the same claim back twice, which would
      // drop a cache entry another holder still owns.
      group.release();
      expect(releases, 1);
      group.dispose();
      expect(releases, 1);
    });

    test('track still counts toward progress like add', () async {
      final group = ResourceGroup();
      group.track(Future<int>.value(1), release: () async {});
      expect(group.total, 1);
      await group.ready;
      expect(group.completed, 1);
      expect(group.isReady, isTrue);
      group.dispose();
    });

    test('a failed tracked load still releases its claim', () async {
      var releases = 0;
      final group = ResourceGroup();
      group.track(
        Future<int>.error(StateError('boom')),
        release: () async => releases++,
      );
      await group.ready;

      expect(group.hasFailures, isTrue);
      group.dispose();
      expect(releases, 1, reason: 'a load that failed may still have cached');
    });
  });

  group('memory report', () {
    test('totals only the categories that can report a size', () {
      const report = MemoryReport([
        MemoryCategory(name: 'textures', bytes: 2 * 1024 * 1024, count: 3),
        MemoryCategory(name: 'scene templates', bytes: null, count: 2),
      ]);
      expect(report.totalBytes, 2 * 1024 * 1024);
      expect(report.toString(), contains('2.00 MiB'));
      expect(report.toString(), contains('scene templates: 2'));
    });

    test('reports empty caches rather than throwing', () {
      final report = takeMemoryReport();
      expect(report.categories, isNotEmpty);
      expect(report.totalBytes, 0);
      for (final category in report.categories) {
        expect(category.count, 0);
      }
    });
  });

  group('held render targets', () {
    testWidgets('a rendered scene holds the bytes of every view ring and '
        'pool texture at the size and sample count it drew, and states each '
        'device-private texture to the VM', (tester) async {
      await tester.runAsync(Scene.initializeStaticResources);
      final scene = Scene()
        ..antiAliasingMode = AntiAliasingMode.msaa
        ..add(_cube());
      const region = ui.Rect.fromLTWH(0, 0, 64, 32);
      _render(scene, _twoViews(), region);
      _render(scene, _twoViews(), region);

      if (scene.effectiveAntiAliasingMode == AntiAliasingMode.msaa) {
        final multisampled = scene.surface.debugHeldTextures.where(
          (texture) => texture.sampleCount == 4,
        );
        expect(multisampled, isNotEmpty);
        for (final texture in multisampled) {
          expect(texture.storageMode, gpu.StorageMode.deviceTransient);
        }
      }
      scene.surface.transientTexturePool().acquire(_multisampledPrivate);

      final held = scene.surface.debugHeldTextures.toList();
      expect(held, hasLength(scene.surface.debugHeldTextureCount));
      expect(
        scene.surface.heldBytes,
        _descriptorFigure(scene.surface, views: 2, ringBytes: 32 * 32 * 4),
      );
      expect(
        scene.surface.transientTexturePool().heldDescriptors,
        containsPair(_multisampledPrivate, 1),
      );
      for (final texture in held) {
        expect(texture.width, lessThanOrEqualTo(32));
        expect(texture.height, lessThanOrEqualTo(32));
      }
      expect(
        scene.surface.heldBytes,
        greaterThanOrEqualTo(2 * 2 * 32 * 32 * 4),
      );
      for (final texture in held) {
        expect(texture.mipLevelCount, 1);
        expect(debugStatedExternalBytes(texture), _descriptorBytes(texture));
      }

      scene.dispose();

      expect(scene.surface.heldBytes, 0);
    }, skip: gpuSkip != false);

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      testWidgets('on ${platform.name} a transient attachment counts 0 held '
          'and states its full bytes to the VM', (tester) async {
        await tester.runAsync(Scene.initializeStaticResources);
        final scene = Scene()
          ..antiAliasingMode = AntiAliasingMode.msaa
          ..add(_cube());
        const region = ui.Rect.fromLTWH(0, 0, 64, 32);
        debugDefaultTargetPlatformOverride = platform;
        try {
          _render(scene, _twoViews(), region);
          _render(scene, _twoViews(), region);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }

        final transient = scene.surface.debugHeldTextures.where(
          (texture) => texture.storageMode == gpu.StorageMode.deviceTransient,
        );
        expect(transient, isNotEmpty);
        for (final texture in transient) {
          expect(
            debugStatedExternalBytes(texture),
            texture.getBaseMipLevelSizeInBytes() * texture.sampleCount,
          );
        }
        expect(
          scene.surface.heldBytes,
          _descriptorFigure(scene.surface, views: 2, ringBytes: 32 * 32 * 4),
        );

        scene.dispose();
      }, skip: gpuSkip != false);
    }

    testWidgets('a render texture holds its own ring and pool until it is '
        'disposed, and the memory report counts it with the scene', (
      tester,
    ) async {
      await tester.runAsync(Scene.initializeStaticResources);
      final bytesBefore = _category('render targets').bytes!;
      final countBefore =
          _category('render targets').count +
          _category('transient attachments').count;
      final target = RenderTexture(width: 32, height: 16);
      final scene = Scene()..add(_cube());
      final views = [
        RenderView(camera: PerspectiveCamera(position: Vector3(0, 0, 5))),
        RenderView(
          camera: PerspectiveCamera(position: Vector3(0, 0, 5)),
          target: target,
        ),
      ];
      _render(scene, views, const ui.Rect.fromLTWH(0, 0, 64, 32));
      _render(scene, views, const ui.Rect.fromLTWH(0, 0, 64, 32));

      expect(target.heldBytes, greaterThanOrEqualTo(2 * 32 * 16 * 4));
      final renderTargets = _category('render targets');
      expect(
        renderTargets.bytes! - bytesBefore,
        scene.surface.heldBytes + target.heldBytes,
      );
      expect(
        renderTargets.count +
            _category('transient attachments').count -
            countBefore,
        scene.surface.debugHeldTextureCount + target.debugHeldTextureCount,
      );
      expect(target.texture, isNotNull);

      target.dispose();

      expect(target.heldBytes, 0);
      expect(target.debugHeldTextureCount, 0);
      expect(target.texture, isNull);
      expect(
        _category('render targets').bytes! - bytesBefore,
        scene.surface.heldBytes,
      );

      scene.dispose();

      expect(_category('render targets').bytes, bytesBefore);
      expect(
        _category('render targets').count +
            _category('transient attachments').count,
        countBefore,
      );
    }, skip: gpuSkip != false);

    test('bytes stated to the VM prompt the collection of their dropped '
        'owner with no other allocation', () async {
      const bytes = 256 << 20;
      final owners = <WeakReference<Object>>[];
      for (var drop = 0; drop < 64; drop++) {
        final owner = Object();
        statesExternalBytes(owner, bytes);
        owners.add(WeakReference(owner));
        await Future<void>.delayed(Duration.zero);
      }

      expect(owners.where((owner) => owner.target != null).length, lessThan(8));
    });
  });
}
