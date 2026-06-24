import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_match.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/screens/anirss/anirss_download_widgets.dart';
import '../../../ui/widgets/anirss/anirss_add_subscription_body.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/anirss/desktop_anirss_edit_dialog.dart';
import '../../widgets/native_feedback.dart';

/// 桌面端 Ani-rss 订阅页——对标 ani-rss 原版 PC 界面。
///
/// 每个订阅 = 一张横向卡（海报 + 标题 + 标签：季/启用/字幕组/集数进度/类型 + 操作：
/// 编辑/刷新/启停/删除）；有下载任务时卡内内联进度条。编辑走完整的「基本/自定义」对话框。
class DesktopAniRssSubscriptionsTab extends ConsumerStatefulWidget {
  const DesktopAniRssSubscriptionsTab({super.key});

  @override
  ConsumerState<DesktopAniRssSubscriptionsTab> createState() =>
      _DesktopAniRssSubscriptionsTabState();
}

class _DesktopAniRssSubscriptionsTabState
    extends ConsumerState<DesktopAniRssSubscriptionsTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
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
            if (context.mounted) showDesktopMessage(context, '已触发全部订阅刷新');
          },
          onSearch: (v) => setState(() => _query = v.trim()),
        ),
        const Divider(height: 1),
        Expanded(
          child: asyncList.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (anis) {
              final torrents = asyncTorrents.valueOrNull ?? const [];
              final match = matchTorrents(anis, torrents);
              return _SubscriptionGrid(anis: anis, match: match, query: _query);
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
  final ValueChanged<String> onSearch;
  const _Toolbar({
    required this.onAdd,
    required this.onRefreshAll,
    required this.onSearch,
  });

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
          const Spacer(),
          SizedBox(
            width: 240,
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索订阅…',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: onSearch,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionGrid extends ConsumerWidget {
  final List<AniModel> anis;
  final TorrentMatchResult match;
  final String query;
  const _SubscriptionGrid(
      {required this.anis, required this.match, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var list = anis;
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      list = anis
          .where((a) =>
              a.title.toLowerCase().contains(q) ||
              (a.subgroup?.toLowerCase().contains(q) ?? false))
          .toList();
    }
    // 有活动下载的订阅排前面。
    final sorted = [...list]..sort((a, b) {
        final ai = (match.byAni[a.id]?.isNotEmpty ?? false) ? 0 : 1;
        final bi = (match.byAni[b.id]?.isNotEmpty ?? false) ? 0 : 1;
        return ai.compareTo(bi);
      });
    final unmatched = match.unmatched;

    if (sorted.isEmpty && unmatched.isEmpty) {
      return Center(
        child: Text(query.isEmpty ? '暂无订阅' : '没有匹配「$query」的订阅'),
      );
    }

    return DesktopSmoothScrollBuilder(
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 440,
                mainAxisExtent: 176,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final ani = sorted[i];
                  return _AniSubscriptionCard(
                    ani: ani,
                    episodes: match.byAni[ani.id] ?? const [],
                    onEdit: () =>
                        showDesktopAniRssEditDialog(context, ref, ani),
                    onRefresh: () => _refresh(context, ref, ani),
                    onToggleEnable: () => _toggle(context, ref, ani),
                    onDelete: (df) => _delete(context, ref, ani, df),
                  );
                },
                childCount: sorted.length,
              ),
            ),
          ),
          if (unmatched.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Text('未匹配下载',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
              sliver: SliverList.builder(
                itemCount: unmatched.length,
                itemBuilder: (_, i) => UnmatchedTorrentTile(torrent: unmatched[i]),
              ),
            ),
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
    if (context.mounted) showDesktopMessage(context, '已刷新「${ani.title}」');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, AniModel ani,
      bool deleteFiles) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.deleteAni([ani.id], deleteFiles: deleteFiles);
    ref.invalidate(aniListProvider);
    if (context.mounted) showDesktopMessage(context, '已删除「${ani.title}」');
  }

  Future<void> _toggle(
      BuildContext context, WidgetRef ref, AniModel ani) async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    await api.batchEnable([ani.id], !ani.enable);
    ref.invalidate(aniListProvider);
  }
}

/// 横向订阅卡：海报 + 标题/标签 + 操作；有下载时内联进度。仿 ani-rss `AniCard.vue`。
class _AniSubscriptionCard extends StatelessWidget {
  final AniModel ani;
  final List<EpisodeProgress> episodes;
  final VoidCallback onEdit;
  final VoidCallback onRefresh;
  final VoidCallback onToggleEnable;
  final void Function(bool deleteFiles) onDelete;

  const _AniSubscriptionCard({
    required this.ani,
    required this.episodes,
    required this.onEdit,
    required this.onRefresh,
    required this.onToggleEnable,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final active = episodes.where((e) => e.progress < 1.0).toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 100,
                  height: 150,
                  child: MediaImage(
                    imageUrl: ani.image,
                    imageUrls: [if (ani.image != null) ani.image!],
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ani.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        _tag('第 ${ani.season ?? 1} 季'),
                        ani.enable
                            ? _tag('已启用', color: const Color(0xFF52B54B))
                            : _tag('未启用', color: Colors.grey),
                        if (ani.subgroup != null)
                          _tag(ani.subgroup!, color: Colors.blueGrey),
                        _tag(
                            '${ani.currentEpisodeNumber ?? 0} / ${(ani.totalEpisodeNumber ?? 0) > 0 ? ani.totalEpisodeNumber : '*'}',
                            color: Colors.orange),
                        _tag(ani.ova ? 'OVA' : 'TV',
                            color: ani.ova
                                ? Colors.redAccent
                                : const Color(0xFF2F6FED)),
                      ],
                    ),
                    if (active.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _ActiveProgress(active: active),
                    ],
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _iconBtn(Icons.edit_outlined, '编辑', onEdit),
                        _iconBtn(Icons.refresh, '刷新', onRefresh),
                        _iconBtn(
                            ani.enable ? Icons.pause : Icons.play_arrow,
                            ani.enable ? '停用' : '启用',
                            onToggleEnable),
                        _iconBtn(Icons.delete_outline, '删除',
                            () => _confirmDelete(context),
                            color: Colors.red),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? Colors.grey).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11,
              color: color ?? Colors.grey,
              fontWeight: FontWeight.w500)),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {Color? color}) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: 19, color: color),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    var deleteFiles = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('删除「${ani.title}」？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('将从 Ani-rss 移除该订阅。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteFiles,
                onChanged: (v) => setState(() => deleteFiles = v ?? false),
                title: const Text('同时删除已下载文件'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除')),
          ],
        ),
      ),
    );
    if (ok == true) onDelete(deleteFiles);
  }
}

/// 卡内下载进度摘要：最多两行集进度。
class _ActiveProgress extends StatelessWidget {
  final List<EpisodeProgress> active;
  const _ActiveProgress({required this.active});

  @override
  Widget build(BuildContext context) {
    final show = active.take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in show)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: e.progress,
                      minHeight: 4,
                      backgroundColor: const Color(0x222F6FED),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text('${(e.progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
          ),
        if (active.length > 2)
          Text('+${active.length - 2} 个下载中',
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
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
