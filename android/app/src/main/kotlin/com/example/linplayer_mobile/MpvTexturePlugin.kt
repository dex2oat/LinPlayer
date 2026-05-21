package com.example.linplayer_mobile

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * MPV Texture Platform Channel 插件
 *
 * 处理 Dart 层的 `com.linplayer/mpv_texture` MethodChannel 调用：
 * - createMpvTexture: 创建 SurfaceTexture，返回 textureId
 * - attachMpvToTexture: 将 MPV handle 绑定到 Texture 进行渲染
 * - disposeMpvTexture: 释放渲染资源
 */
class MpvTexturePlugin(
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.linplayer/mpv_texture"

        fun registerWith(engine: FlutterEngine): MpvTexturePlugin {
            val plugin = MpvTexturePlugin(engine.renderer)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(plugin)
            return plugin
        }
    }

    private val textures = mutableMapOf<Int, MpvTexture>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createMpvTexture" -> {
                val width = call.argument<Int>("width") ?: 1920
                val height = call.argument<Int>("height") ?: 1080
                val entry = textureRegistry.createSurfaceTexture()
                entry.surfaceTexture().setDefaultBufferSize(width, height)
                val texture = MpvTexture(entry)
                textures[entry.id().toInt()] = texture
                result.success(mapOf("textureId" to entry.id()))
            }
            "attachMpvToTexture" -> {
                val textureId = call.argument<Int>("textureId") ?: 0
                val mpvHandle = call.argument<Long>("mpvHandle") ?: 0
                try {
                    textures[textureId]?.attachMpv(mpvHandle)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ATTACH_ERROR", e.message, null)
                }
            }
            "disposeMpvTexture" -> {
                val textureId = call.argument<Int>("textureId") ?: 0
                textures.remove(textureId)?.dispose()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    fun disposeAll() {
        textures.values.forEach { it.dispose() }
        textures.clear()
    }
}
