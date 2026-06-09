import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/subtitle_track_matcher.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../utils/desktop_smooth_scroll.dart';

/// 桌面端播放器 - 全新设计
///
/// 专为桌面端（Windows/Linux）优化的沉浸式播放器界面：
/// - 独立的桌面控制栏布局（顶栏、底栏、侧边浮动按钮）
/// - 鼠标移动自动显示/隐藏控制栏
/// - 丰富的键盘快捷键支持
/// - 视频区域热区点击交互
class DesktopPlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final String? mediaSourceId;

  const DesktopPlayerScreen({
    super.key,
    required this.itemId,
    this.mediaSourceId,
  });

  @override
  ConsumerState<DesktopPlayerScreen> createState() => _DesktopPlayerScreenState();
}

class _DesktopPlayerScreenState extends ConsumerState<DesktopPlayerScreen> {
  static const MethodChannel _windowChannel = MethodChannel('com.linplayer/window');
  static const Duration _uiRefreshInterval = Duration(milliseconds: 200);

  late VideoPlayerService _playerService;
  final FocusNode _focusNode = FocusNode();
  bool _initializingPlayer = false;
  Timer? _uiRefreshTimer;

  // 控制栏显隐状态
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // 全屏状态
  bool _isFullscreen = false;

  // 倍速按钮长按状态
  bool _isSpeedLongPressing = false;
  bool _didTriggerSpeedLongPress = false;
  Timer? _speedLongPressTimer;

  // 跳过片头按钮
  bool _showSkipButton = false;
  Timer? _skipButtonTimer;
  bool _autoSkipTriggeredForCurrentOpening = false;

  // 鼠标是否在控制栏区域内
  bool _mouseInControlsArea = false;

  // 音量滑块显示
  bool _showVolumeSlider = false;
  Timer? _volumeSliderTimer;

  // 统计信息显示
  bool _showStatsOverlay = false;
  Map<String, String> _playbackStats = {};
  Timer? _statsRefreshTimer;
  bool _statsRefreshInFlight = false;
  MediaSource? _currentMediaSource;
  String? _displayTitle;

  @override
  void initState() {
    super.initState();
    _playerService = VideoPlayerService();
    _initializePlayer();
    _focusNode.requestFocus();
    unawaited(_syncFullscreenState());
    _uiRefreshTimer = Timer.periodic(_uiRefreshInterval, (_) {
      if (!mounted) return;
      _checkSkipOpening();
      setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(audioTrackProvider, (prev, next) {
        if (_initializingPlayer || prev == next || next == null) {
          return;
        }
        final audioStreams = _audioStreamsFromCurrentSource();
        if (audioStreams.isEmpty) {
          return;
        }
        unawaited(_applyAudioStreamSelection(audioStreams, next));
      });
      ref.listenManual(subtitleTrackProvider, (prev, next) {
        if (_initializingPlayer || prev == next) {
          return;
        }
        unawaited(_onSubtitleSelectionChanged(prev, next));
      });
      ref.listenManual(subtitleDelayProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleDelay(next));
        }
      });
      ref.listenManual(audioDelayProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setAudioDelay(next));
        }
      });
      ref.listenManual(subtitleSizeProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleSize(next));
        }
      });
      ref.listenManual(subtitlePositionProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitlePosition(next));
        }
      });
      ref.listenManual(subtitleFontProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleFont(next));
        }
      });
      ref.listenManual(subtitleBackgroundProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleBackground(next));
        }
      });
    });
  }

  void _checkSkipOpening() {
    final openingStart = ref.read(skipOpeningStartProvider);
    final openingEnd = ref.read(skipOpeningEndProvider);
    final autoSkip = ref.read(skipAutoModeProvider);
    if (openingStart <= 0 || openingEnd <= 0 || openingEnd <= openingStart) {
      _autoSkipTriggeredForCurrentOpening = false;
      return;
    }

    final pos = _playerService.position.inSeconds;
    final inOpening = pos >= openingStart && pos < openingEnd;

    if (inOpening && autoSkip) {
      if (_autoSkipTriggeredForCurrentOpening) {
        return;
      }
      _autoSkipTriggeredForCurrentOpening = true;
      unawaited(_playerService.seekTo(Duration(seconds: openingEnd)));
    } else if (inOpening && !_showSkipButton) {
      setState(() => _showSkipButton = true);
      _skipButtonTimer?.cancel();
      _skipButtonTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _showSkipButton = false);
      });
    } else if (!inOpening && _showSkipButton) {
      setState(() => _showSkipButton = false);
      _skipButtonTimer?.cancel();
    } else if (!inOpening) {
      _autoSkipTriggeredForCurrentOpening = false;
    }
  }

  Future<void> _initializePlayer() async {
    if (_initializingPlayer) return;
    _initializingPlayer = true;
    final api = ref.read(apiClientProvider);
    try {
      final cachedItem = ref.read(currentPlayingItemProvider);
      final item = cachedItem != null && cachedItem.id == widget.itemId
          ? cachedItem
          : await api.media.getItemDetails(widget.itemId);

      final playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
      final selection = buildPlaybackSelection(
        playbackInfo: playbackInfo,
        itemId: widget.itemId,
        preferredMediaSourceId:
            widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider),
        playSessionId: '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
      );
      final mediaSource = selection.mediaSource;

      final videoUrl = api.playback.getVideoStreamUrl(
        selection.primaryRequest.itemId,
        mediaSourceId: selection.primaryRequest.mediaSourceId,
        container: selection.primaryRequest.container,
        playSessionId: selection.primaryRequest.playSessionId,
        staticStream: selection.primaryRequest.staticStream,
        allowDirectPlay: selection.primaryRequest.allowDirectPlay,
        allowDirectStream: selection.primaryRequest.allowDirectStream,
        allowTranscoding: selection.primaryRequest.allowTranscoding,
        enableAutoStreamCopy: selection.primaryRequest.enableAutoStreamCopy,
        enableAutoStreamCopyAudio:
            selection.primaryRequest.enableAutoStreamCopyAudio,
        enableAutoStreamCopyVideo:
            selection.primaryRequest.enableAutoStreamCopyVideo,
      );
      final fallbackVideoUrl = selection.fallbackRequest == null
          ? null
          : api.playback.getVideoStreamUrl(
              selection.fallbackRequest!.itemId,
              mediaSourceId: selection.fallbackRequest!.mediaSourceId,
              container: selection.fallbackRequest!.container,
              playSessionId: selection.fallbackRequest!.playSessionId,
              staticStream: selection.fallbackRequest!.staticStream,
              allowDirectPlay: selection.fallbackRequest!.allowDirectPlay,
              allowDirectStream: selection.fallbackRequest!.allowDirectStream,
              allowTranscoding: selection.fallbackRequest!.allowTranscoding,
              enableAutoStreamCopy:
                  selection.fallbackRequest!.enableAutoStreamCopy,
              enableAutoStreamCopyAudio:
                  selection.fallbackRequest!.enableAutoStreamCopyAudio,
              enableAutoStreamCopyVideo:
                  selection.fallbackRequest!.enableAutoStreamCopyVideo,
            );

      Duration? startPosition;
      if (item.userData?.playbackPositionTicks != null) {
        startPosition = Duration(
          milliseconds: (item.userData!.playbackPositionTicks! / 10000).round(),
        );
      }

      ref.read(currentPlayingItemProvider.notifier).state = item;
      ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;
      _currentMediaSource = mediaSource;
      _displayTitle = item.name;

      final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
      final coreType = coreString == 'mpv' ? PlayerCoreType.mpv : PlayerCoreType.exoPlayer;

      final dolbyVisionFix = coreType == PlayerCoreType.mpv ? ref.read(mpvDolbyVisionFixProvider) : false;
      final useLibass = coreType == PlayerCoreType.exoPlayer ? ref.read(exoLibassProvider) : false;
      final hardwareDecoding = ref.read(hardwareDecodingProvider);
      final preferredSubtitleLanguage = ref.read(preferredSubtitleLanguageProvider);

      await _playerService.initialize(
        videoUrl: videoUrl,
        itemId: widget.itemId,
        mediaSourceId: mediaSource?.id,
        fallbackVideoUrl: fallbackVideoUrl,
        startPosition: startPosition,
        coreType: coreType,
        dolbyVisionFix: dolbyVisionFix,
        useLibass: useLibass,
        hardwareDecoding: hardwareDecoding,
        startWithSoftwareDecoding:
            selection.startsWithSoftwareDecoding && hardwareDecoding,
        fallbackReason: selection.fallbackReason,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        onStart: (info) async {
          try { await api.playback.reportPlaybackStart(info); } catch (_) {}
        },
        onProgress: (info) async {
          try { await api.playback.reportPlaybackProgress(info); } catch (_) {}
        },
        onStop: (info) async {
          try { await api.playback.reportPlaybackStopped(info); } catch (_) {}
        },
      );

      await Future.wait([
        _playerService.setSubtitleSize(ref.read(subtitleSizeProvider)),
        _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider)),
        _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider)),
        _playerService.setSubtitleFont(ref.read(subtitleFontProvider)),
        _playerService.setSubtitleBackground(ref.read(subtitleBackgroundProvider)),
        _playerService.setAspectRatio(ref.read(aspectRatioProvider)),
      ]);

      await _playerService.play();

      final audioStreams = mediaSource?.mediaStreams.where((s) => s.isAudio).toList() ?? [];
      final subtitleStreams = mediaSource?.mediaStreams.where((s) => s.isSubtitle).toList() ?? [];
      await _waitForTracksReady(
        requireAudio: audioStreams.isNotEmpty,
        requireSubtitle: subtitleStreams.isNotEmpty,
      );

      final selectedAudioIndex = ref.read(audioTrackProvider);
      if (audioStreams.isNotEmpty) {
        final initialAudio = selectedAudioIndex ?? _resolveInitialAudioIndex(audioStreams);
        if (initialAudio != null) {
          ref.read(audioTrackProvider.notifier).state = initialAudio;
          await _applyAudioStreamSelection(audioStreams, initialAudio);
        }
      }

      if (subtitleStreams.isNotEmpty) {
        final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
        if (selectedSubtitleIndex != null) {
          await _applyInitialSubtitleTrack(subtitleStreams, selectedSubtitleIndex);
        } else {
          await _applyPreferredSubtitleTrack(subtitleStreams);
        }
      } else {
        ref.read(subtitleTrackProvider.notifier).state = null;
      }

      _startHideControlsTimer();
    } finally {
      _initializingPlayer = false;
    }
  }

  Future<void> _applyInitialAudioTrack(List<MediaStream> audioStreams, int selectedIndex) async {
    final trackId = _matchAudioTrackId(audioStreams, selectedIndex);
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  List<Map<String, dynamic>> _subtitleTracksFrom([List<Map<String, dynamic>>? tracks]) {
    final source = tracks ?? _playerService.tracksInfo;
    return source.where((track) {
      final type = track['type']?.toString();
      return type == 'subtitle' || type == 'text' || type == 'bitmap';
    }).toList();
  }

  Future<void> _waitForTracksReady({
    bool requireAudio = false,
    bool requireSubtitle = false,
  }) async {
    if (!requireAudio && !requireSubtitle) {
      return;
    }
    for (var i = 0; i < 30; i++) {
      final tracks = _playerService.tracksInfo;
      final audioReady = !requireAudio || tracks.any((track) => track['type'] == 'audio');
      final subtitleReady = !requireSubtitle || _subtitleTracksFrom(tracks).isNotEmpty;
      if (audioReady && subtitleReady) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _applyInitialSubtitleTrack(
    List<MediaStream> subtitleStreams,
    int selectedIndex,
  ) async {
    await _onSubtitleSelectionChanged(null, selectedIndex);
  }

  Future<void> _applyPreferredSubtitleTrack(List<MediaStream> subtitleStreams) async {
    if (subtitleStreams.isEmpty) {
      return;
    }
    final preferredLanguage = ref.read(preferredSubtitleLanguageProvider).trim().toLowerCase();
    final preferredTrack = subtitleStreams.firstWhere(
      (stream) => (stream.language ?? '').trim().toLowerCase() == preferredLanguage,
      orElse: () => subtitleStreams.first,
    );
    ref.read(subtitleTrackProvider.notifier).state = preferredTrack.index;
    await _onSubtitleSelectionChanged(null, preferredTrack.index);
  }

  List<MediaStream> _audioStreamsFromCurrentSource() {
    return _currentMediaSource?.mediaStreams.where((stream) => stream.isAudio).toList() ??
        const <MediaStream>[];
  }

  List<MediaStream> _subtitleStreamsFromCurrentSource() {
    return _currentMediaSource?.mediaStreams.where((stream) => stream.isSubtitle).toList() ??
        const <MediaStream>[];
  }

  int? _resolveInitialAudioIndex(List<MediaStream> audioStreams) {
    if (audioStreams.isEmpty) {
      return null;
    }
    final selected = audioStreams.firstWhere(
      (stream) => stream.isDefault == true,
      orElse: () => audioStreams.first,
    );
    return selected.index;
  }

  Future<void> _applyAudioStreamSelection(
    List<MediaStream> audioStreams,
    int selectedIndex,
  ) async {
    await _applyInitialAudioTrack(audioStreams, selectedIndex);
  }

  Future<void> _onSubtitleSelectionChanged(int? prev, int? next) async {
    if (prev == next || _currentMediaSource == null) {
      return;
    }
    if (next == null) {
      _playerService.setSubtitleSelectionHint();
      await _playerService.deselectSubtitleTrack();
      return;
    }

    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    final target = subtitleStreams.where((stream) => stream.index == next).firstOrNull;
    if (target == null) {
      return;
    }

    final codec = (target.codec ?? '').toLowerCase();
    final targetTitle = target.displayTitle ?? target.title;
    final isExternal = target.isExternal == true;
    final isGraphical = _isGraphicalSubtitleCodec(codec);

    if (!isExternal && !isGraphical) {
      _playerService.setSubtitleSelectionHint(codec: codec, title: targetTitle);
      final trackId = _matchSubtitleTrackId(
        subtitleStreams,
        target.language,
        targetTitle,
        target.codec,
        target.index,
      );
      if (trackId != null && trackId.isNotEmpty) {
        await _playerService.selectSubtitleTrack(trackId);
      } else if (_playerService.coreType == PlayerCoreType.mpv) {
        await _playerService.selectSubtitleTrack('auto');
      }
      return;
    }

    _playerService.setSubtitleSelectionHint();
    await _playerService.deselectSubtitleTrack();
    final subtitleFile = await _prepareExternalSubtitleFile(target, codec);
    await _playerService.loadLibassSubtitle(subtitleFile.path);
  }

  String? _matchAudioTrackId(List<MediaStream> audioStreams, int selectedIndex) {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((track) => track['type'] == 'audio').toList();
    if (audioTracks.isEmpty) {
      return null;
    }

    final position = audioStreams.indexWhere((stream) => stream.index == selectedIndex);
    if (position >= 0 && position < audioTracks.length) {
      final trackId = audioTracks[position]['id']?.toString();
      if (trackId != null && trackId.isNotEmpty) {
        return trackId;
      }
    }

    final target = audioStreams.where((stream) => stream.index == selectedIndex).firstOrNull;
    final targetTitle = target?.displayTitle ?? target?.title ?? '';
    final targetLang = (target?.language ?? '').toLowerCase();
    if (targetTitle.isNotEmpty) {
      for (final track in audioTracks) {
        final title = (track['title'] ?? '').toString();
        if (_titlesMatch(targetTitle, title)) {
          return track['id']?.toString();
        }
      }
    }
    if (targetLang.isNotEmpty) {
      final candidates = audioTracks.where((track) {
        final language = (track['language'] ?? '').toString().toLowerCase();
        return language == targetLang;
      }).toList();
      if (candidates.length == 1) {
        return candidates.first['id']?.toString();
      }
      if (position >= 0 && position < candidates.length) {
        return candidates[position]['id']?.toString();
      }
    }

    return audioTracks.first['id']?.toString();
  }

  String? _matchSubtitleTrackId(
    List<MediaStream> subtitleStreams,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) {
    final subtitleTracks = _subtitleTracksFrom()
        .where((track) => track['id'] != 'auto' && track['id'] != 'no')
        .toList();
    if (subtitleTracks.isEmpty) {
      return null;
    }

    final kind = SubtitleTrackMatcher.classifyKind(
      codec: targetCodec,
      title: targetTitle,
    );
    if (_playerService.coreType == PlayerCoreType.mpv) {
      final directMatch = _matchLegacyMpvSubtitleTrack(
        subtitleTracks,
        targetLang: targetLang,
        targetTitle: targetTitle,
        targetCodec: targetCodec,
        targetStreamIndex: targetStreamIndex,
      );
      if (directMatch != null && directMatch.isNotEmpty) {
        return directMatch;
      }
    }
    final typedStreamPosition = _typedSubtitleStreamPosition(
      subtitleStreams,
      targetStreamIndex,
      kind,
    );

    return SubtitleTrackMatcher.matchTrackId(
      subtitleTracks: subtitleTracks,
      targetKind: kind,
      targetStreamIndex: targetStreamIndex,
      typedStreamPosition: typedStreamPosition,
      targetLang: targetLang,
      targetTitle: targetTitle,
      titlesMatch: _titlesMatch,
    );
  }

  String? _matchLegacyMpvSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks, {
    required String? targetLang,
    required String? targetTitle,
    required String? targetCodec,
    required int targetStreamIndex,
  }) {
    final codec = targetCodec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec == 'dvdsub' ||
        codec == 'vobsub' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');
    final isAss = codec == 'ass' || codec == 'ssa';

    var candidates = isGraphical
        ? subtitleTracks
            .where((track) => track['type'] == 'bitmap' || track['isBitmap'] == true)
            .toList()
        : isAss
            ? subtitleTracks
                .where((track) => track['isAss'] == true || track['type'] == 'text')
                .toList()
            : subtitleTracks;

    if (candidates.isEmpty) {
      return subtitleTracks.isNotEmpty ? subtitleTracks.first['id']?.toString() : null;
    }

    if (targetTitle != null && targetTitle.isNotEmpty) {
      for (final track in candidates) {
        final title = (track['title'] ?? '').toString();
        if (title.isNotEmpty && _titlesMatch(targetTitle, title)) {
          return track['id']?.toString();
        }
      }
    }

    final normalizedTargetLang = (targetLang ?? '').trim().toLowerCase();
    if (normalizedTargetLang.isNotEmpty) {
      final langMatches = candidates.where((track) {
        final language = (track['language'] ?? '').toString().trim().toLowerCase();
        return language == normalizedTargetLang ||
            language == 'chi' ||
            language == 'zh';
      }).toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
      if (langMatches.length > 1 && targetTitle != null && targetTitle.isNotEmpty) {
        for (final track in langMatches) {
          final title = (track['title'] ?? '').toString();
          if (title.isNotEmpty && _titlesMatch(targetTitle, title)) {
            return track['id']?.toString();
          }
        }
        if (targetStreamIndex >= 0 && targetStreamIndex < langMatches.length) {
          return langMatches[targetStreamIndex]['id']?.toString();
        }
        return langMatches.first['id']?.toString();
      }
    }

    final embySubIndex = _extractEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
    if (embySubIndex >= 0 && embySubIndex < candidates.length) {
      return candidates[embySubIndex]['id']?.toString();
    }

    return candidates.first['id']?.toString();
  }

  int _extractEmbySubtitleIndex(
    int targetStreamIndex,
    List<Map<String, dynamic>> subtitleTracks,
  ) {
    if (subtitleTracks.isEmpty) return targetStreamIndex;
    final minId = subtitleTracks
        .map((track) => int.tryParse(track['id']?.toString() ?? ''))
        .whereType<int>()
        .fold<int?>(null, (prev, value) => prev == null || value < prev ? value : prev);
    if (minId == null) return targetStreamIndex;
    return targetStreamIndex - minId;
  }

  int _typedSubtitleStreamPosition(
    List<MediaStream> subtitleStreams,
    int targetStreamIndex,
    SubtitleKind targetKind,
  ) {
    final typedStreams = subtitleStreams.where((stream) {
      final streamKind = SubtitleTrackMatcher.classifyKind(
        codec: stream.codec,
        title: stream.displayTitle ?? stream.title,
      );
      if (targetKind == SubtitleKind.bitmap) {
        return streamKind == SubtitleKind.bitmap;
      }
      return streamKind != SubtitleKind.bitmap;
    }).toList();
    return typedStreams.indexWhere((stream) => stream.index == targetStreamIndex);
  }

  bool _titlesMatch(String expected, String actual) {
    final e = expected.toLowerCase();
    final a = actual.toLowerCase();
    if (e.isEmpty || a.isEmpty) {
      return false;
    }
    if (e == a || e.contains(a) || a.contains(e)) {
      return true;
    }
    final simpKeywords = ['简', 'chs', '简体', '简日', 'gb', '简中'];
    final tradKeywords = ['繁', 'cht', '繁体', '繁日', 'big5', '繁中'];
    final eIsSimp = simpKeywords.any(e.contains);
    final eIsTrad = tradKeywords.any(e.contains);
    final aIsSimp = simpKeywords.any(a.contains);
    final aIsTrad = tradKeywords.any(a.contains);
    if (eIsSimp && aIsSimp) {
      return true;
    }
    if (eIsTrad && aIsTrad) {
      return true;
    }
    return false;
  }

  bool _isAssSubtitleCodec(String codec) {
    return SubtitleTrackMatcher.isAssSubtitleCodec(codec);
  }

  bool _isGraphicalSubtitleCodec(String codec) {
    return SubtitleTrackMatcher.isGraphicalSubtitleCodec(codec);
  }

  String _embySubtitleCodec(String codec) {
    final lower = codec.toLowerCase();
    if (lower == 'srt' || lower == 'subrip') {
      return 'srt';
    }
    if (lower == 'vtt' || lower == 'webvtt') {
      return 'vtt';
    }
    if (_isGraphicalSubtitleCodec(lower)) {
      return 'pgs';
    }
    return 'ass';
  }

  String _subtitleFileExtension(String codec) {
    final lower = codec.toLowerCase();
    if (lower == 'srt' || lower == 'subrip') {
      return 'srt';
    }
    if (lower == 'vtt' || lower == 'webvtt') {
      return 'vtt';
    }
    if (_isAssSubtitleCodec(lower)) {
      return 'ass';
    }
    if (_isGraphicalSubtitleCodec(lower)) {
      return 'sup';
    }
    return 'srt';
  }

  Future<File> _prepareExternalSubtitleFile(MediaStream target, String codec) async {
    final currentSource = _currentMediaSource;
    if (currentSource == null) {
      throw StateError('当前媒体源为空，无法加载外挂字幕');
    }
    final api = ref.read(apiClientProvider);
    final subtitleUrl = api.playback.getSubtitleStreamUrl(
      widget.itemId,
      currentSource.id,
      target.index,
      _embySubtitleCodec(codec),
    );

    final tempDir = await getTemporaryDirectory();
    final file = File(
      p.join(
        tempDir.path,
        'desktop_subtitle_${widget.itemId}_${target.index}.${_subtitleFileExtension(codec)}',
      ),
    );

    if (!file.existsSync() || await file.length() == 0) {
      final server = ref.read(currentServerProvider);
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      if (server?.authToken != null) {
        dio.options.headers['X-Emby-Token'] = server!.authToken;
        dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
      }
      await dio.download(subtitleUrl, file.path);
    }

    if (_isAssSubtitleCodec(codec) ||
        _isGraphicalSubtitleCodec(codec) ||
        codec == 'srt' ||
        codec == 'subrip' ||
        codec == 'vtt' ||
        codec == 'webvtt') {
      return file;
    }

    return file;
  }

  // ========== 控制栏显隐 ==========

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (_playerService.isPlaying && !_mouseInControlsArea && mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _cancelHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  void _onMouseMoved() {
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    if (_playerService.isPlaying) {
      _startHideControlsTimer();
    }
  }

  // ========== 键盘快捷键 ==========

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else if (context.canPop()) {
          context.pop();
        }
        break;
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
        _playerService.togglePlay();
        break;
      case LogicalKeyboardKey.arrowLeft:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _playerService.seekBy(const Duration(seconds: -60));
        } else {
          _playerService.seekBy(const Duration(seconds: -15));
        }
        break;
      case LogicalKeyboardKey.arrowRight:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _playerService.seekBy(const Duration(seconds: 60));
        } else {
          _playerService.seekBy(const Duration(seconds: 15));
        }
        break;
      case LogicalKeyboardKey.keyJ:
        _playerService.seekBy(const Duration(seconds: -15));
        break;
      case LogicalKeyboardKey.keyL:
        _playerService.seekBy(const Duration(seconds: 15));
        break;
      case LogicalKeyboardKey.arrowUp:
        _adjustVolume(0.05);
        break;
      case LogicalKeyboardKey.arrowDown:
        _adjustVolume(-0.05);
        break;
      case LogicalKeyboardKey.bracketLeft:
        _adjustSpeed(-0.25);
        break;
      case LogicalKeyboardKey.bracketRight:
        _adjustSpeed(0.25);
        break;
      case LogicalKeyboardKey.backspace:
        _playerService.setSpeed(1.0);
        break;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.keyS:
        _cycleSubtitleTrack();
        break;
      case LogicalKeyboardKey.keyA:
        _cycleAudioTrack();
        break;
      case LogicalKeyboardKey.keyM:
        _toggleMute();
        break;
      case LogicalKeyboardKey.controlLeft:
      case LogicalKeyboardKey.controlRight:
        break;
      default:
        if (event.logicalKey == LogicalKeyboardKey.keyH && HardwareKeyboard.instance.isControlPressed) {
          _toggleControlsVisibility();
        } else if (event.logicalKey == LogicalKeyboardKey.keyS && HardwareKeyboard.instance.isControlPressed) {
          _takeScreenshot();
        }
    }
  }

  void _adjustVolume(double delta) {
    final newVolume = (_playerService.volume + delta).clamp(0.0, 1.0);
    _playerService.setVolume(newVolume);
  }

  void _adjustSpeed(double delta) {
    final newSpeed = (_playerService.speed + delta).clamp(0.25, 4.0);
    _playerService.setSpeed(newSpeed);
  }

  void _toggleMute() {
    if (_playerService.volume > 0) {
      _playerService.setVolume(0.0);
    } else {
      _playerService.setVolume(1.0);
    }
  }

  Future<void> _syncFullscreenState() async {
    if (!Platform.isWindows) return;
    try {
      final isFullscreen = await _windowChannel.invokeMethod<bool>('isFullscreen');
      if (mounted && isFullscreen != null) {
        setState(() => _isFullscreen = isFullscreen);
      }
    } on MissingPluginException {
      // Ignore on platforms without desktop window integration.
    } on PlatformException {
      // Ignore and keep the local fallback state.
    }
  }

  void _toggleFullscreen() async {
    final target = !_isFullscreen;
    var fullscreen = target;

    try {
      if (Platform.isWindows) {
        fullscreen = await _windowChannel.invokeMethod<bool>(
              'setFullscreen',
              {'fullscreen': target},
            ) ??
            target;
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          target ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      }
    } on MissingPluginException {
      fullscreen = target;
    } on PlatformException {
      fullscreen = target;
    }

    if (!mounted) return;
    setState(() => _isFullscreen = fullscreen);
    if (_showControls && _playerService.isPlaying) {
      _startHideControlsTimer();
    }
  }

  void _toggleControlsVisibility() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _startHideControlsTimer();
    }
  }

  void _cycleSubtitleTrack() {
    final subtitleTracks = _subtitleTracksFrom();
    if (subtitleTracks.isEmpty) return;

    final currentIndex = subtitleTracks.indexWhere((t) => t['selected'] == true);
    final nextIndex = (currentIndex + 1) % (subtitleTracks.length + 1);

    if (nextIndex >= subtitleTracks.length) {
      _playerService.deselectSubtitleTrack();
    } else {
      final trackId = subtitleTracks[nextIndex]['id']?.toString();
      if (trackId != null) _playerService.selectSubtitleTrack(trackId);
    }
  }

  void _cycleAudioTrack() {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    if (audioTracks.length <= 1) return;

    final currentIndex = audioTracks.indexWhere((t) => t['selected'] == true);
    final nextIndex = (currentIndex + 1) % audioTracks.length;
    final trackId = audioTracks[nextIndex]['id']?.toString();
    if (trackId != null) _playerService.selectAudioTrack(trackId);
  }

  // ========== 截图 ==========

  String _sanitizeFileName(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _buildScreenshotFileName(String itemName, DateTime timestamp) {
    final sanitizedName = _sanitizeFileName(itemName);
    final padded = [
      timestamp.year.toString().padLeft(4, '0'),
      timestamp.month.toString().padLeft(2, '0'),
      timestamp.day.toString().padLeft(2, '0'),
      timestamp.hour.toString().padLeft(2, '0'),
      timestamp.minute.toString().padLeft(2, '0'),
      timestamp.second.toString().padLeft(2, '0'),
    ].join('');
    return '${sanitizedName.isEmpty ? widget.itemId : sanitizedName}_$padded.png';
  }

  Future<void> _takeScreenshot() async {
    try {
      final data = await _playerService.screenshot();
      if (!mounted) return;

      if (data != null && data.isNotEmpty) {
        final baseDirectory =
            await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
        final screenshotsDirectory =
            Directory(p.join(baseDirectory.path, 'LinPlayer', 'Screenshots'));
        if (!await screenshotsDirectory.exists()) {
          await screenshotsDirectory.create(recursive: true);
        }

        final itemName = ref.read(currentPlayingItemProvider)?.name ?? widget.itemId;
        final file = File(
          p.join(
            screenshotsDirectory.path,
            _buildScreenshotFileName(itemName, DateTime.now()),
          ),
        );
        await file.writeAsBytes(data, flush: true);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图已保存到 ${file.path}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图功能暂不支持当前播放器内核')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图失败: $e')),
        );
      }
    }
  }

  // ========== 视频热区 ==========

  void _onVideoTapUp(TapUpDetails details) {
    final width = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < width * 0.25) {
      _playerService.seekBy(const Duration(seconds: -15));
    } else if (tapX > width * 0.75) {
      _playerService.seekBy(const Duration(seconds: 15));
    } else {
      _playerService.togglePlay();
    }
  }

  // ========== 倍速长按 ==========

  void _onSpeedButtonDown(bool increase) {
    _isSpeedLongPressing = true;
    _didTriggerSpeedLongPress = false;
    _speedLongPressTimer?.cancel();
    _speedLongPressTimer = Timer(const Duration(milliseconds: 320), () {
      if (!_isSpeedLongPressing) return;
      _didTriggerSpeedLongPress = true;
      _adjustSpeed(increase ? 0.05 : -0.05);
      _speedLongPressTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (_isSpeedLongPressing) {
          _adjustSpeed(increase ? 0.05 : -0.05);
        }
      });
    });
  }

  void _onSpeedButtonUp() {
    _isSpeedLongPressing = false;
    _speedLongPressTimer?.cancel();
    _speedLongPressTimer = null;
  }

  void _onSpeedButtonCancel() {
    _onSpeedButtonUp();
    _didTriggerSpeedLongPress = false;
  }

  void _handleSpeedButtonTap(bool increase) {
    if (_didTriggerSpeedLongPress) {
      _didTriggerSpeedLongPress = false;
      return;
    }
    _adjustSpeed(increase ? 0.25 : -0.25);
  }

  // ========== 上一集/下一集 ==========

  Future<void> _playPrevious() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return;
    try {
      final currentMediaSourceId = ref.read(selectedMediaSourceProvider);
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
        currentItem!.seriesId!,
        seasonId: currentItem.seasonId,
      );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex > 0) {
        if (mounted) {
          final previousEpisode = episodes[currentIndex - 1];
          context.replace(
            '/player/${previousEpisode.id}'
            '${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}',
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是第一集了')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  Future<void> _playNext() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return;
    try {
      final currentMediaSourceId = ref.read(selectedMediaSourceProvider);
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
        currentItem!.seriesId!,
        seasonId: currentItem.seasonId,
      );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
        if (mounted) {
          final nextEpisode = episodes[currentIndex + 1];
          context.replace(
            '/player/${nextEpisode.id}'
            '${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}',
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是最后一集了')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  // ========== Anime4K ==========

  Future<void> _showAnime4KMenu() async {
    final currentLevel = ref.read(anime4KLevelProvider);
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _Anime4KLevelDialog(currentLevel: currentLevel),
    );
    if (result != null && mounted) {
      ref.read(anime4KLevelProvider.notifier).state = result;
      if (result == 'off') {
        await _playerService.applySuperResolution(false);
      } else {
        await _playerService.applySuperResolutionLevel(result);
      }
    }
  }

  // ========== 跳过片头 ==========

  void _onSkipOpeningPressed() {
    final openingEnd = ref.read(skipOpeningEndProvider);
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  // ========== 更多菜单 ==========

  void _showMoreMenu() {
    final item = ref.read(currentPlayingItemProvider);
    final isMpv = normalizePlayerCore(ref.read(playerCoreProvider)) == 'mpv';
    final anime4KLevel = ref.read(anime4KLevelProvider);
    final hardwareDecoding = ref.read(hardwareDecodingProvider);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _MoreMenuSheet(
        onShowAspectRatio: _showAspectRatioDialog,
        onTakeScreenshot: _takeScreenshot,
        onShowSubtitleSelector: _showSubtitleSelector,
        onShowAudioSelector: _showAudioSelector,
        onShowEpisodeSelector: item?.seriesId != null ? _showEpisodeSelector : null,
        onToggleHardwareDecoding: _toggleHardwareDecoding,
        onToggleStats: _toggleStatsOverlay,
        onToggleFullscreen: _toggleFullscreen,
        onShowAnime4K: isMpv ? _showAnime4KMenu : null,
        isStatsVisible: _showStatsOverlay,
        isFullscreen: _isFullscreen,
        hardwareDecodingEnabled: hardwareDecoding,
        anime4KLabel: isMpv ? anime4KLevel : null,
      ),
    );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自动', '16:9', '4:3', '21:9', '全屏', '原始'];
    final currentRatio = ref.read(aspectRatioProvider);

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('画面比例', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const Divider(color: Colors.white12, height: 1),
              ...ratios.map((ratio) => ListTile(
                title: Text(ratio, style: const TextStyle(color: Colors.white)),
                trailing: currentRatio == ratio
                    ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                    : null,
                onTap: () {
                  ref.read(aspectRatioProvider.notifier).state = ratio;
                  _playerService.setAspectRatio(ratio);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('画面比例: $ratio')),
                  );
                },
              )),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 选集弹窗 ==========

  void _showEpisodeSelector() {
    final item = ref.read(currentPlayingItemProvider);
    if (item?.seriesId == null) return;

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _EpisodeSelectorDialog(
        seriesId: item!.seriesId!,
        currentEpisodeId: item.id,
        currentMediaSourceId: ref.read(selectedMediaSourceProvider),
      ),
    );
  }

  // ========== 字幕/音轨弹窗 ==========

  Future<void> _waitForTrackSelectorItems({
    required bool subtitle,
  }) async {
    for (var i = 0; i < 10; i++) {
      final streams = subtitle
          ? _subtitleStreamsFromCurrentSource()
          : _audioStreamsFromCurrentSource();
      if (streams.isNotEmpty) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _showSubtitleSelector() async {
    await _waitForTrackSelectorItems(subtitle: true);
    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    if (subtitleStreams.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有可切换的字幕轨道')),
      );
      return;
    }
    _showTrackSelectorDialog(
      title: '字幕选择',
      streams: subtitleStreams,
      selectedIndex: ref.read(subtitleTrackProvider),
      onSelect: (streamIndex) {
        ref.read(subtitleTrackProvider.notifier).state = streamIndex;
      },
      canDisable: true,
      subtitle: true,
    );
  }

  Future<void> _showAudioSelector() async {
    await _waitForTrackSelectorItems(subtitle: false);
    final audioStreams = _audioStreamsFromCurrentSource();
    if (audioStreams.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有可切换的音轨')),
      );
      return;
    }
    _showTrackSelectorDialog(
      title: '音轨选择',
      streams: audioStreams,
      selectedIndex: ref.read(audioTrackProvider),
      onSelect: (streamIndex) {
        ref.read(audioTrackProvider.notifier).state = streamIndex;
      },
      subtitle: false,
    );
  }

  void _showTrackSelectorDialog({
    required String title,
    required List<MediaStream> streams,
    required int? selectedIndex,
    required ValueChanged<int> onSelect,
    required bool subtitle,
    bool canDisable = false,
  }) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Flexible(
                child: DesktopSmoothScrollBuilder(
                  builder: (context, controller) => ListView.builder(
                    controller: controller,
                    shrinkWrap: true,
                    itemCount: canDisable ? streams.length + 1 : streams.length,
                    itemBuilder: (context, index) {
                      if (canDisable && index == 0) {
                        final isSelected = selectedIndex == null;
                        return ListTile(
                          title: const Text('关闭字幕', style: TextStyle(color: Colors.white)),
                          trailing: isSelected
                              ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                              : null,
                          onTap: () {
                            _playerService.deselectSubtitleTrack();
                            Navigator.pop(context);
                          },
                        );
                      }
                      final trackIndex = canDisable ? index - 1 : index;
                      final stream = streams[trackIndex];
                      final isSelected = selectedIndex == stream.index;
                      final label = stream.readableLabel(siblings: streams);
                      return ListTile(
                        title: Text(label, style: const TextStyle(color: Colors.white)),
                        subtitle: stream.codec != null
                            ? Text(
                                '编码: ${stream.codec}${subtitle ? (stream.isExternal == true ? ' (外挂)' : ' (内封)') : ''}',
                                style: const TextStyle(color: Colors.white54),
                              )
                            : null,
                        trailing: isSelected
                            ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                            : null,
                        onTap: () {
                          onSelect(stream.index);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 格式化时间 ==========

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // ========== 鼠标滚轮音量 ==========

  void _onMouseWheelScroll(PointerScrollEvent event) {
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    _adjustVolume(delta);
  }

  // ========== 统计信息行 ==========

  List<Widget> _buildStatsRows() {
    final rows = <Widget>[];

    // 文件信息
    final versionName = _currentMediaSource?.name?.trim();
    if (versionName != null && versionName.isNotEmpty) {
      rows.add(_buildStatRow('文件', versionName));
    }

    final fileSize = _playbackStats['file-size'];
    if (fileSize != null && fileSize != 'null') {
      final size = int.tryParse(fileSize);
      if (size != null) {
        rows.add(_buildStatRow('大小', _formatFileSize(size)));
      }
    }

    // 视频信息
    final width = _playbackStats['width'];
    final height = _playbackStats['height'];
    if (width != null && height != null) {
      rows.add(_buildStatRow('分辨率', '$width x $height'));
    }

    final fps = _playbackStats['container-fps'] ?? _playbackStats['fps'];
    if (fps != null) {
      rows.add(_buildStatRow('帧率', '$fps fps'));
    }

    final videoBitrate = _playbackStats['video-bitrate'];
    if (videoBitrate != null) {
      final bitrate = int.tryParse(videoBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('视频码率', _formatBitrate(bitrate)));
      }
    }

    final videoCodec = _playbackStats['video-codec'] ?? _playbackStats['current-tracks/video/codec'];
    if (videoCodec != null && videoCodec.isNotEmpty) {
      rows.add(_buildStatRow('视频编码', videoCodec));
    }

    final pixelFormat = _playbackStats['video-params/pixelformat'];
    if (pixelFormat != null && pixelFormat.isNotEmpty) {
      rows.add(_buildStatRow('像素格式', pixelFormat));
    }

    // 音频信息
    final audioCodec = _playbackStats['audio-codec'] ?? _playbackStats['current-tracks/audio/codec'];
    if (audioCodec != null && audioCodec.isNotEmpty) {
      rows.add(_buildStatRow('音频编码', audioCodec));
    }

    final audioBitrate = _playbackStats['audio-bitrate'];
    if (audioBitrate != null) {
      final bitrate = int.tryParse(audioBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('音频码率', _formatBitrate(bitrate)));
      }
    }

    final sampleRate = _playbackStats['audio-params/sample-rate'];
    if (sampleRate != null) {
      rows.add(_buildStatRow('采样率', '${sampleRate}Hz'));
    }

    final channels = _playbackStats['audio-params/channel-count'];
    if (channels != null) {
      rows.add(_buildStatRow('声道', '${channels}ch'));
    }

    // 渲染信息
    final hwdec = _playbackStats['hwdec-current'];
    if (hwdec != null && hwdec.isNotEmpty && hwdec != 'no') {
      rows.add(_buildStatRow('硬解', hwdec));
    }

    final voFps = _playbackStats['estimated-vf-fps'];
    if (voFps != null) {
      rows.add(_buildStatRow('渲染帧率', '${voFps}fps'));
    }

    final dropCount = _playbackStats['frame-drop-count'] ?? _playbackStats['vo-drop-frame-count'];
    if (dropCount != null && dropCount != '0') {
      rows.add(_buildStatRow('丢帧', dropCount));
    }

    final cacheDuration = _playbackStats['demuxer-cache-duration'];
    if (cacheDuration != null) {
      rows.add(_buildStatRow('缓冲', '${cacheDuration}s'));
    }

    // 播放状态
    rows.add(_buildStatRow('速度', '${_playerService.speed.toStringAsFixed(2)}x'));
    rows.add(_buildStatRow('位置', '${_formatDuration(_playerService.position)} / ${_formatDuration(_playerService.duration)}'));

    return rows;
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        Text(value),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _formatBitrate(int bps) {
    if (bps < 1000) return '${bps}bps';
    if (bps < 1000000) return '${(bps / 1000).toStringAsFixed(0)}Kbps';
    return '${(bps / 1000000).toStringAsFixed(2)}Mbps';
  }

  // ========== 生命周期 ==========

  @override
  void dispose() {
    _cancelHideControlsTimer();
    _skipButtonTimer?.cancel();
    _speedLongPressTimer?.cancel();
    _volumeSliderTimer?.cancel();
    _statsRefreshTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _focusNode.dispose();
    _playerService.dispose();
    super.dispose();
  }

  // ========== 统计信息显示 ==========

  void _toggleStatsOverlay() {
    setState(() {
      _showStatsOverlay = !_showStatsOverlay;
      if (_showStatsOverlay) {
        _refreshStats();
        _statsRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          _refreshStats();
        });
      } else {
        _statsRefreshTimer?.cancel();
        _statsRefreshTimer = null;
        _playbackStats = {};
      }
    });
  }

  Future<void> _refreshStats() async {
    if (!_showStatsOverlay || !mounted || _statsRefreshInFlight) return;
    _statsRefreshInFlight = true;
    try {
      final stats = await _playerService.getPlaybackStats();
      if (mounted && _showStatsOverlay) {
        setState(() {
          _playbackStats = stats;
        });
      }
    } finally {
      _statsRefreshInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final isMpv = normalizePlayerCore(ref.read(playerCoreProvider)) == 'mpv';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) {
          _handleKeyEvent(event);
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          onHover: (_) => _onMouseMoved(),
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _onMouseWheelScroll(event);
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 视频区域
                _playerService.buildVideo(),

                // 缓冲指示器
                if (_playerService.isBuffering)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),

                // 错误显示
                if (_playerService.hasError)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          '播放失败: ${_playerService.errorMessage}',
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _initializePlayer,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),

                // 视频热区点击层
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: _onVideoTapUp,
                  onDoubleTap: _toggleFullscreen,
                ),

                // 统计信息覆盖层（MPV式OSD）
                if (_showStatsOverlay)
                  Positioned(
                    top: 80,
                    left: 16,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DefaultTextStyle(
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            height: 1.5,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_playbackStats.isEmpty)
                                const Text('正在获取统计信息...')
                              else
                                ..._buildStatsRows(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // 跳过片头按钮
                if (_showSkipButton)
                  Positioned(
                    top: 80,
                    right: 24,
                    child: ElevatedButton.icon(
                      onPressed: _onSkipOpeningPressed,
                      icon: const Icon(Icons.skip_next, size: 18),
                      label: const Text('跳过片头'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),

                // 控制栏覆盖层
                if (_showControls && !_playerService.isLocked)
                  _buildControlsOverlay(item, isMpv),

                // 锁定状态指示
                if (_playerService.isLocked)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: IconButton(
                      icon: const Icon(Icons.lock, color: Colors.white),
                      tooltip: '已锁定',
                      onPressed: _playerService.toggleLock,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 控制栏覆盖层 ==========

  Widget _buildControlsOverlay(MediaItem? item, bool isMpv) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 顶栏渐变背景
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.8),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: _buildTopBar(item, isMpv),
              ),
            ),
          ),
        ),

        // 左侧浮动按钮
        Positioned(
          left: 0,
          top: 120,
          bottom: 132,
          width: 60,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconButton(
                    icon: Icons.camera_alt,
                    tooltip: '截图 (Ctrl+S)',
                    onPressed: _takeScreenshot,
                  ),
                  const SizedBox(height: 16),
                  _buildIconButton(
                    icon: _playerService.isLocked ? Icons.lock : Icons.lock_open,
                    tooltip: '锁定',
                    onPressed: _playerService.toggleLock,
                  ),
                ],
              ),
            ),
          ),
        ),

        // 右侧浮动按钮（倍速）
        Positioned(
          right: 0,
          top: 120,
          bottom: 132,
          width: 60,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconButton(
                    icon: Icons.add,
                    tooltip: '加速',
                    onPressed: () => _handleSpeedButtonTap(true),
                    onTapDown: (_) => _onSpeedButtonDown(true),
                    onTapUp: (_) => _onSpeedButtonUp(),
                    onTapCancel: _onSpeedButtonCancel,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_playerService.speed.toStringAsFixed(2)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildIconButton(
                    icon: Icons.remove,
                    tooltip: '减速',
                    onPressed: () => _handleSpeedButtonTap(false),
                    onTapDown: (_) => _onSpeedButtonDown(false),
                    onTapUp: (_) => _onSpeedButtonUp(),
                    onTapCancel: _onSpeedButtonCancel,
                  ),
                ],
              ),
            ),
          ),
        ),

        // 底栏渐变背景
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildProgressBar(),
                    _buildBottomBar(item),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ========== 顶栏 ==========

  Widget _buildTopBar(MediaItem? item, bool isMpv) {
    final title = _displayTitle?.trim().isNotEmpty == true
        ? _displayTitle!
        : item?.name ?? widget.itemId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 返回按钮
          _buildIconButton(
            icon: Icons.arrow_back,
            tooltip: '返回',
            onPressed: () => context.pop(),
          ),
          const SizedBox(width: 12),
          // 标题
          Expanded(
            child: _MarqueeText(
              text: title,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          // Anime4K
          if (isMpv)
            _buildIconButton(
              icon: Icons.hd,
              tooltip: 'Anime4K 超分',
              color: ref.watch(anime4KLevelProvider) != 'off' ? const Color(0xFF5B8DEF) : Colors.white,
              onPressed: _showAnime4KMenu,
            ),
          // 跳过片头
          _buildIconButton(
            icon: Icons.skip_next,
            tooltip: '跳过片头设置',
            onPressed: _showSkipDialog,
          ),
          // 硬解开关
          _buildIconButton(
            icon: ref.watch(hardwareDecodingProvider) ? Icons.memory : Icons.slow_motion_video,
            tooltip: '硬件解码',
            onPressed: _toggleHardwareDecoding,
          ),
          // 更多菜单
          _buildIconButton(
            icon: Icons.more_vert,
            tooltip: '更多',
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  // ========== 进度条 ==========

  Widget _buildProgressBar() {
    final currentTime = _formatDuration(_playerService.position);
    final totalTime = _formatDuration(_playerService.duration);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // 当前时间
          Text(
            currentTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 12),
          // 进度条
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF5B8DEF),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                thumbColor: const Color(0xFF5B8DEF),
                overlayColor: const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: _playerService.progress.clamp(0.0, 1.0),
                onChanged: (value) {
                  final position = Duration(
                    milliseconds: (value * _playerService.duration.inMilliseconds).round(),
                  );
                  _playerService.seekTo(position);
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 总时间
          Text(
            totalTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ========== 底栏 ==========

  Widget _buildBottomBar(MediaItem? item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          // 左侧：音量
          _buildVolumeControl(),
          const Spacer(),
          // 中间：播放控制
          _buildPlaybackControls(),
          const Spacer(),
          // 右侧：功能按钮
          _buildFunctionControls(item),
        ],
      ),
    );
  }

  Widget _buildVolumeControl() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) {
            setState(() => _showVolumeSlider = true);
            _volumeSliderTimer?.cancel();
          },
          onExit: (_) {
            _volumeSliderTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _showVolumeSlider = false);
            });
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconButton(
                icon: _playerService.volume == 0
                    ? Icons.volume_off
                    : _playerService.volume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
                tooltip: '音量',
                onPressed: _toggleMute,
              ),
              if (_showVolumeSlider)
                SizedBox(
                  width: 100,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF5B8DEF),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                      thumbColor: const Color(0xFF5B8DEF),
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    ),
                    child: Slider(
                      value: _playerService.volume.clamp(0.0, 1.0),
                      onChanged: (value) => _playerService.setVolume(value),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaybackControls() {
    final isPlayActionBlocked =
        _initializingPlayer || !_playerService.isInitialized || _playerService.hasError;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          icon: Icons.skip_previous,
          tooltip: '上一集',
          onPressed: _playPrevious,
        ),
        const SizedBox(width: 16),
        GestureDetector(
          onTap: isPlayActionBlocked ? null : _playerService.togglePlay,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(
                alpha: isPlayActionBlocked ? 0.05 : 0.1,
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _playerService.isPlaybackActionPending || _initializingPlayer
                  ? Icons.hourglass_top
                  : (_playerService.isPlaying ? Icons.pause : Icons.play_arrow),
              color: isPlayActionBlocked
                  ? Colors.white.withValues(alpha: 0.45)
                  : Colors.white,
              size: 28,
            ),
          ),
        ),
        const SizedBox(width: 16),
        _buildIconButton(
          icon: Icons.skip_next,
          tooltip: '下一集',
          onPressed: _playNext,
        ),
      ],
    );
  }

  Widget _buildFunctionControls(MediaItem? item) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          icon: Icons.subtitles,
          tooltip: '字幕',
          onPressed: _showSubtitleSelector,
        ),
        _buildIconButton(
          icon: Icons.audiotrack,
          tooltip: '音轨',
          onPressed: _showAudioSelector,
        ),
        _buildIconButton(
          icon: _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: '全屏 (F)',
          onPressed: _toggleFullscreen,
        ),
        if (item?.seriesId != null)
          _buildIconButton(
            icon: Icons.playlist_play,
            tooltip: '选集',
            onPressed: _showEpisodeSelector,
          ),
      ],
    );
  }

  // ========== 通用按钮 ==========

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    GestureTapCancelCallback? onTapCancel,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          onTapDown: onTapDown,
          onTapUp: onTapUp,
          onTapCancel: onTapCancel,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: color ?? Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  // ========== 跳过片头设置 ==========

  void _showSkipDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('跳过片头设置', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                _SkipTimeField(label: '片头开始 (秒)', provider: skipOpeningStartProvider),
                const SizedBox(height: 12),
                _SkipTimeField(label: '片头结束 (秒)', provider: skipOpeningEndProvider),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('自动跳过', style: TextStyle(color: Colors.white)),
                    const Spacer(),
                    Switch(
                      value: ref.read(skipAutoModeProvider),
                      onChanged: (value) {
                        ref.read(skipAutoModeProvider.notifier).state = value;
                        Navigator.pop(context);
                      },
                      activeThumbColor: const Color(0xFF5B8DEF),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('确定', style: TextStyle(color: Color(0xFF5B8DEF))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 硬解切换 ==========

  void _toggleHardwareDecoding() async {
    final current = ref.read(hardwareDecodingProvider);
    final savedPosition = _playerService.position;
    final wasPlaying = _playerService.isPlaying;

    ref.read(hardwareDecodingProvider.notifier).state = !current;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    await _initializePlayer();
    if (savedPosition > Duration.zero) {
      await _playerService.seekTo(savedPosition);
    }
    if (!wasPlaying) {
      await _playerService.pause();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(!current ? '已切换硬件解码' : '已切换软件解码')),
      );
    }
  }
}

// ========== 辅助组件 ==========

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _needsScroll = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
  }

  @override
  void didUpdateWidget(_MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.stop();
      _controller.reset();
      _needsScroll = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _checkOverflow(BoxConstraints constraints) {
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: double.infinity);
    _needsScroll = textPainter.width > constraints.maxWidth;
    if (_needsScroll && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!_needsScroll && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _checkOverflow(constraints);
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              if (!_needsScroll) return child!;
              final textPainter = TextPainter(
                text: TextSpan(text: widget.text, style: widget.style),
                textDirection: TextDirection.ltr,
              );
              textPainter.layout(maxWidth: double.infinity);
              final offset = (textPainter.width - constraints.maxWidth) * _controller.value;
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: child,
              );
            },
            child: Text(widget.text, style: widget.style, overflow: TextOverflow.ellipsis),
          ),
        );
      },
    );
  }
}

class _Anime4KLevelDialog extends StatelessWidget {
  final String currentLevel;

  const _Anime4KLevelDialog({required this.currentLevel});

  static const List<Map<String, String>> levels = [
    {'value': 'off', 'label': '关闭'},
    {'value': 'modeA', 'label': '模式 A - 性能优先'},
    {'value': 'modeB', 'label': '模式 B - 平衡'},
    {'value': 'modeC', 'label': '模式 C - 质量优先'},
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Anime4K 超分设置', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(color: Colors.white12, height: 1),
            ...levels.map((level) => ListTile(
              title: Text(level['label']!, style: const TextStyle(color: Colors.white)),
              trailing: currentLevel == level['value']
                  ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                  : null,
              onTap: () => Navigator.pop(context, level['value']),
            )),
          ],
        ),
      ),
    );
  }
}

class _MoreMenuSheet extends StatelessWidget {
  final VoidCallback onShowAspectRatio;
  final VoidCallback onTakeScreenshot;
  final VoidCallback onShowSubtitleSelector;
  final VoidCallback onShowAudioSelector;
  final VoidCallback? onShowEpisodeSelector;
  final VoidCallback onToggleHardwareDecoding;
  final VoidCallback onToggleStats;
  final VoidCallback onToggleFullscreen;
  final VoidCallback? onShowAnime4K;
  final bool isStatsVisible;
  final bool isFullscreen;
  final bool hardwareDecodingEnabled;
  final String? anime4KLabel;

  const _MoreMenuSheet({
    required this.onShowAspectRatio,
    required this.onTakeScreenshot,
    required this.onShowSubtitleSelector,
    required this.onShowAudioSelector,
    required this.onShowEpisodeSelector,
    required this.onToggleHardwareDecoding,
    required this.onToggleStats,
    required this.onToggleFullscreen,
    required this.onShowAnime4K,
    required this.isStatsVisible,
    required this.isFullscreen,
    required this.hardwareDecodingEnabled,
    required this.anime4KLabel,
  });

  @override
  Widget build(BuildContext context) {
    void handleAction(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined, color: Colors.white),
            title: const Text('截图', style: TextStyle(color: Colors.white)),
            onTap: () => handleAction(onTakeScreenshot),
          ),
          ListTile(
            leading: const Icon(Icons.subtitles, color: Colors.white),
            title: const Text('字幕选择', style: TextStyle(color: Colors.white)),
            onTap: () => handleAction(onShowSubtitleSelector),
          ),
          ListTile(
            leading: const Icon(Icons.audiotrack, color: Colors.white),
            title: const Text('音轨选择', style: TextStyle(color: Colors.white)),
            onTap: () => handleAction(onShowAudioSelector),
          ),
          if (onShowEpisodeSelector != null)
            ListTile(
              leading: const Icon(Icons.playlist_play, color: Colors.white),
              title: const Text('选集', style: TextStyle(color: Colors.white)),
              onTap: () => handleAction(onShowEpisodeSelector!),
            ),
          ListTile(
            leading: const Icon(Icons.aspect_ratio, color: Colors.white),
            title: const Text('画面比例', style: TextStyle(color: Colors.white)),
            onTap: () {
              handleAction(onShowAspectRatio);
            },
          ),
          ListTile(
            leading: Icon(
              hardwareDecodingEnabled ? Icons.memory : Icons.slow_motion_video,
              color: Colors.white,
            ),
            title: const Text('硬件解码', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              hardwareDecodingEnabled ? '当前已开启' : '当前已关闭',
              style: const TextStyle(color: Colors.white54),
            ),
            onTap: () => handleAction(onToggleHardwareDecoding),
          ),
          if (onShowAnime4K != null)
            ListTile(
              leading: const Icon(Icons.hd, color: Colors.white),
              title: const Text('Anime4K 超分', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                anime4KLabel == null || anime4KLabel == 'off'
                    ? '当前已关闭'
                    : '当前模式: $anime4KLabel',
                style: const TextStyle(color: Colors.white54),
              ),
              onTap: () => handleAction(onShowAnime4K!),
            ),
          ListTile(
            leading: const Icon(Icons.analytics, color: Colors.white),
            title: const Text('统计信息', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              isStatsVisible ? '当前显示中' : '当前已隐藏',
              style: const TextStyle(color: Colors.white54),
            ),
            onTap: () => handleAction(onToggleStats),
          ),
          ListTile(
            leading: Icon(
              isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            title: Text(
              isFullscreen ? '退出全屏' : '进入全屏',
              style: const TextStyle(color: Colors.white),
            ),
            onTap: () => handleAction(onToggleFullscreen),
          ),
        ],
      ),
    );
  }
}

class _EpisodeSelectorDialog extends ConsumerWidget {
  final String seriesId;
  final String currentEpisodeId;
  final String? currentMediaSourceId;

  const _EpisodeSelectorDialog({
    required this.seriesId,
    required this.currentEpisodeId,
    this.currentMediaSourceId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync = ref.watch(episodesProvider((seriesId: seriesId, seasonId: null)));

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('选集', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Flexible(
              child: DesktopSmoothScrollBuilder(
                builder: (context, controller) => episodesAsync.when(
                  data: (episodes) => ListView.builder(
                    controller: controller,
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final episode = episodes[index];
                      final isCurrent = episode.id == currentEpisodeId;
                      return ListTile(
                        title: Text(
                          '第 ${episode.indexNumber ?? index + 1} 集: ${episode.name}',
                          style: TextStyle(
                            color: isCurrent ? const Color(0xFF5B8DEF) : Colors.white,
                            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        trailing: isCurrent
                            ? const Icon(Icons.play_arrow, color: Color(0xFF5B8DEF))
                            : null,
                        onTap: () {
                          if (!isCurrent) {
                            context.replace(
                              '/player/${episode.id}'
                              '${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}',
                            );
                          }
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Text('加载失败: $error', style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkipTimeField extends ConsumerWidget {
  final String label;
  final StateProvider<int> provider;

  const _SkipTimeField({required this.label, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.1),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (text) {
              final val = int.tryParse(text);
              if (val != null && val >= 0) {
                ref.read(provider.notifier).state = val;
              }
            },
          ),
        ),
      ],
    );
  }
}
