// Measures whether a stored depth attachment reads back as a texture, for
// the probe in stored_depth_probe.dart.
//
// The fill draw (mode x = 0) covers a 4x4 target whose depth attachment
// cleared to a known depth and writes no depth, so the attachment stores the
// clear. The check draw (mode x = 1) samples that attachment and writes green
// where its red channel holds the known depth, mode y, within one part in a
// thousand, red elsewhere. A device that cannot sample a depth attachment
// holds no known depth there, so its check reads red.

precision highp float;

uniform StoredDepthProbeInfo {
  // x: 0 for the fill draw, 1 for the check draw. y: the known depth.
  vec4 mode;
}
info;

uniform highp sampler2D stored;

out vec4 frag_color;

void main() {
  if (info.mode.x < 0.5) {
    frag_color = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }
  highp float read = texelFetch(stored, ivec2(gl_FragCoord.xy), 0).r;
  bool holds = abs(read - info.mode.y) <= 1.0e-3;
  frag_color = holds ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
