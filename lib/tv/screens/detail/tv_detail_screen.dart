import 'package:flutter/material.dart';
import '../../../core/theme/app_motion.dart';
import '../../theme/tv_design_tokens.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_toast.dart';
import '../../widgets/tv_panel.dart';

/// TV 详情页（剧/电影）
/// Hero 区域 + 信息 + 操作按钮 + 季选择 + 集列表
class TvDetailScreen extends StatefulWidget {
  final String? mediaId;

  const TvDetailScreen({super.key, this.mediaId});

  @override
  State<TvDetailScreen> createState() => _TvDetailScreenState();
}

class _TvDetailScreenState extends State<TvDetailScreen> {
  int _selectedSeason = 0;
  bool _isFavorited = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero 区域（占内容区 40%）
            _buildHeroArea(),
            // 内容区
            Padding(
              padding: const EdgeInsets.all(TvDesignTokens.spacingXl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 操作按钮
                  _buildActionButtons(),
                  const SizedBox(height: TvDesignTokens.spacingLg),
                  // 简介
                  _buildSynopsis(),
                  const SizedBox(height: TvDesignTokens.spacingLg),
                  // 季选择（如果是剧集）
                  _buildSeasonSelector(),
                  const SizedBox(height: TvDesignTokens.spacingLg),
                  // 集列表
                  _buildEpisodeList(),
                  const SizedBox(height: TvDesignTokens.spacingXxl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroArea() {
    return SizedBox(
      height: 400,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景图
          Container(
            color: TvDesignTokens.surfaceElevated,
            child: const Center(
              child: Icon(
                Icons.image_not_supported_outlined,
                color: TvDesignTokens.textDisabled,
                size: 64,
              ),
            ),
          ),
          // 渐变遮罩
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  TvDesignTokens.background.withOpacity(0.8),
                  TvDesignTokens.background,
                ],
                stops: const [0.5, 0.8, 1.0],
              ),
            ),
          ),
          // 信息
          Positioned(
            left: TvDesignTokens.spacingXl,
            right: TvDesignTokens.spacingXl,
            bottom: TvDesignTokens.spacingLg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '剧集标题',
                  style: const TextStyle(
                    fontSize: TvDesignTokens.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: TvDesignTokens.spacingSm),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: TvDesignTokens.spacingSm,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: TvDesignTokens.brand,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '9.2',
                        style: TextStyle(
                          fontSize: TvDesignTokens.fontSizeSm,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: TvDesignTokens.spacingMd),
                    const Text(
                      '2024 · 剧情 · 悬疑',
                      style: TextStyle(
                        fontSize: TvDesignTokens.fontSizeSm,
                        color: TvDesignTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        // 播放按钮
        TvFocusable(
          autofocus: true,
          onSelect: () => TvToast.show(context, '开始播放'),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: TvDesignTokens.spacingLg,
              vertical: TvDesignTokens.spacingSm,
            ),
            decoration: BoxDecoration(
              color: TvDesignTokens.brand,
              borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 28,
                ),
                SizedBox(width: TvDesignTokens.spacingSm),
                Text(
                  '播放',
                  style: TextStyle(
                    fontSize: TvDesignTokens.fontSizeMd,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: TvDesignTokens.spacingMd),
        // 收藏按钮
        TvFocusable(
          onSelect: () {
            setState(() => _isFavorited = !_isFavorited);
            TvToast.show(context, _isFavorited ? '已收藏' : '取消收藏');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: TvDesignTokens.spacingLg,
              vertical: TvDesignTokens.spacingSm,
            ),
            decoration: BoxDecoration(
              color: TvDesignTokens.surface,
              borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
            ),
            child: Row(
              children: [
                Icon(
                  _isFavorited ? Icons.favorite : Icons.favorite_border,
                  color: _isFavorited ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
                  size: 28,
                ),
                const SizedBox(width: TvDesignTokens.spacingSm),
                Text(
                  _isFavorited ? '已收藏' : '收藏',
                  style: TextStyle(
                    fontSize: TvDesignTokens.fontSizeMd,
                    color: TvDesignTokens.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: TvDesignTokens.spacingMd),
        // 更多按钮
        TvFocusable(
          onSelect: () => _showMorePanel(),
          child: Container(
            padding: const EdgeInsets.all(TvDesignTokens.spacingSm),
            decoration: BoxDecoration(
              color: TvDesignTokens.surface,
              borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
            ),
            child: const Icon(
              Icons.more_vert,
              color: TvDesignTokens.textPrimary,
              size: 28,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSynopsis() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '简介',
          style: TextStyle(
            fontSize: TvDesignTokens.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: TvDesignTokens.spacingSm),
        const Text(
          '这是一部精彩的剧集，讲述了令人着迷的故事。剧情扣人心弦，演员表现出色，制作精良。',
          style: TextStyle(
            fontSize: TvDesignTokens.fontSizeSm,
            color: TvDesignTokens.textSecondary,
            height: TvDesignTokens.lineHeightRelaxed,
          ),
        ),
      ],
    );
  }

  Widget _buildSeasonSelector() {
    // TODO: 从 Provider 获取季列表
    final seasons = ['第 1 季', '第 2 季', '第 3 季'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '选择季',
          style: TextStyle(
            fontSize: TvDesignTokens.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: TvDesignTokens.spacingSm),
        SizedBox(
          height: 48,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: seasons.length,
            itemBuilder: (context, index) {
              final isSelected = _selectedSeason == index;
              return Padding(
                padding: const EdgeInsets.only(right: TvDesignTokens.spacingSm),
                child: TvFocusable(
                  onSelect: () => setState(() => _selectedSeason = index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TvDesignTokens.spacingMd,
                      vertical: TvDesignTokens.spacingXs,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? TvDesignTokens.brand.withOpacity(0.15)
                          : TvDesignTokens.surface,
                      borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                      border: isSelected
                          ? Border.all(color: TvDesignTokens.brand, width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        seasons[index],
                        style: TextStyle(
                          fontSize: TvDesignTokens.fontSizeSm,
                          color: isSelected ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodeList() {
    // TODO: 从 Provider 获取集列表
    final episodes = List.generate(10, (index) => '第 ${index + 1} 集');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '第 ${_selectedSeason + 1} 季 · 共 ${episodes.length} 集',
          style: const TextStyle(
            fontSize: TvDesignTokens.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: TvDesignTokens.spacingSm),
        ...episodes.asMap().entries.map((entry) {
          final index = entry.key;
          final episode = entry.value;
          return TvFocusable(
            onSelect: () => TvToast.show(context, '播放 $episode'),
            child: Container(
              padding: const EdgeInsets.all(TvDesignTokens.spacingMd),
              margin: const EdgeInsets.only(bottom: TvDesignTokens.spacingSm),
              decoration: BoxDecoration(
                color: TvDesignTokens.surface,
                borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
              ),
              child: Row(
                children: [
                  Container(
                    width: 120,
                    height: 67,
                    decoration: BoxDecoration(
                      color: TvDesignTokens.surfaceElevated,
                      borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          fontSize: TvDesignTokens.fontSizeLg,
                          color: TvDesignTokens.textDisabled,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: TvDesignTokens.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          episode,
                          style: const TextStyle(
                            fontSize: TvDesignTokens.fontSizeMd,
                            color: TvDesignTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: TvDesignTokens.spacingXs),
                        const Text(
                          '45 分钟',
                          style: TextStyle(
                            fontSize: TvDesignTokens.fontSizeSm,
                            color: TvDesignTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.play_circle_outline,
                    color: TvDesignTokens.brand,
                    size: 32,
                  ),
                ],
              ),
            ),
          ).appEntrance(index: index);
        }),
      ],
    );
  }

  void _showMorePanel() {
    showDialog(
      context: context,
      builder: (context) => TvPanel(
        title: '更多',
        onClose: () => Navigator.pop(context),
        children: [
          const TvPanelSection(title: '播放设置'),
          TvPanelOption(
            title: '倍速',
            subtitle: '1.0x',
            onTap: () {},
          ),
          TvPanelOption(
            title: '画面比例',
            subtitle: '默认',
            onTap: () {},
          ),
          const TvPanelSection(title: '轨道'),
          TvPanelOption(
            title: '字幕',
            subtitle: '中文',
            onTap: () {},
          ),
          TvPanelOption(
            title: '音轨',
            subtitle: '原声',
            onTap: () {},
          ),
          const TvPanelSection(title: '其他'),
          TvPanelOption(
            title: '投屏',
            onTap: () {},
          ),
          TvPanelOption(
            title: '统计信息',
            onTap: () {},
          ),
        ],
      ),
    );
  }
}
