package xyz.linplayer.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import `is`.xyz.mpv.MPVLib
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Flutter platform channel plugin for native mpv playback.
 *
 * Follows the same MethodChannel + EventChannel pattern as ExoPlayerPlugin.
 * Each player instance wraps an MPVLib-managed mpv context. The video surface
 * from Flutter's TextureRegistry is attached to mpv via MPVLib.attachSurface(),
 * which sets the "wid" option 鈥?mpv creates its own EGL context on the surface
 * and manages all rendering internally.
 */
class MpvPlayerPlugin(
    private val context: Context,
    private val binaryMessenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "MpvPlayerPlugin"
        private const val METHOD_CHANNEL = "com.linplayer/mpv"
    }

    private val players = ConcurrentHashMap<String, MpvPlayerInstance>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        android.util.Log.d(TAG, "onMethodCall: ${call.method}, players=${players.keys}")
        when (call.method) {
            "createPlayer" -> {
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Number>("startPositionMs")?.toInt() ?: 0
                val dolbyVisionFix = call.argument<Boolean>("dolbyVisionFix") ?: false
                val preferredSubtitleLanguage = call.argument<String>("preferredSubtitleLanguage")
                val hardwareDecoding = call.argument<Boolean>("hardwareDecoding") ?: true
                // Dart 浼犺繃鏉ョ殑 int 鍦?Android 绔彲鑳芥槸 Long锛岀敤 Number 鍏煎
                val surfaceViewId = call.argument<Number>("surfaceViewId")?.toInt()
                val useGpuNext = call.argument<Boolean>("useGpuNext") ?: false
                // 鐢ㄦ埛鑷畾涔変唬鐞嗭紙浠?HTTP 浠ｇ悊鍙 mpv 娑堣垂锛涗负绌哄垯鐩磋繛锛?
                val httpProxy = call.argument<String>("httpProxy")
                // 缁熶竴 UA锛氶儴鍒?CDN 鎷掔粷 mpv 榛樿 UA 瀵艰嚧鍙栨祦澶辫触銆?
                val userAgent = call.argument<String>("userAgent")
                // 閫愭祦 HTTP 澶达紙缃戠洏/鑱氬悎婧愮洿閾鹃渶 Cookie/Authorization/Referer锛夈€?
                val httpHeaders = call.argument<Map<String, String>>("httpHeaders")
                // 缃戠粶鎾斁纾佺洏缂撳瓨锛堟寜鐢ㄦ埛 300MB鈥?GB 璁剧疆锛涙湰鍦版枃浠朵负绌?0 琛ㄧず涓嶅惎鐢級
                val videoCacheDir = call.argument<String>("videoCacheDir")
                val diskCacheForwardBytes = call.argument<Number>("diskCacheForwardBytes")?.toLong() ?: 0L
                val diskCacheBackBytes = call.argument<Number>("diskCacheBackBytes")?.toLong() ?: 0L
                createPlayer(videoUrl, startPositionMs, hardwareDecoding, surfaceViewId, useGpuNext, httpProxy, userAgent, httpHeaders, videoCacheDir, diskCacheForwardBytes, diskCacheBackBytes, result)
            }
            "reloadPlayer" -> {
                // L2 鍘熷湴閲嶈浇锛氬灞傞噸瑙ｆ瀽閲嶇鍚庣殑鏂?URL锛屽鐢ㄥ悓涓€ surface/texture锛屽厤榛戝睆銆?
                val playerId = call.argument<String>("playerId") ?: ""
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Number>("startPositionMs")?.toInt() ?: 0
                getPlayer(playerId)?.reload(videoUrl, startPositionMs)
                result.success(true)
            }
            "play" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.play()
                result.success(true)
            }
            "pause" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.pause()
                result.success(true)
            }
            "seekTo" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val positionMs = call.argument<Number>("positionMs")?.toInt() ?: 0
                getPlayer(playerId)?.seekTo(positionMs)
                result.success(true)
            }
            "setSpeed" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val speed = call.argument<Double>("speed") ?: 1.0
                getPlayer(playerId)?.setSpeed(speed)
                result.success(true)
            }
            "setVolume" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val volume = call.argument<Double>("volume") ?: 1.0
                getPlayer(playerId)?.setVolume(volume)
                result.success(true)
            }
            "getPosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val pos = getPlayer(playerId)?.getPosition() ?: 0
                result.success(pos)
            }
            "getDuration" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val dur = getPlayer(playerId)?.getDuration() ?: 0
                result.success(dur)
            }
            "getVideoSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = getPlayer(playerId)?.getVideoSize()
                result.success(size ?: mapOf("width" to 0, "height" to 0))
            }
            "getTracks" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val tracks = getPlayer(playerId)?.getTracksInfo()
                result.success(tracks ?: emptyList<Map<String, Any>>())
            }
            "selectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val trackId = call.argument<String>("trackId") ?: ""
                getPlayer(playerId)?.selectSubtitleTrack(trackId)
                result.success(true)
            }
            "deselectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.deselectSubtitleTrack()
                result.success(true)
            }
            "selectAudioTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val trackId = call.argument<String>("trackId") ?: ""
                getPlayer(playerId)?.selectAudioTrack(trackId)
                result.success(true)
            }
            "loadSubtitle" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val subtitleUrl = call.argument<String>("subtitleUrl") ?: ""
                val subtitleLanguage = call.argument<String>("subtitleLanguage") ?: "und"
                getPlayer(playerId)?.loadSubtitle(subtitleUrl, subtitleLanguage)
                result.success(true)
            }
            "setProperty" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = call.argument<String>("value") ?: ""
                getPlayer(playerId)?.setProperty(name, value)
                result.success(true)
            }
            "getProperty" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = getPlayer(playerId)?.getProperty(name)
                result.success(value)
            }
            "getPropertyDouble" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = getPlayer(playerId)?.getPropertyDouble(name)
                result.success(value)
            }
            "command" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                @Suppress("UNCHECKED_CAST")
                val args = call.argument<List<String>>("args") ?: emptyList()
                getPlayer(playerId)?.command(args.toTypedArray())
                result.success(true)
            }
            "screenshot" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val bitmap = getPlayer(playerId)?.screenshot()
                result.success(bitmap)
            }
            "setSubtitleDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setProperty("sub-delay", seconds.toString())
                result.success(true)
            }
            "setAudioDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setProperty("audio-delay", seconds.toString())
                result.success(true)
            }
            "setSubtitleFont" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val fontName = call.argument<String>("fontName") ?: ""
                getPlayer(playerId)?.setProperty("sub-font", fontName)
                result.success(true)
            }
            "setSubtitleSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = call.argument<Double>("size") ?: 0.5
                // mpv sub-font-size is in scaled pixels; map 0.0-1.0 to a reasonable range
                val fontSize = (size * 60).toInt().coerceIn(10, 120)
                getPlayer(playerId)?.setProperty("sub-font-size", fontSize.toString())
                result.success(true)
            }
            "setSubtitlePosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val position = call.argument<Double>("position") ?: 0.0
                // mpv sub-pos: 0=top, 100=bottom (inverted from UI)
                val subPos = ((1.0 - position) * 100).toInt().coerceIn(0, 100)
                getPlayer(playerId)?.setProperty("sub-pos", subPos.toString())
                result.success(true)
            }
            "setSubtitleBackground" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: false
                getPlayer(playerId)?.setProperty(
                    "sub-back-color",
                    if (enabled) "0.0/0.0/0.0/0.75" else "0.0/0.0/0.0/0.0"
                )
                result.success(true)
            }
            "setAspectRatio" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val ratio = call.argument<String>("ratio") ?: "鑷姩"
                getPlayer(playerId)?.setAspectRatio(ratio)
                result.success(true)
            }
            "disposePlayer" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                disposePlayer(playerId)
                result.success(true)
            }
            "getCacheDir" -> {
                result.success(context.cacheDir.absolutePath)
            }
            "writeFile" -> {
                val path = call.argument<String>("path") ?: ""
                val data = call.argument<ByteArray>("data")
                if (path.isNotEmpty() && data != null) {
                    try {
                        java.io.File(path).writeBytes(data)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WRITE_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGS", "path and data required", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(
        videoUrl: String,
        startPositionMs: Int,
        hardwareDecoding: Boolean,
        surfaceViewId: Int?,
        useGpuNext: Boolean,
        httpProxy: String?,
        userAgent: String?,
        httpHeaders: Map<String, String>?,
        videoCacheDir: String?,
        diskCacheForwardBytes: Long,
        diskCacheBackBytes: Long,
        result: MethodChannel.Result
    ) {
        // Always use SurfaceTexture (no SurfaceView polling needed)
        mainHandler.post { createPlayerOnMainThread(videoUrl, startPositionMs, hardwareDecoding, useGpuNext, httpProxy, userAgent, httpHeaders, videoCacheDir, diskCacheForwardBytes, diskCacheBackBytes, result) }
    }

    private fun createPlayerOnMainThread(
        videoUrl: String,
        startPositionMs: Int,
        hardwareDecoding: Boolean,
        useGpuNext: Boolean,
        httpProxy: String?,
        userAgent: String?,
        httpHeaders: Map<String, String>?,
        videoCacheDir: String?,
        diskCacheForwardBytes: Long,
        diskCacheBackBytes: Long,
        result: MethodChannel.Result
    ) {
        var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
        try {
            // MPVLib is a singleton 鈥?only one mpv context can exist at a time.
            // Dispose any existing player first.锛堟斁杩?try锛歳elease 鍐呴儴寮傚父涔熶笉澶栨硠锛?
            if (players.isNotEmpty()) {
                android.util.Log.w(TAG, "createPlayer: disposing existing player(s)")
                players.values.forEach { it.release() }
                players.clear()
            }

            val playerId = UUID.randomUUID().toString()

            // Always use SurfaceTexture for both gpu and gpu-next modes
            surfaceTextureEntry = textureRegistry.createSurfaceTexture()
            val surfaceTexture = surfaceTextureEntry.surfaceTexture()

            // Set initial surface size using screen dimensions (landscape orientation)
            // IMPORTANT: Must be set BEFORE creating Surface to avoid SurfaceSyncer errors
            val dm = context.resources.displayMetrics
            val screenW = if (dm.widthPixels > dm.heightPixels) dm.widthPixels else dm.heightPixels
            val screenH = if (dm.widthPixels > dm.heightPixels) dm.heightPixels else dm.widthPixels
            surfaceTexture.setDefaultBufferSize(screenW, screenH)

            val surface = Surface(surfaceTexture)

            // Create mpv context.
            // 杩欎竴姝ヤ細瑙﹀彂 MPVLib 鐨?init{}锛堥娆¤闂椂 System.loadLibrary("mpv"/"player")锛夛紝
            // 浠庤€屾妸 libmpv.so 鍙婂叾渚濊禆 libavcodec.so 鐪熸鍔犺浇杩涜繘绋嬨€?
            MPVLib.create(context)

            // 娉ㄥ唽 JavaVM 缁?ffmpeg锛坅v_jni_set_java_vm锛宮ediacodec 纭В蹇呴渶锛夈€?
            // 蹇呴』鏀惧湪 MPVLib.create() 涔嬪悗锛歯ativeRegisterJavaVm 閫氳繃 dlsym 鍙?
            // av_jni_set_java_vm 绗﹀彿锛岃€岃绗﹀彿鏉ヨ嚜 libavcodec.so鈥斺€旈甯ф挱鏀炬椂鑻ュ湪
            // libmpv 鍔犺浇鍓嶈皟鐢紝dlsym 杩斿洖 null銆佸師鐢熶晶璋冪敤绌烘寚閽?鈫?SIGSEGV 闂€€銆?
            // 宕╂簝浼氶噸鍚繘绋嬶紝浣挎瘡娆℃挱鏀惧張鎴?棣栧抚" 鈫?琛ㄧ幇涓?姣忔鎾斁蹇呴棯閫€"銆?
            MpvInitBridge.ensureJavaVmRegistered()

            // Set mpv options (must be before init)
            android.util.Log.i(TAG, "Setting mpv options: hardwareDecoding=$hardwareDecoding, useGpuNext=$useGpuNext")
            setMpvOptions(hardwareDecoding, useGpuNext = useGpuNext, httpProxy = httpProxy,
                userAgent = userAgent,
                httpHeaders = httpHeaders,
                videoCacheDir = videoCacheDir,
                diskCacheForwardBytes = diskCacheForwardBytes,
                diskCacheBackBytes = diskCacheBackBytes)

            // Initialize mpv (registers JavaVM, starts event thread)
            MPVLib.init()

            MPVLib.attachSurface(surface)

            // Notify mpv of initial render target dimensions
            MPVLib.setPropertyString("android-surface-size", "${screenW}x${screenH}")

            // Enable video output
            MPVLib.setPropertyBoolean("force-window", true)

            // Set up EventChannel
            val eventChannel = EventChannel(
                binaryMessenger,
                "$METHOD_CHANNEL/events/$playerId"
            )

            val mpvTexture = MpvTexture(surfaceTextureEntry)
            val instance = MpvPlayerInstance(
                playerId = playerId,
                context = context,
                surface = surface,
                mpvTexture = mpvTexture,
                eventChannel = eventChannel,
                mainHandler = mainHandler
            )

            // Register observer锛堝惈鏃ュ織璁㈤槄锛氭妸 mpv 鍘熺敓 warn/error/fatal 钀藉埌 App 鏃ュ織锛?
            MPVLib.addObserver(instance)
            MPVLib.addLogObserver(instance)

            // Observe key properties
            MPVLib.observeProperty("time-pos", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("duration", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("pause", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("paused-for-cache", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("eof-reached", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("idle-active", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("speed", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("volume", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("track-list", MPVLib.MpvFormat.NODE)
            MPVLib.observeProperty("video-params/w", MPVLib.MpvFormat.INT64)
            MPVLib.observeProperty("video-params/h", MPVLib.MpvFormat.INT64)
            MPVLib.observeProperty("hwdec-current", MPVLib.MpvFormat.STRING)

            players[playerId] = instance

            // Load the video
            if (videoUrl.isNotEmpty()) {
                // 缁挱锛氬湪 loadfile 涔嬪墠閫氳繃 start 灞炴€ф寚瀹氳捣濮嬩綅缃紝璁?mpv 鍦ㄥ姞杞芥椂
                // 鐩存帴瀹氫綅鍒扮画鎾偣銆傛棫鍋氭硶鏄?loadfile 涔嬪悗绔嬪埢鍙?seek锛屼絾 loadfile 鏄?
                // 寮傛鐨勶紝鏂囦欢灏氭湭瑙ｅ皝瑁呭畬鎴愭椂 seek 浼氳惤绌鸿涓㈠純锛屽鑷?鏃朵笉鏃朵粠澶存挱鏀?銆?
                // 鐢?start 閫夐」鍙交搴曟秷闄よ绔炴€侊紝涓斾笉浼氬嚭鐜板厛闂竴涓嬬墖澶寸殑闂銆?
                if (startPositionMs > 0) {
                    MPVLib.setPropertyString("start", "${startPositionMs / 1000.0}")
                    android.util.Log.i(TAG, "Resume playback from ${startPositionMs / 1000.0}s")
                } else {
                    MPVLib.setPropertyString("start", "none")
                }
                MPVLib.command(arrayOf("loadfile", videoUrl, "replace"))
                val voMode = if (useGpuNext) "gpu-next" else "gpu"
                android.util.Log.i(TAG, "Loading video, SurfaceTexture/$voMode")
            } else {
                android.util.Log.w(TAG, "videoUrl is empty, not loading")
            }

            // Return result with texture info
            val resultMap = mutableMapOf<String, Any>(
                "playerId" to playerId,
                "textureId" to surfaceTextureEntry.id()
            )
            android.util.Log.i(TAG, "Created player with SurfaceTexture (textureId=${surfaceTextureEntry.id()})")
            result.success(resultMap)
        } catch (e: Throwable) {
            // 鍏抽敭锛氬繀椤绘崟鑾?Throwable 鑰岄潪 Exception銆?
            // MPVLib / MpvInitBridge 棣栨璁块棶浼氳Е鍙?object 鐨?init{} 闈欐€佸垵濮嬪寲閲岀殑
            // System.loadLibrary()锛?so 缂哄け/鍔犺浇澶辫触鎶涚殑鏄?UnsatisfiedLinkError /
            // ExceptionInInitializerError 鈥斺€?瀹冧滑缁ф壙 Error 鑰岄潪 Exception锛屼細缁曡繃
            // catch(Exception) 鐩存帴鍦ㄤ富绾跨▼鏈崟鑾?鈫?鏁翠釜 App 宕╂簝(鏃ュ織琛ㄧ幇涓?CRASH(JVM)銆?
            // 鏃㈡棤"鍒濆鍖栧畬鎴?涔熸棤"鍒濆鍖栧け璐?)銆傛崟鑾?Throwable 鍚庨檷绾т负鍙仮澶嶇殑閿欒锛?
            // 鎾斁椤垫寜缁熶竴鏂囨鎻愮ず锛屽苟鎶婄湡瀹炲師鍥犳姏鍥?Dart 钀藉叆鏃ュ織銆?
            android.util.Log.e(TAG, "createPlayer failed", e)
            try { MPVLib.destroy() } catch (_: Throwable) {}
            try { surfaceTextureEntry?.release() } catch (_: Throwable) {}
            try { players.clear() } catch (_: Throwable) {}
            // 甯︿笂鍘熺敓搴撳姞杞藉け璐ヨ鎯咃紙鑻ユ湁锛夛紝璁?Dart 鏃ュ織鐩存帴鐪嬪埌"鍝釜 .so銆佷负浣曞姞杞藉け璐?锛?
            // 鑰屼笉鏄彧鐪嬪埌涓嬫父鐨?"MPVLib.create 鏃犲疄鐜?銆?
            val libInfo = MPVLib.loadErrors.let { if (it.isEmpty()) "" else " nativeLibLoad=[$it]" }
            result.error(
                "CREATE_ERROR",
                "${e.javaClass.simpleName}: ${e.message}$libInfo",
                null
            )
        }
    }

    /**
     * 妫€娴嬭澶囨槸鍚︽敮鎸佹潨姣旇鐣屾樉绀?
     */
    private fun isDolbyVisionSupported(): Boolean {
        return try {
            val activity = context as? android.app.Activity ?: return false
            val display = activity.display ?: return false
            val hdrCapabilities = display.hdrCapabilities ?: return false
            val supportedHdrTypes = hdrCapabilities.supportedHdrTypes
            // Display.HdrCapabilities.DOLBY_VISION = 2
            supportedHdrTypes.contains(2)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "妫€娴嬫潨姣旇鐣屾敮鎸佸け璐? ${e.message}")
            false
        }
    }

    private fun setMpvOptions(
        hardwareDecoding: Boolean,
        useGpuNext: Boolean = false,
        httpProxy: String? = null,
        userAgent: String? = null,
        httpHeaders: Map<String, String>? = null,
        videoCacheDir: String? = null,
        diskCacheForwardBytes: Long = 0L,
        diskCacheBackBytes: Long = 0L,
    ) {
        // 鐢ㄦ埛鑷畾涔?HTTP 浠ｇ悊锛坢pv 涓嶆敮鎸?SOCKS锛孲OCKS 鍦烘櫙鍦?TV 涓婄粡 mihomo 鏈湴鍙ｄ腑杞級
        if (!httpProxy.isNullOrEmpty()) {
            MPVLib.setOptionString("http-proxy", httpProxy)
            android.util.Log.i(TAG, "mpv http-proxy enabled")
        }

        // 缁熶竴 UA锛氶儴鍒?CDN 鎷掔粷 mpv/libavformat 榛樿 UA 瀵艰嚧鍙栨祦澶辫触锛?03/绌哄搷搴旓級銆?
        if (!userAgent.isNullOrEmpty()) {
            MPVLib.setOptionString("user-agent", userAgent)
            android.util.Log.i(TAG, "mpv user-agent set: $userAgent")
        }

        // 閫愭祦 HTTP 澶达紙缃戠洏/鑱氬悎婧愮洿閾鹃渶 Cookie/Authorization/Referer锛夈€?
        // mpv 鐢?http-header-fields锛堥€楀彿鍒嗛殧鐨?"Key: Value"锛屼笉鍚?User-Agent锛夈€?
        if (!httpHeaders.isNullOrEmpty()) {
            val fields = httpHeaders.entries
                .filter { it.key.lowercase() != "user-agent" }
                .joinToString(",") { "${it.key}: ${it.value}" }
            if (fields.isNotEmpty()) {
                MPVLib.setOptionString("http-header-fields", fields)
                android.util.Log.i(TAG, "mpv http-header-fields set (${httpHeaders.size} headers)")
            }
        }

        // Video output - try gpu-next for better HDR/DV support, fallback to gpu if unavailable
        var actuallyUsingGpuNext = false
        if (useGpuNext) {
            try {
                MPVLib.setOptionString("vo", "gpu-next")
                actuallyUsingGpuNext = true
                android.util.Log.i(TAG, "Configured mpv for gpu-next rendering")
            } catch (e: Exception) {
                // gpu-next not available (requires Vulkan/libplacebo), fallback to gpu
                android.util.Log.w(TAG, "gpu-next not available, falling back to gpu: ${e.message}")
                MPVLib.setOptionString("vo", "gpu")
                android.util.Log.i(TAG, "Configured mpv for gpu rendering (fallback)")
            }
        } else {
            MPVLib.setOptionString("vo", "gpu")
            android.util.Log.i(TAG, "Configured mpv for gpu rendering")
        }

        // Common GPU settings
        MPVLib.setOptionString("gpu-context", "android")
        MPVLib.setOptionString("opengl-es", "yes")

        // HDR/鏉滄瘮瑙嗙晫璁剧疆
        MPVLib.setOptionString("target-colorspace-hint", "yes")

        if (actuallyUsingGpuNext) {
            // gpu-next 妯″紡锛歭ibplacebo 澶勭悊 DV RPU 鍏冩暟鎹紝姝ｇ‘鏄犲皠 IPT-PQ 鑹茬┖闂?
            MPVLib.setOptionString("dolby-vision-mode", "auto")
            MPVLib.setOptionString("tone-mapping", "spline")
            // hdr-compute-peak 鏄€愬抚 GPU 鐩存柟鍥撅紙compute shader锛夛紝鍦ㄧЩ鍔?GPU 涓婂紑閿€寰堝ぇ銆?
            // 杞В鏃?CPU 宸茶瑙ｇ爜鍚冩弧锛屽啀鍙犲姞 per-frame 宄板€兼娴嬩細璁╃敾闈㈡槑鏄惧崱椤匡紝鏁呰蒋瑙ｈ矾寰?
            // 鍏抽棴銆佹敼鐢ㄩ潤鎬佸厓鏁版嵁锛涚‖瑙ｆ湁 GPU 浣欓噺鏃朵繚鐣欎互姹傛洿鍑嗙殑鍔ㄦ€佽壊璋冩槧灏勩€?
            MPVLib.setOptionString("hdr-compute-peak", if (hardwareDecoding) "yes" else "no")
            android.util.Log.i(TAG, "DV: gpu-next mode, libplacebo handles DV RPU (compute-peak=$hardwareDecoding)")
        } else {
            // gpu 妯″紡锛氫笉澶勭悊 DV RPU锛岀敤 video filter 鍘婚櫎 DV 鏍囪閬垮厤缁垮睆
            MPVLib.setOptionString("vf", "format:dolbyvision=no")
            android.util.Log.i(TAG, "DV: gpu mode, stripping DV metadata via vf filter")
        }

        // Hardware decoding
        if (hardwareDecoding) {
            // 鐩蹭慨闂€€锛氬彧鐢?mediacodec-copy锛堟嫹璐濇ā寮忥級锛屼笉鍐嶄紭鍏?direct mediacodec銆?
            // direct mediacodec 鎶婅В鐮佸抚鐩存帴浜ょ粰 Android Surface锛岄渶瑕?vo 涓庤В鐮佸櫒鍏变韩
            // surface 骞惰蛋 AImageReader 鍙ユ焺锛屽湪閮ㄥ垎鏈哄瀷/缂栫爜涓婇甯ф彙鎵嬪け璐ヤ細鍘熺敓 SIGSEGV锛?
            // 鏄?姣忔鎾斁蹇呴棯閫€"鐨勫父瑙佹牴婧愩€俢opy 妯″紡鎶婂抚鎷峰洖 CPU 鍐嶈蛋 GL 涓婁紶锛岃嚜鍖呭惈銆?
            // 涓嶄緷璧?surface 鍙ユ焺浜ゆ帴锛岀ǔ瀹氬緱澶氾紱鎬ц兘鎹熷け瀵规祦寮忕洿杩炲彲蹇界暐銆傝В鐮佸け璐ユ椂 mpv
            // 浠嶄細鑷姩鍥為€€杞В銆?
            MPVLib.setOptionString("hwdec", "mediacodec-copy")
            MPVLib.setOptionString("hwdec-codecs",
                "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
        } else {
            MPVLib.setOptionString("hwdec", "no")
            // 杞В鎬ц兘浼樺寲锛?K HEVC/鏉滄瘮瑙嗙晫绾蒋瑙ｆ瀬鍚?CPU锛岄粯璁ら厤缃笅绉诲姩绔細涓ラ噸鍗￠】銆?
            // 鈶?瑙ｇ爜绾跨▼閾烘弧 CPU 鏍稿績鈥斺€攎pv 鐨?auto 鍦ㄩ儴鍒嗘満鍨嬪彧鐢ㄤ簡涓€鍗婃牳锛屾樉寮忕粰婊°€?
            val decodeThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 16)
            MPVLib.setOptionString("vd-lavc-threads", decodeThreads.toString())
            // 鈶?璺宠繃闈炲弬鑰冨抚鐨勭幆璺幓鍧楁护娉?+ 鍚敤蹇€?闈炰弗鏍煎悎瑙?瑙ｇ爜璺緞锛氱渷涓嬪彲瑙?CPU锛?
            //    鑲夌溂鍑犱箮鏃犳崯锛屾槸杞В鑳藉惁璺戝埌瀹炴椂甯х巼鐨勫叧閿€?
            MPVLib.setOptionString("vd-lavc-skiploopfilter", "nonref")
            MPVLib.setOptionString("vd-lavc-fast", "yes")
            // 鈶?瑙ｇ爜鍣ㄧ洿鎺ユ覆鏌擄紝鐪佷竴娆″抚鎷疯礉銆?
            MPVLib.setOptionString("vd-lavc-dr", "yes")
            // 鈶?浠嶈窡涓嶄笂瀹炴椂鏃跺厑璁稿湪 VO 涓㈠抚杩藉钩锛岄伩鍏嶉煶鐢讳笉鍚屾涓庢寔缁崱椤垮爢绉€?
            MPVLib.setOptionString("framedrop", "vo")
            android.util.Log.i(TAG, "Software decode tuned: threads=$decodeThreads, skiploopfilter=nonref, fast=yes")
        }

        // Audio output - 寮哄埗绔嬩綋澹伴檷娣凤紝瑙ｅ喅 TrueHD 绛夊澹伴亾闊抽鏃犲０闂
        MPVLib.setOptionString("ao", "audiotrack,opensles")
        MPVLib.setOptionString("audio-channels", "stereo")
        MPVLib.setOptionString("ad-lavc-downmix", "yes")
        // 绠€鍖栭煶棰戣繃婊ゅ櫒 - 绉婚櫎鍙兘瀵艰嚧闂鐨?pan filter
        // 璁?ad-lavc-downmix 鑷姩澶勭悊澶氬０閬撳埌绔嬩綋澹扮殑杞崲
        // MPVLib.setOptionString("af", "lavfi=[pan=stereo|c0=c2+0.30*c0+0.30*c4|c1=c2+0.30*c1+0.30*c5]")

        // Config
        MPVLib.setOptionString("config", "yes")
        val configDir = File(context.filesDir, "mpv")
        configDir.mkdirs()
        MPVLib.setOptionString("config-dir", configDir.absolutePath)

        // Idle and window management
        MPVLib.setOptionString("idle", "once")
        MPVLib.setOptionString("force-window", "no")

        // Subtitles
        MPVLib.setOptionString("sub-visibility", "yes")
        // 瀛楀箷璧?OSD 瑕嗙洊灞傛覆鏌擄紝涓嶆贩鍏ヨ棰戝抚銆俠lend-subtitles=video 浼氳
        // PGS/SUP 浣嶅浘瀛楀箷姣忔鍒锋柊閮介噸缁樻暣甯э紝閫犳垚瑙嗛鐢婚潰闂幇銆?
        MPVLib.setOptionString("blend-subtitles", "no")
        MPVLib.setOptionString("sub-auto", "all")
        MPVLib.setOptionString("sub-ass", "yes")
        MPVLib.setOptionString("sub-codepage", "utf-8")
        // 鍏抽敭锛欰ndroid 涓?libass 娌℃湁 fontconfig锛屽繀椤绘樉寮忕粰瀛椾綋鐩綍锛屽惁鍒欏唴灏?澶栨寕鐨?
        // 鏂囨湰瀛楀箷(SRT/ASS)鍥犳壘涓嶅埌浠讳綍瀛椾綋鑰屾暣娈典笉娓叉煋鈥斺€旇〃鐜颁负"閫変簡瀛楀箷涔熶笉鏄剧ず"銆?
        // 鎸囧悜绯荤粺瀛椾綋鐩綍锛宭ibass 鍙壂鎻忓埌 NotoSansCJK / DroidSansFallback 绛変腑鏂囧瓧浣撳苟
        // 鍦ㄨ姹傜殑瀛椾綋鍚嶇己澶辨椂鍥為€€鍒板彲鐢ㄥ瓧浣擄紙浣嶅浘 PGS/SUP 涓嶄緷璧栧瓧浣擄紝鏈氨涓嶅彈褰卞搷锛夈€?
        MPVLib.setOptionString("sub-fonts-dir", "/system/fonts")

        // Cache
        // 缃戠粶鎾斁锛氭寜鐢ㄦ埛璁剧疆锛?00MB鈥?GB锛夋妸缂撳啿钀藉埌纾佺洏锛岄伩鍏嶅ぇ缂撳啿鍗犳弧鍐呭瓨瀵艰嚧
        // 浣庨厤鏈?TV OOM 闂€€銆倂ideoCacheDir 涓虹┖锛堟湰鍦版枃浠讹級鏃堕€€鍥炲皬棰濆唴瀛樼紦鍐插嵆鍙€?
        if (!videoCacheDir.isNullOrEmpty() && diskCacheForwardBytes > 0L) {
            File(videoCacheDir).mkdirs()
            MPVLib.setOptionString("cache", "yes")
            MPVLib.setOptionString("cache-on-disk", "yes")
            MPVLib.setOptionString("cache-dir", videoCacheDir)
            MPVLib.setOptionString("demuxer-max-bytes", diskCacheForwardBytes.toString())
            MPVLib.setOptionString("demuxer-max-back-bytes", diskCacheBackBytes.toString())
            MPVLib.setOptionString("demuxer-readahead-secs", "180")
            // L1 棰勯槻灞傦細缃戠粶鎺夌嚎鏃?libavformat 閫忔槑閲嶈繛(杩炲綋鍓?URL)锛岀灛鏂湪缂撳啿鍖哄唴娑堝寲銆?
            // 鍙紑 reconnect_on_network_error锛屼笉寮€ http_error鈥斺€旂綉鐩?302 杩囨湡鐨?4xx/5xx 瑕?
            // 涓婃姏浜ょ粰 Dart 灞?L2 閲嶈В鏋愰噸绛撅紝涓嶈兘璁?ffmpeg 姝荤杩囨湡閾炬妸閿欒鍚炴帀銆?
            MPVLib.setOptionString("stream-lavf-o",
                "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=30")
            android.util.Log.i(TAG, "mpv disk cache: dir=$videoCacheDir fwd=$diskCacheForwardBytes back=$diskCacheBackBytes")
        } else {
            // 鏈湴鏂囦欢锛氭棤闇€澶х紦鍐诧紝娌跨敤灏忛鍐呭瓨缂撳啿銆?
            MPVLib.setOptionString("demuxer-max-bytes", "64MiB")
            MPVLib.setOptionString("demuxer-max-back-bytes", "32MiB")
        }

        // TLS
        val cacert = File(context.filesDir, "cacert.pem")
        if (cacert.exists()) {
            MPVLib.setOptionString("tls-verify", "yes")
            MPVLib.setOptionString("tls-ca-file", cacert.absolutePath)
        } else {
            MPVLib.setOptionString("tls-verify", "no")
            android.util.Log.w(TAG, "cacert.pem not found, disabling TLS verification")
        }

        // Misc
        MPVLib.setOptionString("save-position-on-quit", "no")
        MPVLib.setOptionString("msg-level", "all=v")
    }

    private fun getPlayer(playerId: String): MpvPlayerInstance? = players[playerId]

    private fun disposePlayer(playerId: String) {
        mainHandler.post {
            players.remove(playerId)?.release()
        }
    }

    fun disposeAll() {
        mainHandler.post {
            players.values.forEach { it.release() }
            players.clear()
        }
    }

    /**
     * Represents a single mpv player instance.
     * Implements MPVLib.EventObserver to receive property change callbacks
     * from the native event thread and forwards them to Flutter via EventChannel.
     */
    class MpvPlayerInstance(
        val playerId: String,
        private val context: Context,
        private val surface: Surface,
        private val mpvTexture: MpvTexture?,  // Nullable when using SurfaceView
        private val eventChannel: EventChannel,
        private val mainHandler: Handler
    ) : MPVLib.EventObserver, MPVLib.LogObserver {

        private var eventSink: EventChannel.EventSink? = null
        private var currentTracks: List<Map<String, Any>> = emptyList()

        init {
            eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }

        // ---- Playback control ----

        fun play() {
            android.util.Log.i(TAG, "play() - setting pause=false")
            MPVLib.setPropertyBoolean("pause", false)
        }

        fun pause() {
            android.util.Log.i(TAG, "pause() - setting pause=true")
            MPVLib.setPropertyBoolean("pause", true)
        }

        fun seekTo(positionMs: Int) {
            MPVLib.command(arrayOf("seek", "${positionMs / 1000.0}", "absolute"))
        }

        fun reload(videoUrl: String, startPositionMs: Int) {
            // L2 鍘熷湴閲嶈浇锛氫笌 createPlayer 鐨勫姞杞介€昏緫涓€鑷粹€斺€斿厛鐢?start 灞炴€у畾浣嶅啀 loadfile
            // replace锛岄伩鍏?loadfile 鍚庣珛鍒?seek 钀界┖鐨勭珵鎬併€傜綉缁?缂撳瓨/閲嶈繛绛?mpv 閫夐」宸插湪
            // createPlayer 鏃跺啓鍏ュ悓涓€ mpv 涓婁笅鏂囷紝閲嶈浇鏃犻渶閲嶈锛岀洿鎺ュ鐢ㄣ€?
            if (startPositionMs > 0) {
                MPVLib.setPropertyString("start", "${startPositionMs / 1000.0}")
            } else {
                MPVLib.setPropertyString("start", "none")
            }
            MPVLib.command(arrayOf("loadfile", videoUrl, "replace"))
            android.util.Log.i(TAG, "reload: loadfile replace from ${startPositionMs / 1000.0}s")
        }

        fun setSpeed(speed: Double) {
            MPVLib.setPropertyDouble("speed", speed.coerceIn(0.25, 8.0))
        }

        fun setVolume(volume: Double) {
            // mpv volume range is 0-100, Flutter passes 0.0-1.0
            MPVLib.setPropertyDouble("volume", (volume * 100).coerceIn(0.0, 100.0))
        }

        fun getPosition(): Int {
            val pos = MPVLib.getPropertyDouble("time-pos") ?: return 0
            return (pos * 1000).toInt()
        }

        fun getDuration(): Int {
            val dur = MPVLib.getPropertyDouble("duration") ?: return 0
            return (dur * 1000).toInt().coerceAtLeast(0)
        }

        fun getVideoSize(): Map<String, Int> {
            val w = MPVLib.getPropertyInt("video-params/w") ?: 0
            val h = MPVLib.getPropertyInt("video-params/h") ?: 0
            return mapOf("width" to w, "height" to h)
        }

        // ---- Track management ----

        fun getTracksInfo(): List<Map<String, Any>> = currentTracks

        fun selectSubtitleTrack(trackId: String) {
            MPVLib.command(arrayOf("set_property", "sid", trackId))
        }

        fun deselectSubtitleTrack() {
            MPVLib.command(arrayOf("set_property", "sid", "no"))
        }

        fun selectAudioTrack(trackId: String) {
            MPVLib.setPropertyString("aid", trackId)
        }

        fun loadSubtitle(subtitleUrl: String, language: String) {
            MPVLib.command(arrayOf("sub-add", subtitleUrl, "auto", "external-sub", language))
        }

        // ---- Property access ----

        fun setProperty(name: String, value: String) {
            MPVLib.setPropertyString(name, value)
        }

        fun getProperty(name: String): String? {
            return MPVLib.getPropertyString(name)
        }

        fun getPropertyDouble(name: String): Double? {
            return MPVLib.getPropertyDouble(name)
        }

        fun command(args: Array<out String>) {
            MPVLib.command(args)
        }

        // ---- Screenshot ----

        fun screenshot(): ByteArray? {
            // 浼樺厛鐢?mpv 鍘熺敓 screenshot-to-file 鎴€寁ideo銆嶅抚锛氭寜鐗囨簮鍘熷鍒嗚鲸鐜囪緭鍑恒€?
            // 瀹介珮姣旀纭€佸畬鏁存棤瑁佸垏銆俫rabThumbnail(1920) 浼氭寜鍥哄畾杈归暱缂╂斁锛屽鑷?
            // 鎴浘姣斾緥澶辩湡 / 鎴笉鍏紙鐢ㄦ埛鍙嶉鐨勬牳蹇冮棶棰橈級锛屼粎浣滃厹搴曘€?
            try {
                val tmp = java.io.File(
                    context.cacheDir,
                    "mpv_shot_${System.currentTimeMillis()}.jpg"
                )
                // 绗笁鍙傛暟 "video"锛氬彧鎴В鐮佸悗鐨勮棰戝抚锛堜笉鍚?OSD/瀛楀箷锛夛紝鍘熷鍒嗚鲸鐜囥€?
                MPVLib.command(arrayOf("screenshot-to-file", tmp.absolutePath, "video"))
                if (tmp.exists() && tmp.length() > 0L) {
                    val bytes = tmp.readBytes()
                    tmp.delete()
                    return bytes
                }
                if (tmp.exists()) tmp.delete()
            } catch (e: Exception) {
                android.util.Log.w(
                    "MpvScreenshot",
                    "screenshot-to-file 澶辫触锛屽洖閫€ grabThumbnail: ${e.message}"
                )
            }
            val bitmap = MPVLib.grabThumbnail(1920) ?: return null
            val stream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, stream)
            bitmap.recycle()
            return stream.toByteArray()
        }

        // ---- Aspect ratio ----

        fun setAspectRatio(ratio: String) {
            // 鍘熺敓 mpv 鍦ㄥ睆骞曞ぇ灏忕殑 surface 閲岃嚜琛屽仛缂╂斁/letterbox锛屾晠姣斾緥鐢?mpv 灞炴€ф帶鍒讹細
            // video-aspect-override 鏀规樉绀哄楂樻瘮锛沰eepaspect=no 鍙樺舰鎷変几閾烘弧锛沺anscan=1 淇濇寔
            // 姣斾緥鏀惧ぇ瑁佸垏閾烘弧銆傛瘡涓ā寮忛兘鎶婂彟澶栦袱椤瑰浣嶏紝閬垮厤涓婃妯″紡娈嬬暀銆?
            when (ratio) {
                "16:9" -> applyAspect(override = "16:9")
                "4:3" -> applyAspect(override = "4:3")
                "21:9" -> applyAspect(override = "21:9")
                "鍘熷" -> applyAspect(override = "0") // 鐢ㄧ墖婧愬師濮嬫瘮渚?
                "鎷変几" -> applyAspect(override = "-1", keepAspect = false) // 鍙樺舰閾烘弧
                "閾烘弧" -> applyAspect(override = "-1", panscan = 1.0) // 瑁佸垏閾烘弧
                else -> applyAspect(override = "-1") // 鑷€傚簲 / 鑷姩
            }
        }

        private fun applyAspect(
            override: String,
            keepAspect: Boolean = true,
            panscan: Double = 0.0,
        ) {
            try {
                MPVLib.setPropertyBoolean("keepaspect", keepAspect)
                MPVLib.setPropertyDouble("panscan", panscan)
                MPVLib.setPropertyString("video-aspect-override", override)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "applyAspect failed: ${e.message}")
            }
        }

        // ---- Release ----

        fun release() {
            MPVLib.removeObserver(this)
            MPVLib.removeLogObserver(this)

            // Detach surface from mpv (stops video rendering)
            try {
                MPVLib.setPropertyBoolean("force-window", false)
                MPVLib.detachSurface()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "detachSurface failed", e)
            }

            // Destroy mpv context
            try {
                MPVLib.destroy()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "MPVLib.destroy() failed", e)
            }

            // Release surface and Flutter texture
            // Note: When using SurfaceView, surface.release() is not needed
            // as the SurfaceView manages its own surface lifecycle
            try {
                surface.release()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "surface.release() failed (may be SurfaceView)", e)
            }
            mpvTexture?.dispose()
            eventSink = null
        }

        // ---- EventObserver implementation ----

        override fun eventProperty(property: String) {
            // NONE format 鈥?just a notification that the property changed
            // We'll handle it when the typed value arrives
        }

        override fun eventProperty(property: String, value: Long) {
            when (property) {
                "video-params/w", "video-params/h" -> {
                    emitVideoSize()
                }
            }
        }

        override fun eventProperty(property: String, value: Boolean) {
            android.util.Log.v(TAG, "property[$property] = $value")
            when (property) {
                "pause" -> emitEvent("playing", !value)
                "paused-for-cache" -> emitEvent("buffering", value)
                // 涓嶅啀鐢?eof-reached / idle-active 灞炴€ф帹鏂?鎾斁瀹屾垚"銆?
                // seek锛堝挨鍏跺悜鍓?seek锛夋垨缂撳啿鏋鏃?mpv 浼氭妸 eof-reached 鐬椂缃?true锛?
                // 鐢ㄥ畠鍙?completed 浼氳涓婂眰褰撴垚"鎾斁缁撴潫"鈫掑仠姝㈡挱鏀俱€佺敾闈㈡秷澶便€佽繘搴︽潯鍋滃湪
                // seek 鐐癸紝姝ｆ槸"閲嶆柊 seek 缁挱鍚庢病鐢婚潰"鐨勬牴鍥犮€傜湡姝ｇ殑缁撴潫鍙 END_FILE 浜嬩欢銆?
            }
        }

        override fun eventProperty(property: String, value: String) {
            when (property) {
                "hwdec-current" -> {
                    // Available for stats
                }
            }
        }

        override fun eventProperty(property: String, value: Double) {
            android.util.Log.v(TAG, "property[$property] = $value")
            when (property) {
                "time-pos" -> emitEvent("timePos", (value * 1000).toLong())
                "duration" -> emitEvent("duration", (value * 1000).toLong())
                "speed" -> emitEvent("speed", value)
                "volume" -> emitEvent("volume", value / 100.0) // normalize to 0-1
            }
        }

        // ---- LogObserver implementation ----

        // mpv 鑷韩鐨勬棩蹇楋紙鏉ヨ嚜 libmpv锛岀粡 libplayer.so 鍥炶皟锛夈€傚師鏈棤浜鸿闃咃紝瀵艰嚧
        // 鍘熺敓宕╂簝鍓嶇殑銆屾渶鍚庨仐瑷€銆嶅叏閮ㄤ涪澶便€佺敤鎴峰鍑虹殑鏃ュ織閲屼粈涔堥兘娌℃湁銆傝繖閲岃闃呭苟鎶?
        // 璀﹀憡/閿欒/鑷村懡绾у埆杞彂鍒?Flutter 渚?AppLogger 钀界洏锛屼究浜庡穿婧冨悗鍙栬瘉銆?
        // mpv 绾у埆锛欶ATAL=10 ERROR=20 WARN=30 INFO=40 V=50 DEBUG=60 TRACE=70锛屾暟瀛楄秺灏忚秺涓ラ噸銆?
        override fun logMessage(prefix: String, level: Int, text: String) {
            if (level > MPVLib.MpvLogLevel.WARN) return // 浠呰浆鍙?warn/error/fatal锛岄伩鍏嶅埛灞?
            val trimmed = text.trimEnd()
            if (trimmed.isEmpty()) return
            emitEvent(
                "log",
                mapOf("level" to level, "prefix" to prefix, "text" to trimmed)
            )
        }

        override fun event(eventId: Int) {
            android.util.Log.d(TAG, "mpv event: $eventId")
            when (eventId) {
                MPVLib.MpvEvent.START_FILE -> {
                    android.util.Log.i(TAG, "START_FILE")
                }
                MPVLib.MpvEvent.FILE_LOADED -> {
                    android.util.Log.i(TAG, "FILE_LOADED 鈥?emitting tracks and duration")
                    emitEvent("buffering", false)
                    loadTracks()

                    // 璇婃柇鏃ュ織锛氭鏌ュ綋鍓嶉煶棰戝拰瀛楀箷鐘舵€?
                    val audioCodec = MPVLib.getPropertyString("audio-codec")
                    val audioCodecName = MPVLib.getPropertyString("audio-codec-name")
                    val currentAid = MPVLib.getPropertyInt("aid")
                    val currentSid = MPVLib.getPropertyInt("sid")
                    val subVisibility = MPVLib.getPropertyBoolean("sub-visibility")
                    val audioChannels = MPVLib.getPropertyString("audio-channels")
                    android.util.Log.i(TAG, "FILE_LOADED diagnostics:")
                    android.util.Log.i(TAG, "  audio-codec: $audioCodec")
                    android.util.Log.i(TAG, "  audio-codec-name: $audioCodecName")
                    android.util.Log.i(TAG, "  current aid: $currentAid")
                    android.util.Log.i(TAG, "  current sid: $currentSid")
                    android.util.Log.i(TAG, "  sub-visibility: $subVisibility")
                    android.util.Log.i(TAG, "  audio-channels: $audioChannels")

                    // 妫€鏌ヨВ鐮佸櫒鍒楄〃
                    val decoderList = MPVLib.getPropertyString("decoder-list")
                    if (decoderList != null) {
                        val hasTruehd = decoderList.contains("truehd", ignoreCase = true)
                        val hasSubrip = decoderList.contains("subrip", ignoreCase = true)
                        val hasSrt = decoderList.contains("srt", ignoreCase = true)
                        val hasAss = decoderList.contains("ass", ignoreCase = true)
                        android.util.Log.i(TAG, "  decoder-list contains truehd: $hasTruehd")
                        android.util.Log.i(TAG, "  decoder-list contains subrip: $hasSubrip")
                        android.util.Log.i(TAG, "  decoder-list contains srt: $hasSrt")
                        android.util.Log.i(TAG, "  decoder-list contains ass: $hasAss")
                        // 鎵撳嵃鍓?00瀛楃鐨勮В鐮佸櫒鍒楄〃
                        android.util.Log.i(TAG, "  decoder-list (first 500): ${decoderList.take(500)}")
                    }

                    val dur = MPVLib.getPropertyDouble("duration")
                    if (dur != null && dur > 0) {
                        emitEvent("duration", (dur * 1000).toLong())
                    }
                }
                MPVLib.MpvEvent.END_FILE -> {
                    android.util.Log.i(TAG, "END_FILE 鈥?emitting completed")
                    val reason = MPVLib.getPropertyInt("eof-reached")
                    emitEvent("completed", true)
                }
                MPVLib.MpvEvent.VIDEO_RECONFIG -> {
                    emitVideoSize()
                }
            }
        }

        // ---- Track parsing ----

        private fun loadTracks() {
            try {
                val count = MPVLib.getPropertyInt("track-list/count") ?: 0
                val trackList = mutableListOf<Map<String, Any>>()

                for (i in 0 until count) {
                    val type = MPVLib.getPropertyString("track-list/$i/type") ?: continue
                    val id = MPVLib.getPropertyInt("track-list/$i/id") ?: continue
                    val lang = MPVLib.getPropertyString("track-list/$i/lang") ?: ""
                    val title = MPVLib.getPropertyString("track-list/$i/title") ?: ""
                    val codec = MPVLib.getPropertyString("track-list/$i/codec") ?: ""
                    val selected = MPVLib.getPropertyBoolean("track-list/$i/selected") ?: false

                    val resolvedType = when (type) {
                        "video" -> "video"
                        "audio" -> "audio"
                        "sub" -> {
                            // Detect bitmap subtitles by codec
                            if (codec.contains("pgs", ignoreCase = true) ||
                                codec.contains("hdmv", ignoreCase = true) ||
                                codec.contains("dvd_subtitle", ignoreCase = true)) {
                                "bitmap"
                            } else {
                                "text"
                            }
                        }
                        else -> type
                    }

                    val isAss = codec.contains("ass", ignoreCase = true) ||
                            codec.contains("ssa", ignoreCase = true)

                    trackList.add(mapOf(
                        "id" to id.toString(),
                        "type" to resolvedType,
                        "language" to lang,
                        "label" to title,
                        "codec" to codec,
                        "isAss" to isAss,
                        "isBitmap" to (resolvedType == "bitmap"),
                        "isSelected" to selected
                    ))
                }

                currentTracks = trackList
                emitEvent("tracksChanged", trackList)
            } catch (e: Exception) {
                android.util.Log.e(TAG, "loadTracks failed", e)
            }
        }

        private fun emitVideoSize() {
            val w = MPVLib.getPropertyInt("video-params/w") ?: return
            val h = MPVLib.getPropertyInt("video-params/h") ?: return
            if (w > 0 && h > 0) {
                // Don't update SurfaceTexture buffer 鈥?let mpv handle aspect ratio
                // and letterboxing internally at the surface's native dimensions
                emitEvent("videoSize", mapOf("width" to w, "height" to h))
            }
        }

        private fun emitEvent(type: String, value: Any?) {
            mainHandler.post {
                eventSink?.success(mapOf("type" to type, "value" to value))
            }
        }
    }
}
