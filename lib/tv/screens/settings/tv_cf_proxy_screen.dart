import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/cf_proxy/cf_proxy_controller.dart';
import '../../../core/network/cf_proxy/cf_speed_tester.dart';
import '../../../core/providers/server_providers.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_toast.dart';

/// TV 端「CF 优选反代」面板（D-pad/遥控器友好版）。
///
/// 与移动/桌面共用同一套宿主引擎 [CfProxyController]，但 UI 全部改用 TV 焦点控件
/// （[TvFocusable] / [TvPanel] / 选择弹层），不依赖鼠标向的下拉框/可编辑输入框，
/// 用遥控器即可：选服务器 → 测速并反代 → 定时测速 → 关闭。
class TvCfProxyScreen extends ConsumerStatefulWidget {
  const TvCfProxyScreen({super.key});

  @override
  ConsumerState<TvCfProxyScreen> createState() => _TvCfProxyScreenState();
}

class _TvCfProxyScreenState extends ConsumerState<TvCfProxyScreen> {
  final CfProxyController _ctrl = CfProxyController.instance;
  final Map<String, CfTestProgress> _progress = {};
  final Map<String, CfCancelToken> _cancels = {};

  @override
  void initState() {
    super.initState();
    // 确保引擎已注入容器（TV 端可能在未启用插件流程时直接进入本页）。
    _ctrl.ensureInit(ProviderScope.containerOf(context, listen: false));
    _ctrl.addListener(_onCtrl);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onCtrl);
    super.dispose();
  }

  void _onCtrl() {
    if (mounted) setState(() {});
  }

  Future<void> _runTest(ServerConfig server) async {
    final cancel = CfCancelToken();
    _cancels[server.id] = cancel;
    setState(() {
      _progress[server.id] =
          const CfTestProgress(phase: CfTestPhase.sampling, message: '准备中…');
    });
    String? errMsg;
    try {
      final best = await _ctrl.speedTestAndApply(
        server.id,
        cancel: cancel,
        onProgress: (p) {
          if (p.phase == CfTestPhase.error && p.message != null) {
            errMsg = p.message;
          }
          if (mounted) setState(() => _progress[server.id] = p);
        },
      );
      if (!mounted) return;
      if (cancel.canceled) {
        TvToast.show(context, '已取消测速');
      } else if (best == null) {
        TvToast.show(context, errMsg ?? '测速失败：未找到可用的优选 IP');
      } else {
        TvToast.show(
            context,
            '已反代「${server.name}」→ ${best.ip}（${best.latencyMs}ms'
            '${best.downloadKBps != null ? ' · ${(best.downloadKBps! / 1024).toStringAsFixed(2)} MB/s' : ''}）');
      }
    } catch (e) {
      if (mounted) TvToast.show(context, '测速出错: $e');
    } finally {
      _cancels.remove(server.id);
      if (mounted) setState(() => _progress.remove(server.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final servers = ref.watch(serverListProvider);
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(m.spacingXl),
          children: [
            Text('CF 优选反代',
                style: TextStyle(
                    fontSize: m.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold)),
            SizedBox(height: m.spacingMd),
            _intro(m),
            SizedBox(height: m.spacingLg),
            _ipModeRow(m),
            _globalTestUrlRow(m),
            SizedBox(height: m.spacingLg),
            if (servers.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: m.spacingXxl),
                child: Center(
                  child: Text('还没有添加任何服务器',
                      style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textSecondary)),
                ),
              )
            else
              for (final s in servers) _serverBlock(m, s),
          ],
        ),
      ),
    );
  }

  Widget _intro(TvMetrics m) {
    return Container(
      padding: EdgeInsets.all(m.spacingLg),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.bolt, color: TvDesignTokens.brand, size: m.s(28)),
          SizedBox(width: m.spacingMd),
          Expanded(
            child: Text(
              '为走 Cloudflare 的服务器，从本机实测挑出最快的 CF 边缘 IP，并通过本地反代'
              '改写线路。比公共优选 IP 更贴合你的网络。开启定时测速可全天候保速。',
              style: TextStyle(
                  fontSize: m.fontSizeSm,
                  height: 1.5,
                  color: TvDesignTokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ipModeRow(TvMetrics m) {
    String label(CfIpMode v) => switch (v) {
          CfIpMode.auto => '自动',
          CfIpMode.v4 => '仅 IPv4',
          CfIpMode.v6 => '仅 IPv6',
          CfIpMode.dual => '双栈',
        };
    return _rowCard(
      m,
      title: '优选协议',
      subtitle: label(_ctrl.ipMode),
      trailing: Icon(Icons.chevron_right,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
      onSelect: () => _showChoice<CfIpMode>(
        '优选协议',
        _ctrl.ipMode,
        [for (final v in CfIpMode.values) MapEntry(label(v), v)],
        (v) => _ctrl.setIpMode(v),
      ),
    );
  }

  Widget _globalTestUrlRow(TvMetrics m) {
    return _rowCard(
      m,
      title: '全局测速文件',
      subtitle: _ctrl.globalTestUrl,
      trailing: Icon(Icons.edit,
          color: TvDesignTokens.textSecondary, size: m.s(24)),
      onSelect: () => _showTextInput(
        '全局测速文件（需走 Cloudflare）',
        _ctrl.globalTestUrl,
        (v) async {
          await _ctrl.setGlobalTestUrl(v);
          if (mounted) TvToast.show(context, '已保存测速文件地址');
        },
      ),
    );
  }

  Widget _serverBlock(TvMetrics m, ServerConfig server) {
    final state = _ctrl.stateFor(server.id);
    final active = _ctrl.isActive(server.id);
    final running = _progress.containsKey(server.id);
    final host = Uri.tryParse(server.directLineUrl)?.host ?? server.directLineUrl;
    final scheduleEnabled = state?.scheduleEnabled ?? false;
    final minutes = state?.scheduleMinutes ?? 30;

    return Container(
      margin: EdgeInsets.only(bottom: m.spacingLg),
      padding: EdgeInsets.all(m.spacingLg),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(server.name,
                        style: TextStyle(
                            fontSize: m.fontSizeLg,
                            color: TvDesignTokens.textPrimary,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: m.s(2)),
                    Text(host,
                        style: TextStyle(
                            fontSize: m.fontSizeXs,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ),
              ),
              _statusChip(m, active),
            ],
          ),
          if (active && state?.pinnedIp != null) ...[
            SizedBox(height: m.spacingSm),
            Text(_activeInfo(state!),
                style:
                    TextStyle(fontSize: m.fontSizeSm, color: TvDesignTokens.brand)),
          ],
          if (running) ...[
            SizedBox(height: m.spacingMd),
            _progressView(m, server.id),
          ],
          SizedBox(height: m.spacingSm),
          if (running)
            _actionRow(m,
                icon: Icons.stop,
                title: '取消测速',
                onSelect: () => _cancels[server.id]?.cancel())
          else
            _actionRow(m,
                icon: Icons.speed,
                title: active ? '重新测速并反代' : '测速并反代',
                onSelect: () => _runTest(server)),
          if (active && !running)
            _actionRow(m,
                icon: Icons.link_off,
                title: '关闭反代',
                onSelect: () => _ctrl.disable(server.id)),
          _toggleRow(
            m,
            title: '定时测速',
            subtitle: scheduleEnabled ? '每 $minutes 分钟自动复测保速' : '关闭',
            value: scheduleEnabled,
            onToggle: () =>
                _ctrl.setSchedule(server.id, !scheduleEnabled, minutes),
          ),
          if (scheduleEnabled)
            _rowCard(
              m,
              title: '复测间隔',
              subtitle: '每 $minutes 分钟',
              trailing: Icon(Icons.chevron_right,
                  color: TvDesignTokens.textSecondary, size: m.s(28)),
              onSelect: () => _showChoice<int>(
                '复测间隔',
                const [15, 30, 60, 120, 360].contains(minutes) ? minutes : 30,
                const [
                  MapEntry('每 15 分钟', 15),
                  MapEntry('每 30 分钟', 30),
                  MapEntry('每 1 小时', 60),
                  MapEntry('每 2 小时', 120),
                  MapEntry('每 6 小时', 360),
                ],
                (v) => _ctrl.setSchedule(server.id, true, v),
              ),
            ),
        ],
      ),
    );
  }

  String _activeInfo(CfServerState state) {
    final r = state.lastResult;
    final parts = <String>[
      '优选 IP ${state.pinnedIp}',
      if (r != null) '${r.latencyMs}ms',
      if (r?.downloadKBps != null)
        '${(r!.downloadKBps! / 1024).toStringAsFixed(2)} MB/s',
    ];
    return parts.join(' · ');
  }

  Widget _statusChip(TvMetrics m, bool active) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingMd, vertical: m.s(4)),
      decoration: BoxDecoration(
        color: active
            ? TvDesignTokens.brand.withValues(alpha: 0.18)
            : TvDesignTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        active ? '反代中' : '未启用',
        style: TextStyle(
            fontSize: m.fontSizeXs,
            color: active ? TvDesignTokens.brand : TvDesignTokens.textSecondary),
      ),
    );
  }

  Widget _progressView(TvMetrics m, String serverId) {
    final p = _progress[serverId]!;
    final phaseLabel = switch (p.phase) {
      CfTestPhase.sampling => '抽样 IP',
      CfTestPhase.latency => '① 测延迟',
      CfTestPhase.validate => '② HTTP 校验',
      CfTestPhase.download => '③ 测速度',
      CfTestPhase.done => '完成',
      CfTestPhase.error => '出错',
    };
    final sub = p.total > 0 ? (p.tested / p.total).clamp(0.0, 1.0) : 0.0;
    final double overall = switch (p.phase) {
      CfTestPhase.sampling => 0.03,
      CfTestPhase.latency => 0.03 + 0.42 * sub,
      CfTestPhase.validate => 0.45 + 0.20 * sub,
      CfTestPhase.download => 0.65 + 0.35 * sub,
      CfTestPhase.done => 1.0,
      CfTestPhase.error => 0.0,
    };
    final best = p.best;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(phaseLabel,
                style: TextStyle(
                    fontSize: m.fontSizeSm,
                    fontWeight: FontWeight.bold,
                    color: TvDesignTokens.textPrimary)),
            const Spacer(),
            Text('${(overall * 100).round()}%',
                style: TextStyle(
                    fontSize: m.fontSizeSm,
                    fontWeight: FontWeight.bold,
                    color: TvDesignTokens.brand)),
          ],
        ),
        SizedBox(height: m.spacingXs),
        ClipRRect(
          borderRadius: BorderRadius.circular(m.s(4)),
          child: LinearProgressIndicator(
            value: overall,
            minHeight: m.s(6),
            backgroundColor: TvDesignTokens.surfaceElevated,
            valueColor:
                const AlwaysStoppedAnimation<Color>(TvDesignTokens.brand),
          ),
        ),
        SizedBox(height: m.spacingXs),
        if (p.message != null)
          Text(p.message!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: m.fontSizeXs, color: TvDesignTokens.textSecondary)),
        if (best != null)
          Text(
            '当前最优 ${best.ip} · ${best.latencyMs}ms'
            '${best.downloadKBps != null ? ' · ${(best.downloadKBps! / 1024).toStringAsFixed(2)} MB/s' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.fontSizeXs, color: TvDesignTokens.brand),
          ),
      ],
    );
  }

  // ===== 复用控件（TV 焦点向）=====

  Widget _rowCard(
    TvMetrics m, {
    required String title,
    String? subtitle,
    required Widget trailing,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      padding: const EdgeInsets.all(4),
      onSelect: onSelect,
      child: Container(
        padding: EdgeInsets.all(m.spacingMd),
        margin: EdgeInsets.only(bottom: m.spacingSm),
        decoration: BoxDecoration(
          color: TvDesignTokens.surfaceElevated,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textPrimary)),
                  if (subtitle != null) ...[
                    SizedBox(height: m.s(2)),
                    Text(subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.fontSizeXs,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ],
              ),
            ),
            SizedBox(width: m.spacingMd),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _actionRow(
    TvMetrics m, {
    required IconData icon,
    required String title,
    required VoidCallback onSelect,
  }) {
    return _rowCard(
      m,
      title: title,
      trailing: Icon(icon, color: TvDesignTokens.brand, size: m.s(26)),
      onSelect: onSelect,
    );
  }

  Widget _toggleRow(
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
          color: value ? TvDesignTokens.brand : TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: EdgeInsets.all(m.s(3)),
        child: Container(
          width: m.s(24),
          height: m.s(24),
          decoration:
              const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }

  void _showChoice<T>(String title, T current,
      List<MapEntry<String, T>> options, ValueChanged<T> onPick) {
    showDialog<void>(
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

  void _showTextInput(
      String title, String value, ValueChanged<String> onSubmit) {
    final controller = TextEditingController(text: value);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        title:
            Text(title, style: const TextStyle(color: TvDesignTokens.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: TvDesignTokens.textPrimary),
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
}
