import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/raster_sync.dart';
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import 'package:flutter_scene/src/render/depth_raster.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/uniform_slots.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:vector_math/vector_math.dart';

/// Whether this device samples a stored depth attachment as a texture,
/// measured by [probeStoredDepthRead]. Null until the probe runs, and where
/// it does not apply.
bool? platformSamplesStoredDepth;

/// Forces [storedDepthIsSampled] false, as on a device that samples no depth
/// attachment, so a test proves the linear depth that stands in for it on a
/// GPU that samples both. Set it before the scene draws its next frame.
bool debugStoredDepthUnsampled = false;

/// Whether a pass may sample the depth the scene pass stored
/// (`RenderInput.depthStored`).
///
/// True only where the probe measured that both camera depth formats read
/// back the depth they stored. Where it is false the scene draws the linear
/// depth of the depth prepass for the pass that asked.
bool get storedDepthIsSampled =>
    !debugStoredDepthUnsampled && platformSamplesStoredDepth == true;

/// Measures whether a depth attachment the scene stored samples as a texture.
///
/// Flutter GPU states no capability for it, and an OpenGL ES device may keep
/// a depth attachment in storage no shader reads, so the probe measures the
/// read itself in both camera depth formats.
///
/// Runs during `Scene.initializeStaticResources`. Web keeps the linear depth.
Future<void> probeStoredDepthRead() async {
  if (kIsWeb) return;
  try {
    final formats = {
      DepthRaster.depthStencilFormatFor(reversed: false),
      DepthRaster.depthStencilFormatFor(reversed: true),
    };
    var sampled = true;
    for (final format in formats) {
      sampled = sampled && await measureStoredDepthRead(format: format);
    }
    platformSamplesStoredDepth = sampled;
  } catch (error) {
    // A depth texture the backend refuses throws here rather than reading
    // back wrong. The linear depth draws wherever the scene does, so a probe
    // that could not finish takes it.
    debugPrint('flutter_scene: stored depth probe failed: $error');
    platformSamplesStoredDepth = false;
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

const double _probeDepth = 0.25;

/// Clears a depth attachment of [format] to a known depth, stores it, samples
/// it in a second pass and returns whether every texel read that depth.
///
/// Requires the base shader library to be loaded. Exposed for tests; use
/// [probeStoredDepthRead] to apply the platform gating.
@visibleForTesting
Future<bool> measureStoredDepthRead({required gpu.PixelFormat format}) async {
  gpu.Texture color() => gpu.gpuContext.createTexture(
    gpu.StorageMode.devicePrivate,
    _probeSize,
    _probeSize,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  );
  final stored = gpu.gpuContext.createTexture(
    gpu.StorageMode.devicePrivate,
    _probeSize,
    _probeSize,
    format: format,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  );
  final verdict = color();
  final vertexShader = baseShaderLibrary['FullscreenVertex']!;
  final fragmentShader = baseShaderLibrary['StoredDepthProbeFragment']!;
  void draw(gpu.RenderTarget target, {required bool check}) {
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(target);
    renderPass.bindPipeline(resolvePipeline(vertexShader, fragmentShader));
    renderPass.setColorBlendEnable(false);
    renderPass.setDepthWriteEnable(false);
    renderPass.setDepthCompareOperation(gpu.CompareFunction.always);
    bindVertexBufferCompat(renderPass, _fullscreenQuadView, 6);
    renderPass.bindUniform(
      fragmentShader.cachedUniformSlot('StoredDepthProbeInfo'),
      uniformTransients.emplace(
        ByteData.sublistView(
          Float32List.fromList([check ? 1.0 : 0.0, _probeDepth, 0, 0]),
        ),
      ),
    );
    renderPass.bindTexture(
      fragmentShader.cachedUniformSlot('stored'),
      check ? stored : verdict,
      sampler: gpu.SamplerOptions(
        minFilter: gpu.MinMagFilter.nearest,
        magFilter: gpu.MinMagFilter.nearest,
      ),
    );
    drawCompat(renderPass, 6);
    rendererSubmissions.submit(commandBuffer);
  }

  draw(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: color(), clearValue: Vector4.zero()),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: stored,
        depthClearValue: _probeDepth,
        depthStoreAction: gpu.StoreAction.store,
      ),
    ),
    check: false,
  );
  draw(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: verdict, clearValue: Vector4.zero()),
    ),
    check: true,
  );
  await awaitRasterThread();

  final ui.Image image = gpu.gpuHost.textureToImage(verdict);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (bytes == null) {
    throw StateError('Could not read back the stored depth probe target.');
  }
  for (var texel = 0; texel < _probeSize * _probeSize; texel++) {
    if (bytes.getUint8(texel * 4) != 0 || bytes.getUint8(texel * 4 + 1) < 128) {
      return false;
    }
  }
  return true;
}
