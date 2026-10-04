import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/src/external_bytes.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

import 'package:flutter_scene/src/render/render_graph.dart';

/// Manages the swapchain color textures a [Scene] composites onto the
/// Flutter canvas, plus the pools of transient render-graph attachments.
///
/// Each [Scene] owns one `Surface`. A scene may render several views per
/// frame (split-screen, picture-in-picture); each view gets its own
/// swapchain ring and its own transient texture pool, so simultaneous views
/// never share a render target within a frame. View 0 is the single-view
/// default.
///
/// Every view, every frame, the renderer asks the surface for that view's
/// next swapchain color texture via [getNextSwapchainColorTexture]; the
/// surface rotates through a small ring per view so the GPU isn't asked to
/// overwrite one the compositor is still reading. The tone-mapping pass
/// renders the final image into this texture, which is then drawn to the
/// canvas via `Texture.asImage`. Each ring (and the view's transient pool)
/// is dropped and rebuilt whenever that view's requested size changes.
///
/// Applications typically don't interact with `Surface` directly; it is
/// driven internally by [Scene.render] / [Scene.renderViews].
/// {@category Rendering}
class Surface {
  /// Creates a surface that holds no render target until a view draws.
  Surface() {
    _live.add(WeakReference(this));
    if (_live.length >= _pruneAt) {
      _live.removeWhere((surface) => surface.target == null);
      _pruneAt = 2 * _live.length + 16;
    }
  }

  // TODO(bdero): There should be a method on the Flutter GPU context to pull
  //              this information.
  static const int _maxFramesInFlight = 2;

  static final List<WeakReference<Surface>> _live = [];
  static int _pruneAt = 16;

  final List<_ViewSurface> _views = [];

  _ViewSurface _view(int index) {
    while (_views.length <= index) {
      _views.add(_ViewSurface());
    }
    return _views[index];
  }

  /// The transient texture pool for view [viewIndex] (the intermediate
  /// render-graph attachments: HDR scene color, depth, shadow maps,
  /// post-process buffers). Each view has its own pool so simultaneous
  /// views in a frame never share an attachment.
  @internal
  TransientTexturePool transientTexturePool([int viewIndex = 0]) =>
      _view(viewIndex).pool;

  /// Returns the next 8-bit swapchain color texture for view [viewIndex] at
  /// [size], advancing that view's frame. The ring (and the view's
  /// transient pool) are dropped and rebuilt whenever [size] changes from
  /// the view's previous call.
  gpu.Texture getNextSwapchainColorTexture(Size size, [int viewIndex = 0]) =>
      _view(viewIndex).nextSwapchainColor(size);

  /// The color texture most recently issued for [viewIndex] (the previous
  /// frame's output once the next frame begins), or null before the first
  /// frame or after a resize.
  ///
  /// Sampling it from a material creates a one-frame feedback loop, the
  /// scene's own output appearing inside the scene. The ring guarantees the
  /// returned texture is not the one being rendered this frame, so reading
  /// it while the current frame draws is safe.
  gpu.Texture? lastSwapchainColorTexture([int viewIndex = 0]) =>
      _view(viewIndex)._lastIssued;

  /// The number of textures every view's ring and transient pool holds.
  @internal
  int get debugHeldTextureCount => _views.fold(
    0,
    (count, view) =>
        count + view._swapchainColors.length + view.pool.heldTextureCount,
  );

  /// Every texture every view's ring and transient pool holds.
  @internal
  Iterable<gpu.Texture> get debugHeldTextures => _heldTextures;

  Iterable<gpu.Texture> get _heldTextures => _views.expand(
    (view) => view._swapchainColors.followedBy(view.pool.heldTextures),
  );

  /// The device memory, in bytes, of the render targets every view's ring
  /// and transient pool holds: each texture's mip levels times its samples.
  ///
  /// A [gpu.StorageMode.deviceTransient] attachment (the depth and the
  /// multisampled colour of the main pass) counts 0, since the device keeps
  /// it in tile memory where it can (Metal on an Apple GPU, Vulkan with
  /// lazily allocated memory); a device with no such memory allocates it in
  /// full. The surface also states every texture it holds to the VM as
  /// external memory, so a collection follows the render targets a dropped
  /// surface leaves: the bytes counted here, plus the full bytes of each
  /// transient attachment on Windows and Linux, whose devices allocate it in
  /// full (Flutter GPU has no query for memoryless storage). [dispose] and a
  /// resize drop what this counts.
  int get heldBytes => _heldTextures.fold(
    0,
    (bytes, texture) => bytes + renderTargetBytes(texture),
  );

  /// Drops every view's ring and transient pool, so their textures are
  /// unreachable from this surface. A later frame allocates them again.
  void dispose() {
    for (final view in _views) {
      view.dispose();
    }
    _views.clear();
  }
}

/// One view's swapchain color ring plus its transient texture pool. View 0
/// reproduces the historical single-view behavior exactly.
class _ViewSurface {
  final TransientTexturePool pool = TransientTexturePool(
    framesInFlight: Surface._maxFramesInFlight,
  );

  final List<gpu.Texture> _swapchainColors = [];
  int _cursor = 0;
  Size _previousSize = const Size(0, 0);
  gpu.Texture? _lastIssued;

  gpu.Texture nextSwapchainColor(Size size) {
    pool.beginFrame();
    if (size != _previousSize) {
      _cursor = 0;
      _swapchainColors.clear();
      pool.clear();
      _previousSize = size;
      _lastIssued = null;
    }
    if (_cursor == _swapchainColors.length) {
      _swapchainColors.add(
        gpu.gpuContext.createTexture(
          gpu.StorageMode.devicePrivate,
          size.width.toInt(),
          size.height.toInt(),
          enableRenderTargetUsage: true,
          enableShaderReadUsage: true,
        ),
      );
      final texture = _swapchainColors.last;
      statesExternalBytes(texture, statedRenderTargetBytes(texture));
    }
    final result = _swapchainColors[_cursor];
    _cursor = (_cursor + 1) % Surface._maxFramesInFlight;
    _lastIssued = result;
    return result;
  }

  void dispose() {
    _swapchainColors.clear();
    pool.clear();
    _cursor = 0;
    _previousSize = const Size(0, 0);
    _lastIssued = null;
  }
}

/// The render targets every live [Surface] holds: the device-private
/// textures with their bytes, and the count of the transient attachments,
/// whose bytes the device decides.
@internal
({int bytes, int count, int transientCount}) renderTargetFootprint() {
  var bytes = 0;
  var count = 0;
  var transientCount = 0;
  Surface._live.removeWhere((surface) => surface.target == null);
  for (final reference in Surface._live) {
    final surface = reference.target;
    if (surface == null) continue;
    for (final texture in surface._heldTextures) {
      if (texture.storageMode == gpu.StorageMode.deviceTransient) {
        transientCount++;
      } else {
        count++;
        bytes += renderTargetBytes(texture);
      }
    }
  }
  return (bytes: bytes, count: count, transientCount: transientCount);
}
