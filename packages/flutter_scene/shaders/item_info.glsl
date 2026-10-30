// What one render item draws with that no view changes: its depth offset in
// steps and pixels, its instance frame and local transform, its band and its
// turns. It sits at an offset of its own that a draw keeps from frame to
// frame, written only when one of these changes; HeldItemInfo in
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
  // The transform applied after the instance-rate model transform: a node's
  // world transform for node-space instance records, the anchor less the
  // draw origin for an anchored item, the identity otherwise.
  mat4 instance_frame;
  // The transform applied before the instance-rate model transform: the
  // draw's own placement inside each record (InstancedMesh.instanceLocal),
  // the identity otherwise.
  mat4 instance_local;
  // The band test of instance_band.glsl. band_sphere: the record-space bound
  // center (xyz) and radius (w). band_reach: the near and far reach in row
  // radii (xy) and the near and far distance (zw). band_edge: the margin (x),
  // the kept fraction (y) and whether the draw has a band (z).
  vec4 band_sphere;
  vec4 band_reach;
  vec4 band_edge;
  // The turns of vertex_spin.glsl (VertexSpin): the transform out of the
  // space the lines are stated in, each turn's axis and rate and its pivot
  // and phase, and the number of turns (x).
  mat4 spin_frame;
  vec4 spin_axis_0;
  vec4 spin_pivot_0;
  vec4 spin_axis_1;
  vec4 spin_pivot_1;
  vec4 spin_count;
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
