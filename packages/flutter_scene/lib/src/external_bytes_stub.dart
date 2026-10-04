import 'package:flutter/foundation.dart';

/// Does nothing where the VM takes no external size (web).
@internal
void statesExternalBytes(Object owner, int bytes) {}

/// Always 0 where the VM takes no external size (web).
@visibleForTesting
int debugStatedExternalBytes(Object owner) => 0;
