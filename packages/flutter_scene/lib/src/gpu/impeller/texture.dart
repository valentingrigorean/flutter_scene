part of '_gpu.dart';

/// A texture in GPU memory.
final class Texture {
  Texture._impeller(fg.Texture this._impeller) : _wgpu = null;
  Texture._wgpu(WgpuTexture this._wgpu) : _impeller = null;

  /// Wraps the GPU texture behind a Flutter-rendered [image].
  factory Texture.fromImage(GpuContext gpuContext, ui.Image image) {
    final impeller = gpuContext._impeller;
    if (impeller != null) {
      return Texture._impeller(fg.Texture.fromImage(impeller, image));
    }
    return Texture._wgpu(gpuContext._wgpu!.textureFromImage(image));
  }

  /// The mip count of a full chain for a [width] by [height] texture.
  static int fullMipCount(int width, int height) =>
      fg.Texture.fullMipCount(width, height);

  final fg.Texture? _impeller;
  final WgpuTexture? _wgpu;

  /// How the memory is reachable from the host.
  StorageMode get storageMode => _impeller?.storageMode ?? _wgpu!.storageMode;

  /// The texel format.
  PixelFormat get format => _impeller?.format ?? _wgpu!.format;

  /// The base level's width.
  int get width => _impeller?.width ?? _wgpu!.width;

  /// The base level's height.
  int get height => _impeller?.height ?? _wgpu!.height;

  /// Samples per texel; above 1 for a multisampled texture.
  int get sampleCount => _impeller?.sampleCount ?? _wgpu!.sampleCount;

  /// The texture's dimensionality.
  TextureType get textureType => _impeller?.textureType ?? _wgpu!.textureType;

  /// Whether a pass can render into the texture.
  bool get enableRenderTargetUsage =>
      _impeller?.enableRenderTargetUsage ?? _wgpu!.enableRenderTargetUsage;

  /// Whether shaders can sample the texture.
  bool get enableShaderReadUsage =>
      _impeller?.enableShaderReadUsage ?? _wgpu!.enableShaderReadUsage;

  /// Whether shaders can write the texture.
  bool get enableShaderWriteUsage =>
      _impeller?.enableShaderWriteUsage ?? _wgpu!.enableShaderWriteUsage;

  /// The number of mip levels.
  int get mipLevelCount => _impeller?.mipLevelCount ?? _wgpu!.mipLevelCount;

  /// Whether the texture is still backed by GPU memory.
  bool get isValid => _impeller?.isValid ?? _wgpu!.isValid;

  /// The number of slices: 6 for a cube, else 1.
  int get sliceCount =>
      _impeller?.sliceCount ??
      (textureType == TextureType.textureCube ? 6 : 1);

  /// The width of [mipLevel], at least 1.
  int getMipLevelWidth(int mipLevel) {
    final impeller = _impeller;
    if (impeller != null) return impeller.getMipLevelWidth(mipLevel);
    _checkMipLevel(mipLevel);
    final w = width >> mipLevel;
    return w > 0 ? w : 1;
  }

  /// The height of [mipLevel], at least 1.
  int getMipLevelHeight(int mipLevel) {
    final impeller = _impeller;
    if (impeller != null) return impeller.getMipLevelHeight(mipLevel);
    _checkMipLevel(mipLevel);
    final h = height >> mipLevel;
    return h > 0 ? h : 1;
  }

  /// The tightly packed byte size of [mipLevel].
  int getMipLevelSizeInBytes(int mipLevel) {
    final impeller = _impeller;
    if (impeller != null) return impeller.getMipLevelSizeInBytes(mipLevel);
    final f = format;
    final blocksWide = (getMipLevelWidth(mipLevel) + f.blockWidth - 1) ~/
        f.blockWidth;
    final blocksHigh = (getMipLevelHeight(mipLevel) + f.blockHeight - 1) ~/
        f.blockHeight;
    return blocksWide * blocksHigh * f.bytesPerBlock;
  }

  /// The tightly packed byte size of the base level.
  int getBaseMipLevelSizeInBytes() => getMipLevelSizeInBytes(0);

  /// Replaces the texels of one mip level and slice with [sourceBytes].
  void overwrite(ByteData sourceBytes, {int mipLevel = 0, int slice = 0}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.overwrite(sourceBytes, mipLevel: mipLevel, slice: slice);
    } else {
      _wgpu!.overwrite(sourceBytes, mipLevel: mipLevel, slice: slice);
    }
  }

  /// Hands the texture to Flutter as a `ui.Image`.
  ui.Image asImage() => _impeller?.asImage() ?? _wgpu!.asImage();

  void _checkMipLevel(int mipLevel) {
    if (mipLevel < 0 || mipLevel >= mipLevelCount) {
      throw Exception(
        'mipLevel ($mipLevel) must be in the range '
        '[0, ${mipLevelCount - 1}] for this texture',
      );
    }
  }
}
