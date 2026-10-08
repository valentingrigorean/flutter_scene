// Clipped variant of the object mask fragment shader (see
// flutter_scene_mask.frag): discards the fragments the material's clip volume
// discards, and those its MASK coverage rejects, so a mask of a sliced or
// clipped surface covers it only where the color pass shows it. A draw that
// cuts no alpha binds a mask that keeps every fragment.
//
// Pairs with the engine's full vertex shaders, which supply the world-position
// varying the clip volume tests and the varyings the alpha mask reads.

// Varyings only; nothing here reads the view axis.
#define FLUTTER_SCENE_NO_VIEW_INFO
#include <material_varyings.glsl>
#include <material_inputs.glsl>
#include <depth_mask.glsl>
#include <clip_volume.glsl>

uniform MaskColor {
  // rgb: the fill color (linear); a: coverage (always 1).
  vec4 color;
}
mask_color;

void main() {
  ApplyClipVolume();
  ApplyDepthAlphaMask();
  frag_color = mask_color.color;
}
