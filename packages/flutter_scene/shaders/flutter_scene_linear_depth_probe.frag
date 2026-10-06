// Measures whether the linear depth target reads back a known depth, for the
// probe in linear_depth_probe.dart.
//
// The write draw (mode y = 0) writes a known depth into each texel of a 4x4
// target through EncodeLinearDepth, in the layout mode x names. The check draw
// (mode y = 1) reads that target back through LinearDepthOf and writes green
// where the depth reads within one part in a million of the known depth, red
// elsewhere. A target the device cannot render holds no known depth, so its
// check reads red. The decode draw (mode y = 2) writes the decoded texel of
// any linear depth target: the depth in r, the octahedral normal mapped to
// [0, 1] in g and b and the roughness in a, for a test that reads one back.

precision highp float;

#include <linear_depth.glsl>

uniform ProbeInfo {
  // x: 1 for the half float layout of linear_depth.glsl, else 0. y: 0 for the
  // write draw, 1 for the check draw, 2 for the decode draw.
  vec4 mode;
}
info;

uniform highp sampler2D written;

out vec4 frag_color;

const highp float kProbeDepths[16] = float[16](
    0.003, 0.0123, 0.25, 0.9999, 1.5, 7.77, 42.4242, 100.001, 777.777,
    1234.5678, 4096.003, 31415.9, 65432.1, 123456.7, 543210.9, 1000000.0);

void main() {
  ivec2 texel = ivec2(gl_FragCoord.xy);
  if (info.mode.y > 1.5) {
    highp vec4 stored = texelFetch(written, texel, 0);
    frag_color = vec4(LinearDepthOf(stored),
                      LinearDepthOctNormalOf(stored) * 0.5 + 0.5,
                      LinearDepthRoughnessOf(stored));
    return;
  }
  highp float depth = kProbeDepths[texel.y * 4 + texel.x];
  if (info.mode.y < 0.5) {
    frag_color = EncodeLinearDepth(depth, vec2(0.0), 1.0, info.mode.x);
    return;
  }
  highp float read = LinearDepthOf(texelFetch(written, texel, 0));
  bool holds = abs(read - depth) <= depth * 1.0e-6;
  frag_color = holds ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
