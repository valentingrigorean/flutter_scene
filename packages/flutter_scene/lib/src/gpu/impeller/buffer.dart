part of '_gpu.dart';

/// A range of a [DeviceBuffer].
final class BufferView {
  /// A view of [lengthInBytes] bytes of [buffer] from [offsetInBytes].
  BufferView(
    this.buffer, {
    required this.offsetInBytes,
    required this.lengthInBytes,
  }) : _fixed = switch (buffer._fixed) {
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
      _fixed = view;

  /// The buffer this views.
  final DeviceBuffer buffer;

  /// Where the range starts in [buffer].
  final int offsetInBytes;

  /// How long the range is.
  final int lengthInBytes;

  // Built once with the view, so binding it on Impeller allocates nothing.
  final fg.BufferView? _fixed;

  // The view onto the copy of an ordered buffer it was last bound with.
  fg.DeviceBuffer? _copy;
  fg.BufferView? _copyView;

  // The flutter_gpu view a pass binds. On a buffer with ordered writes it
  // views the copy current at the bind, which a later write leaves alone
  // while the GPU may still read it.
  fg.BufferView? get _impeller {
    final fixed = _fixed;
    if (fixed != null) return fixed;
    final copy = buffer._ordered?.current;
    if (copy == null) return null;
    if (!identical(copy, _copy)) {
      _copy = copy;
      _copyView = fg.BufferView(
        copy,
        offsetInBytes: offsetInBytes,
        lengthInBytes: lengthInBytes,
      );
    }
    return _copyView;
  }

  GpuBackendBufferRange get _backend => (
    buffer: buffer._backend!,
    offsetInBytes: offsetInBytes,
    lengthInBytes: lengthInBytes,
  );
}

/// A region of GPU memory.
final Expando<bool> _transientBuffers = Expando('transient buffer');

/// States that [buffer] holds a frame's transient data, rewritten for other
/// draws in later frames, so a draw that reads it is never kept in an
/// [ItemSet].
void markTransientBuffer(DeviceBuffer buffer) =>
    _transientBuffers[buffer] = true;

final class DeviceBuffer {
  DeviceBuffer._impeller(fg.DeviceBuffer this._fixed)
    : _ordered = null,
      _backend = null;
  DeviceBuffer._ordered(_OrderedCopies this._ordered)
    : _fixed = null,
      _backend = null;
  DeviceBuffer._backend(GpuBackendDeviceBuffer this._backend)
    : _fixed = null,
      _ordered = null;

  final fg.DeviceBuffer? _fixed;
  final _OrderedCopies? _ordered;
  final GpuBackendDeviceBuffer? _backend;

  fg.DeviceBuffer? get _impeller => _fixed ?? _ordered?.current;

  /// How the memory is reachable from the host.
  StorageMode get storageMode =>
      _impeller?.storageMode ?? _backend!.storageMode;

  /// The buffer's size.
  int get sizeInBytes => _impeller?.sizeInBytes ?? _backend!.sizeInBytes;

  /// Whether the buffer is still backed by GPU memory.
  bool get isValid => _impeller?.isValid ?? _backend!.isValid;

  /// Copies [sourceBytes] into the buffer from [destinationOffsetInBytes].
  /// Returns false when the copy did not happen.
  bool overwrite(ByteData sourceBytes, {int destinationOffsetInBytes = 0}) =>
      _ordered?.overwrite(sourceBytes, destinationOffsetInBytes) ??
      _impeller?.overwrite(
        sourceBytes,
        destinationOffsetInBytes: destinationOffsetInBytes,
      ) ??
      _backend!.overwrite(
        sourceBytes,
        destinationOffsetInBytes: destinationOffsetInBytes,
      );

  /// Makes host writes to the range visible to the GPU.
  void flush({int offsetInBytes = 0, int lengthInBytes = -1}) {
    final impeller = _impeller;
    if (impeller != null) {
      impeller.flush(
        offsetInBytes: offsetInBytes,
        lengthInBytes: lengthInBytes,
      );
    } else {
      _backend!.flush(
        offsetInBytes: offsetInBytes,
        lengthInBytes: lengthInBytes,
      );
    }
  }
}

// The submissions made through [CommandBuffer.submit] on Impeller, and those
// the GPU has not finished, oldest first.
int _impellerSubmitted = 0;
final List<int> _impellerPending = [];

int get _impellerCompletedThrough =>
    _impellerPending.isEmpty ? _impellerSubmitted : _impellerPending.first - 1;

// A buffer with ordered writes on Impeller ([GpuContext.createOrderedDeviceBuffer]).
// Flutter GPU copies no buffer into another on the GPU, so a write the GPU
// may still be reading the current copy for moves to another copy, which the
// next bind and every kept draw read from then on. A copy waits until the
// submissions that may read it complete, then catches up on the bytes written
// since from a host mirror.
final class _OrderedCopies {
  _OrderedCopies(this._context, int sizeInBytes)
    : _contents = Uint8List(sizeInBytes),
      current = _context.createDeviceBuffer(
        StorageMode.hostVisible,
        sizeInBytes,
      );

  final fg.GpuContext _context;
  final Uint8List _contents;
  fg.DeviceBuffer current;
  int _currentSince = _impellerSubmitted;
  final List<_SpareCopy> _spares = [];

  bool overwrite(ByteData bytes, int offset) {
    final length = bytes.lengthInBytes;
    final end = offset + length;
    if (offset < 0 || end > _contents.length) return false;
    if (length == 0) return true;
    if (_impellerSubmitted > _currentSince &&
        _impellerCompletedThrough < _impellerSubmitted) {
      _turn();
    }
    _contents.setRange(
      offset,
      end,
      bytes.buffer.asUint8List(bytes.offsetInBytes, length),
    );
    for (final spare in _spares) {
      spare.stale(offset, end);
    }
    return current.overwrite(bytes, destinationOffsetInBytes: offset);
  }

  void _turn() {
    final done = _impellerCompletedThrough;
    final retired = _SpareCopy(current, _impellerSubmitted);
    _SpareCopy? free;
    for (final spare in _spares) {
      if (spare.readThrough <= done) {
        free = spare;
        break;
      }
    }
    if (free == null) {
      current = _context.createDeviceBufferWithCopy(
        ByteData.sublistView(_contents),
      );
    } else {
      _spares.remove(free);
      final low = free.low;
      final high = free.high;
      if (high > low) {
        free.buffer
          ..overwrite(
            ByteData.sublistView(_contents, low, high),
            destinationOffsetInBytes: low,
          )
          ..flush(offsetInBytes: low, lengthInBytes: high - low);
      }
      current = free.buffer;
    }
    _spares.add(retired);
    _currentSince = _impellerSubmitted;
  }
}

// A copy of an ordered buffer the GPU may read through [readThrough], and the
// span of bytes written since it stopped being current.
final class _SpareCopy {
  _SpareCopy(this.buffer, this.readThrough);

  final fg.DeviceBuffer buffer;
  final int readThrough;
  int low = 0;
  int high = 0;

  void stale(int start, int end) {
    if (high == low) {
      low = start;
      high = end;
      return;
    }
    if (start < low) low = start;
    if (end > high) high = end;
  }
}

/// A per-frame bump allocator for transient data such as uniforms.
final class HostBuffer {
  HostBuffer._impeller(fg.HostBuffer this._impeller)
    : _backend = null,
      blockLengthInBytes = _impeller.blockLengthInBytes;
  HostBuffer._backend(
    GpuBackendHostBuffer this._backend,
    this.blockLengthInBytes,
  ) : _impeller = null;

  /// The block size [GpuContext.createHostBuffer] uses by default.
  static const int kDefaultBlockLengthInBytes =
      fg.HostBuffer.kDefaultBlockLengthInBytes;

  final fg.HostBuffer? _impeller;
  final GpuBackendHostBuffer? _backend;

  /// The size of each block the allocator draws from.
  final int blockLengthInBytes;

  /// How many frames of blocks the allocator rotates through.
  int get frameCount => _impeller?.frameCount ?? _backend!.frameCount;

  // The blocks Impeller allocates are its own buffers; each gets one wrapper,
  // and the last one is kept so a run of emplaces into a block does not look
  // it up again.
  static final Expando<DeviceBuffer> _blocks = Expando('HostBuffer block');
  static final Expando<DeviceBuffer> _backendBlocks = Expando(
    'HostBuffer block',
  );
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
    final range = _backend!.emplace(bytes);
    return BufferView(
      _backendBlocks[range.buffer] ??= DeviceBuffer._backend(range.buffer),
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
      _backend!.reset();
    }
  }
}
