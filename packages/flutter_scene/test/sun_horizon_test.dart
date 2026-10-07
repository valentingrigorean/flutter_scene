import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/material/engine_lighting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

Float32List? _packed(DirectionalLight light) {
  late EnvironmentMap environment;
  try {
    environment = EnvironmentMap.empty();
  } catch (_) {
    return null;
  }
  final fragInfo = Float32List(EngineLightingUniforms.fragInfoFloatCount);
  EngineLightingUniforms.packInto(
    fragInfo,
    Lighting(environmentMap: environment, directionalLight: light),
    environment,
  );
  return fragInfo;
}

void main() {
  test('a light without a horizon packs full daylight and no night', () {
    final fragInfo = _packed(DirectionalLight());
    if (fragInfo == null) return;
    expect(fragInfo.sublist(208, 216), [0, 0, 0, 0, 1, 1, 1, 1]);
  });

  test('a light with a horizon packs its center, twilight, low-sun color and '
      'night ambient factor', () {
    final fragInfo = _packed(
      DirectionalLight(
        horizon: SunHorizon(
          center: Vector3(-6378, 1, 2),
          twilight: 12 * math.pi / 180,
          nightEnvironmentScale: 0.25,
          lowSunColor: Vector3(1, 0.92, 0.78),
        ),
      ),
    );
    if (fragInfo == null) return;
    final packed = fragInfo.sublist(208, 216);
    final expected = [-6378, 1, 2, 12 * math.pi / 180, 1, 0.92, 0.78, 0.25];
    for (var i = 0; i < expected.length; i++) {
      expect(packed[i], closeTo(expected[i], 1e-6));
    }
  });

  test('a light outside the item channels packs no horizon', () {
    late EnvironmentMap environment;
    try {
      environment = EnvironmentMap.empty();
    } catch (_) {
      return;
    }
    final fragInfo = Float32List(EngineLightingUniforms.fragInfoFloatCount);
    EngineLightingUniforms.packInto(
      fragInfo,
      Lighting(
        environmentMap: environment,
        directionalLight: DirectionalLight(
          channelMask: 0x01,
          horizon: SunHorizon(center: Vector3.zero()),
        ),
      ),
      environment,
      nodeChannelMask: 0x02,
    );
    expect(fragInfo[211], 0);
  });
}
