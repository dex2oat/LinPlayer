package com.example.linplayer_mobile

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * ExoPlayer Platform Channel 插件
 *
 * 通过 Flutter TextureRegistry + SurfaceTexture 实现视频渲染，
 * 所有播放控制通过 MethodChannel 下发，状态通过 EventChannel 上报。
 * 字幕通过 TextOutput 获取 Cue，推送给 Dart 层渲染。
 */
class ExoPlayerPlugin(
    private val context: Context,
    private val binaryMessenger: io.flutter.plugin.common.BinaryMessenger,
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "com.linplayer/exoplayer"

        fun registerWith(engine: FlutterEngine, context: Context) {
            val plugin = ExoPlayerPlugin(
                context,
                engine.dartExecutor.binaryMessenger,
                engine.renderer
            )
            MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
                .setMethodCallHandler(plugin)
        }
    }

    private val players = ConcurrentHashMap<String, ExoPlayerInstance>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createPlayer" -> {
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Int>("startPositionMs") ?: 0
                val dolbyVisionFix = call.argument<Boolean>("dolbyVisionFix") ?: false
                createPlayer(videoUrl, startPositionMs, dolbyVisionFix, result)
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
                val positionMs = call.argument<Int>("positionMs") ?: 0
                getPlayer(playerId)?.seekTo(positionMs.toLong())
                result.success(true)
            }
            "setSpeed" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val speed = call.argument<Double>("speed") ?: 1.0
                getPlayer(playerId)?.setSpeed(speed.toFloat())
                result.success(true)
            }
            "setVolume" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val volume = call.argument<Double>("volume") ?: 1.0
                getPlayer(playerId)?.setVolume(volume.toFloat())
                result.success(true)
            }
            "getPosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val pos = getPlayer(playerId)?.currentPosition?.toInt() ?: 0
                result.success(pos)
            }
            "getDuration" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val dur = getPlayer(playerId)?.duration?.toInt() ?: 0
                result.success(if (dur > 0) dur else 0)
            }
            "screenshot" -> {
                result.success(null)
            }
            "setSubtitleDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setSubtitleDelay(seconds)
                result.success(true)
            }
            "setAudioDelay" -> {
                // ExoPlayer 不支持音频延迟，忽略
                result.success(true)
            }
            "setSubtitleFont" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val fontName = call.argument<String>("fontName") ?: ""
                getPlayer(playerId)?.setSubtitleFont(fontName)
                result.success(true)
            }
            "setSubtitleSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = call.argument<Double>("size") ?: 0.5
                getPlayer(playerId)?.setSubtitleSize(size)
                result.success(true)
            }
            "setSubtitlePosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val position = call.argument<Double>("position") ?: 0.5
                getPlayer(playerId)?.setSubtitlePosition(position)
                result.success(true)
            }
            "setAspectRatio" -> {
                result.success(true)
            }
            "disposePlayer" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                disposePlayer(playerId)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(
        videoUrl: String,
        startPositionMs: Int,
        dolbyVisionFix: Boolean,
        result: MethodChannel.Result
    ) {
        mainHandler.post {
            try {
                val playerId = UUID.randomUUID().toString()

                val surfaceTextureEntry = textureRegistry.createSurfaceTexture()
                val surfaceTexture = surfaceTextureEntry.surfaceTexture()
                val surface = Surface(surfaceTexture)

                val exoPlayer = ExoPlayer.Builder(context).build()
                exoPlayer.setVideoSurface(surface)

                val mediaItem = MediaItem.fromUri(Uri.parse(videoUrl))
                exoPlayer.setMediaItem(mediaItem)
                exoPlayer.prepare()

                if (startPositionMs > 0) {
                    exoPlayer.seekTo(startPositionMs.toLong())
                }

                val eventChannel = EventChannel(
                    binaryMessenger,
                    "com.linplayer/exoplayer/events/$playerId"
                )

                val instance = ExoPlayerInstance(
                    playerId = playerId,
                    exoPlayer = exoPlayer,
                    surfaceTextureEntry = surfaceTextureEntry,
                    surface = surface,
                    eventChannel = eventChannel,
                )

                exoPlayer.addListener(instance)
                players[playerId] = instance

                result.success(mapOf(
                    "playerId" to playerId,
                    "textureId" to surfaceTextureEntry.id()
                ))
            } catch (e: Exception) {
                result.error("CREATE_ERROR", e.message, null)
            }
        }
    }

    private fun getPlayer(playerId: String): ExoPlayerInstance? = players[playerId]

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

    class ExoPlayerInstance(
        val playerId: String,
        val exoPlayer: ExoPlayer,
        val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        private val eventChannel: EventChannel,
    ) : Player.Listener {

        private var eventSink: EventChannel.EventSink? = null
        private val instanceHandler = Handler(Looper.getMainLooper())

        // 字幕设置
        private var subtitleDelayMs: Long = 0
        private var subtitleFont: String = ""
        private var subtitleSize: Double = 0.5
        private var subtitlePosition: Double = 0.5

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

        fun play() = exoPlayer.play()
        fun pause() = exoPlayer.pause()
        fun seekTo(positionMs: Long) = exoPlayer.seekTo(positionMs)
        fun setSpeed(speed: Float) {
            exoPlayer.playbackParameters = PlaybackParameters(speed)
        }
        fun setVolume(volume: Float) {
            exoPlayer.volume = volume
        }

        fun setSubtitleDelay(seconds: Double) {
            subtitleDelayMs = (seconds * 1000).toLong()
            emitEvent("subtitleDelayChanged", seconds)
        }

        fun setSubtitleFont(fontName: String) {
            subtitleFont = fontName
            emitEvent("subtitleFontChanged", fontName)
        }

        fun setSubtitleSize(size: Double) {
            subtitleSize = size
            emitEvent("subtitleSizeChanged", size)
        }

        fun setSubtitlePosition(position: Double) {
            subtitlePosition = position
            emitEvent("subtitlePositionChanged", position)
        }

        val currentPosition: Long get() = exoPlayer.currentPosition
        val duration: Long get() = exoPlayer.duration

        fun release() {
            exoPlayer.removeListener(this)
            exoPlayer.release()
            surface.release()
            surfaceTextureEntry.release()
            eventSink = null
        }

        private fun emitEvent(type: String, value: Any?) {
            instanceHandler.post {
                eventSink?.success(mapOf("type" to type, "value" to value))
            }
        }

        // 提取字幕纯文本
        private fun extractCueText(cues: List<Cue>): String {
            return cues.mapNotNull { cue ->
                cue.text?.toString()
            }.joinToString("\n")
        }

        override fun onCues(cues: List<Cue>) {
            val text = extractCueText(cues)
            emitEvent("subtitle", text)
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_BUFFERING -> emitEvent("buffering", true)
                Player.STATE_READY -> {
                    emitEvent("buffering", false)
                    emitEvent("duration", exoPlayer.duration.toInt())
                }
                Player.STATE_ENDED -> emitEvent("completed", true)
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emitEvent("playing", isPlaying)
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                surfaceTextureEntry.surfaceTexture().setDefaultBufferSize(
                    videoSize.width, videoSize.height
                )
            }
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            emitEvent("error", error.message)
        }
    }
}
