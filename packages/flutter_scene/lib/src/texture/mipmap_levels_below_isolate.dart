import 'dart:isolate';
import 'dart:typed_data';

import 'mipmap.dart';

/// The levels below level 0 of [generateMipChain], built on a background
/// isolate.
Future<List<MipLevel>> mipLevelsBelow(
  Uint8List pixels,
  int width,
  int height,
  TextureContent content,
) => _levelsBelow(
  TransferableTypedData.fromList([pixels]),
  width,
  height,
  content,
);

// Takes only the transferable bytes, so the isolate's closure never captures
// the caller's pixels and sends them as a copy.
Future<List<MipLevel>> _levelsBelow(
  TransferableTypedData sent,
  int width,
  int height,
  TextureContent content,
) => Isolate.run(
  () => generateMipChain(
    sent.materialize().asUint8List(),
    width,
    height,
    content,
  ).sublist(1),
  debugName: 'mip chain',
);
