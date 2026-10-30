// The turns of a draw's VertexSpin. Include after item_info.glsl, whose
// ItemInfo block carries the spin_* members: spin_frame takes a turned vertex out of the
// space the lines are stated in, spin_axis_N holds a unit axis (xyz) and the
// turns per second (w), spin_pivot_N a point of the line (xyz) and the turns
// at the start of the folded time (w), and spin_count the number of turns
// (x). The folded seconds are view_info.camera_position.w.

mat4 SpinTurn(vec4 axis_rate, vec4 pivot_phase) {
  float angle = 6.283185307179586 *
      fract(pivot_phase.w + axis_rate.w * view_info.camera_position.w);
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
  if (item_info.spin_count.x == 0.0) {
    return local;
  }
  mat4 turned = local;
  if (item_info.spin_count.x > 1.5) {
    turned = SpinTurn(item_info.spin_axis_1, item_info.spin_pivot_1) * turned;
  }
  turned = SpinTurn(item_info.spin_axis_0, item_info.spin_pivot_0) * turned;
  return item_info.spin_frame * turned;
}
