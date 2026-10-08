import 'dart:math' as math;

import 'package:flutter_scene/scene.dart'
    show Node, PerspectiveCamera, ShadowTileRefreshReason;
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/light.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/shadow_cache.dart';
import 'package:vector_math/vector_math.dart';

ShadowCascade cascade(Vector3 center, double radius, double split) =>
    ShadowCascade(
      lightSpaceMatrix: Matrix4.identity(),
      splitDistance: split,
      boxSize: radius * 2.0,
      center: center,
      radius: radius,
    );

List<ShadowCascade> idealCascades({Vector3? offset}) {
  final o = offset ?? Vector3.zero();
  return [
    cascade(Vector3(0, 0, 5) + o, 6.0, 10.0),
    cascade(Vector3(0, 0, 20) + o, 25.0, 45.0),
  ];
}

void main() {
  late DirectionalLight light;
  late DirectionalShadowCache cache;

  setUp(() {
    light = DirectionalLight()
      ..direction = Vector3(0.3, -1.0, 0.2).normalized()
      ..shadowMapResolution = 512;
    cache = DirectionalShadowCache();
  });

  ShadowCachePlan plan(List<ShadowCascade> ideal, {int signature = 1}) =>
      cache.plan(
        light: light,
        lightDirection: light.direction,
        idealCascades: ideal,
        contentRevision: signature,
        staticSignatureIn: (_) => signature,
      );

  // Plans against point casters: a tile's signature covers the casters
  // inside the box its matrix draws.
  ShadowCachePlan planOver(
    List<ShadowCascade> ideal,
    List<Vector3> casters, {
    required int revision,
  }) => cache.plan(
    light: light,
    lightDirection: light.direction,
    idealCascades: ideal,
    contentRevision: revision,
    staticSignatureIn: (matrix) {
      var signature = DirectionalShadowCache.noCasters;
      for (final (index, caster) in casters.indexed) {
        final clip = matrix.transformed3(caster);
        if (clip.x.abs() <= 1 && clip.y.abs() <= 1 && clip.z.abs() <= 1) {
          signature += 1 << index;
        }
      }
      return signature;
    },
  );

  test('a caster that arrives outside a tile\'s box leaves the tile, and one '
      'inside a box refreshes that tile alone', () {
    final near = Vector3(0, 0, 5);
    expect(planOver(idealCascades(), [near], revision: 1).refreshes.length, 2);

    final outside = Vector3(500, 0, 0);
    expect(
      planOver(idealCascades(), [near, outside], revision: 2).refreshes,
      isEmpty,
    );

    // Inside the far cascade's box and outside the near one's.
    final far = Vector3(0, 0, 40);
    final arrived = planOver(idealCascades(), [
      near,
      outside,
      far,
    ], revision: 3);
    expect(arrived.refreshes.single.cascadeIndex, 1);
    expect(arrived.refreshes.single.reason, ShadowTileRefreshReason.casters);
    expect(
      planOver(idealCascades(), [near, outside, far], revision: 3).refreshes,
      isEmpty,
    );
  });

  test('a subtree the light names re-renders at once every tile its casters '
      'draw into and no other, once', () {
    final near = Vector3(0, 0, 5);
    final far = Vector3(0, 0, 40);
    final nearNode = Node(name: 'near');
    final farNode = Node(name: 'far');
    final at = {nearNode: near, farNode: far};
    ShadowCachePlan planNamed(int revision) => cache.plan(
      light: light,
      lightDirection: light.direction,
      idealCascades: idealCascades(),
      contentRevision: revision,
      staticSignatureIn: (_) => revision,
      castersIn: (matrix, casters) => casters.any((caster) {
        final clip = matrix.transformed3(at[caster]!);
        return clip.x.abs() <= 1 && clip.y.abs() <= 1 && clip.z.abs() <= 1;
      }),
    );
    expect(planNamed(1).refreshes.length, 2);

    light.invalidateStaticShadowsOf(farNode);
    final named = planNamed(1);
    expect(named.refreshes.single.cascadeIndex, 1);
    expect(
      named.refreshes.single.reason,
      ShadowTileRefreshReason.invalidatedCasters,
    );
    expect(planNamed(1).refreshes, isEmpty);

    // Both tiles hold the near caster: they re-render in one frame, where a
    // caster change the cache sees on its own refreshes one tile a frame.
    light.invalidateStaticShadowsOf(nearNode);
    final both = planNamed(2);
    expect(both.refreshes.map((refresh) => refresh.cascadeIndex), [0, 1]);
    expect(
      both.refreshes.map((refresh) => refresh.reason),
      everyElement(ShadowTileRefreshReason.invalidatedCasters),
    );
    expect(planNamed(2).refreshes, isEmpty);
  });

  test('a light that no longer keeps every subtree named since a plan '
      're-renders every tile', () {
    plan(idealCascades());
    for (var index = 0; index < 300; index++) {
      light.invalidateStaticShadowsOf(Node());
    }
    final p = cache.plan(
      light: light,
      lightDirection: light.direction,
      idealCascades: idealCascades(),
      contentRevision: 1,
      staticSignatureIn: (_) => 1,
      castersIn: (_, _) => false,
    );
    expect(p.refreshes.map((refresh) => refresh.reason), [
      ShadowTileRefreshReason.invalidated,
      ShadowTileRefreshReason.invalidated,
    ]);
    expect(plan(idealCascades()).refreshes, isEmpty);
  });

  test('a tile that holds no caster follows its cascade to a box that holds '
      'none without a render, and renders once a caster stands in its box', () {
    expect(planOver(idealCascades(), [], revision: 1).refreshes.length, 2);

    final offset = Vector3(40, 0, 0);
    final moved = planOver(idealCascades(offset: offset), [], revision: 1);
    expect(moved.refreshes, isEmpty);
    for (final (index, cascade) in idealCascades(offset: offset).indexed) {
      final effective = moved.cascades[index];
      expect(
        (cascade.center! - effective.center!).length + cascade.radius,
        lessThanOrEqualTo(effective.boxSize / 2 + 1e-9),
      );
    }

    light.invalidateStaticShadows();
    expect(
      planOver(idealCascades(offset: offset), [], revision: 1).refreshes,
      isEmpty,
    );

    final arrived = planOver(idealCascades(offset: offset), [
      Vector3(40, 0, 5),
    ], revision: 2);
    expect(arrived.refreshes, isNotEmpty);
    expect(arrived.refreshes.first.cascadeIndex, 0);

    // A tile that holds a caster renders to follow its cascade.
    final back = planOver(idealCascades(), [Vector3(40, 0, 5)], revision: 2);
    expect(back.refreshes.map((refresh) => refresh.cascadeIndex), contains(0));
  });

  test('first frame refreshes every cascade', () {
    final p = plan(idealCascades());
    expect(p.refreshes.length, 2);
    expect(p.cascades.length, 2);
    // Effective boxes carry the slack.
    expect(
      p.cascades[0].boxSize,
      closeTo(
        DirectionalShadowCache.snappedRadius(6.0) *
            DirectionalShadowCache.slackFactor *
            2.0,
        1e-9,
      ),
    );
  });

  test('a stable view refreshes nothing and keeps the same matrices', () {
    plan(idealCascades());
    final p = plan(idealCascades());
    expect(p.refreshes, isEmpty);
    final q = plan(idealCascades());
    expect(q.cascades[1].lightSpaceMatrix, p.cascades[1].lightSpaceMatrix);
  });

  test('drift within the slack keeps the cached tiles', () {
    plan(idealCascades());
    // 10% of the small cascade's radius, under the 15% slack.
    final p = plan(idealCascades(offset: Vector3(0.6, 0, 0)));
    expect(p.refreshes, isEmpty);
  });

  test('drift past the slack re-renders the cascade that no longer fits', () {
    plan(idealCascades());
    // 20% of the near cascade's radius (over the slack), but only 4.8% of
    // the far cascade's.
    final p = plan(idealCascades(offset: Vector3(1.2, 0, 0)));
    expect(p.refreshes.length, 1);
    expect(p.refreshes.single.cascadeIndex, 0);
  });

  test('content changes refresh amortized, nearest cascade first', () {
    plan(idealCascades());
    final p1 = plan(idealCascades(), signature: 2);
    expect(p1.refreshes.length, DirectionalShadowCache.maxAmortizedRefreshes);
    expect(p1.refreshes.first.cascadeIndex, 0);
    final p2 = plan(idealCascades(), signature: 2);
    expect(p2.refreshes.length, 1);
    expect(p2.refreshes.first.cascadeIndex, 1);
    final p3 = plan(idealCascades(), signature: 2);
    expect(p3.refreshes, isEmpty);
  });

  test('a small light turn refreshes amortized, nearest cascade first', () {
    plan(idealCascades());
    // A 2 degree step, inside the lag tolerance.
    light.direction = Quaternion.axisAngle(
      Vector3(0, 0, 1),
      2.0 * degrees2Radians,
    ).rotated(light.direction);
    final p1 = plan(idealCascades());
    expect(p1.refreshes.length, DirectionalShadowCache.maxAmortizedRefreshes);
    expect(p1.refreshes.single.cascadeIndex, 0);
    // The far cascade still samples through its old matrix.
    final oldFar = Matrix4.copy(p1.cascades[1].lightSpaceMatrix);
    final p2 = plan(idealCascades());
    expect(p2.refreshes.single.cascadeIndex, 1);
    expect(p2.cascades[1].lightSpaceMatrix, isNot(oldFar));
    expect(plan(idealCascades()).refreshes, isEmpty);
  });

  test('a large light turn re-renders everything', () {
    plan(idealCascades());
    light.direction = Vector3(-0.5, -1.0, 0.1).normalized();
    final p = plan(idealCascades());
    expect(p.refreshes.length, 2);
  });

  test('a resolution change rebuilds everything', () {
    plan(idealCascades());
    light.shadowMapResolution = 1024;
    final p = plan(idealCascades());
    expect(p.refreshes.length, 2);
  });

  test('a shadow-caster channel change rebuilds everything', () {
    plan(idealCascades());
    expect(plan(idealCascades()).refreshes, isEmpty);
    light.shadowCasterChannelMask = 0x0F;
    expect(plan(idealCascades()).refreshes.length, 2);
  });

  test('invalidating the static shadows refreshes every cascade in one frame '
      'and keeps the tiles', () {
    final first = plan(idealCascades());
    final entries = List.of(first.entries);
    expect(plan(idealCascades()).refreshes, isEmpty);
    light.invalidateStaticShadows();
    final p = plan(idealCascades());
    expect(p.refreshes.map((r) => r.cascadeIndex), [0, 1]);
    expect(p.entries, orderedEquals(entries));
    expect(plan(idealCascades()).refreshes, isEmpty);
  });

  test('invalidating the static shadows also refreshes a content change '
      'without amortizing it', () {
    plan(idealCascades());
    light.invalidateStaticShadows();
    expect(plan(idealCascades(), signature: 2).refreshes.length, 2);
    expect(plan(idealCascades(), signature: 2).refreshes, isEmpty);
  });

  test('a new cache takes the light as it finds it', () {
    light.invalidateStaticShadows();
    expect(plan(idealCascades()).refreshes.length, 2);
    expect(plan(idealCascades()).refreshes, isEmpty);
  });

  group('a zoom whose near plane follows the camera distance, so the '
      'cascade radii change on every frame, keeps its tiles from one '
      'radius step to the next', () {
    final target = Vector3.zero();
    final toEye = Vector3(0, 0.6, -0.8);

    List<ShadowCascade> idealAt(double distance, {required bool pinned}) {
      final near = distance / 50;
      // A first cascade pinned to a multiple of the near plane's power of two
      // moves the later splits in steps and leaves the first radius following
      // the near plane.
      light.firstCascadeFarBound = pinned
          ? 16.0 * math.pow(2, (math.log(near) / math.ln2).floor())
          : null;
      return light.computeCascades(
        PerspectiveCamera(
          position: target + toEye * distance,
          target: target,
          fovNear: near,
          fovFar: 50000,
        ),
        16 / 9,
      );
    }

    // A pinned first cascade leaves its tile as the camera moves, as in a pan;
    // the free cascades only change radius.
    for (final (pinned, limit) in [(false, 10), (true, 18)]) {
      for (final (name, step) in [('out', 1.01), ('in', 1 / 1.01)]) {
        test('zooming $name, first cascade ${pinned ? 'pinned' : 'free'}', () {
          light
            ..shadowCascadeCount = 4
            ..shadowMapResolution = 1024
            ..shadowMaxDistance = 8000;
          var distance = 1000.0;
          expect(plan(idealAt(distance, pinned: pinned)).refreshes.length, 4);
          var refreshes = 0;
          var most = 0;
          for (var frame = 0; frame < 60; frame++) {
            distance *= step;
            final count = plan(
              idealAt(distance, pinned: pinned),
            ).refreshes.length;
            refreshes += count;
            most = math.max(most, count);
          }
          printOnFailure('$refreshes refreshes, at most $most in a frame');
          expect(refreshes, lessThanOrEqualTo(limit));
          expect(most, lessThan(4));
        });
      }
    }
  });

  test('a tile serves every ideal radius down to one radius step below the '
      'radius it was rendered for', () {
    const step = DirectionalShadowCache.radiusStep;
    final rendered = plan([cascade(Vector3.zero(), 10.0, 10.0)]);
    final radius = rendered.cascades.single.radius;
    expect(radius, greaterThanOrEqualTo(10.0));
    expect(radius, lessThan(10.0 * step));
    final matrix = Matrix4.copy(rendered.cascades.single.lightSpaceMatrix);

    final smaller = plan([cascade(Vector3.zero(), radius / step * 1.01, 10.0)]);
    expect(smaller.refreshes, isEmpty);
    expect(smaller.cascades.single.lightSpaceMatrix, matrix);

    final below = plan([cascade(Vector3.zero(), radius / step * 0.9, 10.0)]);
    expect(below.refreshes.length, 1);
    expect(below.cascades.single.radius, closeTo(radius / step, 1e-9));
  });

  test('a cached tile always covers the ideal sphere it is sampled for', () {
    final random = math.Random(7);
    var center = Vector3.zero();
    var radius = 10.0;
    for (var frame = 0; frame < 500; frame++) {
      center += Vector3(
        random.nextDouble() - 0.5,
        0,
        random.nextDouble() - 0.5,
      );
      radius *= 0.97 + random.nextDouble() * 0.06;
      final effective = plan([cascade(center, radius, 10.0)]).cascades.single;
      expect(
        (center - effective.center!).length + radius,
        lessThanOrEqualTo(effective.boxSize / 2 + 1e-9),
      );
    }
  });
}
