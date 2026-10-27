// ignore_for_file: implementation_imports
import 'package:flutter_scene/src/gpu/shared/web_backend_choice.dart';
import 'package:test/test.dart';

void main() {
  test('WebGPU is chosen where the browser hands out a device', () {
    expect(
      chooseWebBackend(define: '', webGpuDevice: true),
      WebBackendKind.webGpu,
    );
  });

  test('WebGL2 is chosen where the browser hands out no WebGPU device', () {
    expect(
      chooseWebBackend(define: '', webGpuDevice: false),
      WebBackendKind.webGl2,
    );
  });

  test('the webgl2 define forces WebGL2', () {
    expect(
      chooseWebBackend(define: webGl2BackendDefine, webGpuDevice: true),
      WebBackendKind.webGl2,
    );
  });
}
