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

  GpuBackendColorTarget _toBackend() => (
    texture: texture._backend!,
    resolveTexture: resolveTexture?._backend,
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

  GpuBackendDepthStencilTarget _toBackend() => (
    texture: texture._backend!,
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
  RenderPass._impeller(fg.RenderPass this._impeller)
    : _backend = null,
      _recording = null,
      _state = _ItemDrawState();
  RenderPass._backend(GpuBackendRenderPass this._backend)
    : _impeller = null,
      _recording = null,
      _state = null;
  RenderPass._recording(_ItemRecorder this._recording)
    : _impeller = null,
      _backend = null,
      _state = _recording.state;

  final fg.RenderPass? _impeller;
  final GpuBackendRenderPass? _backend;

  // The recorder a pass made by [ItemSet.recorder] on Impeller records its
  // draws into; null for a pass that encodes.
  final _ItemRecorder? _recording;

  // What the pass keeps of the fixed-function state its setters set, on
  // Impeller, where an [ItemSet] replays a kept item's state and restores
  // the pass's own afterwards; null on a registered backend, whose render
  // pipeline bakes that state.
  final _ItemDrawState? _state;

  // The item set this pass records draws for; null for a pass that encodes.
  ItemSet? _records;

  // Whether the draw being recorded reads a buffer the frame's transient
  // arena hands out, which no kept item may hold.
  bool _readsTransient = false;

  void bindPipeline(RenderPipeline pipeline) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindPipeline(pipeline._impeller!);
      return;
    }
    final recording = _recording;
    if (recording != null) {
      recording.bindPipeline(pipeline);
      return;
    }
    _backend!.bindPipeline(pipeline._backend!);
  }

  void bindVertexBuffer(BufferView bufferView, {int slot = 0}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.bindVertexBuffer(bufferView._impeller!, slot: slot);
    } else {
      final recording = _recording;
      if (recording != null) {
        _note(bufferView.buffer);
        recording.bindVertexBuffer(bufferView, slot);
        return;
      }
      if (_records != null) _note(bufferView.buffer);
      _backend!.bindVertexBuffer(
        bufferView.buffer._backend!,
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
      final recording = _recording;
      if (recording != null) {
        _note(bufferView.buffer);
        recording.bindIndexBuffer(bufferView, indexType);
        return;
      }
      if (_records != null) _note(bufferView.buffer);
      _backend!.bindIndexBuffer(
        bufferView.buffer._backend!,
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
      final records = _records;
      if (records != null &&
          !records._viewBlockNames.contains(slot.uniformName)) {
        _note(bufferView.buffer);
      }
      final recording = _recording;
      if (recording != null) {
        recording.bindUniform(slot, bufferView);
        return;
      }
      _backend!.bindUniform(
        slot.shader._backend!,
        slot.uniformName,
        bufferView.buffer._backend!,
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
      final records = _records;
      if (records != null &&
          (_transientTextures[texture] ?? false) &&
          !records._viewTextureNames.contains(slot.uniformName)) {
        _readsTransient = true;
      }
      final recording = _recording;
      if (recording != null) {
        recording.bindTexture(slot, texture, sampler ?? SamplerOptions());
        return;
      }
      _backend!.bindTexture(
        slot.shader._backend!,
        slot.uniformName,
        texture._backend!,
        sampler,
      );
    }
  }

  void _note(DeviceBuffer buffer) {
    if (_transientBuffers[buffer] ?? false) _readsTransient = true;
  }

  void clearBindings() {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.clearBindings();
      return;
    }
    final recording = _recording;
    if (recording != null) {
      recording.clearBindings();
      return;
    }
    _backend!.clearBindings();
  }

  void setColorBlendEnable(bool enable, {int colorAttachmentIndex = 0}) {
    _impeller?.setColorBlendEnable(
      enable,
      colorAttachmentIndex: colorAttachmentIndex,
    );
    final state = _state;
    if (state != null) {
      state.setBlend(colorAttachmentIndex, enable);
      return;
    }
    _backend!.setColorBlendEnable(
      enable,
      colorAttachmentIndex: colorAttachmentIndex,
    );
  }

  void setColorBlendEquation(
    ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  }) {
    _impeller?.setColorBlendEquation(
      equation,
      colorAttachmentIndex: colorAttachmentIndex,
    );
    final state = _state;
    if (state != null) {
      state.setEquation(colorAttachmentIndex, equation);
      return;
    }
    _backend!.setColorBlendEquation(
      equation,
      colorAttachmentIndex: colorAttachmentIndex,
    );
  }

  void setDepthWriteEnable(bool enable) {
    _impeller?.setDepthWriteEnable(enable);
    final state = _state;
    if (state != null) {
      state.depthWrite = enable;
      return;
    }
    _backend!.setDepthWriteEnable(enable);
  }

  void setDepthCompareOperation(CompareFunction compareFunction) {
    _impeller?.setDepthCompareOperation(compareFunction);
    final state = _state;
    if (state != null) {
      state.depthCompare = compareFunction;
      return;
    }
    _backend!.setDepthCompareOperation(compareFunction);
  }

  void setStencilReference(int referenceValue) {
    _impeller?.setStencilReference(referenceValue);
    final state = _state;
    if (state != null) {
      state.stencilReference = referenceValue;
      return;
    }
    _backend!.setStencilReference(referenceValue);
  }

  void setStencilConfig(
    StencilConfig configuration, {
    StencilFace targetFace = StencilFace.both,
  }) {
    _impeller?.setStencilConfig(configuration, targetFace: targetFace);
    final state = _state;
    if (state != null) {
      state.setStencil(configuration, targetFace);
      return;
    }
    _backend!.setStencilConfig(configuration, targetFace);
  }

  void setCullMode(CullMode cullMode) {
    _impeller?.setCullMode(cullMode);
    final state = _state;
    if (state != null) {
      state.cull = cullMode;
      return;
    }
    _backend!.setCullMode(cullMode);
  }

  void setPolygonMode(PolygonMode polygonMode) {
    _impeller?.setPolygonMode(polygonMode);
    final state = _state;
    if (state != null) {
      state.polygon = polygonMode;
      return;
    }
    _backend!.setPolygonMode(polygonMode);
  }

  void setPrimitiveType(PrimitiveType primitiveType) {
    _impeller?.setPrimitiveType(primitiveType);
    final state = _state;
    if (state != null) {
      state.primitive = primitiveType;
      return;
    }
    _backend!.setPrimitiveType(primitiveType);
  }

  void setWindingOrder(WindingOrder windingOrder) {
    _impeller?.setWindingOrder(windingOrder);
    final state = _state;
    if (state != null) {
      state.winding = windingOrder;
      return;
    }
    _backend!.setWindingOrder(windingOrder);
  }

  void setScissor(Scissor scissor) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setScissor(scissor);
      return;
    }
    // A recorder states no viewport or scissor: a kept item draws under the
    // ones of the pass that draws it.
    if (_recording != null) return;
    _backend!.setScissor(scissor);
  }

  void setViewport(Viewport viewport) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.setViewport(viewport);
      return;
    }
    // A recorder states no viewport or scissor: a kept item draws under the
    // ones of the pass that draws it.
    if (_recording != null) return;
    _backend!.setViewport(viewport);
  }

  void draw(int vertexCount, {int instanceCount = 1}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.draw(vertexCount, instanceCount: instanceCount);
      return;
    }
    final recording = _recording;
    if (recording != null) {
      recording.record(vertexCount, instanceCount, indexed: false);
      return;
    }
    _backend!.draw(vertexCount, instanceCount: instanceCount);
  }

  void drawIndexed(int indexCount, {int instanceCount = 1}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.drawIndexed(indexCount, instanceCount: instanceCount);
      return;
    }
    final recording = _recording;
    if (recording != null) {
      recording.record(indexCount, instanceCount, indexed: true);
      return;
    }
    _backend!.drawIndexed(indexCount, instanceCount: instanceCount);
  }

  /// Draws indexed primitives with the five 32-bit draw arguments at the
  /// start of [arguments]: index count, instance count, first index, base
  /// vertex and first instance, which a compute pass may have written.
  ///
  /// Throws an [UnsupportedError] on Impeller, which draws no indirect
  /// arguments; check `gpuHost.capabilities.indirectDraw` first.
  void drawIndexedIndirect(BufferView arguments) {
    final backend =
        _backend ??
        (throw UnsupportedError('Impeller draws no indirect arguments.'));
    backend.drawIndexedIndirect(
      arguments.buffer._backend!,
      arguments.offsetInBytes,
    );
  }
}
