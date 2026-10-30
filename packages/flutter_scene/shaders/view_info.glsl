// The view a pass draws, one block per pass (each shadow cascade its own),
// which the vertex and fragment stages of every engine material read.
// ViewInfoBlock in lib/src/render/view_info.dart writes it.

#ifndef VIEW_INFO_GLSL_
#define VIEW_INFO_GLSL_

uniform ViewInfo {
  // The world-to-clip transform.
  highp mat4 camera_transform;
  // The eye (xyz) and the folded animation time vertex_spin.glsl reads (w).
  highp vec4 camera_position;
  // The camera axis (xyz) and 1 for an orthographic camera (w), for the view
  // direction under an orthographic camera, where every view ray is
  // parallel and v_viewvector (the true vector to the eye, for derivatives
  // and depth) does not point along one.
  highp vec4 camera_forward;
  // The camera a band test reads (xyz) with the view's nearest-depth range
  // start (w), and its view direction (xyz) with the range end (w); a
  // shadow pass states the camera of the primary view.
  highp vec4 band_eye;
  highp vec4 band_forward;
  // The clip-space offset of one depth-buffer step as DepthRaster.writeOffset
  // writes it (xy), and the window depth per pixel per unit of DepthSlopes
  // (z), see item_info.glsl.
  highp vec4 depth_unit;
}
view_info;

#endif  // VIEW_INFO_GLSL_
