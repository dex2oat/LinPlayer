import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/ranking/ranking_models.dart';
import '../../../core/providers/ranking_providers.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../../ui/widgets/common/ranking_entry_panel.dart';

/// 桌面端排行榜（左侧分类导轨 + 右侧海报网格 + hover 抬升）。风格独立于移动/TV。
class DesktopRankingsScreen extends ConsumerStatefulWidget {
  const DesktopRankingsScreen({super.key});

  @override
  ConsumerState<DesktopRankingsScreen> createState() =>
      _DesktopRankingsScreenState();
}

class _DesktopRankingsScreenState extends ConsumerState<DesktopRankingsScreen> {
  String? _categoryId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = ref.watch(rankingGroupsProvider);

    if (groups.isEmpty) {
      return const Center(
        child: _DesktopEmpty(
            icon: Icons.leaderboard_outlined, text: '当前版本未配置排行榜数据源'),
      );
    }

    // 全部可用分类（跨分组，供左侧导轨列出）。
    final all = <RankingCategory>[
      for (final g in groups) ...ref.watch(rankingCategoriesProvider(g)),
    ];
    final categoryId =
        all.any((c) => c.id == _categoryId) ? _categoryId! : all.first.id;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CategoryRail(
            groups: groups,
            selectedId: categoryId,
            onSelect: (id) => setState(() => _categoryId = id),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      all.firstWhere((c) => c.id == categoryId).label,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '刷新',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: () =>
                          ref.invalidate(rankingListProvider(categoryId)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(child: _Grid(categoryId: categoryId)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.groups,
    required this.selectedId,
    required this.onSelect,
  });

  final List<RankingGroup> groups;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 190,
      child: Consumer(
        builder: (context, ref, _) => ListView(
          children: [
            for (final g in groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                child: Text(
                  g.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              for (final c in ref.watch(rankingCategoriesProvider(g)))
                _RailTile(
                  label: c.label,
                  selected: c.id == selectedId,
                  onTap: () => onSelect(c.id),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RailTile extends StatelessWidget {
  const _RailTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected
                    ? const Color(0xFF5B8DEF)
                    : theme.colorScheme.onSurface,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Grid extends ConsumerWidget {
  const _Grid({required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rankingListProvider(categoryId));
    const delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 172,
      childAspectRatio: 0.54,
      crossAxisSpacing: 18,
      mainAxisSpacing: 20,
    );
    return async.when(
      loading: () => GridView.builder(
        gridDelegate: delegate,
        itemCount: 18,
        itemBuilder: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ShimmerBox(borderRadius: BorderRadius.circular(12)),
            ),
            const SizedBox(height: 8),
            ShimmerBox(
                width: 120, height: 12, borderRadius: BorderRadius.circular(4)),
          ],
        ),
      ),
      error: (e, _) => const _DesktopEmpty(
          icon: Icons.wifi_off_rounded, text: '加载失败，点击右上角刷新'),
      data: (items) {
        if (items.isEmpty) {
          return const _DesktopEmpty(icon: Icons.inbox_outlined, text: '暂无数据');
        }
        return GridView.builder(
          gridDelegate: delegate,
          itemCount: items.length,
          itemBuilder: (context, index) => _PosterCard(entry: items[index]),
        );
      },
    );
  }
}

class _PosterCard extends StatefulWidget {
  const _PosterCard({required this.entry});

  final RankingEntry entry;

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.entry;
    final accent = _rankColor(e.rank);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => showRankingEntryDialog(context, e),
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.fastOutSlowIn,
        transform: _hovered
            ? (Matrix4.identity()..translateByDouble(0.0, -6.0, 0.0, 1.0))
            : Matrix4.identity(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      imageUrl: e.imageUrl,
                      fit: BoxFit.cover,
                      cacheWidth: 344,
                    ),
                    // 名次角标
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: (accent ?? Colors.black).withValues(alpha: 0.82),
                          borderRadius: const BorderRadius.only(
                            bottomRight: Radius.circular(10),
                          ),
                        ),
                        child: Text(
                          '${e.rank}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
                    if (e.rating != null && e.rating! > 0)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.66),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '★ ${e.rating!.toStringAsFixed(1)}',
                            style: const TextStyle(
                              color: Color(0xFFFFD54F),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _hovered ? 1 : 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.35),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              e.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if ((e.subtitle ?? '').isNotEmpty)
              Text(
                e.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

class _DesktopEmpty extends StatelessWidget {
  const _DesktopEmpty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

Color? _rankColor(int rank) => switch (rank) {
      1 => const Color(0xFFFFC107),
      2 => const Color(0xFFB0BEC5),
      3 => const Color(0xFFCD7F32),
      _ => null,
    };
