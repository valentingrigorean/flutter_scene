part of '_gpu.dart';

/// A rectangle of one mip level and slice of a texture. A width or height of
/// -1 spans the whole mip level.
final class TextureRegion {
  const TextureRegion(
    this.texture, {
    this.x = 0,
    this.y = 0,
    this.width = -1,
    this.height = -1,
    this.mipLevel = 0,
    this.slice = 0,
  });

  final Texture texture;
  final int x;
  final int y;
  final int width;
  final int height;
  final int mipLevel;
  final int slice;

  fg.TextureRegion get _impeller => fg.TextureRegion(
    texture._impeller!,
    x: x,
    y: y,
    width: width,
    height: height,
    mipLevel: mipLevel,
    slice: slice,
  );

  WgpuTextureRegion get _wgpu => (
    texture: texture._wgpu!,
    x: x,
    y: y,
    width: width == -1 ? texture.getMipLevelWidth(mipLevel) : width,
    height: height == -1 ? texture.getMipLevelHeight(mipLevel) : height,
    mipLevel: mipLevel,
    slice: slice,
  );
}

/// Where a texture-to-texture copy lands.
final class TextureDestinationRegion {
  const TextureDestinationRegion(
    this.texture, {
    this.x = 0,
    this.y = 0,
    this.mipLevel = 0,
    this.slice = 0,
  });

  final Texture texture;
  final int x;
  final int y;
  final int mipLevel;
  final int slice;
}

/// Records render passes and copies, then submits them to the GPU.
final class CommandBuffer {
  CommandBuffer._impeller(fg.CommandBuffer this._impeller) : _wgpu = null;
  CommandBuffer._wgpu(WgpuCommandBuffer this._wgpu) : _impeller = null;

  final fg.CommandBuffer? _impeller;
  final WgpuCommandBuffer? _wgpu;
  bool _wgpuSubmitted = false;

  /// Whether [submit] has run.
  bool get submitted => _impeller?.submitted ?? _wgpuSubmitted;

  /// Starts a render pass into [renderTarget].
  RenderPass createRenderPass(RenderTarget renderTarget) {
    final impeller = _impeller;
    if (impeller != null) {
      return RenderPass._impeller(
        impeller.createRenderPass(renderTarget._toImpeller()),
      );
    }
    return RenderPass._wgpu(
      _wgpu!.createRenderPass(
        colors: [
          for (final color in renderTarget.colorAttachments) color._toWgpu(),
        ],
        depthStencil: renderTarget.depthStencilAttachment?._toWgpu(),
      ),
    );
  }

  /// Copies tightly packed texel data from [source] into [destination].
  void copyBufferToTexture(BufferView source, TextureRegion destination) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.copyBufferToTexture(source._impeller!, destination._impeller);
    } else {
      _wgpu!.copyBufferToTexture(source._wgpu, destination._wgpu);
    }
  }

  /// Copies the texels of [source] into [destination], tightly packed.
  void copyTextureToBuffer(TextureRegion source, BufferView destination) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.copyTextureToBuffer(source._impeller, destination._impeller!);
    } else {
      _wgpu!.copyTextureToBuffer(source._wgpu, destination._wgpu);
    }
  }

  /// Copies the texels of [source] into [destination].
  void copyTextureToTexture(
    TextureRegion source,
    TextureDestinationRegion destination,
  ) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.copyTextureToTexture(
        source._impeller,
        fg.TextureDestinationRegion(
          destination.texture._impeller!,
          x: destination.x,
          y: destination.y,
          mipLevel: destination.mipLevel,
          slice: destination.slice,
        ),
      );
    } else {
      _wgpu!.copyTextureToTexture(
        source._wgpu,
        destination.texture._wgpu!,
        x: destination.x,
        y: destination.y,
        mipLevel: destination.mipLevel,
        slice: destination.slice,
      );
    }
  }

  /// Submits the recorded work. [completionCallback] runs once the GPU is
  /// done with it.
  void submit({CompletionCallback? completionCallback}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.submit(completionCallback: completionCallback);
      return;
    }
    if (_wgpuSubmitted) {
      throw StateError('CommandBuffer has already been submitted.');
    }
    _wgpu!.submit(completionCallback: completionCallback);
    _wgpuSubmitted = true;
  }
}
