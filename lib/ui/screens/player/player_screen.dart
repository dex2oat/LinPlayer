import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../widgets/common/danmaku_search_widget.dart';
import '../../widgets/common/danmaku_overlay.dart';
import '../../widgets/common/media_widgets.dart';
import '../../utils/media_helpers.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/services/mpv_player_adapter.dart';
import '../../../core/services/exo_player_adapter.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/subtitle_processor.dart';
import '../../../core/utils/platform_utils.dart';

/// 播放页
class PlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final String? mediaSourceId;

  const PlayerScreen({super.key, required this.itemId, this.mediaSourceId});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> with WidgetsBindingObserver {
  late VideoPlayerService _playerService;
  bool _showRemaining = false;
  bool _isLongPressing = false;
  Timer? _longPressTimer;
  Timer? _sleepTimer;
  double? _initialVideoAspectRatio;

  static VideoPlayerService? _activePlayerService;

  static VideoPlayerService? get activePlayerService => _activePlayerService;

  MediaSource? _resolveMediaSource(
    PlaybackInfo playbackInfo, {
    String? preferredMediaSourceId,
  }) {
    final mediaSources = playbackInfo.mediaSources;
    if (mediaSources.isEmpty) {
      return null;
    }

    final targetSourceId =
        preferredMediaSourceId ??
        ref.read(selectedMediaSourceProvider) ??
        widget.mediaSourceId;

    if (targetSourceId == null || targetSourceId.isEmpty) {
      return mediaSources.firstOrNull;
    }

    return mediaSources.where((source) => source.id == targetSourceId).firstOrNull ??
        mediaSources.firstOrNull;
  }

  void _sanitizeSelectionState(MediaSource? mediaSource) {
    if (mediaSource == null) {
      ref.read(audioTrackProvider.notifier).state = null;
      ref.read(subtitleTrackProvider.notifier).state = null;
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
      return;
    }

    final audioIndexes = mediaSource.mediaStreams
        .where((stream) => stream.isAudio)
        .map((stream) => stream.index)
        .toSet();
    final subtitleIndexes = mediaSource.mediaStreams
        .where((stream) => stream.isSubtitle)
        .map((stream) => stream.index)
        .toSet();

    final selectedAudioIndex = ref.read(audioTrackProvider);
    if (selectedAudioIndex != null && !audioIndexes.contains(selectedAudioIndex)) {
      ref.read(audioTrackProvider.notifier).state = null;
    }

    final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (selectedSubtitleIndex != null &&
        !subtitleIndexes.contains(selectedSubtitleIndex)) {
      ref.read(subtitleTrackProvider.notifier).state = null;
    }

    final selectedSecondarySubtitleIndex = ref.read(secondarySubtitleTrackProvider);
    if (selectedSecondarySubtitleIndex != null &&
        (!subtitleIndexes.contains(selectedSecondarySubtitleIndex) ||
            selectedSecondarySubtitleIndex == ref.read(subtitleTrackProvider))) {
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
    }
  }

  Rect _computeContentRect(Size containerSize) {
    if (containerSize.width <= 0 || containerSize.height <= 0) {
      return Rect.zero;
    }
    final ratio = _resolveDisplayAspectRatio();
    if (ratio == null || ratio <= 0) {
      return Offset.zero & containerSize;
    }

    final containerRatio = containerSize.width / containerSize.height;
    if (containerRatio > ratio) {
      final contentWidth = containerSize.height * ratio;
      final left = (containerSize.width - contentWidth) / 2;
      return Rect.fromLTWH(left, 0, contentWidth, containerSize.height);
    }

    final contentHeight = containerSize.width / ratio;
    final top = (containerSize.height - contentHeight) / 2;
    return Rect.fromLTWH(0, top, containerSize.width, contentHeight);
  }

  double? _resolveDisplayAspectRatio() {
    final aspectMode = ref.read(aspectRatioProvider);
    if (aspectMode == '全屏') return null;

    switch (aspectMode) {
      case '16:9':
        return 16 / 9;
      case '4:3':
        return 4 / 3;
      case '21:9':
        return 21 / 9;
      case '原始':
      case '自动':
      default:
        break;
    }

    final adapter = _playerService.adapter;
    if (adapter is ExoPlayerAdapter) {
      return adapter.videoAspectRatio ?? _initialVideoAspectRatio;
    }
    return _initialVideoAspectRatio;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playerService = VideoPlayerService();
    _playerService.addListener(_onPlayerUpdate);
    _initializePlayer();
    
    // 监听播放器设置变化并下发到播放器
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(subtitleDelayProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleDelay(next);
      });
      ref.listenManual(audioDelayProvider, (prev, next) {
        if (prev != next) _playerService.setAudioDelay(next);
      });
      ref.listenManual(subtitleSizeProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleSize(next);
      });
      ref.listenManual(subtitlePositionProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitlePosition(next);
      });
      ref.listenManual(subtitleFontProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleFont(next);
      });
      ref.listenManual(subtitleBackgroundProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleBackground(next);
      });
      ref.listenManual(subtitleTrackProvider, (prev, next) {
        _onSubtitleTrackChanged(prev, next);
      });
      ref.listenManual(secondarySubtitleTrackProvider, (prev, next) {
        _onSecondarySubtitleTrackChanged(next);
      });
      ref.listenManual(currentPlayingItemProvider, (prev, next) {
        if (prev?.id != next?.id) {
          ref.read(loadedDanmakuProvider.notifier).state = [];
        }
      });
    });
  }

  Future<void> _initializePlayer() async {
    final api = ref.read(apiClientProvider);
    final item = await api.media.getItemDetails(widget.itemId);

    final playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
    final mediaSource = _resolveMediaSource(
      playbackInfo,
      preferredMediaSourceId: widget.mediaSourceId,
    );
    _sanitizeSelectionState(mediaSource);
    final videoStream = mediaSource?.mediaStreams.where((stream) => stream.isVideo).firstOrNull;
    _initialVideoAspectRatio = (videoStream?.width != null &&
            videoStream?.height != null &&
            videoStream!.width! > 0 &&
            videoStream.height! > 0)
        ? videoStream.width! / videoStream.height!
        : null;

    final videoUrl = api.playback.getVideoStreamUrl(
      widget.itemId,
      mediaSourceId: mediaSource?.id,
      container: mediaSource?.container ?? videoStream?.codec,
      playSessionId: '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
    );

    Duration? startPosition;
    if (item.userData?.playbackPositionTicks != null) {
      startPosition = Duration(
        milliseconds: (item.userData!.playbackPositionTicks! / 10000).round(),
      );
    }

    ref.read(currentPlayingItemProvider.notifier).state = item;
    ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;

    final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
    final coreType = coreString == 'mpv'
        ? PlayerCoreType.mpv
        : PlayerCoreType.exoPlayer;

    final dolbyVisionFix = coreType == PlayerCoreType.mpv
        ? ref.read(mpvDolbyVisionFixProvider)
        : false;
    final useLibass = coreType == PlayerCoreType.exoPlayer
        ? ref.read(exoLibassProvider)
        : false;

    final preferredSubtitleLanguage = ref.read(preferredSubtitleLanguageProvider);

    await _playerService.initialize(
      videoUrl: videoUrl,
      itemId: widget.itemId,
      mediaSourceId: mediaSource?.id,
      startPosition: startPosition,
      coreType: coreType,
      dolbyVisionFix: dolbyVisionFix,
      useLibass: useLibass,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      onStart: (info) async {
        try {
          await api.playback.reportPlaybackStart(info);
        } catch (_) {}
      },
      onProgress: (info) async {
        try {
          await api.playback.reportPlaybackProgress(info);
        } catch (_) {}
      },
      onStop: (info) async {
        try {
          await api.playback.reportPlaybackStopped(info);
        } catch (_) {}
      },
    );

    await _playerService.play();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 加载字幕（内封/外挂）—— 两个内核都支持
    if (mediaSource != null) {
      await _waitForTracksReady();
      await _loadSubtitles(item, mediaSource);
    }

    final audioStreams = mediaSource?.mediaStreams.where((stream) => stream.isAudio).toList() ?? const <MediaStream>[];
    final selectedAudioIndex = ref.read(audioTrackProvider);
    if (selectedAudioIndex != null) {
      await _applyInitialAudioTrack(audioStreams, selectedAudioIndex);
    }

    final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (selectedSubtitleIndex != null) {
      await _onSubtitleTrackChanged(null, selectedSubtitleIndex);
    }

    final selectedSecondarySubtitleIndex = ref.read(secondarySubtitleTrackProvider);
    if (selectedSecondarySubtitleIndex != null) {
      await _onSecondarySubtitleTrackChanged(selectedSecondarySubtitleIndex);
    }

    _playerService.setSubtitleSize(ref.read(subtitleSizeProvider));
    _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider));
    _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider));
    _playerService.setSubtitleFont(ref.read(subtitleFontProvider));
    _playerService.setSubtitleBackground(ref.read(subtitleBackgroundProvider));
    _playerService.setAspectRatio(ref.read(aspectRatioProvider));
  }

  Future<void> _waitForTracksReady() async {
    for (int i = 0; i < 30; i++) {
      final tracks = _playerService.tracksInfo;
      final subtitleTracks = tracks.where((t) =>
          (t['type'] == 'text' || t['type'] == 'bitmap') &&
          t['id'] != 'auto' && t['id'] != 'no').toList();
      if (subtitleTracks.isNotEmpty) return;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    AppLogger().w('Player', '等待轨道就绪超时，继续加载');
  }

  Future<void> _loadSubtitles(MediaItem item, MediaSource mediaSource) async {
    final logger = AppLogger();
    final api = ref.read(apiClientProvider);
    final subtitleStreams = mediaSource.mediaStreams
        .where((s) => s.isSubtitle)
        .toList();

    logger.i('Player', '开始加载字幕 - 可用字幕流: ${subtitleStreams.length} 个');

    if (subtitleStreams.isEmpty) {
      logger.w('Player', '没有可用字幕流');
      return;
    }

    final userSelectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (userSelectedSubtitleIndex != null) {
      logger.i('Player', '保留用户在详情页中选择的字幕轨道: $userSelectedSubtitleIndex');
      return;
    }

    for (final stream in subtitleStreams) {
      logger.d('Player', '字幕流: index=${stream.index}, codec=${stream.codec}, language=${stream.language}, external=${stream.isExternal}, title=${stream.displayTitle}');
    }

    final preferredLang = ref.read(preferredSubtitleLanguageProvider);
    logger.i('Player', '首选字幕语言: $preferredLang');

    final target = subtitleStreams.firstWhere(
      (s) => s.language == preferredLang,
      orElse: () => subtitleStreams.first,
    );

    final codec = target.codec?.toLowerCase() ?? 'ass';
    final isExternal = target.isExternal ?? false;
    final targetIndex = target.index;
    final isGraphical = _isGraphicalSubtitleCodec(codec);
    final isAss = _isAssSubtitleCodec(codec);
    logger.i('Player', '选择字幕: index=$targetIndex, codec=$codec, language=${target.language}, external=$isExternal, graphical=$isGraphical, isAss=$isAss');

    ref.read(subtitleTrackProvider.notifier).state = targetIndex;

    if (!isExternal) {
      final isExoAss = isAss && !isGraphical && _playerService.coreType == PlayerCoreType.exoPlayer;

      if (isExoAss) {
        logger.i('Player', 'EXO内核: 内封ASS字幕直接走Media3轨道选择，由原生ASS管线处理');
        try {
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        } catch (e, stackTrace) {
          logger.eWithStack('Player', 'EXO内封ASS轨道选择失败，回退原生选择', e, stackTrace);
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        }
      } else {
        logger.i('Player', '内封字幕，通过播放器轨道选择');
        try {
          if (_playerService.coreType == PlayerCoreType.mpv) {
            await _selectInternalSubtitleMPV(target, preferredLang, logger);
          } else {
            await _selectInternalSubtitleEXO(target, preferredLang, logger);
          }
        } catch (e, stackTrace) {
          logger.eWithStack('Player', '内封字幕轨道选择失败', e, stackTrace);
        }
      }
      return;
    }

    try {
      if (_playerService.coreType == PlayerCoreType.mpv) {
        final embyCodec = _embySubtitleCodec(codec);
        final subUrl = api.playback.getSubtitleStreamUrl(
          widget.itemId,
          mediaSource.id,
          targetIndex,
          embyCodec,
        );
        if (isGraphical) {
          final ext = _subtitleFileExtension(codec, _playerService.coreType);
          final subFile = await _downloadSubtitleToTempFile(
            subtitleUrl: subUrl,
            fileName: 'subtitle_${widget.itemId}_$targetIndex.$ext',
          );
          logger.i('Player', 'MPV内核: 图形外挂字幕使用本地文件: ${subFile.path}');
          if (subFile.existsSync() && await subFile.length() > 0) {
            await _playerService.loadLibassSubtitle(subFile.path);
          }
        } else {
          logger.i('Player', 'MPV内核: 直接加载Emby字幕URL: $subUrl');
          await _playerService.loadLibassSubtitle(subUrl);
        }
        logger.i('Player', 'MPV外挂字幕加载成功');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('外挂字幕: ${target.language ?? '默认'} (${codec.toUpperCase()})')),
          );
        }
      } else {
        final embyCodec = _embySubtitleCodec(codec);
        final subUrl = api.playback.getSubtitleStreamUrl(
          widget.itemId,
          mediaSource.id,
          targetIndex,
          embyCodec,
        );
        logger.i('Player', 'EXO内核: 下载字幕后再加载: $subUrl');

        final ext = _subtitleFileExtension(codec, _playerService.coreType);
        final subFile = await _prepareSubtitleFileForPlayer(
          subtitleUrl: subUrl,
          fileName: 'subtitle_${widget.itemId}_$targetIndex.$ext',
          codec: codec,
          coreType: _playerService.coreType,
          logger: logger,
        );
        logger.i('Player', '字幕下载完成/使用缓存 (${await subFile.length()} bytes)');

        if (subFile.existsSync() && await subFile.length() > 0) {
          await _playerService.loadLibassSubtitle(subFile.path);
          logger.i('Player', 'EXO外挂字幕加载成功');

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('外挂字幕: ${target.language ?? '默认'} (${codec.toUpperCase()})')),
            );
          }
        }
      }
    } catch (e, stackTrace) {
      logger.eWithStack('Player', '外挂字幕加载失败', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('字幕加载失败: $e')),
        );
      }
    }
  }

  String _embySubtitleCodec(String codec) {
    final lower = codec.toLowerCase();
    final isPgs = lower == 'pgssub' || lower == 'pgs' || lower == 'sup' || lower.contains('hdmv');
    if (_playerService.coreType == PlayerCoreType.mpv) {
      switch (lower) {
        case 'srt' || 'subrip':
          return 'srt';
        case 'vtt' || 'webvtt':
          return 'vtt';
        default:
          if (isPgs) return 'pgs';
          return 'ass';
      }
    } else {
      switch (lower) {
        case 'srt' || 'subrip':
          return 'srt';
        case 'vtt' || 'webvtt':
          return 'vtt';
        case 'ass' || 'ssa':
          return 'ass';
        case 'pgssub' || 'pgs' || 'sup':
          return 'pgs';
        default:
          if (isPgs) return 'pgs';
          return 'srt';
      }
    }
  }

  String _subtitleFileExtension(String codec, PlayerCoreType coreType) {
    final lower = codec.toLowerCase();
    if (lower == 'srt' || lower == 'subrip') return 'srt';
    if (lower == 'vtt' || lower == 'webvtt') return 'vtt';
    if (lower == 'ass' || lower == 'ssa') return 'ass';
    if (lower == 'pgssub' || lower == 'pgs' || lower == 'sup' || lower == 'dvdsub' || lower == 'vobsub' || lower.contains('hdmv') || lower.contains('pgs')) return 'sup';
    if (coreType == PlayerCoreType.mpv) return 'ass';
    return 'srt';
  }

  bool _isAssSubtitleCodec(String codec) {
    final lower = codec.toLowerCase();
    return lower == 'ass' || lower == 'ssa';
  }

  bool _isGraphicalSubtitleCodec(String codec) {
    final lower = codec.toLowerCase();
    return lower == 'pgssub' ||
        lower == 'sup' ||
        lower == 'pgs' ||
        lower == 'dvdsub' ||
        lower == 'vobsub' ||
        lower.contains('hdmv') ||
        lower.contains('pgs');
  }

  Future<File> _prepareSubtitleFileForPlayer({
    required String subtitleUrl,
    required String fileName,
    required String codec,
    required PlayerCoreType coreType,
    required AppLogger logger,
  }) async {
    final sourceFile = await _downloadSubtitleToTempFile(
      subtitleUrl: subtitleUrl,
      fileName: fileName,
    );

    if (coreType != PlayerCoreType.exoPlayer) {
      return sourceFile;
    }

    if (_isAssSubtitleCodec(codec)) {
      final preferLibass = ref.read(exoLibassProvider);
      if (preferLibass) {
        logger.i('Player', 'EXO内核: ASS/SSA 保留原文件，交给Media3原生ASS管线处理');
        return sourceFile;
      }

      final convertedPath = await SubtitleProcessor.convertAssToSrt(
        sourceFile.path,
        outputPath: sourceFile.path.replaceFirst(RegExp(r'\.[^.]+$'), '.srt'),
      );
      logger.i('Player', 'EXO内核: ASS/SSA 已转换为 SRT 兼容播放: $convertedPath');
      return File(convertedPath);
    }

    if (_isGraphicalSubtitleCodec(codec)) {
      logger.w('Player', 'EXO内核: 图形字幕仍依赖 Media3 设备侧解析，若不显示请切换 MPV');
    }

    return sourceFile;
  }

  Future<File> _downloadSubtitleToTempFile({
    required String subtitleUrl,
    required String fileName,
  }) async {
    final server = ref.read(currentServerProvider);
    final tempDir = await getTemporaryDirectory();
    final subFile = File('${tempDir.path}/$fileName');

    if (!subFile.existsSync() || await subFile.length() == 0) {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      if (server?.authToken != null) {
        dio.options.headers['X-Emby-Token'] = server!.authToken;
        dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
      }
      await dio.download(subtitleUrl, subFile.path);
    }

    return subFile;
  }

  Future<void> _selectInternalSubtitleMPV(MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) =>
        (t['type'] == 'text' || t['type'] == 'bitmap') &&
        t['id'] != 'auto' && t['id'] != 'no').toList();
    logger.i('Player', 'MPV 可用字幕轨道: ${subtitleTracks.length} 个');
    for (final track in subtitleTracks) {
      logger.d('Player', '  轨道: id=${track['id']}, title=${track['title']}, language=${track['language']}, codec=${track['codec']}, type=${track['type']}');
    }

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'MPV 无可用字幕轨道 - 设置pending等待轨道就绪');
      final mpvAdapter = _playerService.adapter;
      if (mpvAdapter is MpvPlayerAdapter) {
        mpvAdapter.setPendingSubtitle(
          target.codec?.toLowerCase() ?? 'ass',
          title: target.displayTitle ?? target.title,
        );
      }
      await _playerService.selectSubtitleTrack('auto');
      return;
    }

    String? trackId;
    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec == 'dvdsub' || codec == 'vobsub' || codec.contains('hdmv') || codec.contains('pgs');

    if (isGraphical) {
      final bitmapMatches = subtitleTracks.where((t) =>
          t['type'] == 'bitmap' || (t['isBitmap'] == true)).toList();
      if (bitmapMatches.isNotEmpty) {
        final targetTitle = target.displayTitle ?? target.title;
        if (targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in bitmapMatches) {
            final tTitle = t['title']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              trackId = t['id']?.toString();
              break;
            }
          }
        }
        if (trackId == null) {
          final langMatch = bitmapMatches.where((t) =>
              t['language'] == preferredLang || t['language'] == 'chi' || t['language'] == 'zh').toList();
          trackId = (langMatch.isNotEmpty ? langMatch : bitmapMatches).first['id']?.toString();
        }
      }
    }

    trackId ??= _matchMpvSubtitleTrack(
      subtitleTracks, target.language, target.displayTitle ?? target.title,
      target.codec, target.index,
    );

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'MPV 已选择内封字幕轨道: $trackId');
    } else {
      logger.w('Player', 'MPV 未找到匹配的字幕轨道');
    }
  }

  Future<void> _selectInternalSubtitleEXO(MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    var subtitleTracks = tracks.where((t) =>
        t['type'] == 'text' || t['type'] == 'bitmap').toList();
    logger.i('Player', 'EXO 可用字幕轨道: ${subtitleTracks.length} 个');

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'EXO 无可用字幕轨道 - 等待轨道就绪后重试');
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 300));
        final retryTracks = _playerService.tracksInfo.where((t) =>
            t['type'] == 'text' || t['type'] == 'bitmap').toList();
        if (retryTracks.isNotEmpty) {
          subtitleTracks = retryTracks;
          logger.i('Player', 'EXO 轨道就绪 - 可用字幕轨道: ${subtitleTracks.length} 个');
          break;
        }
      }
      if (subtitleTracks.isEmpty) {
        logger.w('Player', 'EXO 等待轨道超时，放弃字幕选择');
        return;
      }
    }

    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec == 'dvdsub' || codec == 'vobsub' || codec.contains('hdmv') || codec.contains('pgs');

    String? trackId;

    if (isGraphical) {
      final bitmapTracks = subtitleTracks.where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true).toList();
      if (bitmapTracks.isNotEmpty) {
        final targetTitle = target.displayTitle ?? target.title;
        if (targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in bitmapTracks) {
            final tTitle = t['title']?.toString() ?? t['label']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              trackId = t['id']?.toString();
              break;
            }
          }
        }
        if (trackId == null) {
          final langMatch = bitmapTracks.where((t) =>
              t['language'] == preferredLang || t['language'] == 'chi' || t['language'] == 'zh').toList();
          final targetList = langMatch.isNotEmpty ? langMatch : bitmapTracks;
          trackId = targetList.first['id']?.toString();
        }
      }
    }

    trackId ??= _matchExoSubtitleTrack(
      subtitleTracks, target.language, target.displayTitle ?? target.title,
      target.codec, target.index,
    );

    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'EXO 已选择内封字幕轨道: id=$trackId');
      
      // PGS 字幕提示：显示能力依赖设备侧 Media3 解码输出，异常时建议切换 MPV
      if (isGraphical && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PGS字幕加载中，如无法显示请切换MPV内核'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  String? _matchMpvSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) {
    final codec = targetCodec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec == 'dvdsub' || codec == 'vobsub' || codec.contains('hdmv') || codec.contains('pgs');
    final isAss = codec == 'ass' || codec == 'ssa';

    final candidates = isGraphical
        ? subtitleTracks.where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true).toList()
        : isAss
            ? subtitleTracks.where((t) => t['isAss'] == true || t['type'] == 'text').toList()
            : subtitleTracks;

    if (candidates.isEmpty) return subtitleTracks.first['id']?.toString();

    if (targetTitle != null && targetTitle.isNotEmpty) {
      for (final t in candidates) {
        final tTitle = t['title']?.toString() ?? '';
        if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
          return t['id']?.toString();
        }
      }
    }

    if (targetLang != null) {
      final langMatches = candidates.where((t) =>
          t['language'] == targetLang ||
          t['language'] == 'chi' || t['language'] == 'zh').toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
        if (langMatches.length > 1 && targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in langMatches) {
            final tTitle = t['title']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              return t['id']?.toString();
            }
          }
          if (targetStreamIndex >= 0 && targetStreamIndex < langMatches.length) {
            return langMatches[targetStreamIndex]['id']?.toString();
          }
          return langMatches.first['id']?.toString();
        }
    }

    final embySubIndex = _computeEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
    if (embySubIndex >= 0 && embySubIndex < candidates.length) {
      return candidates[embySubIndex]['id']?.toString();
    }

    return candidates.first['id']?.toString();
  }

  String? _matchMpvSecondarySubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    MediaStream target,
    String? primaryTrackId,
  ) {
    if (subtitleTracks.isEmpty) return null;

    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');
    if (isGraphical) return null;

    final filtered = subtitleTracks.where((t) {
      final isBitmap = t['type'] == 'bitmap' || t['isBitmap'] == true;
      if (isBitmap) return false;
      final embyIndex = _extractEmbySubtitleIndex(t['id']?.toString());
      if (embyIndex != null && embyIndex == target.index) return true;
      return false;
    }).toList();
    if (filtered.isNotEmpty) {
      return filtered.first['id']?.toString();
    }

    final title = target.displayTitle ?? target.title;
    if (title != null && title.isNotEmpty) {
      for (final t in subtitleTracks) {
        if (t['id']?.toString() == primaryTrackId) continue;
        final isBitmap = t['type'] == 'bitmap' || t['isBitmap'] == true;
        if (isBitmap) continue;
        final tTitle = t['title']?.toString() ?? '';
        if (tTitle.isNotEmpty && _titlesMatch(title, tTitle)) {
          return t['id']?.toString();
        }
      }
    }

    for (final t in subtitleTracks) {
      if (t['id']?.toString() == primaryTrackId) continue;
      final isBitmap = t['type'] == 'bitmap' || t['isBitmap'] == true;
      if (isBitmap) continue;
      return t['id']?.toString();
    }

    return null;
  }

  String? _matchExoSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) {
    final codec = targetCodec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec == 'dvdsub' || codec == 'vobsub' || codec.contains('hdmv') || codec.contains('pgs');

    final candidates = isGraphical
        ? subtitleTracks.where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true).toList()
        : subtitleTracks;

    if (candidates.isEmpty) return null;

    for (final t in candidates) {
      final groupIndex = t['groupIndex'];
      if (groupIndex != null && groupIndex == targetStreamIndex) {
        return t['id']?.toString();
      }
    }

    if (targetTitle != null && targetTitle.isNotEmpty) {
      for (final t in candidates) {
        final tTitle = t['title']?.toString() ?? t['label']?.toString() ?? '';
        if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
          return t['id']?.toString();
        }
      }
    }

    if (targetLang != null) {
      final langMatches = candidates.where((t) => t['language'] == targetLang).toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
      if (langMatches.length > 1) {
        final idx = _computeEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
        if (idx >= 0 && idx < langMatches.length) {
          return langMatches[idx]['id']?.toString();
        }
        return langMatches.first['id']?.toString();
      }
    }

    final idx = _computeEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
    if (idx >= 0 && idx < candidates.length) {
      return candidates[idx]['id']?.toString();
    }

    return candidates.first['id']?.toString();
  }

  int _computeEmbySubtitleIndex(int embyStreamIndex, List<Map<String, dynamic>> subtitleTracks) {
    if (subtitleTracks.isEmpty) return -1;
    final ids = subtitleTracks.map((t) => t['id']?.toString() ?? '').toList();
    for (int i = 0; i < ids.length; i++) {
      final parts = ids[i].split('_');
      if (parts.length == 2 && int.tryParse(parts[0]) == embyStreamIndex) {
        return i;
      }
    }
    final sorted = List<Map<String, dynamic>>.from(subtitleTracks);
    sorted.sort((a, b) {
      final aId = a['id']?.toString() ?? '0';
      final bId = b['id']?.toString() ?? '0';
      final aGroup = int.tryParse(aId.split('_').first) ?? 0;
      final bGroup = int.tryParse(bId.split('_').first) ?? 0;
      if (aGroup != bGroup) return aGroup.compareTo(bGroup);
      final aTrack = int.tryParse(aId.split('_').last) ?? 0;
      final bTrack = int.tryParse(bId.split('_').last) ?? 0;
      return aTrack.compareTo(bTrack);
    });
    int subCounter = 0;
    for (int i = 0; i < sorted.length; i++) {
      final groupStr = sorted[i]['id'].toString().split('_').first;
      final group = int.tryParse(groupStr) ?? 0;
      if (group == embyStreamIndex) return subCounter;
      subCounter++;
    }
    return -1;
  }

  int? _extractEmbySubtitleIndex(String? trackId) {
    if (trackId == null || trackId.isEmpty) return null;
    final parts = trackId.split('_');
    if (parts.length != 2) return null;
    return int.tryParse(parts.first);
  }

  bool _titlesMatch(String embyTitle, String playerTitle) {
    final e = embyTitle.toLowerCase();
    final p = playerTitle.toLowerCase();
    if (e == p) return true;
    if (p.contains(e) || e.contains(p)) return true;
    final simpKeywords = ['简', 'chs', '简体', '简日', 'gb', '简中'];
    final tradKeywords = ['繁', 'cht', '繁体', '繁日', 'big5', '繁中'];
    final eIsSimp = simpKeywords.any((k) => e.contains(k));
    final eIsTrad = tradKeywords.any((k) => e.contains(k));
    final pIsSimp = simpKeywords.any((k) => p.contains(k));
    final pIsTrad = tradKeywords.any((k) => p.contains(k));
    if (eIsSimp && pIsSimp) return true;
    if (eIsTrad && pIsTrad) return true;
    return false;
  }

  Future<void> _selectInternalSubtitleViaTrack(MediaStream target, int next, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) =>
        (t['type'] == 'text' || t['type'] == 'bitmap') &&
        t['id'] != 'auto' && t['id'] != 'no').toList();

    String? trackId;
    final targetDisplayTitle = target.displayTitle ?? target.title;

    if (_playerService.coreType == PlayerCoreType.mpv) {
      trackId = _matchMpvSubtitleTrack(
        subtitleTracks, target.language, targetDisplayTitle,
        target.codec, next,
      );
    } else {
      trackId = _matchExoSubtitleTrack(
        subtitleTracks, target.language, targetDisplayTitle,
        target.codec, next,
      );
    }

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', '切换字幕轨道: id=$trackId');
    } else {
      logger.w('Player', '切换字幕轨道: 未找到匹配轨道, targetIndex=$next, lang=${target.language}, title=$targetDisplayTitle');
    }
  }

  Future<void> _onSubtitleTrackChanged(int? prev, int? next) async {
    if (prev == next || next == null) {
      if (next == null && prev != null) {
        await _playerService.deselectSubtitleTrack();
      }
      return;
    }

    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;

    final api = ref.read(apiClientProvider);
    final logger = AppLogger();

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;

      final subtitleStreams = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = _isGraphicalSubtitleCodec(codec);

      if (!isExternal) {
        final isAss = _isAssSubtitleCodec(codec);
        final isExoAss = _playerService.coreType == PlayerCoreType.exoPlayer &&
            isAss && !isGraphical;

        if (isExoAss) {
          try {
            logger.i('Player', 'EXO内核: 内封ASS切换直接走Media3轨道选择');
            await _selectInternalSubtitleViaTrack(target, next, logger);
          } catch (e, stackTrace) {
            logger.eWithStack('Player', 'EXO内封ASS切换失败，回退原生轨道选择', e, stackTrace);
            await _selectInternalSubtitleViaTrack(target, next, logger);
          }
        } else {
          await _selectInternalSubtitleViaTrack(target, next, logger);
        }
      } else {
        final embyCodec = _embySubtitleCodec(codec);
        final isGraphicalExternal = _isGraphicalSubtitleCodec(codec);

        if (_playerService.coreType == PlayerCoreType.mpv || isGraphicalExternal) {
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );

          await _playerService.deselectSubtitleTrack();

          if (isGraphicalExternal) {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );
            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          } else {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );

            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          }
        } else {
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );
          if (_playerService.coreType == PlayerCoreType.exoPlayer) {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );

            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          } else {
            await _playerService.loadLibassSubtitle(subUrl);
          }
        }
      }
    } catch (e) {
      logger.e('Player', '切换字幕轨道失败: $e');
    }
  }

  Future<void> _onSecondarySubtitleTrackChanged(int? next) async {
    if (next == null) {
      await _playerService.deselectSecondarySubtitle();
      return;
    }

    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;

    final api = ref.read(apiClientProvider);
    final server = ref.read(currentServerProvider);
    final logger = AppLogger();

    if (_playerService.coreType != PlayerCoreType.mpv) {
      logger.w('Player', '次字幕仅支持MPV内核');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('次字幕功能需要MPV内核，请在设置中切换')),
        );
      }
      return;
    }

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;

      final subtitleStreams = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec.contains('hdmv') || codec.contains('pgs');

      if (isGraphical) {
        logger.w('Player', '次字幕: 图形字幕暂不支持作为次字幕');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('图形字幕(PGS/SUP)暂不支持作为次字幕')),
          );
        }
        return;
      }

      if (!isExternal) {
        logger.i('Player', '次字幕: 内封字幕，通过MPV轨道ID直接设置');
        final tracks = _playerService.tracksInfo;
        final subtitleTracks = tracks.where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' && t['id'] != 'no').toList();
        final currentPrimaryIndex = ref.read(subtitleTrackProvider);
        String? primaryTrackId;
        if (currentPrimaryIndex != null) {
          final primaryTarget = subtitleStreams.where((s) => s.index == currentPrimaryIndex).firstOrNull;
          if (primaryTarget != null) {
            primaryTrackId = _matchMpvSubtitleTrack(
              subtitleTracks,
              primaryTarget.language,
              primaryTarget.displayTitle ?? primaryTarget.title,
              primaryTarget.codec,
              primaryTarget.index,
            );
          }
        }

        final trackId = _matchMpvSecondarySubtitleTrack(
          subtitleTracks,
          target,
          primaryTrackId,
        );

        if (trackId != null && trackId.isNotEmpty) {
          await _playerService.selectSecondarySubtitleTrack(trackId);
          logger.i('Player', '内封次字幕已设置: trackId=$trackId');
        } else {
          logger.w('Player', '未找到匹配的MPV字幕轨道');
        }
        return;
      }

      final embyCodec = _embySubtitleCodec(codec);
      final subUrl = api.playback.getSubtitleStreamUrl(
        item.id,
        mediaSource.id,
        target.index,
        embyCodec,
      );

      final tempDir = await getTemporaryDirectory();
      final ext = _subtitleFileExtension(codec, _playerService.coreType);
      final subFile = File('${tempDir.path}/secondary_subtitle_${item.id}_${target.index}.$ext');

      if (!subFile.existsSync() || await subFile.length() == 0) {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ));
        if (server?.authToken != null) {
          dio.options.headers['X-Emby-Token'] = server!.authToken;
          dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
        }
        await dio.download(subUrl, subFile.path);
      }

      if (subFile.existsSync() && await subFile.length() > 0) {
        await _playerService.loadSecondarySubtitle(subFile.path);
        logger.i('Player', '次字幕加载成功: ${subFile.path}');
      }
    } catch (e) {
      logger.e('Player', '加载次字幕失败: $e');
    }
  }

  void _onPlayerUpdate() {
    setState(() {});
    _checkSkipOpening();
  }

  bool _showSkipButton = false;
  Timer? _skipButtonTimer;

  void _checkSkipOpening() {
    final openingStart = ref.read(skipOpeningStartProvider);
    final openingEnd = ref.read(skipOpeningEndProvider);
    final autoSkip = ref.read(skipAutoModeProvider);
    if (openingStart <= 0 || openingEnd <= 0 || openingEnd <= openingStart) return;

    final pos = _playerService.position.inSeconds;
    final inOpening = pos >= openingStart && pos < openingEnd;

    if (inOpening && autoSkip) {
      _playerService.seekTo(Duration(seconds: openingEnd));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已自动跳过片头')),
      );
    } else if (inOpening && !_showSkipButton) {
      setState(() => _showSkipButton = true);
      _skipButtonTimer?.cancel();
      _skipButtonTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _showSkipButton = false);
      });
    } else if (!inOpening && _showSkipButton) {
      setState(() => _showSkipButton = false);
      _skipButtonTimer?.cancel();
    }
  }

  void _onSkipOpeningPressed() {
    final openingEnd = ref.read(skipOpeningEndProvider);
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _playerService.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activePlayerService = null;
    _playerService.removeListener(_onPlayerUpdate);
    _playerService.dispose();
    _longPressTimer?.cancel();
    _skipButtonTimer?.cancel();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onTap: _playerService.toggleControls,
            onDoubleTapDown: _onDoubleTapDown,
            onLongPressStart: (_) => _onLongPressStart(),
            onLongPressEnd: (_) => _onLongPressEnd(),
            onHorizontalDragStart: (details) => _playerService.onDragStart(details, constraints),
            onHorizontalDragUpdate: (details) => _playerService.onDragUpdate(details, constraints),
            onHorizontalDragEnd: _playerService.onDragEnd,
            onVerticalDragStart: (details) => _playerService.onDragStart(details, constraints),
            onVerticalDragUpdate: (details) => _playerService.onDragUpdate(details, constraints),
            onVerticalDragEnd: _playerService.onDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildVideoArea(),

                if (_playerService.isBuffering)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),

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

                // 亮度/音量手势指示器
                if (_playerService.isDragging)
                  _buildGestureIndicator(),

                // 长按快进指示器
                if (_isLongPressing)
                  _buildLongPressIndicator(),

                // 控制层
                if (_playerService.showControls && !_playerService.isLocked)
                  _buildControlsOverlay(item),

                // 锁定按钮（始终显示）
                if (_playerService.isLocked)
                  Positioned(
                    top: 40,
                    left: 16,
                    child: IconButton(
                      icon: const Icon(Icons.lock, color: Colors.white),
                      onPressed: _playerService.toggleLock,
                    ),
                  ),

                // 拖动进度提示
                if (_playerService.isDragging)
                  _buildDragIndicator(),

                // 跳过片头按钮
                if (_showSkipButton)
                  Positioned(
                    top: 100,
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
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildVideoArea() {
    final videoWidget = _playerService.buildVideo();
    final danmakuItems = ref.watch(loadedDanmakuProvider);
    final danmakuEnabled = ref.watch(danmakuEnabledProvider);
    final danmakuOpacity = ref.watch(danmakuOpacityProvider);
    final danmakuFontSize = ref.watch(danmakuFontSizeProvider);
    final danmakuSpeed = ref.watch(danmakuSpeedProvider);
    final danmakuDensity = ref.watch(danmakuDensityProvider);
    final danmakuDelay = ref.watch(danmakuDelayProvider);

    if (_playerService.coreType != PlayerCoreType.exoPlayer) {
      final overlays = <Widget>[];
      if (danmakuEnabled && danmakuItems.isNotEmpty) {
        final delayedPosition = _playerService.position -
            Duration(milliseconds: (danmakuDelay * 1000).round());
        overlays.add(
          Positioned.fill(
            child: DanmakuOverlay(
              items: danmakuItems,
              position: delayedPosition,
              isPlaying: _playerService.isPlaying,
              opacity: danmakuOpacity,
              fontSizeFactor: danmakuFontSize,
              speedFactor: danmakuSpeed,
              densityFactor: danmakuDensity,
            ),
          ),
        );
      }
      if (overlays.isEmpty) return videoWidget;
      return Stack(fit: StackFit.expand, children: [videoWidget, ...overlays]);
    }

    final adapter = _playerService.adapter;
    if (adapter is! ExoPlayerAdapter) {
      return videoWidget;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentRect = _computeContentRect(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        final delayedPosition = _playerService.position -
            Duration(milliseconds: (danmakuDelay * 1000).round());

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: contentRect,
              child: videoWidget,
            ),
            if (danmakuEnabled && danmakuItems.isNotEmpty)
              Positioned.fromRect(
                rect: contentRect,
                child: DanmakuOverlay(
                  items: danmakuItems,
                  position: delayedPosition,
                  isPlaying: _playerService.isPlaying,
                  opacity: danmakuOpacity,
                  fontSizeFactor: danmakuFontSize,
                  speedFactor: danmakuSpeed,
                  densityFactor: danmakuDensity,
                ),
              ),
            if (contentRect == Rect.zero)
              Positioned.fill(
                child: IgnorePointer(
                  child: videoWidget,
                ),
              ),
          ],
        );
      },
    );
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_playerService.isLocked) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < screenWidth / 3) {
      _playerService.seekBy(Duration(seconds: -ref.read(skipForwardStepProvider)));
    } else if (tapX > screenWidth * 2 / 3) {
      _playerService.seekBy(Duration(seconds: ref.read(skipForwardStepProvider)));
    } else {
      _playerService.togglePlay();
    }
  }

  void _onLongPressStart() {
    if (_playerService.isLocked) return;
    setState(() => _isLongPressing = true);
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isLongPressing) {
        _playerService.setSpeed(ref.read(longPressSpeedProvider));
      }
    });
  }

  void _onLongPressEnd() {
    setState(() => _isLongPressing = false);
    _longPressTimer?.cancel();
    _playerService.setSpeed(ref.read(defaultPlaybackSpeedProvider));
  }

  Widget _buildGestureIndicator() {
    final screenWidth = MediaQuery.of(context).size.width;
    final dragX = _playerService.dragStartX;

    String label;
    IconData icon;
    double value;

    if (dragX < screenWidth / 2) {
      // 左侧：亮度
      label = '亮度';
      icon = Icons.brightness_high;
      value = _playerService.brightness;
    } else {
      // 右侧：音量
      label = '音量';
      icon = Icons.volume_up;
      value = _playerService.volume;
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 100,
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(value * 100).toInt()}%',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLongPressIndicator() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fast_forward, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              '${ref.read(longPressSpeedProvider)}x 快进中',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(MediaItem? item) {
    return AnimatedOpacity(
      opacity: _playerService.showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: SafeArea(
        child: Column(
          children: [
            _buildTopBar(item),
            Expanded(
              child: Row(
                children: [
                  _buildLeftSideControls(),
                  const Spacer(),
                  _buildRightSideControls(),
                ],
              ),
            ),
            _buildProgressBar(),
            _buildBottomBar(item),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(MediaItem? item) {
    final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
    final isMpv = coreString == 'mpv';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.pop(),
          ),
          Expanded(
            child: _MarqueeText(
              text: item?.name ?? widget.itemId,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          if (isMpv)
            IconButton(
              icon: const Icon(Icons.hd, color: Colors.white),
              tooltip: '超分 (Anime4K)',
              onPressed: () async {
                await _playerService.applySuperResolution(true);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已开启 Anime4K 超分辨率')),
                  );
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white),
            tooltip: '跳过片头/片尾',
            onPressed: _showSkipDialog,
          ),
          IconButton(
            icon: Icon(
              ref.read(hardwareDecodingProvider) ? Icons.memory : Icons.slow_motion_video,
              color: Colors.white,
            ),
            tooltip: '硬解/软解',
            onPressed: () async {
              final current = ref.read(hardwareDecodingProvider);
              ref.read(hardwareDecodingProvider.notifier).state = !current;
              // 重新初始化播放器以应用硬解/软解设置
              final savedPosition = _playerService.position;
              await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
              await _initializePlayer();
              if (savedPosition > Duration.zero) {
                await _playerService.seekTo(savedPosition);
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(!current ? '已切换硬件解码' : '已切换软件解码')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  Widget _buildLeftSideControls() {
    return SizedBox(
      width: 60,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.camera_alt, color: Colors.white),
            tooltip: '截图',
            onPressed: _takeScreenshot,
          ),
          IconButton(
            icon: Icon(
              _playerService.isLocked ? Icons.lock : Icons.lock_open,
              color: Colors.white,
            ),
            tooltip: '锁定',
            onPressed: _playerService.toggleLock,
          ),
        ],
      ),
    );
  }

  Widget _buildRightSideControls() {
    return SizedBox(
      width: 60,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.add, color: Colors.white),
            onPressed: () {
              final newSpeed = (_playerService.speed + 0.25).clamp(0.25, 4.0);
              _playerService.setSpeed(newSpeed);
            },
          ),
          Text(
            '${_playerService.speed}x',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove, color: Colors.white),
            onPressed: () {
              final newSpeed = (_playerService.speed - 0.25).clamp(0.25, 4.0);
              _playerService.setSpeed(newSpeed);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final currentTime = _formatDuration(_playerService.position);
    final remainingTime = _formatDuration(_playerService.duration - _playerService.position);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _showRemaining = !_showRemaining),
                child: Text(
                  _showRemaining ? '-$remainingTime' : currentTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF5B8DEF),
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: const Color(0xFF5B8DEF),
                    overlayColor: const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                    trackHeight: 3,
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
              Text(
                _formatDuration(_playerService.duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(MediaItem? item) {
    final isPlaying = _playerService.isPlaying;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white),
            tooltip: '上一集',
            onPressed: _playPrevious,
          ),
          IconButton(
            icon: const Icon(Icons.replay_10, color: Colors.white),
            tooltip: '快退 10s',
            onPressed: () => _playerService.seekBy(const Duration(seconds: -10)),
          ),
          IconButton(
            icon: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 40,
            ),
            tooltip: '播放/暂停',
            onPressed: _playerService.togglePlay,
          ),
          IconButton(
            icon: const Icon(Icons.forward_10, color: Colors.white),
            tooltip: '快进 10s',
            onPressed: () => _playerService.seekBy(const Duration(seconds: 10)),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white),
            tooltip: '下一集',
            onPressed: _playNext,
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, color: Colors.white),
            tooltip: '弹幕设置',
            onPressed: _showDanmakuSettings,
          ),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: '搜索弹幕',
            onPressed: _showDanmakuSearch,
          ),
          IconButton(
            icon: const Icon(Icons.subtitles, color: Colors.white),
            tooltip: '字幕设置',
            onPressed: _showSubtitleSettings,
          ),
          IconButton(
            icon: const Icon(Icons.audiotrack, color: Colors.white),
            tooltip: '音频设置',
            onPressed: _showAudioSettings,
          ),
          IconButton(
            icon: const Icon(Icons.playlist_play, color: Colors.white),
            tooltip: '选集',
            onPressed: () => _showEpisodeSelector(item),
          ),
        ],
      ),
    );
  }

  Widget _buildDragIndicator() {
    final direction = _playerService.dragDirection;
    final isForward = direction == 1;
    final isBackward = direction == -1;

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isForward
                  ? Icons.fast_forward
                  : isBackward
                      ? Icons.fast_rewind
                      : Icons.drag_handle,
              color: Colors.white,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              _formatDuration(_playerService.position),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _playPrevious() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
          currentItem!.seriesId!,
          seasonId: currentItem.seasonId,
        );
        final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
        if (currentIndex > 0) {
          final prevEpisode = episodes[currentIndex - 1];
          if (mounted) {
            context.replace('/player/${prevEpisode.id}');
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
  }

  Future<void> _playNext() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
          currentItem!.seriesId!,
          seasonId: currentItem.seasonId,
        );
        final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
        if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
          final nextEpisode = episodes[currentIndex + 1];
          if (mounted) {
            context.replace('/player/${nextEpisode.id}');
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
  }

  void _showMoreMenu() {
    _showRightPanel(
      title: '更多选项',
      children: [
        ListTile(
          leading: const Icon(Icons.route, color: Colors.white),
          title: const Text('线路切换', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showLineSelector();
          },
        ),
        ListTile(
          leading: const Icon(Icons.screen_rotation, color: Colors.white),
          title: const Text('旋转屏幕', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _toggleOrientation();
          },
        ),
        ListTile(
          leading: const Icon(Icons.timer, color: Colors.white),
          title: const Text('定时关闭', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showTimerDialog();
          },
        ),
        if (!isDesktopPlatform)
          ListTile(
          leading: const Icon(Icons.memory, color: Colors.white),
          title: const Text('内核切换', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showCoreSwitchDialog();
          },
        ),
        ListTile(
          leading: const Icon(Icons.analytics, color: Colors.white),
          title: const Text('统计信息', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showStats();
          },
        ),
        ListTile(
          leading: const Icon(Icons.aspect_ratio, color: Colors.white),
          title: const Text('画面比例', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _showAspectRatioDialog();
          },
        ),
      ],
    );
  }

  void _showRightPanel({required String title, required List<Widget> children}) {
    final screenSize = MediaQuery.of(context).size;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: screenSize.width * 0.35,
              constraints: BoxConstraints(
                maxHeight: screenSize.height * 0.8,
              ),
              margin: const EdgeInsets.only(right: 0),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.88),
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(-5, 0),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 标题栏
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.white.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => Navigator.pop(dialogContext),
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                child: const Icon(
                                  Icons.close,
                                  color: Colors.white70,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 内容区域
                    Flexible(
                      child: Theme(
                        data: Theme.of(dialogContext).copyWith(
                          listTileTheme: const ListTileThemeData(
                            textColor: Colors.white,
                            iconColor: Colors.white70,
                            selectedColor: Color(0xFF5B8DEF),
                          ),
                          radioTheme: RadioThemeData(
                            fillColor: WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return const Color(0xFF5B8DEF);
                              }
                              return Colors.white54;
                            }),
                          ),
                        ),
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: children,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: child,
        );
      },
    );
  }

  void _showSkipDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (context) => Dialog(
        backgroundColor: Colors.black87,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: _SkipDialog(currentPosition: _playerService.position),
      ),
    );
  }

  void _toggleOrientation() {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.portrait) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  Future<void> _takeScreenshot() async {
    try {
      final data = await _playerService.screenshot();
      if (!mounted) return;
      if (data != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图已保存')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图功能暂不支持当前播放器内核')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('截图失败: $e')),
      );
    }
  }

  void _showStats() {
    _showRightPanel(
      title: '播放统计',
      children: [
        ListTile(
          title: const Text('播放速度', style: TextStyle(color: Colors.white70)),
          trailing: Text('${_playerService.speed}x', style: const TextStyle(color: Colors.white)),
        ),
        ListTile(
          title: const Text('音量', style: TextStyle(color: Colors.white70)),
          trailing: Text('${(_playerService.volume * 100).toInt()}%', style: const TextStyle(color: Colors.white)),
        ),
        ListTile(
          title: const Text('亮度', style: TextStyle(color: Colors.white70)),
          trailing: Text('${(_playerService.brightness * 100).toInt()}%', style: const TextStyle(color: Colors.white)),
        ),
        ListTile(
          title: const Text('播放状态', style: TextStyle(color: Colors.white70)),
          trailing: Text(_playerService.isPlaying ? '播放中' : '已暂停', style: const TextStyle(color: Colors.white)),
        ),
        ListTile(
          title: const Text('当前位置', style: TextStyle(color: Colors.white70)),
          trailing: Text(
            '${_formatDuration(_playerService.position)} / ${_formatDuration(_playerService.duration)}',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }

  void _showDanmakuSettings() {
    _showRightPanel(
      title: '弹幕设置',
      children: [
        const _DanmakuSettingsContent(),
      ],
    );
  }

  void _showDanmakuSearch() {
    final item = ref.read(currentPlayingItemProvider);
    _showRightPanel(
      title: '搜索弹幕',
      children: [
        DanmakuSearchContent(item: item),
      ],
    );
  }

  void _showSubtitleSettings() {
    _showRightPanel(
      title: '字幕设置',
      children: [
        const _SubtitleSettingsContent(),
      ],
    );
  }

  Future<void> _applyInitialAudioTrack(List<MediaStream> audioStreams, int selectedIndex) async {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((track) => track['type'] == 'audio').toList();
    final audioPosition = audioStreams.indexWhere((stream) => stream.index == selectedIndex);
    if (audioPosition < 0 || audioPosition >= audioTracks.length) {
      return;
    }
    final trackId = audioTracks[audioPosition]['id']?.toString();
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  void _showAudioSettings() {
    _showRightPanel(
      title: '音频设置',
      children: [
        const _AudioSettingsContent(),
      ],
    );
  }

  void _showEpisodeSelector(MediaItem? item) {
    if (item?.seriesId == null) return;

    _showRightPanel(
      title: '选集',
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: _EpisodeSelectorContent(
            seriesId: item!.seriesId!,
            currentEpisodeId: item.id,
            currentMediaSourceId: ref.read(selectedMediaSourceProvider),
          ),
        ),
      ],
    );
  }

  void _showTimerDialog() {
    final options = [15, 30, 45, 60, 90, 120];
    _showRightPanel(
      title: '定时关闭',
      children: [
        ...options.map((minutes) => ListTile(
          title: Text('$minutes 分钟后关闭', style: const TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            _startSleepTimer(Duration(minutes: minutes));
          },
        )),
      ],
    );
  }

  void _startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(duration, () {
      if (mounted) {
        _playerService.pause();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已定时关闭播放')),
        );
      }
      _sleepTimer = null;
    });
    ref.read(sleepTimerRemainingProvider.notifier).state = duration;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已设置 ${duration.inMinutes} 分钟后关闭')),
    );
  }

  void _showCoreSwitchDialog() {
    final currentCore = normalizePlayerCore(ref.read(playerCoreProvider));
    _showRightPanel(
      title: '切换播放器内核',
      children: [
        ListTile(
          title: const Text('ExoPlayer', style: TextStyle(color: Colors.white)),
          subtitle: const Text('Android 原生，轻量稳定', style: TextStyle(fontSize: 12, color: Colors.white70)),
          leading: currentCore == 'exoPlayer'
              ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
              : null,
          onTap: () {
            Navigator.pop(context);
            if (currentCore != 'exoPlayer') {
              _switchCore('exoPlayer');
            }
          },
        ),
        ListTile(
          title: const Text('MPV', style: TextStyle(color: Colors.white)),
          subtitle: const Text('libmpv FFI，全格式/HDR/高级字幕', style: TextStyle(fontSize: 12, color: Colors.white70)),
          leading: currentCore == 'mpv'
              ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
              : null,
          onTap: () {
            Navigator.pop(context);
            if (currentCore != 'mpv') {
              _switchCore('mpv');
            }
          },
        ),
      ],
    );
  }

  Future<void> _switchCore(String core) async {
    final savedPosition = _playerService.position;
    ref.read(playerCoreProvider.notifier).state = normalizePlayerCore(core);
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer();
    if (savedPosition > Duration.zero) {
      await _playerService.seekTo(savedPosition);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到 ${core == 'mpv' ? 'MPV' : 'ExoPlayer'}')),
      );
    }
  }

  void _showLineSelector() {
    final server = ref.read(currentServerProvider);
    if (server == null || server.lines.length <= 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前只有一个可用线路')),
        );
      }
      return;
    }
    _showRightPanel(
      title: '选择线路',
      children: [
        ...server.lines.asMap().entries.map((entry) {
          final idx = entry.key;
          final line = entry.value;
          return ListTile(
            leading: const Icon(Icons.route, color: Colors.white70),
            title: Text(line.name, style: const TextStyle(color: Colors.white)),
            trailing: idx == server.activeLineIndex
                ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                : null,
                onTap: () async {
                  ref.read(serverListProvider.notifier).setActiveLine(server.id, idx);
                  // 同步更新 currentServerProvider
                  final updatedServer = ref.read(serverListProvider).firstWhere((s) => s.id == server.id);
                  ref.read(currentServerProvider.notifier).state = updatedServer;
                  Navigator.pop(context);
                  // 重新初始化播放器以应用新线路
                  final savedPosition = _playerService.position;
                  await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
                  await _initializePlayer();
                  if (savedPosition > Duration.zero) {
                    await _playerService.seekTo(savedPosition);
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已切换到线路: ${line.name}')),
                    );
                  }
                },
              );
            }),
          ],
        );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自动', '16:9', '4:3', '21:9', '全屏', '原始'];
    _showRightPanel(
      title: '画面比例',
      children: ratios.map((ratio) => ListTile(
        title: Text(ratio, style: const TextStyle(color: Colors.white)),
        trailing: ref.read(aspectRatioProvider) == ratio
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
      )).toList(),
    );
  }
}

/// 滚动文字组件
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    );
    _animation = Tween<double>(begin: 1.0, end: -1.0).animate(_controller);
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return FractionalTranslation(
            translation: Offset(_animation.value, 0),
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.visible,
              style: widget.style,
            ),
          );
        },
      ),
    );
  }
}

/// 跳过片头/片尾弹窗
class _SkipDialog extends ConsumerStatefulWidget {
  final Duration currentPosition;

  const _SkipDialog({required this.currentPosition});

  @override
  ConsumerState<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends ConsumerState<_SkipDialog> {
  late Duration _openingStart;
  late Duration _openingEnd;
  late bool _autoSkip;

  @override
  void initState() {
    super.initState();
    final openingStartSec = ref.read(skipOpeningStartProvider);
    final openingEndSec = ref.read(skipOpeningEndProvider);
    _openingStart = Duration(seconds: openingStartSec);
    _openingEnd = Duration(seconds: openingEndSec);
    _autoSkip = ref.read(skipAutoModeProvider);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳过片头'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('开始时间'),
              const Spacer(),
              Text(_formatTime(_openingStart)),
              IconButton(
                icon: const Icon(Icons.location_on),
                tooltip: '取当前时间',
                onPressed: () {
                  setState(() => _openingStart = widget.currentPosition);
                },
              ),
            ],
          ),
          Row(
            children: [
              const Text('结束时间'),
              const Spacer(),
              Text(_formatTime(_openingEnd)),
              IconButton(
                icon: const Icon(Icons.location_on),
                tooltip: '取当前时间',
                onPressed: () {
                  setState(() => _openingEnd = widget.currentPosition);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('跳过模式'),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('显示按钮')),
                  ButtonSegment(value: true, label: Text('自动跳过')),
                ],
                selected: {_autoSkip},
                onSelectionChanged: (value) {
                  setState(() => _autoSkip = value.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前: ${_autoSkip ? "自动跳过" : "显示跳过按钮"}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            ref.read(skipOpeningStartProvider.notifier).state = _openingStart.inSeconds;
            ref.read(skipOpeningEndProvider.notifier).state = _openingEnd.inSeconds;
            ref.read(skipAutoModeProvider.notifier).state = _autoSkip;
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('跳过设置已保存')),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  String _formatTime(Duration duration) {
    final m = duration.inMinutes.toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// 弹幕设置内容
class _DanmakuSettingsContent extends ConsumerWidget {
  const _DanmakuSettingsContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final danmakuEnabled = ref.watch(danmakuEnabledProvider);
    final danmakuOpacity = ref.watch(danmakuOpacityProvider);
    final danmakuFontSize = ref.watch(danmakuFontSizeProvider);
    final danmakuSpeed = ref.watch(danmakuSpeedProvider);
    final danmakuDensity = ref.watch(danmakuDensityProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: const Text('显示弹幕', style: TextStyle(color: Colors.white)),
          value: danmakuEnabled,
          onChanged: (value) {
            ref.read(danmakuEnabledProvider.notifier).state = value;
          },
        ),
        const Divider(color: Colors.white24),
        const Text('不透明度', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuOpacity,
          onChanged: (value) {
            ref.read(danmakuOpacityProvider.notifier).state = value;
          },
        ),
        const Text('字号', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuFontSize,
          onChanged: (value) {
            ref.read(danmakuFontSizeProvider.notifier).state = value;
          },
        ),
        const Text('速度', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuSpeed,
          onChanged: (value) {
            ref.read(danmakuSpeedProvider.notifier).state = value;
          },
        ),
        const Text('密度', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuDensity,
          onChanged: (value) {
            ref.read(danmakuDensityProvider.notifier).state = value;
          },
        ),
        const Text('延迟', style: TextStyle(color: Colors.white70)),
        Consumer(builder: (context, ref, _) {
          final delay = ref.watch(danmakuDelayProvider);
          return Slider(
            value: delay,
            min: -5.0,
            max: 5.0,
            label: '${delay.toStringAsFixed(1)}s',
            onChanged: (value) {
              ref.read(danmakuDelayProvider.notifier).state = value;
            },
          );
        }),
        const Text('去重', style: TextStyle(color: Colors.white70)),
        Consumer(builder: (context, ref, _) {
          final dedup = ref.watch(danmakuDedupProvider);
          return Switch(
            value: dedup,
            onChanged: (v) => ref.read(danmakuDedupProvider.notifier).state = v,
          );
        }),
      ],
    );
  }
}

/// 字幕设置弹窗
class _SubtitleSettingsContent extends ConsumerStatefulWidget {
  const _SubtitleSettingsContent();

  @override
  ConsumerState<_SubtitleSettingsContent> createState() => _SubtitleSettingsContentState();
}

class _SubtitleSettingsContentState extends ConsumerState<_SubtitleSettingsContent> {
  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final subtitleAsync = item != null ? ref.watch(playbackInfoProvider(item.id)) : null;
    final subtitleOffset = ref.watch(subtitleDelayProvider);
    final subtitleSize = ref.watch(subtitleSizeProvider);
    final subtitlePosition = ref.watch(subtitlePositionProvider);
    final subtitleFont = ref.watch(subtitleFontProvider);
    final subtitleBackground = ref.watch(subtitleBackgroundProvider);
    final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
    final selectedSecondaryIndex = ref.watch(secondarySubtitleTrackProvider);
    final selectedMediaSourceId = ref.watch(selectedMediaSourceProvider);

    if (subtitleAsync == null) {
      return const _SettingsSection(
        children: [Center(child: Text('无播放信息', style: TextStyle(color: Colors.white70)))],
      );
    }

    return subtitleAsync.when(
      data: (info) {
        final fallbackMediaSource = info.mediaSources.firstOrNull;
        if (fallbackMediaSource == null) {
          return const _SettingsSection(
            children: [
              Center(child: Text('无可用字幕轨道', style: TextStyle(color: Colors.white70))),
            ],
          );
        }
        final mediaSource = selectedMediaSourceId != null
            ? info.mediaSources.firstWhere(
                (source) => source.id == selectedMediaSourceId,
                orElse: () => fallbackMediaSource,
              )
            : fallbackMediaSource;
        final subtitles = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
        final playerService = _PlayerScreenState.activePlayerService;
        final nameMap = _buildSubtitleNameMap(subtitles, playerService);

        return _SettingsSection(
          children: [
            const _SectionTitle('字幕轨道'),
            if (subtitles.isEmpty)
              const ListTile(
                leading: Icon(Icons.subtitles_off, color: Colors.white54),
                title: Text('无可用字幕', style: TextStyle(color: Colors.white70)),
              )
            else
              RadioGroup<int>(
                groupValue: selectedSubtitleIndex,
                onChanged: (value) {
                  ref.read(subtitleTrackProvider.notifier).state = value;
                },
                child: Column(
                  children: subtitles.map((stream) => RadioListTile<int>(
                    title: Text(
                      nameMap[stream.index] ?? stream.readableLabel(siblings: subtitles),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: stream.codec != null
                        ? Text('编码: ${stream.codec}${stream.isExternal == true ? ' (外挂)' : ' (内封)'}', style: const TextStyle(color: Colors.white54, fontSize: 12))
                        : null,
                    value: stream.index,
                  )).toList(),
                ),
              ),
            const SizedBox(height: 8),
            _SettingsButton(
              icon: Icons.upload_file,
              label: '导入外部字幕',
              onTap: () => _pickExternalSubtitle(),
            ),
            const SizedBox(height: 16),
            const _Divider(),
            const _SectionTitle('次字幕（第二字幕）'),
            RadioGroup<int?>(
              groupValue: selectedSecondaryIndex,
              onChanged: (value) {
                ref.read(secondarySubtitleTrackProvider.notifier).state = value;
              },
              child: Column(
                children: [
                  const RadioListTile<int?>(
                    title: Text('关闭', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    value: null,
                  ),
                  if (subtitles.isEmpty)
                    const ListTile(
                      title: Text('无可用次字幕', style: TextStyle(color: Colors.white70)),
                    )
                  else
                    ...subtitles.map((stream) => RadioListTile<int?>(
                      title: Text(
                        nameMap[stream.index] ?? stream.readableLabel(siblings: subtitles),
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      value: stream.index,
                    )),
                ],
              ),
            ),
            const _Divider(),
            const _SectionTitle('字体'),
            _SettingsItem(
              label: subtitleFont,
              onTap: () => _showFontSelector(context),
            ),
            const _Divider(),
            const _SectionTitle('字幕同步'),
            _SyncControl(
              value: subtitleOffset,
              onDecrease: () => ref.read(subtitleDelayProvider.notifier).state = subtitleOffset - 0.5,
              onIncrease: () => ref.read(subtitleDelayProvider.notifier).state = subtitleOffset + 0.5,
              onCustom: () => _showCustomOffsetDialog(context),
              onReset: () => ref.read(subtitleDelayProvider.notifier).state = 0.0,
            ),
            const _Divider(),
            const _SectionTitle('字幕大小'),
            Slider(
              value: subtitleSize.clamp(0.0, 1.0),
              onChanged: (value) => ref.read(subtitleSizeProvider.notifier).state = value,
              activeColor: const Color(0xFF5B8DEF),
              inactiveColor: Colors.white24,
            ),
            const _SectionTitle('字幕位置'),
            Slider(
              value: subtitlePosition.clamp(0.0, 1.0),
              onChanged: (value) => ref.read(subtitlePositionProvider.notifier).state = value,
              activeColor: const Color(0xFF5B8DEF),
              inactiveColor: Colors.white24,
            ),
            const _Divider(),
            SwitchListTile(
              title: const Text('字幕黑色背景', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('为字幕添加半透明黑色背景', style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: subtitleBackground,
              onChanged: (value) => ref.read(subtitleBackgroundProvider.notifier).state = value,
            ),
          ],
        );
      },
      loading: () => const _SettingsSection(
        children: [Center(child: CircularProgressIndicator(color: Colors.white54))],
      ),
      error: (_, __) => const _SettingsSection(
        children: [Center(child: Text('加载字幕信息失败', style: TextStyle(color: Colors.white70)))],
      ),
    );
  }

  Future<void> _pickExternalSubtitle() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'ass', 'ssa', 'vtt', 'sup', 'pgs'],
      );
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final logger = AppLogger();
        logger.i('Player', '导入外部字幕: $filePath');

        final playerService = _PlayerScreenState.activePlayerService;
        if (playerService != null) {
          var pathToLoad = filePath;
          final lowerExt = filePath.split('.').last.toLowerCase();
          if (playerService.coreType == PlayerCoreType.exoPlayer &&
              (lowerExt == 'ass' || lowerExt == 'ssa') &&
              !ref.read(exoLibassProvider)) {
            pathToLoad = await SubtitleProcessor.convertAssToSrt(filePath);
            logger.i('Player', '导入字幕: EXO内核已将 ASS/SSA 转为 SRT: $pathToLoad');
          }
          await playerService.loadLibassSubtitle(pathToLoad);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已导入并加载字幕: ${result.files.single.name}')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('字幕文件已选择，但播放器未就绪')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  void _showFontSelector(BuildContext context) {
    final fonts = ['默认', 'Arial', 'Helvetica', 'Times New Roman', 'Courier New'];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: fonts.map((font) => ListTile(
            title: Text(font),
            trailing: ref.read(subtitleFontProvider) == font
                ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                : null,
            onTap: () {
              ref.read(subtitleFontProvider.notifier).state = font;
              Navigator.pop(ctx);
            },
          )).toList(),
        ),
      ),
    );
  }

  void _showCustomOffsetDialog(BuildContext context) {
    final controller = TextEditingController(text: ref.read(subtitleDelayProvider).toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义字幕同步'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: const InputDecoration(
            labelText: '偏移量（秒）',
            hintText: '正数 = 延后，负数 = 提前',
            suffixText: 's',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                ref.read(subtitleDelayProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Map<int, String> _buildSubtitleNameMap(
    List<MediaStream> embySubtitles,
    VideoPlayerService? playerService,
  ) {
    final result = <int, String>{};
    if (playerService == null) return result;

    final playerTracks = playerService.tracksInfo
        .where((t) => (t['type'] == 'text' || t['type'] == 'bitmap') && t['id'] != 'auto' && t['id'] != 'no')
        .toList();

    if (playerTracks.isEmpty) return result;

    for (final stream in embySubtitles) {
      if (stream.displayTitle != null && stream.displayTitle!.isNotEmpty) continue;
      if (stream.title != null && stream.title!.isNotEmpty) {
        result[stream.index] = stream.title!;
        continue;
      }

      String? playerTitle;
      if (playerService.coreType == PlayerCoreType.exoPlayer) {
        for (final t in playerTracks) {
          if (t['groupIndex'] == stream.index) {
            playerTitle = t['label']?.toString() ?? t['title']?.toString();
            break;
          }
        }
      }

      if (playerTitle == null) {
        final lang = stream.language ?? '';
        final sameLang = playerTracks.where((t) =>
            t['language'] == lang ||
            (lang == 'chi' && (t['language'] == 'chi' || t['language'] == 'zh'))).toList();
        if (sameLang.isNotEmpty) {
          final sameCodecEmby = embySubtitles
              .where((s) => s.language == lang || (lang == 'chi' && (s.language == 'chi' || s.language == 'zh')))
              .toList();
          final posInEmby = sameCodecEmby.indexWhere((s) => s.index == stream.index);
          if (posInEmby >= 0 && posInEmby < sameLang.length) {
            playerTitle = sameLang[posInEmby]['title']?.toString();
          }
          if (playerTitle == null || playerTitle.isEmpty) {
            for (final t in sameLang) {
              final tTitle = t['title']?.toString() ?? '';
              if (tTitle.isNotEmpty) {
                final codec = stream.codec?.toLowerCase() ?? '';
                final isAss = codec == 'ass' || codec == 'ssa';
                final isBitmap = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec.contains('hdmv') || codec.contains('pgs');
                final tIsAss = (t['isAss'] == true) || (t['codec']?.toString().toLowerCase().contains('ass') == true);
                final tIsBitmap = t['isBitmap'] == true || t['type'] == 'bitmap';
                if (isAss && tIsAss && !tIsBitmap) { playerTitle = tTitle; break; }
                if (isBitmap && tIsBitmap) { playerTitle = tTitle; break; }
              }
            }
          }
        }
      }

      if (playerTitle != null && playerTitle.isNotEmpty) {
        result[stream.index] = playerTitle;
      }
    }
    return result;
  }
}

/// 音频设置内容
class _AudioSettingsContent extends ConsumerStatefulWidget {
  const _AudioSettingsContent();

  @override
  ConsumerState<_AudioSettingsContent> createState() => _AudioSettingsContentState();
}

class _AudioSettingsContentState extends ConsumerState<_AudioSettingsContent> {
  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final audioAsync = item != null ? ref.watch(playbackInfoProvider(item.id)) : null;
    final audioOffset = ref.watch(audioDelayProvider);
    final selectedIndex = ref.watch(audioTrackProvider);
    final selectedMediaSourceId = ref.watch(selectedMediaSourceProvider);

    if (audioAsync == null) {
      return const _SettingsSection(
        children: [Center(child: Text('无播放信息', style: TextStyle(color: Colors.white70)))],
      );
    }

    return audioAsync.when(
      data: (info) {
        final fallbackMediaSource = info.mediaSources.firstOrNull;
        if (fallbackMediaSource == null) {
          return const _SettingsSection(
            children: [
              Center(child: Text('无可用音轨', style: TextStyle(color: Colors.white70))),
            ],
          );
        }
        final mediaSource = selectedMediaSourceId != null
            ? info.mediaSources.firstWhere(
                (source) => source.id == selectedMediaSourceId,
                orElse: () => fallbackMediaSource,
              )
            : fallbackMediaSource;
        final audios = mediaSource.mediaStreams.where((s) => s.isAudio).toList();

        return _SettingsSection(
          children: [
            const _SectionTitle('音频轨道'),
            if (audios.isEmpty)
              const ListTile(
                leading: Icon(Icons.audiotrack, color: Colors.white54),
                title: Text('无可用音轨', style: TextStyle(color: Colors.white70)),
              )
            else
              RadioGroup<int>(
                groupValue: selectedIndex,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(audioTrackProvider.notifier).state = value;
                    _switchAudioTrack(audios, value);
                  }
                },
                child: Column(
                  children: audios.map((stream) => RadioListTile<int>(
                    title: Text(
                      stream.readableLabel(),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: stream.codec != null
                        ? Text('编码: ${stream.codec}', style: const TextStyle(color: Colors.white54, fontSize: 12))
                        : null,
                    value: stream.index,
                  )).toList(),
                ),
              ),
            const _Divider(),
            const _SectionTitle('音频同步'),
            _SyncControl(
              value: audioOffset,
              onDecrease: () => ref.read(audioDelayProvider.notifier).state = audioOffset - 0.5,
              onIncrease: () => ref.read(audioDelayProvider.notifier).state = audioOffset + 0.5,
              onCustom: () => _showCustomOffsetDialog(context),
              onReset: () => ref.read(audioDelayProvider.notifier).state = 0.0,
            ),
          ],
        );
      },
      loading: () => const _SettingsSection(
        children: [Center(child: CircularProgressIndicator(color: Colors.white54))],
      ),
      error: (_, __) => const _SettingsSection(
        children: [Center(child: Text('加载音频信息失败', style: TextStyle(color: Colors.white70)))],
      ),
    );
  }

  Future<void> _switchAudioTrack(List<MediaStream> audios, int selectedStreamIndex) async {
    final playerService = _PlayerScreenState.activePlayerService;
    if (playerService == null) return;

    final tracks = playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    final audioPosition = audios.indexWhere((stream) => stream.index == selectedStreamIndex);
    if (audioPosition < 0 || audioPosition >= audioTracks.length) {
      return;
    }
    final trackId = audioTracks[audioPosition]['id']?.toString() ?? '';
    if (trackId.isNotEmpty) {
      await playerService.selectAudioTrack(trackId);
    }
  }

  void _showCustomOffsetDialog(BuildContext context) {
    final controller = TextEditingController(text: ref.read(audioDelayProvider).toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义音频同步'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: const InputDecoration(
            labelText: '偏移量（秒）',
            hintText: '正数 = 延后，负数 = 提前',
            suffixText: 's',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                ref.read(audioDelayProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 选集内容
class _EpisodeSelectorContent extends ConsumerStatefulWidget {
  final String seriesId;
  final String currentEpisodeId;
  final String? currentMediaSourceId;

  const _EpisodeSelectorContent({
    required this.seriesId,
    required this.currentEpisodeId,
    this.currentMediaSourceId,
  });

  @override
  ConsumerState<_EpisodeSelectorContent> createState() => _EpisodeSelectorContentState();
}

 class _EpisodeSelectorContentState extends ConsumerState<_EpisodeSelectorContent> {
  String? _selectedSeasonId;
  bool _isGridView = false;

  void _playEpisode(Episode episode) {
    if (episode.id == widget.currentEpisodeId) {
      Navigator.pop(context);
      return;
    }

    final mediaSourceQuery = widget.currentMediaSourceId != null &&
            widget.currentMediaSourceId!.isNotEmpty
        ? '?mediaSourceId=${widget.currentMediaSourceId!}'
        : '';
    Navigator.pop(context);
    context.replace('/player/${episode.id}$mediaSourceQuery');
  }

  @override
  Widget build(BuildContext context) {
    final seasonsAsync = ref.watch(seasonsProvider(widget.seriesId));
    final api = ref.read(apiClientProvider);

    return Column(
      children: [
        // 头部控制栏
        Row(
          children: [
            // 季选择
            seasonsAsync.when(
              data: (seasons) {
                if (seasons.isEmpty) return const SizedBox.shrink();
                return DropdownButton<String>(
                  value: _selectedSeasonId ?? seasons.first.id,
                  items: seasons.map((season) => DropdownMenuItem(
                    value: season.id,
                    child: Text(season.name, style: const TextStyle(color: Colors.white)),
                  )).toList(),
                  onChanged: (value) {
                    setState(() => _selectedSeasonId = value);
                  },
                  dropdownColor: Colors.black87,
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const Spacer(),
            // 视图切换
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view, color: Colors.white),
              onPressed: () => setState(() => _isGridView = !_isGridView),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 集列表
        Expanded(
          child: _buildEpisodesList(api),
        ),
      ],
    );
  }

  Widget _buildEpisodesList(ApiClientFactory api) {
    final episodesAsync = ref.watch(episodesProvider((
      seriesId: widget.seriesId,
      seasonId: _selectedSeasonId,
    )));

    return episodesAsync.when(
      data: (episodes) {
        if (_isGridView) {
          return GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              childAspectRatio: 1,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              final isCurrent = episode.id == widget.currentEpisodeId;
              final isWatched = episode.userData?.played ?? false;

              return GestureDetector(
                onTap: () => _playEpisode(episode),
                child: Container(
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? const Color(0xFF5B8DEF).withValues(alpha: 0.2)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: isCurrent
                        ? Border.all(color: const Color(0xFF5B8DEF), width: 2)
                        : null,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${episode.indexNumber}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            color: isCurrent ? const Color(0xFF5B8DEF) : null,
                          ),
                        ),
                        if (isWatched)
                          const Icon(Icons.check, color: Color(0xFF5B8DEF), size: 16),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        }

        return ListView.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final isCurrent = episode.id == widget.currentEpisodeId;
            final isWatched = episode.userData?.played ?? false;
            final imageUrls = resolveEpisodeLandscapeImageUrls(
              api,
              episode,
              maxWidth: 320,
            );

            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 80,
                  height: 48,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: imageUrls.isNotEmpty
                      ? MediaImage(
                          imageUrl: imageUrls.first,
                          imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                          width: 80,
                          height: 48,
                          fit: BoxFit.cover,
                        )
                      : const Center(child: Icon(Icons.play_arrow, size: 20)),
                ),
              ),
              title: Row(
                children: [
                  if (isWatched)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.check_circle, size: 16, color: Color(0xFF5B8DEF)),
                    ),
                  Expanded(
                    child: Text(
                      'E${episode.indexNumber} ${episode.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              subtitle: Text(
                episode.formattedRuntime ?? '',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: isCurrent
                  ? const Icon(Icons.play_circle, color: Color(0xFF5B8DEF))
                  : null,
              selected: isCurrent,
              onTap: () => _playEpisode(episode),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('加载失败')),
    );
  }
}

/// 设置区块容器
class _SettingsSection extends StatelessWidget {
  final List<Widget> children;
  const _SettingsSection({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// 分组标题
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 分隔线
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      color: Colors.white.withValues(alpha: 0.1),
      height: 1,
      indent: 16,
      endIndent: 16,
    );
  }
}

/// 设置按钮
class _SettingsButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SettingsButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: Colors.white70, size: 20),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置项（带箭头）
class _SettingsItem extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      trailing: const Icon(Icons.arrow_drop_down, color: Colors.white54),
      onTap: onTap,
    );
  }
}

/// 同步控制组件
class _SyncControl extends StatelessWidget {
  final double value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onCustom;
  final VoidCallback onReset;

  const _SyncControl({
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    required this.onCustom,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onDecrease,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.remove, color: Colors.white70, size: 20),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '${value >= 0 ? "+" : ""}${value.toStringAsFixed(1)}s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onIncrease,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.add, color: Colors.white70, size: 20),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: onCustom,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF5B8DEF),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('自定义输入', style: TextStyle(fontSize: 13)),
            ),
            TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white54,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('重置', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }
}
