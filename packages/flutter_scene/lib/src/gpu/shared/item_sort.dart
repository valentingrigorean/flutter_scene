/// The order a pass draws its kept render items in.
enum ItemSort {
  /// The backend's own order, which groups items that share state; for
  /// draws whose order does not change what they draw, such as depth-tested
  /// opaque draws.
  key,

  /// Back to front: the farthest item first, by the clip-space `w` of its
  /// bounds' centre, for blended draws. Where the clip matrix gives every
  /// point one `w` (an orthographic view), by the clip-space depth `z`
  /// instead, the greater farther. An item with no bounds sorts at 0.
  farthestFirst,

  /// [farthestFirst] for a view with reversed depth (1 at the near plane):
  /// where the clip matrix gives every point one `w`, the lesser `z` is
  /// farther.
  farthestFirstReversedDepth,
}
