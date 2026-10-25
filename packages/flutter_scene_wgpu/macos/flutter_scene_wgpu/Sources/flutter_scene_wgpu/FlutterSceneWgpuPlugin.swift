import CoreVideo
import Foundation
import IOSurface
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Registers external textures backed by IOSurface CVPixelBuffers that the
/// Rust presenter renders into, on the `flutter_scene_wgpu/present` channel.
public class FlutterSceneWgpuPlugin: NSObject, FlutterPlugin {
  private let registry: FlutterTextureRegistry
  private var textures: [Int64: PresentTexture] = [:]

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    let registry = registrar.textures()
    #else
    let messenger = registrar.messenger
    let registry = registrar.textures
    #endif
    let channel = FlutterMethodChannel(name: "flutter_scene_wgpu/present", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(FlutterSceneWgpuPlugin(registry: registry), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      let texture = PresentTexture(registry: registry)
      guard texture.allocate(width: args["width"] as! Int, height: args["height"] as! Int,
                             count: args["count"] as? Int ?? 3) else {
        result(FlutterError(code: "alloc", message: "CVPixelBufferCreate failed", details: nil))
        return
      }
      texture.textureId = registry.register(texture)
      textures[texture.textureId] = texture
      result(texture.describe())
    case "resize":
      guard let texture = textures[(args["textureId"] as! NSNumber).int64Value],
        texture.allocate(width: args["width"] as! Int, height: args["height"] as! Int,
                         count: args["count"] as? Int ?? 3)
      else {
        result(FlutterError(code: "resize", message: "resize failed", details: nil))
        return
      }
      result(texture.describe())
    case "dispose":
      let id = (args["textureId"] as! NSNumber).int64Value
      if let texture = textures.removeValue(forKey: id) {
        registry.unregisterTexture(id)
        texture.release()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private let presentReady: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32) -> Void = {
  context, generation, index in
  Unmanaged<PresentTexture>.fromOpaque(context!).takeUnretainedValue()
    .ready(generation: generation, index: Int(index))
}

/// A set of IOSurface-backed BGRA pixel buffers; Flutter composites the one
/// the GPU finished most recently.
final class PresentTexture: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let lock = NSLock()
  private var buffers: [CVPixelBuffer] = []
  private var latest: CVPixelBuffer?
  private var generation: UInt32 = 0
  private lazy var context = Unmanaged.passRetained(self)
  var textureId: Int64 = 0

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  func allocate(width: Int, height: Int, count: Int) -> Bool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var fresh: [CVPixelBuffer] = []
    for _ in 0..<count {
      var buffer: CVPixelBuffer?
      guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                attributes as CFDictionary, &buffer) == kCVReturnSuccess,
        let buffer, CVPixelBufferGetIOSurface(buffer) != nil
      else { return false }
      fresh.append(buffer)
    }
    lock.lock()
    buffers = fresh
    generation += 1
    lock.unlock()
    return true
  }

  /// What Dart passes to `fsw_present_create_apple`.
  func describe() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let surfaces = buffers.map { buffer -> Int in
      let surface = CVPixelBufferGetIOSurface(buffer)!.takeUnretainedValue()
      return Int(bitPattern: Unmanaged.passUnretained(surface).toOpaque())
    }
    return [
      "textureId": textureId,
      "surfaces": surfaces,
      "generation": Int(generation),
      "callback": unsafeBitCast(presentReady, to: Int.self),
      "context": Int(bitPattern: context.toOpaque()),
    ]
  }

  func ready(generation: UInt32, index: Int) {
    lock.lock()
    if generation == self.generation, index < buffers.count {
      latest = buffers[index]
    }
    lock.unlock()
    let id = textureId
    DispatchQueue.main.async { [registry] in registry.textureFrameAvailable(id) }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  func release() {
    context.release()
  }
}
