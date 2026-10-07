/// The GPU surface flutter_scene renders through, for a caller that draws
/// with it: a custom [ShaderMaterial], a `Geometry` that overrides `bind` and
/// `draw`, or a pass of its own into an offscreen target.
///
/// The library is `package:flutter_gpu` on native and a WebGL2 backend with
/// the same names on the web, so code written against it compiles for both.
/// Import this library in place of `package:flutter_gpu/gpu.dart`, which
/// imports `dart:ffi` and so does not compile for the web.
///
/// ```dart
/// import 'package:flutter_scene/gpu.dart' as gpu;
///
/// final library = await gpu.loadShaderLibraryAsync(
///   await gpu.resolveShaderBundleKey('my'),
/// );
/// final material = ShaderMaterial(fragmentShader: library!['MyFragment']!);
/// ```
///
/// A `Geometry` that overrides `draw` issues its draw calls through
/// [drawCompat] and [drawIndexedCompat], the funnel every engine draw goes
/// through, so `Scene.renderStats` and render graph captures count them.
library;

export 'src/generated_assets/generated_asset_lookup.dart'
    show resolveShaderBundleKey;

export 'src/gpu/render_pass_compat.dart' show drawCompat, drawIndexedCompat;

export 'src/gpu/gpu.dart';
