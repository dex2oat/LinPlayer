package com.example.linplayer_mobile

import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * MPV 纹理渲染管理器
 *
 * 通过 JNI 与 C++ 层通信，管理 EGL + OpenGL ES 渲染上下文，
 * 将 MPV 视频帧渲染到 Flutter Texture。
 */
class MpvTexture(
    private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry
) {
    private val surface = Surface(surfaceTextureEntry.surfaceTexture())
    private var nativeRenderContext: Long = 0
    @Volatile
    private var disposed = false

    fun attachMpv(mpvHandle: Long) {
        if (nativeRenderContext != 0L || disposed) return

        nativeRenderContext = nativeCreateRenderContext(mpvHandle, surface)
        if (nativeRenderContext == 0L) {
            throw RuntimeException("Failed to create MPV render context")
        }
        Log.i("MpvTexture", "MPV render context attached, textureId=${surfaceTextureEntry.id()}")
    }

    fun dispose() {
        if (disposed) return
        disposed = true

        if (nativeRenderContext != 0L) {
            nativeDestroyRenderContext(nativeRenderContext)
            nativeRenderContext = 0
        }
        surface.release()
        surfaceTextureEntry.release()
        Log.i("MpvTexture", "MPV texture disposed")
    }

    private external fun nativeCreateRenderContext(mpvHandle: Long, surface: Surface): Long
    private external fun nativeDestroyRenderContext(renderContext: Long)

    companion object {
        init {
            System.loadLibrary("mpv_render_jni")
        }
    }
}
