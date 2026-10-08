// The layouts of a shadow map, which holds the window-space depth of the
// nearest caster, and the write and read every shadow map pass goes through.
//
// Alpha names the layout of a whole target: at or above zero the 32-bit float
// layout, below zero the half float layout. A shadow map is a 32-bit float
// target where the device renders one and a half float target where it
// renders none (OpenGL ES without EXT_color_buffer_float), and the same write
// and the same clear fill either, so no writer and no reader needs to know
// which one it got.
//
// 32-bit float layout: r is the depth. The target keeps r alone and reads
// (depth, 0, 0, 1), as does the clear (1, 0, 1, -1).
//
// Half float layout: b holds the depth rounded to a multiple of 1 / 2048,
// which a half float stores exactly, and g the remainder in steps of 1 / 2048,
// at most a half, which a half float keeps to 2^-12 or better, so the depth
// keeps about 2^-23. The read b + g / 2048 is linear in the texel, so a
// filtered read is as exact as a nearest one, and the clear reads 1.
//
// Depth attachment: where the device samples a stored depth attachment, the
// shadow map is the depth the casters drew with and the color they write is
// discarded. A depth sample reads (depth, 0, 0, 1), which is the 32-bit
// float layout.

#ifndef SHADOW_DEPTH_GLSL_
#define SHADOW_DEPTH_GLSL_

const highp float kShadowDepthSteps = 2048.0;

highp vec4 EncodeShadowDepth(highp float depth) {
  highp float coarse =
      floor(depth * kShadowDepthSteps + 0.5) / kShadowDepthSteps;
  return vec4(depth, (depth - coarse) * kShadowDepthSteps, coarse, -1.0);
}

highp float ShadowDepthOf(highp vec4 texel) {
  if (texel.a >= 0.0) {
    return texel.r;
  }
  return texel.b + texel.g / kShadowDepthSteps;
}

#endif  // SHADOW_DEPTH_GLSL_
