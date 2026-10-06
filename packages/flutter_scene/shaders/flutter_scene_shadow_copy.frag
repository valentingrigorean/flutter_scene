// Replays a cached static shadow tile into the frame's shadow atlas: copies
// the stored texel, in either layout of shadow_depth.glsl, into the color
// (what the lit shader samples) and its depth into the fragment depth (so the
// dynamic casters drawn after this depth-test correctly against the cached
// static geometry).

precision highp float;

#include <shadow_depth.glsl>

uniform highp sampler2D source_texture;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  highp vec4 texel = texture(source_texture, v_uv);
  frag_color = texel;
  gl_FragDepth = ShadowDepthOf(texel);
}
