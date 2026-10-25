import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_wgpu/present.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// flutter_scene on its wgpu backend renders an orbiting scene into a
/// [RenderTexture], and the presenter shows that texture through
/// `presentTexture`, with no readback into a `ui.Image`.
class ScenePage extends StatefulWidget {
  const ScenePage({super.key});

  @override
  State<ScenePage> createState() => _ScenePageState();
}

class _ScenePageState extends State<ScenePage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onFrame);
  final Scene _scene = Scene();
  final List<Node> _spinners = [];
  RenderTexture? _target;
  WgpuPresenter? _presenter;
  bool _ready = false;
  bool _creating = false;
  Size _size = Size.zero;
  double _dpr = 1;
  int _frameIndex = 0;
  int _skipped = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    Scene.initializeStaticResources().then((_) {
      _build();
      if (mounted) setState(() => _ready = true);
    });
    _ticker.start();
  }

  void _build() {
    _scene.add(
      Node(
        localTransform: vm.Matrix4.translationValues(0, -0.75, 0)
          ..scaleByDouble(8, 1, 8, 1),
        mesh: Mesh(
          PlaneGeometry(),
          PhysicallyBasedMaterial()
            ..baseColorFactor = vm.Vector4(0.55, 0.57, 0.6, 1),
        ),
      ),
    );
    final colours = [
      vm.Vector4(0.9, 0.25, 0.2, 1),
      vm.Vector4(0.2, 0.75, 0.3, 1),
      vm.Vector4(0.2, 0.35, 0.95, 1),
    ];
    for (var i = 0; i < 3; i++) {
      final node = Node(
        mesh: Mesh(
          i == 1 ? SphereGeometry() : CuboidGeometry(vm.Vector3.all(0.9)),
          PhysicallyBasedMaterial()
            ..baseColorFactor = colours[i]
            ..roughnessFactor = 0.4,
        ),
      )..position = vm.Vector3((i - 1) * 1.4, 0, 0);
      _spinners.add(node);
      _scene.add(node);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _presenter?.dispose();
    _target?.dispose();
    _scene.dispose();
    super.dispose();
  }

  Future<void> _ensurePresenter() async {
    if (_creating || _size.isEmpty) return;
    final w = (_size.width * _dpr).round();
    final h = (_size.height * _dpr).round();
    final presenter = _presenter;
    if (presenter != null && presenter.width == w && presenter.height == h) {
      return;
    }
    _creating = true;
    try {
      if (presenter == null) {
        _presenter = await WgpuPresenter.create(width: w, height: h);
      } else {
        await presenter.resize(w, h);
      }
      _target?.dispose();
      _target = RenderTexture(width: w, height: h);
      setState(() {});
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      _creating = false;
    }
  }

  void _onFrame(Duration elapsed) {
    final presenter = _presenter;
    final target = _target;
    if (!_ready || presenter == null || target == null) return;
    _frameIndex++;
    final t = elapsed.inMicroseconds / 1e6;
    for (final (i, node) in _spinners.indexed) {
      node.rotation = vm.Quaternion.axisAngle(
        vm.Vector3(0, 1, 0),
        t * (0.6 + 0.3 * i),
      );
    }
    final camera = PerspectiveCamera(
      position: vm.Vector3(5 * math.sin(t * 0.2), 2.2, 5 * math.cos(t * 0.2)),
      target: vm.Vector3.zero(),
    );
    // A texture view draws nothing onto the canvas.
    final recorder = ui.PictureRecorder();
    _scene.renderViews(
      [RenderView(camera: camera, target: target)],
      ui.Canvas(recorder),
      region: Offset.zero & _size,
    );
    recorder.endRecording().dispose();
    final texture = target.texture;
    if (texture == null) return;
    try {
      if (presenter.presentTexture(texture) != PresentResult.rendered) {
        _skipped++;
      }
    } catch (e) {
      _error = '$e';
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size != _size) {
            _size = size;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _ensurePresenter(),
            );
          }
          final presenter = _presenter;
          return Stack(
            children: [
              if (presenter != null)
                Positioned.fill(child: Texture(textureId: presenter.textureId)),
              Positioned(
                left: 12,
                bottom: 12,
                child: Text(
                  _error ??
                      'flutter_scene on ${gpu.gpuBackend.name} -> presentTexture '
                          '(${_target?.texture?.format.name ?? '…'})  '
                          'frame $_frameIndex  skipped $_skipped',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
