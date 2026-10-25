// The packed command stream, written here and decoded by
// native/src/commands.rs.
//
// Little-endian. Each command is an 8-byte header (u32 opcode, u32 payload
// length in bytes) and its payload. Scalars are u32 unless marked; u64
// fields (handles, offsets, sizes) are 8 bytes and need no alignment. Enum
// values are flutter_gpu ordinals. The native decoder rejects a command
// whose payload length does not match what it reads.
//
//  op  command                    payload
//  1   begin render pass          color count; per color: u64 texture, mip
//                                 level, slice, load action, store action,
//                                 f32 r g b a clear, u64 resolve texture (0:
//                                 none); has depth/stencil; if set: u64
//                                 texture, mip level, slice, depth load,
//                                 depth store, f32 depth clear, stencil load,
//                                 stencil store, stencil clear
//  2   end render pass            -
//  3   bind pipeline              u64 pipeline
//  4   bind vertex buffer         slot, u64 buffer, u64 offset, u64 size (0:
//                                 to the end)
//  5   bind index buffer          u64 buffer, u64 offset, u64 size (0: to the
//                                 end), index type
//  6   bind buffer range          group, binding, u64 buffer, u64 offset, u64
//                                 size (0: to the end)
//  7   bind texture and sampler   group, texture binding, u64 texture,
//                                 sampler binding, u64 sampler (0: none)
//  8   set viewport               f32 x, y, width, height, min/max depth
//  9   set scissor                x, y, width, height
//  10  set stencil reference      reference
//  11  set blend constant         f32 r, g, b, a
//  12  draw                       vertex count, instance count, first
//                                 vertex, first instance
//  13  draw indexed               index count, instance count, first index,
//                                 i32 base vertex, first instance
//  14  copy buffer to buffer      u64 src, u64 src offset, u64 dst, u64 dst
//                                 offset, u64 size
//  15  copy buffer to texture     u64 buffer, u64 offset, bytes per row, rows
//                                 per image, u64 texture, mip, slice, x, y,
//                                 width, height
//  16  copy texture to buffer     u64 texture, mip, slice, x, y, width,
//                                 height, u64 buffer, u64 offset, bytes per
//                                 row, rows per image
//  17  copy texture to texture    u64 src, mip, slice, x, y, u64 dst, mip,
//                                 slice, x, y, width, height
//  18  generate mipmaps           u64 texture
//
// Commands 3 to 13 need an open render pass, 14 to 18 need none. Bindings
// persist until rebound. Buffer copies need bytes per row to be a multiple
// of 256; uniform binding offsets a multiple of
// WgpuLimits.minUniformBufferOffsetAlignment.

import 'dart:ffi';

import 'package:flutter_gpu/gpu.dart';

import 'device.dart';
import 'packed_writer.dart';

/// A clear color for a color attachment.
class WgpuColor {
  /// Creates a color from linear components.
  const WgpuColor(this.r, this.g, this.b, this.a);

  /// Red.
  final double r;

  /// Green.
  final double g;

  /// Blue.
  final double b;

  /// Alpha.
  final double a;
}

/// A color attachment of a render pass.
class WgpuColorAttachment {
  /// Creates an attachment rendering into [texture].
  const WgpuColorAttachment({
    required this.texture,
    this.loadAction = LoadAction.clear,
    this.storeAction = StoreAction.store,
    this.clearColor = const WgpuColor(0, 0, 0, 0),
    this.resolveTexture,
    this.mipLevel = 0,
    this.slice = 0,
  });

  /// The texture rendered into.
  final WgpuTexture texture;

  /// What happens to its contents when the pass begins.
  final LoadAction loadAction;

  /// What happens to its contents when the pass ends.
  final StoreAction storeAction;

  /// The clear color for [LoadAction.clear].
  final WgpuColor clearColor;

  /// The single-sampled texture a multisample store action resolves into.
  final WgpuTexture? resolveTexture;

  /// The mip level rendered into.
  final int mipLevel;

  /// The array layer or cube face rendered into.
  final int slice;
}

/// The depth/stencil attachment of a render pass.
class WgpuDepthStencilAttachment {
  /// Creates an attachment rendering into [texture].
  const WgpuDepthStencilAttachment({
    required this.texture,
    this.depthLoadAction = LoadAction.clear,
    this.depthStoreAction = StoreAction.dontCare,
    this.depthClearValue = 1,
    this.stencilLoadAction = LoadAction.clear,
    this.stencilStoreAction = StoreAction.dontCare,
    this.stencilClearValue = 0,
    this.mipLevel = 0,
    this.slice = 0,
  });

  /// The depth/stencil texture.
  final WgpuTexture texture;

  /// Depth load action.
  final LoadAction depthLoadAction;

  /// Depth store action.
  final StoreAction depthStoreAction;

  /// Depth clear value.
  final double depthClearValue;

  /// Stencil load action.
  final LoadAction stencilLoadAction;

  /// Stencil store action.
  final StoreAction stencilStoreAction;

  /// Stencil clear value.
  final int stencilClearValue;

  /// The mip level rendered into.
  final int mipLevel;

  /// The array layer or cube face rendered into.
  final int slice;
}

/// Records commands into one packed buffer for [WgpuDevice.submit].
class WgpuCommandStream {
  /// Creates an empty stream.
  WgpuCommandStream() : _w = PackedWriter();

  final PackedWriter _w;
  int _headerAt = -1;

  /// The native address of the recorded commands.
  Pointer<Uint8> get pointer => _w.pointer;

  /// The recorded length in bytes.
  int get length => _w.length;

  void _begin(int op) {
    _w.u32(op);
    _headerAt = _w.length;
    _w.u32(0);
  }

  void _end() => _w.patchU32(_headerAt, _w.length - _headerAt - 4);

  void _texRef(WgpuTexture texture, int mip, int slice, int x, int y) {
    _w.u64(texture.handle);
    _w.u32(mip);
    _w.u32(slice);
    _w.u32(x);
    _w.u32(y);
  }

  /// Begins a render pass.
  void beginRenderPass(
    List<WgpuColorAttachment> colors, {
    WgpuDepthStencilAttachment? depthStencil,
  }) {
    _begin(1);
    _w.u32(colors.length);
    for (final c in colors) {
      _w.u64(c.texture.handle);
      _w.u32(c.mipLevel);
      _w.u32(c.slice);
      _w.u32(c.loadAction.index);
      _w.u32(c.storeAction.index);
      _w.f32(c.clearColor.r);
      _w.f32(c.clearColor.g);
      _w.f32(c.clearColor.b);
      _w.f32(c.clearColor.a);
      _w.u64(c.resolveTexture?.handle ?? 0);
    }
    final ds = depthStencil;
    _w.boolean(ds != null);
    if (ds != null) {
      _w.u64(ds.texture.handle);
      _w.u32(ds.mipLevel);
      _w.u32(ds.slice);
      _w.u32(ds.depthLoadAction.index);
      _w.u32(ds.depthStoreAction.index);
      _w.f32(ds.depthClearValue);
      _w.u32(ds.stencilLoadAction.index);
      _w.u32(ds.stencilStoreAction.index);
      _w.u32(ds.stencilClearValue);
    }
    _end();
  }

  /// Ends the open render pass.
  void endRenderPass() {
    _begin(2);
    _end();
  }

  /// Binds a compiled pipeline.
  void bindPipeline(WgpuPipeline pipeline) {
    _begin(3);
    _w.u64(pipeline.handle);
    _end();
  }

  /// Binds a vertex buffer range to [slot]; [size] 0 runs to the end.
  void bindVertexBuffer(
    int slot,
    WgpuBuffer buffer, {
    int offset = 0,
    int size = 0,
  }) {
    _begin(4);
    _w.u32(slot);
    _w.u64(buffer.handle);
    _w.u64(offset);
    _w.u64(size);
    _end();
  }

  /// Binds an index buffer range; [size] 0 runs to the end.
  void bindIndexBuffer(
    WgpuBuffer buffer,
    IndexType type, {
    int offset = 0,
    int size = 0,
  }) {
    _begin(5);
    _w.u64(buffer.handle);
    _w.u64(offset);
    _w.u64(size);
    _w.u32(type.index);
    _end();
  }

  /// Binds a uniform or storage buffer range at `@group(group)
  /// @binding(binding)`; [size] 0 runs to the end.
  void bindBuffer(
    int group,
    int binding,
    WgpuBuffer buffer, {
    int offset = 0,
    int size = 0,
  }) {
    _begin(6);
    _w.u32(group);
    _w.u32(binding);
    _w.u64(buffer.handle);
    _w.u64(offset);
    _w.u64(size);
    _end();
  }

  /// Binds [texture] at [binding] and, when given, [sampler] at
  /// [samplerBinding], both in [group].
  void bindTexture(
    int group,
    int binding,
    WgpuTexture texture, {
    WgpuSampler? sampler,
    int? samplerBinding,
  }) {
    _begin(7);
    _w.u32(group);
    _w.u32(binding);
    _w.u64(texture.handle);
    _w.u32(samplerBinding ?? binding + 1);
    _w.u64(sampler?.handle ?? 0);
    _end();
  }

  /// Sets the viewport.
  void setViewport(
    double x,
    double y,
    double width,
    double height, {
    double minDepth = 0,
    double maxDepth = 1,
  }) {
    _begin(8);
    for (final v in [x, y, width, height, minDepth, maxDepth]) {
      _w.f32(v);
    }
    _end();
  }

  /// Sets the scissor rectangle.
  void setScissor(int x, int y, int width, int height) {
    _begin(9);
    for (final v in [x, y, width, height]) {
      _w.u32(v);
    }
    _end();
  }

  /// Sets the stencil reference value.
  void setStencilReference(int reference) {
    _begin(10);
    _w.u32(reference);
    _end();
  }

  /// Sets the blend constant.
  void setBlendConstant(WgpuColor color) {
    _begin(11);
    _w.f32(color.r);
    _w.f32(color.g);
    _w.f32(color.b);
    _w.f32(color.a);
    _end();
  }

  /// Draws non-indexed primitives.
  void draw(
    int vertexCount, {
    int instanceCount = 1,
    int firstVertex = 0,
    int firstInstance = 0,
  }) {
    _begin(12);
    _w.u32(vertexCount);
    _w.u32(instanceCount);
    _w.u32(firstVertex);
    _w.u32(firstInstance);
    _end();
  }

  /// Draws indexed primitives.
  void drawIndexed(
    int indexCount, {
    int instanceCount = 1,
    int firstIndex = 0,
    int baseVertex = 0,
    int firstInstance = 0,
  }) {
    _begin(13);
    _w.u32(indexCount);
    _w.u32(instanceCount);
    _w.u32(firstIndex);
    _w.i32(baseVertex);
    _w.u32(firstInstance);
    _end();
  }

  /// Copies between buffers.
  void copyBufferToBuffer(
    WgpuBuffer src,
    WgpuBuffer dst,
    int size, {
    int srcOffset = 0,
    int dstOffset = 0,
  }) {
    _begin(14);
    _w.u64(src.handle);
    _w.u64(srcOffset);
    _w.u64(dst.handle);
    _w.u64(dstOffset);
    _w.u64(size);
    _end();
  }

  /// Copies buffer rows into a texture region.
  void copyBufferToTexture(
    WgpuBuffer buffer,
    WgpuTexture texture, {
    required int bytesPerRow,
    required int width,
    required int height,
    int bufferOffset = 0,
    int? rowsPerImage,
    int mipLevel = 0,
    int slice = 0,
    int x = 0,
    int y = 0,
  }) {
    _begin(15);
    _w.u64(buffer.handle);
    _w.u64(bufferOffset);
    _w.u32(bytesPerRow);
    _w.u32(rowsPerImage ?? height);
    _texRef(texture, mipLevel, slice, x, y);
    _w.u32(width);
    _w.u32(height);
    _end();
  }

  /// Copies a texture region into buffer rows.
  void copyTextureToBuffer(
    WgpuTexture texture,
    WgpuBuffer buffer, {
    required int bytesPerRow,
    required int width,
    required int height,
    int bufferOffset = 0,
    int? rowsPerImage,
    int mipLevel = 0,
    int slice = 0,
    int x = 0,
    int y = 0,
  }) {
    _begin(16);
    _texRef(texture, mipLevel, slice, x, y);
    _w.u32(width);
    _w.u32(height);
    _w.u64(buffer.handle);
    _w.u64(bufferOffset);
    _w.u32(bytesPerRow);
    _w.u32(rowsPerImage ?? height);
    _end();
  }

  /// Copies a region between textures.
  void copyTextureToTexture(
    WgpuTexture src,
    WgpuTexture dst, {
    required int width,
    required int height,
    int srcMipLevel = 0,
    int srcSlice = 0,
    int srcX = 0,
    int srcY = 0,
    int dstMipLevel = 0,
    int dstSlice = 0,
    int dstX = 0,
    int dstY = 0,
  }) {
    _begin(17);
    _texRef(src, srcMipLevel, srcSlice, srcX, srcY);
    _texRef(dst, dstMipLevel, dstSlice, dstX, dstY);
    _w.u32(width);
    _w.u32(height);
    _end();
  }

  /// Fills every mip level below 0 from the level above it.
  void generateMipmaps(WgpuTexture texture) {
    _begin(18);
    _w.u64(texture.handle);
    _end();
  }

  /// Clears the recorded commands for reuse.
  void reset() => _w.reset();

  /// Frees the native buffer.
  void dispose() => _w.dispose();
}
