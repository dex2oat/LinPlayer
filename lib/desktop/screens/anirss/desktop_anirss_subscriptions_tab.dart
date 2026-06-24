import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_match.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/screens/anirss/anirss_download_widgets.dart';
import '../../../ui/widgets/anirss/anirss_add_subscription_body.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/native_feedback.dart';

/// 桌面端 Ani-rss 订阅页：添加订阅入口 + 下载进度监控（按订阅聚合，精确到每集）。
class DesktopAniRssSubscriptionsTab extends ConsumerWidget {
  const DesktopAniRssSubscriptionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(aniListProvider);
    final asyncTorrents = ref.watch(torrentsProvider);

    return Column(
      children: [
        _Toolbar(
          onAdd: () => _showAddDialog(context, ref),
          onRefreshAll: () async {
            final api = ref.read(aniRssApiProvider);
            if (api == null) return;
            await api.refreshAll();
            if (context.mounted) {
              showDesktopMessage(context, '已触发全部订阅刷新');
            }
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: asyncList.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (anis) {
              final torrents = asyncTorrents.valueOrNull ?? const [];
              final match = matchTorrents(anis, torrents);
              return _SubscriptionList(anis: anis, match: match);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return Future.value();
    return showDialog<void>(
      context: context,
      builder: (_) => _AddSubscriptionDialog(api: api, parentRef: ref),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final VoidCallback onAdd;
  final Future<void> Function() onRefreshAll;
  const _Toolbar({required this.onAdd, required this.onRefreshAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('搜索并添加订阅'),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onRefreshAll,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('刷新全部'),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionList extends ConsumerWidget {
  final List<AniModel> anis;
  final TorrentMatchResult match;
  const _SubscriptionList({required this.anis, required this.match});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 有活动下载的订阅排前面。
    final sorted = [...anis]..sort((a, b) {
        final ai = (match.byAni[a.id]?.isNotEmpty ?? false) ? 0 : 1;
        final bi = (match.byAni[b.id]?.isNotEmpty ?? false) ? 0 : 1;
        return ai.compareTo(bi);
      });
    final unmatched = match.unmatched;

    return DesktopSmoothScrollBuilder(
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        children: [
          for (final ani in sorted)
            SubscriptionTile(
              ani: ani,
              episodes: match.byAni[ani.id] ?? const [],
              onRefresh: () => _refresh(context, ref, ani),
              onDelete: (deleteFiles) =>
                  _delete(context, ref, ani, deleteFiles),
              onToggleEnable: () => _toggle(context, ref, ani),
            ),
          if (unmatched.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
              child: Text('未匹配下载',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final t in unmatched) UnmatchedTorrentTile(torrent: t),
          ],
        ],
      ),
    );
  }

  Future<void> _refresh(
      BuildContext context, WidgetRef ref, AniModel ani) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.refreshAni(ani.id);
    if (context.mounted) {
      showDesktopMessage(context, '已刷新「${ani.title}」');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, AniModel ani,
      bool deleteFiles) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.deleteAni([ani.id], deleteFiles: deleteFiles);
    ref.invalidate(aniListProvider);
    if (context.mounted) {
      showDesktopMessage(context, '已删除「${ani.title}」');
    }
  }

  Future<void> _toggle(
      BuildContext context, WidgetRef ref, AniModel ani) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.batchEnable([ani.id], !ani.enable);
    ref.invalidate(aniListProvider);
  }
}

/// 桌面端「添加订阅」对话框：复用多搜索源主体（BGM / Mikan / AniBT / AnimeGarden / RSS
/// + previewAni 预览），桌面仅负责包一个 Dialog 外壳。
class _AddSubscriptionDialog extends StatelessWidget {
  final AniRssApi api;
  final WidgetRef parentRef;
  const _AddSubscriptionDialog({required this.api, required this.parentRef});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: AniRssAddSubscriptionBody(
            api: api,
            parentRef: parentRef,
            onAdded: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }
}
