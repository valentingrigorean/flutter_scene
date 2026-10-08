// The device writes of a mesh that holds instance records, read through a
// device that records them, so the test needs no Flutter GPU context.

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/instance_packing.dart'
    show beginRetainedInstanceFrame;
import 'package:flutter_scene/src/render/instance_record_ring.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_scene/src/render/shared_instance_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

class _StubGeometry extends Geometry {
  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Matrix4 modelTransform,
    Matrix4 cameraTransform,
    Vector3 cameraPosition, {
    gpu.Shader? shaderOverride,
    double depthBias = 0.0,
  }) => throw UnsupportedError('Stub geometry is not renderable');
}

class _StubMaterial extends Material {
  @override
  void bind(
    gpu.RenderPass pass,
    TransientWriter transientsBuffer,
    Lighting lighting,
  ) => throw UnsupportedError('Stub material is not renderable');
}

final class _Buffer implements InstanceRecordBuffer {
  _Buffer(this.device, int sizeInBytes) : bytes = Uint8List(sizeInBytes);

  final _Device device;
  final Uint8List bytes;

  @override
  void write(ByteData records, int offsetInBytes) {
    bytes.setRange(
      offsetInBytes,
      offsetInBytes + records.lengthInBytes,
      Uint8List.sublistView(records),
    );
    device.writes.add((
      buffer: device.buffers.indexOf(this),
      offset: offsetInBytes,
      bytes: records.lengthInBytes,
    ));
  }
}

final class _Device implements InstanceRecordDevice {
  final List<_Buffer> buffers = [];
  final List<({int buffer, int offset, int bytes})> writes = [];

  @override
  InstanceRecordBuffer create(int sizeInBytes) {
    final buffer = _Buffer(this, sizeInBytes);
    buffers.add(buffer);
    return buffer;
  }
}

const int _rows = 4096;
const int _recordFloats = 20;
const int _recordBytes = _recordFloats * Float32List.bytesPerElement;

Float32List _records(int first, int count, {double tint = 1}) {
  final records = Float32List(count * _recordFloats);
  for (var row = 0; row < count; row++) {
    final at = row * _recordFloats;
    records
      ..[at] = 1
      ..[at + 5] = 1
      ..[at + 10] = 1
      ..[at + 12] = (first + row) * 2.0
      ..[at + 15] = 1
      ..fillRange(at + 16, at + 20, tint);
  }
  return records;
}

Float32List _bounds(int first, int count) {
  final bounds = Float32List(count * 6);
  for (var row = 0; row < count; row++) {
    final x = (first + row) * 2.0;
    bounds.setAll(row * 6, [x - 0.5, -0.5, -0.5, x + 0.5, 0.5, 0.5]);
  }
  return bounds;
}

void main() {
  late _Device device;
  late InstancedMesh mesh;

  int uploaded(void Function() body) {
    final before = activeRenderCounters.instanceBytesUploaded;
    body();
    return activeRenderCounters.instanceBytesUploaded - before;
  }

  // One frame: the passes bind the records, then the frame is submitted and
  // stays on the GPU until the test completes its id.
  int frame() {
    beginRetainedInstanceFrame();
    sharedInstanceRowsOf(mesh);
    return rendererSubmissions.record();
  }

  setUp(() {
    debugInstanceRecordDevice = device = _Device();
    mesh = InstancedMesh.records(
      geometry: _StubGeometry(),
      material: _StubMaterial(),
    )..setInstanceRecords(0, _records(0, _rows), bounds: _bounds(0, _rows));
  });

  tearDown(() {
    debugInstanceRecordDevice = null;
    for (
      var id = rendererSubmissions.completedThrough + 1;
      id <= rendererSubmissions.latestSubmission;
      id++
    ) {
      rendererSubmissions.complete(id);
    }
  });

  test('a mesh of many rows in which one row changes while a frame is in '
      'flight uploads one record', () {
    late int first;
    expect(uploaded(() => first = frame()), _rows * _recordBytes);
    expect(device.writes, [
      (buffer: 0, offset: 0, bytes: _rows * _recordBytes),
    ]);

    // The first frame is still on the GPU and drew row 7, so the changed
    // record goes to a second buffer, which starts with every row.
    mesh.setInstanceRecords(
      7,
      _records(7, 1, tint: 0.5),
      bounds: _bounds(7, 1),
    );
    late int second;
    expect(uploaded(() => second = frame()), _recordBytes);
    expect(device.buffers, hasLength(2));

    // From here on a change in flight writes its record and what the free
    // buffer missed, never the store.
    rendererSubmissions.complete(first);
    device.writes.clear();
    mesh.setInstanceRecords(
      9,
      _records(9, 1, tint: 0.25),
      bounds: _bounds(9, 1),
    );
    final replayedBefore = activeRenderCounters.instanceBytesReplayed;
    expect(uploaded(frame), _recordBytes);
    expect(device.writes, [
      (buffer: 0, offset: 7 * _recordBytes, bytes: _recordBytes),
      (buffer: 0, offset: 9 * _recordBytes, bytes: _recordBytes),
    ]);
    expect(
      activeRenderCounters.instanceBytesReplayed - replayedBefore,
      _recordBytes,
    );
    expect(device.buffers, hasLength(2));
    expect(
      device.buffers[0].bytes,
      Uint8List.sublistView(mesh.recordStoreBytes),
    );

    rendererSubmissions.complete(second);
    device.writes.clear();
    expect(uploaded(frame), 0);
    expect(device.writes, isEmpty);
  });

  test('a row appended while a frame is in flight is written into the bound '
      'buffer, which no frame reads there', () {
    mesh.truncateInstanceRecords(_rows - 1);
    frame();
    device.writes.clear();
    mesh.setInstanceRecords(
      _rows - 1,
      _records(_rows - 1, 1),
      bounds: _bounds(_rows - 1, 1),
    );
    expect(uploaded(frame), _recordBytes);
    expect(device.writes, [
      (buffer: 0, offset: (_rows - 1) * _recordBytes, bytes: _recordBytes),
    ]);
    expect(device.buffers, hasLength(1));
  });

  test('rows that change in more scattered ranges than a buffer keeps apart '
      'count as the changed rows alone', () {
    frame();
    for (var row = 0; row < _rows; row += 4) {
      mesh.setInstanceRecords(
        row,
        _records(row, 1, tint: 0.5),
        bounds: _bounds(row, 1),
      );
    }
    expect(uploaded(frame), _rows ~/ 4 * _recordBytes);
  });

  test('a pad widens the bounds of a mesh that holds records on every '
      'side', () {
    mesh.recordBoundsPad = 3;
    expect(mesh.aggregateBounds!.min, Vector3(-3.5, -3.5, -3.5));
    expect(mesh.aggregateBounds!.max.x, (_rows - 1) * 2.0 + 3.5);
    mesh.recordBoundsPad = 0;
    expect(mesh.aggregateBounds!.min, Vector3(-0.5, -0.5, -0.5));
  });

  test('the bounds of a mesh that holds records are the hull of the bounds '
      'its rows state', () {
    expect(mesh.aggregateBounds!.min, Vector3(-0.5, -0.5, -0.5));
    expect(mesh.aggregateBounds!.max.x, (_rows - 1) * 2.0 + 0.5);
    mesh.truncateInstanceRecords(10);
    expect(mesh.aggregateBounds!.max.x, 18.5);
    mesh.setInstanceRecords(0, _records(3, 1), bounds: _bounds(3, 1));
    expect(mesh.aggregateBounds!.min.x, 1.5);
    expect(mesh.instanceCount, 10);
    expect(mesh.instanceTransformAt(1).getTranslation().x, 2);
    expect(() => mesh.addInstance(Matrix4.identity()), throwsStateError);
  });
}
