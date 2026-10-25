import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene_wgpu/present.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'scene_page.dart';

const _sceneMode = bool.fromEnvironment('FSW_PRESENT_SCENE');

void main() {
  if (_sceneMode) gpu.selectGpuBackend(gpu.GpuBackendKind.wgpu);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _sceneMode ? const ScenePage() : const CubePage(),
    ),
  );
}

/// A cube drawn by Rust into a Flutter texture, one synchronous render call
/// per frame, with a Flutter marker pinned to one of its corners.
class CubePage extends StatefulWidget {
  const CubePage({super.key});

  @override
  State<CubePage> createState() => _CubePageState();
}

class _CubePageState extends State<CubePage>
    with SingleTickerProviderStateMixin {
  // Radians of camera orbit per frame while nobody drags.
  static const _autoOrbit = 0.01;
  static final _corner = vm.Vector3(0.5, 0.5, 0.5);

  late final Ticker _ticker = createTicker(_onFrame);
  WgpuPresenter? _presenter;
  bool _creating = false;
  Size _size = Size.zero;
  double _dpr = 1;
  EdgeInsets _padding = EdgeInsets.zero;

  int _frameIndex = 0;
  int _skipped = 0;
  double _yaw = 0.6;
  double _pitch = 0.45;
  bool _dragging = false;
  Offset? _cornerOnScreen;
  String? _error;

  int get _block => (10 * _dpr).round();
  int get _markerX => ((_padding.left + 12) * _dpr).round();
  int get _markerY => ((_padding.top + 12) * _dpr).round();

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _presenter?.dispose();
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
        _presenter = await WgpuPresenter.create(
          width: w,
          height: h,
          preferGl: const bool.fromEnvironment('FSW_PRESENT_GL'),
        );
      } else {
        await presenter.resize(w, h);
      }
      setState(() {});
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      _creating = false;
    }
  }

  void _onFrame(Duration _) {
    final presenter = _presenter;
    if (presenter == null || _size.isEmpty) return;
    _frameIndex++;
    if (!_dragging) _yaw += _autoOrbit;

    final aspect = _size.width / _size.height;
    final eye = vm.Vector3(
      3.2 * math.cos(_pitch) * math.sin(_yaw),
      3.2 * math.sin(_pitch),
      3.2 * math.cos(_pitch) * math.cos(_yaw),
    );
    final viewProj =
        _perspective(math.pi / 3, aspect, 0.1, 50) *
        vm.makeViewMatrix(eye, vm.Vector3.zero(), vm.Vector3(0, 1, 0));
    final model = vm.Matrix4.rotationY(_frameIndex * 0.015)
      ..rotateX(_frameIndex * 0.007);

    final result = presenter.render(
      viewProj: viewProj.storage,
      model: model.storage,
      frameIndex: _frameIndex,
      markerX: _markerX,
      markerY: _markerY,
      markerBlock: _block,
    );
    if (result != PresentResult.rendered) _skipped++;

    final clip = (viewProj * model).transform(
      vm.Vector4(_corner.x, _corner.y, _corner.z, 1),
    );
    setState(() {
      _cornerOnScreen = Offset(
        (clip.x / clip.w + 1) / 2 * _size.width,
        (1 - clip.y / clip.w) / 2 * _size.height,
      );
    });
  }

  // wgpu clip space: depth 0..1.
  static vm.Matrix4 _perspective(double fovY, double aspect, double near, double far) {
    final f = 1 / math.tan(fovY / 2);
    return vm.Matrix4.zero()
      ..setEntry(0, 0, f / aspect)
      ..setEntry(1, 1, f)
      ..setEntry(2, 2, far / (near - far))
      ..setEntry(2, 3, near * far / (near - far))
      ..setEntry(3, 2, -1);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    _dpr = media.devicePixelRatio;
    _padding = media.padding;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size != _size) {
            _size = size;
            WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePresenter());
          }
          final presenter = _presenter;
          final corner = _cornerOnScreen;
          return GestureDetector(
            onPanStart: (_) => _dragging = true,
            onPanEnd: (_) => _dragging = false,
            onPanCancel: () => _dragging = false,
            onPanUpdate: (d) {
              _yaw -= d.delta.dx * 0.01;
              _pitch = (_pitch + d.delta.dy * 0.01).clamp(-1.4, 1.4);
            },
            child: Stack(
              children: [
                if (presenter != null)
                  Positioned.fill(child: Texture(textureId: presenter.textureId)),
                // The index Dart requested this frame, drawn by Flutter right
                // under the strip Rust draws into the texture.
                Positioned(
                  left: _markerX / _dpr,
                  top: (_markerY + 2 * _block) / _dpr,
                  child: CustomPaint(
                    size: Size(17 * _block / _dpr, _block / _dpr),
                    painter: _IndexStrip(_frameIndex, _block / _dpr),
                  ),
                ),
                if (corner != null)
                  Positioned(
                    left: corner.dx - 6,
                    top: corner.dy - 6,
                    child: IgnorePointer(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black, width: 2),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 12 + _padding.left,
                  bottom: 12 + _padding.bottom,
                  child: Text(
                    _error ??
                        'wgpu ${WgpuPresenter.backend ?? '…'}  frame $_frameIndex  skipped $_skipped',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A cyan anchor block, then the frame index in 16 blocks (most
/// significant bit first, white for 1).
class _IndexStrip extends CustomPainter {
  _IndexStrip(this.index, this.block);

  final int index;
  final double block;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = false;
    for (var b = 0; b < 17; b++) {
      paint.color = b == 0
          ? const Color(0xFF00FFFF)
          : ((index & 0xffff) >> (16 - b)) & 1 == 1
          ? Colors.white
          : Colors.black;
      canvas.drawRect(Rect.fromLTWH(b * block, 0, block, block), paint);
    }
  }

  @override
  bool shouldRepaint(_IndexStrip old) => old.index != index;
}
