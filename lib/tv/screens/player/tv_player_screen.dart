import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/tv_toast.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/network/prefetch_proxy/prefetch_proxy.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/cache_service.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/utils/danmaku_filter.dart';
import '../../../core/utils/danmaku_local_parser.dart';
import '../../../core/utils/danmaku_matcher.dart';
import '../../../ui/widgets/common/danmaku_overlay.dart';
import '../../../core/services/player_subtitle_loader.dart';
import '../../../core/services/translation/streaming_subtitle_translator.dart';
import '../../../core/services/intro_skip_controller.dart';
import '../../../core/services/translation/translation_actions.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/font_service.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/sources/source_playback.dart';
import '../../../core/sources/source_registry.dart';
import '../../../core/utils/playback_error_text.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../../core/utils/track_preference.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../services/lan_remote.dart';
import '../../widgets/tv_player_osd.dart';
import '../../widgets/tv_panel.dart';

/// TV 播放页 —— 接入 VideoPlayerService 真实播放 + 遥控器控制 + 看完自动同步。
class TvPlayerScreen extends ConsumerStatefulWidget {
  final String? mediaId;
  final String? episodeId;

  /// 非空表示「网盘/聚合源直链播放」：复用本播放页全部能力播放网盘直链。
  final SourcePlayback? sourcePlay;

  const TvPlayerScreen(
      {super.key, this.mediaId, this.episodeId, this.sourcePlay});

  @override
  ConsumerState<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends ConsumerState<TvPlayerScreen> {
  final VideoPlayerService _service = VideoPlayerService();
  // 控制栏隐藏时把焦点收回这里，避免隐藏中的按钮误吃遥控器按键。
  final FocusNode _rootFocus = FocusNode(debugLabel: 'tvPlayerRoot');
  bool _ready = false;
  String? _error;
  MediaItem? _item;
  bool _showControls = true;
  Timer? _hideTimer;
  bool _didScrobble = false;
  bool _handledCompletion = false;
  MediaSource? _mediaSource;
  // OSD「选集」栏用：本剧当前季全集；「版本」栏用：本片多版本媒体源。
  List<Episode> _episodes = const [];
  List<MediaSource> _versions = const [];
  String? _selectedVersionId;
  StreamingSubtitleTranslator? _streamTranslator;
  late final IntroSkipController _introSkip;
  List<DanmakuMatchCandidate> _danmakuCandidates = [];
  String? _danmakuLoadedEpisodeId;
  StreamSubscription<LanRemoteCommand>? _remoteSub;

  String get _itemId => widget.episodeId ?? widget.mediaId ?? '';

  @override
  void initState() {
    super.initState();
    _introSkip = IntroSkipController(service: ref.read(introSkipServiceProvider));
    _service.addListener(_onTick);
    // 局域网扫码遥控：订阅命令总线，执行远程播放控制。
    _remoteSub = ref.read(lanRemoteBusProvider).stream.listen(_handleRemote);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _remoteSub?.cancel();
    // 清空遥控状态，Web 端显示「未在播放」。
    ref.read(lanRemoteStateProvider.notifier).state = null;
    _streamTranslator?.stop();
    _introSkip.dispose();
    _service.removeListener(_onTick);
    _rootFocus.dispose();
    unawaited(PrefetchProxy.instance.stop());
    _service.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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

  void _onTick() {
    if (!mounted) return;
    if (_ready && _service.isCompleted && !_handledCompletion) {
      _handledCompletion = true;
      _onPlaybackComplete();
    }
    _introSkip.onPosition(_service.position);
    _publishRemoteState();
    setState(() {});
  }

  /// 向 [lanRemoteStateProvider] 写入当前播放快照，供扫码遥控页读取。
  void _publishRemoteState() {
    final item = _item;
    final tracks = _service.tracksInfo;
    List<Map<String, dynamic>> mapTracks(Set<String> types, String? selId) =>
        tracks
            .where((t) => types.contains(t['type']?.toString()))
            .map((t) {
          final id = t['id']?.toString();
          return {'id': id, 'label': _trackLabel(t), 'selected': id == selId};
        }).toList();
    ref.read(lanRemoteStateProvider.notifier).state = LanRemoteState(
      hasItem: _ready && item != null,
      playing: _service.isPlaying,
      positionMs: _service.position.inMilliseconds,
      durationMs: _service.duration.inMilliseconds,
      title: item?.name ?? '',
      type: item?.type ?? '',
      seriesId: item?.seriesId,
      seasonId: item?.seasonId,
      audioTracks: mapTracks({'audio'}, _service.selectedAudioTrackId),
      subtitleTracks:
          mapTracks({'text', 'bitmap'}, _service.selectedSubtitleTrackId),
    );
  }

  /// 处理来自扫码遥控页的远程命令。
  void _handleRemote(LanRemoteCommand c) {
    if (!mounted) return;
    switch (c.action) {
      case 'toggle':
        _togglePlay();
        break;
      case 'play':
        _service.play();
        _revealControls();
        break;
      case 'pause':
        _service.pause();
        break;
      case 'seekRel':
        final s = (c.value is num)
            ? (c.value as num).toInt()
            : int.tryParse('${c.value}') ?? 0;
        _seek(s);
        break;
      case 'seekTo':
        final ms = (c.value is num) ? (c.value as num).toInt() : 0;
        _service.seekTo(Duration(milliseconds: ms));
        _revealControls();
        break;
      case 'next':
        unawaited(_goToAdjacentEpisode(1));
        break;
      case 'prev':
        unawaited(_goToAdjacentEpisode(-1));
        break;
      case 'playEpisode':
        final id = c.value?.toString();
        if (id != null && id.isNotEmpty) {
          context.replace('/tv/player?mediaId=$id');
        }
        break;
      case 'audio':
        final id = c.value?.toString();
        if (id != null) _service.selectAudioTrack(id);
        break;
      case 'subtitle':
        final id = c.value?.toString();
        if (id == null || id == 'off') {
          _service.deselectSubtitleTrack();
          ref.read(subtitleTrackProvider.notifier).state = null;
        } else {
          _service.selectSubtitleTrack(id);
        }
        break;
    }
    _publishRemoteState();
  }

  Future<void> _goToAdjacentEpisode(int delta) async {
    final item = _item;
    if (item == null || item.seriesId == null) return;
    try {
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
            item.seriesId!,
            seasonId: item.seasonId,
          );
      final idx = episodes.indexWhere((e) => e.id == item.id);
      final n = idx + delta;
      if (idx >= 0 && n >= 0 && n < episodes.length && mounted) {
        context.replace('/tv/player?mediaId=${episodes[n].id}');
      }
    } catch (_) {}
  }

  /// 点按「跳过片头/片尾」：片尾且开启自动连播则切下一集（无下一集回退 seek），
  /// 其余情况 seek 到段末。
  void _onIntroSkipPressed(SkipPrompt prompt) {
    if (prompt.kind == SkipKind.outro &&
        ref.read(autoPlayNextProvider) &&
        _item?.seriesId != null) {
      unawaited(_goNextEpisodeOrSeek(prompt.target));
    } else {
      _service.seekTo(prompt.target);
      _introSkip.onPosition(prompt.target);
    }
    _revealControls();
  }

  Future<void> _goNextEpisodeOrSeek(Duration fallback) async {
    final item = _item;
    if (item != null && item.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              item.seriesId!,
              seasonId: item.seasonId,
            );
        final idx = episodes.indexWhere((e) => e.id == item.id);
        if (idx >= 0 && idx < episodes.length - 1 && mounted) {
          context.replace('/tv/player?mediaId=${episodes[idx + 1].id}');
          return;
        }
      } catch (_) {}
    }
    _service.seekTo(fallback);
    _introSkip.onPosition(fallback);
  }

  /// 播放自然结束：开启「自动播放下一集」且为剧集时跳到下一集，否则退出。
  Future<void> _onPlaybackComplete() async {
    final item = _item;
    if (item != null &&
        item.type == 'Episode' &&
        item.seriesId != null &&
        ref.read(autoPlayNextProvider)) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              item.seriesId!,
              seasonId: item.seasonId,
            );
        final idx = episodes.indexWhere((e) => e.id == item.id);
        if (idx >= 0 && idx < episodes.length - 1 && mounted) {
          context.replace('/tv/player?mediaId=${episodes[idx + 1].id}');
          return;
        }
      } catch (_) {}
    }
    if (mounted) context.pop();
  }

  Future<void> _init({Duration? startPositionOverride}) async {
    // 网盘/聚合源直链：走专属初始化，复用本播放页 UI/内核。
    if (widget.sourcePlay != null) {
      await _initSourcePlayer(widget.sourcePlay!,
          startPosition: startPositionOverride);
      return;
    }
    if (_itemId.isEmpty) {
      setState(() => _error = '无效的媒体 ID');
      return;
    }
    try {
      // 清掉上一集残留弹幕，避免新页面起播瞬间闪现旧弹幕。
      ref.read(loadedDanmakuProvider.notifier).state = const [];
      final api = ref.read(apiClientProvider);
      final item = await api.media.getItemDetails(_itemId);
      final playbackInfo = await api.playback.getPlaybackInfo(_itemId);
      final selection = buildPlaybackSelection(
        playbackInfo: playbackInfo,
        itemId: _itemId,
        preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
        strmDirectPlay: ref.read(strmDirectPlayProvider),
        versionRegex: ref.read(preferredVersionRegexProvider),
        playSessionId: '$_itemId-${DateTime.now().microsecondsSinceEpoch}',
      );
      final videoUrl =
          buildStreamUrlFromRequest(api.playback, selection.primaryRequest);
      // STRM 直链：开启且解析出可用直链时优先用直链喂给内核。
      final directUrl = selection.directPlayUrl;
      final hasDirect = directUrl != null && directUrl.isNotEmpty;
      final onlineUrl = hasDirect ? directUrl : videoUrl;
      // 预取代理上游重签：短效签名的服务端直传流到期时重走 PlaybackInfo 拿新地址续拉。
      Future<String?> reResolveDirectStreamUrl() async {
        final pi = await api.playback.getPlaybackInfo(_itemId);
        final sel = buildPlaybackSelection(
          playbackInfo: pi,
          itemId: _itemId,
          preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
          strmDirectPlay: ref.read(strmDirectPlayProvider),
          versionRegex: ref.read(preferredVersionRegexProvider),
          playSessionId: '$_itemId-${DateTime.now().microsecondsSinceEpoch}',
        );
        return buildStreamUrlFromRequest(api.playback, sel.primaryRequest);
      }
      // 多线程加载：仅对 Emby 服务端直传流起本地缓存预取代理；直链/转码自动跳过。
      final proxiedUrl = hasDirect
          ? null
          : await _maybeStartPrefetch(onlineUrl,
              onExpired: reResolveDirectStreamUrl);
      final effectiveUrl = proxiedUrl ?? onlineUrl;
      final coreType =
          switch (normalizePlayerCore(ref.read(playerCoreProvider))) {
        'mpv' => PlayerCoreType.mpv,
        'nativeMpv' => PlayerCoreType.nativeMpv,
        _ => PlayerCoreType.exoPlayer,
      };
      // 内核相关开关，与移动端一致：
      // - ExoPlayer 的内封特效 ASS 字幕需要开启 libass（exoLibassProvider）后，
      //   由原生 libass 渲染成位图，经 bitmapNotifier 叠加到画面上。
      // - nativeMpv 的 libass 内置于 libmpv.so，始终生效；gpu-next 需 SurfaceView。
      final useLibass = coreType == PlayerCoreType.exoPlayer
          ? ref.read(exoLibassProvider)
          : false;
      // 杜比视界自动切换 gpu-next + 软解（默认开，可关）：DV 流 + mpv 系内核时强制
      // libplacebo 软解链路，避免硬解 mediacodec 丢 RPU 偏色。见 dolbyAutoGpuNextSwProvider。
      // 取最高分辨率视频流判定 DV，避免被排在前面的低清流误导。
      final videoStream = selection.mediaSource?.primaryVideoStream;
      final isMpvFamily = coreType == PlayerCoreType.mpv ||
          coreType == PlayerCoreType.nativeMpv;
      final autoDvMode = isMpvFamily &&
          ref.read(dolbyAutoGpuNextSwProvider) &&
          (videoStream?.isDolbyVision ?? false);
      final dolbyVisionFix = coreType == PlayerCoreType.mpv
          ? (autoDvMode || ref.read(mpvDolbyVisionFixProvider))
          : false;
      final hardwareDecoding =
          autoDvMode ? false : ref.read(hardwareDecodingProvider);
      final useGpuNext = autoDvMode || ref.read(gpuNextEnabledProvider);
      final preferredSubtitleLanguage =
          ref.read(preferredSubtitleLanguageProvider);
      final surfaceViewId = coreType == PlayerCoreType.nativeMpv
          ? DateTime.now().microsecondsSinceEpoch
          : null;
      // 续播：与桌面/移动端统一走 resolveResumeStartPosition——优先本地观看记录
      // （含跨服务器续播），回退服务器 userData。旧实现只读服务器 userData，会漏掉
      // 本地已记录但未同步到服务器的进度，导致 TV“经常续不上”。
      Duration? startPosition;
      if (startPositionOverride != null) {
        startPosition = startPositionOverride;
      } else {
        try {
          startPosition = await resolveResumeStartPosition(ref, api, item);
        } catch (_) {
          startPosition = null;
        }
      }

      await _service.initialize(
        videoUrl: effectiveUrl,
        fallbackVideoUrl: proxiedUrl != null ? onlineUrl : null,
        itemId: _itemId,
        mediaSourceId: selection.mediaSource?.id,
        playSessionId: selection.primaryRequest.playSessionId,
        coreType: coreType,
        startPosition: startPosition,
        dolbyVisionFix: dolbyVisionFix,
        useLibass: useLibass,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        surfaceViewId: surfaceViewId,
        useGpuNext: useGpuNext,
        onStart: (info) async {
          try {
            await api.playback.reportPlaybackStart(info);
          } catch (_) {}
          // Trakt scrobble/start：账号显示「正在观看」（续播时带上起播进度）。
          final runtime = item.runTimeTicks;
          final startTicks = (startPosition?.inMilliseconds ?? 0) * 10000;
          final startProgress = (runtime != null && runtime > 0)
              ? (startTicks / runtime * 100).clamp(0, 100).toDouble()
              : 0.0;
          unawaited(ref
              .read(syncControllerProvider.notifier)
              .scrobbleStart(item, progress: startProgress));
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
          await _maybeScrobble(info, item);
        },
      );

      _item = item;
      _mediaSource = selection.mediaSource;
      _versions = playbackInfo.mediaSources;
      _selectedVersionId = selection.mediaSource?.id;
      ref.read(currentPlayingItemProvider.notifier).state = item;
      // OSD「选集」栏：拉本剧当前季全集（仅剧集）。
      unawaited(_loadEpisodes(item));
      // 弹幕：起播自动并行匹配，命中最佳候选即加载（TV 输入不便，默认自动）。
      unawaited(_autoLoadDanmaku(item));
      // 自动跳过片头/片尾：联网识别本集片段（仅剧集，受设置开关控制）。
      unawaited(_introSkip.loadForItem(
        item,
        enabled: ref.read(autoSkipSegmentsProvider),
        fetchItem: (id) => api.media.getItemDetails(id),
      ));
      await _service.play();
      if (mounted) {
        setState(() => _ready = true);
        _scheduleHide();
      }
      await _loadSubtitles(preferredSubtitleLanguage, useLibass);
      await _applyPreferredAudio();
    } catch (e, st) {
      // 原始错误（可能含播放地址/api_key）只写日志供导出反馈，界面只显示安全文案。
      AppLogger().eWithStack('TvPlayer', '播放失败', e, st);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 网盘/聚合源直链播放初始化：复用 TV 播放页全部能力。
  Future<void> _initSourcePlayer(SourcePlayback sp,
      {Duration? startPosition}) async {
    final backend = mediaSourceBackendFor(sp.server.sourceKind);
    try {
      ref.read(loadedDanmakuProvider.notifier).state = const [];
      final qualityId = ref.read(sourceSelectedQualityProvider) ?? sp.qualityId;
      final play =
          await backend.resolvePlay(sp.server, sp.entry, qualityId: qualityId);
      final cfg = resolveSourcePlayerConfig(ref);
      final item = sp.toMediaItem();
      ref.read(sourcePlayQualitiesProvider.notifier).state = play.qualities;
      if (ref.read(sourceSelectedQualityProvider) == null) {
        ref.read(sourceSelectedQualityProvider.notifier).state =
            play.selectedQualityId;
      }
      await _service.initialize(
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
      _item = item;
      _mediaSource = null;
      ref.read(currentPlayingItemProvider.notifier).state = item;
      unawaited(_autoLoadDanmaku(item));
      await _service.play();
      if (mounted) {
        setState(() => _ready = true);
        _scheduleHide();
      }
      if (play.subtitles.isNotEmpty) {
        try {
          await _service.loadLibassSubtitle(play.subtitles.first.url);
        } catch (_) {}
      }
    } catch (e, st) {
      AppLogger().eWithStack('TvPlayer', '源播放失败', e, st);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 播放内切换清晰度：记当前进度，按新档重解析并续播。
  Future<void> _switchSourceQuality(String qualityId) async {
    final sp = widget.sourcePlay;
    if (sp == null) return;
    final pos = _service.position;
    ref.read(sourceSelectedQualityProvider.notifier).state = qualityId;
    await _initSourcePlayer(sp, startPosition: pos);
  }

  /// 播放停止 → 上报同步服务：Trakt 总是发 scrobble/stop（按进度自动判定看过/
  /// 续播点）；Bangumi 仅在进度达到统一观看阈值时标记「在看 + 单集看过」。
  Future<void> _maybeScrobble(PlaybackStopInfo info, MediaItem item) async {
    if (_didScrobble) return;
    _didScrobble = true;
    try {
      final runtime = item.runTimeTicks;
      if (runtime == null || runtime <= 0) return;
      final progress =
          (info.positionTicks / runtime * 100).clamp(0, 100).toDouble();
      final reachedThreshold = progress >= ref.read(watchedThresholdProvider);

      Map<String, String>? seriesProviderIds;
      if (reachedThreshold && item.type == 'Episode' && item.seriesId != null) {
        try {
          final series =
              await ref.read(apiClientProvider).media.getItemDetails(item.seriesId!);
          seriesProviderIds = series.providerIds;
        } catch (_) {}
      }
      await ref.read(syncControllerProvider.notifier).scrobbleStop(item,
          progress: progress,
          reachedThreshold: reachedThreshold,
          seriesProviderIds: seriesProviderIds);
    } catch (_) {}
  }

  // ============ 弹幕 ============

  Future<void> _autoLoadDanmaku(MediaItem item) async {
    try {
      final service = ref.read(danmakuServiceProvider);
      // 官方弹弹Play 是动漫专库：非动漫内容剔除，避免乱匹配（电视剧/电影只用自定义源）。
      final allowOfficial = await DanmakuMatcher.resolveIsAnime(
        item,
        fetchItem: (id) => ref.read(apiClientProvider).media.getItemDetails(id),
      );
      final candidates = await DanmakuMatcher.matchAll(service, item,
          allowOfficial: allowOfficial);
      if (!mounted) return;
      setState(() => _danmakuCandidates = candidates);
      // 阈值过滤：低可信度不自动上屏（用户仍可在弹幕面板手动挑）。
      if (candidates.isNotEmpty &&
          candidates.first.score >= 0.5 &&
          ref.read(danmakuEnabledProvider)) {
        final best = candidates.first;
        await _loadDanmakuFrom(best);
      }
    } catch (_) {}
  }

  Future<void> _loadDanmakuFrom(DanmakuMatchCandidate c) async {
    try {
      final service = ref.read(danmakuServiceProvider);
      var items = await service.getComments(c.episodeId, sourceId: c.sourceId);
      final blockwords = ref.read(danmakuBlockwordsProvider);
      if (blockwords.isNotEmpty) {
        final filter = DanmakuFilter()..importBlockwords(blockwords);
        items = items
            .where((it) => !filter.shouldFilter(it.text, userId: it.userId))
            .toList();
      }
      if (!mounted) return;
      ref.read(loadedDanmakuProvider.notifier).state = items;
      _danmakuLoadedEpisodeId = c.episodeId;
      if (items.isNotEmpty) {
        _toast('已加载 ${items.length} 条弹幕 · ${c.sourceName}');
      } else {
        _toast('该集没有弹幕');
      }
    } catch (_) {
      _toast('加载弹幕失败');
    }
  }

  /// 本地导入弹幕文件（.xml/.json/.ass）→ 解析 → 过滤屏蔽词 → 加载。
  Future<void> _importLocalDanmaku() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: DanmakuLocalParser.supportedExtensions,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      String content;
      if (f.bytes != null) {
        content = utf8.decode(f.bytes!, allowMalformed: true);
      } else if (f.path != null) {
        content = await File(f.path!).readAsString();
      } else {
        _toast('无法读取文件内容');
        return;
      }
      var items = DanmakuLocalParser.parse(f.name, content);
      final blockwords = ref.read(danmakuBlockwordsProvider);
      if (blockwords.isNotEmpty) {
        final filter = DanmakuFilter()..importBlockwords(blockwords);
        items = items
            .where((it) => !filter.shouldFilter(it.text, userId: it.userId))
            .toList();
      }
      if (!mounted) return;
      if (items.isEmpty) {
        _toast('该文件没有可用弹幕');
        return;
      }
      ref.read(loadedDanmakuProvider.notifier).state = items;
      if (!ref.read(danmakuEnabledProvider)) {
        ref.read(danmakuEnabledProvider.notifier).state = true;
      }
      _danmakuLoadedEpisodeId = null;
      _toast('已导入 ${items.length} 条本地弹幕 · ${f.name}');
    } on FormatException catch (e) {
      _toast('解析失败: ${e.message}');
    } catch (e) {
      _toast('导入失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 播放页统一顶部居中，避免遮挡底部进度条/控件。
    TvToast.show(context, msg, top: true);
  }

  Widget _buildDanmakuOverlay() {
    final enabled = ref.watch(danmakuEnabledProvider);
    final items = ref.watch(loadedDanmakuProvider);
    if (!enabled || items.isEmpty) return const SizedBox.shrink();
    final delay = ref.watch(danmakuDelayProvider);
    return Positioned.fill(
      child: IgnorePointer(
        child: DanmakuOverlay(
          items: items,
          position: _service.position -
              Duration(milliseconds: (delay * 1000).round()),
          isPlaying: _service.isPlaying,
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

  // ============ 字幕 / 音轨 ============

  /// 轨道信息在 initialize 后可能稍有延迟，轮询几次直到就绪。
  Future<List<Map<String, dynamic>>> _tracksOfType(Set<String> types) async {
    for (var i = 0; i < 8; i++) {
      final tracks = _service.tracksInfo
          .where((t) => types.contains(t['type']?.toString()))
          .toList();
      if (tracks.isNotEmpty) return tracks;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) break;
    }
    return _service.tracksInfo
        .where((t) => types.contains(t['type']?.toString()))
        .toList();
  }

  /// 按首选语言加载字幕：内封走轨道选择，外挂下载到本地再加载（公共加载器）。
  Future<void> _loadSubtitles(String? preferredLang, bool exoLibass) async {
    if (ref.read(subtitleTrackProvider) != null) return; // 尊重已有选择
    final source = _mediaSource;
    if (source == null) return;
    // 等内封轨道就绪，提升内封选中成功率。
    await _tracksOfType({'text', 'bitmap'});
    try {
      final index = await PlayerSubtitleLoader.loadPreferred(
        service: _service,
        api: ref.read(apiClientProvider),
        itemId: _itemId,
        mediaSource: source,
        preferredLanguage: preferredLang,
        exoLibassEnabled: exoLibass,
        authToken: ref.read(currentServerProvider)?.authToken,
        preferredRegex: ref.read(preferredSubtitleRegexProvider),
      );
      if (index != null && mounted) {
        ref.read(subtitleTrackProvider.notifier).state = index;
      }
    } catch (_) {}
  }

  /// 「音频选择」正则：用户未手动选轨时，按正则在播放器音频轨里自动挑选匹配项。
  /// TV 直接匹配播放器轨道的「标题/语言/编码」文本，避免 Emby 流序映射。
  Future<void> _applyPreferredAudio() async {
    if (ref.read(audioTrackProvider) != null) return; // 尊重已有选择
    final re = compilePreferenceRegex(ref.read(preferredAudioRegexProvider));
    if (re == null) return;
    final audios = await _tracksOfType({'audio'});
    if (audios.isEmpty || !mounted) return;
    for (final t in audios) {
      final text = [t['title'], t['language'], t['codec']]
          .where((e) => e != null && e.toString().isNotEmpty)
          .join(' ');
      if (re.hasMatch(text)) {
        final id = t['id']?.toString();
        if (id != null) await _service.selectAudioTrack(id);
        return;
      }
    }
  }

  String _trackLabel(Map<String, dynamic> t) {
    final title = t['title']?.toString();
    if (title != null && title.trim().isNotEmpty) return title;
    final lang = t['language']?.toString();
    if (lang != null && lang.trim().isNotEmpty) return lang;
    return '轨道 ${t['trackIndex'] ?? t['id'] ?? ''}';
  }

  /// 翻译字幕轨为中文并加载（TV）。
  Future<void> _translateSubtitle() async {
    final engine = ref.read(activeTranslationEngineProvider);
    final item = _item;
    final source = _mediaSource;
    if (engine == null) {
      _info('请先在「设置 → 翻译」中配置翻译引擎');
      return;
    }
    if (item == null || source == null) {
      _info('无播放信息');
      return;
    }
    final subtitles =
        source.mediaStreams.where((s) => s.isSubtitle).toList();
    if (subtitles.isEmpty) {
      _info('该片源无字幕轨可翻译');
      return;
    }
    final stream =
        subtitles.length == 1 ? subtitles.first : await _pickStreamToTranslate(subtitles);
    if (stream == null) return;

    final progress = ValueNotifier<String>('准备中…');
    if (!mounted) {
      progress.dispose();
      return;
    }
    final m = context.tv;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        content: Row(
          children: [
            SizedBox(
                width: m.s(22),
                height: m.s(22),
                child: const CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: m.s(16)),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v,
                    style:
                        const TextStyle(color: TvDesignTokens.textPrimary)),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final path = await TranslationActions.translateEmbyStream(
        api: ref.read(apiClientProvider),
        service: ref.read(subtitleTranslationServiceProvider),
        engine: engine,
        itemId: item.id,
        mediaSourceId: source.id,
        stream: stream,
        targetLang: ref.read(translationTargetLangProvider),
        layout: ref.read(bilingualLayoutProvider),
        authToken: ref.read(currentServerProvider)?.authToken,
        onProgress: (done, total, stage) {
          progress.value = total > 1 ? '$stage $done/$total' : stage;
        },
      );
      await _service.loadLibassSubtitle(path);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _info('翻译完成并已加载中文字幕');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      // 内封字幕拉取不到（服务端不支持单轨导出）→ 自动改为流式翻译（边播边译）。
      if (e.toString().contains('所有字幕地址均不可用')) {
        _startStreamingTranslate(engine, stream);
      } else if (mounted) {
        _info('翻译失败: $e');
      }
    } finally {
      progress.dispose();
    }
  }

  /// 内封字幕无法整轨下载时，启动流式翻译（叠加层按双语排版显示原文/译文）。
  void _startStreamingTranslate(TranslationEngine engine, MediaStream stream) {
    _streamTranslator?.stop();
    final translator = StreamingSubtitleTranslator(
      engine: engine,
      sourceLang:
          (stream.language?.isNotEmpty ?? false) ? stream.language! : 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
    );
    translator.errorMessage.addListener(() {
      final msg = translator.errorMessage.value;
      if (msg != null && mounted) _info('流式翻译引擎错误: $msg');
    });
    _streamTranslator = translator;
    translator.start(_service);
    if (mounted) setState(() {});
    _info('该字幕为内封、无法整轨下载，已改为流式翻译（边播边译）');
  }

  void _stopStreamingTranslate() {
    if (_streamTranslator == null) return;
    _streamTranslator?.stop();
    _streamTranslator = null;
    if (mounted) setState(() {});
  }

  Future<MediaStream?> _pickStreamToTranslate(List<MediaStream> subs) {
    return showDialog<MediaStream>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => TvPanel(
        title: '选择要翻译的字幕轨',
        onClose: () => Navigator.pop(ctx),
        children: [
          for (final s in subs)
            TvPanelOption(
              title: s.readableLabel(siblings: subs),
              subtitle: s.codec,
              onTap: () => Navigator.pop(ctx, s),
            ),
        ],
      ),
    );
  }

  void _info(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        content:
            Text(msg, style: const TextStyle(color: TvDesignTokens.textPrimary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  // ============ 控制 ============

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(TvDesignTokens.playerControlHideDelay, () {
      if (mounted && _service.isPlaying) {
        setState(() => _showControls = false);
        _rootFocus.requestFocus();
      }
    });
  }

  void _revealControls() {
    if (!_showControls) setState(() => _showControls = true);
    _scheduleHide();
  }

  /// 平板/Pad 触控：点击画面切换控制条显隐（遥控器仍用方向/确认键）。
  void _toggleControls() {
    if (_showControls) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
      _rootFocus.requestFocus();
    } else {
      _revealControls();
    }
  }

  Future<void> _togglePlay() async {
    if (_service.isPlaying) {
      await _service.pause();
      _hideTimer?.cancel();
      setState(() => _showControls = true);
    } else {
      await _service.play();
      _scheduleHide();
    }
  }

  void _seek(int seconds) {
    final target = _service.position + Duration(seconds: seconds);
    final dur = _service.duration;
    _service.seekTo(target < Duration.zero
        ? Duration.zero
        : (target > dur ? dur : target));
    _revealControls();
  }

  /// 收起 OSD（进度条栏再按 ↑ 或按返回时），焦点收回根节点。
  void _hideOsd() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _showControls = false);
    _rootFocus.requestFocus();
  }

  /// OSD「选集」栏数据：本剧当前季全集（仅剧集）。
  Future<void> _loadEpisodes(MediaItem item) async {
    if (item.seriesId == null) return;
    try {
      final eps = await ref
          .read(apiClientProvider)
          .media
          .getEpisodes(item.seriesId!, seasonId: item.seasonId);
      if (mounted) setState(() => _episodes = eps);
    } catch (_) {}
  }

  /// 「版本」栏切换多版本媒体源：记进度→按新版本重载播放器→续播。
  Future<void> _switchVersion(MediaSource v) async {
    if (v.id == _selectedVersionId) return;
    ref.read(selectedMediaSourceProvider.notifier).state = v.id;
    ref.read(audioTrackProvider.notifier).state = null;
    ref.read(subtitleTrackProvider.notifier).state = null;
    await _reinitAt(_service.position);
  }

  /// 「线路」栏切换服务器线路：换线路后媒体源可能变，重取 PlaybackInfo 重载→续播。
  Future<void> _switchLine(int index) async {
    final server = ref.read(currentServerProvider);
    if (server == null) return;
    ref.read(serverListProvider.notifier).setActiveLine(server.id, index);
    final updated =
        ref.read(serverListProvider).firstWhere((s) => s.id == server.id);
    ref.read(currentServerProvider.notifier).state = updated;
    ref.read(selectedMediaSourceProvider.notifier).state = null;
    ref.read(audioTrackProvider.notifier).state = null;
    ref.read(subtitleTrackProvider.notifier).state = null;
    await _reinitAt(_service.position);
  }

  /// 版本/线路切换共用：在当前进度处重跑初始化（复用网盘换清晰度的续播套路）。
  Future<void> _reinitAt(Duration pos) async {
    _stopStreamingTranslate();
    _didScrobble = false;
    _handledCompletion = false;
    _hideOsd();
    await _init(startPositionOverride: pos);
  }

  /// 遥控器根键位（在焦点链最外层）：控制栏隐藏时任意键先唤出；显示时把方向键
  /// 交给焦点遍历（中央/顶栏/底栏按钮）与进度条（左右快进退），确认键交给聚焦按钮。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final step = ref.read(skipForwardStepProvider);

    // 返回：控制栏显示中先收起，否则退出播放。
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_showControls && _service.isPlaying) {
        _hideTimer?.cancel();
        setState(() => _showControls = false);
        _rootFocus.requestFocus();
      } else {
        context.pop();
      }
      return KeyEventResult.handled;
    }

    // 媒体键始终可用（不依赖焦点位置）。
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      _revealControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seek(step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seek(-step);
      return KeyEventResult.handled;
    }

    // 控制栏隐藏：任意方向/确认键仅唤出控制栏，不触发按钮动作。
    if (!_showControls) {
      final wake = key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space;
      if (wake) {
        _revealControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 控制栏显示：重置隐藏计时，方向键交给焦点遍历/进度条，确认键交给聚焦按钮。
    _scheduleHide();
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final dur = _service.duration;
    final pos = _service.position;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready)
              Center(child: _service.buildVideo())
            else if (_error != null)
              _buildError(m)
            else
              const Center(
                child: AppLoadingIndicator(size: 48, color: TvDesignTokens.brand),
              ),
            // 弹幕层（视频之上、触控/控制条之下；鼠标/遥控穿透）。
            if (_ready) _buildDanmakuOverlay(),
            // 触控层（位于视频之上、控制条之下）：控制条隐藏时点击画面唤出，
            // 显示时点击空白处隐藏；控制条上的按钮在更上层会优先捕获各自的点击。
            if (_ready)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                ),
              ),
            // 流式翻译叠加层（按双语排版显示原文/译文，位于控制条之下）。
            if (_streamTranslator != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: m.s(96),
                child: IgnorePointer(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _streamTranslator!.displayText,
                    builder: (context, text, _) {
                      if (text.isEmpty) return const SizedBox.shrink();
                      return Center(
                        child: Container(
                          margin: EdgeInsets.symmetric(horizontal: m.s(48)),
                          padding: EdgeInsets.symmetric(
                              horizontal: m.s(16), vertical: m.s(6)),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(m.s(8)),
                          ),
                          child: Text(
                            text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: m.fs(28),
                              fontWeight: FontWeight.w600,
                              shadows: const [
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
            // 自动跳过片头/片尾按钮：OSD 未开时出现在左下、自动获焦，确认即跳；
            // 打开 OSD 后让位给底栏导航（隐藏）。
            if (_ready && !_showControls)
              Positioned(
                left: m.s(48),
                bottom: m.s(120),
                child: ValueListenableBuilder<SkipPrompt?>(
                  valueListenable: _introSkip.prompt,
                  builder: (context, prompt, _) {
                    if (prompt == null) return const SizedBox.shrink();
                    return ElevatedButton.icon(
                      autofocus: true,
                      onPressed: () => _onIntroSkipPressed(prompt),
                      icon: Icon(Icons.skip_next, size: m.s(24)),
                      label: Text(prompt.label,
                          style: TextStyle(fontSize: m.fs(20))),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.7),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                            horizontal: m.s(24), vertical: m.s(14)),
                      ),
                    );
                  },
                ),
              ),
            // 常驻进度条（设置项开启且 OSD 未开时）：底部一条加粗进度条做参考。
            if (_ready &&
                !_showControls &&
                ref.watch(tvPinnedProgressBarProvider))
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildPinnedProgress(m, pos, dur),
              ),
            // 流媒体式单栏轮播 OSD（顶栏标题+时钟 / 底栏进度·选集·字幕·音频·弹幕·倍速·版本·线路）。
            if (_ready)
              Positioned.fill(
                child: TvPlayerOsd(
                  visible: _showControls,
                  service: _service,
                  item: _item,
                  position: pos,
                  duration: dur,
                  isPlaying: _service.isPlaying,
                  episodes: _episodes,
                  versions: _versions,
                  selectedVersionId: _selectedVersionId,
                  sourceQualities: widget.sourcePlay != null
                      ? ref.watch(sourcePlayQualitiesProvider)
                      : const [],
                  selectedQualityId: ref.watch(sourceSelectedQualityProvider),
                  isSourcePlay: widget.sourcePlay != null,
                  danmakuCandidates: _danmakuCandidates,
                  loadedDanmakuEpisodeId: _danmakuLoadedEpisodeId,
                  onActivity: _scheduleHide,
                  onRequestHide: _hideOsd,
                  onSeekForward: () =>
                      _seek(ref.read(skipForwardStepProvider)),
                  onSeekBackward: () =>
                      _seek(-ref.read(skipForwardStepProvider)),
                  onTogglePlay: _togglePlay,
                  onSelectVersion: _switchVersion,
                  onSelectQuality: _switchSourceQuality,
                  onSelectLine: _switchLine,
                  onLoadDanmaku: (c) => unawaited(_loadDanmakuFrom(c)),
                  onImportLocalDanmaku: () => unawaited(_importLocalDanmaku()),
                  onTranslateSubtitle: _translateSubtitle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 常驻底部进度条（设置项）：加粗、只读，OSD 未开时提供进度参考。
  Widget _buildPinnedProgress(TvMetrics m, Duration pos, Duration dur) {
    final p =
        dur.inMilliseconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 0.0;
    String fmt(Duration d) {
      final h = d.inHours;
      final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
    }

    final style = TextStyle(
        color: Colors.white,
        fontSize: m.fontSizeSm,
        fontFeatures: const [FontFeature.tabularFigures()]);
    return IgnorePointer(
      child: Container(
        padding: EdgeInsets.fromLTRB(
            m.spacingXl, m.spacingXl, m.spacingXl, m.spacingLg),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xB3000000)],
          ),
        ),
        child: Row(
          children: [
            Text(fmt(pos), style: style),
            SizedBox(width: m.spacingLg),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(m.s(6)),
                child: Stack(
                  children: [
                    // 已缓冲区间（半透明白）垫底。
                    LinearProgressIndicator(
                      value: _service.bufferedProgress.clamp(0.0, 1.0),
                      minHeight: m.s(12),
                      backgroundColor: Colors.white.withValues(alpha: 0.28),
                      valueColor: AlwaysStoppedAnimation(
                          Colors.white.withValues(alpha: 0.5)),
                    ),
                    // 已播放（品牌蓝）盖在上层，背景透明露出缓冲层。
                    LinearProgressIndicator(
                      value: p.clamp(0.0, 1.0),
                      minHeight: m.s(12),
                      backgroundColor: Colors.transparent,
                      valueColor:
                          const AlwaysStoppedAnimation(TvDesignTokens.brand),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: m.spacingLg),
            Text(fmt(dur), style: style),
          ],
        ),
      ),
    );
  }

  Widget _buildError(TvMetrics m) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.s(640)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                color: TvDesignTokens.error, size: m.s(64)),
            SizedBox(height: m.spacingLg),
            Text(
              friendlyPlaybackError(_error),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: m.spacingMd),
            Text(
              kPlaybackErrorFeedbackHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.textSecondary,
                height: 1.6,
              ),
            ),
            SizedBox(height: m.spacingXs),
            Text(
              kFeedbackChannelUrl,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.brand,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
