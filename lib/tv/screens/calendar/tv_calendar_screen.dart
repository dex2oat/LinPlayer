import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/afdian_providers.dart';
import '../../../core/providers/calendar_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/services/afdian_service.dart';
import '../../../core/services/sync/calendar_models.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../../ui/widgets/common/ranking_entry_panel.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_text_field.dart';

/// TV 端追剧日历（付费解锁，观感对齐移动端）。顶部 Trakt/Bangumi 分段 + 只看我追的/
/// 刷新动作，下方按日分组的条目卡片。数据/门控逻辑保持不变，仅重绘 build。
class TvCalendarScreen extends ConsumerStatefulWidget {
  const TvCalendarScreen({super.key});

  @override
  ConsumerState<TvCalendarScreen> createState() => _TvCalendarScreenState();
}

class _TvCalendarScreenState extends ConsumerState<TvCalendarScreen> {
  late SyncService _source;
  bool _onlyMine = true;

  @override
  void initState() {
    super.initState();
    _source = calendarSourceOf(ref.read(calendarSourceProvider));
  }

  void _select(SyncService s) {
    if (s == _source) return;
    setState(() => _source = s);
    ref.read(calendarSourceProvider.notifier).state = s.name;
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final connected = ref.watch(syncControllerProvider).isConnected(_source);
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Padding(
        padding: EdgeInsets.fromLTRB(m.spacingXl, m.spacingXl, m.spacingXl, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('追剧日历',
                    style: TextStyle(
                      fontSize: m.fontSizeXxl,
                      color: TvDesignTokens.textPrimary,
                      fontWeight: FontWeight.bold,
                    )),
                const Spacer(),
                _actionChip(
                  m,
                  _onlyMine ? Icons.person : Icons.public,
                  _onlyMine ? '只看我追的' : '整季全部',
                  onSelect: () => setState(() => _onlyMine = !_onlyMine),
                ),
                SizedBox(width: m.spacingMd),
                _actionChip(
                  m,
                  Icons.refresh,
                  '刷新',
                  onSelect: () => ref.invalidate(calendarEntriesProvider(
                      (source: _source, onlyMine: _onlyMine))),
                ),
              ],
            ),
            SizedBox(height: m.spacingLg),
            Row(
              children: [
                _sourceChip(m, SyncService.trakt, 'Trakt',
                    Icons.movie_outlined, autofocus: true),
                SizedBox(width: m.spacingMd),
                _sourceChip(m, SyncService.bangumi, 'Bangumi',
                    Icons.animation_outlined),
              ],
            ),
            SizedBox(height: m.spacingLg),
            Expanded(
              child: connected ? _list(m) : _notConnected(m),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(TvMetrics m, SyncService s, String label, IconData icon,
      {bool autofocus = false}) {
    final active = s == _source;
    return TvFocusable(
      autofocus: autofocus,
      onSelect: () => _select(s),
      padding: EdgeInsets.all(m.spacingXs),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: m.spacingLg, vertical: m.spacingSm),
        decoration: BoxDecoration(
          color: active ? TvDesignTokens.brand : TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.s(22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: m.s(20),
                color: active ? Colors.white : TvDesignTokens.textSecondary),
            SizedBox(width: m.spacingSm),
            Text(label,
                style: TextStyle(
                  fontSize: m.fontSizeMd,
                  color: active ? Colors.white : TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      ),
    );
  }

  Widget _actionChip(TvMetrics m, IconData icon, String label,
      {required VoidCallback onSelect}) {
    return TvFocusable(
      onSelect: onSelect,
      padding: EdgeInsets.all(m.spacingXs),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: m.spacingLg, vertical: m.spacingSm),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.s(22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: m.s(20), color: TvDesignTokens.textSecondary),
            SizedBox(width: m.spacingSm),
            Text(label,
                style: TextStyle(
                  fontSize: m.fontSizeMd,
                  color: TvDesignTokens.textPrimary,
                )),
          ],
        ),
      ),
    );
  }

  Widget _notConnected(TvMetrics m) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_off,
              size: m.s(56), color: TvDesignTokens.textSecondary),
          SizedBox(height: m.spacingMd),
          Text('未连接 ${_source.displayName}',
              style: TextStyle(
                  fontSize: m.fontSizeMd, color: TvDesignTokens.textPrimary)),
          SizedBox(height: m.spacingXs),
          Text('请先到「设置 → 同步」连接账号',
              style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.textSecondary)),
        ],
      ),
    );
  }

  Widget _list(TvMetrics m) {
    final async = ref
        .watch(calendarEntriesProvider((source: _source, onlyMine: _onlyMine)));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
          child: Text('加载失败：$e',
              style: const TextStyle(color: TvDesignTokens.textSecondary))),
      data: (entries) {
        if (entries.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(m.spacingLg),
              child: const Text(
                '暂无放送数据（Bangumi 仅显示在看中当季正在放送的番）',
                textAlign: TextAlign.center,
                style: TextStyle(color: TvDesignTokens.textSecondary),
              ),
            ),
          );
        }
        final sections = groupCalendarEntries(entries);
        // TV 横向布局：一天一列并排，整体横向滚动，每列内部纵向滚动。
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final sec in sections)
                Container(
                  width: m.s(360),
                  margin: EdgeInsets.only(right: m.spacingLg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _dayHeader(m, sec),
                      SizedBox(height: m.spacingSm),
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.only(bottom: m.spacingXl),
                          children: [
                            for (final e in sec.items) _entry(m, e),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _dayHeader(TvMetrics m, CalendarSection sec) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: m.spacingMd),
      child: Row(
        children: [
          Flexible(
            child: Text(
              sec.header,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: sec.isToday
                    ? TvDesignTokens.brand
                    : TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (sec.isToday) ...[
            SizedBox(width: m.spacingSm),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: m.spacingSm, vertical: m.spacingXs / 2),
              decoration: BoxDecoration(
                color: TvDesignTokens.brand.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(m.s(6)),
              ),
              child: Text('今天',
                  style: TextStyle(
                      fontSize: m.fontSizeXs, color: TvDesignTokens.brand)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _entry(TvMetrics m, CalendarEntry e) {
    final img = e.imageUrl;
    final time = e.airDate != null
        ? '${e.airDate!.hour.toString().padLeft(2, '0')}:'
            '${e.airDate!.minute.toString().padLeft(2, '0')}'
        : null;
    return TvFocusable(
      onSelect: () => showCrossServerLookup(
        context,
        title: e.title,
        imageUrl: img,
        subtitle: e.subtitle,
        dialog: true,
      ),
      padding:
          EdgeInsets.symmetric(vertical: m.spacingXs, horizontal: m.spacingSm),
      child: Container(
        padding: EdgeInsets.all(m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(m.s(6)),
              child: MediaImage(
                imageUrl: img,
                width: m.s(48),
                height: m.s(68),
                fit: BoxFit.cover,
                cacheWidth: 140,
              ),
            ),
            SizedBox(width: m.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(e.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textPrimary,
                      )),
                  if (e.subtitle != null && e.subtitle!.isNotEmpty) ...[
                    SizedBox(height: m.spacingXs),
                    Text(e.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.fontSizeSm,
                          color: TvDesignTokens.textSecondary,
                        )),
                  ],
                ],
              ),
            ),
            if (time != null) ...[
              SizedBox(width: m.spacingSm),
              Text(time,
                  style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}

/// TV 端爱发电订单解锁面板。校验成功后 pop(true)。
class TvAfdianUnlockPanel extends ConsumerStatefulWidget {
  const TvAfdianUnlockPanel({super.key});

  @override
  ConsumerState<TvAfdianUnlockPanel> createState() =>
      _TvAfdianUnlockPanelState();
}

class _TvAfdianUnlockPanelState extends ConsumerState<TvAfdianUnlockPanel> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final orderNo = _controller.text.trim();
    if (orderNo.isEmpty) {
      setState(() => _error = '请输入订单号');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await ref.read(afdianServiceProvider).verifyOrder(orderNo);
    if (!mounted) return;
    if (result.valid) {
      ref.read(afdianOrderProvider.notifier).state = orderNo;
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = result.reason ?? '校验未通过';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return TvPanel(
      title: '解锁追剧日历',
      onClose: () => Navigator.of(context).pop(false),
      children: [
        const Text('在爱发电赞助任意金额即可解锁。赞助后在「我的 → 订单」复制订单号，输入下方校验。',
            style: TextStyle(color: TvDesignTokens.textSecondary)),
        SizedBox(height: m.spacingMd),
        const Text('赞助页：$kAfdianSponsorUrl',
            style: TextStyle(color: TvDesignTokens.textSecondary)),
        SizedBox(height: m.spacingLg),
        TvTextField(
          controller: _controller,
          hint: '订单号 (out_trade_no)',
        ),
        SizedBox(height: m.spacingLg),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          SizedBox(height: m.spacingMd),
        ],
        TvPanelOption(
          title: _submitting ? '校验中…' : '校验并解锁',
          onTap: _submitting ? null : _submit,
        ),
      ],
    );
  }
}
