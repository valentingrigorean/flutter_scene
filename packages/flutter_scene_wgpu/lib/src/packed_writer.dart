import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A growable little-endian byte buffer in native memory, the input of the
/// packed descriptor and command stream calls.
class PackedWriter {
  /// Creates a writer with [initialCapacity] bytes reserved.
  PackedWriter([int initialCapacity = 4096]) {
    _reserve(initialCapacity);
  }

  Pointer<Uint8> _ptr = nullptr;
  late ByteData _view;
  int _capacity = 0;
  int _length = 0;

  /// The native address of the written bytes. Valid until the next write.
  Pointer<Uint8> get pointer => _ptr;

  /// The number of bytes written.
  int get length => _length;

  void _reserve(int capacity) {
    final next = malloc<Uint8>(capacity);
    if (_ptr != nullptr) {
      next.asTypedList(_length).setAll(0, _ptr.asTypedList(_length));
      malloc.free(_ptr);
    }
    _ptr = next;
    _capacity = capacity;
    _view = _ptr.asTypedList(capacity).buffer.asByteData(
      _ptr.asTypedList(capacity).offsetInBytes,
      capacity,
    );
  }

  void _ensure(int extra) {
    if (_length + extra <= _capacity) return;
    var capacity = _capacity * 2;
    while (capacity < _length + extra) {
      capacity *= 2;
    }
    _reserve(capacity);
  }

  /// Writes a 32-bit unsigned integer.
  void u32(int value) {
    _ensure(4);
    _view.setUint32(_length, value, Endian.little);
    _length += 4;
  }

  /// Writes a 32-bit signed integer.
  void i32(int value) {
    _ensure(4);
    _view.setInt32(_length, value, Endian.little);
    _length += 4;
  }

  /// Writes a 64-bit unsigned integer.
  void u64(int value) {
    _ensure(8);
    _view.setUint64(_length, value, Endian.little);
    _length += 8;
  }

  /// Writes a 32-bit float.
  void f32(double value) {
    _ensure(4);
    _view.setFloat32(_length, value, Endian.little);
    _length += 4;
  }

  /// Writes a boolean as a `u32` 0 or 1.
  void boolean(bool value) => u32(value ? 1 : 0);

  /// Writes a `u32` byte length, the UTF-8 bytes and zero padding to four.
  void string(String value) {
    final bytes = utf8.encode(value);
    u32(bytes.length);
    final padded = (bytes.length + 3) & ~3;
    _ensure(padded);
    final target = _ptr.asTypedList(_capacity);
    target.setAll(_length, bytes);
    target.fillRange(_length + bytes.length, _length + padded, 0);
    _length += padded;
  }

  /// Overwrites a `u32` already written at [offset].
  void patchU32(int offset, int value) =>
      _view.setUint32(offset, value, Endian.little);

  /// Forgets the written bytes, keeping the reserved memory.
  void reset() => _length = 0;

  /// Frees the native memory. The writer is unusable afterwards.
  void dispose() {
    malloc.free(_ptr);
    _ptr = nullptr;
    _capacity = 0;
    _length = 0;
  }
}
