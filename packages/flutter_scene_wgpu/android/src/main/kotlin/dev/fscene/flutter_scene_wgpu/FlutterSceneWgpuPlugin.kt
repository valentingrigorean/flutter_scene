package dev.fscene.flutter_scene_wgpu

import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/** Registers SurfaceProducer textures and hands their windows to the Rust presenter. */
class FlutterSceneWgpuPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var textures: TextureRegistry
  private val producers = HashMap<Long, TextureRegistry.SurfaceProducer>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // The same library the Dart code asset loads; JNI needs it registered here.
    System.loadLibrary("flutter_scene_wgpu_native")
    textures = binding.textureRegistry
    channel = MethodChannel(binding.binaryMessenger, "flutter_scene_wgpu/present")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    for ((id, producer) in producers) {
      WgpuPresentNative.setSurface(id, null)
      producer.release()
    }
    producers.clear()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "create" -> {
        val producer = textures.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
        val id = producer.id()
        producer.setSize(call.argument<Int>("width")!!, call.argument<Int>("height")!!)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
          override fun onSurfaceAvailable() {
            Log.i(TAG, "surface available for texture $id")
            WgpuPresentNative.setSurface(id, producer.surface)
          }

          override fun onSurfaceCleanup() {
            Log.i(TAG, "surface cleanup for texture $id")
            WgpuPresentNative.setSurface(id, null)
          }
        })
        producers[id] = producer
        WgpuPresentNative.setSurface(id, producer.surface)
        result.success(mapOf("textureId" to id))
      }
      "resize" -> {
        val id = call.argument<Number>("textureId")!!.toLong()
        val producer = producers[id] ?: return result.error("resize", "unknown texture $id", null)
        producer.setSize(call.argument<Int>("width")!!, call.argument<Int>("height")!!)
        WgpuPresentNative.setSurface(id, producer.surface)
        result.success(mapOf("textureId" to id))
      }
      "dispose" -> {
        val id = call.argument<Number>("textureId")!!.toLong()
        producers.remove(id)?.let {
          WgpuPresentNative.setSurface(id, null)
          it.release()
        }
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }
}

private const val TAG = "flutter_scene_wgpu"

/** JNI entry points of flutter_scene_wgpu_native. */
object WgpuPresentNative {
  /** Hands the presenter the window of [surface], or takes it away when null. */
  @JvmStatic external fun setSurface(textureId: Long, surface: Surface?)
}
