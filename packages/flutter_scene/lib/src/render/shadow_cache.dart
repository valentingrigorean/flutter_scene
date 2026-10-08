import 'dart:math' as math;

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/light.dart';
import 'package:flutter_scene/src/render/render_stats.dart';

/// One cascade's cached static-caster shadow tile: the persistent texture the
/// static geometry was rendered into, the light-space matrix it was rendered
/// with, and the coverage it was fit to.
class ShadowCascadeCacheEntry {
  /// The persistent tile texture, allocated lazily by the shadow pass on the
  /// entry's first refresh (kept out of [DirectionalShadowCache.plan] so the
  /// planning logic stays GPU-free).
  gpu.Texture? tile;

  /// World -> light-clip matrix the tile's content was rendered with. Every
  /// consumer (dynamic casters, the lit shader, custom passes) samples through
  /// this matrix, not the frame's ideal one, so the cached content stays
  /// correct while it is reused.
  final Matrix4 matrix = Matrix4.zero();

  /// The bounding sphere the slack box was built around: the ideal center at
  /// the refresh, and the ideal radius snapped up to a power of
  /// [DirectionalShadowCache.radiusStep].
  final Vector3 center = Vector3.zero();
  double radius = 0.0;

  /// Side length of the slack-enlarged orthographic box in world units.
  double boxSize = 0.0;

  /// The signature of the static casters inside the tile's box when it was
  /// rendered, [DirectionalShadowCache.noCasters] for a tile that holds none;
  /// a mismatch with [signature] marks the tile stale (refreshed amortized).
  int renderedSignature = DirectionalShadowCache.noCasters;

  /// The signature of the static casters inside the tile's box now, as of
  /// [signatureRevision].
  int signature = DirectionalShadowCache.noCasters;

  /// The static content revision [signature] was read at.
  int signatureRevision = -1;

  /// The frame the tile last rendered in.
  int renderedFrame = 0;

  /// The normalized light direction the tile was rendered with; a mismatch
  /// marks the tile stale (refreshed amortized).
  final Vector3 direction = Vector3.zero();

  /// Whether the tile has ever been rendered with the current parameters.
  bool hasContent = false;

  /// Whether the tile's last render left out casters whose pipelines were
  /// still building, so the next frame renders it again.
  bool incomplete = false;
}

/// A static tile the shadow pass must (re)render this frame.
class ShadowTileRefresh {
  ShadowTileRefresh(this.cascadeIndex, this.entry, this.reason);

  final int cascadeIndex;
  final ShadowCascadeCacheEntry entry;
  final ShadowTileRefreshReason reason;
}

/// One frame's cached-shadow decisions: the cascades every consumer samples
/// with (cached matrices, this frame's split distances) and the tiles to
/// re-render.
class ShadowCachePlan {
  ShadowCachePlan(this.cascades, this.refreshes, this.entries, this.cache);

  /// Effective cascades. Matrices and box sizes describe the cached tiles;
  /// split distances are the frame's ideal ones (they only select which
  /// cascade a fragment samples).
  final List<ShadowCascade> cascades;

  /// Tiles to render static casters into this frame, in cascade order.
  final List<ShadowTileRefresh> refreshes;

  /// All cache entries, indexed by cascade.
  final List<ShadowCascadeCacheEntry> entries;

  /// The cache that made this plan (owns the shared tile depth).
  final DirectionalShadowCache cache;
}

/// Cross-frame cache for the directional light's cascaded shadow tiles.
///
/// Static casters ([RenderItem.shadowStatic]) render into persistent per
/// cascade tiles that are reused while they still cover the view; the shadow
/// pass composites them into each frame's atlas and draws only the dynamic
/// casters on top. Tiles are fit with [slackFactor] extra radius so the
/// camera can move and turn inside the slack before a cascade must
/// re-render, and their radius snaps up to a power of [radiusStep], so a zoom
/// that changes every cascade's radius each frame keeps a tile until the
/// ideal radius leaves that step. Stale tiles (a static caster appeared,
/// changed or vanished inside the tile's box, or the light turned by up to
/// [maxDirectionLagDegrees]) refresh at most [maxAmortizedRefreshes] per
/// frame, nearest cascade first, so streaming worlds and a stepped sun never
/// pay for every cascade at once. A stale tile keeps sampling through the
/// matrix it was rendered with until it refreshes. A caster outside a tile's
/// box leaves the tile as it is, and a tile that holds no caster moves to a
/// box that holds none without a render, since its cleared content is the
/// same in both.
/// [DirectionalLight.invalidateStaticShadows] re-renders every tile in the
/// next frame instead, into the textures the tiles already hold.
class DirectionalShadowCache {
  /// How much larger than the ideal bounding sphere each tile is rendered.
  /// Costs ~13% effective resolution; buys re-render-free camera movement
  /// within the slack.
  static const double slackFactor = 1.15;

  /// The ratio between the radii a tile is rendered at. A tile rendered for
  /// one step serves every ideal radius down to the step below, so a cascade
  /// whose radius follows the camera (a near plane that tracks the zoom)
  /// re-renders once per step instead of once per frame. Costs up to this
  /// factor of effective resolution on top of [slackFactor].
  static const double radiusStep = slackFactor;

  // Tolerance on the lower radius bound, so an ideal radius that sits on a
  // step does not flip between two steps on rounding.
  static const double _radiusTolerance = 1e-3;

  /// How many ideal radii from an ideal cascade's center a cached tile's box
  /// can reach: the tile is rendered up to [radiusStep] larger, past the
  /// tolerance on the lower radius bound, with
  /// [slackFactor] around it, and drifts until the ideal sphere touches its
  /// edge.
  static const double maxReachFactor =
      2 * radiusStep * slackFactor / (1 - _radiusTolerance) - 1;

  static final double _logRadiusStep = math.log(radiusStep);

  /// The smallest power of [radiusStep] that is at least [radius].
  static double snappedRadius(double radius) {
    if (!(radius > 0.0) || !radius.isFinite) return radius;
    final step = (math.log(radius) / _logRadiusStep - 1e-9).ceil();
    return math.max(radius, math.pow(radiusStep, step).toDouble());
  }

  /// The signature of a box that holds no static caster.
  static const int noCasters = 0;

  /// Upper bound on stale-but-usable tile refreshes per frame.
  static const int maxAmortizedRefreshes = 1;

  /// How far the light may turn from a tile's direction before that tile
  /// re-renders immediately instead of amortized.
  static const double maxDirectionLagDegrees = 5.0;

  static final double _minDirectionLagCos = math.cos(
    maxDirectionLagDegrees * math.pi / 180.0,
  );

  final List<ShadowCascadeCacheEntry> _entries = [];

  /// The cache entries, by cascade, as the last [plan] left them.
  List<ShadowCascadeCacheEntry> get debugEntries => _entries;

  /// The static tile textures the cascades hold, and the depth attachment
  /// their refreshes render with.
  Iterable<gpu.Texture> get heldTextures =>
      _entries.map((entry) => entry.tile).nonNulls.followedBy([?tileDepth]);
  int _resolution = 0;
  ShadowCasterFaces _casterFaces = ShadowCasterFaces.front;
  int _casterChannelMask = 0xFF;
  int _staticShadowRevision = 0;

  /// The depth attachment every tile refresh renders with, allocated lazily by
  /// the shadow pass and dropped with the tiles on a resolution change.
  ///
  /// Backends cache a framebuffer per color texture (flutter/flutter#192538),
  /// so a tile must keep the depth it was first rendered with for as long as
  /// it lives. A pooled depth rotates and is freed on resize or memory
  /// pressure, leaving the cached framebuffer attached to a released texture.
  gpu.Texture? tileDepth;

  /// Decides which tiles to re-render for this frame's [idealCascades] and
  /// returns the effective cascades to sample with.
  ///
  /// [staticSignatureIn] fingerprints the static casters a tile rendered with
  /// the given world to light-clip matrix draws, [noCasters] when it draws
  /// none; the plan asks again for a tile's box only when [contentRevision]
  /// changed or the box moved. A change inside a tile's box marks that tile
  /// stale, as does a small turn of [lightDirection]. A larger turn or a
  /// change to the shadow parameters re-renders every tile this frame,
  /// keeping the tile textures unless the resolution changed, and so does a
  /// new [DirectionalLight.staticShadowRevision]. A tile that holds no caster
  /// and whose next box holds none takes the box without a render. [frame]
  /// counts the frames the scene renders: a tile stale for a caster change
  /// waits until [DirectionalLight.staticShadowCasterRefreshInterval] frames
  /// have passed since its last render.
  ShadowCachePlan plan({
    required DirectionalLight light,
    required Vector3 lightDirection,
    required List<ShadowCascade> idealCascades,
    required int contentRevision,
    required int Function(Matrix4 lightSpaceMatrix) staticSignatureIn,
    int frame = 0,
  }) {
    final resolution = light.shadowMapResolution;
    final dir = lightDirection.normalized();
    final paramsChanged =
        resolution != _resolution ||
        light.shadowCasterFaces != _casterFaces ||
        light.shadowCasterChannelMask != _casterChannelMask ||
        _entries.length != idealCascades.length;
    if (paramsChanged) {
      if (resolution != _resolution) {
        for (final entry in _entries) {
          entry.tile = null;
        }
        tileDepth = null;
      }
      // Kept entries keep their tile textures, which still pair with
      // [tileDepth].
      if (_entries.length > idealCascades.length) {
        _entries.length = idealCascades.length;
      }
      for (final entry in _entries) {
        entry.hasContent = false;
        entry.incomplete = false;
      }
      while (_entries.length < idealCascades.length) {
        _entries.add(ShadowCascadeCacheEntry());
      }
      _resolution = resolution;
      _casterFaces = light.shadowCasterFaces;
      _casterChannelMask = light.shadowCasterChannelMask;
      _staticShadowRevision = light.staticShadowRevision;
    }
    final invalidated = light.staticShadowRevision != _staticShadowRevision;
    _staticShadowRevision = light.staticShadowRevision;

    final refreshes = <ShadowTileRefresh>[];
    final effective = <ShadowCascade>[];
    var amortized = 0;
    for (var i = 0; i < idealCascades.length; i++) {
      final ideal = idealCascades[i];
      final entry = _entries[i];
      final center = ideal.center ?? Vector3.zero();
      // A tile is reusable while the ideal sphere still fits inside its
      // slack box and is no smaller than the radius step below the tile's,
      // under which the tile wastes more resolution than a step.
      final directionCos = entry.direction.dot(dir);
      if (entry.hasContent && entry.signatureRevision != contentRevision) {
        entry
          ..signature = staticSignatureIn(entry.matrix)
          ..signatureRevision = contentRevision;
      }
      final signatureChanged = entry.renderedSignature != entry.signature;
      final empty = entry.hasContent && entry.renderedSignature == noCasters;
      var amortizes = false;
      ShadowTileRefreshReason? reason;
      if (!entry.hasContent) {
        reason = entry.incomplete ? .incomplete : .uncached;
      } else if (invalidated) {
        reason = .invalidated;
      } else if (directionCos < _minDirectionLagCos) {
        reason = .turned;
      } else if (ideal.radius <
          entry.radius / radiusStep * (1.0 - _radiusTolerance)) {
        reason = .radius;
      } else if ((center - entry.center).length + ideal.radius >
          entry.radius * slackFactor) {
        reason = ideal.radius > entry.radius ? .radius : .drift;
      } else if (signatureChanged ||
          entry.direction.distanceToSquared(dir) > 1e-10) {
        // Usable but stale: refresh a bounded number per frame, nearest
        // cascade first (this loop runs near-to-far). An empty tile may
        // still move for free.
        amortizes = true;
        final waits =
            signatureChanged &&
            frame - entry.renderedFrame <
                light.staticShadowCasterRefreshInterval;
        if (!waits && (amortized < maxAmortizedRefreshes || empty)) {
          reason = signatureChanged ? .casters : .lightStep;
        }
      }
      if (reason != null) {
        final radius = snappedRadius(ideal.radius);
        final matrix = light.cascadeLightSpaceMatrix(
          dir,
          center,
          radius * slackFactor,
        );
        final signature = staticSignatureIn(matrix);
        final renders = !(empty && signature == noCasters);
        if (!renders || !amortizes || amortized < maxAmortizedRefreshes) {
          if (renders && amortizes) amortized++;
          entry.center.setFrom(center);
          entry.radius = radius;
          entry.boxSize = radius * slackFactor * 2.0;
          entry.matrix.setFrom(matrix);
          entry.signature = signature;
          entry.signatureRevision = contentRevision;
          entry.renderedSignature = signature;
          entry.direction.setFrom(dir);
          entry.hasContent = true;
          entry.incomplete = false;
          if (renders) {
            entry.renderedFrame = frame;
            refreshes.add(ShadowTileRefresh(i, entry, reason));
          }
        }
      }
      effective.add(
        ShadowCascade(
          lightSpaceMatrix: entry.matrix,
          splitDistance: ideal.splitDistance,
          boxSize: entry.boxSize,
          center: entry.center,
          radius: entry.radius,
        ),
      );
    }
    return ShadowCachePlan(effective, refreshes, _entries, this);
  }
}
