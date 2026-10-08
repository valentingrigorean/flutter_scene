// The turns of a draw's VertexSpin. Include after the FrameInfo block, which
// carries the spin_* members: spin_frame takes a turned vertex out of the
// space the lines are stated in, spin_axis_N holds a unit axis (xyz) and the
// turns per second (w), spin_pivot_N a point of the line (xyz) and the turns
// at the start of the folded time (w), and spin_time the folded seconds (x)
// and the number of turns (y).

mat4 SpinTurn(vec4 axis_rate, vec4 pivot_phase) {
  float angle = 6.283185307179586 *
      fract(pivot_phase.w + axis_rate.w * frame_info.spin_time.x);
  float c = cos(angle);
  float s = sin(angle);
  float t = 1.0 - c;
  vec3 a = axis_rate.xyz;
  mat3 turn = mat3(
      t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y,
      t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x,
      t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c);
  vec3 p = pivot_phase.xyz;
  mat4 result = mat4(turn);
  result[3] = vec4(p - turn * p, 1.0);
  return result;
}

// The transform a vertex takes before its record: local alone without a
// spin, else local, the turns from the last to the first, and spin_frame.
mat4 SpinLocal(mat4 local) {
  if (frame_info.spin_time.y == 0.0) {
    return local;
  }
  mat4 turned = local;
  if (frame_info.spin_time.y > 1.5) {
    turned = SpinTurn(frame_info.spin_axis_1, frame_info.spin_pivot_1) * turned;
  }
  turned = SpinTurn(frame_info.spin_axis_0, frame_info.spin_pivot_0) * turned;
  return frame_info.spin_frame * turned;
}
