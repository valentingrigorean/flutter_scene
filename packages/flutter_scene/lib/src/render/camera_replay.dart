/// The view blocks of a frame of kept items, rebuilt for another camera
/// without rendering.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/light.dart';

/// The view a frame that moves only the camera rebuilds its passes' view
/// blocks for: the camera bound to the frame's viewport and depth raster, the
/// render-target size, the directional light's cascades for that camera and
/// the frame clock.
final class CameraReplayView {
  /// The view of [camera] drawn at [dimensions].
  CameraReplayView({
    required this.camera,
    required this.dimensions,
    required this.cascades,
    required this.time,
  });

  /// The camera, bound to the viewport and depth raster of the frame.
  final Camera camera;

  /// The render-target size in physical pixels.
  final ui.Size dimensions;

  /// The directional light's shadow cascades for [camera], near to far.
  final List<ShadowCascade> cascades;

  /// The frame clock in seconds, as the frame's passes read it.
  final double time;
}

/// The view blocks and clip matrix of one pass of a frame of kept items.
typedef CameraReplayBlocks = ({List<ByteData> blocks, Float32List clip});

/// Rebuilds a pass's view blocks for [view], or returns null where the pass
/// cannot draw that view as it drew the frame.
typedef CameraReplayPass = CameraReplayBlocks? Function(CameraReplayView view);

/// The passes of a frame of kept items, each with how to rebuild its view
/// blocks and clip matrix for another camera ([CameraReplayView]), recorded
/// while the frame renders.
///
/// A frame whose items set draws only kept items, and whose content, size
/// and lighting stay, differs from a frame for another camera only in those
/// blocks; a scene draws such a frame by publishing them
/// (`Scene.cameraFrame`). A pass that draws work it cannot rebuild that way
/// [refuse]s the recording.
final class CameraReplay {
  /// The recording of the frame rendering now, or null.
  static CameraReplay? recording;

  final Map<int, CameraReplayPass> _passes = {};
  bool _refused = false;

  /// Whether a pass of the frame drew what no other camera's blocks rebuild.
  bool get refused => _refused;

  /// Records how to rebuild the view blocks of the item set's pass [index].
  void pass(int index, CameraReplayPass blocks) => _passes[index] = blocks;

  /// Marks the frame as one no camera replay draws.
  void refuse() => _refused = true;

  /// [refuse]s the frame where [refused] holds: a pass that keeps some of
  /// its draws and encodes others, which another camera may bring into view.
  void refuseWhere(bool refused) {
    if (refused) _refused = true;
  }

  /// The view blocks and clip matrix of each pass for [view], by pass index,
  /// or null where a pass cannot draw it.
  Map<int, CameraReplayBlocks>? blocksFor(CameraReplayView view) {
    if (_refused) return null;
    final blocks = <int, CameraReplayBlocks>{};
    for (final MapEntry(:key, :value) in _passes.entries) {
      final pass = value(view);
      if (pass == null) return null;
      blocks[key] = pass;
    }
    return blocks;
  }
}
