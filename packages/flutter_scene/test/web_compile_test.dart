@TestOn('browser')
library;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the renderer compiles against the web backend', () {
    expect(Scene.new, isA<Function>());
  });
}
