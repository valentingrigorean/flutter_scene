// The per-row band test of an instanced draw (InstanceBand). Include after
// the FrameInfo block, which carries the band_* members.

float InstanceBandHash(vec3 translation) {
  vec3 p = fract(translation * vec3(0.1031, 0.1030, 0.0973));
  float d = dot(p, p.yxz + 33.33);
  return fract((p.x + d + p.y + d) * (p.z + d));
}

// Whether the row whose record under its node is node_record draws in this
// view. record_translation is the translation of the record as stored, so the
// hash holds when the node moves.
bool InstanceBandHolds(mat4 node_record, vec3 record_translation) {
  if (frame_info.band_eye.w == 0.0) {
    return true;
  }
  float hash = InstanceBandHash(record_translation);
  if (hash >= frame_info.band_edge.y) {
    return false;
  }
  vec3 center = (node_record * vec4(frame_info.band_sphere.xyz, 1.0)).xyz;
  mat3 axes = mat3(node_record);
  float scale = sqrt(max(dot(axes[0], axes[0]),
                         max(dot(axes[1], axes[1]), dot(axes[2], axes[2]))));
  float radius = frame_info.band_sphere.w * scale;
  vec3 to_center = center - frame_info.band_eye.xyz;
  float eye_distance = length(to_center);
  float edge = 1.0 + frame_info.band_edge.x * (hash - 0.5);
  float near_edge =
      max(frame_info.band_reach.x * radius, frame_info.band_reach.z) * edge;
  float far_edge =
      min(frame_info.band_reach.y * radius, frame_info.band_reach.w) * edge;
  if (eye_distance <= near_edge || eye_distance > far_edge) {
    return false;
  }
  float nearest = dot(to_center, frame_info.band_forward.xyz) - radius;
  return nearest >= frame_info.band_edge.z && nearest < frame_info.band_edge.w;
}
