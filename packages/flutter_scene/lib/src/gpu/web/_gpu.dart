/// The web GPU shim: flutter_gpu's API over a browser backend chosen at
/// startup, WebGPU where the browser hands out a device and WebGL2 elsewhere
/// or with `--dart-define=FLUTTER_SCENE_GPU_BACKEND=webgl2`.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:vector_math/vector_math.dart' as vm;

import '../shared/encoded_image_types.dart';
import '../shared/gpu_capabilities.dart';
import '../shared/web_backend_choice.dart';
import '../webgpu/webgpu_backend.dart' show createWebGpuBackend;
import '../webgpu/webgpu_device.dart' show WebGpuDevice;
import 'webgl/_webgl.dart' show createWebGlBackend;

part 'backend.dart';
part 'formats.dart';
part 'host_buffer.dart';
part 'shader_names.dart';
part 'types.dart';
part 'vertex_layout.dart';
