import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
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
import '../../../core/services/video_player_service.dart';
import '../../../core/services/libass_bridge.dart';
import '../../../core/services/app_logger.dart';

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

  static VideoPlayerService? _activePlayerService;

  static VideoPlayerService? get activePlayerService => _activePlayerService;

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
    });
  }

  Future<void> _initializePlayer() async {
    final api = ref.read(apiClientProvider);
    final item = await api.media.getItemDetails(widget.itemId);

    final playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
    final mediaSource = playbackInfo.mediaSources.firstOrNull;

    final videoUrl = api.playback.getVideoStreamUrl(widget.itemId);

    Duration? startPosition;
    if (item.userData?.playbackPositionTicks != null) {
      startPosition = Duration(
        milliseconds: (item.userData!.playbackPositionTicks! / 10000).round(),
      );
    }

    ref.read(currentPlayingItemProvider.notifier).state = item;

    final coreString = ref.read(playerCoreProvider);
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

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 加载字幕（内封/外挂）—— 两个内核都支持
    if (mediaSource != null) {
      await Future.delayed(const Duration(milliseconds: 1500));
      await _loadSubtitles(item, mediaSource);
    }
  }

  Future<void> _loadSubtitles(MediaItem item, MediaSource mediaSource) async {
    final logger = AppLogger();
    final api = ref.read(apiClientProvider);
    final server = ref.read(currentServerProvider);
    final subtitleStreams = mediaSource.mediaStreams
        .where((s) => s.isSubtitle)
        .toList();

    logger.i('Player', '开始加载字幕 - 可用字幕流: ${subtitleStreams.length} 个');

    if (subtitleStreams.isEmpty) {
      logger.w('Player', '没有可用字幕流');
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
    final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec == 'dvdsub' || codec == 'vobsub';
    logger.i('Player', '选择字幕: index=$targetIndex, codec=$codec, language=${target.language}, external=$isExternal, graphical=$isGraphical');

    ref.read(subtitleTrackProvider.notifier).state = targetIndex;

    if (!isExternal) {
      logger.i('Player', '内封字幕，通过播放器轨道选择');
      try {
        if (_playerService.coreType == PlayerCoreType.mpv) {
          await _selectInternalSubtitleMPV(target, preferredLang, logger);
        } else {
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('内封字幕: ${target.language ?? '默认'}')),
          );
        }
      } catch (e, stackTrace) {
        logger.eWithStack('Player', '内封字幕轨道选择失败', e, stackTrace);
      }
      return;
    }

    if (isGraphical) {
      if (_playerService.coreType == PlayerCoreType.mpv) {
        logger.i('Player', '图形外挂字幕 (PGS/SUP)，MPV内核通过轨道选择加载');
        try {
          if (_playerService.coreType == PlayerCoreType.mpv) {
            await _selectInternalSubtitleMPV(target, preferredLang, logger);
          } else {
            await _selectInternalSubtitleEXO(target, preferredLang, logger);
          }
        } catch (e) {
          logger.e('Player', '图形字幕选择失败: $e');
        }
        return;
      } else {
        logger.w('Player', 'EXO内核不支持PGS/SUP外挂字幕，请切换到MPV内核');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PGS/SUP字幕需MPV内核支持，请在设置中切换')),
          );
        }
        return;
      }
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
        logger.i('Player', 'MPV内核: 直接加载Emby字幕URL: $subUrl');
        await _playerService.loadLibassSubtitle(subUrl);
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

        final tempDir = await getTemporaryDirectory();
        final ext = codec == 'srt' || codec == 'subrip' ? 'srt' : 'ass';
        final subFile = File('${tempDir.path}/subtitle_${widget.itemId}_${targetIndex}.$ext');

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
          logger.i('Player', '字幕下载完成 - ${subFile.lengthSync()} bytes');
        } else {
          logger.i('Player', '使用已缓存字幕 (${await subFile.length()} bytes)');
        }

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
    if (_playerService.coreType == PlayerCoreType.mpv) {
      switch (codec) {
        case 'srt' || 'subrip':
          return 'srt';
        case 'vtt' || 'webvtt':
          return 'vtt';
        default:
          return 'ass';
      }
    } else {
      return 'srt';
    }
  }

  Future<void> _selectInternalSubtitleMPV(MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) => t['type'] == 'text').toList();
    logger.i('Player', 'MPV 可用字幕轨道: ${subtitleTracks.length} 个');
    for (final track in subtitleTracks) {
      logger.d('Player', '  轨道: id=${track['id']}, title=${track['title']}, language=${track['language']}');
    }

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'MPV 无可用字幕轨道 - 可能track-list尚未就绪');
      return;
    }

    String? trackId;
    final langMatches = subtitleTracks.where((t) =>
        t['language'] == preferredLang ||
        t['language'] == 'chi' ||
        t['language'] == 'zh' ||
        t['language'] == 'eng' ||
        t['language'] == 'en').toList();
    if (langMatches.isNotEmpty) {
      trackId = langMatches.first['id']?.toString();
    } else {
      trackId = subtitleTracks.first['id']?.toString();
    }

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'MPV 已选择内封字幕轨道: $trackId');
    } else {
      logger.w('Player', 'MPV 未找到匹配的字幕轨道');
    }
  }

  Future<void> _selectInternalSubtitleEXO(MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) => t['type'] == 'text').toList();
    logger.i('Player', 'EXO 可用字幕轨道: ${subtitleTracks.length} 个');

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'EXO 无可用字幕轨道');
      return;
    }

    Map<String, dynamic>? trackTarget;
    final langMatches = subtitleTracks.where((t) =>
        t['language'] == preferredLang ||
        t['language'] == 'chi' ||
        t['language'] == 'zh' ||
        t['language'] == 'eng' ||
        t['language'] == 'en').toList();
    if (langMatches.isNotEmpty) {
      trackTarget = langMatches.first;
    } else {
      trackTarget = subtitleTracks.first;
    }

    final trackId = trackTarget['id']?.toString() ?? '';
    await _playerService.selectSubtitleTrack(trackId);
    logger.i('Player', 'EXO 已选择内封字幕轨道: id=$trackId');
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
    final server = ref.read(currentServerProvider);
    final logger = AppLogger();

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = playbackInfo.mediaSources.firstOrNull;
      if (mediaSource == null) return;

      final subtitleStreams = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs' || codec == 'dvdsub' || codec == 'vobsub';

      if (!isExternal || isGraphical) {
        final tracks = _playerService.tracksInfo;
        final subtitleTracks = tracks.where((t) => t['type'] == 'text').toList();

        final preferredLang = target.language;
        final langMatch = subtitleTracks.where((t) =>
            t['language'] == preferredLang ||
            (preferredLang != null && t['title']?.toString().contains(preferredLang) == true)).toList();
        final trackTarget = langMatch.isNotEmpty ? langMatch.first : (subtitleTracks.isNotEmpty ? subtitleTracks.first : null);

        if (trackTarget != null) {
          final trackId = trackTarget['id']?.toString() ?? '';
          await _playerService.selectSubtitleTrack(trackId);
          logger.i('Player', '切换字幕轨道: id=$trackId');
        }
      } else {
        if (_playerService.coreType == PlayerCoreType.mpv) {
          final embyCodec = _embySubtitleCodec(codec);
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );
          await _playerService.loadLibassSubtitle(subUrl);
        } else {
          final embyCodec = _embySubtitleCodec(codec);
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );

          final tempDir = await getTemporaryDirectory();
          final ext = codec == 'srt' || codec == 'subrip' ? 'srt' : 'ass';
          final subFile = File('${tempDir.path}/subtitle_${item.id}_${target.index}.$ext');

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
            await _playerService.loadLibassSubtitle(subFile.path);
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
      final mediaSource = playbackInfo.mediaSources.firstOrNull;
      if (mediaSource == null) return;

      final subtitleStreams = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = codec == 'pgssub' || codec == 'sup' || codec == 'pgs';

      if (!isExternal || isGraphical) {
        logger.w('Player', '次字幕: 内封/图形字幕暂不支持作为次字幕');
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
      final ext = codec == 'srt' || codec == 'subrip' ? 'srt' : 'ass';
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
                        backgroundColor: Colors.black.withOpacity(0.7),
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

    // ExoPlayer 内核且启用了 libass：叠加 libass 位图字幕
    // MPV 内核：libmpv 自行渲染字幕，无需 Dart 层叠加
    if (_playerService.coreType == PlayerCoreType.exoPlayer && _playerService.libassReady) {
      return Stack(
        fit: StackFit.expand,
        children: [
          videoWidget,
          Positioned.fill(
            child: _LibassOverlay(playerService: _playerService),
          ),
        ],
      );
    }

    return videoWidget;
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
          color: Colors.black.withOpacity(0.7),
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
          color: Colors.black.withOpacity(0.7),
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
    final coreString = ref.read(playerCoreProvider);
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
                    inactiveTrackColor: Colors.white.withOpacity(0.3),
                    thumbColor: const Color(0xFF5B8DEF),
                    overlayColor: const Color(0xFF5B8DEF).withOpacity(0.2),
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
          color: Colors.black.withOpacity(0.7),
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
                color: Colors.black.withOpacity(0.88),
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
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
                        color: Colors.black.withOpacity(0.5),
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.white.withOpacity(0.1),
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

  void _showSubtitleSettings() {
    _showRightPanel(
      title: '字幕设置',
      children: [
        _SubtitleSettingsContent(),
      ],
    );
  }

  void _showAudioSettings() {
    _showRightPanel(
      title: '音频设置',
      children: [
        _AudioSettingsContent(),
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
    final currentCore = ref.read(playerCoreProvider);
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
    ref.read(playerCoreProvider.notifier).state = core;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
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
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '弹幕功能当前版本暂不支持显示，设置仅作预留',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                ),
              ),
            ],
          ),
        ),
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

    if (subtitleAsync == null) {
      return const _SettingsSection(
        children: [Center(child: Text('无播放信息', style: TextStyle(color: Colors.white70)))],
      );
    }

    return subtitleAsync.when(
      data: (info) {
        final subtitles = info.mediaSources.firstOrNull?.mediaStreams.where((s) => s.isSubtitle).toList() ?? [];

        return _SettingsSection(
          children: [
            const _SectionTitle('字幕轨道'),
            if (subtitles.isEmpty)
              const ListTile(
                leading: Icon(Icons.subtitles_off, color: Colors.white54),
                title: Text('无可用字幕', style: TextStyle(color: Colors.white70)),
              )
            else
              ...subtitles.map((stream) => RadioListTile<int>(
                title: Text(
                  stream.displayTitle ?? stream.language ?? '轨道 ${stream.index}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: stream.codec != null
                    ? Text('编码: ${stream.codec}${stream.isExternal == true ? ' (外挂)' : ' (内封)'}', style: const TextStyle(color: Colors.white54, fontSize: 12))
                    : null,
                value: stream.index,
                groupValue: selectedSubtitleIndex,
                onChanged: (value) {
                  ref.read(subtitleTrackProvider.notifier).state = value;
                },
              )),
            const SizedBox(height: 8),
            _SettingsButton(
              icon: Icons.upload_file,
              label: '导入外部字幕',
              onTap: () => _pickExternalSubtitle(),
            ),
            const SizedBox(height: 16),
            const _Divider(),
            const _SectionTitle('次字幕（第二字幕）'),
            RadioListTile<int?>(
              title: const Text('关闭', style: TextStyle(color: Colors.white70, fontSize: 13)),
              value: null,
              groupValue: selectedSecondaryIndex,
              onChanged: (_) {
                ref.read(secondarySubtitleTrackProvider.notifier).state = null;
              },
            ),
            if (subtitles.isEmpty)
              const ListTile(
                title: Text('无可用次字幕', style: TextStyle(color: Colors.white70)),
              )
            else
              ...subtitles.map((stream) => RadioListTile<int?>(
                title: Text(
                  stream.displayTitle ?? stream.language ?? '轨道 ${stream.index}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                value: stream.index,
                groupValue: selectedSecondaryIndex,
                onChanged: (value) {
                  ref.read(secondarySubtitleTrackProvider.notifier).state = value;
                },
              )),
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
        allowedExtensions: ['srt', 'ass', 'ssa', 'vtt'],
      );
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        AppLogger().i('Player', '导入外部字幕: $filePath');

        final playerService = _PlayerScreenState.activePlayerService;
        if (playerService != null) {
          await playerService.loadLibassSubtitle(filePath);
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

  void _searchOnlineSubtitle(String title) {
    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('在线搜索字幕'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('正在搜索: $title'),
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Text(
                '在线字幕搜索需要接入字幕 API（如 OpenSubtitles、射手网等），当前版本暂未集成。您可以先使用「导入字幕」功能加载本地字幕文件。',
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
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _pickExternalSubtitle();
              },
              child: const Text('导入本地字幕'),
            ),
          ],
        ),
      );
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

    if (audioAsync == null) {
      return const _SettingsSection(
        children: [Center(child: Text('无播放信息', style: TextStyle(color: Colors.white70)))],
      );
    }

    return audioAsync.when(
      data: (info) {
        final audios = info.mediaSources.firstOrNull?.mediaStreams.where((s) => s.isAudio).toList() ?? [];

        return _SettingsSection(
          children: [
            const _SectionTitle('音频轨道'),
            if (audios.isEmpty)
              const ListTile(
                leading: Icon(Icons.audiotrack, color: Colors.white54),
                title: Text('无可用音轨', style: TextStyle(color: Colors.white70)),
              )
            else
              ...audios.map((stream) => RadioListTile<int>(
                title: Text(
                  stream.displayTitle ?? stream.language ?? '轨道 ${stream.index}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: stream.codec != null
                    ? Text('编码: ${stream.codec}', style: const TextStyle(color: Colors.white54, fontSize: 12))
                    : null,
                value: stream.index,
                groupValue: selectedIndex,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(audioTrackProvider.notifier).state = value;
                    _switchAudioTrack(value);
                  }
                },
              )),
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

  Future<void> _switchAudioTrack(int index) async {
    final playerService = _PlayerScreenState.activePlayerService;
    if (playerService == null) return;

    final tracks = playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();

    if (index < audioTracks.length) {
      final trackId = audioTracks[index]['id']?.toString() ?? '';
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

  const _EpisodeSelectorContent({
    required this.seriesId,
    required this.currentEpisodeId,
  });

  @override
  ConsumerState<_EpisodeSelectorContent> createState() => _EpisodeSelectorContentState();
}

class _EpisodeSelectorContentState extends ConsumerState<_EpisodeSelectorContent> {
  String? _selectedSeasonId;
  bool _isGridView = false;

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
                onTap: () {
                  Navigator.pop(context);
                  context.push('/player/${episode.id}');
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? const Color(0xFF5B8DEF).withOpacity(0.2)
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
            final imageUrl = episode.primaryImageTag != null
                ? api.image.getPrimaryImageUrl(episode.id, tag: episode.primaryImageTag, maxWidth: 200)
                : null;

            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 80,
                  height: 48,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: imageUrl != null
                      ? Image.network(imageUrl, fit: BoxFit.cover)
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
              onTap: () {
                Navigator.pop(context);
                context.push('/player/${episode.id}');
              },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('加载失败')),
    );
  }
}

/// libass 字幕位图叠加层
class _LibassOverlay extends StatefulWidget {
  final VideoPlayerService playerService;

  const _LibassOverlay({required this.playerService});

  @override
  State<_LibassOverlay> createState() => _LibassOverlayState();
}

class _LibassOverlayState extends State<_LibassOverlay> {
  List<LibassBlendRect>? _rects;
  List<ui.Image>? _images;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 41), (_) => _render());
  }

  Future<void> _render() async {
    if (!mounted || !widget.playerService.libassReady) return;
    final ptsMs = widget.playerService.position.inMilliseconds;
    final rects = await LibassBridge.renderFrame(ptsMs);
    if (rects == null || rects.isEmpty || !mounted) {
      if (_images != null && _images!.isNotEmpty && mounted) {
        for (final img in _images!) {
          img.dispose();
        }
        setState(() {
          _rects = null;
          _images = null;
        });
      }
      return;
    }

    final images = <ui.Image>[];
    for (final rect in rects) {
      final image = await rect.toImage();
      images.add(image);
    }

    if (!mounted) {
      for (final img in images) {
        img.dispose();
      }
      return;
    }

    final oldImages = _images;
    setState(() {
      _rects = rects;
      _images = images;
    });

    for (final img in oldImages ?? <ui.Image>[]) {
      img.dispose();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final img in _images ?? <ui.Image>[]) {
      img.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_images == null || _images!.isEmpty) return const SizedBox.shrink();
    return CustomPaint(
      painter: _LibassPainter(_images!, _rects!),
      size: Size.infinite,
    );
  }
}

class _LibassPainter extends CustomPainter {
  final List<ui.Image> images;
  final List<LibassBlendRect> rects;

  _LibassPainter(this.images, this.rects);

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < images.length && i < rects.length; i++) {
      final paint = Paint()..filterQuality = FilterQuality.medium;
      final offset = Offset(rects[i].dstX.toDouble(), rects[i].dstY.toDouble());
      canvas.drawImage(images[i], offset, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LibassPainter oldDelegate) => true;
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
      color: Colors.white.withOpacity(0.1),
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
        color: Colors.white.withOpacity(0.08),
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
