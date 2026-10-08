// Shared body for the position-only depth vertex shader and for a `.fmat`'s
// generated depth variant. Requires VertexInputs and Vertex() to be declared
// first by including material_vertex.glsl.
//
// This variant reads only the position attribute (plus the instance-rate model
// transform), so normal/uv/color are not available and are passed to Vertex()
// as zero. A material that displaces geometry purely from world_position (the
// common case, e.g. a world-space curve) casts a matching shadow and reads
// matching depth because the same displacement runs here; a displacement that
// depends on normal/uv/color does not, which is documented.
//
// In the shadow pass camera_transform is the light-space matrix and
// camera_position is a placeholder, so a camera-relative displacement is only
// correct in the shadow map once the real camera position is plumbed here.

uniform FrameInfo {
  mat4 camera_transform;
  vec3 camera_position;
  float depth_bias;
  // The draw's depth-layer offset (xy) and one instance tie-break rank's
  // (zw), see ApplyDepthOffset.
  vec4 depth_offset;
  // The color body's slope-scaled offsets, unused here: this stage reads no
  // normal, so it matches the position-only velocity pass instead.
  vec4 depth_slope;
  // The transform applied after the instance-rate model transform: a node's
  // world transform for node-space instance records, the identity otherwise.
  mat4 instance_frame;
  // The transform applied before the instance-rate model transform: the
  // draw's own placement inside each record (InstancedMesh.instanceLocal),
  // the identity otherwise.
  mat4 instance_local;
  // The band test of instance_band.glsl. band_eye: the camera the band reads
  // (xyz) and whether the draw has a band (w). band_forward: the view
  // direction (xyz). band_sphere: the record-space bound center (xyz) and
  // radius (w). band_reach: the near and far reach in row radii (xy) and the
  // near and far distance (zw). band_edge: the margin (x), the kept fraction
  // (y) and the view's nearest-depth range (zw).
  vec4 band_eye;
  vec4 band_forward;
  vec4 band_sphere;
  vec4 band_reach;
  vec4 band_edge;
}
frame_info;

#include <instance_band.glsl>

#include <depth_bias.glsl>

in vec3 position;

// Instance-rate model matrix columns (vertex buffer slot 1, advanced once per
// instance). Non-instanced draws bind a single-element buffer holding the
// node's world transform, matching the unskinned body.
in vec4 model_transform_0;
in vec4 model_transform_1;
in vec4 model_transform_2;
in vec4 model_transform_3;

// The v_* outputs are declared in material_vertex.glsl (included first), so a
// material's custom varyings can follow them with matching interpolant slots.

void main() {
  mat4 node_record =
      frame_info.instance_frame * mat4(model_transform_0, model_transform_1,
                                       model_transform_2, model_transform_3);
  if (!InstanceBandHolds(node_record, model_transform_3.xyz)) {
    // Outside the clip volume, so the row rasterizes no fragment.
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    return;
  }
  mat4 model_transform = node_record * frame_info.instance_local;
  vec4 model_position = model_transform * vec4(position, 1.0);

  VertexInputs vertex;
  vertex.position = position;
  vertex.normal = vec3(0.0);
  vertex.tangent = vec4(0.0);
  vertex.world_position = model_position.xyz;
  vertex.world_normal = vec3(0.0);
  vertex.world_tangent = vec4(0.0);
  vertex.uv = vec2(0.0);
  vertex.uv1 = vec2(0.0);
  vertex.color = vec4(0.0);
  vertex.camera_position = frame_info.camera_position;
  vertex.model_transform = model_transform;
  Vertex(vertex);

  v_position = vertex.world_position;
  vec3 draw_position = ApplyDepthBias(
      vertex.world_position, frame_info.camera_transform,
      frame_info.camera_position, frame_info.depth_bias);
  vec4 clip_position = frame_info.camera_transform * vec4(draw_position, 1.0);
  gl_Position = ApplyDepthOffset(
      clip_position, frame_info.depth_offset, model_transform[3].xyz,
      frame_info.camera_transform, draw_position, frame_info.camera_position);
  v_viewvector = frame_info.camera_position - vertex.world_position;
  v_normal = vec3(0.0);
  v_texture_coords = vec2(0.0);
  v_texture_coords_1 = vec2(0.0);
  v_color = vec4(0.0);
  v_tangent = vec4(0.0);

#ifdef MATERIAL_INSTANCE_VARYINGS
  // Forward the material's declared per-instance attributes to the fragment
  // stage (defined only when Surface() reads one through its accessor).
  MATERIAL_INSTANCE_VARYINGS
#endif

#ifdef HAS_MATERIAL_VERTEX
  // Keep the position input and the instance-rate model_transform columns
  // live so a hook that replaces world_position cannot strip them (see
  // VertexKeepAlive). Only position is fetched in the depth pass.
  gl_Position += vertex_keep_alive.keep_alive.x *
      vec4(position + model_transform_0.xyz + model_transform_1.xyz +
               model_transform_2.xyz + model_transform_3.xyz,
           0.0);
#ifdef MATERIAL_PARAMS_KEEP_ALIVE
  // Keep MaterialParams live even when Vertex() reads no parameter; the
  // runtime binds the block to the vertex stage unconditionally.
  gl_Position.x += vertex_keep_alive.keep_alive.x * MATERIAL_PARAMS_KEEP_ALIVE;
#endif
#ifdef MATERIAL_ATTRIBUTES_KEEP_ALIVE
  // Keep declared custom attributes live even when Vertex() reads none; a
  // stripped input breaks reflection and the pipeline's vertex layout.
  gl_Position.x +=
      vertex_keep_alive.keep_alive.x * MATERIAL_ATTRIBUTES_KEEP_ALIVE;
#endif
#endif
}
