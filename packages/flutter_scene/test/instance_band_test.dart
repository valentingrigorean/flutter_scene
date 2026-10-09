// InstanceBand: the per-row test a draw of an instanced mesh keeps rows by.
// The Dart test mirrors the vertex stage's (shaders/instance_band.glsl).

import 'dart:io';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  final eye = Vector3.zero();
  Matrix4 rowAt(double distance, {double scale = 1}) =>
      Matrix4.translation(Vector3(distance, 0, 0))
        ..scaleByDouble(scale, scale, scale, 1);

  test('a row draws inside the reach its radius states, past the near edge '
      'and up to the far one', () {
    final band = InstanceBand(radius: 2, nearReach: 4, farReach: 16);
    expect(band.holds(rowAt(8), eye, hash: 0.5), isFalse);
    expect(band.holds(rowAt(8.1), eye, hash: 0.5), isTrue);
    expect(band.holds(rowAt(32), eye, hash: 0.5), isTrue);
    expect(band.holds(rowAt(32.1), eye, hash: 0.5), isFalse);
    expect(band.holds(rowAt(20, scale: 3), eye, hash: 0.5), isFalse);
    expect(band.holds(rowAt(30, scale: 3), eye, hash: 0.5), isTrue);
  });

  test('a row draws inside the stated distances whatever its radius', () {
    final band = InstanceBand(nearDistance: 10, farDistance: 50);
    expect(band.holds(rowAt(10), eye, hash: 0.5), isFalse);
    expect(band.holds(rowAt(50, scale: 9), eye, hash: 0.5), isTrue);
    expect(band.holds(rowAt(50.5), eye, hash: 0.5), isFalse);
  });

  test('the reach reads the row center, the bound center under the row', () {
    final band = InstanceBand(center: Vector3(0, 3, 0), farReach: 5);
    expect(band.holds(rowAt(4), eye, hash: 0.5), isTrue);
    expect(band.holds(rowAt(4.1), eye, hash: 0.5), isFalse);
  });

  test('two bands that share an edge draw every row in exactly one of them, '
      'and the rows cross the edge over the margin', () {
    final finer = InstanceBand(farReach: 10, margin: 0.2);
    final coarser = InstanceBand(nearReach: 10, margin: 0.2);
    var finerAtEdge = 0;
    for (var row = 0; row < 200; row++) {
      final hash = InstanceBand.hashOf(Vector3(row * 0.37, row * 1.3, 2));
      expect(hash, inInclusiveRange(0, 1));
      for (final distance in [8.9, 9.5, 10.0, 10.5, 11.1]) {
        final record = rowAt(distance);
        expect(
          finer.holds(record, eye, hash: hash),
          isNot(coarser.holds(record, eye, hash: hash)),
        );
      }
      expect(finer.holds(rowAt(8.9), eye, hash: hash), isTrue);
      expect(finer.holds(rowAt(11.1), eye, hash: hash), isFalse);
      if (finer.holds(rowAt(10), eye, hash: hash)) finerAtEdge++;
    }
    expect(finerAtEdge, inInclusiveRange(60, 140));
  });

  test('keep draws the rows whose hash lies below it', () {
    final band = InstanceBand(keep: 0.25);
    expect(band.holds(rowAt(1), eye, hash: 0.2), isTrue);
    expect(band.holds(rowAt(1), eye, hash: 0.25), isFalse);
  });

  test('the hash spreads rows a unit apart evenly, near the node and far from '
      'it', () {
    for (final base in [0.0, 100.0, 8000.0, 40000.0]) {
      var kept = 0;
      final seen = <double>{};
      for (var row = 0; row < 2000; row++) {
        final hash = InstanceBand.hashOf(
          Vector3(base + row % 50, 0, base + row ~/ 50),
        );
        seen.add(hash);
        if (hash < 0.25) kept++;
      }
      expect(kept, inInclusiveRange(400, 600), reason: 'base $base');
      expect(seen.length, greaterThan(1500), reason: 'base $base');
    }
  });

  test('the vertex stage tests the band where a material draws the row: the '
      'record moved by the offset the material defines', () {
    for (final body in [
      'flutter_scene_unskinned_body.glsl',
      'flutter_scene_unskinned_depth_body.glsl',
    ]) {
      final source = File('shaders/$body').readAsStringSync();
      final hook = source.indexOf('#ifdef INSTANCE_BAND_OFFSET');
      final test = source.indexOf('InstanceBandHolds(band_record,');
      expect(hook, greaterThan(0), reason: body);
      expect(test, greaterThan(hook), reason: body);
      expect(
        source,
        contains('band_record[3].xyz += INSTANCE_BAND_OFFSET;'),
        reason: body,
      );
      expect(source, contains('#define band_record node_record'), reason: body);
      expect(source, isNot(contains('InstanceBandHolds(node_record,')));
    }
  });
}
