// The skinned pose-union bake poses each skin once per sample time and bounds
// every primitive of every node the skin drives with that palette.

import 'dart:typed_data';

import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/importer/src/gltf/bounds_baker.dart';
import 'package:flutter_test/flutter_test.dart';

// A glTF document and its binary chunk, built accessor by accessor.
class _Doc {
  final BytesBuilder _bytes = BytesBuilder();
  final List<Map<String, Object?>> bufferViews = [];
  final List<Map<String, Object?>> accessors = [];

  int floats(List<double> values, String type) {
    final count = values.length ~/ _width[type]!;
    return _add(Float32List.fromList(values).buffer.asUint8List(), {
      'componentType': 5126,
      'count': count,
      'type': type,
      if (type == 'VEC3') ...{
        'min': [for (var c = 0; c < 3; c++) _extreme(values, c, -1)],
        'max': [for (var c = 0; c < 3; c++) _extreme(values, c, 1)],
      },
    });
  }

  int joints(List<int> values) => _add(
    Uint16List.fromList(values).buffer.asUint8List(),
    {'componentType': 5123, 'count': values.length ~/ 4, 'type': 'VEC4'},
  );

  int _add(Uint8List data, Map<String, Object?> accessor) {
    final offset = _bytes.length;
    _bytes.add(data);
    while (_bytes.length % 4 != 0) {
      _bytes.addByte(0);
    }
    bufferViews.add({
      'buffer': 0,
      'byteOffset': offset,
      'byteLength': data.length,
    });
    accessors.add({...accessor, 'bufferView': bufferViews.length - 1});
    return accessors.length - 1;
  }

  Uint8List get binary => _bytes.toBytes();

  static const _width = {'SCALAR': 1, 'VEC3': 3, 'VEC4': 4};

  static double _extreme(List<double> values, int component, int sign) {
    var best = values[component];
    for (var i = component; i < values.length; i += 3) {
      if (values[i] * sign > best * sign) best = values[i];
    }
    return best;
  }
}

void main() {
  // Two joints, the second a child of the first; a mesh of three skinned
  // triangles, two on the child joint and one on the root, drawn by two nodes
  // that share the skin. One animation moves the child along x over three
  // keyframes, another along y over two.
  // Without [skinned] the triangles carry no joints and weights.
  ({GltfDocument doc, Uint8List binary}) build({bool skinned = true}) {
    final d = _Doc();
    Map<String, Object?> triangle(double z, int joint) => {
      'attributes': {
        'POSITION': d.floats([0, 0, z, 1, 0, z, 0, 1, z], 'VEC3'),
        if (skinned) ...{
          'JOINTS_0': d.joints([
            for (var v = 0; v < 3; v++) ...[joint, 0, 0, 0],
          ]),
          'WEIGHTS_0': d.floats([
            for (var v = 0; v < 3; v++) ...[1, 0, 0, 0],
          ], 'VEC4'),
        },
      },
      'mode': 4,
    };

    final primitives = [triangle(0, 1), triangle(1, 0), triangle(-1, 1)];
    final xTimes = d.floats([0, 1, 2], 'SCALAR');
    final xValues = d.floats([0, 0, 0, 1, 0, 0, 2, 0, 0], 'VEC3');
    final yTimes = d.floats([0, 0.5], 'SCALAR');
    final yValues = d.floats([0, 0, 0, 0, 3, 0], 'VEC3');
    final json = <String, Object?>{
      'asset': {'version': '2.0'},
      'scene': 0,
      'scenes': [
        {
          'nodes': [0, 2, 3],
        },
      ],
      'nodes': [
        {
          'children': [1],
        },
        <String, Object?>{},
        {'mesh': 0, 'skin': 0},
        {'mesh': 0, 'skin': 0},
      ],
      'skins': [
        {
          'joints': [0, 1],
        },
      ],
      'meshes': [
        {'primitives': primitives},
      ],
      'animations': [
        {
          'samplers': [
            {'input': xTimes, 'output': xValues, 'interpolation': 'LINEAR'},
          ],
          'channels': [
            {
              'sampler': 0,
              'target': {'node': 1, 'path': 'translation'},
            },
          ],
        },
        {
          'samplers': [
            {'input': yTimes, 'output': yValues, 'interpolation': 'LINEAR'},
          ],
          'channels': [
            {
              'sampler': 0,
              'target': {'node': 1, 'path': 'translation'},
            },
          ],
        },
      ],
      'buffers': [
        {'byteLength': d.binary.length},
      ],
      'bufferViews': d.bufferViews,
      'accessors': d.accessors,
    };
    return (doc: parseGltfJson(json), binary: d.binary);
  }

  List<double>? box(AabbBounds? bounds) => bounds == null
      ? null
      : [
          bounds.minX,
          bounds.minY,
          bounds.minZ,
          bounds.maxX,
          bounds.maxY,
          bounds.maxZ,
        ];

  test('a bake poses a skin once per sample time, whatever primitives and '
      'nodes it drives', () {
    final (:doc, :binary) = build();
    debugPoseBoundsPaletteBuilds = 0;

    final unions = bakeSkinnedPoseUnionAabbs(doc, binary);

    // The rest pose, three keyframes of the first animation and two of the
    // second: six palettes for three primitives on two nodes.
    expect(debugPoseBoundsPaletteBuilds, 1 + 3 + 2);
    expect(unions.keys, [2, 3]);
    for (final node in [2, 3]) {
      expect(
        [for (final union in unions[node]!) box(union)],
        [
          [0, 0, 0, 3, 4, 0],
          [0, 0, 1, 1, 1, 1],
          [0, 0, -1, 3, 4, -1],
        ],
        reason: 'node $node',
      );
    }
  });

  test('a mesh with no skinned primitive poses no skin', () {
    final (:doc, :binary) = build(skinned: false);
    debugPoseBoundsPaletteBuilds = 0;

    final unions = bakeSkinnedPoseUnionAabbs(doc, binary);

    expect(debugPoseBoundsPaletteBuilds, 0);
    expect(unions[2], [null, null, null]);
  });
}
