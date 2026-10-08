part of '_gpu.dart';

/// Bridge helper to display an offscreen-rendered Texture in a Flutter
/// widget. Web-only at runtime; throws on Impeller (native) targets
/// because flutter_gpu's `Texture.asImage()` is the standard path there.
Future<ui.Image> presentTextureAsImage(
  Texture texture, {
  bool transferOwnership = false,
}) {
  throw UnimplementedError(
    'presentTextureAsImage is only implemented on web. On native, use '
    'Texture.asImage().',
  );
}

/// The depth-stencil format for passes that rasterize reversed depth (near
/// at 1, far at 0), where float depth keeps distant surfaces apart: float
/// where the context creates a `d32FloatS8UInt` attachment, as Metal and most
/// Vulkan devices do, else the context default. OpenGL ES keeps its default:
/// it clips depth to [-1, 1] and maps it to the buffer's [0, 1] by a half
/// scale and offset, which drops the precision float keeps near 0.
PixelFormat get reversedDepthStencilFormat =>
    _reversedDepthStencilFormat ??= _floatDepthOr(
      gpuContext.defaultDepthStencilFormat,
    );

PixelFormat? _reversedDepthStencilFormat;

PixelFormat _floatDepthOr(PixelFormat fallback) {
  if (fallback == PixelFormat.d32FloatS8UInt) return fallback;
  // Flutter GPU names no backend; OpenGL ES is the one that renders into no
  // mip level of a framebuffer.
  if (!gpuContext.doesSupportFramebufferRenderMipmap) return fallback;
  try {
    gpuContext.createTexture(
      StorageMode.deviceTransient,
      1,
      1,
      format: PixelFormat.d32FloatS8UInt,
      enableShaderReadUsage: false,
    );
    return PixelFormat.d32FloatS8UInt;
  } on Object {
    return fallback;
  }
}

/// The buffers one mesh upload needs. Native has no per-role restriction, so
/// this is the single shared buffer it always was, indices after vertices.
({DeviceBuffer vertex, DeviceBuffer index, int indexBaseOffset})
createGeometryBuffers(int vertexBytes, int indexBytes) {
  final buffer = gpuContext.createDeviceBuffer(
    StorageMode.hostVisible,
    vertexBytes + indexBytes,
  );
  return (vertex: buffer, index: buffer, indexBaseOffset: vertexBytes);
}

/// Writes mesh data into a buffer from [createGeometryBuffers] (or an arena's).
/// The web backend uses [source]'s element type; here bytes are bytes.
bool writeGeometryData(
  DeviceBuffer buffer,
  TypedData source, {
  required int destinationOffsetInBytes,
}) => buffer.overwrite(
  source is ByteData ? source : ByteData.sublistView(source),
  destinationOffsetInBytes: destinationOffsetInBytes,
);
