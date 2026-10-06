import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/raster_sync.dart';
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/uniform_slots.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:vector_math/vector_math.dart';

/// Whether this device renders a 32-bit float color target, measured by
/// [probeFloat32ColorTargets]. Null until the probe runs, and where it does
/// not apply.
bool? platformRendersFloat32ColorTargets;

/// Forces the half float layout of the linear depth target, as on a device
/// that renders no 32-bit float color target, so a test proves that layout on
/// a GPU that renders both. Set it before the scene draws its next frame.
bool debugSplitLinearDepth = false;

/// Whether the depth prepass writes the half float layout of
/// `shaders/linear_depth.glsl` into the linear depth target.
///
/// True where the probe measured that a 32-bit float color target does not
/// render, or under [debugSplitLinearDepth]. Every reader decodes through
/// `LinearDepthOf` of that include, which reads either layout, so only the
/// writers consult this.
bool get linearDepthIsSplit =>
    debugSplitLinearDepth || platformRendersFloat32ColorTargets == false;

/// The format of the linear depth target, and of the depth levels built from
/// it: a half float target in the half float layout, else a 32-bit float one,
/// with four channels when it carries normals.
gpu.PixelFormat linearDepthFormat({required bool normals}) {
  if (linearDepthIsSplit) return gpu.PixelFormat.r16g16b16a16Float;
  return normals ? gpu.PixelFormat.r32g32b32a32Float : gpu.PixelFormat.r32Float;
}

/// The texel that clears the linear depth target to [depth] with a zero
/// normal and roughness 1, in the layout [linearDepthIsSplit] names.
///
/// The half float texel never reads back nearer than [depth] at 32-bit float
/// precision, so a reader that takes a depth at or past the far plane for
/// background still does.
Vector4 linearDepthClearValue(double depth) {
  if (!linearDepthIsSplit) return Vector4(depth, 0.0, 0.0, 1.0);
  final split = splitLinearDepthAtLeast(depth);
  return Vector4(
    split.high,
    split.low,
    _splitBlankNormal,
    -_splitBlankNormal - 1,
  );
}

// The zero normal (127 of 254 steps) with roughness 1 (the high and the low
// three bits of 63 both 7) that EncodeLinearDepth packs into b and -a - 1.
const double _splitBlankNormal = 7 * 256 + 127;
const double _splitDepthUnit = 16;
const double _splitDepthLow = 1024;
const double _halfFloatMost = 65504;
const int _halfFloatLeastNormalExponent = -14;

/// The half float pair `r` (`high`) and `g` (`low`) of `SplitLinearDepth` in
/// `shaders/linear_depth.glsl` for a positive [depth], with `g` rounded up to
/// a half float, so `(r + g / 1024) * 16` evaluated at 32-bit float precision
/// is never less than [depth] as a 32-bit float.
@visibleForTesting
({double high, double low}) splitLinearDepthAtLeast(double depth) {
  final single = (Float32List(1)..[0] = depth)[0];
  final v = math.min(single.abs() / _splitDepthUnit, _halfFloatMost);
  final step = _halfFloatUlp(v);
  final high = (v / step).floor() * step;
  final low = (v - high) * _splitDepthLow;
  if (low == 0) return (high: high, low: 0.0);
  final lowStep = _halfFloatUlp(low);
  return (high: high, low: (low / lowStep).ceil() * lowStep);
}

double _halfFloatUlp(double value) {
  var exponent = _halfFloatLeastNormalExponent;
  while (exponent < 15 && math.pow(2.0, exponent + 1) <= value) {
    exponent++;
  }
  return math.pow(2.0, exponent - 10).toDouble();
}

/// Measures whether this device renders the 32-bit float linear depth target,
/// on the platforms where the backend can lack it.
///
/// OpenGL ES 3.0 and 3.1 render a 32-bit float color target only with
/// `EXT_color_buffer_float`, while the half float scene color target needs
/// only `EXT_color_buffer_half_float`, so a device can draw the scene and not
/// its depth. Flutter GPU reports every uncompressed format as supported, so
/// the probe measures the read itself: where it does not hold, the depth
/// prepass and the shadow maps take their half float layouts, which render
/// wherever the scene does.
///
/// Runs during `Scene.initializeStaticResources` on Android, the platform
/// whose OpenGL ES backend can lack the extension. Metal and Vulkan render a
/// 32-bit float color target on every device, and web keeps its own backend.
Future<void> probeFloat32ColorTargets() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  try {
    platformRendersFloat32ColorTargets = await measureLinearDepthRead(
      split: false,
    );
  } catch (error) {
    // A target the backend refuses to render throws here rather than reading
    // back wrong. The half float layout renders wherever the scene does, so a
    // probe that could not finish takes it.
    debugPrint('flutter_scene: 32-bit float color target probe failed: $error');
    platformRendersFloat32ColorTargets = false;
  }
  if (platformRendersFloat32ColorTargets == false) {
    debugPrint(
      'flutter_scene: this device renders no 32-bit float color target, so '
      'the linear depth target and the shadow maps take the half float '
      'layout.',
    );
  }
}

final gpu.BufferView _fullscreenQuadView = gpu.BufferView(
  gpu.gpuContext.createDeviceBufferWithCopy(
    ByteData.sublistView(
      Float32List.fromList(<double>[
        -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, //
        -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, //
      ]),
    ),
  ),
  offsetInBytes: 0,
  lengthInBytes: 6 * 2 * 4,
);

const int _probeSize = 4;

/// Writes a known depth into each texel of a linear depth target in the
/// layout [split] names, reads it back through the decode every reader uses,
/// and returns whether every texel held its depth within one part in a
/// million.
///
/// Requires the base shader library to be loaded. Exposed for tests; use
/// [probeFloat32ColorTargets] to apply the platform gating.
@visibleForTesting
Future<bool> measureLinearDepthRead({required bool split}) async {
  final written = gpu.gpuContext.createTexture(
    gpu.StorageMode.devicePrivate,
    _probeSize,
    _probeSize,
    format: split
        ? gpu.PixelFormat.r16g16b16a16Float
        : gpu.PixelFormat.r32Float,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  );
  final verdict = gpu.gpuContext.createTexture(
    gpu.StorageMode.devicePrivate,
    _probeSize,
    _probeSize,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  );
  final vertexShader = baseShaderLibrary['FullscreenVertex']!;
  final fragmentShader = baseShaderLibrary['LinearDepthProbeFragment']!;
  void draw(gpu.Texture target, gpu.Texture source, {required bool check}) {
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: target, clearValue: Vector4.zero()),
      ),
    );
    renderPass.bindPipeline(resolvePipeline(vertexShader, fragmentShader));
    renderPass.setColorBlendEnable(false);
    bindVertexBufferCompat(renderPass, _fullscreenQuadView, 6);
    renderPass.bindUniform(
      fragmentShader.cachedUniformSlot('ProbeInfo'),
      uniformTransients.emplace(
        ByteData.sublistView(
          Float32List.fromList([split ? 1.0 : 0.0, check ? 1.0 : 0.0, 0, 0]),
        ),
      ),
    );
    renderPass.bindTexture(
      fragmentShader.cachedUniformSlot('written'),
      source,
      sampler: gpu.SamplerOptions(
        minFilter: gpu.MinMagFilter.nearest,
        magFilter: gpu.MinMagFilter.nearest,
      ),
    );
    drawCompat(renderPass, 6);
    rendererSubmissions.submit(commandBuffer);
  }

  draw(written, verdict, check: false);
  draw(verdict, written, check: true);
  await awaitRasterThread();

  final ui.Image image = gpu.gpuHost.textureToImage(verdict);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (bytes == null) {
    throw StateError('Could not read back the linear depth probe target.');
  }
  for (var texel = 0; texel < _probeSize * _probeSize; texel++) {
    if (bytes.getUint8(texel * 4) != 0 || bytes.getUint8(texel * 4 + 1) < 128) {
      return false;
    }
  }
  return true;
}
