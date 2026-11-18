import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/debug_view.dart' show DebugViewFrame;
import 'package:flutter_scene/src/render/uniform_slots.dart';
import 'package:vector_math/vector_math.dart';

/// A translucent material the scene keeps as an item, or encodes each frame
/// where [kept] is false.
///
/// The test shader bundle compiles the debug views in, and a draw that takes
/// part in them is not kept. This one takes no part and binds the block
/// their shader declares itself, from a buffer that outlives the frame, so
/// the software GPU of the tester draws it.
class SheetMaterial extends UnlitMaterial {
  /// A sheet of [color], premultiplied over what lies behind it.
  SheetMaterial(Vector4 color, {this.kept = true}) {
    baseColorFactor = color;
    alphaMode = AlphaMode.blend;
  }

  /// Whether the scene may keep the draw.
  final bool kept;

  static gpu.BufferView? _noDebugView;

  @override
  bool get colorRetainable => kept && super.colorRetainable;

  @override
  bool get participatesInDebugViews => false;

  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    final slot = fragmentShaderForLighting(
      lighting,
    ).cachedUniformSlot('DebugViewInfo');
    if (slot.sizeInBytes == null) return;
    final bytes = ByteData.sublistView(DebugViewFrame.inactive);
    pass.bindUniform(
      slot,
      _noDebugView ??= gpu.BufferView(
        gpu.gpuContext.createDeviceBufferWithCopy(bytes),
        offsetInBytes: 0,
        lengthInBytes: bytes.lengthInBytes,
      ),
    );
  }
}
