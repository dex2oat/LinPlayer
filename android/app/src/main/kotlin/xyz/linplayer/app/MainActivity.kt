package xyz.linplayer.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall

class MainActivity : FlutterActivity() {
    private var exoPlayerPlugin: ExoPlayerPlugin? = null
    private var mpvPlayerPlugin: MpvPlayerPlugin? = null
    private var libassChannel: MethodChannel? = null
    private var proxyChannel: MethodChannel? = null
    private var diagnosticsChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 鍏ㄨ鐩栧穿婧冨彇璇侊細JVM 鏈崟鑾峰紓甯革紙浠讳綍绾跨▼锛屽惈 mpv 鍘熺敓浜嬩欢绾跨▼鍥炶皟锛夊湪琚郴缁?
        // 璁板綍涓?CRASH(JVM) 鏃讹紝ApplicationExitInfo 寰€寰€鎷夸笉鍒板洖婧枃鏈紙瀹炴祴涓?null锛夈€?
        // 杩欓噷瑁呬竴涓粯璁ゆ湭鎹曡幏寮傚父澶勭悊鍣紝鎶婂畬鏁?Java 鍫嗘爤鐩存帴杩藉姞杩涘彲瀵煎嚭鐨?App 鏃ュ織锛?
        // 鍐嶉摼鍥炲師澶勭悊鍣紙涓嶆敼鍙樺穿婧冭涓猴紝鍙ˉ鍙栬瘉锛夈€?
        installCrashLogger()

        // 娉ㄥ唽 MpvSurfaceView 骞冲彴瑙嗗浘宸ュ巶锛堢敤浜?gpu-next 娓叉煋锛?
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.linplayer/mpv_surface",
            MpvSurfaceViewFactory()
        )

        // 娉ㄥ唽 ExoPlayer 鎻掍欢锛坴2 - 鏀寔瀛楀箷杞ㄩ亾锛?
        exoPlayerPlugin = ExoPlayerPlugin(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.linplayer/exoplayer")
            .setMethodCallHandler(exoPlayerPlugin)

        // 娉ㄥ唽鍘熺敓 MPV 鎻掍欢锛堥€氳繃 libplayer.so 鐩存帴璋冪敤 libmpv锛?
        mpvPlayerPlugin = MpvPlayerPlugin(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.linplayer/mpv")
            .setMethodCallHandler(mpvPlayerPlugin)

        // 娉ㄥ唽 legacy libass JNI 妗ユ帴 MethodChannel
        // 褰撳墠 ExoPlayer 宸蹭紭鍏堣蛋 Media3/libass 鍘熺敓瀛楀箷绠＄嚎锛岃繖閲屼粎淇濈暀鍏煎瀹炵幇
        libassChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/libass"
        )
        libassChannel!!.setMethodCallHandler { call, result ->
            handleLibassCall(this, call, result)
        }

        // 娉ㄥ唽 mihomo 浠ｇ悊鍐呮牳妗ユ帴锛堜粎 TV 鏋勫缓鍚唴鏍革紝鍏朵綑鏋勫缓璋冪敤 start 浼氳繑鍥炲唴鏍哥己澶憋級
        proxyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/proxy"
        )
        proxyChannel!!.setMethodCallHandler { call, result ->
            ProxyBridge.handle(this, call, result)
        }

        // 璇婃柇锛氬彇涓婃杩涚▼閫€鍑哄師鍥狅紙鍚師鐢熷穿婧?tombstone 鍥炴函锛夈€?
        // 鍘熺敓 SIGSEGV锛堝 libmpv 闂€€锛夊湪 Dart/Java 灞傛姄涓嶅埌銆佸簲鐢ㄦ棩蹇楅噷鍙湁"鎴涚劧鑰屾"銆?
        // 鐢?ActivityManager.getHistoricalProcessExitReasons锛圓PI 30+锛屽厤鏉冮檺锛夎兘鎷垮埌
        // 涓婃宕╂簝鐨勫師鐢熷洖婧紝鍚姩鍚庣敱 Dart 鍐欏叆鍙鍑虹殑 App 鏃ュ織锛屼究浜庡畾浣嶃€?
        diagnosticsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/diagnostics"
        )
        diagnosticsChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getRecentExitReasons" -> result.success(getRecentExitReasons())
                else -> result.notImplemented()
            }
        }

        // 濯掍綋锛氭妸鎾斁鍣ㄦ埅鍥惧瓧鑺傚啓鍏ョ郴缁熺浉鍐岋紙涔嬪墠 Dart 渚у彧鎷垮埌瀛楄妭銆佷粠鏈惤鐩橈級銆?
        mediaChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/media"
        )
        mediaChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImageToGallery" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name")
                        ?: "LinPlayer_${System.currentTimeMillis()}"
                    if (bytes == null) {
                        result.success(false)
                    } else {
                        result.success(saveImageToGallery(bytes, name))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 鎶婃埅鍥惧瓧鑺備繚瀛樺埌绯荤粺銆屼笅杞姐€嶇洰褰曚笅鐨?Linpic 瀛愭枃浠跺す锛圖ownload/Linpic锛夈€?
     * Android 10+锛圦锛夎蛋 MediaStore.Downloads 浣滅敤鍩熷瓨鍌紝**鏃犻渶浠讳綍瀛樺偍鏉冮檺**锛?
     * Android 9 鍙婁互涓嬪啓鍏ュ叕鍏?Download/Linpic锛堥渶 WRITE_EXTERNAL_STORAGE锛屾竻鍗曞凡澹版槑 maxSdk28锛夈€?
     */
    private fun saveImageToGallery(bytes: ByteArray, displayName: String): Boolean {
        val fileName = if (displayName.endsWith(".jpg", true)) displayName else "$displayName.jpg"
        return try {
            val resolver = contentResolver
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, "image/jpeg")
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/Linpic"
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                ) ?: return false
                resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return false
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                true
            } else {
                @Suppress("DEPRECATION")
                val downloadDir =
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val dir = java.io.File(downloadDir, "Linpic").apply { mkdirs() }
                val file = java.io.File(dir, fileName)
                file.outputStream().use { it.write(bytes) }
                // 閫氱煡濯掍綋鎵弿锛岃鏂囦欢绠＄悊鍣?鐩稿唽鑳界珛鍒荤湅鍒般€?
                android.media.MediaScannerConnection.scanFile(
                    this, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null
                )
                true
            }
        } catch (e: Exception) {
            android.util.Log.e("MediaSave", "saveImageToGallery failed: ${e.message}")
            false
        }
    }

    /** 瑁呴粯璁ゆ湭鎹曡幏寮傚父澶勭悊鍣細鎶婂爢鏍堝啓鍏?App 鏃ュ織鍚庨摼鍥炲師澶勭悊鍣ㄣ€?*/
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = java.io.StringWriter()
                throwable.printStackTrace(java.io.PrintWriter(sw))
                val text = "绾跨▼ ${thread.name} 鏈崟鑾峰紓甯?\n$sw"
                android.util.Log.e("UncaughtCrash", text)
                appendCrashToLog(text)
            } catch (_: Throwable) {
                // 鍙栬瘉澶辫触缁濅笉褰卞搷宕╂簝閾捐矾鏈韩銆?
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    /** 鎶婂穿婧冩枃鏈拷鍔犺繘 AppLogger 鍚屽悕鏃ュ織鏂囦欢锛堚€?files/linplayer_logs/linplayer-<date>.log锛夈€?*/
    private fun appendCrashToLog(text: String) {
        try {
            val dir = java.io.File(getExternalFilesDir(null), "linplayer_logs")
            if (!dir.exists()) dir.mkdirs()
            val date = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                .format(java.util.Date())
            val ts = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", java.util.Locale.US)
                .format(java.util.Date())
            java.io.File(dir, "linplayer-$date.log")
                .appendText("\n$ts  FATAL [UncaughtCrash] $text\n")
        } catch (_: Throwable) {
        }
    }

    /** 璇诲彇鏈€杩戠殑杩涚▼閫€鍑鸿褰曪紱宕╂簝/ANR 闄勫甫鍘熺敓鍥炴函鏂囨湰锛坱ombstone/anr trace锛夈€?*/
    private fun getRecentExitReasons(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val infos = am.getHistoricalProcessExitReasons(packageName, 0, 8)
            infos.map { info ->
                var trace: String? = null
                val reason = info.reason
                if (reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                    reason == ApplicationExitInfo.REASON_CRASH ||
                    reason == ApplicationExitInfo.REASON_ANR
                ) {
                    try {
                        info.traceInputStream?.use { stream ->
                            trace = stream.readBytes().toString(Charsets.UTF_8)
                        }
                    } catch (_: Exception) {
                    }
                }
                mapOf(
                    "reason" to reason,
                    "description" to (info.description ?: ""),
                    "timestamp" to info.timestamp,
                    "importance" to info.importance,
                    "pid" to info.pid,
                    "trace" to trace
                )
            }
        } catch (e: Exception) {
            android.util.Log.w("Diagnostics", "getRecentExitReasons failed: ${e.message}")
            emptyList()
        }
    }

    override fun onDestroy() {
        exoPlayerPlugin?.disposeAll()
        mpvPlayerPlugin?.disposeAll()
        ProxyBridge.stop()
        super.onDestroy()
    }
}

/**
 * libass JNI 妗ユ帴鐨?MethodChannel 澶勭悊
 * 瀵瑰簲 Dart 灞?LibassBridge 鐨勮皟鐢?
 */
private fun handleLibassCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
        "isLibassAvailable" -> {
            result.success(LibassBridge.isAvailable(context))
        }
        "initLibass" -> {
            val width = call.argument<Int>("width") ?: 1920
            val height = call.argument<Int>("height") ?: 1080
            LibassBridge.init(context, width, height)
            result.success(true)
        }
        "loadSubFile" -> {
            val path = call.argument<String>("path") ?: ""
            LibassBridge.loadSubFile(path)
            result.success(true)
        }
        "loadSubMemory" -> {
            val data = call.argument<ByteArray>("data") ?: byteArrayOf()
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
            val frameData = LibassBridge.renderFrame(ptsMs.toLong(), changed)
            result.success(frameData)
        }
        "dispose" -> {
            LibassBridge.dispose()
            result.success(true)
        }
        else -> result.notImplemented()
    }
}

object LibassBridge {
    private var assLibrary: Long = 0
    private var assRenderer: Long = 0
    private var assTrack: Long = 0
    private var initialized = false
    private var pathsSet = false

    init {
        try {
            System.loadLibrary("ass")
            android.util.Log.i("LibassBridge", "libass.so loaded successfully")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.w("LibassBridge", "libass.so not found, trying libmpv.so (libass may be statically linked)")
            try {
                // libass may be statically linked in libmpv.so (from mpv-android)
                System.loadLibrary("mpv")
                android.util.Log.i("LibassBridge", "libmpv.so loaded, libass symbols should be available")
            } catch (e2: UnsatisfiedLinkError) {
                android.util.Log.w("LibassBridge", "libmpv.so also not found: ${e2.message}")
            }
        }
        try {
            System.loadLibrary("linass_jni")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("LibassBridge", "Failed to load linass_jni: ${e.message}")
        }
    }

    external fun nativeSetLibraryPaths(libassPath: String, libmpvPath: String)
    external fun nativeIsAvailable(): Boolean
    external fun nativeInit(width: Int, height: Int): Long
    external fun nativeLoadFile(assLibrary: Long, path: String): Long
    external fun nativeLoadMemory(assLibrary: Long, data: ByteArray, codec: String): Long
    external fun nativeSetFontSize(renderer: Long, size: Int)
    external fun nativeSetFontName(renderer: Long, name: String)
    external fun nativeRenderFrame(renderer: Long, track: Long, ptsMs: Long): ByteArray?
    external fun nativeDispose(assLibrary: Long, renderer: Long, track: Long)

    fun isAvailable(context: Context): Boolean {
        if (!pathsSet) {
            try {
                val nativeDir = context.applicationInfo.nativeLibraryDir
                val libassFile = java.io.File(nativeDir, "libass.so")
                val libmpvFile = java.io.File(nativeDir, "libmpv.so")
                
                // 妫€鏌ュ簱鏂囦欢鏄惁鐪熷疄瀛樺湪锛屼笉瀛樺湪鍒欐彁渚涚┖璺緞璁㎎NI鍥為€€澶勭悊
                val libassPath = if (libassFile.exists()) libassFile.absolutePath else ""
                val libmpvPath = if (libmpvFile.exists()) libmpvFile.absolutePath else ""
                
                nativeSetLibraryPaths(libassPath, libmpvPath)
                pathsSet = true
                android.util.Log.i("LibassBridge", "Set library paths: ass=$libassPath, mpv=$libmpvPath")
            } catch (e: Exception) {
                android.util.Log.e("LibassBridge", "Failed to set library paths: ${e.message}")
            }
        }
        return try {
            nativeIsAvailable()
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("LibassBridge", "nativeIsAvailable failed: ${e.message}")
            false
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "nativeIsAvailable exception: ${e.message}")
            false
        }
    }

    fun init(context: Context, width: Int, height: Int) {
        if (initialized) dispose()
        try {
            assLibrary = nativeInit(width, height)
            assRenderer = assLibrary
            initialized = true
            android.util.Log.i("LibassBridge", "Initialized: ${width}x${height}, library=$assLibrary")
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Init failed: ${e.message}")
            initialized = false
        }
    }

    fun loadSubFile(path: String) {
        if (assLibrary == 0L) {
            android.util.Log.w("LibassBridge", "Cannot load sub file: library not initialized")
            return
        }
        try {
            assTrack = nativeLoadFile(assLibrary, path)
            android.util.Log.i("LibassBridge", "Loaded sub file: $path, track=$assTrack")
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Load sub file failed: ${e.message}")
        }
    }

    fun loadSubMemory(data: ByteArray, codec: String) {
        if (assLibrary == 0L) {
            android.util.Log.w("LibassBridge", "Cannot load sub memory: library not initialized")
            return
        }
        try {
            assTrack = nativeLoadMemory(assLibrary, data, codec)
            android.util.Log.i("LibassBridge", "Loaded sub memory: ${data.size} bytes, codec=$codec, track=$assTrack")
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Load sub memory failed: ${e.message}")
        }
    }

    fun setFontSize(size: Int) {
        if (assRenderer == 0L) return
        try {
            nativeSetFontSize(assRenderer, size)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Set font size failed: ${e.message}")
        }
    }

    fun setFontName(name: String) {
        if (assRenderer == 0L) return
        try {
            nativeSetFontName(assRenderer, name)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Set font name failed: ${e.message}")
        }
    }

    fun renderFrame(ptsMs: Long, changed: IntArray): ByteArray? {
        if (assRenderer == 0L || assTrack == 0L) return null
        return try {
            nativeRenderFrame(assRenderer, assTrack, ptsMs)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Render frame failed: ${e.message}")
            null
        }
    }

    fun dispose() {
        if (!initialized) return
        try {
            nativeDispose(assLibrary, assRenderer, assTrack)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Dispose failed: ${e.message}")
        }
        assLibrary = 0
        assRenderer = 0
        assTrack = 0
        initialized = false
        android.util.Log.i("LibassBridge", "Disposed")
    }
}
