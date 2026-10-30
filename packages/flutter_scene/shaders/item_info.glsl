// What one render item draws with that no view changes: its depth offset in
// depth-buffer steps and in pixels of its depth gradient, and its depth bias.
// It sits at an offset of its own that a draw keeps from frame to frame,
// written only when one of these changes; HeldItemInfo in
// lib/src/render/view_info.dart writes it. Include after view_info.glsl.

#ifndef ITEM_INFO_GLSL_
#define ITEM_INFO_GLSL_

uniform ItemInfo {
  // The depth-buffer steps of the draw's layer and tie-break rank (x) and of
  // one instance tie-break rank (y), and the depth bias toward the eye in
  // world units (z).
  vec4 depth_steps;
  // The pixels of depth gradient of the draw's layer (x), of one instance
  // rank (y) and of its tie-break rank (z).
  vec4 depth_pixels;
}
item_info;

// The draw's offset (xy) and one instance rank's (zw) in clip space, the
// pair ApplyDepthOffset takes.
vec4 ItemDepthOffset() {
  return vec4(item_info.depth_steps.x * view_info.depth_unit.xy,
              item_info.depth_steps.y * view_info.depth_unit.xy);
}

// The slope-scaled offsets ApplySlopedDepthOffset takes.
vec4 ItemDepthSlope() {
  return vec4(item_info.depth_pixels.xyz * view_info.depth_unit.z, 0.0);
}

#endif  // ITEM_INFO_GLSL_
