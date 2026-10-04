import 'dart:typed_data';

import 'mipmap.dart';

/// The levels below level 0 of [generateMipChain], built on the caller where
/// no isolate runs.
Future<List<MipLevel>> mipLevelsBelow(
  Uint8List pixels,
  int width,
  int height,
  TextureContent content,
) async => generateMipChain(pixels, width, height, content).sublist(1);
