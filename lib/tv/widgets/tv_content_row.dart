import 'package:flutter/material.dart';
import '../../core/theme/app_motion.dart';
import '../theme/tv_design_tokens.dart';
import 'tv_focusable.dart';
import 'tv_poster_card.dart';

/// TV 横向内容行
/// 包含标题 + 横向可滚动的海报卡片列表
class TvContentRow extends StatelessWidget {
  final String title;
  final List<TvPosterCardData> items;
  final VoidCallback? onSeeAll;
  final bool autofocusFirstItem;

  const TvContentRow({
    super.key,
    required this.title,
    required this.items,
    this.onSeeAll,
    this.autofocusFirstItem = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 行标题
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: TvDesignTokens.spacingXl,
            vertical: TvDesignTokens.spacingMd,
          ),
          child: Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: TvDesignTokens.fontSizeLg,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (onSeeAll != null) ...[
                const Spacer(),
                TvFocusable(
                  onSelect: onSeeAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TvDesignTokens.spacingMd,
                      vertical: TvDesignTokens.spacingXs,
                    ),
                    child: const Row(
                      children: [
                        Text(
                          '查看全部',
                          style: TextStyle(
                            fontSize: TvDesignTokens.fontSizeSm,
                            color: TvDesignTokens.brand,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: TvDesignTokens.brand,
                          size: 24,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // 横向滚动列表
        SizedBox(
          height: TvDesignTokens.posterHeight16_9 + 60, // 海报 + 文字区域
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: TvDesignTokens.spacingXl,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Padding(
                padding: const EdgeInsets.only(
                  right: TvDesignTokens.posterSpacing,
                ),
                child: TvFocusable(
                  autofocus: autofocusFirstItem && index == 0,
                  onSelect: item.onTap,
                  child: TvPosterCard(
                    imageUrl: item.imageUrl,
                    title: item.title,
                    subtitle: item.subtitle,
                    progress: item.progress,
                    isNew: item.isNew,
                    nextEpisodeLabel: item.nextEpisodeLabel,
                    width: item.width ?? TvDesignTokens.posterWidth16_9,
                    height: item.height ?? TvDesignTokens.posterHeight16_9,
                  ),
                ),
              ).appEntrance(index: index);
            },
          ),
        ),
      ],
    );
  }
}

/// TV 海报卡片数据模型
class TvPosterCardData {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double? progress;
  final bool isNew;
  final String? nextEpisodeLabel;
  final double? width;
  final double? height;
  final VoidCallback? onTap;

  const TvPosterCardData({
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.progress,
    this.isNew = false,
    this.nextEpisodeLabel,
    this.width,
    this.height,
    this.onTap,
  });
}
