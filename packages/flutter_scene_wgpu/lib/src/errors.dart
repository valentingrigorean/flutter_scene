import 'package:ffi/ffi.dart';

import 'ffi/bindings.dart';

/// Status codes the native calls return; `ok` is success.
enum WgpuErrorCode {
  ok,
  invalidHandle,
  invalidArgument,
  validation,
  outOfMemory,
  notReady,
  unsupported,
  shaderCompile,
  panic,
  noAdapter,
  internal,
}

/// A failed native call: its code and the native error message.
class WgpuException implements Exception {
  /// Creates an exception for [code] with [message].
  WgpuException(this.code, this.message);

  /// What kind of failure this is.
  final WgpuErrorCode code;

  /// The native error message.
  final String message;

  @override
  String toString() => 'WgpuException(${code.name}): $message';
}

/// Converts a raw status into a [WgpuErrorCode], mapping unknown values to
/// [WgpuErrorCode.internal].
WgpuErrorCode codeOf(int status) => status >= 0 &&
        status < WgpuErrorCode.values.length
    ? WgpuErrorCode.values[status]
    : WgpuErrorCode.internal;

/// Throws a [WgpuException] carrying the thread's last native error unless
/// [status] is success.
void check(int status) {
  if (status == 0) return;
  throw WgpuException(codeOf(status), fswLastErrorMessage().toDartString());
}
