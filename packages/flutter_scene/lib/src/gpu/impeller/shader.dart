part of '_gpu.dart';

/// A named uniform of a [Shader], which a [RenderPass] binds a buffer or a
/// texture to.
final class UniformSlot {
  UniformSlot._(this.shader, this.uniformName, this._impeller);

  /// The shader that declares the uniform.
  final Shader shader;

  /// The uniform's name in the shader.
  final String uniformName;

  final fg.UniformSlot? _impeller;

  /// The size of the uniform's struct, or null when it is not a struct.
  int? get sizeInBytes {
    final impeller = _impeller;
    if (impeller != null) return impeller.sizeInBytes;
    return shader._backend!.uniformStructSize(uniformName);
  }

  /// Where [memberName] sits in the uniform's struct, or null when absent.
  int? getMemberOffsetInBytes(String memberName) {
    final impeller = _impeller;
    if (impeller != null) return impeller.getMemberOffsetInBytes(memberName);
    return shader._backend!.uniformMemberOffset(uniformName, memberName);
  }
}

/// One compiled shader stage from a [ShaderLibrary].
final class Shader {
  Shader._impeller(fg.Shader this._impeller) : _backend = null;
  Shader._backend(GpuBackendShader this._backend) : _impeller = null;

  final fg.Shader? _impeller;
  final GpuBackendShader? _backend;

  // One slot per name, so a draw that looks a slot up again allocates nothing.
  final Map<String, UniformSlot> _slots = {};

  /// The uniform named [uniformName].
  UniformSlot getUniformSlot(String uniformName) => _slots[uniformName] ??=
      UniformSlot._(this, uniformName, _impeller?.getUniformSlot(uniformName));
}

/// A pipeline built from a vertex and a fragment shader.
final class RenderPipeline {
  RenderPipeline._impeller(
    this.vertexShader,
    this.fragmentShader,
    fg.RenderPipeline this._impeller,
  ) : _backend = null;
  RenderPipeline._backend(
    this.vertexShader,
    this.fragmentShader,
    GpuBackendRenderPipeline this._backend,
  ) : _impeller = null;

  /// The vertex stage.
  final Shader vertexShader;

  /// The fragment stage.
  final Shader fragmentShader;

  final fg.RenderPipeline? _impeller;
  final GpuBackendRenderPipeline? _backend;
}

/// A loaded shader bundle.
final class ShaderLibrary {
  ShaderLibrary._impeller(fg.ShaderLibrary this._impeller) : _backend = null;
  ShaderLibrary._backend(GpuBackendShaderLibrary this._backend)
    : _impeller = null;

  final fg.ShaderLibrary? _impeller;
  final GpuBackendShaderLibrary? _backend;
  final Map<String, Shader?> _shaders = {};

  static final Expando<ShaderLibrary> _wrapped = Expando('ShaderLibrary');
  static final Map<String, ShaderLibrary> _backendByAsset = {};

  static ShaderLibrary? _ofImpeller(fg.ShaderLibrary? library) {
    if (library == null) return null;
    return _wrapped[library] ??= ShaderLibrary._impeller(library);
  }

  /// Loads the shader bundle asset [assetName], once per asset.
  static Future<ShaderLibrary?> fromAsset(String assetName) async {
    switch (_useBackend()) {
      case GpuBackendKind.impeller:
        return _ofImpeller(
          await Future.value(fg.ShaderLibrary.fromAsset(assetName)),
        );
      case GpuBackendKind.wgpu:
        final cached = _backendByAsset[assetName];
        if (cached != null) return cached;
        final library = await gpuContext._backend!.loadShaderLibraryFromAsset(
          assetName,
        );
        if (library == null) return null;
        return _backendByAsset[assetName] = ShaderLibrary._backend(library);
    }
  }

  /// Loads a shader bundle from [bytes].
  static Future<ShaderLibrary?> fromBytes(ByteData bytes) async {
    switch (_useBackend()) {
      case GpuBackendKind.impeller:
        return _ofImpeller(
          await Future.value(fg.ShaderLibrary.fromBytes(bytes)),
        );
      case GpuBackendKind.wgpu:
        final library = gpuContext._backend!.loadShaderLibraryFromBytes(bytes);
        return library == null ? null : ShaderLibrary._backend(library);
    }
  }

  /// Reloads the asset-loaded library for [assetKey] in place, keeping every
  /// [Shader] it has handed out. Does nothing when it is not loaded.
  static void reinitialize(String assetKey) {
    switch (_kind) {
      case GpuBackendKind.impeller:
        // TODO(shader-reload): drop the ignore once ShaderLibrary.reinitialize
        // reaches a released Flutter channel. The API exists only on master,
        // so analyzing against stable reports it undefined.
        // ignore: undefined_method
        fg.ShaderLibrary.reinitialize(assetKey);
      case GpuBackendKind.wgpu:
        final error = _backendByAsset[assetKey]?._backend!
            .reinitializeFromAsset(assetKey);
        if (error != null) {
          throw Exception('Failed to reinitialize ShaderLibrary: $error');
        }
    }
  }

  /// The shader named [shaderName], or null when the bundle has none.
  Shader? operator [](String shaderName) =>
      _shaders.putIfAbsent(shaderName, () {
        final impeller = _impeller;
        if (impeller != null) {
          final shader = impeller[shaderName];
          return shader == null ? null : Shader._impeller(shader);
        }
        final shader = _backend![shaderName];
        return shader == null ? null : Shader._backend(shader);
      });

  /// Reloads the library in place from the asset [assetName]. Returns an
  /// error description, or null on success.
  String? debugReinitializeFromAsset(String assetName) =>
      // ignore: undefined_method
      _impeller?.debugReinitializeFromAsset(assetName) ??
      _backend?.reinitializeFromAsset(assetName);

  /// Reloads the library in place from regenerated bundle [bytes]. Returns an
  /// error description, or null on success.
  String? reinitializeFromBytes(ByteData bytes) {
    final impeller = _impeller;
    if (impeller != null) {
      // ignore: undefined_method
      return impeller.reinitializeFromBytes(bytes);
    }
    return _backend!.reinitializeFromBytes(bytes);
  }
}
