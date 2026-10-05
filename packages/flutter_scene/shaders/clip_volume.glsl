// The clip volume of a material (ClipVolume in Dart): a convex region of world
// space whose fragments are discarded. A fragment is inside when it lies on the
// positive side of every plane, dot(plane, vec4(world, 1)) > 0. The engine pads
// a volume of fewer planes with (0, 0, 0, 1), which every point lies in front
// of, and binds a zero block for a material without one: the first plane then
// keeps every fragment, so an unclipped draw pays one dot product.
//
// Requires the world-space varying v_position (material_varyings.glsl).

uniform ClipInfo {
  vec4 planes[6];
}
clip_info;

// Discards the fragment when it lies inside the material's clip volume.
void ApplyClipVolume() {
  vec4 at = vec4(v_position, 1.0);
  for (int i = 0; i < 6; i++) {
    if (dot(clip_info.planes[i], at) <= 0.0) {
      return;
    }
  }
  discard;
}
