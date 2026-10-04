import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

final class _StatedBytes implements Finalizable {
  _StatedBytes(this.bytes);

  final int bytes;
}

final NativeFinalizer _freed = NativeFinalizer(malloc.nativeFree);
final Expando<_StatedBytes> _stated = Expando();

/// Tells the VM that [owner] keeps [bytes] of GPU memory alive, so a
/// collection follows the GPU memory dropped owners leave. The VM forgets
/// the bytes when [owner] is collected. An owner states its bytes once.
@internal
void statesExternalBytes(Object owner, int bytes) {
  if (bytes <= 0 || _stated[owner] != null) return;
  final stated = _stated[owner] = _StatedBytes(bytes);
  _freed.attach(stated, malloc<Uint8>().cast(), externalSize: bytes);
}

/// The bytes [statesExternalBytes] stated for [owner], or 0.
@visibleForTesting
int debugStatedExternalBytes(Object owner) => _stated[owner]?.bytes ?? 0;
