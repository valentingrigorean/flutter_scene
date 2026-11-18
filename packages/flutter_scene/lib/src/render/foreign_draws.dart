/// The draws an app makes itself into pass indices of a scene's item set,
/// at the places in a frame where the scene draws its own kept draws.
library;

import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart' show Lighting;

/// Where in a frame a [ForeignSite] stands.
enum ForeignSiteKind {
  /// The depth prepass, after the scene's kept draws and before its encoded
  /// ones.
  prepass,

  /// A directional shadow cascade's tile of the shadow atlas, after the
  /// scene's kept casters, while no static shadow cache holds the cascade.
  cascade,

  /// A refresh of a cascade's cached static shadow tile, after the scene's
  /// static casters: where a static shadow cache holds the cascade, its
  /// static content is drawn only here.
  staticTile,

  /// The color pass's opaque phase, at one of [ForeignDraws.opaqueOrders].
  opaque,

  /// The color pass's translucent phase, at one of
  /// [ForeignDraws.translucentOrders], where the app's draws take their place
  /// by depth among the scene's of that order ([ForeignSite.merge],
  /// [ForeignSite.fartherThan]).
  translucent,
}

/// What the scene hands [ForeignDraws.draw] at one place of a frame: the
/// open render pass and what the scene's own kept draw there is given.
final class ForeignSite {
  /// A site of [kind]; the scene makes them.
  ForeignSite({
    required this.kind,
    required this.items,
    required this.pass,
    required this.target,
    required this.viewBlocks,
    required this.clip,
    this.viewTextures = const [],
    this.sort = gpu.ItemSort.key,
    this.cascade = 0,
    this.order = 0,
    this.layerMask = 0xFFFFFFFF,
    this.primaryView = true,
    this.lighting,
    this.merge,
    this.fartherThan,
    this.notFartherThan,
  });

  /// Where in the frame the site stands.
  final ForeignSiteKind kind;

  /// The scene's item set, whose pass indices from
  /// [ForeignDraws.firstPass] the app fills. The scene makes it again when
  /// the GPU context is reopened or the app's view blocks change.
  final gpu.ItemSet items;

  /// The open render pass, under the viewport of the site.
  final gpu.RenderPass pass;

  /// The render target [pass] draws into.
  final gpu.RenderTarget target;

  /// The view blocks the scene's kept draw here is given, the app's blocks
  /// among them.
  final List<ByteData> viewBlocks;

  /// The matrix into clip space the scene's kept draw here is culled by,
  /// column-major.
  final Float32List clip;

  /// The view textures the scene's kept draw here is given.
  final List<gpu.Texture> viewTextures;

  /// The order the scene's kept draws here are drawn in.
  final gpu.ItemSort sort;

  /// The cascade of a [ForeignSiteKind.cascade] or
  /// [ForeignSiteKind.staticTile] site, else 0.
  final int cascade;

  /// The render order of an [ForeignSiteKind.opaque] or
  /// [ForeignSiteKind.translucent] site, else 0.
  final double order;

  /// The layers the view draws; all for a shadow site.
  final int layerMask;

  /// Whether the view is the frame's primary view, the one a camera replay
  /// records.
  final bool primaryView;

  /// The lighting the scene's own materials bind with at an
  /// [ForeignSiteKind.opaque] or [ForeignSiteKind.translucent] site, which a
  /// material drawn there binds with and picks its fragment shader by; null
  /// at a depth or shadow site. The app states its draw on such a material
  /// with `Material.drawsAs` before it binds it, as the scene does for its
  /// own draws.
  final Lighting? lighting;

  /// At a [ForeignSiteKind.translucent] site, the pass index that holds the
  /// scene's kept draws of the site's render order, which the app draws
  /// with its own in one order by depth (the `merge` of [gpu.ItemSet.draw]);
  /// null where the scene keeps none of that order, or draws them itself.
  ///
  /// The scene draws that pass index itself only where [ForeignDraws.draw]
  /// returns null, so an app that draws at a site with a [merge] passes it
  /// on.
  final int? merge;

  /// At a [ForeignSiteKind.translucent] site, the key [sort] gives the draw
  /// of the scene's that follows this call: the app draws its items farther
  /// than it (the `fartherThan` of [gpu.ItemSet.draw]), and the scene's draw
  /// then blends over them. Null where no draw of the site's render order
  /// follows, and the app draws through its nearest item.
  ///
  /// The scene calls the site before each of its draws of the site's render
  /// order that it encodes itself, farthest first, and once after the last,
  /// so each call's range starts where the last one ended
  /// ([notFartherThan]); a draw no nearer than the one before it takes no
  /// call. A frame in which the app drew such a range is not one a camera
  /// replays (`Scene.cameraFrame`).
  final double? fartherThan;

  /// At a [ForeignSiteKind.translucent] site, the [fartherThan] of the last
  /// call of this site in the frame, past which the app drew then (the
  /// `notFartherThan` of [gpu.ItemSet.draw]); null at the first call, where
  /// the app draws from its farthest item.
  final double? notFartherThan;
}

/// The draws an app makes itself into pass indices [firstPass] to
/// [firstPass] + [passes] - 1 of a scene's item set, from native code that
/// holds the items there (`Scene.foreignDraws`).
///
/// At each place of a frame the scene calls [draw] with a [ForeignSite]: in
/// the depth prepass, each shadow cascade or static shadow tile refresh,
/// and in the color pass at each of [opaqueOrders] among the opaque draws
/// and each of [translucentOrders] among the translucent ones. A foreign
/// draw of a render order draws after every draw of the scene of a lower
/// order and before any of a higher one. Among the scene's draws of its own
/// order an opaque one draws last, and a translucent one draws by depth,
/// back to front, as the scene orders its own: with the scene's kept draws
/// of that order in one sorted draw ([ForeignSite.merge]), or in the ranges
/// of depth between the draws the scene encodes
/// ([ForeignSite.fartherThan]). [draw] returns the index it drew, which the
/// scene records for a camera replay as it records its own kept draw at the
/// site, or null where it drew nothing. Spot and point light shadow maps
/// have no site, so the app's draws cast no shadow from those lights.
///
/// The scene knows the app's static shadow casters through
/// [castsStaticShadows] and [staticSignatureIn]; the app calls
/// `Scene.markForeignShadowCastersChanged` when either answer changes.
final class ForeignDraws {
  /// Draws through [draw] at the sites of a frame.
  ForeignDraws({
    required this.draw,
    List<double> opaqueOrders = const [],
    List<double> translucentOrders = const [],
    this.castsStaticShadows,
    this.staticSignatureIn,
  }) : opaqueOrders = List.unmodifiable(opaqueOrders.toList()..sort()),
       translucentOrders = List.unmodifiable(
         translucentOrders.toList()..sort(),
       );

  /// The first pass index of the scene's item set the app fills.
  static const int firstPass = 56;

  /// The number of pass indices the app fills.
  static const int passes = 8;

  /// Draws at [site], and returns the pass index drawn, or null for none.
  final int? Function(ForeignSite site) draw;

  /// The render orders at which the color pass's opaque phase calls [draw],
  /// ascending.
  final List<double> opaqueOrders;

  /// The render orders at which the color pass's translucent phase calls
  /// [draw], ascending.
  final List<double> translucentOrders;

  /// Whether the app draws any static shadow caster; none where null.
  final bool Function()? castsStaticShadows;

  /// A fingerprint of the app's static shadow casters inside the frustum of
  /// a shadow tile rendered with the light-space matrix it is given, 0 for
  /// none. A cached static shadow tile whose fingerprint changed is
  /// rendered again.
  final int Function(Matrix4 lightSpaceMatrix)? staticSignatureIn;
}
