// The layouts of a shadow map, which holds the window-space depth of the
// nearest caster, and the write and read every shadow map pass goes through.
//
// Each texel names its own layout: alpha at or above zero is the 32-bit float
// layout, alpha below zero the half float layout. A shadow map is a 32-bit
// float target where the device renders one and a half float target where it
// renders none (OpenGL ES without EXT_color_buffer_float), and the same write
// fills either, so no writer and no reader needs to know which one it got.
//
// 32-bit float layout: r is the depth. The target keeps r alone and reads
// (depth, 0, 0, 1), as does the clear to white.
//
// Half float layout: r holds the depth rounded to a half float and g the
// fraction of the depth times 512, so the depth is (k + g) / 512 for the
// whole k nearest to r * 512 - g. A half float r is off by at most 2^-11,
// a quarter of a step of 1 / 512, and a half float g by at most 2^-11 of a
// step, so a read keeps the depth to about 2^-20.

#ifndef SHADOW_DEPTH_GLSL_
#define SHADOW_DEPTH_GLSL_

const highp float kShadowDepthSteps = 512.0;

highp vec4 EncodeShadowDepth(highp float depth) {
  return vec4(depth, fract(depth * kShadowDepthSteps), 0.0, -1.0);
}

highp float ShadowDepthOf(highp vec4 texel) {
  if (texel.a >= 0.0) {
    return texel.r;
  }
  highp float step = floor(texel.r * kShadowDepthSteps - texel.g + 0.5);
  return (step + texel.g) / kShadowDepthSteps;
}

#endif  // SHADOW_DEPTH_GLSL_
