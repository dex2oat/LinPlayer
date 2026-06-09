import '../api/api_interfaces.dart';

class PlaybackUrlRequest {
  final String itemId;
  final String? mediaSourceId;
  final String? container;
  final String? playSessionId;
  final bool staticStream;
  final bool allowDirectPlay;
  final bool allowDirectStream;
  final bool allowTranscoding;
  final bool enableAutoStreamCopy;
  final bool enableAutoStreamCopyAudio;
  final bool enableAutoStreamCopyVideo;

  const PlaybackUrlRequest({
    required this.itemId,
    this.mediaSourceId,
    this.container,
    this.playSessionId,
    this.staticStream = true,
    this.allowDirectPlay = true,
    this.allowDirectStream = true,
    this.allowTranscoding = false,
    this.enableAutoStreamCopy = true,
    this.enableAutoStreamCopyAudio = true,
    this.enableAutoStreamCopyVideo = true,
  });

  PlaybackUrlRequest copyWith({
    String? itemId,
    String? mediaSourceId,
    String? container,
    String? playSessionId,
    bool? staticStream,
    bool? allowDirectPlay,
    bool? allowDirectStream,
    bool? allowTranscoding,
    bool? enableAutoStreamCopy,
    bool? enableAutoStreamCopyAudio,
    bool? enableAutoStreamCopyVideo,
  }) {
    return PlaybackUrlRequest(
      itemId: itemId ?? this.itemId,
      mediaSourceId: mediaSourceId ?? this.mediaSourceId,
      container: container ?? this.container,
      playSessionId: playSessionId ?? this.playSessionId,
      staticStream: staticStream ?? this.staticStream,
      allowDirectPlay: allowDirectPlay ?? this.allowDirectPlay,
      allowDirectStream: allowDirectStream ?? this.allowDirectStream,
      allowTranscoding: allowTranscoding ?? this.allowTranscoding,
      enableAutoStreamCopy: enableAutoStreamCopy ?? this.enableAutoStreamCopy,
      enableAutoStreamCopyAudio:
          enableAutoStreamCopyAudio ?? this.enableAutoStreamCopyAudio,
      enableAutoStreamCopyVideo:
          enableAutoStreamCopyVideo ?? this.enableAutoStreamCopyVideo,
    );
  }
}

class PlaybackSelection {
  final MediaSource? mediaSource;
  final PlaybackUrlRequest primaryRequest;
  final PlaybackUrlRequest? fallbackRequest;
  final bool startsWithSoftwareDecoding;
  final String? fallbackReason;

  const PlaybackSelection({
    required this.mediaSource,
    required this.primaryRequest,
    this.fallbackRequest,
    this.startsWithSoftwareDecoding = false,
    this.fallbackReason,
  });
}

MediaSource? resolvePreferredMediaSource(
  PlaybackInfo playbackInfo, {
  String? preferredMediaSourceId,
}) {
  final mediaSources = playbackInfo.mediaSources;
  if (mediaSources.isEmpty) {
    return null;
  }
  if (preferredMediaSourceId == null || preferredMediaSourceId.isEmpty) {
    return mediaSources.firstOrNull;
  }
  return mediaSources
          .where((source) => source.id == preferredMediaSourceId)
          .firstOrNull ??
      mediaSources.firstOrNull;
}

PlaybackSelection buildPlaybackSelection({
  required PlaybackInfo playbackInfo,
  required String itemId,
  String? preferredMediaSourceId,
  String? playSessionId,
}) {
  final mediaSource = resolvePreferredMediaSource(
    playbackInfo,
    preferredMediaSourceId: preferredMediaSourceId,
  );
  final normalizedContainer = _preferredContainer(mediaSource);
  final primaryRequest = PlaybackUrlRequest(
    itemId: itemId,
    mediaSourceId: mediaSource?.id,
    container: normalizedContainer,
    playSessionId: playSessionId,
  );

  // 当前播放器链路只依赖本地内核解码，不应因为音频编码类型自动切到
  // 服务端转码/“更安全”的流策略，否则会破坏直连与 seek 的稳定性。
  return PlaybackSelection(
    mediaSource: mediaSource,
    primaryRequest: primaryRequest,
  );
}

String _preferredContainer(MediaSource? mediaSource) {
  final container = mediaSource?.container?.trim().toLowerCase();
  if (container != null && container.isNotEmpty) {
    return container;
  }
  final videoStream =
      mediaSource?.mediaStreams.where((stream) => stream.isVideo).firstOrNull;
  final codec = videoStream?.codec?.trim().toLowerCase();
  if (codec == 'hevc' || codec == 'h265') {
    return 'mkv';
  }
  return 'mp4';
}
