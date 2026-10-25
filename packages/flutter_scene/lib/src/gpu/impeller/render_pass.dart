part of '_gpu.dart';

/// A color texture a render pass draws into.
final class ColorAttachment {
  ColorAttachment({
    this.loadAction = LoadAction.clear,
    this.storeAction = StoreAction.store,
    vm.Vector4? clearValue,
    required this.texture,
    this.resolveTexture,
    this.mipLevel = 0,
    this.slice = 0,
  }) : clearValue = clearValue ?? vm.Vector4.zero();

  LoadAction loadAction;
  StoreAction storeAction;
  vm.Vector4 clearValue;
  Texture texture;

  /// The single-sample texture a multisampled [texture] resolves into.
  Texture? resolveTexture;

  int mipLevel;
  int slice;

  fg.ColorAttachment _toImpeller() => fg.ColorAttachment(
    loadAction: loadAction,
    storeAction: storeAction,
    clearValue: clearValue,
    texture: texture._impeller!,
    resolveTexture: resolveTexture?._impeller,
    mipLevel: mipLevel,
    slice: slice,
  );

  WgpuColorTarget _toWgpu() => (
    texture: texture._wgpu!,
    resolveTexture: resolveTexture?._wgpu,
    loadAction: loadAction,
    storeAction: storeAction,
    clearValue: clearValue,
    mipLevel: mipLevel,
    slice: slice,
  );
}

/// The depth-stencil texture a render pass tests and writes.
final class DepthStencilAttachment {
  DepthStencilAttachment({
    this.depthLoadAction = LoadAction.clear,
    this.depthStoreAction = StoreAction.dontCare,
    this.depthClearValue = 0.0,
    this.stencilLoadAction = LoadAction.clear,
    this.stencilStoreAction = StoreAction.dontCare,
    this.stencilClearValue = 0,
    required this.texture,
    this.mipLevel = 0,
    this.slice = 0,
  });

  LoadAction depthLoadAction;
  StoreAction depthStoreAction;
  double depthClearValue;
  LoadAction stencilLoadAction;
  StoreAction stencilStoreAction;
  int stencilClearValue;
  Texture texture;
  int mipLevel;
  int slice;

  fg.DepthStencilAttachment _toImpeller() => fg.DepthStencilAttachment(
    depthLoadAction: depthLoadAction,
    depthStoreAction: depthStoreAction,
    depthClearValue: depthClearValue,
    stencilLoadAction: stencilLoadAction,
    stencilStoreAction: stencilStoreAction,
    stencilClearValue: stencilClearValue,
    texture: texture._impeller!,
    mipLevel: mipLevel,
    slice: slice,
  );

  WgpuDepthStencilTarget _toWgpu() => (
    texture: texture._wgpu!,
    depthLoadAction: depthLoadAction,
    depthStoreAction: depthStoreAction,
    depthClearValue: depthClearValue,
    stencilLoadAction: stencilLoadAction,
    stencilStoreAction: stencilStoreAction,
    stencilClearValue: stencilClearValue,
    mipLevel: mipLevel,
    slice: slice,
  );
}

/// The attachments one render pass draws into.
final class RenderTarget {
  const RenderTarget({
    this.colorAttachments = const <ColorAttachment>[],
    this.depthStencilAttachment,
  });

  /// A target with one color attachment.
  RenderTarget.singleColor(
    ColorAttachment colorAttachment, {
    DepthStencilAttachment? depthStencilAttachment,
  }) : this(
         colorAttachments: [colorAttachment],
         depthStencilAttachment: depthStencilAttachment,
       );

  final List<ColorAttachment> colorAttachments;
  final DepthStencilAttachment? depthStencilAttachment;

  fg.RenderTarget _toImpeller() => fg.RenderTarget(
    colorAttachments: [
      for (final color in colorAttachments) color._toImpeller(),
    ],
    depthStencilAttachment: depthStencilAttachment?._toImpeller(),
  );
}

/// Draws into a [RenderTarget]; created by [CommandBuffer.createRenderPass].
final class RenderPass {
  RenderPass._impeller(fg.RenderPass this._impeller) : _wgpu = null;
  RenderPass._wgpu(WgpuRenderPass this._wgpu) : _impeller = null;

  final fg.RenderPass? _impeller;
  final WgpuRenderPass? _wgpu;

  void bindPipeline(RenderPipeline pipeline) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindPipeline(pipeline._impeller!);
    } else {
      _wgpu!.bindPipeline(pipeline._wgpu!);
    }
  }

  void bindVertexBuffer(BufferView bufferView, {int slot = 0}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindVertexBuffer(bufferView._impeller!, slot: slot);
    } else {
      _wgpu!.bindVertexBuffer(
        bufferView.buffer._wgpu!,
        bufferView.offsetInBytes,
        bufferView.lengthInBytes,
        slot: slot,
      );
    }
  }

  void bindIndexBuffer(BufferView bufferView, IndexType indexType) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindIndexBuffer(bufferView._impeller!, indexType);
    } else {
      _wgpu!.bindIndexBuffer(
        bufferView.buffer._wgpu!,
        bufferView.offsetInBytes,
        bufferView.lengthInBytes,
        indexType,
      );
    }
  }

  void bindUniform(UniformSlot slot, BufferView bufferView) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindUniform(slot._impeller!, bufferView._impeller!);
    } else {
      _wgpu!.bindUniform(
        slot.shader._wgpu!,
        slot.uniformName,
        bufferView.buffer._wgpu!,
        bufferView.offsetInBytes,
        bufferView.lengthInBytes,
      );
    }
  }

  void bindTexture(
    UniformSlot slot,
    Texture texture, {
    SamplerOptions? sampler,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindTexture(
        slot._impeller!,
        texture._impeller!,
        sampler: sampler,
      );
    } else {
      _wgpu!.bindTexture(
        slot.shader._wgpu!,
        slot.uniformName,
        texture._wgpu!,
        sampler,
      );
    }
  }

  void clearBindings() {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.clearBindings();
    } else {
      _wgpu!.clearBindings();
    }
  }

  void setColorBlendEnable(bool enable, {int colorAttachmentIndex = 0}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setColorBlendEnable(
        enable,
        colorAttachmentIndex: colorAttachmentIndex,
      );
    } else {
      _wgpu!.setColorBlendEnable(
        enable,
        colorAttachmentIndex: colorAttachmentIndex,
      );
    }
  }

  void setColorBlendEquation(
    ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setColorBlendEquation(
        equation,
        colorAttachmentIndex: colorAttachmentIndex,
      );
    } else {
      _wgpu!.setColorBlendEquation(
        equation,
        colorAttachmentIndex: colorAttachmentIndex,
      );
    }
  }

  void setDepthWriteEnable(bool enable) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setDepthWriteEnable(enable);
    } else {
      _wgpu!.setDepthWriteEnable(enable);
    }
  }

  void setDepthCompareOperation(CompareFunction compareFunction) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setDepthCompareOperation(compareFunction);
    } else {
      _wgpu!.setDepthCompareOperation(compareFunction);
    }
  }

  void setStencilReference(int referenceValue) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setStencilReference(referenceValue);
    } else {
      _wgpu!.setStencilReference(referenceValue);
    }
  }

  void setStencilConfig(
    StencilConfig configuration, {
    StencilFace targetFace = StencilFace.both,
  }) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setStencilConfig(configuration, targetFace: targetFace);
    } else {
      _wgpu!.setStencilConfig(configuration, targetFace);
    }
  }

  void setCullMode(CullMode cullMode) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setCullMode(cullMode);
    } else {
      _wgpu!.setCullMode(cullMode);
    }
  }

  void setPolygonMode(PolygonMode polygonMode) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setPolygonMode(polygonMode);
    } else {
      _wgpu!.setPolygonMode(polygonMode);
    }
  }

  void setPrimitiveType(PrimitiveType primitiveType) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setPrimitiveType(primitiveType);
    } else {
      _wgpu!.setPrimitiveType(primitiveType);
    }
  }

  void setWindingOrder(WindingOrder windingOrder) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setWindingOrder(windingOrder);
    } else {
      _wgpu!.setWindingOrder(windingOrder);
    }
  }

  void setScissor(Scissor scissor) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setScissor(scissor);
    } else {
      _wgpu!.setScissor(scissor);
    }
  }

  void setViewport(Viewport viewport) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setViewport(viewport);
    } else {
      _wgpu!.setViewport(viewport);
    }
  }

  void draw(int vertexCount, {int instanceCount = 1}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.draw(vertexCount, instanceCount: instanceCount);
    } else {
      _wgpu!.draw(vertexCount, instanceCount: instanceCount);
    }
  }

  void drawIndexed(int indexCount, {int instanceCount = 1}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.drawIndexed(indexCount, instanceCount: instanceCount);
    } else {
      _wgpu!.drawIndexed(indexCount, instanceCount: instanceCount);
    }
  }
}
