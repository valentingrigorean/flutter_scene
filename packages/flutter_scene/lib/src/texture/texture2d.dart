import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/services.dart';

import '../asset_helpers.dart';
import '../gpu/gpu.dart' as gpu;
import '../render/mip_sampling_probe.dart';
import 'mipmap.dart';

/// Something a material can sample: it yields the GPU texture to sample for the
/// current frame and the sampler to bind it with. Implemented by [Texture2D]
/// (a static image) and `RenderTexture` (a live, rendered-into texture).
///
/// {@category Assets and loading}
abstract interface class TextureSource {
  /// The GPU texture to sample this frame, or null when none is available yet
  /// (a live source before its first frame; callers substitute a placeholder).
  gpu.Texture? get sampledTexture;

  /// The sampler this source is bound with.
  gpu.SamplerOptions get sampledSampler;
}

/// Wraps a raw [gpu.Texture] as a [TextureSource], for advanced or interop
/// cases that already own a GPU texture (widget/particle textures, custom
/// pipelines) and do not need [Texture2D]'s image decode and mip generation.
///
/// {@category Assets and loading}
class GpuTextureSource implements TextureSource {
  GpuTextureSource(this.texture, {gpu.SamplerOptions? sampler})
    : sampler = sampler ?? _defaultSampler(texture);

  // Trilinear and anisotropic when the texture carries a mip chain, matching
  // what [TextureSampling] gives a [Texture2D]. Anisotropy needs linear
  // min/mag/mip filtering, so a mipless texture leaves it off.
  static gpu.SamplerOptions _defaultSampler(gpu.Texture texture) {
    final mipped = texture.mipLevelCount > 1;
    return gpu.SamplerOptions(
      minFilter: gpu.MinMagFilter.linear,
      magFilter: gpu.MinMagFilter.linear,
      mipFilter: mipped ? gpu.MipFilter.linear : gpu.MipFilter.nearest,
      widthAddressMode: gpu.SamplerAddressMode.repeat,
      heightAddressMode: gpu.SamplerAddressMode.repeat,
      maxAnisotropy: mipped ? TextureSampling.defaultMaxAnisotropy : 1,
    );
  }

  final gpu.Texture texture;
  final gpu.SamplerOptions sampler;

  @override
  gpu.Texture? get sampledTexture => texture;

  @override
  gpu.SamplerOptions get sampledSampler => sampler;
}

/// How a texture is sampled. The defaults are trilinear, anisotropic, and
/// mipmapped, the tasteful default for material textures viewed in 3D.
///
/// {@category Assets and loading}
class TextureSampling {
  const TextureSampling({
    this.mipmaps = true,
    this.maxMipmapLevels,
    this.minFilter = gpu.MinMagFilter.linear,
    this.magFilter = gpu.MinMagFilter.linear,
    this.mipFilter = gpu.MipFilter.linear,
    this.maxAnisotropy = defaultMaxAnisotropy,
    this.addressMode = gpu.SamplerAddressMode.repeat,
  });

  /// The anisotropy a mipmapped texture samples with by default, shared with
  /// [GpuTextureSource] so a texture filters the same however it was built.
  static const int defaultMaxAnisotropy = 8;

  /// Whether the texture carries a mip chain (built at creation) and is sampled
  /// with mip filtering. Turn off for UI/full-screen sources never minified.
  final bool mipmaps;

  /// Caps the number of mip levels generated (null builds the full chain).
  /// A texture atlas uses this so tiles stop shrinking before they merge into
  /// their neighbors across the padding gutter.
  final int? maxMipmapLevels;

  final gpu.MinMagFilter minFilter;
  final gpu.MinMagFilter magFilter;
  final gpu.MipFilter mipFilter;

  /// Maximum anisotropy (clamped to the device max). 1 disables it.
  final int maxAnisotropy;

  final gpu.SamplerAddressMode addressMode;

  gpu.SamplerOptions toSamplerOptions() {
    final effectiveMipFilter = mipmaps ? mipFilter : gpu.MipFilter.nearest;
    // Anisotropic filtering requires linear min/mag/mip filtering; pairing it
    // with any nearest filter is rejected, so drop it when a filter is nearest
    // (e.g. a mipmaps-off UI texture).
    final allLinear =
        minFilter == gpu.MinMagFilter.linear &&
        magFilter == gpu.MinMagFilter.linear &&
        effectiveMipFilter == gpu.MipFilter.linear;
    return gpu.SamplerOptions(
      minFilter: minFilter,
      magFilter: magFilter,
      mipFilter: effectiveMipFilter,
      widthAddressMode: addressMode,
      heightAddressMode: addressMode,
      maxAnisotropy: allLinear ? maxAnisotropy : 1,
    );
  }
}

/// A 2D image texture ready to bind to a material's texture slot.
///
/// Create one from an asset ([fromAsset]), a decoded `dart:ui` image
/// ([fromImage]), or raw RGBA pixels ([fromPixels]). A mip chain is generated
/// at creation, downsampled correctly for the texture's [TextureContent] (sRGB
/// color averaged in linear light, normals renormalized), and the texture
/// carries its own [TextureSampling] (trilinear + anisotropic by default).
///
/// ```dart
/// final albedo = await Texture2D.fromAsset('assets/brick_color.png');
/// final normal = await Texture2D.fromAsset('assets/brick_normal.png',
///     content: TextureContent.normal);
/// material.baseColorTexture = albedo;
/// material.normalTexture = normal;
/// ```
/// {@category Assets and loading}
class Texture2D implements TextureSource {
  Texture2D._(this._texture, this._sampler);

  final gpu.Texture _texture;
  final gpu.SamplerOptions _sampler;

  /// The underlying GPU texture, for advanced/interop use.
  gpu.Texture get gpuTexture => _texture;

  @override
  gpu.Texture? get sampledTexture => _texture;

  @override
  gpu.SamplerOptions get sampledSampler => _sampler;

  /// Builds a texture from RGBA8888 [pixels] (straight alpha, row-major) of
  /// [width] x [height].
  static Texture2D fromPixels(
    Uint8List pixels,
    int width,
    int height, {
    TextureContent content = TextureContent.color,
    TextureSampling sampling = const TextureSampling(),
  }) => Texture2D._(
    uploadMipLevels(
      sampling.mipmaps && mipChainsAreSampled
          ? generateMipChain(pixels, width, height, content)
          : <MipLevel>[MipLevel(width, height, pixels)],
      width,
      height,
      maxMipmapLevels: sampling.maxMipmapLevels,
    ),
    sampling.toSamplerOptions(),
  );

  /// Builds a texture from a prebuilt mip chain ([levels], base level first,
  /// each level RGBA8888, straight alpha, row-major), sized by its base level.
  ///
  /// Level `i` is `max(1, baseWidth >> i)` x `max(1, baseHeight >> i)` with
  /// `width * height * 4` bytes; a chain that breaks this throws an
  /// [ArgumentError] naming the level before anything is allocated.
  ///
  /// The chain is uploaded as given: build it with [generateMipChain] or on a
  /// background isolate. It is capped at [TextureSampling.maxMipmapLevels]
  /// and at the levels the allocator accepts for a non-square size, and only
  /// the base level is uploaded where [TextureSampling.mipmaps] is off or
  /// [mipChainsAreSampled] is false, as in [fromPixels].
  static Texture2D fromMipLevels(
    List<MipLevel> levels, {
    TextureSampling sampling = const TextureSampling(),
  }) {
    if (levels.isEmpty) {
      throw ArgumentError.value(levels, 'levels', 'holds no base level');
    }
    final base = levels.first;
    if (base.width < 1 || base.height < 1) {
      throw ArgumentError.value(
        levels,
        'levels',
        'level 0 is ${base.width} x ${base.height}, not at least 1 x 1',
      );
    }
    for (var i = 0; i < levels.length; i++) {
      final level = levels[i];
      final width = math.max(1, base.width >> i);
      final height = math.max(1, base.height >> i);
      if (level.width != width || level.height != height) {
        throw ArgumentError.value(
          levels,
          'levels',
          'level $i is ${level.width} x ${level.height}, not $width x $height',
        );
      }
      if (level.pixels.length != width * height * 4) {
        throw ArgumentError.value(
          levels,
          'levels',
          'level $i holds ${level.pixels.length} bytes, not '
              '${width * height * 4}',
        );
      }
    }
    return Texture2D._(
      uploadMipLevels(
        sampling.mipmaps && mipChainsAreSampled ? levels : [base],
        base.width,
        base.height,
        maxMipmapLevels: sampling.maxMipmapLevels,
      ),
      sampling.toSamplerOptions(),
    );
  }

  /// Wraps an already-uploaded GPU [texture] with [sampling] (the KTX2 load
  /// paths, whose mip chains come from the file rather than the generator).
  @internal
  static Texture2D fromGpuTexture(
    gpu.Texture texture, {
    TextureSampling sampling = const TextureSampling(),
  }) => Texture2D._(texture, sampling.toSamplerOptions());

  /// Builds a texture from a decoded [image].
  static Future<Texture2D> fromImage(
    ui.Image image, {
    TextureContent content = TextureContent.color,
    TextureSampling sampling = const TextureSampling(),
  }) async {
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null) {
      throw Exception('Failed to read RGBA data from image.');
    }
    return fromPixels(
      bytes.buffer.asUint8List(),
      image.width,
      image.height,
      content: content,
      sampling: sampling,
    );
  }

  /// Loads, decodes, and uploads the image asset at [assetPath].
  static Future<Texture2D> fromAsset(
    String assetPath, {
    TextureContent content = TextureContent.color,
    TextureSampling sampling = const TextureSampling(),
    AssetBundle? bundle,
  }) async {
    final image = await imageFromAsset(assetPath, bundle: bundle);
    try {
      return await fromImage(image, content: content, sampling: sampling);
    } finally {
      image.dispose();
    }
  }
}

/// Uploads a prebuilt mip chain ([levels], base first) as a texture of
/// [width] x [height], capping the chain the allocator will accept.
///
/// Shared by the synchronous [Texture2D.fromPixels] and the async paths that
/// build their chain on a background isolate, so both agree on the cap and the
/// per-level upload.
gpu.Texture uploadMipLevels(
  List<MipLevel> levels,
  int width,
  int height, {
  int? maxMipmapLevels,
}) {
  // The GPU allocator caps mip levels at fullMipCount (floor(log2(min(w, h)))),
  // which is below the canonical chain length for non-square textures, so
  // clamp before requesting the texture or creation throws a range error.
  final maxLevels = gpu.Texture.fullMipCount(width, height);
  final cap = maxMipmapLevels;
  final limit = cap != null && cap >= 1 && cap < maxLevels ? cap : maxLevels;
  final capped = limit < levels.length ? levels.sublist(0, limit) : levels;
  final texture = gpu.gpuContext.createTexture(
    gpu.StorageMode.hostVisible,
    width,
    height,
    mipLevelCount: capped.length,
  );
  for (var i = 0; i < capped.length; i++) {
    texture.overwrite(ByteData.sublistView(capped[i].pixels), mipLevel: i);
  }
  return texture;
}
