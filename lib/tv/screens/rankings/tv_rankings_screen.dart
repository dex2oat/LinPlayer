import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/ranking/ranking_models.dart';
import '../../../core/providers/ranking_providers.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../../ui/widgets/common/ranking_entry_panel.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_poster_card.dart';

/// TV 排行榜（Netflix 式横向焦点导轨）。每个分类一行，D-pad 上下切行、左右滚动。
class TvRankingsScreen extends ConsumerWidget {
  const TvRankingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final service = ref.watch(rankingServiceProvider);
    final categories = service.availableCategories;

    if (categories.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.leaderboard_outlined,
                size: m.s(72), color: TvDesignTokens.textSecondary),
            SizedBox(height: m.spacingMd),
            Text('当前版本未配置排行榜数据源',
                style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.textSecondary)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.symmetric(vertical: m.spacingLg),
      itemCount: categories.length,
      itemBuilder: (context, index) => _RankingRail(
        category: categories[index],
        autofocusFirst: index == 0,
      ),
    );
  }
}

class _RankingRail extends ConsumerWidget {
  const _RankingRail({required this.category, required this.autofocusFirst});

  final RankingCategory category;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final async = ref.watch(rankingListProvider(category.id));
    final width = m.posterWidth2_3;
    final height = m.posterHeight2_3;
    // 行高 = 海报 + 标题两行 + 名次留白余量。
    final rowHeight = height + m.s(78);

    Widget railBody;
    railBody = async.when(
      loading: () => _placeholderRow(m, width, height),
      error: (_, __) => SizedBox(
        height: rowHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: m.spacingXl),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('加载失败',
                style: TextStyle(
                    color: TvDesignTokens.textSecondary,
                    fontSize: m.fontSizeSm)),
          ),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return SizedBox(
            height: rowHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: m.spacingXl),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无数据',
                    style: TextStyle(
                        color: TvDesignTokens.textSecondary,
                        fontSize: m.fontSizeSm)),
              ),
            ),
          );
        }
        return SizedBox(
          height: rowHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: m.spacingXl),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final e = items[i];
              return Padding(
                padding: EdgeInsets.only(right: m.posterSpacing),
                child: TvFocusable(
                  autofocus: autofocusFirst && i == 0,
                  onSelect: () => showRankingEntryDialog(context, e),
                  child: _RankPoster(
                    entry: e,
                    width: width,
                    height: height,
                  ),
                ),
              );
            },
          ),
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              m.spacingXl, m.spacingMd, m.spacingXl, m.spacingSm),
          child: Row(
            children: [
              Text(
                category.group.label,
                style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.brand,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: m.spacingSm),
              Text(
                category.label,
                style: TextStyle(
                  fontSize: m.fontSizeLg,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        railBody,
      ],
    );
  }

  Widget _placeholderRow(TvMetrics m, double width, double height) {
    return SizedBox(
      height: height + m.s(78),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: m.spacingXl),
        itemCount: 6,
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.only(right: m.posterSpacing),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: TvDesignTokens.surfaceElevated,
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
          ),
        ),
      ),
    );
  }
}

/// 海报 + 名次角标。
class _RankPoster extends StatelessWidget {
  const _RankPoster({
    required this.entry,
    required this.width,
    required this.height,
  });

  final RankingEntry entry;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final accent = _rankColor(entry.rank);
    return Stack(
      children: [
        TvPosterCard(
          imageUrl: entry.imageUrl,
          title: entry.title,
          subtitle: entry.rating != null && entry.rating! > 0
              ? '★ ${entry.rating!.toStringAsFixed(1)}'
              : entry.subtitle,
          width: width,
          height: height,
        ),
        Positioned(
          left: 0,
          top: 0,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: m.s(12), vertical: m.s(4)),
            decoration: BoxDecoration(
              color: (accent ?? Colors.black).withValues(alpha: 0.82),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(m.posterRadius),
                bottomRight: Radius.circular(m.s(12)),
              ),
            ),
            child: Text(
              '${entry.rank}',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: m.fontSizeSm,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Color? _rankColor(int rank) => switch (rank) {
      1 => const Color(0xFFFFC107),
      2 => const Color(0xFFB0BEC5),
      3 => const Color(0xFFCD7F32),
      _ => null,
    };
