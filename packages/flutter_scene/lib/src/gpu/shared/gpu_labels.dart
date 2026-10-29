/// The label a command buffer or render pass made without one takes.
library;

import 'package:meta/meta.dart';

/// The name of the render graph pass that runs now, which a command buffer
/// or render pass created without a label takes, so a GPU capture or trace
/// names the pass; null outside a pass.
@internal
String? activeGpuPassLabel;
