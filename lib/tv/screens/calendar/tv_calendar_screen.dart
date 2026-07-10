import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/afdian_providers.dart';
import '../../../core/providers/calendar_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/services/afdian_service.dart';
import '../../../core/services/sync/calendar_models.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../ui/widgets/common/ranking_entry_panel.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';

/// TV 端追剧日历（付费解锁）。数据来源在 Trakt / Bangumi 间切换。
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
        padding: EdgeInsets.all(m.spacingXl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('追剧日历',
                style: TextStyle(
                  fontSize: m.fontSizeXxl,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                )),
            SizedBox(height: m.spacingLg),
            Row(children: [
              _sourceChip(m, SyncService.trakt, 'Trakt'),
              SizedBox(width: m.spacingMd),
              _sourceChip(m, SyncService.bangumi, 'Bangumi'),
              const Spacer(),
              TvFocusable(
                onSelect: () => setState(() => _onlyMine = !_onlyMine),
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: m.spacingLg, vertical: m.spacingMd),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surface,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Text(_onlyMine ? '只看我追的' : '整季全部',
                      style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textPrimary,
                      )),
                ),
              ),
            ]),
            SizedBox(height: m.spacingLg),
            Expanded(
              child: connected
                  ? _list(m)
                  : Center(
                      child: Text('未连接 ${_source.displayName}，请先到「设置 → 同步」连接',
                          style: const TextStyle(
                              color: TvDesignTokens.textSecondary)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(TvMetrics m, SyncService s, String label) {
    final active = s == _source;
    return TvFocusable(
      onSelect: () => _select(s),
      child: Container(
        padding:
            EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingMd),
        decoration: BoxDecoration(
          color: active ? TvDesignTokens.brand : TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: m.fontSizeMd,
              color: active ? Colors.white : TvDesignTokens.textPrimary,
            )),
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
          return const Center(
            child: Text('暂无放送数据（Bangumi 仅显示在看中当季正在放送的番）',
                style: TextStyle(color: TvDesignTokens.textSecondary)),
          );
        }
        final sections = groupCalendarEntries(entries);
        return ListView.builder(
          itemCount: sections.length,
          itemBuilder: (context, i) {
            final sec = sections[i];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: m.spacingMd),
                  child: Text(
                    sec.isToday ? '${sec.header}（今天）' : sec.header,
                    style: TextStyle(
                      fontSize: m.fontSizeLg,
                      color: sec.isToday
                          ? TvDesignTokens.brand
                          : TvDesignTokens.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ...sec.items.map((e) => _entry(m, e)),
              ],
            );
          },
        );
      },
    );
  }

  Widget _entry(TvMetrics m, CalendarEntry e) {
    return TvFocusable(
      onSelect: () => showCrossServerLookup(
        context,
        title: e.title,
        imageUrl: e.imageUrl,
        subtitle: e.subtitle,
        dialog: true,
      ),
      child: Container(
        padding: EdgeInsets.all(m.spacingMd),
        margin: EdgeInsets.only(bottom: m.spacingSm),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            if (e.imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(m.s(4)),
                child: Image.network(e.imageUrl!,
                    width: m.s(40),
                    height: m.s(56),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            if (e.imageUrl != null) SizedBox(width: m.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textPrimary,
                      )),
                  if (e.subtitle != null)
                    Text(e.subtitle!,
                        style: TextStyle(
                          fontSize: m.fontSizeSm,
                          color: TvDesignTokens.textSecondary,
                        )),
                ],
              ),
            ),
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
        TextField(
          controller: _controller,
          style: const TextStyle(color: TvDesignTokens.textPrimary),
          decoration: const InputDecoration(
            hintText: '订单号 (out_trade_no)',
            filled: true,
            fillColor: TvDesignTokens.background,
            border: OutlineInputBorder(),
          ),
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
