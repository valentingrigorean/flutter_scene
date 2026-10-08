// The clip volume of a material (ClipVolume in Dart): a convex region of world
// space whose fragments are discarded, and a convex region outside which every
// fragment is discarded.
//
// The cut region: a fragment is inside when it lies on the positive side of
// every plane, dot(plane, vec4(world, 1)) > 0. The engine pads a volume of
// fewer planes with (0, 0, 0, 1), which every point lies in front of, and
// writes zero planes for a volume with no cut plane: the first plane then
// cuts nothing.
//
// The keep region: a fragment behind any keep plane,
// dot(plane, vec4(world, 1)) < 0, is discarded. The engine pads a volume of
// fewer keep planes with zero planes, which keep every point.
//
// A material without a volume binds a zero block, which keeps every fragment.
//
// Requires the world-space varying v_position (material_varyings.glsl).

uniform ClipInfo {
  vec4 planes[6];
  vec4 keep[4];
}
clip_info;

// Discards the fragment when it lies outside the material's keep region or
// inside its cut region.
void ApplyClipVolume() {
  vec4 at = vec4(v_position, 1.0);
  for (int i = 0; i < 4; i++) {
    if (dot(clip_info.keep[i], at) < 0.0) {
      discard;
    }
  }
  for (int i = 0; i < 6; i++) {
    if (dot(clip_info.planes[i], at) <= 0.0) {
      return;
    }
  }
  discard;
}
