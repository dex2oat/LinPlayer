part of 'desktop_player_screen.dart';

class _DesktopPlayerScreenState extends ConsumerState<DesktopPlayerScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _windowChannel =
      MethodChannel('com.linplayer/window');
  static const Duration _uiRefreshInterval = Duration(milliseconds: 200);

  late VideoPlayerService _playerService;
  final FocusNode _focusNode = FocusNode();
  bool _initializingPlayer = false;
  Timer? _uiRefreshTimer;
  // 上一次的缓冲态，用于在控制栏隐藏时仍能感知缓冲开始/结束触发一次重建。
  bool _lastBuffering = false;

  // 控制栏显隐状态
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // 全屏状态
  bool _isFullscreen = false;

  // 退出播放页的两段式放行：先在 PopScope 拦截里还原窗口外壳（退全屏+恢复
  // 标题栏），再放行真正的返回。详见 [_handleExit]。
  bool _allowExitPop = false;
  bool _exiting = false;

  // 倍速按钮长按状态
  bool _isSpeedLongPressing = false;
  bool _didTriggerSpeedLongPress = false;
  Timer? _speedLongPressTimer;

  // 跳过片头按钮
  bool _showSkipButton = false;
  Timer? _skipButtonTimer;
  bool _autoSkipTriggeredForCurrentOpening = false;

  // 音量滑块显示
  bool _showVolumeSlider = false;
  Timer? _volumeSliderTimer;

  // 统计信息显示
  bool _showStatsOverlay = false;
  // 局部刷新:统计浮层每秒更新只重建浮层自身(ValueListenableBuilder),
  // 不再 setState 整棵播放页 —— 否则 media_kit 的视频 Texture 会随整树重建闪一帧。
  final ValueNotifier<Map<String, String>> _playbackStats =
      ValueNotifier(const {});
  bool _isSeekingWithSlider = false;
  double? _sliderSeekValue;
  MediaSource? _currentMediaSource;
  String? _videoUrl;
  WhisperSubtitleController? _whisperController;
  StreamingSubtitleTranslator? _streamTranslator;
  String? _displayTitle;
  late final IntroSkipController _introSkip;
  bool _suppressTrackSelectionListeners = false;
  bool _hasUserTouchedSubtitleSelection = false;
  bool _subtitleBootstrapInFlight = false;
  // 初始化阶段（拉取 PlaybackInfo / 元数据）失败信息。播放器适配器尚未创建时
  // _playerService.hasError 不会置位，需用它把网络超时等错误显示给用户。
  String? _initErrorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _introSkip = IntroSkipController(service: ref.read(introSkipServiceProvider));
    _playerService = VideoPlayerService();
    _initializePlayer();
    _focusNode.requestFocus();
    unawaited(_syncFullscreenState());
    _uiRefreshTimer = Timer.periodic(_uiRefreshInterval, (_) {
      if (!mounted) return;
      _checkSkipOpening();
      _introSkip.onPosition(_playerService.position);
      // 仅在「屏幕上有随时间变化的可见元素」时才整树重建：控制栏可见(进度条要走)、
      // 正在缓冲(转圈)、统计浮层开着，或缓冲态刚发生切换。控制栏隐藏且无这些时跳过重建，
      // 让隐藏后的播放不再每 200ms 重绘一次，进一步缓解卡顿。
      final buffering = _playerService.isBuffering;
      // 统计浮层已改为 ValueNotifier 局部刷新,不再靠整树重建驱动,
      // 故这里不再因 _showStatsOverlay 而 200ms 重建整页(避免视频 Texture 闪)。
      final needsRefresh =
          _showControls || buffering || _lastBuffering != buffering;
      _lastBuffering = buffering;
      if (needsRefresh) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(audioTrackProvider, (prev, next) {
        if (_initializingPlayer ||
            _suppressTrackSelectionListeners ||
            prev == next ||
            next == null) {
          return;
        }
        final audioStreams = _audioStreamsFromCurrentSource();
        if (audioStreams.isEmpty) {
          return;
        }
        unawaited(_applyAudioStreamSelection(audioStreams, next));
      });
      ref.listenManual(subtitleTrackProvider, (prev, next) {
        if (_initializingPlayer ||
            _suppressTrackSelectionListeners ||
            prev == next) {
          return;
        }
        _hasUserTouchedSubtitleSelection = true;
        unawaited(_onSubtitleSelectionChanged(prev, next));
      });
      ref.listenManual(secondarySubtitleTrackProvider, (prev, next) {
        if (_initializingPlayer ||
            _suppressTrackSelectionListeners ||
            prev == next) {
          return;
        }
        unawaited(_onSecondarySubtitleSelectionChanged(next));
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
      ref.listenManual(pgsBlendModeProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleBlendMode(next));
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      return;
    }
    unawaited(_persistCurrentWatchHistory(force: true));
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

  /// 点按「跳过片头/片尾」：片尾且开启自动连播则切下一集，否则 seek 到段末。
  void _onIntroSkipPressed(SkipPrompt prompt) {
    if (prompt.kind == SkipKind.outro &&
        ref.read(autoPlayNextProvider) &&
        ref.read(currentPlayingItemProvider)?.seriesId != null) {
      unawaited(_playNext());
    } else {
      unawaited(_playerService.seekTo(prompt.target));
      _introSkip.onPosition(prompt.target); // 立即收起按钮
    }
  }

  /// 网盘/聚合源直链播放初始化：复用桌面播放页全部能力。
  Future<void> _initializeSourcePlayer(SourcePlayback sp,
      {Duration? startPosition}) async {
    final backend = mediaSourceBackendFor(sp.server.sourceKind);
    try {
      final qualityId = ref.read(sourceSelectedQualityProvider) ?? sp.qualityId;
      final play =
          await backend.resolvePlay(sp.server, sp.entry, qualityId: qualityId);
      final cfg = resolveSourcePlayerConfig(ref);
      final spItem = sp.toMediaItem();
      ref.read(currentPlayingItemProvider.notifier).state = spItem;
      unawaited(DanmakuAutoLoader.run(ref, null, spItem));
      ref.read(sourcePlayQualitiesProvider.notifier).state = play.qualities;
      if (ref.read(sourceSelectedQualityProvider) == null) {
        ref.read(sourceSelectedQualityProvider.notifier).state =
            play.selectedQualityId;
      }
      _currentMediaSource = null;
      _videoUrl = play.url;
      _displayTitle = sp.entry.name;
      await _playerService.initialize(
        videoUrl: play.url,
        itemId: sp.syntheticItemId,
        startPosition: startPosition,
        coreType: cfg.coreType,
        hardwareDecoding: cfg.hardwareDecoding,
        useLibass: cfg.useLibass,
        useGpuNext: cfg.useGpuNext,
        surfaceViewId: cfg.surfaceViewId,
        httpHeaders: play.httpHeaders.isEmpty ? null : play.httpHeaders,
        userAgentOverride: play.userAgentOverride,
        streamUrlResolver: () async {
          final q = ref.read(sourceSelectedQualityProvider) ?? sp.qualityId;
          final fresh =
              await backend.resolvePlay(sp.server, sp.entry, qualityId: q);
          return (url: fresh.url, fallbackUrl: null);
        },
        streamUrlTtl: const Duration(minutes: 3),
      );
      await _playerService.play();
      if (play.subtitles.isNotEmpty) {
        try {
          await _playerService.loadLibassSubtitle(play.subtitles.first.url);
        } catch (_) {}
      }
      await _playerService.setSubtitleSize(ref.read(subtitleSizeProvider));
      await _playerService
          .setSubtitlePosition(ref.read(subtitlePositionProvider));
      await _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider));
      await _playerService.setSubtitleFont(ref.read(subtitleFontProvider));
      await _playerService
          .setSubtitleBackground(ref.read(subtitleBackgroundProvider));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() => _initErrorMessage = '播放失败: $e');
      }
    }
  }

  /// 播放内切换清晰度：记当前进度，按新档重解析并续播。
  Future<void> _switchSourceQuality(String qualityId) async {
    final sp = widget.sourcePlay;
    if (sp == null) return;
    final pos = _playerService.position;
    ref.read(sourceSelectedQualityProvider.notifier).state = qualityId;
    await _initializeSourcePlayer(sp, startPosition: pos);
  }

  Future<void> _initializePlayer() async {
    if (_initializingPlayer) return;
    _initializingPlayer = true;
    _hasUserTouchedSubtitleSelection = false;
    _initErrorMessage = null;
    // 网盘/聚合源直链：走专属初始化，复用本播放页 UI/内核。
    if (widget.sourcePlay != null) {
      await _initializeSourcePlayer(widget.sourcePlay!);
      _initializingPlayer = false;
      return;
    }
    final api = ref.read(apiClientProvider);
    List<MediaStream> deferredSubtitleStreams = const <MediaStream>[];
    try {
      // 离线优先：本集已下载完成则用本地文件，拉取元数据失败时兜底离线播放。
      final downloadManager = ref.read(downloadManagerProvider);
      final localPath = downloadManager.completedFilePath(widget.itemId);
      final hasLocal = localPath != null && await File(localPath).exists();

      MediaItem item;
      PlaybackInfo? playbackInfo;
      try {
        final cachedItem = ref.read(currentPlayingItemProvider);
        item = cachedItem != null && cachedItem.id == widget.itemId
            ? cachedItem
            : await api.media.getItemDetails(widget.itemId);
        playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
      } catch (e) {
        final record = downloadManager.byItemId(widget.itemId);
        if (!hasLocal || record == null) rethrow;
        item = mediaItemFromDownload(record);
        playbackInfo = null;
      }

      final selection = playbackInfo != null
          ? buildPlaybackSelection(
              playbackInfo: playbackInfo,
              itemId: widget.itemId,
              preferredMediaSourceId:
                  widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider),
              versionRegex: ref.read(preferredVersionRegexProvider),
              playSessionId:
                  '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
              strmDirectPlay: ref.read(strmDirectPlayProvider),
            )
          : buildOfflinePlaybackSelection(itemId: widget.itemId);
      final mediaSource = selection.mediaSource;

      final videoUrl =
          buildStreamUrlFromRequest(api.playback, selection.primaryRequest);
      final fallbackVideoUrl = selection.fallbackRequest == null
          ? null
          : buildStreamUrlFromRequest(api.playback, selection.fallbackRequest!);

      // 预取代理上游重签：短效签名的服务端直传流到期时，重走 PlaybackInfo 拿新地址，
      // 代理换 URL 续拉，不断流。仅在走代理（非直链/本地）时用得上。
      Future<String?> reResolveDirectStreamUrl() async {
        final pi = await api.playback.getPlaybackInfo(widget.itemId);
        final sel = buildPlaybackSelection(
          playbackInfo: pi,
          itemId: widget.itemId,
          preferredMediaSourceId:
              widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider),
          versionRegex: ref.read(preferredVersionRegexProvider),
          playSessionId:
              '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
          strmDirectPlay: ref.read(strmDirectPlayProvider),
        );
        return buildStreamUrlFromRequest(api.playback, sel.primaryRequest);
      }

      // STRM 直链：开启且解析出可用直链时优先用直链，服务端直传流作为回退。
      final directUrl = selection.directPlayUrl;
      final hasDirect = directUrl != null && directUrl.isNotEmpty;
      final onlineUrl = hasDirect ? directUrl : videoUrl;

      // 本地文件覆盖播放源；在线地址留作本地失效时回退。
      final localFileSource =
          hasLocal ? Uri.file(localPath).toString() : null;

      // 多线程加载：仅对 Emby 服务端直传流起本地缓存预取代理（2~4 并发 Range）。
      // 跳过：① 本地文件；② STRM/网盘直链（需逐流专属 headers/UA，代理不复制，会鉴权失败）。
      // 转码流/HLS 无固定大小，代理探测拿不到 size 会自动放弃 → 回退在线直链。
      final proxiedUrl = (localFileSource != null || hasDirect)
          ? null
          : await _maybeStartPrefetch(onlineUrl,
              onExpired: reResolveDirectStreamUrl);

      final effectiveVideoUrl = localFileSource ?? proxiedUrl ?? onlineUrl;
      final effectiveFallbackUrl = localFileSource != null
          ? (playbackInfo != null ? onlineUrl : null)
          : (proxiedUrl != null
              ? onlineUrl
              : (hasDirect ? videoUrl : fallbackVideoUrl));

      Duration? startPosition;
      try {
        startPosition = await resolveResumeStartPosition(ref, api, item);
      } catch (_) {
        startPosition = null;
      }
      final startPositionTicks = (startPosition?.inMilliseconds ?? 0) * 10000;

      ref.read(currentPlayingItemProvider.notifier).state = item;
      ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;
      // 播放即自动匹配加载弹幕（动漫走弹弹Play+自定义源，非动漫仅自定义源）。
      unawaited(DanmakuAutoLoader.run(ref, api, item));
      // 自动跳过片头/片尾：联网识别本集片段（仅剧集，受设置开关控制）。
      unawaited(_introSkip.loadForItem(
        item,
        enabled: ref.read(autoSkipSegmentsProvider),
        fetchItem: (id) => api.media.getItemDetails(id),
      ));
      _currentMediaSource = mediaSource;
      _videoUrl = effectiveVideoUrl;
      _displayTitle = item.name;

      final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
      final coreType =
          coreString == 'mpv' ? PlayerCoreType.mpv : PlayerCoreType.exoPlayer;

      // 杜比视界自动切换（默认开，可关）：DV 流 + media_kit(mpv) 时强制软解 + DV 色彩修正，
      // 避免硬解杜比视界偏色。桌面 media_kit 走 vo=libmpv，无独立 gpu-next vo，
      // 故以软解 + dolbyVisionFix 的色调映射作为等效处理。见 dolbyAutoGpuNextSwProvider。
      // 取最高分辨率视频流判定 DV，避免被排在前面的低清流误导。
      final dvVideoStream = mediaSource?.primaryVideoStream;
      final autoDvMode = coreType == PlayerCoreType.mpv &&
          ref.read(dolbyAutoGpuNextSwProvider) &&
          (dvVideoStream?.isDolbyVision ?? false);
      final dolbyVisionFix = coreType == PlayerCoreType.mpv
          ? (autoDvMode || ref.read(mpvDolbyVisionFixProvider))
          : false;
      final useLibass = coreType == PlayerCoreType.exoPlayer
          ? ref.read(exoLibassProvider)
          : false;
      final hardwareDecoding =
          autoDvMode ? false : ref.read(hardwareDecodingProvider);
      final preferredSubtitleLanguage =
          ref.read(preferredSubtitleLanguageProvider);

      await _playerService.initialize(
        videoUrl: effectiveVideoUrl,
        itemId: widget.itemId,
        mediaSourceId: mediaSource?.id,
        playSessionId: selection.primaryRequest.playSessionId,
        fallbackVideoUrl: effectiveFallbackUrl,
        startPosition: startPosition,
        coreType: coreType,
        dolbyVisionFix: dolbyVisionFix,
        useLibass: useLibass,
        hardwareDecoding: hardwareDecoding,
        startWithSoftwareDecoding:
            selection.startsWithSoftwareDecoding && hardwareDecoding,
        fallbackReason: selection.fallbackReason,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        superResolutionLevel: ref.read(anime4KLevelProvider),
        onStart: (info) async {
          try {
            await api.playback.reportPlaybackStart(info);
          } catch (_) {}
          await _writeWatchHistoryForItem(
            item: item,
            positionTicks: startPositionTicks,
            incrementPlayCount: true,
            force: true,
          );
        },
        onProgress: (info) async {
          try {
            await api.playback.reportPlaybackProgress(info);
          } catch (_) {}
          await _writeWatchHistoryForItem(
            item: item,
            positionTicks: info.positionTicks,
          );
        },
        onStop: (info) async {
          try {
            await api.playback.reportPlaybackStopped(info);
          } catch (_) {}
          await _writeWatchHistoryForItem(
            item: item,
            positionTicks: info.positionTicks,
            force: true,
          );
        },
      );

      // 初始化为异步过程，若期间用户已返回（widget 销毁），直接收尾退出，
      // 不再继续起播/选轨。VideoPlayerService 内部也已对 dispose 后的调用做短路。
      if (!mounted) return;

      await Future.wait([
        _playerService.setSubtitleSize(ref.read(subtitleSizeProvider)),
        _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider)),
        _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider)),
        _playerService.setSubtitleFont(ref.read(subtitleFontProvider)),
        _playerService
            .setSubtitleBackground(ref.read(subtitleBackgroundProvider)),
        _playerService.setAspectRatio(ref.read(aspectRatioProvider)),
      ]);

      await _playerService.play();

      final audioStreams =
          mediaSource?.mediaStreams.where((s) => s.isAudio).toList() ?? [];
      final subtitleStreams =
          mediaSource?.mediaStreams.where((s) => s.isSubtitle).toList() ?? [];
      await _waitForTracksReady(
        requireAudio: audioStreams.isNotEmpty,
      );

      final selectedAudioIndex = ref.read(audioTrackProvider);
      if (audioStreams.isNotEmpty) {
        final initialAudio =
            selectedAudioIndex ?? _resolveInitialAudioIndex(audioStreams);
        if (initialAudio != null) {
          ref.read(audioTrackProvider.notifier).state = initialAudio;
          await _applyAudioStreamSelection(audioStreams, initialAudio);
        }
      }

      if (subtitleStreams.isNotEmpty) {
        deferredSubtitleStreams = subtitleStreams;
      } else {
        ref.read(subtitleTrackProvider.notifier).state = null;
      }

      _startHideControlsTimer();
    } catch (e, st) {
      // 拉取 PlaybackInfo / 元数据失败（如服务器连接超时）。在适配器创建前抛出时，
      // _playerService 不会进入错误态，必须在此兜底显示错误，否则页面会停在 loading 且
      // 异常变成未捕获的异步错误。原始错误仅写日志（供导出反馈），界面只显示安全文案。
      AppLogger().eWithStack(
          'DesktopPlayer', '播放初始化失败: ${widget.itemId}', e, st);
      if (mounted) {
        _initErrorMessage = e.toString();
      }
    } finally {
      _initializingPlayer = false;
      if (mounted) {
        setState(() {});
      }
    }

    if (deferredSubtitleStreams.isNotEmpty) {
      unawaited(
          _initializeSubtitleSelectionAfterStartup(deferredSubtitleStreams));
    }
  }

  Future<T> _runWithSuppressedTrackSelectionListeners<T>(
    Future<T> Function() action,
  ) async {
    _suppressTrackSelectionListeners = true;
    try {
      return await action();
    } finally {
      _suppressTrackSelectionListeners = false;
    }
  }

  Future<void> _initializeSubtitleSelectionAfterStartup(
    List<MediaStream> subtitleStreams,
  ) async {
    if (_subtitleBootstrapInFlight || subtitleStreams.isEmpty) {
      return;
    }
    _subtitleBootstrapInFlight = true;
    try {
      AppLogger().i(
        'DesktopPlayer',
        '起播后异步初始化字幕轨道: count=${subtitleStreams.length}',
      );
      await _waitForTracksReady(requireSubtitle: true);
      if (!mounted) {
        return;
      }

      final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
      if (selectedSubtitleIndex != null) {
        await _applyInitialSubtitleTrack(
            subtitleStreams, selectedSubtitleIndex);
      } else if (_hasUserTouchedSubtitleSelection) {
        AppLogger().i(
          'DesktopPlayer',
          '用户已手动处理字幕选择，跳过默认字幕自动挂载',
        );
      } else {
        await _applyPreferredSubtitleTrack(subtitleStreams);
      }

      // 起播后应用用户在详情页选择的次字幕（次字幕默认为「无」，不自动挂载）
      final selectedSecondaryIndex = ref.read(secondarySubtitleTrackProvider);
      if (selectedSecondaryIndex != null) {
        await _onSecondarySubtitleSelectionChanged(selectedSecondaryIndex);
      }
    } catch (e, stackTrace) {
      AppLogger().eWithStack(
        'DesktopPlayer',
        '起播后异步初始化字幕失败',
        e,
        stackTrace,
      );
    } finally {
      _subtitleBootstrapInFlight = false;
    }
  }

  Future<void> _applyInitialAudioTrack(
      List<MediaStream> audioStreams, int selectedIndex) async {
    final trackId = _matchAudioTrackId(audioStreams, selectedIndex);
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  List<Map<String, dynamic>> _subtitleTracksFrom(
      [List<Map<String, dynamic>>? tracks]) {
    final source = tracks ?? _playerService.tracksInfo;
    return source.where((track) {
      final type = track['type']?.toString();
      return type == 'subtitle' || type == 'text' || type == 'bitmap';
    }).toList();
  }

  List<Map<String, dynamic>> _selectableSubtitleTracksFrom([
    List<Map<String, dynamic>>? tracks,
  ]) {
    return _subtitleTracksFrom(tracks)
        .where((track) => track['id'] != 'auto' && track['id'] != 'no')
        .toList();
  }

  Future<void> _waitForTracksReady({
    bool requireAudio = false,
    bool requireSubtitle = false,
  }) async {
    if (!requireAudio && !requireSubtitle) {
      return;
    }
    final waitBudget =
        requireSubtitle && _playerService.coreType == PlayerCoreType.mpv
            ? const Duration(seconds: 18)
            : const Duration(milliseconds: 4500);
    final deadline = DateTime.now().add(waitBudget);
    while (DateTime.now().isBefore(deadline)) {
      final tracks = _playerService.tracksInfo;
      final audioReady =
          !requireAudio || tracks.any((track) => track['type'] == 'audio');
      final subtitleReady =
          !requireSubtitle || _selectableSubtitleTracksFrom(tracks).isNotEmpty;
      if (audioReady && subtitleReady) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    AppLogger().w(
      'DesktopPlayer',
      '等待轨道就绪超时: audio=$requireAudio, subtitle=$requireSubtitle, '
          'knownTracks=${_playerService.tracksInfo.length}, '
          'selectableSubtitles=${_selectableSubtitleTracksFrom().length}',
    );
  }

  Future<void> _applyInitialSubtitleTrack(
    List<MediaStream> subtitleStreams,
    int selectedIndex,
  ) async {
    await _onSubtitleSelectionChanged(null, selectedIndex);
  }

  /// 应用次字幕（MPV `secondary-sid`）。次字幕默认为「无」。
  /// 内封轨道直接按 trackId 设置，外挂字幕下载后加载；图形字幕(PGS/SUP)不支持。
  Future<void> _onSecondarySubtitleSelectionChanged(int? next) async {
    if (_currentMediaSource == null) {
      return;
    }
    if (next == null) {
      await _playerService.deselectSecondarySubtitle();
      return;
    }

    final coreType = _playerService.coreType;
    if (coreType != PlayerCoreType.mpv &&
        coreType != PlayerCoreType.nativeMpv) {
      AppLogger().w('DesktopPlayer', '次字幕仅支持 MPV 内核，当前内核: $coreType');
      return;
    }

    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    final target =
        subtitleStreams.where((stream) => stream.index == next).firstOrNull;
    if (target == null) {
      return;
    }

    final codec = (target.codec ?? '').toLowerCase();
    final targetTitle = target.displayTitle ?? target.title;
    final isExternal = target.isExternal == true;
    final kind = SubtitleTrackMatcher.classifyKind(
      codec: target.codec,
      title: targetTitle,
    );
    if (kind == SubtitleKind.bitmap) {
      AppLogger().w('DesktopPlayer', '图形字幕(PGS/SUP)暂不支持作为次字幕: index=$next');
      return;
    }

    try {
      if (!isExternal) {
        var trackId = _matchSubtitleTrackId(
          subtitleStreams,
          target.language,
          targetTitle,
          target.codec,
          target.index,
        );
        if (trackId == null || trackId.isEmpty) {
          trackId = await _waitForInternalSubtitleTrackId(
            subtitleStreams,
            target,
            targetTitle,
          );
        }
        if (trackId != null && trackId.isNotEmpty) {
          await _playerService.selectSecondarySubtitleTrack(trackId);
          AppLogger().i('DesktopPlayer', '内封次字幕已设置: trackId=$trackId');
          return;
        }
        AppLogger().w('DesktopPlayer', '未匹配到内封次字幕轨道，回退外挂加载: index=$next');
      }

      final file = await _prepareExternalSubtitleFile(
        target,
        codec,
        title: targetTitle,
        kind: kind,
      );
      await _playerService.loadSecondarySubtitle(file.path);
      AppLogger().i('DesktopPlayer', '外挂次字幕加载成功: ${file.path}');
    } catch (e, stackTrace) {
      AppLogger().eWithStack('DesktopPlayer', '加载次字幕失败', e, stackTrace);
    }
  }

  Future<void> _applyPreferredSubtitleTrack(
      List<MediaStream> subtitleStreams) async {
    if (subtitleStreams.isEmpty) {
      return;
    }
    final preferredLanguage =
        ref.read(preferredSubtitleLanguageProvider).trim().toLowerCase();
    // 「字幕选择」正则优先：命中则用正则结果，否则回退到首选字幕语言。
    final preferredTrack = matchPreferredStream(
            subtitleStreams, ref.read(preferredSubtitleRegexProvider)) ??
        subtitleStreams.firstWhere(
          (stream) =>
              (stream.language ?? '').trim().toLowerCase() == preferredLanguage,
          orElse: () => subtitleStreams.first,
        );
    await _runWithSuppressedTrackSelectionListeners(() async {
      ref.read(subtitleTrackProvider.notifier).state = preferredTrack.index;
      await _onSubtitleSelectionChanged(null, preferredTrack.index);
    });
  }

  List<MediaStream> _audioStreamsFromCurrentSource() {
    return _currentMediaSource?.mediaStreams
            .where((stream) => stream.isAudio)
            .toList() ??
        const <MediaStream>[];
  }

  List<MediaStream> _subtitleStreamsFromCurrentSource() {
    return _currentMediaSource?.mediaStreams
            .where((stream) => stream.isSubtitle)
            .toList() ??
        const <MediaStream>[];
  }

  int? _resolveInitialAudioIndex(List<MediaStream> audioStreams) {
    if (audioStreams.isEmpty) {
      return null;
    }
    // 「音频选择」正则优先：命中则用正则结果，否则回退到服务端默认轨。
    final regexMatch =
        matchPreferredStream(audioStreams, ref.read(preferredAudioRegexProvider));
    if (regexMatch != null) {
      return regexMatch.index;
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
    // 用户切换/关闭字幕轨 → 结束流式翻译：清掉译文叠加层并恢复原文字幕可见性，
    // 否则旧译文叠加层会与新选中的内封字幕叠加，造成双字幕（双外语）。
    if (_streamTranslator != null) {
      _stopStreamingTranslate();
    }
    if (next == null) {
      _playerService.setSubtitleSelectionHint();
      await _playerService.deselectSubtitleTrack();
      return;
    }

    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    final target =
        subtitleStreams.where((stream) => stream.index == next).firstOrNull;
    if (target == null) {
      return;
    }

    final codec = (target.codec ?? '').toLowerCase();
    final targetTitle = target.displayTitle ?? target.title;
    final isExternal = target.isExternal == true;
    final subtitleKind = SubtitleTrackMatcher.classifyKind(
      codec: target.codec,
      title: targetTitle,
    );
    final shouldPreferNativeBitmapSubtitle =
        _playerService.coreType == PlayerCoreType.mpv &&
            subtitleKind == SubtitleKind.bitmap &&
            !isExternal;
    final canAttemptExternalSubtitleFallback =
        _canAttemptExternalSubtitleFallback(target);

    AppLogger().i(
      'DesktopPlayer',
      '字幕切换请求: index=${target.index}, codec=${target.codec}, title=$targetTitle, '
          'external=$isExternal, externalUrl=${target.isExternalUrl == true}, '
          'hasDeliveryUrl=${_hasSubtitleDeliveryUrl(target)}, '
          'kind=$subtitleKind, preferNativeBitmap=$shouldPreferNativeBitmapSubtitle, '
          'canExternalFallback=$canAttemptExternalSubtitleFallback',
    );

    if (!isExternal) {
      _playerService.setSubtitleSelectionHint(codec: codec, title: targetTitle);
      var trackId = _matchSubtitleTrackId(
        subtitleStreams,
        target.language,
        targetTitle,
        target.codec,
        target.index,
      );
      if ((trackId == null || trackId.isEmpty) &&
          _playerService.coreType == PlayerCoreType.mpv) {
        AppLogger().i(
          'DesktopPlayer',
          '字幕轨道尚未就绪，等待 MPV 暴露真实字幕轨道: index=${target.index}, codec=${target.codec}, title=$targetTitle',
        );
        trackId = await _waitForInternalSubtitleTrackId(
          subtitleStreams,
          target,
          targetTitle,
        );
      }
      if (trackId != null && trackId.isNotEmpty) {
        await _playerService.selectSubtitleTrack(trackId);
        if (!shouldPreferNativeBitmapSubtitle) {
          return;
        }
        final nativeBitmapSelected = await _verifyNativeBitmapSubtitleSelection(
          trackId,
          codec: codec,
          title: targetTitle,
        );
        if (nativeBitmapSelected) {
          AppLogger().i(
            'DesktopPlayer',
            'PGS/SUP 内封字幕已通过 mpv 原生轨道选中: trackId=$trackId',
          );
          return;
        }
        AppLogger().w(
          'DesktopPlayer',
          'PGS/SUP 内封字幕原生选轨未挂载成功，回退外挂加载: trackId=$trackId',
        );
      } else if (_playerService.coreType == PlayerCoreType.mpv) {
        if (!shouldPreferNativeBitmapSubtitle) {
          AppLogger().w(
            'DesktopPlayer',
            'MPV 内封字幕轨道仍未匹配成功，保留当前字幕状态: index=${target.index}, codec=${target.codec}',
          );
          return;
        }
        AppLogger().w(
          'DesktopPlayer',
          'PGS/SUP 未匹配到内封轨道 ID，回退外挂加载: index=${target.index}',
        );
      } else {
        return;
      }
    }

    // Only use the external bitmap subtitle path as a fallback after native
    // track selection fails, or when the subtitle is already external.
    if (!canAttemptExternalSubtitleFallback) {
      AppLogger().w(
        'DesktopPlayer',
        '跳过外挂字幕回退: index=${target.index}, codec=${target.codec}, '
            'reason=${_describeExternalSubtitleFallbackBlocker(target)}',
      );
      if (!mounted) {
        return;
      }
      AppToast.show(
        context,
        _externalSubtitleFallbackUnavailableMessage(
          target,
          subtitleKind,
        ),
        position: AppToastPosition.topCenter,
      );
      return;
    }
    _playerService.setSubtitleSelectionHint();
    await _playerService.deselectSubtitleTrack();
    try {
      final subtitleFile = await _prepareExternalSubtitleFile(
        target,
        codec,
        title: targetTitle,
        kind: subtitleKind,
      );
      await _loadExternalSubtitleWithRetry(subtitleFile);
    } catch (e, stackTrace) {
      AppLogger().eWithStack(
        'DesktopPlayer',
        '图形字幕加载失败: index=${target.index}, codec=${target.codec}, title=$targetTitle',
        e,
        stackTrace,
      );
      await _playerService.deselectSubtitleTrack();
      if (!mounted) {
        return;
      }
      AppToast.show(context, '字幕加载失败: $e',
          kind: AppToastKind.error, position: AppToastPosition.topCenter);
    }
  }

  Future<String?> _waitForInternalSubtitleTrackId(
    List<MediaStream> subtitleStreams,
    MediaStream target,
    String? targetTitle,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 14));
    while (DateTime.now().isBefore(deadline)) {
      final trackId = _matchSubtitleTrackId(
        subtitleStreams,
        target.language,
        targetTitle,
        target.codec,
        target.index,
      );
      if (trackId != null && trackId.isNotEmpty) {
        AppLogger().i(
          'DesktopPlayer',
          '等待后匹配到内封字幕轨道: index=${target.index}, trackId=$trackId',
        );
        return trackId;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<bool> _verifyNativeBitmapSubtitleSelection(
    String trackId, {
    String? codec,
    String? title,
  }) async {
    final adapter = _playerService.adapter;
    if (adapter is! MpvPlayerAdapter) {
      return true;
    }
    try {
      return await adapter.waitForSubtitleTrackSelection(
        trackId,
        hintedCodec: codec,
        hintedTitle: title,
      );
    } catch (e, stackTrace) {
      AppLogger().eWithStack(
        'DesktopPlayer',
        '校验 PGS/SUP 内封字幕轨道失败: trackId=$trackId',
        e,
        stackTrace,
      );
      return false;
    }
  }

  bool _hasSubtitleDeliveryUrl(MediaStream target) {
    final deliveryUrl = target.deliveryUrl?.trim();
    return deliveryUrl != null && deliveryUrl.isNotEmpty;
  }

  bool _hasHttpSubtitlePath(MediaStream target) {
    final path = target.path?.trim();
    return path != null &&
        path.isNotEmpty &&
        (path.startsWith('http://') || path.startsWith('https://'));
  }

  bool _canUseApiSubtitleStreamRoute(MediaStream target) {
    if (target.isExternal == true || target.isExternalUrl == true) {
      return true;
    }
    final deliveryMethod = target.deliveryMethod?.trim().toLowerCase();
    return deliveryMethod == 'external';
  }

  bool _canAttemptExternalSubtitleFallback(MediaStream target) {
    return _hasSubtitleDeliveryUrl(target) ||
        _hasHttpSubtitlePath(target) ||
        _canUseApiSubtitleStreamRoute(target);
  }

  String _describeExternalSubtitleFallbackBlocker(MediaStream target) {
    return 'external=${target.isExternal == true}, '
        'externalUrl=${target.isExternalUrl == true}, '
        'deliveryUrl=${_hasSubtitleDeliveryUrl(target)}, '
        'httpPath=${_hasHttpSubtitlePath(target)}, '
        'deliveryMethod=${target.deliveryMethod ?? ''}';
  }

  String _externalSubtitleFallbackUnavailableMessage(
    MediaStream target,
    SubtitleKind subtitleKind,
  ) {
    final adapter = _playerService.adapter;
    final missingPgsDecoder = subtitleKind == SubtitleKind.bitmap &&
        adapter is MpvPlayerAdapter &&
        !adapter.pgsDecoderAvailable;
    if (missingPgsDecoder) {
      return '当前 PC 端缺少 PGS/SUP 解码器，且该字幕没有可下载外挂源';
    }
    if (target.isExternal == true || target.isExternalUrl == true) {
      return '当前外挂字幕没有可用的下载地址';
    }
    return '当前字幕没有可用的外挂下载地址';
  }

  String? _matchAudioTrackId(
      List<MediaStream> audioStreams, int selectedIndex) {
    final tracks = _playerService.tracksInfo;
    final audioTracks =
        tracks.where((track) => track['type'] == 'audio').toList();
    if (audioTracks.isEmpty) {
      return null;
    }

    final position =
        audioStreams.indexWhere((stream) => stream.index == selectedIndex);
    if (position >= 0 && position < audioTracks.length) {
      final trackId = audioTracks[position]['id']?.toString();
      if (trackId != null && trackId.isNotEmpty) {
        return trackId;
      }
    }

    final target = audioStreams
        .where((stream) => stream.index == selectedIndex)
        .firstOrNull;
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
            .where((track) =>
                track['type'] == 'bitmap' || track['isBitmap'] == true)
            .toList()
        : isAss
            ? subtitleTracks
                .where((track) =>
                    track['isAss'] == true || track['type'] == 'text')
                .toList()
            : subtitleTracks;

    if (candidates.isEmpty) {
      return subtitleTracks.isNotEmpty
          ? subtitleTracks.first['id']?.toString()
          : null;
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
        final language =
            (track['language'] ?? '').toString().trim().toLowerCase();
        return language == normalizedTargetLang ||
            language == 'chi' ||
            language == 'zh';
      }).toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
      if (langMatches.length > 1 &&
          targetTitle != null &&
          targetTitle.isNotEmpty) {
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

    final embySubIndex =
        _extractEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
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
        .fold<int?>(
            null, (prev, value) => prev == null || value < prev ? value : prev);
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
    return typedStreams
        .indexWhere((stream) => stream.index == targetStreamIndex);
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

  String _embySubtitleCodec(String codec, {String? title, SubtitleKind? kind}) {
    final lower = codec.toLowerCase();
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    if (lower == 'srt' || lower == 'subrip') {
      return 'srt';
    }
    if (lower == 'vtt' || lower == 'webvtt') {
      return 'vtt';
    }
    if (resolvedKind == SubtitleKind.bitmap) {
      return 'pgs';
    }
    return 'ass';
  }

  List<String> _embySubtitleCodecCandidates(
    String codec, {
    String? title,
    SubtitleKind? kind,
  }) {
    final primary = _embySubtitleCodec(
      codec,
      title: title,
      kind: kind,
    );
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    if (resolvedKind != SubtitleKind.bitmap) {
      return [primary];
    }

    final candidates = <String>['sup', primary, 'pgs'];
    return candidates.toSet().toList();
  }

  String _subtitleFileExtension(String codec,
      {String? title, SubtitleKind? kind}) {
    final lower = codec.toLowerCase();
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    if (lower == 'srt' || lower == 'subrip') {
      return 'srt';
    }
    if (lower == 'vtt' || lower == 'webvtt') {
      return 'vtt';
    }
    if (resolvedKind == SubtitleKind.ass) {
      return 'ass';
    }
    if (resolvedKind == SubtitleKind.bitmap) {
      return 'sup';
    }
    return 'srt';
  }

  Future<File> _prepareExternalSubtitleFile(
    MediaStream target,
    String codec, {
    String? title,
    SubtitleKind? kind,
  }) async {
    final currentSource = _currentMediaSource;
    if (currentSource == null) {
      throw StateError('当前媒体源为空，无法加载外挂字幕');
    }
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    final embyCodecCandidates = _embySubtitleCodecCandidates(
      codec,
      title: title,
      kind: resolvedKind,
    );
    final fileExtension = _subtitleFileExtension(
      codec,
      title: title,
      kind: resolvedKind,
    );
    final tempDir = await getTemporaryDirectory();
    final file = File(
      p.join(
        tempDir.path,
        'desktop_subtitle_${widget.itemId}_${target.index}.$fileExtension',
      ),
    );

    final shouldForceRefresh = resolvedKind == SubtitleKind.bitmap;
    AppLogger().i(
      'DesktopPlayer',
      '准备外挂字幕文件: index=${target.index}, codec=${target.codec}, title=$title, '
          'kind=$resolvedKind, embyCodecs=${embyCodecCandidates.join('/')}, file=${file.path}',
    );
    if (shouldForceRefresh && file.existsSync()) {
      await file.delete();
    }

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
      Object? lastError;
      final subtitleUrls = _subtitleUrlCandidates(
        target: target,
        currentSource: currentSource,
        codecCandidates: embyCodecCandidates,
      );
      if (subtitleUrls.isEmpty) {
        throw StateError('当前字幕没有可用的外挂下载地址');
      }
      AppLogger().i(
        'DesktopPlayer',
        '外挂字幕候选地址: ${subtitleUrls.join(' | ')}',
      );
      for (final subtitleUrl in subtitleUrls) {
        try {
          AppLogger().i(
            'DesktopPlayer',
            '下载外挂字幕: url=$subtitleUrl',
          );
          await dio.download(subtitleUrl, file.path);
          final downloadedSize = await file.length();
          if (downloadedSize <= 0) {
            throw StateError('下载到的字幕文件为空');
          }
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          AppLogger().w(
            'DesktopPlayer',
            '外挂字幕下载失败: url=$subtitleUrl, error=$e',
          );
          if (file.existsSync()) {
            await file.delete();
          }
        }
      }
      if (lastError != null) {
        throw lastError;
      }
    }

    final fileSize = await file.length();
    if (fileSize <= 0) {
      throw StateError('下载到的字幕文件为空: ${file.path}');
    }

    return file;
  }

  List<String> _subtitleUrlCandidates({
    required MediaStream target,
    required MediaSource currentSource,
    required List<String> codecCandidates,
  }) {
    final api = ref.read(apiClientProvider);
    final urls = <String>[];

    final deliveryUrl = target.deliveryUrl?.trim();
    if (deliveryUrl != null && deliveryUrl.isNotEmpty) {
      urls.add(_resolveServerRelativeUrl(deliveryUrl));
    }

    final path = target.path?.trim();
    if (path != null &&
        path.isNotEmpty &&
        (path.startsWith('http://') || path.startsWith('https://'))) {
      urls.add(path);
    }

    if (_canUseApiSubtitleStreamRoute(target)) {
      for (final codec in codecCandidates) {
        urls.add(
          api.playback.getSubtitleStreamUrl(
            widget.itemId,
            currentSource.id,
            target.index,
            codec,
          ),
        );
      }
    }

    return urls.toSet().toList();
  }

  String _resolveServerRelativeUrl(String rawUrl) {
    if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
      return rawUrl;
    }
    final server = ref.read(currentServerProvider);
    final baseUrl = (server?.activeLineUrl ?? server?.baseUrl ?? '').trim();
    if (baseUrl.isEmpty) {
      return rawUrl;
    }
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = rawUrl.startsWith('/') ? rawUrl : '/$rawUrl';
    final authToken = server?.authToken?.trim();
    if (authToken == null ||
        authToken.isEmpty ||
        normalizedPath.contains('api_key=')) {
      return '$normalizedBase$normalizedPath';
    }
    final separator = normalizedPath.contains('?') ? '&' : '?';
    return '$normalizedBase$normalizedPath${separator}api_key=${Uri.encodeQueryComponent(authToken)}';
  }

  // ========== 控制栏显隐 ==========

  Future<void> _loadExternalSubtitleWithRetry(File subtitleFile) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        AppLogger().i(
          'DesktopPlayer',
          '尝试加载外挂字幕: attempt=$attempt, path=${subtitleFile.path}',
        );
        await _playerService.loadLibassSubtitle(subtitleFile.path);
        return;
      } catch (e) {
        lastError = e;
        AppLogger().e(
          'DesktopPlayer',
          '外挂字幕加载失败: attempt=$attempt, path=${subtitleFile.path}, error=$e',
        );
        if (attempt >= 3) {
          break;
        }
        await _playerService.deselectSubtitleTrack();
        await Future.delayed(const Duration(milliseconds: 220));
      }
    }
    throw lastError ?? StateError('外挂字幕加载失败');
  }

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      // 空闲到点就连同上下栏 + 鼠标光标一起隐藏：哪怕鼠标正停在控制栏上、只要不动
      // 也照隐（计时器在每次移动时已被 _onMouseMoved 重置）。仅在拖动进度条时不隐。
      if (_playerService.isPlaying && !_isSeekingWithSlider && mounted) {
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
          _handleExit(); // 同返回按钮：还原外壳后再 pop，避免标题栏丢失
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
        if (event.logicalKey == LogicalKeyboardKey.keyH &&
            HardwareKeyboard.instance.isControlPressed) {
          _toggleControlsVisibility();
        } else if (event.logicalKey == LogicalKeyboardKey.keyS &&
            HardwareKeyboard.instance.isControlPressed) {
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
    try {
      final bool? isFullscreen = Platform.isWindows
          ? await _windowChannel.invokeMethod<bool>('isFullscreen')
          : await windowManager.isFullScreen();
      if (mounted && isFullscreen != null) {
        setState(() => _isFullscreen = isFullscreen);
        ref.read(desktopImmersiveModeProvider.notifier).state = isFullscreen;
      }
    } on MissingPluginException {
      // Ignore on platforms without desktop window integration.
    } on PlatformException {
      // Ignore and keep the local fallback state.
    }
  }

  /// 离开播放页前还原窗口外壳：恢复自绘标题栏并退出 OS 全屏。
  ///
  /// 关键：恢复沉浸态（`desktopImmersiveModeProvider=false`）必须在 widget 仍
  /// mounted、ref 仍有效时执行——若放到 dispose()，ProviderScope 可能已先行
  /// 销毁导致写入被吞，标题栏（含最小化/关闭按钮）永久隐藏、窗口卡在全屏。
  Future<void> _restoreWindowChrome() async {
    // 先恢复标题栏：这步只要 ref 有效就一定成功，是用户能重新操作窗口的关键。
    try {
      ref.read(desktopImmersiveModeProvider.notifier).state = false;
    } catch (_) {}
    if (!_isFullscreen) return;
    try {
      if (Platform.isWindows) {
        await _windowChannel
            .invokeMethod<bool>('setFullscreen', {'fullscreen': false});
      } else {
        await windowManager.setFullScreen(false);
      }
    } on MissingPluginException {
      // 无桌面窗口集成的平台忽略。
    } on PlatformException {
      // 原生侧失败也忽略：标题栏已恢复，用户仍可操作窗口。
    }
    if (mounted) setState(() => _isFullscreen = false);
  }

  /// PopScope 拦截到返回请求后的处理：先还原窗口外壳，再放行真正的 pop。
  ///
  /// 两段式（先 `canPop:false` 拦截 → 还原 → 置 [_allowExitPop] → 下一帧再
  /// pop）是为了避开「canPop=false 时手动 pop 又被自己拦截」的死循环。
  Future<void> _handleExit() async {
    if (_exiting) return;
    _exiting = true;
    await _restoreWindowChrome();
    if (!mounted) return;
    setState(() => _allowExitPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.mounted && context.canPop()) {
        context.pop();
      }
    });
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
        // macOS / Linux 走 window_manager 的原生窗口全屏。
        await windowManager.setFullScreen(target);
        fullscreen = await windowManager.isFullScreen();
      }
    } on MissingPluginException {
      fullscreen = target;
    } on PlatformException {
      fullscreen = target;
    }

    if (!mounted) return;
    setState(() => _isFullscreen = fullscreen);
    // 通知应用根隐藏/恢复自绘标题栏，实现真正的全屏。
    ref.read(desktopImmersiveModeProvider.notifier).state = fullscreen;
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
    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    if (subtitleStreams.isEmpty) return;

    final currentIndex = ref.read(subtitleTrackProvider);
    final currentPosition =
        subtitleStreams.indexWhere((stream) => stream.index == currentIndex);
    final nextPosition = (currentPosition + 1) % (subtitleStreams.length + 1);

    if (nextPosition >= subtitleStreams.length) {
      ref.read(subtitleTrackProvider.notifier).state = null;
      return;
    }

    ref.read(subtitleTrackProvider.notifier).state =
        subtitleStreams[nextPosition].index;
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
        final baseDirectory = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        // 与移动端统一：截图落到 下载/Linpic。
        final screenshotsDirectory =
            Directory(p.join(baseDirectory.path, 'Linpic'));
        if (!await screenshotsDirectory.exists()) {
          await screenshotsDirectory.create(recursive: true);
        }

        final itemName =
            ref.read(currentPlayingItemProvider)?.name ?? widget.itemId;
        final file = File(
          p.join(
            screenshotsDirectory.path,
            _buildScreenshotFileName(itemName, DateTime.now()),
          ),
        );
        await file.writeAsBytes(data, flush: true);

        if (!mounted) return;
        AppToast.show(context, '截图已保存到 ${file.path}',
            position: AppToastPosition.topCenter);
      } else {
        AppToast.show(context, '截图功能暂不支持当前播放器内核',
            position: AppToastPosition.topCenter);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '截图失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
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
      _speedLongPressTimer =
          Timer.periodic(const Duration(milliseconds: 120), (_) {
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
          AppToast.show(context, '已经是第一集了',
              position: AppToastPosition.topCenter);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '加载失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
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
          AppToast.show(context, '已经是最后一集了',
              position: AppToastPosition.topCenter);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '加载失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
      }
    }
  }

  // ========== Anime4K ==========

  Future<void> _showAnime4KMenu() async {
    final currentLevel = ref.read(anime4KLevelProvider);
    // Anime4K 纯去噪放大梯子（无 Restore/锐化，不拖影）：核显→壮机，越往后越清晰越吃显卡。
    const levels = [
      {'value': 'off', 'label': '关闭'},
      {'value': 'modeA', 'label': '去噪 S · 核显轻量'},
      {'value': 'modeB', 'label': '去噪 M · 均衡'},
      {'value': 'modeC', 'label': '去噪 L · 清晰'},
      {'value': 'modeAA', 'label': '去噪叠加 M · 更净'},
      {'value': 'modeBB', 'label': '去噪叠加 L · 强'},
      {'value': 'modeAC', 'label': '去噪叠加 VL · 壮机'},
    ];
    final result = await showPlayerSettingsPanel<String>(
      context: context,
      title: 'Anime4K 超分设置',
      width: 320,
      children: levels
          .map((level) => PanelOptionTile(
                label: level['label']!,
                selected: currentLevel == level['value'],
                onTap: () => Navigator.pop(context, level['value']),
              ))
          .toList(),
    );
    if (result != null && mounted) {
      try {
        ref.read(anime4KLevelProvider.notifier).state = result;
        // 软件纹理（Win/macOS 消闪屏）下 SW 渲染不跑 GLSL shader，无法运行时开超分。
        // 不再整段重建播放管线（那会把已缓冲的流从头重新下载、进度跳回、爆卡），
        // 而是存下档位、提示下次播放生效——起播时用硬件纹理重建自然带上 shader。
        if (result != 'off' && !_playerService.superResolutionCanApplyLive) {
          if (!mounted) return;
          AppToast.show(
            context,
            '已选择 Anime4K ${_anime4KLevelLabel(result)}，将在下次播放时生效',
            position: AppToastPosition.topCenter,
          );
          return;
        }
        if (result == 'off') {
          await _playerService.applySuperResolution(false);
        } else {
          await _playerService.applySuperResolutionLevel(result);
        }
        if (!mounted) return;
        final n = _playerService.activeGlslShaderCount;
        AppToast.show(
          context,
          result == 'off'
              ? '已关闭 Anime4K 超分'
              : n > 0
                  ? '已应用 Anime4K ${_anime4KLevelLabel(result)}（$n 个 shader）'
                  : '⚠️ Anime4K shader 未进入内核，超分未生效',
          kind: result != 'off' && n == 0
              ? AppToastKind.error
              : AppToastKind.info,
          position: AppToastPosition.topCenter,
        );
      } catch (e) {
        ref.read(anime4KLevelProvider.notifier).state = 'off';
        if (!mounted) return;
        AppToast.show(context, 'Anime4K 应用失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
      }
    }
  }

  String _anime4KLevelLabel(String level) {
    switch (level) {
      case 'modeA':
        return '去噪 S';
      case 'modeB':
        return '去噪 M';
      case 'modeC':
        return '去噪 L';
      case 'modeAA':
        return '去噪叠加 M';
      case 'modeBB':
        return '去噪叠加 L';
      case 'modeAC':
        return '去噪叠加 VL';
      default:
        return level;
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

    void go(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    showPlayerSettingsPanel(
      context: context,
      title: '更多选项',
      width: 320,
      children: [
        PanelOptionTile(
          label: '截图',
          leading: const Icon(Icons.camera_alt_outlined),
          selected: false,
          onTap: () => go(_takeScreenshot),
        ),
        PanelOptionTile(
          label: '字幕选择',
          leading: const Icon(Icons.subtitles_outlined),
          selected: false,
          onTap: () => go(_showSubtitleSelector),
        ),
        if (isMpv)
          PanelOptionTile(
            label: '次字幕选择',
            leading: const Icon(Icons.subtitles),
            selected: false,
            onTap: () => go(_showSecondarySubtitleSelector),
          ),
        PanelOptionTile(
          label: '音轨选择',
          leading: const Icon(Icons.audiotrack),
          selected: false,
          onTap: () => go(_showAudioSelector),
        ),
        if (item?.seriesId != null)
          PanelOptionTile(
            label: '选集',
            leading: const Icon(Icons.playlist_play),
            selected: false,
            onTap: () => go(_showEpisodeSelector),
          ),
        PanelOptionTile(
          label: '画面比例',
          leading: const Icon(Icons.aspect_ratio),
          selected: false,
          onTap: () => go(_showAspectRatioDialog),
        ),
        const PanelDivider(),
        PanelOptionTile(
          label: '硬件解码',
          subtitle: hardwareDecoding ? '当前已开启' : '当前已关闭',
          leading: const Icon(Icons.memory),
          selected: hardwareDecoding,
          onTap: () => go(_toggleHardwareDecoding),
        ),
        if (isMpv)
          PanelOptionTile(
            label: 'Anime4K 超分',
            subtitle: anime4KLevel == 'off'
                ? '当前已关闭'
                : '当前: ${_anime4KLevelLabel(anime4KLevel)}',
            leading: const Icon(Icons.hd),
            selected: anime4KLevel != 'off',
            onTap: () => go(_showAnime4KMenu),
          ),
        // 零拷贝解码：仅 Windows + mpv。d3d11va 解码帧直连 ANGLE、免每帧拷回，
        // 消除硬件纹理下的卡/闪，故默认开；个别显卡若花屏/黑屏可关掉回落 auto-copy。
        if (isMpv && Platform.isWindows)
          PanelOptionTile(
            label: '零拷贝解码（d3d11va）',
            subtitle: _playerService.zeroCopyHwdec
                ? '当前: d3d11va 直连（默认，更顺；若花屏/黑屏请关）'
                : '当前: auto-copy 拷回（兼容兜底）',
            leading: const Icon(Icons.bolt),
            selected: _playerService.zeroCopyHwdec,
            onTap: () => go(_toggleZeroCopyHwdec),
          ),
        PanelOptionTile(
          label: '统计信息',
          subtitle: _showStatsOverlay ? '显示中' : '已隐藏',
          leading: const Icon(Icons.analytics),
          selected: _showStatsOverlay,
          onTap: () => go(_toggleStatsOverlay),
        ),
        PanelOptionTile(
          label: _isFullscreen ? '退出全屏' : '进入全屏',
          leading: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
          selected: false,
          onTap: () => go(_toggleFullscreen),
        ),
      ],
    );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自动', '16:9', '4:3', '21:9', '全屏', '原始'];
    final currentRatio = ref.read(aspectRatioProvider);

    showPlayerSettingsPanel(
      context: context,
      title: '画面比例',
      width: 300,
      children: ratios
          .map((ratio) => PanelOptionTile(
                label: ratio,
                selected: currentRatio == ratio,
                onTap: () {
                  ref.read(aspectRatioProvider.notifier).state = ratio;
                  _playerService.setAspectRatio(ratio);
                  Navigator.pop(context);
                  AppToast.show(context, '画面比例: $ratio',
                      position: AppToastPosition.topCenter);
                },
              ))
          .toList(),
    );
  }

  // ========== 选集弹窗 ==========

  void _showEpisodeSelector() {
    final item = ref.read(currentPlayingItemProvider);
    if (item?.seriesId == null) return;

    showPlayerSettingsPanel(
      context: context,
      title: '选集',
      width: 420,
      children: [
        // 不再套固定高度 SizedBox + 自带滚动条(那样双层嵌套滚动,面板里滑不动)。
        // 直接让选集列表随内容展开,交给面板统一的滚轮/拖拽滚动。
        _EpisodeSelectorList(
          seriesId: item!.seriesId!,
          currentEpisodeId: item.id,
          currentMediaSourceId: ref.read(selectedMediaSourceProvider),
        ),
      ],
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
      AppToast.show(context, '当前没有可切换的字幕轨道',
          position: AppToastPosition.topCenter);
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
      onTranslate: () => _translateSubtitle(subtitleStreams),
      translateStreaming: _streamTranslator != null,
      onWhisper: ref.read(whisperEnabledProvider)
          ? () => _toggleWhisperStreaming()
          : null,
      whisperRunning: _whisperController?.isRunning ?? false,
    );
  }

  Future<void> _showAudioSelector() async {
    await _waitForTrackSelectorItems(subtitle: false);
    final audioStreams = _audioStreamsFromCurrentSource();
    if (audioStreams.isEmpty) {
      if (!mounted) return;
      AppToast.show(context, '当前没有可切换的音轨',
          position: AppToastPosition.topCenter);
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

  /// 次字幕选择（桌面）。次字幕走 MPV `secondary-sid`，仅支持文本字幕,
  /// 图形字幕(PGS/SUP)与已作主字幕的那一条都排除。设 provider 后由监听器套用。
  Future<void> _showSecondarySubtitleSelector() async {
    await _waitForTrackSelectorItems(subtitle: true);
    final primaryIndex = ref.read(subtitleTrackProvider);
    final streams = _subtitleStreamsFromCurrentSource().where((s) {
      final kind = SubtitleTrackMatcher.classifyKind(
          codec: s.codec, title: s.displayTitle ?? s.title);
      return kind != SubtitleKind.bitmap && s.index != primaryIndex;
    }).toList();
    if (streams.isEmpty) {
      if (!mounted) return;
      AppToast.show(context, '没有可作为次字幕的文本字幕轨道',
          position: AppToastPosition.topCenter);
      return;
    }
    if (!mounted) return;
    final selectedIndex = ref.read(secondarySubtitleTrackProvider);
    showPlayerSettingsPanel(
      context: context,
      title: '次字幕选择',
      width: 380,
      children: [
        PanelOptionTile(
          label: '关闭次字幕',
          selected: selectedIndex == null,
          onTap: () {
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
            Navigator.pop(context);
          },
        ),
        ...streams.map((stream) => PanelOptionTile(
              label: stream.readableLabel(siblings: streams),
              subtitle: stream.codec != null
                  ? '编码: ${stream.codec}'
                      '${stream.isExternal == true ? ' (外挂)' : ' (内封)'}'
                  : null,
              selected: selectedIndex == stream.index,
              onTap: () {
                ref.read(secondarySubtitleTrackProvider.notifier).state =
                    stream.index;
                Navigator.pop(context);
              },
            )),
      ],
    );
  }

  /// 翻译字幕轨为中文并加载（桌面）。
  Future<void> _translateSubtitle(List<MediaStream> subtitleStreams) async {
    // 已在流式翻译中 → 再次点击即停止。
    if (_streamTranslator != null) {
      _stopStreamingTranslate();
      _translateMsg('已停止流式翻译');
      return;
    }
    final engine = ref.read(activeTranslationEngineProvider);
    if (engine == null) {
      _translateMsg('请先在「设置 → 字幕翻译」中配置翻译引擎');
      return;
    }
    final source = _currentMediaSource;
    if (source == null) {
      _translateMsg('无播放信息');
      return;
    }
    MediaStream? stream;
    final sel = ref.read(subtitleTrackProvider);
    if (sel != null) {
      for (final s in subtitleStreams) {
        if (s.index == sel) {
          stream = s;
          break;
        }
      }
    }
    stream ??= subtitleStreams.length == 1
        ? subtitleStreams.first
        : await _pickStreamToTranslate(subtitleStreams);
    if (stream == null) return;

    final progress = ValueNotifier<String>('准备中…');
    if (!mounted) {
      progress.dispose();
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(ctx).colorScheme.primary)),
              const SizedBox(width: 16),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final path = await TranslationActions.translateEmbyStream(
        api: ref.read(apiClientProvider),
        service: ref.read(subtitleTranslationServiceProvider),
        engine: engine,
        itemId: widget.itemId,
        mediaSourceId: source.id,
        stream: stream,
        targetLang: ref.read(translationTargetLangProvider),
        layout: ref.read(bilingualLayoutProvider),
        authToken: ref.read(currentServerProvider)?.authToken,
        onProgress: (done, total, stage) {
          progress.value = total > 1 ? '$stage $done/$total' : stage;
        },
      );
      await _playerService.loadLibassSubtitle(path);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _translateMsg('翻译完成并已加载中文字幕');
      }
    } catch (e, st) {
      AppLogger().eWithStack('DesktopPlayer', '字幕翻译失败', e, st);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      // 内封字幕拉取不到（服务端不支持单轨导出）→ 自动改为流式翻译。
      if (e.toString().contains('所有字幕地址均不可用')) {
        _startStreamingTranslate(engine, stream);
      } else if (mounted) {
        _translateMsg('翻译失败: $e');
      }
    } finally {
      progress.dispose();
    }
  }

  /// 内封字幕无法整轨下载时，启动流式翻译（边播边译，叠加层显示中文）。
  void _startStreamingTranslate(TranslationEngine engine, MediaStream stream) {
    _streamTranslator?.stop();
    final translator = StreamingSubtitleTranslator(
      engine: engine,
      sourceLang: (stream.language?.isNotEmpty ?? false)
          ? stream.language!
          : 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
    );
    translator.errorMessage.addListener(() {
      final msg = translator.errorMessage.value;
      if (msg != null && mounted) {
        _translateMsg('流式翻译引擎错误: $msg');
      }
    });
    _streamTranslator = translator;
    translator.start(_playerService);
    if (mounted) setState(() {});
    _translateMsg('该字幕为内封、无法整轨下载，已改为流式翻译（边播边译）');
  }

  void _stopStreamingTranslate() {
    _streamTranslator?.stop();
    _streamTranslator = null;
    if (mounted) setState(() {});
  }

  Future<MediaStream?> _pickStreamToTranslate(List<MediaStream> subs) {
    return showPlayerSettingsPanel<MediaStream>(
      context: context,
      title: '选择要翻译的字幕轨',
      width: 380,
      children: [
        for (final s in subs)
          PanelOptionTile(
            label: s.readableLabel(siblings: subs),
            subtitle: s.codec != null ? '编码: ${s.codec}' : null,
            selected: false,
            onTap: () => Navigator.pop(context, s),
          ),
      ],
    );
  }

  void _translateMsg(String msg) {
    if (!mounted) return;
    AppToast.show(context, msg, position: AppToastPosition.topCenter);
  }

  /// 启动/停止 Whisper 实时字幕（桌面专属）。
  Future<void> _toggleWhisperStreaming() async {
    if (_whisperController?.isRunning ?? false) {
      _whisperController?.stop();
      if (mounted) setState(() {});
      _translateMsg('已停止 Whisper 实时字幕');
      return;
    }
    final engine = ref.read(activeTranslationEngineProvider);
    if (engine == null) {
      _translateMsg('请先在「设置 → 字幕翻译」中配置翻译引擎');
      return;
    }
    final source = _videoUrl;
    if (source == null) {
      _translateMsg('无视频源');
      return;
    }

    final manager = WhisperModelManager();
    final model = ref.read(whisperModelProvider);
    if (!await manager.isDownloaded(model)) {
      _translateMsg('请先在「设置 → 字幕翻译 → Whisper」中下载 ${model.displayName} 模型');
      return;
    }
    final modelFile = await manager.modelFile(model);

    final binMgr = DesktopBinaryManager();
    // whisper-cli：内置/PATH/已配置中定位。
    final whisperPath =
        await binMgr.resolveWhisper(configured: ref.read(whisperBinaryPathProvider));
    if (whisperPath == null) {
      _translateMsg('未找到 whisper-cli（应随应用内置，或在「设置」中指定其路径）');
      return;
    }
    // ffmpeg：自动检测，缺失则征求许可下载。
    var ffmpegPath =
        await binMgr.resolveFfmpeg(configured: ref.read(ffmpegPathProvider));
    if (ffmpegPath == null) {
      ffmpegPath = await _promptDownloadFfmpeg(binMgr);
      if (ffmpegPath == null) {
        _translateMsg('未安装 ffmpeg，已取消');
        return;
      }
      ref.read(ffmpegPathProvider.notifier).state = ffmpegPath;
    }

    final extractor = WhisperAudioExtractor(ffmpegPath: ffmpegPath);
    final transcriber = WhisperTranscriber(
      modelPath: modelFile.path,
      binaryPath: whisperPath,
    );

    final controller = WhisperSubtitleController(
      engine: engine,
      translationService: ref.read(subtitleTranslationServiceProvider),
      extractor: extractor,
      transcriber: transcriber,
      sourceLang: 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
      onSubtitleUpdated: (path) async {
        try {
          await _playerService.loadLibassSubtitle(path);
        } catch (_) {}
      },
    );
    _whisperController = controller;
    if (mounted) setState(() {});
    _translateMsg('Whisper 实时字幕已启动，将随播放逐步生成');

    final token = ref.read(currentServerProvider)?.authToken;
    // 后台运行，不阻塞 UI。
    unawaited(controller.start(
      source: source,
      total: _playerService.duration,
      positionGetter: () => _playerService.position,
      authToken: token,
    ));
  }

  /// 征求许可后下载 ffmpeg，返回安装路径或 null（取消/失败）。
  Future<String?> _promptDownloadFfmpeg(DesktopBinaryManager binMgr) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('需要 ffmpeg'),
        content: const Text(
          'Whisper 实时字幕需要 ffmpeg 抽取音频。系统中未检测到 ffmpeg，'
          '是否现在下载官方静态构建？',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载')),
        ],
      ),
    );
    if (ok != true) return null;

    final progress = ValueNotifier<String>('下载 ffmpeg…');
    if (!mounted) {
      progress.dispose();
      return null;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(ctx).colorScheme.primary)),
              const SizedBox(width: 16),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      final path = await binMgr.downloadFfmpeg(onProgress: (r, t, p) {
        progress.value =
            t > 0 ? '下载 ffmpeg… ${(p * 100).toStringAsFixed(0)}%' : '下载 ffmpeg…';
      });
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      return path;
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _translateMsg('ffmpeg 下载失败: $e');
      }
      return null;
    } finally {
      progress.dispose();
    }
  }

  void _showTrackSelectorDialog({
    required String title,
    required List<MediaStream> streams,
    required int? selectedIndex,
    required ValueChanged<int> onSelect,
    required bool subtitle,
    bool canDisable = false,
    VoidCallback? onTranslate,
    bool translateStreaming = false,
    VoidCallback? onWhisper,
    bool whisperRunning = false,
  }) {
    showPlayerSettingsPanel(
      context: context,
      title: title,
      width: 380,
      children: [
        if (onTranslate != null)
          PanelActionTile(
            icon: translateStreaming ? Icons.stop_circle : Icons.translate,
            label: translateStreaming ? '停止流式翻译' : '翻译字幕（生成中文）',
            onTap: () {
              Navigator.pop(context);
              onTranslate();
            },
          ),
        if (onWhisper != null)
          PanelActionTile(
            icon: whisperRunning ? Icons.stop_circle : Icons.record_voice_over,
            label: whisperRunning ? '停止 Whisper 实时字幕' : 'Whisper 实时字幕',
            onTap: () {
              Navigator.pop(context);
              onWhisper();
            },
          ),
        if (onTranslate != null || onWhisper != null) const PanelDivider(),
        if (canDisable)
          PanelOptionTile(
            label: '关闭字幕',
            selected: selectedIndex == null,
            onTap: () {
              _playerService.deselectSubtitleTrack();
              Navigator.pop(context);
            },
          ),
        ...streams.map((stream) => PanelOptionTile(
              label: stream.readableLabel(siblings: streams),
              subtitle: stream.codec != null
                  ? '编码: ${stream.codec}${subtitle ? (stream.isExternal == true ? ' (外挂)' : ' (内封)') : ''}'
                  : null,
              selected: selectedIndex == stream.index,
              onTap: () {
                onSelect(stream.index);
                Navigator.pop(context);
              },
            )),
      ],
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
    // 有面板/弹窗盖在播放页上时(播放页不再是当前路由),滚轮交给面板列表滚动,不改音量。
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    _adjustVolume(delta);
  }

  // ========== 统计信息行 ==========

  List<Widget> _buildStatsRows(Map<String, String> stats) {
    final rows = <Widget>[];

    // 文件信息
    final versionName = _currentMediaSource?.name?.trim();
    if (versionName != null && versionName.isNotEmpty) {
      rows.add(_buildStatRow('文件', versionName));
    }

    final fileSize = stats['file-size'];
    if (fileSize != null && fileSize != 'null') {
      final size = int.tryParse(fileSize);
      if (size != null) {
        rows.add(_buildStatRow('大小', _formatFileSize(size)));
      }
    }

    // 视频信息
    final width = stats['width'];
    final height = stats['height'];
    if (width != null && height != null) {
      rows.add(_buildStatRow('分辨率', '$width x $height'));
    }

    final fps = stats['container-fps'] ?? stats['fps'];
    if (fps != null) {
      rows.add(_buildStatRow('帧率', '$fps fps'));
    }

    final videoBitrate = stats['video-bitrate'];
    if (videoBitrate != null) {
      final bitrate = int.tryParse(videoBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('视频码率', _formatBitrate(bitrate)));
      }
    }

    final videoCodec = stats['video-codec'] ??
        stats['current-tracks/video/codec'];
    if (videoCodec != null && videoCodec.isNotEmpty) {
      rows.add(_buildStatRow('视频编码', videoCodec));
    }

    final pixelFormat = stats['video-params/pixelformat'];
    if (pixelFormat != null && pixelFormat.isNotEmpty) {
      rows.add(_buildStatRow('像素格式', pixelFormat));
    }

    // 音频信息
    final audioCodec = stats['audio-codec'] ??
        stats['current-tracks/audio/codec'];
    if (audioCodec != null && audioCodec.isNotEmpty) {
      rows.add(_buildStatRow('音频编码', audioCodec));
    }

    final audioBitrate = stats['audio-bitrate'];
    if (audioBitrate != null) {
      final bitrate = int.tryParse(audioBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('音频码率', _formatBitrate(bitrate)));
      }
    }

    final sampleRate = stats['audio-params/sample-rate'];
    if (sampleRate != null) {
      rows.add(_buildStatRow('采样率', '${sampleRate}Hz'));
    }

    final channels = stats['audio-params/channel-count'];
    if (channels != null) {
      rows.add(_buildStatRow('声道', '${channels}ch'));
    }

    // 硬解
    final hwdec = stats['hwdec-current'];
    if (hwdec != null && hwdec.isNotEmpty && hwdec != 'no') {
      rows.add(_buildStatRow('硬解', hwdec));
    }

    // 播放速度。其余实时指标(渲染帧率/丢帧/缓冲/位置)已移除——
    // 它们要每秒轮询 mpv,会与 libmpv 渲染线程争用导致画面闪,
    // 且非常用视频参数;统计面板只展示开播即定的视频/音频参数,查一次即可。
    rows.add(
        _buildStatRow('速度', '${_playerService.speed.toStringAsFixed(2)}x'));

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
    if (bytes < 1024) {
      return '${bytes}B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
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
    WidgetsBinding.instance.removeObserver(this);
    // 先取消所有定时器/订阅，确保即便后续 ref 调用抛错也不会留下仍在运行的
    // 周期定时器（它们会在半销毁状态下继续 ref.read 触发连环崩溃）。
    _cancelHideControlsTimer();
    _skipButtonTimer?.cancel();
    _speedLongPressTimer?.cancel();
    _volumeSliderTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _playbackStats.dispose();
    // 离开播放页时退出全屏并恢复标题栏，避免窗口停在无边框全屏、标题栏却消失的状态。
    if (_isFullscreen) {
      if (Platform.isWindows) {
        _windowChannel.invokeMethod<bool>(
            'setFullscreen', {'fullscreen': false});
      } else {
        windowManager.setFullScreen(false);
      }
    }
    // 整棵路由子树被销毁时 ProviderScope 可能已先行 dispose，此处 ref 访问会抛
    // "Cannot use ref after the widget was disposed"。用 try/catch 包裹，避免 dispose
    // 中途抛错导致 super.dispose() 不被调用、State 停留在半销毁的僵尸态。
    try {
      ref.read(desktopImmersiveModeProvider.notifier).state = false;
    } catch (_) {}
    _whisperController?.stop();
    _streamTranslator?.dispose();
    _introSkip.dispose();
    _focusNode.dispose();
    unawaited(PrefetchProxy.instance.stop());
    _playerService.dispose();
    super.dispose();
  }

  /// 多线程加载预取代理：仅在「开关开 + 已确认服主允许 + 在线 http 源」时启动，
  /// 返回本地播放 URL（失败/不满足条件返回 null，调用方回退在线直链）。
  Future<String?> _maybeStartPrefetch(String onlineUrl,
      {Future<String?> Function()? onExpired}) async {
    try {
      if (!onlineUrl.startsWith('http')) return null;
      // 仅对用户加入「多线程加载」白名单（已确认获服主允许）的当前服务器启用。
      final serverId = ref.read(currentServerProvider)?.id;
      if (serverId == null ||
          !ref.read(multiThreadLoadingServersProvider).contains(serverId)) {
        return null;
      }
      final limitMb = await CacheService.getVideoCacheMaxSizeMB();
      return await PrefetchProxy.instance.start(
        upstreamUrl: onlineUrl,
        threads: ref.read(multiThreadLoadingThreadsProvider),
        cacheLimitBytes: limitMb * 1024 * 1024,
        onUpstreamInvalid: onExpired,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeWatchHistoryForItem({
    required MediaItem item,
    required int positionTicks,
    bool incrementPlayCount = false,
    bool force = false,
  }) async {
    // 播放器进度/停止回调可能在播放页销毁后仍触发，此时严禁再用 ref。
    if (!mounted) return;
    final scopeKey = buildWatchHistoryScopeKey(ref.read(currentServerProvider));
    if (scopeKey == null) {
      return;
    }
    try {
      final record = await ref.read(watchHistoryProvider).capturePlayback(
            scopeKey: scopeKey,
            api: ref.read(apiClientProvider),
            item: item,
            positionTicks: positionTicks,
            source: WatchHistoryWriteSource.internalPlayer,
            watchedThresholdPercent: ref.read(watchedThresholdProvider),
            incrementPlayCount: incrementPlayCount,
            force: force,
          );
      _maybeWriteBackCrossServer(
        scopeKey: scopeKey,
        item: item,
        record: record,
        force: force,
      );
    } catch (_) {
      // Ignore local watch history failures to avoid interrupting playback.
    }
  }

  /// 看完 / 停止时，把进度与「已看完」回传到其它服务器（受设置开关控制）。
  void _maybeWriteBackCrossServer({
    required String scopeKey,
    required MediaItem item,
    required WatchHistoryRecord? record,
    required bool force,
  }) {
    if (record == null || !mounted) return;
    if (!ref.read(crossServerWritebackEnabledProvider)) return;
    // 仅在「看完」或显式停止时回传，避免每个进度回调都打其它服务器。
    if (!record.played && !force) return;
    unawaited(
      ref.read(watchHistoryWritebackServiceProvider).propagate(
            currentScopeKey: scopeKey,
            currentApi: ref.read(apiClientProvider),
            item: item,
            positionTicks: record.lastPositionTicks,
            played: record.played,
            servers: ref.read(serverListProvider),
            range: ref.read(crossServerWritebackRangeProvider),
            includeProgress: ref.read(crossServerWritebackProgressProvider),
          ),
    );
  }

  Future<void> _persistCurrentWatchHistory({bool force = false}) async {
    final item = ref.read(currentPlayingItemProvider);
    if (item == null) {
      return;
    }
    await _writeWatchHistoryForItem(
      item: item,
      positionTicks: (_playerService.position.inMilliseconds * 10000).round(),
      force: force,
    );
  }

  // ========== 统计信息显示 ==========

  void _toggleStatsOverlay() {
    setState(() => _showStatsOverlay = !_showStatsOverlay);
    if (_showStatsOverlay) {
      // 只查一次:统计面板只展示开播即定的视频/音频参数,无需每秒轮询
      // (轮询 mpv 会与渲染争用导致画面闪)。
      _refreshStats();
    } else {
      _playbackStats.value = const {};
    }
  }

  Future<void> _refreshStats() async {
    if (!mounted) return;
    final stats = await _playerService.getPlaybackStats();
    if (mounted && _showStatsOverlay) {
      _playbackStats.value = stats;
    }
  }

  /// 弹幕叠加层（鼠标穿透）。开关/无弹幕时返回空。
  Widget _buildDanmakuOverlay() {
    final enabled = ref.watch(danmakuEnabledProvider);
    final items = ref.watch(loadedDanmakuProvider);
    if (!enabled || items.isEmpty) return const SizedBox.shrink();
    final delay = ref.watch(danmakuDelayProvider);
    return Positioned.fill(
      child: IgnorePointer(
        child: DanmakuOverlay(
          items: items,
          position: _playerService.position -
              Duration(milliseconds: (delay * 1000).round()),
          isPlaying: _playerService.isPlaying,
          opacity: ref.watch(danmakuOpacityProvider),
          fontSizeFactor: ref.watch(danmakuFontSizeProvider),
          speedFactor: ref.watch(danmakuSpeedProvider),
          densityFactor: ref.watch(danmakuDensityProvider),
          displayArea: ref.watch(danmakuDisplayAreaProvider),
          stroke: ref.watch(danmakuStrokeProvider),
          fontFamily: ref.watch(customDanmakuFontPathProvider).isEmpty
              ? null
              : FontService.danmakuFontFamily,
        ),
      ),
    );
  }

  /// 打开「搜索弹幕」弹层（复用移动端的分源搜索面板）。
  void _openDanmakuSearch() {
    final item = ref.read(currentPlayingItemProvider);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1C1C1E),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                child: Row(
                  children: [
                    const Icon(Icons.subtitles_outlined,
                        color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    const Text('搜索弹幕',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: DanmakuSearchContent(item: item),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 弹幕快捷设置弹层（开关 + 透明度/显示区域/描边）。
  void _openDanmakuSettings() {
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, r, _) {
          return Dialog(
            backgroundColor: const Color(0xFF1C1C1E),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示弹幕',
                          style: TextStyle(color: Colors.white)),
                      value: r.watch(danmakuEnabledProvider),
                      onChanged: (v) =>
                          r.read(danmakuEnabledProvider.notifier).state = v,
                    ),
                    _slider(r, '透明度', danmakuOpacityProvider),
                    _slider(r, '字号', danmakuFontSizeProvider),
                    _slider(r, '速度', danmakuSpeedProvider),
                    _slider(r, '密度', danmakuDensityProvider),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示区域',
                          style: TextStyle(color: Colors.white)),
                      trailing: DropdownButton<double>(
                        dropdownColor: const Color(0xFF2C2C2E),
                        value: r.watch(danmakuDisplayAreaProvider),
                        items: const [
                          DropdownMenuItem(
                              value: 0.25,
                              child: Text('顶部 1/4',
                                  style: TextStyle(color: Colors.white))),
                          DropdownMenuItem(
                              value: 0.5,
                              child: Text('半屏',
                                  style: TextStyle(color: Colors.white))),
                          DropdownMenuItem(
                              value: 1.0,
                              child: Text('全屏',
                                  style: TextStyle(color: Colors.white))),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            r.read(danmakuDisplayAreaProvider.notifier).state =
                                v;
                          }
                        },
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('描边文字',
                          style: TextStyle(color: Colors.white)),
                      value: r.watch(danmakuStrokeProvider),
                      onChanged: (v) =>
                          r.read(danmakuStrokeProvider.notifier).state = v,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slider(
      WidgetRef r,
      String label,
      StateNotifierProvider<PreferenceNotifier<double>, double> p) {
    final value = r.watch(p);
    return Row(
      children: [
        SizedBox(
            width: 48,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: (v) => r.read(p.notifier).state = v,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final isMpv = normalizePlayerCore(ref.read(playerCoreProvider)) == 'mpv';

    return PopScope(
      // 拦截所有返回路径（返回按钮 / ESC / 系统返回），先还原窗口外壳再放行，
      // 确保退出全屏后窗口一定窗口化、自绘标题栏一定恢复，杜绝卡全屏。
      canPop: _allowExitPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleExit();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) {
          _handleKeyEvent(event);
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          // 控制栏隐藏时一并隐藏鼠标光标；移动鼠标(onHover)会重新显示控制栏与光标。
          cursor: _showControls ? MouseCursor.defer : SystemMouseCursors.none,
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

                // 弹幕层（鼠标穿透，不挡控制栏）。
                _buildDanmakuOverlay(),

                // 流式翻译译文叠加层（中文显示在 mpv 原文字幕上方，构成双语）。
                if (_streamTranslator != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 72,
                    child: IgnorePointer(
                      child: ValueListenableBuilder<String>(
                        valueListenable: _streamTranslator!.displayText,
                        builder: (context, text, _) {
                          if (text.isEmpty) return const SizedBox.shrink();
                          return Center(
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                text,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(blurRadius: 4, color: Colors.black),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                // 缓冲指示器
                if (_playerService.isBuffering)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: 1,
                        duration: const Duration(milliseconds: 140),
                        curve: Curves.easeOut,
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.88),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.4,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text(
                                  '正在缓冲，等待更多数据...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 错误显示：只展示安全文案，绝不回显含播放地址的原始报错。
                if (_playerService.hasError || _initErrorMessage != null)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.white, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            friendlyPlaybackError(
                                _initErrorMessage ?? _playerService.errorMessage),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            kPlaybackErrorFeedbackHint,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 12,
                                height: 1.6),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 6),
                          const SelectableText(
                            kFeedbackChannelUrl,
                            style: TextStyle(
                                color: Color(0xFF5B8DEF),
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _initializePlayer,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 视频热区点击层
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: _onVideoTapUp,
                  onDoubleTap: _toggleFullscreen,
                ),

                // 统计信息覆盖层（MPV式OSD）— 常驻 + Offstage 切换显隐，
                // 避免 Stack children 增删导致视频 Texture 重新合成卡一帧。
                Positioned(
                  top: 80,
                  left: 16,
                  child: IgnorePointer(
                    child: Offstage(
                      offstage: !_showStatsOverlay,
                      // 自成一层:每秒统计刷新的重绘不弄脏视频 Texture 所在合成层。
                      child: RepaintBoundary(
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
                            child: ValueListenableBuilder<Map<String, String>>(
                              valueListenable: _playbackStats,
                              builder: (context, stats, _) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (stats.isEmpty)
                                    const Text('正在获取统计信息...')
                                  else
                                    ..._buildStatsRows(stats),
                                ],
                              ),
                            ),
                          ),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),

                // 控制栏覆盖层。用 RepaintBoundary 把控制栏自成一层：进度条每 200ms
                // 刷新时只重绘控制栏这层，不再把渐变叠加层整片重新混合到 4K 视频上，
                // 显著缓解「上下栏在时更卡」。
                if (_showControls && !_playerService.isLocked)
                  RepaintBoundary(child: _buildControlsOverlay(item, isMpv)),

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
                // 网盘转码源（夸克等）清晰度切换：仅源直链播放且有多档时显示。
                if (widget.sourcePlay != null &&
                    _showControls &&
                    !_playerService.isLocked)
                  Positioned(
                    right: 24,
                    bottom: 96,
                    child: SourceQualityButton(onSelect: _switchSourceQuality),
                  ),
              ],
            ),
          ),
        ),
      ),
    ));
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
            child:Container(
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
            child:Center(
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
                    icon:
                        _playerService.isLocked ? Icons.lock : Icons.lock_open,
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
            child:Center(
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

        // 自动跳过片头/片尾按钮：左下角、底栏之上，随控制栏一并显隐。
        Positioned(
          left: 24,
          bottom: 96,
          child: ValueListenableBuilder<SkipPrompt?>(
            valueListenable: _introSkip.prompt,
            builder: (context, prompt, _) {
              if (prompt == null) return const SizedBox.shrink();
              return ElevatedButton.icon(
                onPressed: () => _onIntroSkipPressed(prompt),
                icon: const Icon(Icons.skip_next, size: 18),
                label: Text(prompt.label),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                ),
              );
            },
          ),
        ),

        // 底栏渐变背景
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            child:Container(
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
            // 走两段式退出：先在 mounted 时还原窗口外壳（恢复标题栏/退全屏）再 pop。
            // 直接 context.pop() 会强制越过 PopScope，靠 dispose 里还原沉浸态又可能被
            // ProviderScope 提前销毁吞掉 → 回到详情页标题栏（最小化/关闭）永久消失。
            onPressed: _handleExit,
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
              color: ref.watch(anime4KLevelProvider) != 'off'
                  ? const Color(0xFF5B8DEF)
                  : Colors.white,
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
            icon: ref.watch(hardwareDecodingProvider)
                ? Icons.memory
                : Icons.slow_motion_video,
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
    final effectiveProgress =
        _sliderSeekValue ?? _playerService.progress.clamp(0.0, 1.0);
    final effectivePosition = _isSeekingWithSlider
        ? Duration(
            milliseconds:
                (_playerService.duration.inMilliseconds * effectiveProgress)
                    .round(),
          )
        : _playerService.position;
    final currentTime = _formatDuration(effectivePosition);
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
                // 已缓冲区间：介于「已播放」蓝与「未加载」淡灰之间的半透明白。
                secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.5),
                thumbColor: const Color(0xFF5B8DEF),
                overlayColor: const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: effectiveProgress.clamp(0.0, 1.0),
                secondaryTrackValue:
                    _playerService.bufferedProgress.clamp(0.0, 1.0),
                onChangeStart: (_) {
                  setState(() {
                    _isSeekingWithSlider = true;
                    _sliderSeekValue = _playerService.progress.clamp(0.0, 1.0);
                  });
                },
                onChanged: (value) {
                  setState(() {
                    _isSeekingWithSlider = true;
                    _sliderSeekValue = value.clamp(0.0, 1.0);
                  });
                },
                onChangeEnd: (value) {
                  final position = Duration(
                    milliseconds: (value.clamp(0.0, 1.0) *
                            _playerService.duration.inMilliseconds)
                        .round(),
                  );
                  setState(() {
                    _isSeekingWithSlider = false;
                    _sliderSeekValue = null;
                  });
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
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
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
    final isPlayActionBlocked = _initializingPlayer ||
        !_playerService.isInitialized ||
        _playerService.hasError;

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
    final danmakuOn = ref.watch(danmakuEnabledProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '弹幕',
          child: PopupMenuButton<String>(
            tooltip: '',
            color: const Color(0xFF2C2C2E),
            icon: Icon(
              danmakuOn ? Icons.comment : Icons.comments_disabled_outlined,
              color: danmakuOn ? Colors.white : Colors.white60,
              size: 22,
            ),
            onSelected: (v) {
              switch (v) {
                case 'toggle':
                  ref.read(danmakuEnabledProvider.notifier).state = !danmakuOn;
                  break;
                case 'search':
                  _openDanmakuSearch();
                  break;
                case 'settings':
                  _openDanmakuSettings();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'toggle',
                child: Row(children: [
                  Icon(danmakuOn ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white70, size: 18),
                  const SizedBox(width: 10),
                  Text(danmakuOn ? '隐藏弹幕' : '显示弹幕',
                      style: const TextStyle(color: Colors.white)),
                ]),
              ),
              const PopupMenuItem(
                value: 'search',
                child: Row(children: [
                  Icon(Icons.search, color: Colors.white70, size: 18),
                  SizedBox(width: 10),
                  Text('搜索弹幕', style: TextStyle(color: Colors.white)),
                ]),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(children: [
                  Icon(Icons.tune, color: Colors.white70, size: 18),
                  SizedBox(width: 10),
                  Text('弹幕设置', style: TextStyle(color: Colors.white)),
                ]),
              ),
            ],
          ),
        ),
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
    showPlayerSettingsPanel(
      context: context,
      title: '跳过片头设置',
      width: 340,
      children: [
        const PanelSectionTitle('时间区间'),
        _SkipTimeField(
            label: '片头开始 (秒)', provider: skipOpeningStartProvider),
        const SizedBox(height: 4),
        _SkipTimeField(
            label: '片头结束 (秒)', provider: skipOpeningEndProvider),
        const PanelDivider(),
        Consumer(
          builder: (context, ref, _) => PanelSwitchRow(
            label: '自动跳过',
            subtitle: '到达片头区间自动跳过，而不是显示按钮',
            value: ref.watch(skipAutoModeProvider),
            onChanged: (value) =>
                ref.read(skipAutoModeProvider.notifier).state = value,
          ),
        ),
      ],
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
      AppToast.show(context, !current ? '已切换硬件解码' : '已切换软件解码',
          position: AppToastPosition.topCenter);
    }
  }

  // ========== 零拷贝解码（实验）切换 ==========

  void _toggleZeroCopyHwdec() async {
    final enable = !_playerService.zeroCopyHwdec;
    // 即时切换，不重载流（mpv 就地重建解码器，画面短暂一顿属正常）。
    await _playerService.setZeroCopyHwdec(enable);
    if (mounted) {
      AppToast.show(
        context,
        enable
            ? '已切到零拷贝解码(d3d11va)——若花屏/黑屏请再点一次关掉'
            : '已切到 auto-copy 拷回（兼容兜底）',
        position: AppToastPosition.topCenter,
      );
    }
  }
}

// ========== 辅助组件 ==========
