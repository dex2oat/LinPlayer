import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/app_identity.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/episode_aggregation_provider.dart';
import '../../../core/providers/update_providers.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/update/app_update_service.dart';
import '../../../core/services/font_service.dart';
import '../../../ui/widgets/common/app_update_gate.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/subtitle_document.dart';
import '../../../core/providers/proxy_providers.dart';
import '../../../core/network/proxy_settings.dart';
import '../../services/mihomo_service.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_grid.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_text_field.dart';
import '../../widgets/tv_toast.dart';
import 'tv_sync_settings.dart';
import 'zashboard_screen.dart';

/// TV 设置页 —— 左侧分类 + 右侧真实可持久化设置项。
class TvSettingsScreen extends ConsumerStatefulWidget {
  const TvSettingsScreen({super.key});

  @override
  ConsumerState<TvSettingsScreen> createState() => _TvSettingsScreenState();
}

class _TvSettingsScreenState extends ConsumerState<TvSettingsScreen> {
  int _selectedCategory = 0;

  static const List<_SettingCategory> _categories = [
    _SettingCategory(Icons.play_circle_outline, '播放'),
    _SettingCategory(Icons.subtitles_outlined, '弹幕'),
    _SettingCategory(Icons.settings, '通用'),
    _SettingCategory(Icons.palette_outlined, '外观'),
    _SettingCategory(Icons.vpn_key, '网络'),
    _SettingCategory(Icons.translate, '翻译'),
    _SettingCategory(Icons.sync, '同步'),
    _SettingCategory(Icons.info_outline, '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Row(
        children: [
          Container(
            width: m.sidebarWidth,
            color: TvDesignTokens.surface,
            child: ListView.builder(
              padding: EdgeInsets.all(m.spacingLg),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final category = _categories[index];
                final selected = _selectedCategory == index;
                return TvFocusable(
                  autofocus: index == 0,
                  padding: const EdgeInsets.all(4),
                  onSelect: () => setState(() => _selectedCategory = index),
                  child: AnimatedContainer(
                    duration: TvDesignTokens.focusAnimationDuration,
                    padding: EdgeInsets.all(m.spacingSm),
                    margin: EdgeInsets.only(bottom: m.spacingSm),
                    decoration: BoxDecoration(
                      color: selected
                          ? TvDesignTokens.brand.withValues(alpha: 0.15)
                          : TvDesignTokens.surface,
                      borderRadius: BorderRadius.circular(m.posterRadius),
                      border: selected
                          ? Border.all(
                              color: TvDesignTokens.brand.withValues(alpha: 0.5),
                              width: m.s(1.5))
                          : null,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: m.s(44),
                          height: m.s(44),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: TvDesignTokens.brand
                                .withValues(alpha: selected ? 0.25 : 0.12),
                            borderRadius: BorderRadius.circular(m.s(12)),
                          ),
                          child: Icon(category.icon,
                              color: TvDesignTokens.brand, size: m.s(24)),
                        ),
                        SizedBox(width: m.spacingMd),
                        Expanded(
                          child: Text(category.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: m.fontSizeMd,
                                  color: selected
                                      ? TvDesignTokens.textPrimary
                                      : TvDesignTokens.textSecondary,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.w500)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(child: _buildContent(m)),
        ],
      ),
    );
  }

  Widget _buildContent(TvMetrics m) {
    switch (_selectedCategory) {
      case 0:
        return _buildPlaybackSettings(m);
      case 1:
        return _buildDanmakuSettings(m);
      case 2:
        return _buildGeneralSettings(m);
      case 3:
        return _buildAppearanceSettings(m);
      case 4:
        return _buildNetworkSettings(m);
      case 5:
        return _buildTranslationSettings(m);
      case 6:
        return const TvSyncSettings();
      case 7:
        return _buildAboutSettings(m);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPlaybackSettings(TvMetrics m) {
    final core = ref.watch(playerCoreProvider);
    final speed = ref.watch(defaultPlaybackSpeedProvider);
    final threshold = ref.watch(watchedThresholdProvider);
    final skip = ref.watch(skipForwardStepProvider);
    final autoNext = ref.watch(autoPlayNextProvider);
    final autoSkipSegments = ref.watch(autoSkipSegmentsProvider);
    final preloadEnabled = ref.watch(preloadEnabledProvider);
    final strmDirectPlay = ref.watch(strmDirectPlayProvider);
    final exoLibass = ref.watch(exoLibassProvider);
    final gpuNext = ref.watch(gpuNextEnabledProvider);
    final dolbyAuto = ref.watch(dolbyAutoGpuNextSwProvider);
    final versionRegex = ref.watch(preferredVersionRegexProvider);
    final subtitleRegex = ref.watch(preferredSubtitleRegexProvider);
    final audioRegex = ref.watch(preferredAudioRegexProvider);

    return _settingsList(m, '播放设置', [
      _choiceItem<String>(
        m,
        title: '播放器内核',
        current: core,
        options: const [
          MapEntry('原生 MPV', 'nativeMpv'),
          MapEntry('MPV (media_kit)', 'mpv'),
          MapEntry('ExoPlayer', 'exoPlayer'),
        ],
        onPick: (v) =>
            ref.read(playerCoreProvider.notifier).state = v,
      ),
      _choiceItem<double>(
        m,
        title: '默认倍速',
        current: speed,
        labelOf: (v) => '${v}x',
        options: const [
          MapEntry('0.5x', 0.5),
          MapEntry('0.75x', 0.75),
          MapEntry('1.0x', 1.0),
          MapEntry('1.25x', 1.25),
          MapEntry('1.5x', 1.5),
          MapEntry('2.0x', 2.0),
        ],
        onPick: (v) =>
            ref.read(defaultPlaybackSpeedProvider.notifier).state = v,
      ),
      _choiceItem<int>(
        m,
        title: '观看阈值',
        subtitle: '播放进度达到该比例即标记“已看”，并触发同步上报',
        current: threshold,
        labelOf: (v) => '$v%',
        options: const [
          MapEntry('75%', 75),
          MapEntry('80%', 80),
          MapEntry('85%', 85),
          MapEntry('90%', 90),
          MapEntry('95%', 95),
        ],
        onPick: (v) =>
            ref.read(watchedThresholdProvider.notifier).state = v,
      ),
      _choiceItem<int>(
        m,
        title: '快进/快退步进',
        current: skip,
        labelOf: (v) => '$v 秒',
        options: const [
          MapEntry('5 秒', 5),
          MapEntry('10 秒', 10),
          MapEntry('15 秒', 15),
          MapEntry('30 秒', 30),
        ],
        onPick: (v) =>
            ref.read(skipForwardStepProvider.notifier).state = v,
      ),
      _toggleItem(
        m,
        title: '自动播放下一集',
        value: autoNext,
        onToggle: () =>
            ref.read(autoPlayNextProvider.notifier).state = !autoNext,
      ),
      _toggleItem(
        m,
        title: '选集卡用缩略图',
        subtitle: '播放页「选集」底栏用缩略图卡；关闭则用纯集数卡',
        value: ref.watch(tvEpisodeCardThumbnailProvider),
        onToggle: () =>
            ref.read(tvEpisodeCardThumbnailProvider.notifier).state =
                !ref.read(tvEpisodeCardThumbnailProvider),
      ),
      _toggleItem(
        m,
        title: '常驻底部进度条',
        subtitle: '播放时底部常显一条加粗进度条（控制栏未开时也可见）',
        value: ref.watch(tvPinnedProgressBarProvider),
        onToggle: () => ref.read(tvPinnedProgressBarProvider.notifier).state =
            !ref.read(tvPinnedProgressBarProvider),
      ),
      _toggleItem(
        m,
        title: '自动跳过片头/片尾',
        subtitle: '联网识别剧集片头片尾，进入时显示跳过按钮',
        value: autoSkipSegments,
        onToggle: () => ref.read(autoSkipSegmentsProvider.notifier).state =
            !autoSkipSegments,
      ),
      _toggleItem(
        m,
        title: '预加载',
        subtitle: '进入集/电影详情页时提前预热播放流，点播放更接近秒开（会消耗少量流量）',
        value: preloadEnabled,
        onToggle: () => ref.read(preloadEnabledProvider.notifier).state =
            !preloadEnabled,
      ),
      ..._mtlItems(m),
      ..._aggregationItems(m),
      _toggleItem(
        m,
        title: 'STRM 直链播放',
        subtitle: 'STRM 可获取直链时直接直链播放；部分服务器不兼容可能导致无法播放，仅在明确需要时开启',
        value: strmDirectPlay,
        onToggle: () => ref.read(strmDirectPlayProvider.notifier).state =
            !strmDirectPlay,
      ),
      _toggleItem(
        m,
        title: 'ExoPlayer ASS 字幕（libass）',
        subtitle: '开启后 ExoPlayer 内核可渲染内封特效 ASS 字幕（经 libass 转位图叠加）',
        value: exoLibass,
        onToggle: () =>
            ref.read(exoLibassProvider.notifier).state = !exoLibass,
      ),
      _toggleItem(
        m,
        title: 'MPV gpu-next 渲染',
        subtitle: '原生 MPV 使用 SurfaceView + gpu-next（HDR/着色器更佳，部分设备需关闭）',
        value: gpuNext,
        onToggle: () =>
            ref.read(gpuNextEnabledProvider.notifier).state = !gpuNext,
      ),
      _toggleItem(
        m,
        title: '杜比视界自动切换软解',
        subtitle: '播放杜比视界时自动启用 gpu-next 渲染 + 软件解码，修正硬解偏色',
        value: dolbyAuto,
        onToggle: () =>
            ref.read(dolbyAutoGpuNextSwProvider.notifier).state = !dolbyAuto,
      ),
      _textItem(
        m,
        title: '版本筛选（正则）',
        value: versionRegex,
        onSubmit: (v) => _saveRegexPref(preferredVersionRegexProvider, v),
      ),
      _textItem(
        m,
        title: '字幕筛选（正则，如 中文|简|繁|chi）',
        value: subtitleRegex,
        onSubmit: (v) => _saveRegexPref(preferredSubtitleRegexProvider, v),
      ),
      _textItem(
        m,
        title: '音频筛选（正则，如 jpn|日|flac）',
        value: audioRegex,
        onSubmit: (v) => _saveRegexPref(preferredAudioRegexProvider, v),
      ),
    ]);
  }

  /// 跨服聚合设置项：每个 Emby 服务器是否参与详情页「其他服务器版本」聚合。
  /// 开=允许，关=不允许（默认允许）。
  List<Widget> _aggregationItems(TvMetrics m) {
    ref.watch(aggregationDisabledServersProvider); // 状态变更时重建
    final notifier = ref.read(aggregationDisabledServersProvider.notifier);
    final servers =
        ref.watch(serverListProvider).where((s) => !s.isFileBrowse).toList();
    return [
      for (final s in servers)
        _toggleItem(
          m,
          title: '参与聚合：${s.name}',
          subtitle: notifier.isEnabled(s.id) ? '已允许' : '不参与',
          value: notifier.isEnabled(s.id),
          onToggle: () => notifier.setEnabled(s.id, !notifier.isEnabled(s.id)),
        ),
    ];
  }

  /// 多线程加载设置项：并发线程数 + 每个服务器的允许开关（按服务器白名单）。
  List<Widget> _mtlItems(TvMetrics m) {
    final servers = ref.watch(serverListProvider);
    final allowed = ref.watch(multiThreadLoadingServersProvider);
    final threads = ref.watch(multiThreadLoadingThreadsProvider);
    return [
      _choiceItem<int>(
        m,
        title: '多线程加载 · 并发线程数',
        subtitle: '弱网加速预取；仅对下方允许的服务器生效（需服主允许）',
        current: threads,
        options: const [MapEntry('2', 2), MapEntry('3', 3), MapEntry('4', 4)],
        onPick: (v) =>
            ref.read(multiThreadLoadingThreadsProvider.notifier).state = v,
      ),
      ...servers.map((s) => _toggleItem(
            m,
            title: '多线程加载：${s.name}',
            subtitle: allowed.contains(s.id) ? '已允许' : '未允许（需服主允许）',
            value: allowed.contains(s.id),
            onToggle: () => unawaited(_toggleServerMtl(s.id)),
          )),
    ];
  }

  /// 把某服务器加入/移出多线程加载白名单。加入前强制确认须获服主允许。
  Future<void> _toggleServerMtl(String id) async {
    final current = ref.read(multiThreadLoadingServersProvider);
    final notifier = ref.read(multiThreadLoadingServersProvider.notifier);
    if (current.contains(id)) {
      notifier.state = current.where((e) => e != id).toList();
      return;
    }
    final ok = await showTvConfirm(
      context,
      title: '请先获得服主允许',
      message: '多线程加载会用并发连接预取当前播放流，给该服务器带来额外并发压力。'
          '不少服主明确禁止多线程 / 预拉取，滥用可能导致封号。请确认你已获该服服主允许后再开启。',
      confirmLabel: '我已获服主允许',
      cancelLabel: '暂不开启',
    );
    if (!mounted || !ok) return;
    final cur = ref.read(multiThreadLoadingServersProvider);
    if (!cur.contains(id)) {
      ref.read(multiThreadLoadingServersProvider.notifier).state = [...cur, id];
    }
  }

  /// 保存正则筛选偏好：校验合法性，非法则提示且不保存。
  void _saveRegexPref(
      StateNotifierProvider<PreferenceNotifier<String>, String> provider,
      String raw) {
    final value = raw.trim();
    if (value.isNotEmpty) {
      try {
        RegExp(value);
      } catch (_) {
        if (mounted) TvToast.show(context, '正则表达式格式不正确，未保存');
        return;
      }
    }
    ref.read(provider.notifier).state = value;
  }

  /// 外观设置：TV 强制深色 + 纯色背景，故仅保留在 TV 上真正生效的项——
  /// 语言（tv_app 已 watch localeProvider）与隐藏每日推荐（首页 Hero Banner）。
  Widget _buildAppearanceSettings(TvMetrics m) {
    final locale = ref.watch(localeProvider);
    final hideDaily = ref.watch(hideDailyRecommendationsProvider);
    return _settingsList(m, '外观设置', [
      _choiceItem<Locale?>(
        m,
        title: '语言',
        current: locale,
        options: const [
          MapEntry('跟随系统', null),
          MapEntry('简体中文', Locale('zh', 'CN')),
          MapEntry('English', Locale('en')),
        ],
        labelOf: (v) => v == null ? '跟随系统' : v.toLanguageTag(),
        onPick: (v) => ref.read(localeProvider.notifier).state = v,
      ),
      _toggleItem(
        m,
        title: '隐藏每日推荐',
        subtitle: '关闭首页顶部的每日推荐 Hero 大图',
        value: hideDaily,
        onToggle: () => ref
            .read(hideDailyRecommendationsProvider.notifier)
            .state = !hideDaily,
      ),
    ]);
  }

  /// 弹幕设置：离散档位（遥控友好），对齐移动端弹幕设置的可调项。
  /// 屏蔽词/自定义源/字体在 TV 上省略（前者需文字输入、后者已在「通用·弹幕字体」）。
  Widget _buildDanmakuSettings(TvMetrics m) {
    final enabled = ref.watch(danmakuEnabledProvider);
    final opacity = ref.watch(danmakuOpacityProvider);
    final fontSize = ref.watch(danmakuFontSizeProvider);
    final speed = ref.watch(danmakuSpeedProvider);
    final density = ref.watch(danmakuDensityProvider);
    final displayArea = ref.watch(danmakuDisplayAreaProvider);
    final stroke = ref.watch(danmakuStrokeProvider);
    final delay = ref.watch(danmakuDelayProvider);
    final dedup = ref.watch(danmakuDedupProvider);
    final dedupWindow = ref.watch(danmakuDedupWindowProvider);

    return _settingsList(m, '弹幕设置', [
      _toggleItem(
        m,
        title: '弹幕开关',
        subtitle: enabled ? '已开启' : '已关闭',
        value: enabled,
        onToggle: () =>
            ref.read(danmakuEnabledProvider.notifier).state = !enabled,
      ),
      _choiceItem<double>(
        m,
        title: '透明度',
        current: opacity,
        options: const [
          MapEntry('40%', 0.4),
          MapEntry('60%', 0.6),
          MapEntry('80%', 0.8),
          MapEntry('100%', 1.0),
        ],
        labelOf: (v) => '${(v * 100).round()}%',
        onPick: (v) => ref.read(danmakuOpacityProvider.notifier).state = v,
      ),
      _choiceItem<double>(
        m,
        title: '字号',
        current: fontSize,
        options: const [
          MapEntry('小', 0.3),
          MapEntry('较小', 0.4),
          MapEntry('标准', 0.5),
          MapEntry('较大', 0.7),
          MapEntry('大', 0.9),
        ],
        labelOf: (v) => v.toStringAsFixed(2),
        onPick: (v) => ref.read(danmakuFontSizeProvider.notifier).state = v,
      ),
      _choiceItem<double>(
        m,
        title: '速度',
        current: speed,
        options: const [
          MapEntry('慢', 0.2),
          MapEntry('较慢', 0.35),
          MapEntry('标准', 0.5),
          MapEntry('较快', 0.7),
          MapEntry('快', 0.9),
        ],
        labelOf: (v) => v.toStringAsFixed(2),
        onPick: (v) => ref.read(danmakuSpeedProvider.notifier).state = v,
      ),
      _choiceItem<double>(
        m,
        title: '密度',
        current: density,
        options: const [
          MapEntry('稀疏', 0.2),
          MapEntry('较疏', 0.35),
          MapEntry('标准', 0.5),
          MapEntry('较密', 0.7),
          MapEntry('密集', 0.9),
        ],
        labelOf: (v) => v.toStringAsFixed(2),
        onPick: (v) => ref.read(danmakuDensityProvider.notifier).state = v,
      ),
      _choiceItem<double>(
        m,
        title: '显示区域',
        subtitle: '弹幕占用的画面高度范围',
        current: displayArea,
        options: const [
          MapEntry('顶部 1/4', 0.25),
          MapEntry('半屏', 0.5),
          MapEntry('全屏', 1.0),
        ],
        onPick: (v) =>
            ref.read(danmakuDisplayAreaProvider.notifier).state = v,
      ),
      _toggleItem(
        m,
        title: '描边文字',
        subtitle: '黑边彩字，关闭则用半透明底框',
        value: stroke,
        onToggle: () =>
            ref.read(danmakuStrokeProvider.notifier).state = !stroke,
      ),
      _choiceItem<double>(
        m,
        title: '弹幕延迟',
        subtitle: '弹幕相对视频提前/延后出现',
        current: delay,
        options: const [
          MapEntry('-3s', -3.0),
          MapEntry('-2s', -2.0),
          MapEntry('-1s', -1.0),
          MapEntry('不延迟', 0.0),
          MapEntry('+1s', 1.0),
          MapEntry('+2s', 2.0),
          MapEntry('+3s', 3.0),
        ],
        labelOf: (v) => '${v.toStringAsFixed(1)}s',
        onPick: (v) => ref.read(danmakuDelayProvider.notifier).state = v,
      ),
      _toggleItem(
        m,
        title: '弹幕去重',
        subtitle: '合并相同文本弹幕，显示重复次数',
        value: dedup,
        onToggle: () =>
            ref.read(danmakuDedupProvider.notifier).state = !dedup,
      ),
      if (dedup)
        _choiceItem<double>(
          m,
          title: '去重时间窗口',
          current: dedupWindow,
          options: const [
            MapEntry('5 秒', 5.0),
            MapEntry('10 秒', 10.0),
            MapEntry('15 秒', 15.0),
            MapEntry('20 秒', 20.0),
            MapEntry('30 秒', 30.0),
          ],
          labelOf: (v) => '${v.toStringAsFixed(0)} 秒',
          onPick: (v) =>
              ref.read(danmakuDedupWindowProvider.notifier).state = v,
        ),
    ]);
  }

  Widget _buildGeneralSettings(TvMetrics m) {
    final hwDecode = ref.watch(hardwareDecodingProvider);
    final bgPlay = ref.watch(backgroundPlaybackProvider);
    return _settingsList(m, '通用设置', [
      _toggleItem(
        m,
        title: '硬件解码',
        subtitle: '关闭后使用软件解码（更耗电、更兼容）',
        value: hwDecode,
        onToggle: () =>
            ref.read(hardwareDecodingProvider.notifier).state = !hwDecode,
      ),
      _toggleItem(
        m,
        title: '后台播放',
        value: bgPlay,
        onToggle: () =>
            ref.read(backgroundPlaybackProvider.notifier).state = !bgPlay,
      ),
      _rowCard(
        m,
        title: '手机扫码遥控',
        subtitle: '生成局域网二维码，用手机编辑设置/服务器并遥控播放',
        leadingIcon: Icons.qr_code_2,
        trailing: Icon(Icons.chevron_right,
            color: TvDesignTokens.textSecondary, size: m.s(28)),
        onSelect: () => context.push('/tv/lan-control'),
      ),
      _rowCard(
        m,
        title: '配置二维码',
        subtitle: '把本机服务器(含登录凭据)出成二维码，用手机扫码导入',
        leadingIcon: Icons.qr_code_scanner,
        trailing: Icon(Icons.chevron_right,
            color: TvDesignTokens.textSecondary, size: m.s(28)),
        onSelect: () => context.push('/tv/config-qr'),
      ),
      _rowCard(
        m,
        title: '插件',
        subtitle: '从插件市场一键安装、启用/卸载插件（TV 无需文件导入）',
        leadingIcon: Icons.extension,
        trailing: Icon(Icons.chevron_right,
            color: TvDesignTokens.textSecondary, size: m.s(28)),
        onSelect: () => context.push('/tv/plugins'),
      ),
      _fontItem(
        m,
        title: '应用字体',
        path: ref.watch(customAppFontPathProvider),
        defaultHint: '默认字体 · 选择字体文件 (ttf/otf)，切换后重启生效',
        isApp: true,
      ),
      _fontItem(
        m,
        title: '弹幕字体',
        path: ref.watch(customDanmakuFontPathProvider),
        defaultHint: '默认字体 · 选择字体文件 (ttf/otf)',
        isApp: false,
      ),
    ]);
  }

  Widget _buildNetworkSettings(TvMetrics m) {
    final cfg = ref.watch(proxyConfigProvider);
    final notifier = ref.read(proxyConfigProvider.notifier);

    final items = <Widget>[
      _choiceItem<ProxyType>(
        m,
        title: '代理协议',
        current: cfg.type,
        labelOf: (v) => v.label,
        options: [for (final t in ProxyType.values) MapEntry(t.label, t)],
        onPick: (v) => notifier.save(cfg.copyWith(type: v)),
      ),
    ];

    if (cfg.type != ProxyType.none) {
      items.addAll([
        _textItem(
          m,
          title: '主机 (Host)',
          value: cfg.host,
          onSubmit: (v) => notifier.save(cfg.copyWith(host: v.trim())),
        ),
        _textItem(
          m,
          title: '端口 (Port)',
          value: cfg.port > 0 ? '${cfg.port}' : '',
          onSubmit: (v) =>
              notifier.save(cfg.copyWith(port: int.tryParse(v.trim()) ?? 0)),
        ),
        _textItem(
          m,
          title: '用户名（可选）',
          value: cfg.username,
          onSubmit: (v) => notifier.save(cfg.copyWith(username: v)),
        ),
        _textItem(
          m,
          title: '密码（可选）',
          value: cfg.password,
          obscure: true,
          onSubmit: (v) => notifier.save(cfg.copyWith(password: v)),
        ),
        _toggleItem(
          m,
          title: '代理媒体流播放',
          subtitle: cfg.type.isSocks
              ? 'libmpv 不支持 SOCKS，此项仅对 HTTP 代理生效'
              : '关闭则播放直连、仅代理 API/图片等请求',
          value: cfg.proxyMedia,
          onToggle: () => notifier.save(cfg.copyWith(proxyMedia: !cfg.proxyMedia)),
        ),
      ]);
    }

    // CF 优选反代：本机实测 CF 边缘 IP + 本地反代加速走 Cloudflare 的线路。
    items
      ..add(SizedBox(height: m.spacingLg))
      ..add(_rowCard(
        m,
        title: 'CF 优选反代',
        subtitle: '为走 Cloudflare 的服务器优选边缘 IP 并本地反代提速（支持定时复测）',
        leadingIcon: Icons.bolt,
        trailing: Icon(Icons.chevron_right,
            color: TvDesignTokens.textSecondary, size: m.s(28)),
        onSelect: () => context.push('/tv/cf-proxy'),
      ));

    // 订阅代理(mihomo) —— 仅 Android TV 内置内核。
    if (Platform.isAndroid) {
      items
        ..add(SizedBox(height: m.spacingLg))
        ..addAll(_mihomoItems(m));
    }

    return _settingsList(m, '代理设置', items);
  }

  List<Widget> _mihomoItems(TvMetrics m) {
    final mihomo = ref.watch(mihomoControllerProvider);
    final ctrl = ref.read(mihomoControllerProvider.notifier);

    final items = <Widget>[
      Padding(
        padding: EdgeInsets.only(
            left: 4, bottom: m.spacingMd, top: m.spacingMd),
        child: Text('订阅代理 (mihomo)',
            style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold)),
      ),
    ];

    if (!mihomo.coreAvailable) {
      items.add(_staticItem(
        m,
        title: '内核未内置',
        subtitle: '仅 Android TV 构建包含 mihomo 内核（libmihomo.so）。'
            '运行 scripts/fetch_mihomo_tv.ps1 拉取后重新构建 tv flavor。',
      ));
      return items;
    }

    items.add(_toggleItem(
      m,
      title: '启用订阅代理',
      subtitle: mihomo.running
          ? '运行中 · 全局走 mihomo（含播放流），启用后会覆盖上方手动代理'
          : '启动 mihomo 并把全局代理指向本地端口 ${MihomoPorts.mixedPort}',
      value: mihomo.enabled,
      onToggle: () => mihomo.enabled ? ctrl.disable() : ctrl.enable(),
    ));

    for (final s in mihomo.subscriptions) {
      items.add(_rowCard(
        m,
        title: s.name,
        subtitle: s.url,
        trailing: Icon(Icons.delete_outline,
            color: TvDesignTokens.textSecondary, size: m.s(24)),
        onSelect: () => ctrl.removeSubscription(s.id),
      ));
    }

    items.add(_actionItem(
      m,
      title: '添加订阅',
      subtitle: '输入机场订阅链接',
      onTap: _showAddSubscription,
    ));
    if (mihomo.subscriptions.isNotEmpty) {
      items.add(_actionItem(
        m,
        title: '更新订阅',
        subtitle: '重新拉取并重载配置',
        onTap: () {
          ctrl.refresh();
          TvToast.show(context, '正在重载订阅…');
        },
      ));
    }
    if (mihomo.running) {
      items.add(_actionItem(
        m,
        title: '打开 zashboard 面板',
        subtitle: '选择节点 / 查看连接 / 测速',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ZashboardScreen()),
        ),
      ));
    }
    return items;
  }

  void _showAddSubscription() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        title: const Text('添加订阅',
            style: TextStyle(color: TvDesignTokens.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TvTextField(
              controller: nameController,
              autofocus: true,
              hint: '名称（可选）',
            ),
            const SizedBox(height: 12),
            TvTextField(
              controller: urlController,
              hint: '订阅链接 (URL)',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                Navigator.pop(dialogContext);
                return;
              }
              ref
                  .read(mihomoControllerProvider.notifier)
                  .addSubscription(nameController.text, url);
              Navigator.pop(dialogContext);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Widget _buildTranslationSettings(TvMetrics m) {
    final kind = ref.watch(translationEngineKindProvider);
    final target = ref.watch(translationTargetLangProvider);
    final layout = ref.watch(bilingualLayoutProvider);

    final items = <Widget>[
      _choiceItem<TranslationEngineKind>(
        m,
        title: '翻译引擎',
        current: kind,
        labelOf: (v) => v.label,
        options: [
          for (final e in TranslationEngineKind.values) MapEntry(e.label, e),
        ],
        onPick: (v) =>
            ref.read(translationEngineKindProvider.notifier).state = v,
      ),
      _choiceItem<String>(
        m,
        title: '目标语言',
        current: target == 'cht' ? 'cht' : 'zh',
        options: const [
          MapEntry('简体中文', 'zh'),
          MapEntry('繁体中文', 'cht'),
        ],
        onPick: (v) =>
            ref.read(translationTargetLangProvider.notifier).state = v,
      ),
      _choiceItem<BilingualLayout>(
        m,
        title: '双语排版',
        current: layout,
        labelOf: (v) => switch (v) {
          BilingualLayout.translatedOnly => '仅译文',
          BilingualLayout.translatedFirst => '译文+原文',
          BilingualLayout.originalFirst => '原文+译文',
        },
        options: const [
          MapEntry('仅译文', BilingualLayout.translatedOnly),
          MapEntry('译文+原文', BilingualLayout.translatedFirst),
          MapEntry('原文+译文', BilingualLayout.originalFirst),
        ],
        onPick: (v) => ref.read(bilingualLayoutProvider.notifier).state = v,
      ),
      ..._engineConfigItems(m, kind),
    ];
    return _settingsList(m, '字幕翻译', items);
  }

  List<Widget> _engineConfigItems(TvMetrics m, TranslationEngineKind kind) {
    switch (kind) {
      case TranslationEngineKind.openai:
      case TranslationEngineKind.anthropic:
        final provider = kind == TranslationEngineKind.openai
            ? openAiConfigProvider
            : anthropicConfigProvider;
        final cfg = ref.watch(provider);
        return [
          _textItem(
            m,
            title: 'API 地址',
            value: cfg.baseUrl,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(baseUrl: v.trim()),
          ),
          _textItem(
            m,
            title: 'API Key',
            value: cfg.apiKey,
            obscure: true,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(apiKey: v.trim()),
          ),
          _textItem(
            m,
            title: '模型',
            value: cfg.model,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(model: v.trim()),
          ),
        ];
      case TranslationEngineKind.baiduGeneral:
        final cfg = ref.watch(baiduGeneralConfigProvider);
        return [
          _textItem(
            m,
            title: 'APP ID',
            value: cfg.appId,
            onSubmit: (v) => ref.read(baiduGeneralConfigProvider.notifier).state =
                cfg.copyWith(appId: v.trim()),
          ),
          _textItem(
            m,
            title: '密钥',
            value: cfg.secretKey,
            obscure: true,
            onSubmit: (v) => ref.read(baiduGeneralConfigProvider.notifier).state =
                cfg.copyWith(secretKey: v.trim()),
          ),
        ];
      case TranslationEngineKind.baiduLlm:
        final cfg = ref.watch(baiduLlmConfigProvider);
        return [
          _textItem(
            m,
            title: 'APP ID',
            value: cfg.appId,
            onSubmit: (v) => ref.read(baiduLlmConfigProvider.notifier).state =
                cfg.copyWith(appId: v.trim()),
          ),
          _textItem(
            m,
            title: 'API Key',
            value: cfg.apiKey,
            obscure: true,
            onSubmit: (v) => ref.read(baiduLlmConfigProvider.notifier).state =
                cfg.copyWith(apiKey: v.trim()),
          ),
        ];
      case TranslationEngineKind.tencent:
        final cfg = ref.watch(tencentConfigProvider);
        return [
          _textItem(
            m,
            title: 'SecretId',
            value: cfg.secretId,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(secretId: v.trim()),
          ),
          _textItem(
            m,
            title: 'SecretKey',
            value: cfg.secretKey,
            obscure: true,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(secretKey: v.trim()),
          ),
          _textItem(
            m,
            title: '地域 Region',
            value: cfg.region,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(region: v.trim().isEmpty ? 'ap-beijing' : v.trim()),
          ),
        ];
    }
  }

  Widget _textItem(
    TvMetrics m, {
    required String title,
    required String value,
    required ValueChanged<String> onSubmit,
    bool obscure = false,
  }) {
    final display = value.isEmpty
        ? '未设置'
        : (obscure ? '••••••${value.length > 4 ? value.substring(value.length - 4) : ''}' : value);
    return _rowCard(
      m,
      title: title,
      subtitle: display,
      trailing: Icon(Icons.edit,
          color: TvDesignTokens.textSecondary, size: m.s(24)),
      onSelect: () => _showTextInput(title, value, obscure, onSubmit),
    );
  }

  void _showTextInput(
      String title, String value, bool obscure, ValueChanged<String> onSubmit) {
    final controller = TextEditingController(text: value);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        title: Text(title, style: const TextStyle(color: TvDesignTokens.textPrimary)),
        content: TvTextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              onSubmit(controller.text);
              Navigator.pop(dialogContext);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSettings(TvMetrics m) {
    return _settingsList(m, '关于', [
      _staticItem(m, title: '应用', subtitle: 'LinPlayer for TV'),
      _staticItem(m, title: '版本', subtitle: kAppVersion),
      _choiceItem<UpdateChannel>(
        m,
        title: '更新渠道',
        current: ref.watch(updateChannelProvider),
        labelOf: updateChannelLabel,
        options: const [
          MapEntry('稳定版（latest）', UpdateChannel.stable),
          MapEntry('预览版（pre-release）', UpdateChannel.prerelease),
        ],
        onPick: (v) => ref.read(updateChannelProvider.notifier).state = v,
      ),
      _actionItem(
        m,
        title: '检查更新',
        subtitle: '当前 $kAppVersion · 启动与每 24 小时自动检查',
        leadingIcon: Icons.system_update,
        onTap: _checkUpdateTv,
      ),
      _actionItem(
        m,
        title: '导出日志',
        subtitle: '导出到文件并复制路径（排查问题用）',
        leadingIcon: Icons.description_outlined,
        onTap: _exportLogs,
      ),
      _actionItem(
        m,
        title: '重新查看引导',
        subtitle: '打开 TV 引导页',
        leadingIcon: Icons.explore_outlined,
        onTap: () => context.go('/tv/onboarding'),
      ),
    ]);
  }

  Future<void> _exportLogs() async {
    try {
      final path = await AppLogger().exportToFile();
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) TvToast.show(context, '日志已导出并复制路径: $path');
    } catch (e) {
      if (mounted) TvToast.show(context, '导出日志失败: $e');
    }
  }

  Future<void> _checkUpdateTv() async {
    TvToast.show(context, '正在检查更新…');
    final channel = ref.read(updateChannelProvider);
    final UpdateInfo? info;
    try {
      info = await ref.read(appUpdateServiceProvider).checkForUpdate(
            includePrerelease: channel == UpdateChannel.prerelease,
          );
    } catch (_) {
      if (mounted) TvToast.show(context, '检查更新失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    if (info == null) {
      TvToast.show(context, '已是最新版本（$kAppVersion）');
      return;
    }
    ref.read(availableUpdateProvider.notifier).state = info;
    await showUpdateDialog(context, info);
  }

  // ============ 复用控件 ============

  Widget _settingsList(TvMetrics m, String title, List<Widget> items) {
    return ListView(
      padding: EdgeInsets.all(m.spacingXl),
      children: [
        Text(title,
            style: TextStyle(
                fontSize: m.fontSizeXxl,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold)),
        SizedBox(height: m.spacingLg),
        // 右侧内容改多列网格：连续设置卡分 2 列，分区标题/间距仍整宽穿插。
        ...tvGridifyFocusables(items, minCellWidth: 560),
      ],
    );
  }

  Widget _rowCard(
    TvMetrics m, {
    required String title,
    String? subtitle,
    IconData? leadingIcon,
    Widget? trailing,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      padding: const EdgeInsets.all(4),
      onSelect: onSelect,
      child: Container(
        padding: EdgeInsets.all(m.spacingLg),
        margin: EdgeInsets.only(bottom: m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            if (leadingIcon != null) ...[
              Container(
                width: m.s(44),
                height: m.s(44),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: TvDesignTokens.brand.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(m.s(12)),
                ),
                child: Icon(leadingIcon,
                    color: TvDesignTokens.brand, size: m.s(24)),
              ),
              SizedBox(width: m.spacingMd),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textPrimary,
                          fontWeight: FontWeight.w600)),
                  if (subtitle != null) ...[
                    SizedBox(height: m.s(2)),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: m.fontSizeXs,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: m.spacingMd),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _choiceItem<T>(
    TvMetrics m, {
    required String title,
    String? subtitle,
    required T current,
    required List<MapEntry<String, T>> options,
    required ValueChanged<T> onPick,
    String Function(T)? labelOf,
  }) {
    final currentLabel = options
            .firstWhere((e) => e.value == current,
                orElse: () => MapEntry(
                    labelOf?.call(current) ?? '$current', current))
            .key;
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle ?? currentLabel,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(currentLabel,
              style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.brand)),
          SizedBox(width: m.spacingXs),
          Icon(Icons.chevron_right,
              color: TvDesignTokens.textSecondary, size: m.s(28)),
        ],
      ),
      onSelect: () => _showChoice<T>(title, current, options, onPick),
    );
  }

  void _showChoice<T>(String title, T current,
      List<MapEntry<String, T>> options, ValueChanged<T> onPick) {
    showDialog(
      context: context,
      builder: (dialogContext) => TvPanel(
        title: title,
        onClose: () => Navigator.pop(dialogContext),
        children: [
          for (final opt in options)
            TvPanelOption(
              title: opt.key,
              isSelected: opt.value == current,
              onTap: () {
                onPick(opt.value);
                Navigator.pop(dialogContext);
              },
            ),
        ],
      ),
    );
  }

  Widget _toggleItem(
    TvMetrics m, {
    required String title,
    String? subtitle,
    required bool value,
    required VoidCallback onToggle,
  }) {
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle,
      onSelect: onToggle,
      trailing: AnimatedContainer(
        duration: TvDesignTokens.focusAnimationDuration,
        width: m.s(56),
        height: m.s(30),
        decoration: BoxDecoration(
          color: value
              ? TvDesignTokens.brand
              : TvDesignTokens.surfaceElevated,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: EdgeInsets.all(m.s(3)),
        child: Container(
          width: m.s(24),
          height: m.s(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _staticItem(TvMetrics m,
      {required String title, required String subtitle}) {
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle,
      onSelect: () {},
    );
  }

  /// 字体导入行：显示当前字体名 + 点击选择字体文件；已设置时长按清除恢复默认。
  Widget _fontItem(
    TvMetrics m, {
    required String title,
    required String path,
    required String defaultHint,
    required bool isApp,
  }) {
    final isSet = path.isNotEmpty;
    return _rowCard(
      m,
      title: title,
      subtitle: isSet ? p.basename(path) : defaultHint,
      leadingIcon: Icons.font_download_outlined,
      trailing: Icon(isSet ? Icons.clear : Icons.folder_open,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
      onSelect: () {
        if (isSet) {
          _clearFont(isApp: isApp);
        } else {
          _importFont(isApp: isApp);
        }
      },
    );
  }

  Future<void> _importFont({required bool isApp}) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: isApp ? '选择 App 字体文件' : '选择弹幕字体文件',
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf', 'ttc'],
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    // 用 setApp/DanmakuFont 返回的持久化路径更新 Provider，避免用 FilePicker
    // 临时缓存路径覆盖、重启后字体失效。
    final savedPath = isApp
        ? await FontService.setAppFont(path)
        : await FontService.setDanmakuFont(path);
    if (!mounted) return;
    if (savedPath != null) {
      ref
          .read((isApp
                  ? customAppFontPathProvider
                  : customDanmakuFontPathProvider)
              .notifier)
          .state = savedPath;
      TvToast.show(context, '字体已应用：${p.basename(savedPath)}');
    } else {
      TvToast.show(context, '字体加载失败，请确认为有效的 ttf/otf 字体');
    }
  }

  Future<void> _clearFont({required bool isApp}) async {
    if (isApp) {
      await FontService.clearAppFont();
      ref.read(customAppFontPathProvider.notifier).state = '';
    } else {
      await FontService.clearDanmakuFont();
      ref.read(customDanmakuFontPathProvider.notifier).state = '';
    }
    if (mounted) TvToast.show(context, '已恢复默认字体');
  }

  Widget _actionItem(
    TvMetrics m, {
    required String title,
    String? subtitle,
    IconData? leadingIcon,
    required VoidCallback onTap,
  }) {
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle,
      leadingIcon: leadingIcon,
      onSelect: onTap,
      trailing: Icon(Icons.chevron_right,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
    );
  }
}

class _SettingCategory {
  final IconData icon;
  final String name;
  const _SettingCategory(this.icon, this.name);
}
