// The off-thread mip chain build. Split from mipmap.dart because that file is
// re-exported by `build_hooks.dart`, which needs no isolate entry point.

import 'dart:typed_data';

import 'mipmap.dart';
import 'mipmap_levels_below_isolate.dart'
    if (dart.library.js_interop) 'mipmap_levels_below_inline.dart';

/// Builds the mip chain for [pixels] on a background isolate, so a large
/// texture does not block the caller while it downsamples. On the web, where
/// no isolate runs, it builds on the caller.
///
/// The pixels are copied once into transferable bytes at the call, so the
/// caller's buffer is neither detached nor shared, and the levels below come
/// back by ownership transfer without a copy. Level 0 is [pixels] itself, as
/// [generateMipChain] returns it.
///
/// The synchronous [generateMipChain] stays for the sync realize path, which
/// cannot await.
Future<List<MipLevel>> generateMipChainAsync(
  Uint8List pixels,
  int width,
  int height,
  TextureContent content,
) async => [
  MipLevel(width, height, pixels),
  ...await mipLevelsBelow(pixels, width, height, content),
];
