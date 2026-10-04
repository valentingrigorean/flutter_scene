// Internal flutter_gpu shim. Selects a backend by Dart library: native
// re-exports package:flutter_gpu verbatim (zero cost) and is the default the
// analyzer reads, so a caller's package:flutter_gpu types are the shim's own;
// web is a WebGL2 implementation. flutter_scene imports this internally; the
// curated public surface lives in `package:flutter_scene/gpu.dart`.
export 'impeller/_gpu.dart' if (dart.library.js_interop) 'web/_gpu.dart';

// Platform-independent helpers.
export 'shared/encoded_image_types.dart';
export 'shared/glsl_transpile.dart';
