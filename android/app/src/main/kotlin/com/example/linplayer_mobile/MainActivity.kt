package com.example.linplayer_mobile

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val LIBASS_CHANNEL = "com.linplayer/libass"
    private var exoPlayerPlugin: ExoPlayerPlugin? = null
    private var mpvTexturePlugin: MpvTexturePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册 ExoPlayer 插件
        exoPlayerPlugin = ExoPlayerPlugin(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.linplayer/exoplayer")
            .setMethodCallHandler(exoPlayerPlugin)

        // 注册 MPV Texture 插件
        mpvTexturePlugin = MpvTexturePlugin.registerWith(flutterEngine)

        // 注册 libass MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIBASS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isLibassAvailable" -> {
                        result.success(LibassBridge.isAvailable(this))
                    }
                    "initLibass" -> {
                        val width = call.argument<Int>("width") ?: 0
                        val height = call.argument<Int>("height") ?: 0
                        LibassBridge.init(this, width, height)
                        result.success(true)
                    }
                    "loadSubFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        LibassBridge.loadSubFile(path)
                        result.success(true)
                    }
                    "loadSubMemory" -> {
                        val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                        val codec = call.argument<String>("codec") ?: "ass"
                        LibassBridge.loadSubMemory(data, codec)
                        result.success(true)
                    }
                    "setFontSize" -> {
                        val size = call.argument<Int>("size") ?: 48
                        LibassBridge.setFontSize(size)
                        result.success(true)
                    }
                    "setFontName" -> {
                        val name = call.argument<String>("name") ?: ""
                        LibassBridge.setFontName(name)
                        result.success(true)
                    }
                    "renderFrame" -> {
                        val ptsMs = call.argument<Int>("ptsMs") ?: 0
                        val changed = IntArray(1)
                        val bitmap = LibassBridge.renderFrame(ptsMs.toLong(), changed)
                        if (bitmap != null) {
                            result.success(bitmap)
                        } else {
                            result.success(null)
                        }
                    }
                    "dispose" -> {
                        LibassBridge.dispose()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        exoPlayerPlugin?.disposeAll()
        mpvTexturePlugin?.disposeAll()
        LibassBridge.dispose()
        super.onDestroy()
    }
}

object LibassBridge {
    private var assLibrary: Long = 0
    private var assRenderer: Long = 0
    private var assTrack: Long = 0
    private var initialized = false

    init {
        System.loadLibrary("ass")
        System.loadLibrary("linass_jni")
    }

    external fun nativeIsAvailable(): Boolean
    external fun nativeInit(width: Int, height: Int): Long
    external fun nativeLoadFile(assLibrary: Long, path: String): Long
    external fun nativeLoadMemory(assLibrary: Long, data: ByteArray, codec: String): Long
    external fun nativeSetFontSize(renderer: Long, size: Int)
    external fun nativeSetFontName(renderer: Long, name: String)
    external fun nativeRenderFrame(renderer: Long, track: Long, ptsMs: Long): ByteArray?
    external fun nativeDispose(assLibrary: Long, renderer: Long, track: Long)

    fun isAvailable(context: Context): Boolean {
        return try {
            nativeIsAvailable()
        } catch (e: UnsatisfiedLinkError) {
            false
        }
    }

    fun init(context: Context, width: Int, height: Int) {
        if (initialized) dispose()
        assLibrary = nativeInit(width, height)
        assRenderer = assLibrary
        initialized = true
    }

    fun loadSubFile(path: String) {
        if (assLibrary == 0L) return
        assTrack = nativeLoadFile(assLibrary, path)
    }

    fun loadSubMemory(data: ByteArray, codec: String) {
        if (assLibrary == 0L) return
        assTrack = nativeLoadMemory(assLibrary, data, codec)
    }

    fun setFontSize(size: Int) {
        if (assRenderer == 0L) return
        nativeSetFontSize(assRenderer, size)
    }

    fun setFontName(name: String) {
        if (assRenderer == 0L) return
        nativeSetFontName(assRenderer, name)
    }

    fun renderFrame(ptsMs: Long, changed: IntArray): ByteArray? {
        if (assRenderer == 0L || assTrack == 0L) return null
        return nativeRenderFrame(assRenderer, assTrack, ptsMs)
    }

    fun dispose() {
        if (!initialized) return
        nativeDispose(assLibrary, assRenderer, assTrack)
        assLibrary = 0
        assRenderer = 0
        assTrack = 0
        initialized = false
    }
}
