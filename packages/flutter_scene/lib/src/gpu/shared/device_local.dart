import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

/// A GPU object made on `gpuContext` on its first read, and made again on the
/// first read after `reopenGpuContext` opened the context on a new device,
/// since the objects made before stay on the lost device.
final class DeviceLocal<T extends Object> {
  /// Holds what [create] makes.
  DeviceLocal(this._create);

  final T Function() _create;
  T? _value;
  int _generation = -1;

  /// The object, made on the device the context is open on.
  T get value {
    final generation = gpu.gpuContextGeneration;
    if (_generation != generation) {
      _value = _create();
      _generation = generation;
    }
    return _value!;
  }
}
