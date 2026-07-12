import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_interfaces.dart';
import '../../core/providers/appearance_providers.dart';
import '../../core/providers/media_providers.dart';
import '../../core/providers/playback_providers.dart';
import '../../core/providers/server_providers.dart';
import '../../core/services/video_player_service.dart';
import '../../core/sources/media_source_backend.dart';
import '../../core/utils/danmaku_matcher.dart';
import '../../ui/widgets/common/media_widgets.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';

/// 播放页底栏轮播的一条底栏。
enum _Bar { progress, episodes, subtitle, audio, danmaku, speed, version, line }

/// 单个可选卡片的模型：怎么画（含焦点态） + 选中回调 + 是否当前生效。
class _Opt {
  final Widget Function(bool focused) build;
  final VoidCallback onActivate;
  final bool current;
  _Opt({required this.build, required this.onActivate, this.current = false});
}

/// TV 播放页 OSD —— 流媒体式「单栏轮播」控制系统。
///
/// 交互：↓ 从视频唤出进度条栏；继续 ↓ 逐栏下滑切换（进入），↑ 逐栏返回，回到进度条栏
/// 再 ↑ 收起。栏内 ←→ 在卡片间移动、OK 选中；进度条栏 ←→ 快退/快进、OK 播放暂停。
/// 采用「手动焦点」模型（单个 FocusNode + 自绘高亮），避开方向遍历在网格里的抖动。
class TvPlayerOsd extends ConsumerStatefulWidget {
  final bool visible;
  final VideoPlayerService service;
  final MediaItem? item;
  final Duration position;
  final Duration duration;
  final bool isPlaying;

  final List<Episode> episodes;
  final List<MediaSource> versions;
  final String? selectedVersionId;
  final List<PlayQuality> sourceQualities;
  final String? selectedQualityId;
  final bool isSourcePlay;
  final List<DanmakuMatchCandidate> danmakuCandidates;
  final String? loadedDanmakuEpisodeId;

  final VoidCallback onActivity;
  final VoidCallback onRequestHide;
  final VoidCallback onSeekForward;
  final VoidCallback onSeekBackward;
  final VoidCallback onTogglePlay;
  final void Function(MediaSource version) onSelectVersion;
  final void Function(String qualityId) onSelectQuality;
  final void Function(int lineIndex) onSelectLine;
  final void Function(DanmakuMatchCandidate) onLoadDanmaku;
  final VoidCallback onImportLocalDanmaku;
  final VoidCallback onTranslateSubtitle;

  const TvPlayerOsd({
    super.key,
    required this.visible,
    required this.service,
    required this.item,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.episodes,
    required this.versions,
    required this.selectedVersionId,
    required this.sourceQualities,
    required this.selectedQualityId,
    required this.isSourcePlay,
    required this.danmakuCandidates,
    required this.loadedDanmakuEpisodeId,
    required this.onActivity,
    required this.onRequestHide,
    required this.onSeekForward,
    required this.onSeekBackward,
    required this.onTogglePlay,
    required this.onSelectVersion,
    required this.onSelectQuality,
    required this.onSelectLine,
    required this.onLoadDanmaku,
    required this.onImportLocalDanmaku,
    required this.onTranslateSubtitle,
  });

  @override
  ConsumerState<TvPlayerOsd> createState() => _TvPlayerOsdState();
}

class _TvPlayerOsdState extends ConsumerState<TvPlayerOsd> {
  final FocusNode _focus = FocusNode(debugLabel: 'tvOsd');
  final ScrollController _scroll = ScrollController();
  int _bar = 0; // index into _activeBars
  int _sel = 0; // selected card index within current bar
  bool _enterDir = true; // 上次切换方向：true=↓进入 false=↑返回
  List<GlobalKey> _keys = const [];

  @override
  void initState() {
    super.initState();
    if (widget.visible) _focusSoon();
  }

  @override
  void didUpdateWidget(covariant TvPlayerOsd old) {
    super.didUpdateWidget(old);
    if (!old.visible && widget.visible) {
      _bar = 0;
      _sel = 0;
      _focusSoon();
    }
  }

  void _focusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.visible) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // 当前适用的底栏（按约定栏序，只保留有内容的）。
  List<_Bar> get _activeBars {
    final l = <_Bar>[_Bar.progress];
    if (!widget.isSourcePlay && widget.episodes.length > 1) l.add(_Bar.episodes);
    l.add(_Bar.subtitle);
    l.add(_Bar.audio);
    l.add(_Bar.danmaku);
    l.add(_Bar.speed);
    final hasVersion = widget.isSourcePlay
        ? widget.sourceQualities.length > 1
        : widget.versions.length > 1;
    if (hasVersion) l.add(_Bar.version);
    if (!widget.isSourcePlay) {
      final lines = ref.read(currentServerProvider)?.lines ?? const [];
      if (lines.length > 1) l.add(_Bar.line);
    }
    return l;
  }

  // ---------------------------------------------------------------- 键位
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    widget.onActivity();
    final k = event.logicalKey;
    final bars = _activeBars;
    final bar = bars[_bar.clamp(0, bars.length - 1)];

    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      widget.onRequestHide();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (_bar < bars.length - 1) _goBar(_bar + 1, true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_bar > 0) {
        _goBar(_bar - 1, false);
      } else {
        widget.onRequestHide();
      }
      return KeyEventResult.handled;
    }

    if (bar == _Bar.progress) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        widget.onSeekBackward();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        widget.onSeekForward();
        return KeyEventResult.handled;
      }
      if (_isSelect(k)) {
        widget.onTogglePlay();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 卡片栏：←→ 移动选中，OK 激活。
    final opts = _optionsFor(bar);
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (_sel > 0) setState(() => _sel--);
      _scrollToSel();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (_sel < opts.length - 1) setState(() => _sel++);
      _scrollToSel();
      return KeyEventResult.handled;
    }
    if (_isSelect(k)) {
      if (_sel >= 0 && _sel < opts.length) opts[_sel].onActivate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _isSelect(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.space;

  void _goBar(int next, bool enterDir) {
    final bars = _activeBars;
    final bar = bars[next.clamp(0, bars.length - 1)];
    final opts = bar == _Bar.progress ? const <_Opt>[] : _optionsFor(bar);
    var sel = opts.indexWhere((o) => o.current);
    if (sel < 0) sel = 0;
    setState(() {
      _bar = next;
      _enterDir = enterDir;
      _sel = sel;
    });
    _scrollToSel();
  }

  void _scrollToSel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sel < 0 || _sel >= _keys.length) return;
      final ctx = _keys[_sel].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut);
      }
    });
  }

  // ---------------------------------------------------------------- 选项模型
  List<_Opt> _optionsFor(_Bar bar) {
    switch (bar) {
      case _Bar.progress:
        return const [];
      case _Bar.episodes:
        return _episodeOpts();
      case _Bar.subtitle:
        return _subtitleOpts();
      case _Bar.audio:
        return _audioOpts();
      case _Bar.danmaku:
        return _danmakuOpts();
      case _Bar.speed:
        return _speedOpts();
      case _Bar.version:
        return _versionOpts();
      case _Bar.line:
        return _lineOpts();
    }
  }

  String _trackLabel(Map<String, dynamic> t) {
    final title = t['title']?.toString();
    if (title != null && title.trim().isNotEmpty) return title;
    final lang = t['language']?.toString();
    if (lang != null && lang.trim().isNotEmpty) return lang;
    return '轨道 ${t['trackIndex'] ?? t['id'] ?? ''}';
  }

  List<_Opt> _episodeOpts() {
    final useThumb = ref.watch(tvEpisodeCardThumbnailProvider);
    final api = ref.read(apiClientProvider);
    return widget.episodes.map((ep) {
      final playing = ep.id == widget.item?.id;
      return _Opt(
        current: playing,
        onActivate: () {
          if (!playing) context.replace('/tv/player?mediaId=${ep.id}');
        },
        build: (focused) => _EpisodeCard(
          imageUrl: useThumb ? _episodeImageUrl(api, ep) : null,
          index: ep.indexNumber,
          title: ep.name,
          watched: ep.userData?.played ?? false,
          progress: _epProgress(ep),
          nowPlaying: playing,
          focused: focused,
          numberOnly: !useThumb,
        ),
      );
    }).toList();
  }

  double? _epProgress(Episode ep) {
    final ticks = ep.userData?.playbackPositionTicks ?? 0.0;
    final total = ep.runTimeTicks ?? 0;
    if (ticks > 0 && total > 0) return (ticks / total).clamp(0.0, 1.0);
    return null;
  }

  String? _episodeImageUrl(ApiClientFactory api, Episode ep) {
    if (ep.primaryImageTag != null) {
      return api.image
          .getPrimaryImageUrl(ep.id, tag: ep.primaryImageTag, maxWidth: 400);
    }
    if (ep.thumbImageTag != null) {
      return api.image
          .getThumbImageUrl(ep.id, tag: ep.thumbImageTag, maxWidth: 400);
    }
    return null;
  }

  List<_Opt> _subtitleOpts() {
    final subs = widget.service.tracksInfo
        .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
        .toList();
    final current = widget.service.selectedSubtitleTrackId;
    final opts = <_Opt>[
      _Opt(
        current: current == null,
        onActivate: () {
          widget.service.deselectSubtitleTrack();
          ref.read(subtitleTrackProvider.notifier).state = null;
          setState(() {});
        },
        build: (f) => _TextCard(title: '关闭', focused: f, current: current == null),
      ),
    ];
    for (final t in subs) {
      final id = t['id']?.toString();
      final sel = id != null && id == current;
      opts.add(_Opt(
        current: sel,
        onActivate: () {
          if (id != null) widget.service.selectSubtitleTrack(id);
          setState(() {});
        },
        build: (f) => _TextCard(
          title: _trackLabel(t),
          sub: (t['type'] == 'bitmap') ? '图形字幕' : t['codec']?.toString(),
          focused: f,
          current: sel,
        ),
      ));
    }
    opts.add(_Opt(
      onActivate: widget.onTranslateSubtitle,
      build: (f) =>
          _TextCard(title: '翻译成中文', sub: '调用翻译引擎', focused: f, current: false),
    ));
    return opts;
  }

  List<_Opt> _audioOpts() {
    final audios =
        widget.service.tracksInfo.where((t) => t['type'] == 'audio').toList();
    final current = widget.service.selectedAudioTrackId;
    if (audios.isEmpty) {
      return [
        _Opt(
            onActivate: () {},
            build: (f) => _TextCard(title: '无可用音轨', focused: f, current: false))
      ];
    }
    return audios.map((t) {
      final id = t['id']?.toString();
      final sel = id != null && id == current;
      return _Opt(
        current: sel,
        onActivate: () {
          if (id != null) widget.service.selectAudioTrack(id);
          setState(() {});
        },
        build: (f) => _TextCard(
          title: _trackLabel(t),
          sub: t['codec']?.toString(),
          focused: f,
          current: sel,
        ),
      );
    }).toList();
  }

  List<_Opt> _danmakuOpts() {
    final enabled = ref.watch(danmakuEnabledProvider);
    final opts = <_Opt>[
      _Opt(
        current: enabled,
        onActivate: () {
          ref.read(danmakuEnabledProvider.notifier).state = !enabled;
          setState(() {});
        },
        build: (f) => _ToggleCard(on: enabled, focused: f),
      ),
    ];
    for (final c in widget.danmakuCandidates.take(12)) {
      final sel = widget.loadedDanmakuEpisodeId == c.episodeId;
      opts.add(_Opt(
        current: sel,
        onActivate: () => widget.onLoadDanmaku(c),
        build: (f) => _TextCard(
          title: c.animeTitle,
          sub: '${c.sourceName} · ${c.episodeTitle}',
          focused: f,
          current: sel,
        ),
      ));
    }
    opts.add(_Opt(
      onActivate: widget.onImportLocalDanmaku,
      build: (f) =>
          _TextCard(title: '本地导入', sub: '.xml / .ass', focused: f, current: false),
    ));
    return opts;
  }

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  List<_Opt> _speedOpts() {
    final cur = widget.service.speed;
    return _speeds.map((s) {
      final sel = (s - cur).abs() < 0.01;
      return _Opt(
        current: sel,
        onActivate: () {
          widget.service.setSpeed(s);
          setState(() {});
        },
        build: (f) => _TextCard(
            title: '${_fmtSpeed(s)}×', focused: f, current: sel, pill: true),
      );
    }).toList();
  }

  String _fmtSpeed(double s) =>
      s.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  List<_Opt> _versionOpts() {
    if (widget.isSourcePlay) {
      return widget.sourceQualities.map((q) {
        final sel = q.id == widget.selectedQualityId;
        return _Opt(
          current: sel,
          onActivate: () => widget.onSelectQuality(q.id),
          build: (f) => _TextCard(title: q.label, focused: f, current: sel),
        );
      }).toList();
    }
    return widget.versions.map((v) {
      final sel = v.id == widget.selectedVersionId;
      return _Opt(
        current: sel,
        onActivate: () => widget.onSelectVersion(v),
        build: (f) => _TextCard(
          title: _versionTitle(v),
          sub: _versionSummary(v),
          focused: f,
          current: sel,
        ),
      );
    }).toList();
  }

  String _versionTitle(MediaSource v) {
    final name = v.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    final label = v.qualityLabel;
    return label.isNotEmpty ? label : '默认版本';
  }

  String? _versionSummary(MediaSource v) {
    final parts = <String>[];
    final res = v.primaryVideoStream?.resolution ?? '';
    if (res.isNotEmpty) parts.add(res);
    final fmt = v.primaryVideoStream?.videoFormatLabel ?? '';
    if (fmt.isNotEmpty) parts.add(fmt);
    final size = v.size;
    if (size != null && size > 0) {
      const gb = 1024 * 1024 * 1024;
      parts.add(size >= gb
          ? '${(size / gb).toStringAsFixed(1)} GB'
          : '${(size / (1024 * 1024)).toStringAsFixed(0)} MB');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  List<_Opt> _lineOpts() {
    final server = ref.watch(currentServerProvider);
    final lines = server?.lines ?? const [];
    final active = server?.activeLineIndex ?? 0;
    return lines.asMap().entries.map((e) {
      final sel = e.key == active;
      return _Opt(
        current: sel,
        onActivate: () => widget.onSelectLine(e.key),
        build: (f) => _TextCard(title: e.value.name, focused: f, current: sel),
      );
    }).toList();
  }

  // ---------------------------------------------------------------- 画面
  static const _barName = {
    _Bar.progress: '进度',
    _Bar.episodes: '选集',
    _Bar.subtitle: '字幕',
    _Bar.audio: '音频',
    _Bar.danmaku: '弹幕',
    _Bar.speed: '倍速',
    _Bar.version: '版本',
    _Bar.line: '线路',
  };
  static const _barHint = {
    _Bar.progress: '←→ 快退/快进　OK 播放·暂停',
    _Bar.episodes: '←→ 选集　OK 播放',
    _Bar.subtitle: '←→ 选择　OK 切换',
    _Bar.audio: '←→ 选择　OK 切换',
    _Bar.danmaku: '←→ 选择　OK 开关/切源',
    _Bar.speed: '←→ 选择　OK 应用',
    _Bar.version: '←→ 选择　OK 切换（会重载）',
    _Bar.line: '←→ 选择　OK 切换（会重载）',
  };

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _scrim(),
              Positioned(top: 0, left: 0, right: 0, child: _topBar(m)),
              Positioned(left: 0, right: 0, bottom: 0, child: _bottom(m)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scrim() => const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xB8050810),
                Color(0x00050810),
                Color(0x00050810),
                Color(0xE6050810),
              ],
              stops: [0.0, 0.24, 0.62, 1.0],
            ),
          ),
        ),
      );

  Widget _topBar(TvMetrics m) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          m.spacingXl, m.spacingLg, m.spacingXl, m.spacingLg),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.item?.name ?? '正在播放',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: m.fontSizeLg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(width: m.spacingLg),
          const _TvClock(),
        ],
      ),
    );
  }

  Widget _bottom(TvMetrics m) {
    final bars = _activeBars;
    final idx = _bar.clamp(0, bars.length - 1);
    final bar = bars[idx];
    return Padding(
      padding: EdgeInsets.fromLTRB(
          m.spacingXl, m.spacingXxl, m.spacingXl, m.spacingXl),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) {
          final begin =
              _enterDir ? const Offset(0, -0.4) : const Offset(0, 0.4);
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(begin: begin, end: Offset.zero).animate(anim),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey(bar),
          child: _barBody(m, bar, bars.length, idx),
        ),
      ),
    );
  }

  Widget _barBody(TvMetrics m, _Bar bar, int total, int idx) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_barName[bar]!,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: m.fontSizeMd,
                    fontWeight: FontWeight.w700)),
            SizedBox(width: m.spacingMd),
            Text(_barHint[bar]!,
                style: TextStyle(
                    color: TvDesignTokens.textSecondary, fontSize: m.fontSizeXs)),
            const Spacer(),
            _dots(m, total, idx),
          ],
        ),
        SizedBox(height: m.spacingMd),
        bar == _Bar.progress ? _progress(m) : _rail(m, bar),
      ],
    );
  }

  Widget _dots(TvMetrics m, int total, int idx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final on = i == idx;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.symmetric(horizontal: m.s(3)),
          width: on ? m.s(18) : m.s(6),
          height: m.s(6),
          decoration: BoxDecoration(
            color: on ? TvDesignTokens.brand : Colors.white.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(m.s(3)),
          ),
        );
      }),
    );
  }

  Widget _rail(TvMetrics m, _Bar bar) {
    final opts = _optionsFor(bar);
    if (_keys.length != opts.length) {
      _keys = List.generate(opts.length, (_) => GlobalKey());
    }
    return SizedBox(
      height: bar == _Bar.episodes
          ? m.s(196)
          : (bar == _Bar.speed ? m.s(64) : m.s(76)),
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < opts.length; i++)
              Padding(
                key: _keys[i],
                padding: EdgeInsets.only(right: m.spacingMd),
                child: opts[i].build(_sel == i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _progress(TvMetrics m) {
    final dur = widget.duration.inMilliseconds;
    final p = dur > 0 ? widget.position.inMilliseconds / dur : 0.0;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: m.spacingMd),
      child: Row(
        children: [
          Text(_fmt(widget.position),
              style: TextStyle(
                  color: Colors.white,
                  fontSize: m.fontSizeSm,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          SizedBox(width: m.spacingLg),
          Expanded(
              child: _TvSeekTrack(
                  progress: p.clamp(0.0, 1.0),
                  buffered: widget.service.bufferedProgress.clamp(0.0, 1.0),
                  height: m.s(6))),
          SizedBox(width: m.spacingLg),
          Text(_fmt(widget.duration),
              style: TextStyle(
                  color: Colors.white,
                  fontSize: m.fontSizeSm,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
  }
}

/// 顶栏系统时钟（时:分:秒），自带 1s 定时器，暂停也走字。
class _TvClock extends StatefulWidget {
  const _TvClock();
  @override
  State<_TvClock> createState() => _TvClockState();
}

class _TvClockState extends State<_TvClock> {
  late String _now = _fmt();
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = _fmt());
    });
  }

  String _fmt() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Text(_now,
        style: TextStyle(
            color: const Color(0xFFE7EDF7),
            fontSize: m.fontSizeLg,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// 进度条轨道（自绘，只读；键位在 OSD 层处理 ←→ 快退/快进）。
class _TvSeekTrack extends StatelessWidget {
  final double progress;
  final double buffered;
  final double height;
  const _TvSeekTrack(
      {required this.progress, required this.buffered, required this.height});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final thumb = height * 2.6;
      return SizedBox(
        height: thumb,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              height: height,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(height),
              ),
            ),
            // 已缓冲区间（半透明白），叠在底轨之上、已播放之下，区分「缓存到哪」。
            FractionallySizedBox(
              widthFactor: buffered,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
            ),
            FractionallySizedBox(
              widthFactor: progress,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: TvDesignTokens.brand,
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
            ),
            Positioned(
              left: (c.maxWidth * progress - thumb / 2)
                  .clamp(0.0, c.maxWidth - thumb),
              child: Container(
                width: thumb,
                height: thumb,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 6)],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// 通用文字卡（字幕/音频/弹幕源/版本/线路/倍速）。三态：普通 / 选中(蓝描边+✓) / 焦点(蓝底放大)。
class _TextCard extends StatelessWidget {
  final String title;
  final String? sub;
  final bool focused;
  final bool current;
  final bool pill;
  const _TextCard({
    required this.title,
    required this.focused,
    required this.current,
    this.sub,
    this.pill = false,
  });

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final bg = focused
        ? TvDesignTokens.brand
        : (current
            ? TvDesignTokens.brand.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.065));
    final border = focused || current
        ? TvDesignTokens.brand
        : Colors.white.withValues(alpha: 0.13);
    final titleColor = focused
        ? Colors.white
        : (current ? const Color(0xFFCADCFF) : TvDesignTokens.textPrimary);
    return AnimatedScale(
      scale: focused ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: Container(
        constraints: BoxConstraints(minWidth: pill ? m.s(76) : m.s(118)),
        padding: EdgeInsets.symmetric(
            horizontal: pill ? m.s(18) : m.s(20),
            vertical: pill ? m.s(14) : m.s(13)),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(m.s(14)),
          border: Border.all(color: border, width: focused ? m.s(1.5) : 1),
          boxShadow: focused
              ? [
                  BoxShadow(
                      color: TvDesignTokens.brand.withValues(alpha: 0.55),
                      blurRadius: m.s(20),
                      offset: Offset(0, m.s(6)))
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              pill ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        color: titleColor,
                        fontSize: pill ? m.fontSizeMd : m.fontSizeMd,
                        fontWeight: FontWeight.w600)),
                if (current && !focused) ...[
                  SizedBox(width: m.s(8)),
                  Icon(Icons.check, color: TvDesignTokens.brand, size: m.s(18)),
                ],
              ],
            ),
            if (sub != null && sub!.isNotEmpty) ...[
              SizedBox(height: m.s(3)),
              Text(sub!,
                  style: TextStyle(
                      color: focused
                          ? Colors.white.withValues(alpha: 0.9)
                          : TvDesignTokens.textSecondary,
                      fontSize: m.fontSizeXs)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 弹幕开关卡：圆点 + 开/关。
class _ToggleCard extends StatelessWidget {
  final bool on;
  final bool focused;
  const _ToggleCard({required this.on, required this.focused});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return AnimatedScale(
      scale: focused ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: m.s(20), vertical: m.s(13)),
        decoration: BoxDecoration(
          color: focused
              ? TvDesignTokens.brand
              : (on
                  ? TvDesignTokens.brand.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.065)),
          borderRadius: BorderRadius.circular(m.s(14)),
          border: Border.all(
              color: focused || on
                  ? TvDesignTokens.brand
                  : Colors.white.withValues(alpha: 0.13),
              width: focused ? m.s(1.5) : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: m.s(9),
              height: m.s(9),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? TvDesignTokens.brand : const Color(0xFF5A6577),
              ),
            ),
            SizedBox(width: m.s(9)),
            Text(on ? '弹幕开' : '弹幕关',
                style: TextStyle(
                    color: focused ? Colors.white : TvDesignTokens.textPrimary,
                    fontSize: m.fontSizeMd,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// 选集卡：缩略图（含 E 号/看过✓/进度/正在播放）或纯集数卡。
class _EpisodeCard extends StatelessWidget {
  final String? imageUrl;
  final int? index;
  final String title;
  final bool watched;
  final double? progress;
  final bool nowPlaying;
  final bool focused;
  final bool numberOnly;
  const _EpisodeCard({
    required this.imageUrl,
    required this.index,
    required this.title,
    required this.watched,
    required this.progress,
    required this.nowPlaying,
    required this.focused,
    required this.numberOnly,
  });

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final ringColor =
        focused || nowPlaying ? TvDesignTokens.brand : Colors.transparent;
    final num = index?.toString().padLeft(2, '0') ?? '';

    Widget thumb;
    if (numberOnly) {
      thumb = Container(
        width: m.s(120),
        height: m.s(120),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused
              ? TvDesignTokens.brand
              : (nowPlaying
                  ? TvDesignTokens.brand.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.065)),
          borderRadius: BorderRadius.circular(m.s(14)),
          border: Border.all(
              color: focused || nowPlaying
                  ? TvDesignTokens.brand
                  : Colors.white.withValues(alpha: 0.13),
              width: focused ? m.s(1.5) : 1),
        ),
        child: Text(num,
            style: TextStyle(
                color: focused ? Colors.white : TvDesignTokens.textPrimary,
                fontSize: m.fontSizeXl,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()])),
      );
    } else {
      thumb = Container(
        width: m.s(212),
        height: m.s(119),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(m.s(12)),
          border: Border.all(color: ringColor, width: m.s(2)),
          boxShadow: focused
              ? [
                  BoxShadow(
                      color: TvDesignTokens.brand.withValues(alpha: 0.5),
                      blurRadius: m.s(18),
                      offset: Offset(0, m.s(8)))
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(m.s(10)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaImage(imageUrl: imageUrl, fit: BoxFit.cover),
              if (nowPlaying)
                Positioned(
                  left: m.s(8),
                  top: m.s(8),
                  child: _tag(m, '正在播放'),
                ),
              Positioned(
                left: m.s(8),
                bottom: m.s(8),
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: m.s(8), vertical: m.s(2)),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.66),
                    borderRadius: BorderRadius.circular(m.s(7)),
                  ),
                  child: Text(num,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: m.fontSizeSm,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ),
              if (watched)
                Positioned(
                  right: m.s(8),
                  top: m.s(8),
                  child: Container(
                    width: m.s(22),
                    height: m.s(22),
                    decoration: const BoxDecoration(
                        color: TvDesignTokens.brand, shape: BoxShape.circle),
                    child: Icon(Icons.check, color: Colors.white, size: m.s(14)),
                  ),
                ),
              if (progress != null && progress! > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: m.s(4),
                    backgroundColor: Colors.white.withValues(alpha: 0.25),
                    valueColor:
                        const AlwaysStoppedAnimation(TvDesignTokens.brand),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return AnimatedScale(
      scale: focused ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: SizedBox(
        width: numberOnly ? m.s(120) : m.s(212),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            thumb,
            SizedBox(height: m.s(8)),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: nowPlaying
                        ? TvDesignTokens.brand
                        : TvDesignTokens.textPrimary,
                    fontSize: m.fontSizeSm,
                    fontWeight:
                        nowPlaying ? FontWeight.w600 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _tag(TvMetrics m, String s) => Container(
        padding: EdgeInsets.symmetric(horizontal: m.s(8), vertical: m.s(2)),
        decoration: BoxDecoration(
            color: TvDesignTokens.brand,
            borderRadius: BorderRadius.circular(m.s(6))),
        child: Text(s,
            style: TextStyle(
                color: Colors.white,
                fontSize: m.fontSizeXs,
                fontWeight: FontWeight.w700)),
      );
}
