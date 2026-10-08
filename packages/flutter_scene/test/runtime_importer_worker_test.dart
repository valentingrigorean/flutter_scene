@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_scene/src/importer/constants.dart';
import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/runtime_importer/gltf_import_worker.dart';
import 'package:flutter_scene/src/runtime_importer/runtime_importer.dart';
import 'package:flutter_scene/src/runtime_importer/texture_builder.dart';
import 'package:test/test.dart';

/// Tests for the data half of the runtime importer (no GPU required): the
/// worker entry parses, decodes and packs a GLB into plain data, and counts
/// the geometry bytes the upload half creates from it.

void main() {
  group('prepareGlbImport', () {
    test('packs every primitive and keeps the encoded image bytes', () async {
      final result = prepareGlbImport(_triangleGlb());
      final prepared = result.unwrap();

      expect(prepared.doc.nodes, hasLength(2));
      final variants = prepared.primitives.single.single!;
      expect(variants.skinned, same(variants.unskinned));
      final packed = variants.unskinned;
      expect(packed.vertexCount, 3);
      expect(packed.vertexBytes.lengthInBytes, 3 * kUnskinnedPerVertexSize);
      expect(packed.indexCount, 3);
      expect(packed.indices32Bit, isFalse);
      expect(packed.indexBytes.lengthInBytes, 3 * 2);
      expect(Float32List.sublistView(packed.vertexBytes).sublist(0, 3), [
        0,
        0,
        0,
      ]);

      expect(
        await resolveGltfImageBytes(prepared.doc, prepared.bufferData, 0),
        _imageBytes,
      );
    });

    test('counts the vertex and index bytes of the buffers each node '
        'uploads', () {
      final prepared = prepareGlbImport(_triangleGlb()).unwrap();

      var vertexBytes = 0;
      var indexBytes = 0;
      for (final node in prepared.doc.nodes) {
        final packed = prepared.packedFor(node, 0)!;
        vertexBytes += packed.vertexBytes.lengthInBytes;
        indexBytes += packed.indexBytes.lengthInBytes;
      }
      expect(prepared.stats.vertexBytes, vertexBytes);
      expect(prepared.stats.indexBytes, indexBytes);
      // Two nodes draw the one mesh, and each uploads its own buffers.
      expect(prepared.stats.vertexBytes, 2 * 3 * kUnskinnedPerVertexSize);
      expect(prepared.stats.indexBytes, 2 * 3 * 2);
      expect(
        prepared.stats.geometryBytes,
        prepared.stats.vertexBytes + prepared.stats.indexBytes,
      );
    });

    test('decodes meshopt-compressed views before packing', () {
      final compressed = prepareGlbImport(
        _fixture('two_triangles_compressed.glb'),
      ).unwrap();
      final plain = prepareGlbImport(
        _fixture('two_triangles_plain.glb'),
      ).unwrap();

      expect(compressed.doc.bufferViews.any((v) => v.meshopt != null), isFalse);
      final packed = _packedOf(compressed);
      final reference = _packedOf(plain);
      expect(packed, isNotEmpty);
      expect(packed, hasLength(reference.length));
      var vertexBytes = 0;
      var indexBytes = 0;
      for (var i = 0; i < packed.length; i++) {
        expect(packed[i].vertexBytes, reference[i].vertexBytes);
        expect(packed[i].indexBytes, reference[i].indexBytes);
        vertexBytes += packed[i].vertexBytes.lengthInBytes;
        indexBytes += packed[i].indexBytes.lengthInBytes;
      }
      expect(compressed.stats.vertexBytes, vertexBytes);
      expect(compressed.stats.indexBytes, indexBytes);
    });

    test('answers the same data across an isolate boundary', () async {
      final local = prepareGlbImport(_triangleGlb()).unwrap();
      final result = await compute(prepareGlbImport, _triangleGlb());
      final remote = result.unwrap();

      expect(result.warnings.single.message, contains('EXT_not_a_thing'));
      expect(remote.bufferData, local.bufferData);
      final packed = remote.primitives.single.single!.unskinned;
      final reference = local.primitives.single.single!.unskinned;
      expect(packed.vertexBytes, reference.vertexBytes);
      expect(packed.indexBytes, reference.indexBytes);
      expect(remote.stats.vertexBytes, local.stats.vertexBytes);
      expect(remote.stats.indexBytes, local.stats.indexBytes);
    });

    test('answers a parse error as a value, after the warnings it raised', () {
      final garbage = prepareGlbImport(Uint8List.fromList([0, 1, 2]));
      expect(garbage.prepared, isNull);
      expect(garbage.warnings, isEmpty);
      expect(garbage.error, isA<FormatException>());
      expect(garbage.unwrap, throwsA(isA<FormatException>()));

      final external = prepareGlbImport(_triangleGlb(externalBuffer: true));
      expect(external.prepared, isNull);
      expect(external.warnings.single.message, contains('EXT_not_a_thing'));
      expect(external.error, isA<FormatException>());
    });
  });

  group('importGlb', () {
    test('rethrows the worker\'s FormatException on the calling '
        'isolate', () async {
      await expectLater(
        importGlb(Uint8List.fromList([0, 1, 2])),
        throwsA(isA<FormatException>()),
      );
    });

    test('replays the worker\'s warnings before it rethrows', () async {
      final events = <String>[];
      try {
        await importGlb(
          _triangleGlb(externalBuffer: true),
          onWarning: (warning) => events.add('warning: ${warning.message}'),
        );
      } on FormatException catch (e) {
        events.add('error: ${e.message}');
      }
      expect(events, hasLength(2));
      expect(events[0], contains('EXT_not_a_thing'));
      expect(events[1], contains('external buffer "triangle.bin"'));
    });
  });
}

/// The packed primitive each node of [prepared] uploads, in node order.
List<PackedPrimitive> _packedOf(PreparedGltfImport prepared) => [
  for (final node in prepared.doc.nodes)
    if (node.mesh case final mesh?)
      for (var i = 0; i < prepared.primitives[mesh].length; i++)
        ?prepared.packedFor(node, i),
];

final Uint8List _imageBytes = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  1,
  2,
  3,
  4,
]);

/// One indexed triangle drawn by two nodes, with an embedded image and an
/// `extensionsUsed` entry the parser does not know. [externalBuffer] names the
/// buffer by a file URI, which a GLB import cannot resolve.
Uint8List _triangleGlb({bool externalBuffer = false}) {
  final bin = BytesBuilder();
  bin.add(
    Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]).buffer.asUint8List(),
  );
  bin.add(Uint16List.fromList([0, 1, 2]).buffer.asUint8List());
  bin.add([0, 0]);
  bin.add(_imageBytes);
  final json = {
    'asset': {'version': '2.0'},
    'extensionsUsed': ['EXT_not_a_thing'],
    'scene': 0,
    'scenes': [
      {
        'nodes': [0, 1],
      },
    ],
    'nodes': [
      {'mesh': 0},
      {
        'mesh': 0,
        'translation': [2, 0, 0],
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            'indices': 1,
          },
        ],
      },
    ],
    'images': [
      {'bufferView': 2, 'mimeType': 'image/png'},
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'count': 3,
        'type': 'VEC3',
        'min': [0, 0, 0],
        'max': [1, 1, 0],
      },
      {'bufferView': 1, 'componentType': 5123, 'count': 3, 'type': 'SCALAR'},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
      {'buffer': 0, 'byteOffset': 36, 'byteLength': 6},
      {'buffer': 0, 'byteOffset': 44, 'byteLength': _imageBytes.length},
    ],
    'buffers': [
      {
        'byteLength': 44 + _imageBytes.length,
        if (externalBuffer) 'uri': 'triangle.bin',
      },
    ],
  };
  return _glb(utf8.encode(jsonEncode(json)), bin.takeBytes());
}

Uint8List _glb(List<int> json, List<int> bin) {
  List<int> padded(List<int> bytes, int fill) => [
    ...bytes,
    for (var at = bytes.length; at % 4 != 0; at++) fill,
  ];
  final jsonChunk = padded(json, 0x20);
  final binChunk = padded(bin, 0);
  final out = ByteData(28 + jsonChunk.length + binChunk.length);
  out
    ..setUint32(0, 0x46546C67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, out.lengthInBytes, Endian.little)
    ..setUint32(12, jsonChunk.length, Endian.little)
    ..setUint32(16, 0x4E4F534A, Endian.little);
  final bytes = out.buffer.asUint8List()..setAll(20, jsonChunk);
  out
    ..setUint32(20 + jsonChunk.length, binChunk.length, Endian.little)
    ..setUint32(24 + jsonChunk.length, 0x004E4942, Endian.little);
  bytes.setAll(28 + jsonChunk.length, binChunk);
  return bytes;
}

Uint8List _fixture(String name) {
  for (final candidate in [
    'test/fixtures/meshopt',
    'packages/flutter_scene/test/fixtures/meshopt',
  ]) {
    final file = File('$candidate/$name');
    if (file.existsSync()) return file.readAsBytesSync();
  }
  throw StateError(
    'Could not locate the meshopt fixture $name relative to '
    '${Directory.current.path}',
  );
}
