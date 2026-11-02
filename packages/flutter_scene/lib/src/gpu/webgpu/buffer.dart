part of 'webgpu_backend.dart';

int _align4(int value) => (value + 3) & ~3;

/// Every role a buffer can play in a draw or a dispatch, since a flutter_gpu
/// DeviceBuffer is untyped and the engine binds one range as vertices and
/// another as indices, uniforms, storage or indirect arguments.
const int _bufferUsage =
    GPUBufferUsage.vertex |
    GPUBufferUsage.index |
    GPUBufferUsage.uniform |
    GPUBufferUsage.storage |
    GPUBufferUsage.indirect |
    GPUBufferUsage.copyDst |
    GPUBufferUsage.copySrc;

/// Destroys a buffer's GPU allocation once its Dart wrapper is collected.
/// WebGPU defers the destruction until submitted work using it completes.
final Finalizer<GPUBuffer> _bufferFinalizer = Finalizer(
  (buffer) => buffer.destroy(),
);

/// A [DeviceBuffer] over a `GPUBuffer`, which keeps no CPU copy of its
/// contents.
///
/// `writeBuffer` takes only 4-byte-aligned offsets and sizes and nothing reads
/// back synchronously. A write sends its whole words through the queue, and
/// [_WordPatcher] merges the bytes of a word it covers only in part into that
/// word on the GPU. A short final write at the end of the buffer pads into the
/// tail of the allocation instead.
final class _WebGpuDeviceBuffer extends DeviceBuffer {
  _WebGpuDeviceBuffer(this._context, this.storageMode, this.sizeInBytes)
    : buffer = _context.device.device.createBuffer(
        GPUBufferDescriptor(
          size: _align4(sizeInBytes < 4 ? 4 : sizeInBytes),
          usage: _bufferUsage,
        ),
      ) {
    _bufferFinalizer.attach(this, buffer, detach: this);
  }

  /// A host-visible buffer for [writeGeometryData].
  _WebGpuDeviceBuffer.geometry(_WebGpuContext context, int sizeInBytes)
    : this(context, StorageMode.hostVisible, sizeInBytes);

  final _WebGpuContext _context;
  final GPUBuffer buffer;

  @override
  final StorageMode storageMode;

  @override
  final int sizeInBytes;

  @override
  bool get isValid => !_released;

  bool _released = false;

  // How many names of the buffer open command buffers hold, and whether a
  // release waits for the last of them to be submitted, since a submit that
  // reads a destroyed buffer fails.
  int _named = 0;
  bool _releaseWaits = false;

  void _release() {
    if (_released) return;
    _released = true;
    if (_named > 0) {
      _releaseWaits = true;
      return;
    }
    _destroy();
  }

  void _destroy() {
    _bufferFinalizer.detach(this);
    buffer.destroy();
  }

  void _unname() {
    if (--_named > 0 || !_releaseWaits) return;
    _releaseWaits = false;
    _destroy();
  }

  @override
  bool overwrite(ByteData sourceBytes, {int destinationOffsetInBytes = 0}) {
    if (storageMode != StorageMode.hostVisible) {
      throw Exception(
        'DeviceBuffer.overwrite can only be used with DeviceBuffers that are '
        'host visible',
      );
    }
    return _write(sourceBytes, destinationOffsetInBytes);
  }

  bool _write(TypedData source, int offset) {
    if (offset < 0) {
      throw Exception('destinationOffsetInBytes must be positive');
    }
    final length = source.lengthInBytes;
    if (offset + length > sizeInBytes) return false;
    if (length == 0) return true;
    final queue = _context.device.device.queue;
    final end = offset + length;
    if (offset & 3 == 0 && length & 3 == 0) {
      queue.writeBuffer(buffer, offset, _jsViewOf(source));
      return true;
    }
    final bytes = source.buffer.asUint8List(source.offsetInBytes, length);
    if (offset & 3 == 0 && end == sizeInBytes) {
      final padded = Uint8List(_align4(length))..setRange(0, length, bytes);
      queue.writeBuffer(buffer, offset, padded.toJS);
      return true;
    }
    final whole = _align4(offset);
    final wholeEnd = end & ~3;
    if (wholeEnd > whole) {
      queue.writeBuffer(
        buffer,
        whole,
        Uint8List.sublistView(bytes, whole - offset, wholeEnd - offset).toJS,
      );
    }
    final words = {
      if (offset & 3 != 0) offset & ~3,
      if (end & 3 != 0) wholeEnd,
    };
    _context.wordPatcher.patch(this, [
      for (final word in words) _wordPatchOf(word, bytes, offset),
    ]);
    return true;
  }

  /// Hands [source] to JS without a copy when its static type matches its
  /// store, which is the cheap case under dart2wasm (see the WebGL2 buffer's
  /// `_jsViewOf` for the measurements).
  static JSObject _jsViewOf(TypedData source) => switch (source) {
    Float32List() => source.toJS,
    Uint16List() => source.toJS,
    Uint32List() => source.toJS,
    Uint8List() => source.toJS,
    _ => Uint8List.fromList(
      source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
    ).toJS,
  };

  /// Host writes reach the GPU through the queue; there is nothing to flush.
  @override
  void flush({int offsetInBytes = 0, int lengthInBytes = -1}) {}
}

/// The bytes of one write that fall in the 4-byte word at [word], a byte
/// offset: [mask] has the bits of those bytes set and [value] holds them.
typedef _WordPatch = ({int word, int mask, int value});

/// The patch of the word at [word] for [bytes] written at [offset].
_WordPatch _wordPatchOf(int word, Uint8List bytes, int offset) {
  var mask = 0;
  var value = 0;
  for (var byte = 0; byte < 4; byte++) {
    final at = word + byte - offset;
    if (at < 0 || at >= bytes.length) continue;
    mask += 0xff << (8 * byte);
    value += bytes[at] << (8 * byte);
  }
  return (word: word, mask: mask, value: value);
}

/// Merges the bytes a write covers in part of a word into that word on the
/// GPU, one compute invocation per word, in queue order with every other
/// write, so a buffer needs no CPU copy to fill the rest of the word.
final class _WordPatcher {
  _WordPatcher(this._device);

  final GPUDevice _device;

  static const String _source = r"""
@group(0) @binding(0) var<storage, read_write> words: array<u32>;
@group(0) @binding(1) var<uniform> edit: vec4u;

@compute @workgroup_size(1)
fn main() {
  words[edit.x] = (words[edit.x] & ~edit.y) | (edit.z & edit.y);
}
""";

  /// The span of the target bound around a patched word: a storage binding
  /// offset is a multiple of 256 on every device, and so is this span.
  static const int _span = 256;

  late final GPUBindGroupLayout _layout = _device.createBindGroupLayout(
    _obj({
      'entries': [
        {
          'binding': 0,
          'visibility': GPUShaderStage.compute,
          'buffer': {'type': 'storage'},
        },
        {
          'binding': 1,
          'visibility': GPUShaderStage.compute,
          'buffer': {'type': 'uniform'},
        },
      ],
    }),
  );

  late final GPUComputePipeline _pipeline = _device.createComputePipeline(
    _obj({
      'layout': _device.createPipelineLayout(
        _obj({
          'bindGroupLayouts': [_layout],
        }),
      ),
      'compute': {
        'module': _device.createShaderModule(
          _obj({'code': _source, 'label': 'flutter_scene word patch'}),
        ),
        'entryPoint': 'main',
      },
    }),
  );

  /// One patch of a write's first word and one of its last, each at its own
  /// uniform offset.
  late final GPUBuffer _patches = _device.createBuffer(
    GPUBufferDescriptor(
      size: 2 * _span,
      usage: GPUBufferUsage.uniform | GPUBufferUsage.copyDst,
    ),
  );

  final JSUint32Array _values = JSUint32Array.withLength(2 * _span ~/ 4);

  void patch(_WebGpuDeviceBuffer target, List<_WordPatch> patches) {
    final values = _values.toDart;
    final encoder = _device.createCommandEncoder();
    final pass = encoder.beginComputePass()..setPipeline(_pipeline);
    for (final (index, patch) in patches.indexed) {
      final base = patch.word & ~(_span - 1);
      final size = target.buffer.size - base;
      values
        ..[index * _span ~/ 4] = (patch.word - base) >> 2
        ..[index * _span ~/ 4 + 1] = patch.mask
        ..[index * _span ~/ 4 + 2] = patch.value;
      pass
        ..setBindGroup(
          0,
          _device.createBindGroup(
            _obj({
              'layout': _layout,
              'entries': [
                {
                  'binding': 0,
                  'resource': {
                    'buffer': target.buffer,
                    'offset': base,
                    'size': size < _span ? size : _span,
                  },
                },
                {
                  'binding': 1,
                  'resource': {
                    'buffer': _patches,
                    'offset': index * _span,
                    'size': 16,
                  },
                },
              ],
            }),
          ),
        )
        ..dispatchWorkgroups(1);
    }
    pass.end();
    _device.queue.writeBuffer(_patches, 0, _values);
    _device.queue.submit([encoder.finish()].toJS);
  }
}
