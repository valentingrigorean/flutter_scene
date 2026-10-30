/// The reader of a flutter_gpu shader bundle: each shader's per-backend
/// entries (Metal, OpenGL ES, Vulkan SPIR-V) and their reflection, which
/// a GPU backend registered through `package:flutter_scene/gpu_backend.dart`
/// compiles its shaders from.
///
/// The names are the flatbuffer schema's; import the library with a prefix.
@experimental
library;

import 'package:meta/meta.dart' show experimental;

export 'src/gpu/web/shader_bundle_generated.dart';
