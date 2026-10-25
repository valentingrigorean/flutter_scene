part of '_gpu.dart';

GpuBackendKind _backend = GpuBackendKind.impeller;
bool _backendInUse = false;

/// The backend the shim renders through.
GpuBackendKind get gpuBackend => _backend;

/// Chooses the backend the shim renders through.
///
/// Call it at start-up, before anything creates a GPU object: the first
/// [gpuContext] read or shader library load fixes the backend for the rest of
/// the process. Choosing another backend after that throws a [StateError];
/// choosing the one in use is a no-op.
void selectGpuBackend(GpuBackendKind kind) {
  if (kind == _backend) return;
  if (_backendInUse) {
    throw StateError(
      'The GPU backend is ${_backend.name} and GPU objects already exist; '
      'select ${kind.name} before the first GPU object is created.',
    );
  }
  _backend = kind;
}

GpuBackendKind _useBackend() {
  _backendInUse = true;
  return _backend;
}
