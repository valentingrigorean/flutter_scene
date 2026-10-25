part of '_gpu.dart';

/// The name [library] loaded [shader] under, or null when [library] is no
/// shader library or has not handed [shader] out.
String? loadedShaderName(Object library, Shader shader) {
  if (library is! ShaderLibrary) return null;
  for (final MapEntry(:key, :value) in library._shaders.entries) {
    if (identical(value, shader)) return key;
  }
  return null;
}
