package com.example.linplayer_mobile

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@OptIn(UnstableApi::class)
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

        fun detectMimeType(url: String): String {
            val lower = url.lowercase()
            return when {
                lower.endsWith(".srt") -> MimeTypes.APPLICATION_SUBRIP
                lower.endsWith(".ass") || lower.endsWith(".ssa") -> MimeTypes.TEXT_SSA
                lower.endsWith(".vtt") -> MimeTypes.TEXT_VTT
                lower.endsWith(".ttml") || lower.endsWith(".xml") || lower.endsWith(".dfxp") -> MimeTypes.APPLICATION_TTML
                lower.endsWith(".pgs") || lower.endsWith(".sup") -> MimeTypes.APPLICATION_PGS
                else -> MimeTypes.APPLICATION_SUBRIP
            }
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
                val preferredSubtitleLanguage = call.argument<String>("preferredSubtitleLanguage")
                createPlayer(videoUrl, startPositionMs, dolbyVisionFix, preferredSubtitleLanguage, result)
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
            "getTracks" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val tracks = getPlayer(playerId)?.getTracksInfo()
                result.success(tracks)
            }
            "selectTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val groupIndex = call.argument<Int>("groupIndex") ?: 0
                val trackIndex = call.argument<Int>("trackIndex") ?: 0
                val trackType = call.argument<Int>("trackType") ?: C.TRACK_TYPE_TEXT
                getPlayer(playerId)?.selectTrack(groupIndex, trackIndex, trackType)
                result.success(true)
            }
            "deselectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.deselectSubtitleTrack()
                result.success(true)
            }
            "loadSubtitle" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val subtitleUrl = call.argument<String>("subtitleUrl") ?: ""
                val subtitleMimeType = call.argument<String>("subtitleMimeType")
                val subtitleLanguage = call.argument<String>("subtitleLanguage")
                getPlayer(playerId)?.loadSubtitle(subtitleUrl, subtitleMimeType, subtitleLanguage)
                result.success(true)
            }
            "screenshot" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.screenshot(result)
            }
            "setSubtitleDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setSubtitleDelay(seconds)
                result.success(true)
            }
            "setAudioDelay" -> {
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
            "setSubtitleBackground" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: false
                getPlayer(playerId)?.setSubtitleBackground(enabled)
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
        preferredSubtitleLanguage: String?,
        result: MethodChannel.Result
    ) {
        mainHandler.post {
            try {
                val playerId = UUID.randomUUID().toString()

                val surfaceTextureEntry = textureRegistry.createSurfaceTexture()
                val surfaceTexture = surfaceTextureEntry.surfaceTexture()
                val surface = Surface(surfaceTexture)

                val trackSelector = DefaultTrackSelector(context)
                val paramsBuilder = trackSelector.buildUponParameters()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    .setSelectUndeterminedTextLanguage(true)

                if (!preferredSubtitleLanguage.isNullOrEmpty()) {
                    paramsBuilder.setPreferredTextLanguage(preferredSubtitleLanguage)
                }
                trackSelector.parameters = paramsBuilder.build()

                val renderersFactory = DefaultRenderersFactory(context)
                    .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)

                val exoPlayer = ExoPlayer.Builder(context)
                    .setTrackSelector(trackSelector)
                    .setRenderersFactory(renderersFactory)
                    .build()
                exoPlayer.setVideoSurface(surface)

                val mediaItem = MediaItem.Builder()
                    .setUri(videoUrl)
                    .build()
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
                    trackSelector = trackSelector,
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

    @OptIn(UnstableApi::class)
    class ExoPlayerInstance(
        val playerId: String,
        val exoPlayer: ExoPlayer,
        val trackSelector: DefaultTrackSelector,
        val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        private val eventChannel: EventChannel,
    ) : Player.Listener {

        private var eventSink: EventChannel.EventSink? = null
        private val instanceHandler = Handler(Looper.getMainLooper())

        private var subtitleDelayMs: Long = 0
        private var externalSubtitles: MutableList<MediaItem.SubtitleConfiguration> = mutableListOf()

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
        }

        fun setSubtitleFont(fontName: String) {}

        fun setSubtitleSize(size: Double) {}

        fun setSubtitlePosition(position: Double) {}

        fun setSubtitleBackground(enabled: Boolean) {}

        fun getTracksInfo(): List<Map<String, Any>> {
            return currentTracks
        }

        fun selectTrack(groupIndex: Int, trackIndex: Int, trackType: Int) {
            val tracks = exoPlayer.currentTracks
            if (groupIndex < tracks.groups.size) {
                val group = tracks.groups[groupIndex]
                if (group.type == trackType && trackIndex < group.length) {
                    val trackSelection = TrackSelectionOverride(group.mediaTrackGroup, listOf(trackIndex))
                    val paramsBuilder = trackSelector.buildUponParameters()
                    paramsBuilder.setOverrideForType(trackSelection)
                    if (trackType == C.TRACK_TYPE_TEXT) {
                        paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    }
                    trackSelector.parameters = paramsBuilder.build()
                }
            }
        }

        fun deselectSubtitleTrack() {
            val paramsBuilder = trackSelector.buildUponParameters()
            paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            trackSelector.parameters = paramsBuilder.build()
        }

        fun loadSubtitle(subtitleUrl: String, subtitleMimeType: String?, subtitleLanguage: String?) {
            val lowerUrl = subtitleUrl.lowercase()
            val isGraphicalSubtitle = lowerUrl.endsWith(".pgs") || lowerUrl.endsWith(".sup")
            if (isGraphicalSubtitle) {
                emitEvent("error", "PGS/SUP subtitles require FFmpeg extension. Please switch to MPV kernel.")
                return
            }

            val mimeType = subtitleMimeType ?: Companion.detectMimeType(subtitleUrl)
            val subtitleConfig = MediaItem.SubtitleConfiguration.Builder(Uri.parse(subtitleUrl))
                .setMimeType(mimeType)
                .setLanguage(subtitleLanguage)
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .build()

            externalSubtitles.add(subtitleConfig)

            val currentMediaItem = exoPlayer.currentMediaItem
            if (currentMediaItem != null) {
                val allSubtitles = currentMediaItem.localConfiguration?.subtitleConfigurations?.toMutableList() ?: mutableListOf()
                allSubtitles.add(subtitleConfig)

                val currentPosition = exoPlayer.currentPosition
                val playWhenReady = exoPlayer.playWhenReady

                val newMediaItem = currentMediaItem.buildUpon()
                    .setSubtitleConfigurations(allSubtitles)
                    .build()

                exoPlayer.playWhenReady = playWhenReady
                exoPlayer.setMediaItem(newMediaItem, currentPosition)
                exoPlayer.prepare()
            }
        }

        fun screenshot(result: MethodChannel.Result) {
            try {
                val width = exoPlayer.videoSize.width
                val height = exoPlayer.videoSize.height
                if (width <= 0 || height <= 0) {
                    result.success(null)
                    return
                }

                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                val latch = CountDownLatch(1)
                var copyResult = false

                android.view.PixelCopy.request(
                    surface,
                    bitmap,
                    { copyResultCode ->
                        copyResult = copyResultCode == android.view.PixelCopy.SUCCESS
                        latch.countDown()
                    },
                    instanceHandler
                )

                Thread {
                    latch.await(2, TimeUnit.SECONDS)
                    if (copyResult) {
                        val stream = java.io.ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                        val bytes = stream.toByteArray()
                        bitmap.recycle()
                        instanceHandler.post {
                            result.success(bytes)
                        }
                    } else {
                        bitmap.recycle()
                        instanceHandler.post {
                            result.success(null)
                        }
                    }
                }.start()
            } catch (e: Exception) {
                result.success(null)
            }
        }

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

        override fun onCues(cues: List<Cue>) {
            val text = cues.mapNotNull { cue -> cue.text?.toString() }.joinToString("\n")
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

        override fun onTracksChanged(tracks: Tracks) {
            val trackList = mutableListOf<Map<String, Any>>()
            tracks.groups.forEachIndexed { groupIndex, group ->
                val type = when (group.type) {
                    C.TRACK_TYPE_AUDIO -> "audio"
                    C.TRACK_TYPE_TEXT -> "text"
                    C.TRACK_TYPE_VIDEO -> "video"
                    else -> "unknown"
                }
                for (i in 0 until group.length) {
                    val format = group.getTrackFormat(i)
                    trackList.add(mapOf(
                        "id" to "${groupIndex}_$i",
                        "groupIndex" to groupIndex,
                        "trackIndex" to i,
                        "type" to type,
                        "language" to (format.language ?: ""),
                        "label" to (format.label ?: ""),
                        "mimeType" to (format.sampleMimeType ?: ""),
                        "codec" to (format.codecs ?: ""),
                        "isSelected" to group.isTrackSelected(i)
                    ))
                }
            }
            currentTracks = trackList
            emitEvent("tracksChanged", trackList)
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            emitEvent("error", error.message)
        }
    }
}
