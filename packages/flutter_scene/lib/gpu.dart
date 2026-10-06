/// Curated public GPU surface for the custom-shader ([ShaderMaterial])
/// workflow.
///
/// flutter_scene ships an internal `flutter_gpu` shim (a WebGL2 backend on
/// web; a zero-cost re-export of `package:flutter_gpu` on native). Most of it
/// is implementation detail. This library exposes only the handful of types a
/// caller needs to author a custom material: load a compiled shader bundle,
/// hand its fragment shader to a [ShaderMaterial], and name the pass and
/// context types a `Material` override binds against.
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

export 'src/gpu/gpu.dart'
    show
        GpuContext,
        RenderPass,
        Shader,
        ShaderLibrary,
        StorageMode,
        gpuContext,
        loadShaderLibraryAsync,
        Texture,
        SamplerOptions,
        MinMagFilter,
        MipFilter,
        SamplerAddressMode,
        // Value types a caller-declared vertex layout and index buffer need.
        IndexType,
        VertexFormat,
        VertexStepMode;
