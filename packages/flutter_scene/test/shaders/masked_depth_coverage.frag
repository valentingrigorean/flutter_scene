// A material's own masked depth fragment, written the way
// Material.maskedDepthFragmentShader documents it: it defines
// DEPTH_MASK_COVERAGE, includes an engine masked fragment and defines
// DepthMaskCoverage. MASKED_DEPTH_SHADOW or MASKED_DEPTH_NORMAL picks the
// engine fragment; without either it includes the linear depth one.

#define DEPTH_MASK_COVERAGE
#if defined(MASKED_DEPTH_SHADOW)
#include <flutter_scene_depth_only_masked.frag>
#elif defined(MASKED_DEPTH_NORMAL)
#include <flutter_scene_linear_depth_normal_masked.frag>
#else
#include <flutter_scene_linear_depth_masked.frag>
#endif

float DepthMaskCoverage() {
  vec2 uv = fract(
      MaterialTextureUv(mask_info.uv_transform, mask_info.uv_rotation));
  return texture(mask_texture, uv).a * mask_info.params.y;
}
