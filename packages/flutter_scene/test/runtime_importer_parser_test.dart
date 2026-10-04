@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/runtime_importer/skin_builder.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math.dart';

/// Tests for the pure-data layer of the runtime importer (no GPU required).
///
/// Loads .glb files from the workspace's examples/assets_src/ via dart:io
/// and validates that the parser extracts the expected structure.

void main() {
  group('parseGlb', () {
    test('rejects too-short input', () {
      expect(
        () => parseGlb(_bytes([0, 1, 2])),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-glTF magic', () {
      // 12 bytes that don't start with 'glTF'.
      final bytes = _bytes([
        0x00,
        0x00,
        0x00,
        0x00,
        0x02,
        0x00,
        0x00,
        0x00,
        0x0c,
        0x00,
        0x00,
        0x00,
      ]);
      expect(() => parseGlb(bytes), throwsA(isA<FormatException>()));
    });
  });

  group('two_triangles.glb', () {
    late GlbContents container;
    late GltfDocument doc;

    setUpAll(() {
      final bytes = File('${_assetsDir()}/two_triangles.glb').readAsBytesSync();
      container = parseGlb(bytes);
      doc = parseGltfJson(container.json);
    });

    test('container has JSON and a non-empty BIN chunk', () {
      expect(container.json.isNotEmpty, isTrue);
      expect(container.binaryChunk.isNotEmpty, isTrue);
    });

    test('document has at least one scene and node', () {
      expect(doc.scenes, isNotEmpty);
      expect(doc.nodes, isNotEmpty);
      expect(doc.meshes, isNotEmpty);
    });

    test('mesh primitive has POSITION attribute', () {
      final mesh = doc.meshes.first;
      expect(mesh.primitives, isNotEmpty);
      expect(mesh.primitives.first.attributes.containsKey('POSITION'), isTrue);
    });

    test(
      'POSITION accessor reads as Float32List with the right cardinality',
      () {
        final primitive = doc.meshes.first.primitives.first;
        final accessor = doc.accessors[primitive.attributes['POSITION']!];
        final positions = readAccessorAsFloat32(
          accessor,
          doc.bufferViews,
          container.binaryChunk,
        );
        expect(accessor.type, GltfAccessorType.vec3);
        expect(positions.length, accessor.count * 3);
        // No NaN or infinity in well-formed data.
        for (final v in positions) {
          expect(v.isFinite, isTrue);
        }
      },
    );

    test(
      'indices accessor (if present) reads as Uint32List with cardinality count',
      () {
        final primitive = doc.meshes.first.primitives.first;
        if (primitive.indices == null) return;
        final accessor = doc.accessors[primitive.indices!];
        final indices = readAccessorAsUint32(
          accessor,
          doc.bufferViews,
          container.binaryChunk,
        );
        expect(accessor.type, GltfAccessorType.scalar);
        expect(indices.length, accessor.count);
      },
    );
  });

  group('all bundled .glb files parse without errors', () {
    for (final fileName in [
      'two_triangles.glb',
      'flutter_logo_baked.glb',
      'fcar.glb',
      'dash.glb',
    ]) {
      test(fileName, () {
        final path = '${_assetsDir()}/$fileName';
        if (!File(path).existsSync()) return; // skip if not present
        final bytes = File(path).readAsBytesSync();
        final container = parseGlb(bytes);
        final doc = parseGltfJson(container.json);
        expect(doc.nodes, isNotEmpty);
      });
    }
  });

  test('texture parses a KHR_texture_basisu source', () {
    final doc = parseGltfJson(
      jsonDecode('''
{
  "asset": {"version": "2.0"},
  "textures": [
    {"source": 0, "extensions": {"KHR_texture_basisu": {"source": 1}}},
    {"source": 0}
  ],
  "images": [{"uri": "a.png"}, {"uri": "a.ktx2", "mimeType": "image/ktx2"}]
}
''')
          as Map<String, Object?>,
    );
    expect(doc.textures[0].source, 0);
    expect(doc.textures[0].basisuSource, 1);
    expect(doc.textures[1].basisuSource, isNull);
    expect(doc.images[1].mimeType, 'image/ktx2');
  });

  test('primitive packing preserves TEXCOORD_0 and TEXCOORD_1', () {
    final source = Float32List.fromList([
      // Positions.
      0, 0, 0, 0, 1, 0, 1, 0, 0,
      // Normals.
      0, 0, 1, 0, 0, 1, 0, 0, 1,
      // UV0.
      0, 0, 0.5, 0.5, 1, 1,
      // UV1.
      0.25, 0.75, 0.5, 0.25, 0.75, 0.5,
      // Tangents.
      1, 0, 0, 1, 0, 1, 0, -1, -1, 0, 0, 1,
    ]);
    final views = <GltfBufferView>[
      GltfBufferView(buffer: 0, byteOffset: 0, byteLength: 36),
      GltfBufferView(buffer: 0, byteOffset: 36, byteLength: 36),
      GltfBufferView(buffer: 0, byteOffset: 72, byteLength: 24),
      GltfBufferView(buffer: 0, byteOffset: 96, byteLength: 24),
      GltfBufferView(buffer: 0, byteOffset: 120, byteLength: 48),
    ];
    GltfAccessor accessor(int view, GltfAccessorType type) => GltfAccessor(
      componentType: GltfComponentType.float,
      count: 3,
      type: type,
      bufferView: view,
    );
    final packed = packGltfPrimitive(
      primitive: GltfMeshPrimitive(
        attributes: const {
          'POSITION': 0,
          'NORMAL': 1,
          'TEXCOORD_0': 2,
          'TEXCOORD_1': 3,
          'TANGENT': 4,
        },
      ),
      accessors: [
        accessor(0, GltfAccessorType.vec3),
        accessor(1, GltfAccessorType.vec3),
        accessor(2, GltfAccessorType.vec2),
        accessor(3, GltfAccessorType.vec2),
        accessor(4, GltfAccessorType.vec4),
      ],
      bufferViews: views,
      bufferData: source.buffer.asUint8List(),
      coordinatePolicy: GltfCoordinatePolicy.runtimeBoundary,
    );

    final vertices = Float32List.sublistView(packed.vertexBytes);
    expect(vertices.sublist(6, 10), [0, 0, 0.25, 0.75]);
    expect(vertices.sublist(18 + 6, 18 + 10), [0.5, 0.5, 0.5, 0.25]);
    expect(vertices.sublist(36 + 6, 36 + 10), [1, 1, 0.75, 0.5]);
    expect(vertices.sublist(14, 18), [1, 0, 0, 1]);
    expect(vertices.sublist(18 + 14, 18 + 18), [0, 1, 0, -1]);
    expect(vertices.sublist(36 + 14, 36 + 18), [-1, 0, 0, 1]);
  });

  group('a skinned import', () {
    late SkinnedGeometry geometry;

    setUpAll(() async {
      final root = await Node.fromGlbBytes(_skinnedGlb());
      geometry =
          root.children.single.children.first.mesh!.primitives.single.geometry
              as SkinnedGeometry;
    });

    test('keeps the joints and weights of each vertex', () {
      final data = geometry.cpuMeshData;
      final floats = Float32List.sublistView(data.vertices!);
      const stride = 26;
      expect(data.vertexCount, 3);
      expect(floats.sublist(18, 26), [0, 0, 0, 0, 1, 0, 0, 0]);
      expect(floats.sublist(stride + 18, stride + 26), [
        0,
        1,
        0,
        0,
        0.75,
        0.25,
        0,
        0,
      ]);
      expect(floats.sublist(2 * stride + 18, 2 * stride + 26), [
        1,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
      ]);
    });

    test('bounds every keyframe pose of its joints, in the space of its '
        'node, whose transform the skin ignores', () {
      final bounds = geometry.localBounds;
      expect(bounds, isNotNull);
      expect(bounds!.min.x, -10);
      expect(bounds.min.y, 0);
      expect(bounds.max.x, -9);
      expect(bounds.max.y, 6);
      expect(bounds.min.z, 0);
      expect(bounds.max.z, 0);
      expect(geometry.localBoundingSphere, isNotNull);
    });
  }, skip: _gpuAvailable() ? null : 'Requires a GPU device.');

  group('skinned pose bounds', () {
    Aabb3 boundsOf(Uint8List glb) {
      final container = parseGlb(glb);
      return skinnedPoseBounds(
        parseGltfJson(container.json),
        container.binaryChunk,
      )[0]!.single!;
    }

    test('cover the poses of every clip, not only the last one', () {
      final bounds = boundsOf(_skinnedGlb(clips: [5, 0]));
      expect(bounds.min.y, 0);
      expect(bounds.max.y, 6);
    });

    test('cover the rest pose a model shows while no clip plays', () {
      final bounds = boundsOf(_skinnedGlb(clips: [0], restY: 3));
      expect(bounds.min.y, 0);
      expect(bounds.max.y, 4);
    });
  });
}

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

/// A triangle skinned to two joints: the first two vertices follow the root
/// joint, the third its child, which rests [restY] up and which each of
/// [clips] moves from 0 to its value up at 1 s. Both the skinned node and the
/// skeleton hang under a node 2 along z, and the skinned node sits 10 along x,
/// which glTF ignores for a skinned mesh.
Uint8List _skinnedGlb({List<double> clips = const [5], double restY = 0}) {
  final bin = BytesBuilder();
  void floats(List<double> values) =>
      bin.add(Float32List.fromList(values).buffer.asUint8List());
  floats([0, 0, 0, 1, 0, 0, 0, 1, 0]);
  floats([0, 0, 1, 0, 0, 1, 0, 0, 1]);
  bin.add([0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0]);
  floats([1, 0, 0, 0, 0.75, 0.25, 0, 0, 1, 0, 0, 0]);
  floats([0, 1]);
  for (final clip in clips) {
    floats([0, 0, 0, 0, clip, 0]);
  }
  final json = {
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {
        'nodes': [3],
      },
    ],
    'nodes': [
      {
        'mesh': 0,
        'skin': 0,
        'translation': [10, 0, 0],
      },
      {
        'children': [2],
      },
      {
        'translation': [0, restY, 0],
      },
      {
        'translation': [0, 0, 2],
        'children': [0, 1],
      },
    ],
    'skins': [
      {
        'joints': [1, 2],
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {
              'POSITION': 0,
              'NORMAL': 1,
              'JOINTS_0': 2,
              'WEIGHTS_0': 3,
            },
          },
        ],
      },
    ],
    'animations': [
      for (var clip = 0; clip < clips.length; clip++)
        {
          'channels': [
            {
              'sampler': 0,
              'target': {'node': 2, 'path': 'translation'},
            },
          ],
          'samplers': [
            {'input': 4, 'output': 5 + clip},
          ],
        },
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
      {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
      {'bufferView': 2, 'componentType': 5121, 'count': 3, 'type': 'VEC4'},
      {'bufferView': 3, 'componentType': 5126, 'count': 3, 'type': 'VEC4'},
      {
        'bufferView': 4,
        'componentType': 5126,
        'count': 2,
        'type': 'SCALAR',
        'min': [0],
        'max': [1],
      },
      for (var clip = 0; clip < clips.length; clip++)
        {
          'bufferView': 5 + clip,
          'componentType': 5126,
          'count': 2,
          'type': 'VEC3',
        },
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
      {'buffer': 0, 'byteOffset': 36, 'byteLength': 36},
      {'buffer': 0, 'byteOffset': 72, 'byteLength': 12},
      {'buffer': 0, 'byteOffset': 84, 'byteLength': 48},
      {'buffer': 0, 'byteOffset': 132, 'byteLength': 8},
      for (var clip = 0; clip < clips.length; clip++)
        {'buffer': 0, 'byteOffset': 140 + 24 * clip, 'byteLength': 24},
    ],
    'buffers': [
      {'byteLength': 140 + 24 * clips.length},
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

/// Locates the examples/assets_src/ directory in the workspace, regardless of
/// whether tests run from the workspace root or the package directory.
String _assetsDir() {
  for (final candidate in [
    'examples/assets_src',
    '../../examples/assets_src',
    '../../../examples/assets_src',
  ]) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError(
    'Could not locate examples/assets_src/ relative to ${Directory.current.path}',
  );
}

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);
