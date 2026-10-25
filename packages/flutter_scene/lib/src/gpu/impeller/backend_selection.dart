part of '_gpu.dart';

/// The backend a process starts on: Impeller, or the registered wgpu backend
/// when built with `--dart-define=FLUTTER_SCENE_GPU_BACKEND=wgpu`. A test file
/// runs on either backend unchanged through this define, for example
/// `flutter test --dart-define=FLUTTER_SCENE_GPU_BACKEND=wgpu <file>`, as long
/// as the test process registers the backend before its first GPU object.
const String gpuBackendDefine = String.fromEnvironment(
  'FLUTTER_SCENE_GPU_BACKEND',
);

GpuBackendKind _kind = gpuBackendDefine == 'wgpu'
    ? GpuBackendKind.wgpu
    : GpuBackendKind.impeller;
bool _backendInUse = false;
GpuBackend? _registered;

/// The backend the shim renders through.
GpuBackendKind get gpuBackend => _kind;

/// The registered backend the shim renders through, or null while it renders
/// through Impeller.
@experimental
GpuBackend? get activeGpuBackend =>
    _kind == GpuBackendKind.impeller || _registered?.kind != _kind
    ? null
    : _registered;

/// Registers [backend], the implementation [selectGpuBackend] and the
/// `FLUTTER_SCENE_GPU_BACKEND` define use for its [GpuBackend.kind].
///
/// Call it at start-up, before anything creates a GPU object; registering
/// does not select the backend. Registering another backend after the first
/// GPU object exists throws a [StateError]; registering the one already
/// registered is a no-op.
@experimental
void registerGpuBackend(GpuBackend backend) {
  if (identical(backend, _registered)) return;
  if (backend.kind == GpuBackendKind.impeller) {
    throw ArgumentError.value(
      backend,
      'backend',
      'is an Impeller backend; Impeller is built in',
    );
  }
  if (_backendInUse) {
    throw StateError(
      'GPU objects already exist on ${_kind.name}; register the '
      '${backend.kind.name} backend before the first GPU object is created.',
    );
  }
  _registered = backend;
}

/// Registers [backend] and chooses it, as [registerGpuBackend] then
/// [selectGpuBackend] with its [GpuBackend.kind] do.
@experimental
void useGpuBackend(GpuBackend backend) {
  registerGpuBackend(backend);
  selectGpuBackend(backend.kind);
}

/// Chooses the backend the shim renders through.
///
/// Call it at start-up, before anything creates a GPU object: the first
/// [gpuContext] read or shader library load fixes the backend for the rest of
/// the process. Choosing another backend after that throws a [StateError];
/// choosing the one in use is a no-op. A backend other than Impeller must be
/// registered first with [registerGpuBackend]; choosing one that is not
/// throws a [StateError].
void selectGpuBackend(GpuBackendKind kind) {
  if (kind == _kind) return;
  if (_backendInUse) {
    throw StateError(
      'The GPU backend is ${_kind.name} and GPU objects already exist; '
      'select ${kind.name} before the first GPU object is created.',
    );
  }
  if (kind != GpuBackendKind.impeller) _backendFor(kind);
  _kind = kind;
}

GpuBackend _backendFor(GpuBackendKind kind) {
  final registered = _registered;
  if (registered != null && registered.kind == kind) return registered;
  throw StateError(
    'No ${kind.name} GPU backend is registered. The package that implements '
    'it registers it with registerGpuBackend before the first GPU object is '
    'created; without one the GPU backend is Impeller.',
  );
}

GpuBackendKind _useBackend() {
  _backendInUse = true;
  return _kind;
}

/// The registered backend's texture behind [texture], or null when [texture]
/// is an Impeller texture.
@experimental
GpuBackendTexture? gpuBackendTextureOf(Texture texture) => texture._backend;
