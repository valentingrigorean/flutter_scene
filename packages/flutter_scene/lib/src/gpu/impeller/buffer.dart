part of '_gpu.dart';

/// A range of a [DeviceBuffer].
final class BufferView {
  /// A view of [lengthInBytes] bytes of [buffer] from [offsetInBytes].
  BufferView(
    this.buffer, {
    required this.offsetInBytes,
    required this.lengthInBytes,
  }) : _impeller = switch (buffer._impeller) {
         final impeller? => fg.BufferView(
           impeller,
           offsetInBytes: offsetInBytes,
           lengthInBytes: lengthInBytes,
         ),
         null => null,
       };

  BufferView._fromImpeller(this.buffer, fg.BufferView view)
    : offsetInBytes = view.offsetInBytes,
      lengthInBytes = view.lengthInBytes,
      _impeller = view;

  /// The buffer this views.
  final DeviceBuffer buffer;

  /// Where the range starts in [buffer].
  final int offsetInBytes;

  /// How long the range is.
  final int lengthInBytes;

  // Built once with the view, so binding it on Impeller allocates nothing.
  final fg.BufferView? _impeller;

  WgpuBufferRange get _wgpu => (
    buffer: buffer._wgpu!,
    offsetInBytes: offsetInBytes,
    lengthInBytes: lengthInBytes,
  );
}

/// A region of GPU memory.
final class DeviceBuffer {
  DeviceBuffer._impeller(fg.DeviceBuffer this._impeller) : _wgpu = null;
  DeviceBuffer._wgpu(WgpuDeviceBuffer this._wgpu) : _impeller = null;

  final fg.DeviceBuffer? _impeller;
  final WgpuDeviceBuffer? _wgpu;

  /// How the memory is reachable from the host.
  StorageMode get storageMode => _impeller?.storageMode ?? _wgpu!.storageMode;

  /// The buffer's size.
  int get sizeInBytes => _impeller?.sizeInBytes ?? _wgpu!.sizeInBytes;

  /// Whether the buffer is still backed by GPU memory.
  bool get isValid => _impeller?.isValid ?? _wgpu!.isValid;

  /// Copies [sourceBytes] into the buffer from [destinationOffsetInBytes].
  /// Returns false when the copy did not happen.
  bool overwrite(ByteData sourceBytes, {int destinationOffsetInBytes = 0}) =>
      _impeller?.overwrite(
        sourceBytes,
        destinationOffsetInBytes: destinationOffsetInBytes,
      ) ??
      _wgpu!.overwrite(
        sourceBytes,
        destinationOffsetInBytes: destinationOffsetInBytes,
      );

  /// Makes host writes to the range visible to the GPU.
  void flush({int offsetInBytes = 0, int lengthInBytes = -1}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.flush(offsetInBytes: offsetInBytes, lengthInBytes: lengthInBytes);
    } else {
      _wgpu!.flush(offsetInBytes: offsetInBytes, lengthInBytes: lengthInBytes);
    }
  }
}

/// A per-frame bump allocator for transient data such as uniforms.
final class HostBuffer {
  HostBuffer._impeller(fg.HostBuffer this._impeller)
    : _wgpu = null,
      blockLengthInBytes = _impeller.blockLengthInBytes;
  HostBuffer._wgpu(WgpuHostBuffer this._wgpu, this.blockLengthInBytes)
    : _impeller = null;

  /// The block size [GpuContext.createHostBuffer] uses by default.
  static const int kDefaultBlockLengthInBytes =
      fg.HostBuffer.kDefaultBlockLengthInBytes;

  final fg.HostBuffer? _impeller;
  final WgpuHostBuffer? _wgpu;

  /// The size of each block the allocator draws from.
  final int blockLengthInBytes;

  /// How many frames of blocks the allocator rotates through.
  int get frameCount => _impeller?.frameCount ?? _wgpu!.frameCount;

  // The blocks Impeller allocates are its own buffers; each gets one wrapper,
  // and the last one is kept so a run of emplaces into a block does not look
  // it up again.
  static final Expando<DeviceBuffer> _blocks = Expando('HostBuffer block');
  static final Expando<DeviceBuffer> _wgpuBlocks = Expando('HostBuffer block');
  fg.DeviceBuffer? _lastBlock;
  DeviceBuffer? _lastWrapped;

  /// Copies [bytes] into the current frame's blocks and returns its range.
  BufferView emplace(ByteData bytes) {
    final impeller = _impeller;
    if (impeller != null) {
      final view = impeller.emplace(bytes);
      final block = view.buffer;
      var wrapped = _lastWrapped;
      if (!identical(block, _lastBlock) || wrapped == null) {
        wrapped = _blocks[block] ??= DeviceBuffer._impeller(block);
        _lastBlock = block;
        _lastWrapped = wrapped;
      }
      return BufferView._fromImpeller(wrapped, view);
    }
    final range = _wgpu!.emplace(bytes);
    return BufferView(
      _wgpuBlocks[range.buffer] ??= DeviceBuffer._wgpu(range.buffer),
      offsetInBytes: range.offsetInBytes,
      lengthInBytes: range.lengthInBytes,
    );
  }

  /// Advances to the next frame's blocks.
  void reset() {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.reset();
    } else {
      _wgpu!.reset();
    }
  }
}
