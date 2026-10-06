// impellerc inlines every shader function, and SPIRV-Cross writes a function
// that returns before its end as a one pass loop (`do { ... } while (false)`).
// ANGLE marks that loop `[loop]` for Direct3D, where a derivative or an
// implicit-level sample inside it reads zero and level 0. So no engine shader
// function that returns early may take a derivative or an implicit-level
// sample, directly or through a function it calls. The rule covers the
// shaders a lit material includes; a post-process pass reads its own inputs.

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _shaderDirectory() {
  for (final path in const ['shaders', 'packages/flutter_scene/shaders']) {
    final directory = Directory(path);
    if (directory.existsSync()) return directory;
  }
  throw const FileSystemException('Could not find the engine shaders');
}

final _comment = RegExp(r'//[^\n]*|/\*[\s\S]*?\*/');
final _function = RegExp(
  r'\b(?:(?:lowp|mediump|highp)\s+)?[A-Za-z_]\w*\s+([A-Za-z_]\w*)\s*'
  r'\([^(){};]*\)\s*\{',
);
final _gradientMacro = RegExp(
  r'^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)\(([^\n\\]|\\\n)*',
  multiLine: true,
);
final _directive = RegExp(r'^\s*#\s*(if\w*|elif|else|endif)\b');
final _include = RegExp(r'^\s*#\s*include\s*<([^>]+)>', multiLine: true);
final _litRoot = RegExp(
  r'^(flutter_scene_standard\w*\.frag|material_\w+\.glsl|'
  r'filtered_scene_color\.glsl)$',
);
final _call = RegExp(r'\b([A-Za-z_]\w*)\s*\(');
const _controlWords = {'if', 'for', 'while', 'switch', 'return'};
final _return = RegExp(r'\breturn\b');
final _finalReturn = RegExp(r'\breturn\b[^;{}]*;\s*$');
final _gradient = RegExp(
  r'\b(?:texture(?!\w*(?:Lod|Grad|Size|Query|Gather|Samples))\w*|dFd[xy]\w*|'
  r'fwidth\w*)\s*\(',
);

String _body(String text, int open) {
  var depth = 0;
  for (var at = open; at < text.length; at++) {
    if (text[at] == '{') depth++;
    if (text[at] == '}' && --depth == 0) return text.substring(open + 1, at);
  }
  throw StateError('a function body does not close');
}

bool _returnsEarlyIn(String body) =>
    _return.hasMatch(body) &&
    (_return.allMatches(body).length > 1 || !_finalReturn.hasMatch(body));

/// Whether [body] returns before its end when every preprocessor conditional
/// keeps its first branch, or when every one keeps its last.
bool _returnsEarly(String body) =>
    _returnsEarlyIn(_branch(body, last: false)) ||
    _returnsEarlyIn(_branch(body, last: true));

String _branch(String body, {required bool last}) {
  final kept = <String>[];
  final stack = <bool>[];
  for (final line in body.split('\n')) {
    final directive = _directive.firstMatch(line)?.group(1);
    if (directive == null) {
      if (!stack.contains(false)) kept.add(line);
    } else if (directive.startsWith('if')) {
      stack.add(!last);
    } else if (directive == 'endif') {
      stack.removeLast();
    } else {
      stack[stack.length - 1] = last;
    }
  }
  return kept.join('\n');
}

/// The functions of [sources] that return before their end and take a
/// derivative or an implicit-level sample, directly or through a function or
/// macro they call, as `file: name`.
List<String> gradientsUnderEarlyReturn(Map<String, String> sources) {
  final bodies = <(String, String, String)>[];
  final reaching = <String>{};
  for (final MapEntry(key: file, value: text) in sources.entries) {
    final source = text.replaceAll(_comment, '');
    for (final match in _gradientMacro.allMatches(source)) {
      if (_gradient.hasMatch(match.group(0)!)) reaching.add(match.group(1)!);
    }
    for (final match in _function.allMatches(source)) {
      final name = match.group(1)!;
      if (_controlWords.contains(name)) continue;
      bodies.add((file, name, _body(source, match.end - 1)));
    }
  }
  for (var grown = true; grown;) {
    grown = false;
    for (final (_, name, body) in bodies) {
      if (reaching.contains(name)) continue;
      if (_gradient.hasMatch(body) ||
          _call.allMatches(body).any((c) => reaching.contains(c.group(1)))) {
        grown = reaching.add(name) || grown;
      }
    }
  }
  return [
    for (final (file, name, body) in bodies)
      if (_returnsEarly(body) && _reaches(body, reaching)) '$file: $name',
  ];
}

bool _reaches(String body, Set<String> reaching) =>
    _gradient.hasMatch(body) ||
    _call.allMatches(body).any((c) => reaching.contains(c.group(1)));

void main() {
  test('no function a lit material includes that returns early takes a '
      'derivative or an implicit-level sample', () {
    final directory = _shaderDirectory();
    final pending = [
      for (final file in directory.listSync().whereType<File>())
        if (_litRoot.hasMatch(file.uri.pathSegments.last))
          file.uri.pathSegments.last,
    ];
    final sources = <String, String>{};
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      final file = File('${directory.path}/$name');
      if (sources.containsKey(name) || !file.existsSync()) continue;
      final source = sources[name] = file.readAsStringSync();
      pending.addAll(_include.allMatches(source).map((m) => m.group(1)!));
    }
    expect(
      sources.keys,
      containsAll(['material_lighting.glsl', 'normals.glsl']),
    );
    expect(gradientsUnderEarlyReturn(sources), isEmpty);
  });

  test('a function that returns early is named when it samples, '
      'differentiates or calls a function or macro that does', () {
    const source = '''
#define SAMPLE(uv) texture(sprite, uv)
vec4 Branches() {
  if (on) {
    return texture(sprite, uv);
  }
  return vec4(dFdx(uv.x));
}
vec4 Leaf() {
  return vec4(fwidth(uv.x));
}
vec4 Caller() {
  if (on) {
    return vec4(0.0);
  }
  return Leaf();
}
vec4 Macro() {
  if (on) return vec4(0.0);
  return SAMPLE(uv);
}
vec4 Once() {
  vec4 color;
  if (on) {
    color = texture(sprite, uv);
  } else {
    color = Leaf();
  }
  return color;
}
vec4 Explicit() {
  if (on) return vec4(0.0);
  return textureLod(sprite, uv, 0.0) + texelFetch(sprite, ivec2(0), 0);
}
void Plain() {
  // return texture(sprite, uv);
  if (on) {
    return;
  }
  discard;
}
''';
    expect(gradientsUnderEarlyReturn({'a.glsl': source}), [
      'a.glsl: Branches',
      'a.glsl: Caller',
      'a.glsl: Macro',
    ]);
  });
}
