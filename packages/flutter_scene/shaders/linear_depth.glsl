// The layouts of the linear depth target the depth prepass writes, and the
// reads every consumer of that target goes through.
//
// The target holds planar view depth in world units in one of two layouts,
// and each texel names its own: alpha at or above zero is the 32-bit float
// layout, alpha below zero the half float layout. The prepass writes the half
// float layout where the device renders no 32-bit float color target (OpenGL
// ES without EXT_color_buffer_float), so a reader never needs to know which
// one the frame took.
//
// 32-bit float layout: r is the depth, g and b the octahedral view normal in
// [-1, 1] and a the perceptual roughness. A target without normals reads
// (depth, 0, 0, 1).
//
// Half float layout: the depth is (r + g / 1024) * 16. r holds depth / 16 cut
// to the 11 significant bits a half float carries and g the remainder times
// 1024, so a read keeps the depth to about one part in two million up to
// 65504 * 16 world units. b is 256 times the high three bits of the roughness
// in 63 steps plus the octahedral x in 254 steps, and -a - 1 the same for the
// low three bits and y. Every value is an integer a half float holds exactly.
// A target without normals holds a zero normal and roughness 1, as the 32-bit
// float layout reads.

#ifndef LINEAR_DEPTH_GLSL_
#define LINEAR_DEPTH_GLSL_

const highp float kSplitDepthUnit = 16.0;
const highp float kSplitDepthLow = 1024.0;
const highp float kSplitDepthMost = 65504.0;
const highp float kSplitDepthLeastNormal = 6.103515625e-5;
const float kSplitNormalSteps = 254.0;
const float kSplitRoughnessSteps = 63.0;

highp float LinearDepthOf(highp vec4 texel) {
  return texel.a < 0.0
             ? (texel.r + texel.g / kSplitDepthLow) * kSplitDepthUnit
             : texel.r;
}

vec2 SplitNormalPacked(highp vec4 texel) {
  return vec2(texel.b, -texel.a - 1.0);
}

vec2 LinearDepthOctNormalOf(highp vec4 texel) {
  if (texel.a >= 0.0) {
    return texel.gb;
  }
  vec2 packed = SplitNormalPacked(texel);
  vec2 roughness = floor((packed + 0.5) / 256.0);
  return (packed - roughness * 256.0) / (kSplitNormalSteps * 0.5) - 1.0;
}

float LinearDepthRoughnessOf(highp vec4 texel) {
  if (texel.a >= 0.0) {
    return texel.a;
  }
  vec2 roughness = floor((SplitNormalPacked(texel) + 0.5) / 256.0);
  return (roughness.x * 8.0 + roughness.y) / kSplitRoughnessSteps;
}

highp vec2 SplitLinearDepth(highp float depth) {
  highp float v = min(abs(depth) / kSplitDepthUnit, kSplitDepthMost);
  highp float step =
      exp2(floor(log2(max(v, kSplitDepthLeastNormal))) - 10.0);
  if (v >= step * 2048.0) {
    step *= 2.0;
  }
  highp float high = floor(v / step) * step;
  highp vec2 split = vec2(high, (v - high) * kSplitDepthLow);
  return depth < 0.0 ? -split : split;
}

highp vec4 EncodeLinearDepth(highp float depth, vec2 oct, float roughness,
                             float split) {
  if (split < 0.5) {
    return vec4(depth, oct, roughness);
  }
  vec2 steps =
      floor((clamp(oct, -1.0, 1.0) * 0.5 + 0.5) * kSplitNormalSteps + 0.5);
  float level = floor(clamp(roughness, 0.0, 1.0) * kSplitRoughnessSteps + 0.5);
  float high = floor(level / 8.0);
  vec2 packed = vec2(high, level - high * 8.0) * 256.0 + steps;
  return vec4(SplitLinearDepth(depth), packed.x, -packed.y - 1.0);
}

#endif  // LINEAR_DEPTH_GLSL_
