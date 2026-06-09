import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/color_extractor.dart';

import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/desktop_media_card.dart';

/// 桌面端媒体详情页（剧/电影通用）
class DesktopMediaDetailScreen extends ConsumerWidget {
  final String itemId;

  const DesktopMediaDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemAsync = ref.watch(mediaItemProvider(itemId));

    return Scaffold(
      body: itemAsync.when(
        data: (item) => _DetailContent(item: item, itemId: itemId),
        loading: () => const _SkeletonView(),
        error: (error, _) => _ErrorView(
          error: error,
          onRetry: () => ref.invalidate(mediaItemProvider(itemId)),
        ),
      ),
    );
  }
}

// ============================================================================
// 主内容区
// ============================================================================

class _DetailContent extends ConsumerStatefulWidget {
  final MediaItem item;
  final String itemId;

  const _DetailContent({required this.item, required this.itemId});

  @override
  ConsumerState<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends ConsumerState<_DetailContent> {
  late Color _backgroundColor;
  late Color _dominantColor;
  Color _primaryColor = AppColors.brand;
  Color? _extractedBackgroundColor;
  Brightness? _lastBrightness;

  final ScrollController _scrollController = DesktopSmoothScrollController();

  @override
  void initState() {
    super.initState();
    _backgroundColor = _defaultSurfaceColor(context);
    _dominantColor = _defaultSurfaceColor(context);
    _lastBrightness = Theme.of(context).brightness;
    _extractColor();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness == brightness) {
      return;
    }

    _lastBrightness = brightness;
    _backgroundColor = _extractedBackgroundColor != null
        ? _blendWithThemeSurface(_extractedBackgroundColor!)
        : _defaultSurfaceColor(context);
    if (_extractedBackgroundColor == null) {
      _dominantColor = _defaultSurfaceColor(context);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isDarkTheme => Theme.of(context).brightness == Brightness.dark;

  Color _defaultSurfaceColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _isDarkTheme ? colorScheme.surface : colorScheme.surfaceContainerLowest;
  }

  Color _blendWithThemeSurface(Color extracted) {
    final baseSurface = _defaultSurfaceColor(context);
    final blendRatio = _isDarkTheme ? 0.72 : 0.18;
    return Color.lerp(baseSurface, extracted, blendRatio) ?? extracted;
  }

  String get _seriesContextId {
    if (widget.item.type == 'Season') {
      return widget.item.seriesId ?? widget.item.parentId ?? widget.itemId;
    }
    return widget.itemId;
  }

  Future<void> _extractColor() async {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      widget.item,
      maxWidth: 1920,
    );
    final imageUrl = imageUrls.isNotEmpty ? imageUrls.first : null;

    if (imageUrl == null) return;

    final colors = await ColorExtractor.extractFromUrl(imageUrl);
    if (mounted) {
      setState(() {
        _dominantColor = colors.gradientStart;
        _extractedBackgroundColor = colors.background;
        _backgroundColor = _blendWithThemeSurface(colors.background);
        _primaryColor = colors.primary;
      });
    }
  }

  void _handleRefresh() {
    ref.invalidate(mediaItemProvider(widget.itemId));
    ref.invalidate(seasonsProvider(_seriesContextId));
    ref.invalidate(episodesProvider((
      seriesId: _seriesContextId,
      seasonId: widget.item.type == 'Season' ? widget.itemId : null,
    )));
    ref.invalidate(similarItemsProvider(widget.itemId));
  }

  void _handleRematch() async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colorScheme.surface,
        title: const Text('重新匹配'),
        content: const Text('这将重新获取该媒体的元数据，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // TODO: 调用 Emby 刷新元数据 API
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          _handleRefresh();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已开始重新匹配')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('重新匹配失败: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleFactor = (screenWidth / 1440.0).clamp(0.7, 1.3);
    final theme = Theme.of(context);

    // 响应式内边距
    final horizontalPadding = screenWidth > 1600
        ? 48.0
        : screenWidth > 1200
            ? 32.0
            : 24.0;

    // 基准尺寸（基于1440px设计稿）
    const basePosterHeight = 320.0;
    final posterHeight = basePosterHeight * scaleFactor;
    final posterWidth = posterHeight * (2 / 3);
    const overlap = 48.0;
    final heroHeight = (32.0 + posterHeight - overlap * 0.6) * scaleFactor;
    const contentMaxWidth = 1440.0;

    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: _backgroundColor,
      ),
      child: Scaffold(
        backgroundColor: _backgroundColor,
        body: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (context.canPop()) context.pop();
            },
          },
          child: Focus(
            autofocus: true,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                // Hero 区域
                SliverToBoxAdapter(
                  child: _HeroSection(
                    item: widget.item,
                    itemId: widget.itemId,
                    backgroundColor: _backgroundColor,
                    dominantColor: _dominantColor,
                    heroHeight: heroHeight,
                    posterHeight: posterHeight,
                    posterWidth: posterWidth,
                    overlap: overlap,
                    horizontalPadding: horizontalPadding,
                    contentMaxWidth: contentMaxWidth,
                    onRefresh: _handleRefresh,
                    onRematch: _handleRematch,
                    scaleFactor: scaleFactor,
                  ),
                ),

                // 内容区
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: contentMaxWidth),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPadding,
                        ),
                        child: _InfoSection(
                          item: widget.item,
                          itemId: widget.itemId,
                          backgroundColor: _backgroundColor,
                          primaryColor: _primaryColor,
                          posterWidth: posterWidth,
                          overlap: overlap,
                          scaleFactor: scaleFactor,
                        ),
                      ),
                    ),
                  ),
                ),

                // 底部安全区域
                const SliverPadding(padding: EdgeInsets.only(bottom: 64)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _detailUsesDarkTheme(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark;
}

Color _detailSurface(BuildContext context, {double level = 0.0}) {
  final colorScheme = Theme.of(context).colorScheme;
  final base = _detailUsesDarkTheme(context)
      ? colorScheme.surface
      : colorScheme.surfaceContainerLowest;
  final elevated = _detailUsesDarkTheme(context)
      ? colorScheme.surfaceContainerHighest
      : colorScheme.surfaceContainerHigh;
  return Color.lerp(base, elevated, level.clamp(0.0, 1.0)) ?? base;
}

Color _detailCardSurface(
  BuildContext context, {
  bool hovered = false,
  bool selected = false,
}) {
  final level = selected
      ? 0.76
      : hovered
          ? 0.62
          : 0.46;
  return _detailSurface(context, level: level);
}

Color _detailPlaceholderSurface(BuildContext context) {
  return _detailSurface(context, level: 0.54);
}

Color _detailPrimaryText(BuildContext context) {
  return Theme.of(context).colorScheme.onSurface;
}

Color _detailSecondaryText(BuildContext context) {
  return Theme.of(context).colorScheme.onSurfaceVariant;
}

Color _detailHintText(BuildContext context) {
  return _detailSecondaryText(context).withValues(
    alpha: _detailUsesDarkTheme(context) ? 0.76 : 0.88,
  );
}

Color _detailBorder(BuildContext context, {double emphasis = 0.0}) {
  final base = Theme.of(context).colorScheme.outlineVariant;
  final alpha = _detailUsesDarkTheme(context)
      ? 0.18 + (emphasis * 0.18)
      : 0.32 + (emphasis * 0.14);
  return base.withValues(alpha: alpha.clamp(0.0, 1.0));
}

Color _detailShadow(BuildContext context, {double opacity = 0.18}) {
  final colorScheme = Theme.of(context).colorScheme;
  final base = _detailUsesDarkTheme(context) ? Colors.black : colorScheme.shadow;
  final alpha = _detailUsesDarkTheme(context) ? opacity + 0.14 : opacity;
  return base.withValues(alpha: alpha.clamp(0.0, 1.0));
}

Color _detailImageOverlay(
  BuildContext context, {
  double darkAlpha = 0.30,
  double lightAlpha = 0.22,
}) {
  final overlayBase = _detailUsesDarkTheme(context) ? Colors.black : Colors.white;
  return overlayBase.withValues(
    alpha: _detailUsesDarkTheme(context) ? darkAlpha : lightAlpha,
  );
}

Color _heroTitleColor(Color background) {
  return readableTextColorForBackground(background);
}

Color _heroSecondaryColor(Color background) {
  return readableSecondaryTextColorForBackground(background);
}

Color _heroShadowColor(Color background) {
  final textColor = _heroTitleColor(background);
  final isLightText = textColor.computeLuminance() > 0.5;
  return (isLightText ? Colors.black : Colors.white).withValues(
    alpha: isLightText ? 0.30 : 0.18,
  );
}

Color _heroChipColor(Color background) {
  final textColor = _heroTitleColor(background);
  return textColor.withValues(
    alpha: textColor.computeLuminance() > 0.5 ? 0.18 : 0.12,
  );
}

// ============================================================================
// Hero 区域
// ============================================================================

class _HeroSection extends ConsumerWidget {
  final MediaItem item;
  final String itemId;
  final Color backgroundColor;
  final Color dominantColor;
  final double heroHeight;
  final double posterHeight;
  final double posterWidth;
  final double overlap;
  final double horizontalPadding;
  final double contentMaxWidth;
  final VoidCallback onRefresh;
  final VoidCallback onRematch;
  final double scaleFactor;

  const _HeroSection({
    required this.item,
    required this.itemId,
    required this.backgroundColor,
    required this.dominantColor,
    required this.heroHeight,
    required this.posterHeight,
    required this.posterWidth,
    required this.overlap,
    required this.horizontalPadding,
    required this.contentMaxWidth,
    required this.onRefresh,
    required this.onRematch,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final titleColor = _heroTitleColor(backgroundColor);
    final secondaryColor = _heroSecondaryColor(backgroundColor);
    final shadowColor = _heroShadowColor(backgroundColor);
    final chipColor = _heroChipColor(backgroundColor);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      item,
      maxWidth: 1920,
    );
    final posterUrls = resolveMediaItemImageUrls(
      api,
      item,
      maxWidth: 600,
    );

    return Stack(
      children: [
        // 背景图
        SizedBox(
          height: heroHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 底色
              Container(color: dominantColor),

              // 背景图
              if (imageUrls.isNotEmpty)
                MediaImage(
                  imageUrl: imageUrls.first,
                  imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                  width: double.infinity,
                  height: heroHeight,
                  fit: BoxFit.cover,
                ),

              // 底部渐变
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      backgroundColor.withValues(alpha: 0.6),
                      backgroundColor,
                    ],
                    stops: const [0.5, 0.85, 1.0],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 顶部工具栏（返回 + 刷新）
        SafeArea(
          child: Padding(
            padding: EdgeInsets.all(12 * scaleFactor),
            child: Row(
              children: [
                _GlassButton(
                  icon: Icons.arrow_back,
                  onPressed: () => context.pop(),
                  scaleFactor: scaleFactor,
                ),
                SizedBox(width: 8 * scaleFactor),
                _GlassButton(
                  icon: Icons.refresh,
                  onPressed: onRefresh,
                  scaleFactor: scaleFactor,
                ),
                const Spacer(),
                // 窗口控制按钮占位（右侧系统按钮区域）
                SizedBox(width: 120 * scaleFactor),
              ],
            ),
          ),
        ),

        // 海报 + 信息区
        Positioned(
          bottom: -overlap,
          left: 0,
          right: 0,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 海报
                    Container(
                      width: posterWidth,
                      height: posterHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8 * scaleFactor),
                        boxShadow: [
                          BoxShadow(
                            color: _detailShadow(context, opacity: 0.24),
                            offset: Offset(0, 4 * scaleFactor),
                            blurRadius: 16 * scaleFactor,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8 * scaleFactor),
                        child: MediaImage(
                          imageUrl:
                              posterUrls.isNotEmpty ? posterUrls.first : null,
                          width: posterWidth,
                          height: posterHeight,
                          fit: BoxFit.cover,
                          placeholder: Container(
                            color: _detailPlaceholderSurface(context),
                            child: Center(
                              child: Text(
                                item.name.isNotEmpty
                                    ? item.name.substring(0, 1)
                                    : '?',
                                style: TextStyle(
                                  fontSize: 48 * scaleFactor,
                                  fontWeight: FontWeight.bold,
                                  color: _detailHintText(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    SizedBox(width: 32 * scaleFactor),

                    // 标题信息（在海报上方一点）
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: overlap + 16 * scaleFactor,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 标题
                            Text(
                              item.name,
                              style: TextStyle(
                                fontSize: 32 * scaleFactor,
                                fontWeight: FontWeight.w800,
                                color: titleColor,
                                shadows: [
                                  Shadow(blurRadius: 12, color: shadowColor),
                                ],
                              ),
                            ),
                            SizedBox(height: 10 * scaleFactor),

                            // 评分 + 标签行
                            Row(
                              children: [
                                if (item.communityRating != null) ...[
                                  const Icon(
                                    Icons.star,
                                    size: 16,
                                    color: Colors.amber,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    item.communityRating!
                                        .toStringAsFixed(1),
                                    style: TextStyle(
                                      fontSize: 14 * scaleFactor,
                                      fontWeight: FontWeight.w600,
                                      color: titleColor,
                                      shadows: [
                                        Shadow(
                                          blurRadius: 4,
                                          color: shadowColor,
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 16 * scaleFactor),
                                ],
                                if (item.productionYear != null) ...[
                                  Text(
                                    '${item.productionYear}',
                                    style: TextStyle(
                                      fontSize: 14 * scaleFactor,
                                      color: secondaryColor,
                                      shadows: [
                                        Shadow(
                                          blurRadius: 4,
                                          color: shadowColor,
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 12 * scaleFactor),
                                ],
                                if ((item.formattedRuntime ?? '').isNotEmpty) ...[
                                  Text(
                                    item.formattedRuntime!,
                                    style: TextStyle(
                                      fontSize: 14 * scaleFactor,
                                      color: secondaryColor,
                                      shadows: [
                                        Shadow(
                                          blurRadius: 4,
                                          color: shadowColor,
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 12 * scaleFactor),
                                ],
                                ...?item.genres?.take(4).map((genre) {
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      right: 6 * scaleFactor,
                                    ),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8 * scaleFactor,
                                        vertical: 3 * scaleFactor,
                                      ),
                                      decoration: BoxDecoration(
                                        color: chipColor,
                                        borderRadius: BorderRadius.circular(
                                          4 * scaleFactor,
                                        ),
                                        border: Border.all(
                                          color: titleColor.withValues(alpha: 0.16),
                                        ),
                                      ),
                                      child: Text(
                                        genre,
                                        style: TextStyle(
                                          fontSize: 11 * scaleFactor,
                                          color: titleColor,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 毛玻璃按钮
// ============================================================================

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double scaleFactor;

  const _GlassButton({
    required this.icon,
    required this.onPressed,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context) {
    final size = 40.0 * scaleFactor;
    final surface = _detailUsesDarkTheme(context)
        ? Colors.black.withValues(alpha: 0.28)
        : Colors.white.withValues(alpha: 0.58);
    final iconColor = _detailPrimaryText(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: surface,
            shape: BoxShape.circle,
            border: Border.all(
              color: _detailBorder(context, emphasis: 0.1),
            ),
          ),
          child: IconButton(
            icon: Icon(icon, color: iconColor, size: 20 * scaleFactor),
            onPressed: onPressed,
            splashRadius: size / 2,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 右侧信息区
// ============================================================================

class _InfoSection extends ConsumerStatefulWidget {
  final MediaItem item;
  final String itemId;
  final Color backgroundColor;
  final Color primaryColor;
  final double posterWidth;
  final double overlap;
  final double scaleFactor;

  const _InfoSection({
    required this.item,
    required this.itemId,
    required this.backgroundColor,
    required this.primaryColor,
    required this.posterWidth,
    required this.overlap,
    required this.scaleFactor,
  });

  @override
  ConsumerState<_InfoSection> createState() => _InfoSectionState();
}

class _InfoSectionState extends ConsumerState<_InfoSection> {
  bool _overviewExpanded = false;
  bool _mediaInfoExpanded = false;
  bool _isGridView = true;
  String? _selectedSeasonId;

  final LayerLink _playButtonLink = LayerLink();
  final LayerLink _sourceLink = LayerLink();
  final LayerLink _audioLink = LayerLink();
  final LayerLink _subtitleLink = LayerLink();
  final LayerLink _secondarySubtitleLink = LayerLink();

  OverlayEntry? _playMenuOverlay;
  OverlayEntry? _sourceMenuOverlay;
  OverlayEntry? _audioMenuOverlay;
  OverlayEntry? _subtitleMenuOverlay;
  OverlayEntry? _secondarySubtitleMenuOverlay;
  Offset? _menuAnchorPosition;

  @override
  void dispose() {
    _hideAllOverlays();
    super.dispose();
  }

  void _rememberMenuAnchor(TapDownDetails details) {
    _menuAnchorPosition = details.globalPosition;
  }

  void _hideAllOverlays() {
    _playMenuOverlay?.remove();
    _playMenuOverlay = null;
    _sourceMenuOverlay?.remove();
    _sourceMenuOverlay = null;
    _audioMenuOverlay?.remove();
    _audioMenuOverlay = null;
    _subtitleMenuOverlay?.remove();
    _subtitleMenuOverlay = null;
    _secondarySubtitleMenuOverlay?.remove();
    _secondarySubtitleMenuOverlay = null;
  }

  void _togglePlayMenu() {
    if (_playMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    _playMenuOverlay = _createMenuOverlay(
      link: _playButtonLink,
      items: [
        _MenuItem(
          icon: Icons.play_arrow,
          label: '从头开始播放',
          onTap: () {
            _hideAllOverlays();
            ref.read(currentPlayingItemProvider.notifier).state = widget.item;
            context.push('/player/${widget.itemId}');
          },
        ),
        _MenuItem(
          icon: Icons.open_in_new,
          label: '调用外部 MPV 播放器',
          onTap: () {
            _hideAllOverlays();
            _launchExternalPlayer();
          },
        ),
        _MenuItem(
          icon: Icons.download,
          label: '下载',
          onTap: () {
            _hideAllOverlays();
            _handleDownload();
          },
        ),
      ],
    );
    Overlay.of(context).insert(_playMenuOverlay!);
  }

  void _launchExternalPlayer() {
    // TODO: 实现外部播放器调用
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在启动外部播放器...')),
    );
  }

  void _handleDownload() {
    // TODO: 实现下载逻辑
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已添加到下载队列')),
    );
  }

  OverlayEntry _createMenuOverlay({
    required LayerLink link,
    required List<_MenuItem> items,
  }) {
    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final anchor = _menuAnchorPosition;
    final localAnchor = overlayBox != null && anchor != null
        ? overlayBox.globalToLocal(anchor)
        : null;
    const menuWidth = 280.0;
    final estimatedMenuHeight = (items.length * 58.0).clamp(120.0, 360.0);
    final screenSize = MediaQuery.of(context).size;
    final left = localAnchor?.dx
        .clamp(16.0, screenSize.width - menuWidth - 16.0)
        .toDouble();
    final top = localAnchor == null
        ? null
        : (localAnchor.dy + 8.0 + estimatedMenuHeight > screenSize.height - 16.0
              ? (localAnchor.dy - estimatedMenuHeight - 8.0)
              : (localAnchor.dy + 8.0))
            .clamp(16.0, screenSize.height - estimatedMenuHeight - 16.0)
            .toDouble();

    return OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点击外部关闭
          Positioned.fill(
            child: GestureDetector(
              onTap: _hideAllOverlays,
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
          ),
          // 菜单
          if (left != null && top != null)
            Positioned(
              left: left,
              top: top,
              child: _MenuSurface(
                width: menuWidth,
                maxHeight: estimatedMenuHeight,
                backgroundColor: widget.backgroundColor,
                items: items,
                primaryColor: widget.primaryColor,
              ),
            )
          else
            CompositedTransformFollower(
              link: link,
              showWhenUnlinked: false,
              offset: const Offset(0, 8),
              child: _MenuSurface(
                width: menuWidth,
                maxHeight: estimatedMenuHeight,
                backgroundColor: widget.backgroundColor,
                items: items,
                primaryColor: widget.primaryColor,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _togglePlayed() async {
    final api = ref.read(apiClientProvider);
    try {
      if (widget.item.isWatched) {
        await api.user.markAsUnplayed(widget.itemId);
      } else {
        await api.user.markAsPlayed(widget.itemId);
      }
      ref.invalidate(mediaItemProvider(widget.itemId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  Future<void> _toggleFavorite() async {
    final api = ref.read(apiClientProvider);
    try {
      final isFav = widget.item.userData?.isFavorite ?? false;
      if (isFav) {
        await api.favorite.removeFavorite(widget.itemId);
      } else {
        await api.favorite.addFavorite(widget.itemId);
      }
      ref.invalidate(mediaItemProvider(widget.itemId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final isSeries = widget.item.type == 'Series' || widget.item.type == 'Season';
    final selectedSeasonId = widget.item.type == 'Season'
        ? widget.itemId
        : _selectedSeasonId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 简介
        if (widget.item.overview != null &&
            widget.item.overview!.isNotEmpty) ...[
          _OverviewSection(
            overview: widget.item.overview!,
            expanded: _overviewExpanded,
            scaleFactor: scale,
            accentColor: widget.primaryColor,
            onToggle: () => setState(() => _overviewExpanded = !_overviewExpanded),
          ),
          SizedBox(height: 24 * scale),
        ],

        // 操作按钮行
        Row(
          children: [
            _ActionButton(
              icon: widget.item.isWatched
                  ? Icons.check_circle
                  : Icons.check_circle_outline,
              label: widget.item.isWatched ? '标记为未看' : '标记为已看',
              isActive: widget.item.isWatched,
              primaryColor: widget.primaryColor,
              scaleFactor: scale,
              onPressed: _togglePlayed,
            ),
            SizedBox(width: 12 * scale),
            _ActionButton(
              icon: (widget.item.userData?.isFavorite ?? false)
                  ? Icons.favorite
                  : Icons.favorite_border,
              label: '收藏',
              isActive: widget.item.userData?.isFavorite ?? false,
              activeColor: Colors.redAccent,
              primaryColor: widget.primaryColor,
              scaleFactor: scale,
              onPressed: _toggleFavorite,
            ),
          ],
        ),
        SizedBox(height: 24 * scale),

        // 播放按钮
        CompositedTransformTarget(
          link: _playButtonLink,
          child: _PlayButton(
            item: widget.item,
            primaryColor: widget.primaryColor,
            scaleFactor: scale,
            onTap: () {
              // 继续观看或从头播放
              ref.read(currentPlayingItemProvider.notifier).state = widget.item;
              context.push('/player/${widget.itemId}');
            },
            onDropdownTapDown: _rememberMenuAnchor,
            onDropdownTap: _togglePlayMenu,
          ),
        ),

        // 当前播放提示
        if (isSeries) ...[
          SizedBox(height: 8 * scale),
          Text(
            widget.item.type == 'Season' ? '当前浏览本季剧集' : '继续浏览剧集',
            style: TextStyle(
              fontSize: 12 * scale,
              color: _detailHintText(context),
            ),
          ),
        ],

        SizedBox(height: 16 * scale),

        // 媒体源选择器（仅在电影或单集时显示，或者从 playbackInfo 获取）
        if (!isSeries) ...[
          _buildMediaSourceSelectors(scale),
          SizedBox(height: 24 * scale),
        ],

        // 分集区域（仅剧集）
        if (isSeries) ...[
          _EpisodesSection(
            seriesId: widget.item.type == 'Season'
                ? (widget.item.seriesId ?? widget.item.parentId ?? widget.itemId)
                : widget.itemId,
            selectedSeasonId: selectedSeasonId,
            primaryColor: widget.primaryColor,
            scaleFactor: scale,
            isGridView: _isGridView,
            onToggleView: () => setState(() => _isGridView = !_isGridView),
            onEpisodeTap: (episode) {
              context.push('/episode/${episode.id}');
            },
          ),
          SizedBox(height: 48 * scale),

          // 分季区域
          _SeasonsSection(
            seriesId: widget.item.type == 'Season'
                ? (widget.item.seriesId ?? widget.item.parentId ?? widget.itemId)
                : widget.itemId,
            selectedSeasonId: selectedSeasonId,
            primaryColor: widget.primaryColor,
            scaleFactor: scale,
            onSeasonTap: (season) {
              setState(() => _selectedSeasonId = season.id);
            },
          ),
          SizedBox(height: 48 * scale),
        ],

        // 演职人员
        _CastSection(
          persons: widget.item.people ?? const [],
          primaryColor: widget.primaryColor,
          scaleFactor: scale,
        ),
        SizedBox(height: 48 * scale),

        // 相关推荐
        _RelatedSection(
          itemId: widget.itemId,
          primaryColor: widget.primaryColor,
          scaleFactor: scale,
        ),
      ],
    );
  }

  Widget _buildMediaSourceSelectors(double scale) {
    return Consumer(
      builder: (context, ref, child) {
        final playbackAsync = ref.watch(playbackInfoProvider(widget.itemId));
        final server = ref.watch(currentServerProvider);
        final selectedSourceId = ref.watch(selectedMediaSourceProvider);
        final selectedAudioIndex = ref.watch(audioTrackProvider);
        final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
        final selectedSecondarySubtitleIndex = ref.watch(
          secondarySubtitleTrackProvider,
        );

        return playbackAsync.when(
          data: (info) {
            final source = _resolveMediaSource(info, selectedSourceId);
            if (source == null) return const SizedBox.shrink();

            final audioStreams = source.mediaStreams.where((s) => s.isAudio).toList();
            final subtitleStreams = source.mediaStreams
                .where((s) => s.isSubtitle)
                .toList();
            final selectedAudio = _resolveSelectedStream(
              audioStreams,
              selectedAudioIndex,
            );
            final selectedSubtitle = _resolveSelectedStream(
              subtitleStreams,
              selectedSubtitleIndex,
            );
            final secondaryCandidates = subtitleStreams
                .where(
                  (stream) =>
                      selectedSubtitle == null ||
                      stream.index != selectedSubtitle.index,
                )
                .toList();
            final selectedSecondarySubtitle = _resolveSelectedStream(
              secondaryCandidates,
              selectedSecondarySubtitleIndex,
            );
            final videoStream = source.mediaStreams.firstWhere(
              (s) => s.isVideo,
              orElse: () => MediaStream(index: 0, type: 'Video'),
            );
            final fileSummary = <String>[
              if ((source.name ?? '').trim().isNotEmpty) source.name!.trim(),
              if (_buildVideoVersionLabel(source, videoStream).isNotEmpty)
                _buildVideoVersionLabel(source, videoStream),
              if (source.size != null) _formatBytes(source.size!),
              if (_formatBitRate(source, videoStream) != null)
                _formatBitRate(source, videoStream)!,
            ].join('  ');

            _seedPlaybackSelections(
              ref,
              mediaSource: source,
              audioStreams: audioStreams,
              subtitleStreams: subtitleStreams,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _SelectorCard(
                        label: '线路',
                        value: _resolveCurrentLineName(server),
                        scaleFactor: scale,
                        onTapDown: _rememberMenuAnchor,
                        onTap: () => _showLineSelector(ref, server),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _sourceLink,
                        child: _SelectorCard(
                          label: '版本',
                          value: _buildSourceDisplayName(source, videoStream),
                          tooltip: fileSummary,
                          scaleFactor: scale,
                          onTapDown: _rememberMenuAnchor,
                          onTap: () => _toggleSourceMenu(info),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12 * scale),
                Row(
                  children: [
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _audioLink,
                        child: _SelectorCard(
                          label: '音频',
                          value: selectedAudio?.readableLabel(
                                siblings: audioStreams,
                              ) ??
                              '无',
                          tooltip: selectedAudio?.readableLabel(
                                siblings: audioStreams,
                              ) ??
                              '无',
                          scaleFactor: scale,
                          onTapDown: _rememberMenuAnchor,
                          onTap: () => _toggleAudioMenu(audioStreams),
                        ),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _subtitleLink,
                        child: _SelectorCard(
                          label: '字幕',
                          value: selectedSubtitle?.readableLabel(
                                siblings: subtitleStreams,
                              ) ??
                              '无',
                          tooltip: selectedSubtitle?.readableLabel(
                                siblings: subtitleStreams,
                              ) ??
                              '无',
                          scaleFactor: scale,
                          onTapDown: _rememberMenuAnchor,
                          onTap: () => _toggleSubtitleMenu(subtitleStreams),
                        ),
                      ),
                    ),
                  ],
                ),
                if (secondaryCandidates.isNotEmpty) ...[
                  SizedBox(height: 12 * scale),
                  CompositedTransformTarget(
                    link: _secondarySubtitleLink,
                    child: _SelectorCard(
                      label: '次字幕',
                      value: selectedSecondarySubtitle?.readableLabel(
                            siblings: secondaryCandidates,
                          ) ??
                          '无',
                      tooltip: selectedSecondarySubtitle?.readableLabel(
                            siblings: secondaryCandidates,
                          ) ??
                          '无',
                      scaleFactor: scale,
                      onTapDown: _rememberMenuAnchor,
                      onTap: () => _toggleSecondarySubtitleMenu(
                        secondaryCandidates,
                      ),
                    ),
                  ),
                ],

                // 文件信息
                SizedBox(height: 12 * scale),
                Text(
                  fileSummary,
                  style: TextStyle(
                    fontSize: 12 * scale,
                    color: _detailHintText(context),
                  ),
                ),

                // 查看媒体信息
                SizedBox(height: 8 * scale),
                GestureDetector(
                  onTap: () => setState(
                    () => _mediaInfoExpanded = !_mediaInfoExpanded,
                  ),
                  child: Text(
                    '查看媒体信息',
                    style: TextStyle(
                      fontSize: 13 * scale,
                      color: widget.primaryColor,
                    ),
                  ),
                ),

                // 媒体信息折叠面板
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _mediaInfoExpanded
                      ? _MediaInfoPanel(
                          source: source,
                          versionLabel: _buildSourceDisplayName(source, videoStream),
                          scaleFactor: scale,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            );
          },
          loading: () => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  MediaSource? _resolveMediaSource(PlaybackInfo info, String? selectedSourceId) {
    if (info.mediaSources.isEmpty) return null;
    if (selectedSourceId == null || selectedSourceId.isEmpty) {
      return info.mediaSources.first;
    }
    return info.mediaSources
            .where((source) => source.id == selectedSourceId)
            .firstOrNull ??
        info.mediaSources.first;
  }

  MediaStream? _resolveSelectedStream(
    List<MediaStream> streams,
    int? selectedIndex,
  ) {
    if (streams.isEmpty) return null;
    if (selectedIndex == null) {
      return streams.where((stream) => stream.isDefault == true).firstOrNull ??
          streams.first;
    }
    return streams.where((stream) => stream.index == selectedIndex).firstOrNull ??
        streams.where((stream) => stream.isDefault == true).firstOrNull ??
        streams.first;
  }

  void _seedPlaybackSelections(
    WidgetRef ref, {
    required MediaSource mediaSource,
    required List<MediaStream> audioStreams,
    required List<MediaStream> subtitleStreams,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(selectedMediaSourceProvider) != mediaSource.id) {
        ref.read(selectedMediaSourceProvider.notifier).state = mediaSource.id;
      }
      if (ref.read(audioTrackProvider) == null) {
        final selected = _resolveSelectedStream(audioStreams, null);
        if (selected?.index != null) {
          ref.read(audioTrackProvider.notifier).state = selected!.index;
        }
      }
      if (ref.read(subtitleTrackProvider) == null) {
        final selected = _resolveSelectedStream(subtitleStreams, null);
        if (selected?.index != null) {
          ref.read(subtitleTrackProvider.notifier).state = selected!.index;
        }
      }
    });
  }

  String _resolveCurrentLineName(ServerConfig? server) {
    if (server == null || server.lines.isEmpty) {
      return '当前线路';
    }
    final index = server.activeLineIndex.clamp(0, server.lines.length - 1);
    return server.lines[index].name;
  }

  String _buildVideoVersionLabel(MediaSource source, MediaStream videoStream) {
    final parts = <String>[
      if (videoStream.resolution.isNotEmpty) videoStream.resolution,
      if ((videoStream.videoCodec ?? '').trim().isNotEmpty)
        (videoStream.videoCodec ?? '').trim().toUpperCase(),
      if ((source.container ?? '').trim().isNotEmpty)
        source.container!.trim().toUpperCase(),
    ];
    return parts.join(' ');
  }

  String _buildSourceDisplayName(MediaSource source, MediaStream videoStream) {
    final customName = source.name?.trim();
    final version = _buildVideoVersionLabel(source, videoStream);
    if (customName != null && customName.isNotEmpty && version.isNotEmpty) {
      return '$customName · $version';
    }
    if (customName != null && customName.isNotEmpty) {
      return customName;
    }
    if (version.isNotEmpty) {
      return version;
    }
    return '默认版本';
  }

  String? _formatBitRate(MediaSource source, MediaStream videoStream) {
    final bitRate = videoStream.bitRate;
    if (bitRate == null || bitRate <= 0) return null;
    if (bitRate >= 1000000) {
      return '${(bitRate / 1000000).toStringAsFixed(1)} Mbps';
    }
    if (bitRate >= 1000) {
      return '${(bitRate / 1000).toStringAsFixed(0)} Kbps';
    }
    return '$bitRate bps';
  }

  void _showLineSelector(WidgetRef ref, ServerConfig? server) {
    if (server == null || server.lines.isEmpty) return;
    _hideAllOverlays();
    _sourceMenuOverlay = _createMenuOverlay(
      link: _sourceLink,
      items: server.lines.asMap().entries.map((entry) {
        final index = entry.key;
        final line = entry.value;
        final isCurrent = index == server.activeLineIndex;
        return _MenuItem(
          icon: isCurrent ? Icons.check_circle : Icons.route_outlined,
          label: isCurrent ? '${line.name} (当前)' : line.name,
          onTap: () {
            _hideAllOverlays();
            ref.read(serverListProvider.notifier).setActiveLine(server.id, index);
            final updatedServer = ref
                .read(serverListProvider)
                .firstWhere((item) => item.id == server.id);
            ref.read(currentServerProvider.notifier).state = updatedServer;
            ref.read(selectedMediaSourceProvider.notifier).state = null;
            ref.read(audioTrackProvider.notifier).state = null;
            ref.read(subtitleTrackProvider.notifier).state = null;
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
            ref.invalidate(playbackInfoProvider(widget.itemId));
          },
        );
      }).toList(),
    );
    Overlay.of(context).insert(_sourceMenuOverlay!);
  }

  void _toggleSourceMenu(PlaybackInfo info) {
    if (_sourceMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedSourceId = ref.read(selectedMediaSourceProvider);
    _sourceMenuOverlay = _createMenuOverlay(
      link: _sourceLink,
      items: info.mediaSources.map((source) {
        final videoStream = source.mediaStreams.firstWhere(
          (stream) => stream.isVideo,
          orElse: () => MediaStream(index: 0, type: 'Video'),
        );
        final isCurrent = source.id == selectedSourceId;
        return _MenuItem(
          icon: isCurrent ? Icons.check_circle : Icons.layers_outlined,
          label: isCurrent
              ? '${_buildSourceDisplayName(source, videoStream)} (当前)'
              : _buildSourceDisplayName(source, videoStream),
          onTap: () {
            _hideAllOverlays();
            ref.read(selectedMediaSourceProvider.notifier).state = source.id;
            ref.read(audioTrackProvider.notifier).state = null;
            ref.read(subtitleTrackProvider.notifier).state = null;
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          },
        );
      }).toList(),
    );
    Overlay.of(context).insert(_sourceMenuOverlay!);
  }

  void _toggleAudioMenu(List<MediaStream> audioStreams) {
    if (_audioMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedIndex = ref.read(audioTrackProvider);
    _audioMenuOverlay = _createMenuOverlay(
      link: _audioLink,
      items: audioStreams.map((stream) {
        final isCurrent = stream.index == selectedIndex;
        return _MenuItem(
          icon: isCurrent ? Icons.check_circle : Icons.audiotrack,
          label: isCurrent
              ? '${stream.readableLabel(siblings: audioStreams)} (当前)'
              : stream.readableLabel(siblings: audioStreams),
          onTap: () {
            _hideAllOverlays();
            ref.read(audioTrackProvider.notifier).state = stream.index;
          },
        );
      }).toList(),
    );
    Overlay.of(context).insert(_audioMenuOverlay!);
  }

  void _toggleSubtitleMenu(List<MediaStream> subtitleStreams) {
    if (_subtitleMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedIndex = ref.read(subtitleTrackProvider);
    final secondaryIndex = ref.read(secondarySubtitleTrackProvider);
    _subtitleMenuOverlay = _createMenuOverlay(
      link: _subtitleLink,
      items: [
        _MenuItem(
          icon: selectedIndex == null ? Icons.check_circle : Icons.subtitles_off,
          label: selectedIndex == null ? '无字幕 (当前)' : '无字幕',
          onTap: () {
            _hideAllOverlays();
            ref.read(subtitleTrackProvider.notifier).state = null;
          },
        ),
        ...subtitleStreams.map((stream) {
          final isCurrent = stream.index == selectedIndex;
          return _MenuItem(
            icon: isCurrent ? Icons.check_circle : Icons.subtitles_outlined,
            label: isCurrent
                ? '${stream.readableLabel(siblings: subtitleStreams)} (当前)'
                : stream.readableLabel(siblings: subtitleStreams),
            onTap: () {
              _hideAllOverlays();
              ref.read(subtitleTrackProvider.notifier).state = stream.index;
              if (secondaryIndex == stream.index) {
                ref.read(secondarySubtitleTrackProvider.notifier).state = null;
              }
            },
          );
        }),
      ],
    );
    Overlay.of(context).insert(_subtitleMenuOverlay!);
  }

  void _toggleSecondarySubtitleMenu(List<MediaStream> secondaryCandidates) {
    if (_secondarySubtitleMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedIndex = ref.read(secondarySubtitleTrackProvider);
    _secondarySubtitleMenuOverlay = _createMenuOverlay(
      link: _secondarySubtitleLink,
      items: [
        _MenuItem(
          icon: selectedIndex == null ? Icons.check_circle : Icons.subtitles_off,
          label: selectedIndex == null ? '无次字幕 (当前)' : '无次字幕',
          onTap: () {
            _hideAllOverlays();
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          },
        ),
        ...secondaryCandidates.map((stream) {
          final isCurrent = stream.index == selectedIndex;
          return _MenuItem(
            icon: isCurrent ? Icons.check_circle : Icons.closed_caption_disabled,
            label: isCurrent
                ? '${stream.readableLabel(siblings: secondaryCandidates)} (当前)'
                : stream.readableLabel(siblings: secondaryCandidates),
            onTap: () {
              _hideAllOverlays();
              ref.read(secondarySubtitleTrackProvider.notifier).state =
                  stream.index;
            },
          );
        }),
      ],
    );
    Overlay.of(context).insert(_secondarySubtitleMenuOverlay!);
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    } else if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '$bytes B';
  }
}

// ============================================================================
// 简介区块
// ============================================================================

class _OverviewSection extends StatelessWidget {
  final String overview;
  final bool expanded;
  final double scaleFactor;
  final Color accentColor;
  final VoidCallback onToggle;

  const _OverviewSection({
    required this.overview,
    required this.expanded,
    required this.scaleFactor,
    required this.accentColor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scale = scaleFactor;
    final primaryText = _detailPrimaryText(context).withValues(alpha: 0.92);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: Text(
            overview,
            maxLines: expanded ? null : 3,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14 * scale,
              height: 1.6,
              color: primaryText,
            ),
          ),
        ),
        if (overview.length > 100) ...[
          SizedBox(height: 4 * scale),
          GestureDetector(
            onTap: onToggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  expanded ? '收起' : '展开',
                  style: TextStyle(
                    fontSize: 13 * scale,
                    color: accentColor,
                  ),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 16 * scale,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// 操作按钮
// ============================================================================

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color? activeColor;
  final Color primaryColor;
  final double scaleFactor;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.activeColor,
    required this.primaryColor,
    required this.scaleFactor,
    required this.onPressed,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final secondaryText = _detailSecondaryText(context);
    final color = widget.isActive
        ? (widget.activeColor ?? widget.primaryColor)
        : secondaryText;
    final surfaceColor = widget.isActive
        ? color.withValues(alpha: _detailUsesDarkTheme(context) ? 0.15 : 0.12)
        : _detailCardSurface(context, hovered: false);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          _controller.forward().then((_) => _controller.reverse());
          widget.onPressed();
        },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final scaleAnim = 1.0 + (_controller.value * 0.1);
            return Transform.scale(
              scale: scaleAnim,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 16 * scale,
                  vertical: 8 * scale,
                ),
                decoration: BoxDecoration(
                  color: surfaceColor,
                  border: Border.all(
                    color: widget.isActive
                        ? color.withValues(alpha: 0.26)
                        : _detailBorder(context, emphasis: 0.08),
                  ),
                  borderRadius: BorderRadius.circular(20 * scale),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 18 * scale, color: color),
                    SizedBox(width: 6 * scale),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 13 * scale,
                        color: color,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// 播放按钮
// ============================================================================

class _PlayButton extends StatefulWidget {
  final MediaItem item;
  final Color primaryColor;
  final double scaleFactor;
  final VoidCallback onTap;
  final VoidCallback onDropdownTap;
  final ValueChanged<TapDownDetails>? onDropdownTapDown;

  const _PlayButton({
    required this.item,
    required this.primaryColor,
    required this.scaleFactor,
    required this.onTap,
    required this.onDropdownTap,
    this.onDropdownTapDown,
  });

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final foregroundColor = readableTextColorForBackground(widget.primaryColor);
    final dividerColor = foregroundColor.withValues(alpha: 0.24);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Row(
        children: [
          // 主播放按钮
          Expanded(
            flex: 7,
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 48 * scale,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      widget.primaryColor,
                      widget.primaryColor.withValues(alpha: 0.85),
                    ],
                  ),
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(8 * scale),
                  ),
                  boxShadow: _isHovered
                      ? [
                          BoxShadow(
                            color: widget.primaryColor.withValues(alpha: 0.4),
                            blurRadius: 16 * scale,
                            offset: Offset(0, 4 * scale),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.play_arrow,
                      color: foregroundColor,
                      size: 24 * scale,
                    ),
                    SizedBox(width: 8 * scale),
                    Text(
                      '开始播放',
                      style: TextStyle(
                        fontSize: 16 * scale,
                        fontWeight: FontWeight.w600,
                        color: foregroundColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 分隔线
          Container(
            width: 1,
            height: 48 * scale,
            color: dividerColor,
          ),

          // 下拉箭头
          GestureDetector(
            onTapDown: widget.onDropdownTapDown,
            onTap: widget.onDropdownTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 48 * scale,
              height: 48 * scale,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    widget.primaryColor.withValues(alpha: 0.85),
                    widget.primaryColor.withValues(alpha: 0.7),
                  ],
                ),
                borderRadius: BorderRadius.horizontal(
                  right: Radius.circular(8 * scale),
                ),
              ),
              child: Icon(
                Icons.arrow_drop_down,
                color: foregroundColor,
                size: 24 * scale,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 选择器卡片
// ============================================================================

class _SelectorCard extends StatefulWidget {
  final String label;
  final String value;
  final String? tooltip;
  final double scaleFactor;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails>? onTapDown;

  const _SelectorCard({
    required this.label,
    required this.value,
    this.tooltip,
    required this.scaleFactor,
    required this.onTap,
    this.onTapDown,
  });

  @override
  State<_SelectorCard> createState() => _SelectorCardState();
}

class _SelectorCardState extends State<_SelectorCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final hoveredSurface = _detailCardSurface(context, hovered: true);
    final idleSurface = _detailCardSurface(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: widget.onTapDown,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.all(12 * scale),
          decoration: BoxDecoration(
            color: _isHovered
                ? hoveredSurface
                : idleSurface,
            border: Border.all(
              color: _detailBorder(
                context,
                emphasis: _isHovered ? 0.28 : 0.06,
              ),
            ),
            borderRadius: BorderRadius.circular(8 * scale),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11 * scale,
                  color: _detailHintText(context),
                ),
              ),
              SizedBox(height: 4 * scale),
              Tooltip(
                message: widget.tooltip ?? widget.value,
                waitDuration: const Duration(milliseconds: 350),
                child: Text(
                  widget.value,
                  style: TextStyle(
                    fontSize: 13 * scale,
                    color: _detailPrimaryText(context),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 菜单项
// ============================================================================

class _MenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _MenuSurface extends StatelessWidget {
  final double width;
  final double maxHeight;
  final Color backgroundColor;
  final List<_MenuItem> items;
  final Color primaryColor;

  const _MenuSurface({
    required this.width,
    required this.maxHeight,
    required this.backgroundColor,
    required this.items,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Color.lerp(
          _detailSurface(context, level: 0.48),
          backgroundColor,
          0.38,
        ) ??
        backgroundColor;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: width,
            decoration: BoxDecoration(
              color: surface.withValues(
                alpha: _detailUsesDarkTheme(context) ? 0.90 : 0.96,
              ),
              border: Border.all(
                color: _detailBorder(context, emphasis: 0.14),
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: _detailShadow(context, opacity: 0.22),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: DesktopSmoothScrollBuilder(
                builder: (context, controller) => SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: items.map((item) {
                      return _FocusableMenuItem(
                        icon: item.icon,
                        label: item.label,
                        onTap: item.onTap,
                        primaryColor: primaryColor,
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusableMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color primaryColor;

  const _FocusableMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primaryColor,
  });

  @override
  State<_FocusableMenuItem> createState() => _FocusableMenuItemState();
}

class _FocusableMenuItemState extends State<_FocusableMenuItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final primaryText = _detailPrimaryText(context);
    final secondaryText = _detailSecondaryText(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.primaryColor.withValues(
                    alpha: _detailUsesDarkTheme(context) ? 0.14 : 0.10,
                  )
                : Colors.transparent,
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 20,
                color: _isHovered ? widget.primaryColor : secondaryText,
              ),
              const SizedBox(width: 12),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  color: _isHovered ? primaryText : secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 媒体信息面板
// ============================================================================

class _MediaInfoPanel extends StatelessWidget {
  final MediaSource source;
  final String versionLabel;
  final double scaleFactor;

  const _MediaInfoPanel({
    required this.source,
    required this.versionLabel,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context) {
    final scale = scaleFactor;
    final videoStream = source.mediaStreams.firstWhere(
      (s) => s.type == 'Video',
      orElse: () => MediaStream(index: 0, type: 'Video'),
    );
    final audioStreams = source.mediaStreams.where((s) => s.type == 'Audio').toList();
    final subtitleStreams = source.mediaStreams.where((s) => s.type == 'Subtitle').toList();

    return Container(
      margin: EdgeInsets.only(top: 16 * scale),
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: _detailCardSurface(context),
        borderRadius: BorderRadius.circular(8 * scale),
        border: Border.all(
          color: _detailBorder(context, emphasis: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (versionLabel.isNotEmpty)
            _InfoRow(label: '版本', value: versionLabel, scale: scale),
          _InfoRow(label: '容器', value: source.container?.toUpperCase() ?? '未知', scale: scale),
          _InfoRow(label: '大小', value: _formatSize(source.size), scale: scale),
          if (videoStream.displayTitle != null)
            _InfoRow(label: '视频', value: videoStream.displayTitle!, scale: scale),
          if (videoStream.bitRate != null && videoStream.bitRate! > 0)
            _InfoRow(
              label: '码率',
              value: videoStream.bitRate! >= 1000000
                  ? '${(videoStream.bitRate! / 1000000).toStringAsFixed(1)} Mbps'
                  : '${(videoStream.bitRate! / 1000).toStringAsFixed(0)} Kbps',
              scale: scale,
            ),
          ...audioStreams.map((s) => _InfoRow(
            label: '音频',
            value: s.readableLabel(siblings: audioStreams),
            scale: scale,
          )),
          ...subtitleStreams.map((s) => _InfoRow(
            label: '字幕',
            value: s.readableLabel(siblings: subtitleStreams),
            scale: scale,
          )),
        ],
      ),
    );
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '未知';
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '$bytes B';
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final double scale;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = _detailHintText(context);
    final valueColor = _detailPrimaryText(context).withValues(alpha: 0.88);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60 * scale,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12 * scale,
                color: labelColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12 * scale,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 横向滚动列表通用组件
// ============================================================================

class _HorizontalScrollList extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Color primaryColor;
  final double scaleFactor;
  final double itemWidth;
  final double itemHeight;
  final Widget? trailing;

  const _HorizontalScrollList({
    required this.title,
    this.subtitle,
    required this.children,
    required this.primaryColor,
    required this.scaleFactor,
    required this.itemWidth,
    required this.itemHeight,
    this.trailing,
  });

  @override
  State<_HorizontalScrollList> createState() => _HorizontalScrollListState();
}

class _HorizontalScrollListState extends State<_HorizontalScrollList> {
  final ScrollController _controller = ScrollController();
  bool _showLeftArrow = false;
  bool _showRightArrow = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void dispose() {
    _controller.removeListener(_updateArrows);
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted) return;
    setState(() {
      _showLeftArrow = _controller.offset > 0;
      _showRightArrow = _controller.offset <
          (_controller.position.maxScrollExtent - 1);
    });
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) {
      return;
    }

    _controller.animateTo(
      (_controller.offset + delta).clamp(
        0,
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行
        Row(
          children: [
            _SectionTitle(
              title: widget.title,
              scaleFactor: scale,
              primaryColor: widget.primaryColor,
            ),
            if (widget.subtitle != null) ...[
              SizedBox(width: 12 * scale),
              Text(
                widget.subtitle!,
                style: TextStyle(
                  fontSize: 13 * scale,
                  color: _detailHintText(context),
                ),
              ),
            ],
            const Spacer(),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
        SizedBox(height: 16 * scale),

        // 滚动区域
        Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(event, (
                resolvedEvent,
              ) {
                if (resolvedEvent is! PointerScrollEvent) {
                  return;
                }

                final delta = resolvedEvent.scrollDelta.dx != 0
                    ? resolvedEvent.scrollDelta.dx
                    : resolvedEvent.scrollDelta.dy;
                if (delta == 0) {
                  return;
                }

                _scrollBy(delta * 2);
              });
            }
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: Stack(
              children: [
                // 列表
                SizedBox(
                  height: widget.itemHeight,
                  child: ListView.separated(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    primary: false,
                    physics: const ClampingScrollPhysics(
                      parent: _SnapScrollPhysics(),
                    ),
                    itemCount: widget.children.length,
                    separatorBuilder: (_, __) =>
                        SizedBox(width: 12 * scale),
                    itemBuilder: (context, index) => widget.children[index],
                  ),
                ),

                // 左箭头
                if (_showLeftArrow)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: _ScrollArrow(
                      icon: Icons.chevron_left,
                      onPressed: () => _scrollBy(-widget.itemWidth * 4),
                      scaleFactor: scale,
                    ),
                  ),

                // 右箭头
                if (_showRightArrow)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: _ScrollArrow(
                      icon: Icons.chevron_right,
                      onPressed: () => _scrollBy(widget.itemWidth * 4),
                      scaleFactor: scale,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScrollArrow extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double scaleFactor;

  const _ScrollArrow({
    required this.icon,
    required this.onPressed,
    required this.scaleFactor,
  });

  @override
  State<_ScrollArrow> createState() => _ScrollArrowState();
}

class _ScrollArrowState extends State<_ScrollArrow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _isHovered ? 0.8 : 0,
          child: Container(
            width: 40 * scale,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: widget.icon == Icons.chevron_left
                    ? [
                        _detailSurface(context, level: 0.84).withValues(alpha: 0.92),
                        Colors.transparent,
                      ]
                    : [
                        Colors.transparent,
                        _detailSurface(context, level: 0.84).withValues(alpha: 0.92),
                      ],
              ),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                color: _detailPrimaryText(context),
                size: 28 * scale,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SnapScrollPhysics extends ScrollPhysics {
  const _SnapScrollPhysics({super.parent});

  @override
  _SnapScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _SnapScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final simulation = super.createBallisticSimulation(position, velocity);
    if (simulation == null) return null;
    return _SnapSimulation(
      delegateSimulation: simulation,
      position: position,
      itemWidth: 212.0,
    );
  }
}

class _SnapSimulation extends Simulation {
  final Simulation delegateSimulation;
  final ScrollMetrics position;
  final double itemWidth;

  _SnapSimulation({
    required this.delegateSimulation,
    required this.position,
    required this.itemWidth,
  });

  @override
  double x(double time) {
    final value = delegateSimulation.x(time);
    final snapped = (value / itemWidth).round() * itemWidth;
    return snapped.clamp(0.0, position.maxScrollExtent);
  }

  @override
  double dx(double time) => delegateSimulation.dx(time);

  @override
  bool isDone(double time) => delegateSimulation.isDone(time);
}

// ============================================================================
// 区块标题
// ============================================================================

class _SectionTitle extends StatelessWidget {
  final String title;
  final double scaleFactor;
  final Color primaryColor;

  const _SectionTitle({
    required this.title,
    required this.scaleFactor,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final scale = scaleFactor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 4 * scale,
          height: 20 * scale,
          decoration: BoxDecoration(
            color: primaryColor,
            borderRadius: BorderRadius.circular(2 * scale),
          ),
        ),
        SizedBox(width: 10 * scale),
        Text(
          title,
          style: TextStyle(
            fontSize: 18 * scale,
            fontWeight: FontWeight.w700,
            color: _detailPrimaryText(context),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 分集区域
// ============================================================================

class _EpisodesSection extends ConsumerStatefulWidget {
  final String seriesId;
  final String? selectedSeasonId;
  final Color primaryColor;
  final double scaleFactor;
  final bool isGridView;
  final VoidCallback onToggleView;
  final Function(Episode) onEpisodeTap;

  const _EpisodesSection({
    required this.seriesId,
    this.selectedSeasonId,
    required this.primaryColor,
    required this.scaleFactor,
    required this.isGridView,
    required this.onToggleView,
    required this.onEpisodeTap,
  });

  @override
  ConsumerState<_EpisodesSection> createState() => _EpisodesSectionState();
}

class _EpisodesSectionState extends ConsumerState<_EpisodesSection> {
  @override
  Widget build(BuildContext context) {
    final episodesAsync = ref.watch(episodesProvider((
      seriesId: widget.seriesId,
      seasonId: widget.selectedSeasonId,
    )));

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: episodesAsync.when(
        data: (episodes) {
          if (episodes.isEmpty) return const SizedBox.shrink();

          if (widget.isGridView) {
            final scale = widget.scaleFactor;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SectionTitle(
                      title: '分集',
                      scaleFactor: scale,
                      primaryColor: widget.primaryColor,
                    ),
                    SizedBox(width: 12 * scale),
                    Text(
                      '共${episodes.length}集',
                      style: TextStyle(
                        fontSize: 13 * scale,
                        color: _detailHintText(context),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        Icons.list_rounded,
                        size: 20 * scale,
                        color: _detailSecondaryText(context),
                      ),
                      onPressed: widget.onToggleView,
                      tooltip: '切换为海报视图',
                    ),
                  ],
                ),
                SizedBox(height: 16 * scale),
                Wrap(
                  spacing: 10 * scale,
                  runSpacing: 10 * scale,
                  children: episodes.map((episode) {
                    final isWatched = episode.userData?.played ?? false;
                    return _EpisodeStripTile(
                      episode: episode,
                      scaleFactor: scale,
                      primaryColor: widget.primaryColor,
                      isWatched: isWatched,
                      onTap: () => widget.onEpisodeTap(episode),
                    );
                  }).toList(),
                ),
              ],
            );
          }

          return _HorizontalScrollList(
            title: '分集',
            subtitle: '共${episodes.length}集',
            primaryColor: widget.primaryColor,
            scaleFactor: widget.scaleFactor,
            itemWidth: 200 * widget.scaleFactor,
            itemHeight: 160 * widget.scaleFactor,
            trailing: Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.grid_view_rounded,
                    size: 20 * widget.scaleFactor,
                    color: _detailSecondaryText(context),
                  ),
                  onPressed: widget.onToggleView,
                  tooltip: '切换为条形视图',
                ),
              ],
            ),
            children: episodes.map((episode) {
              return _EpisodeCard(
                episode: episode,
                scaleFactor: widget.scaleFactor,
                primaryColor: widget.primaryColor,
                isSelected: false, // TODO: 根据当前播放状态判断
                onTap: () => widget.onEpisodeTap(episode),
              );
            }).toList(),
          );
        },
        loading: () => _buildSkeleton(),
        error: (_, __) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildSkeleton() {
    final scale = widget.scaleFactor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '分集',
          scaleFactor: scale,
          primaryColor: widget.primaryColor,
        ),
        SizedBox(height: 16 * scale),
        SizedBox(
          height: 160 * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 4,
            separatorBuilder: (_, __) => SizedBox(width: 12 * scale),
            itemBuilder: (_, __) => Container(
              width: 200 * scale,
              decoration: BoxDecoration(
                color: _detailPlaceholderSurface(context),
                borderRadius: BorderRadius.circular(8 * scale),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 分集卡片
// ============================================================================

class _EpisodeCard extends StatefulWidget {
  final Episode episode;
  final double scaleFactor;
  final Color primaryColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _EpisodeCard({
    required this.episode,
    required this.scaleFactor,
    required this.primaryColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final isWatched = widget.episode.userData?.played ?? false;
    final progress = widget.episode.userData?.playbackPositionTicks != null &&
            widget.episode.runTimeTicks != null
        ? widget.episode.userData!.playbackPositionTicks! /
            widget.episode.runTimeTicks!
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 200 * scale,
          decoration: BoxDecoration(
            color: _detailCardSurface(context, hovered: _isHovered),
            borderRadius: BorderRadius.circular(8 * scale),
            border: widget.isSelected
                ? Border.all(
                    color: widget.primaryColor,
                    width: 2,
                  )
                : _isHovered
                    ? Border.all(
                        color: _detailBorder(context, emphasis: 0.28),
                        width: 1,
                      )
                    : null,
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: _detailShadow(context, opacity: 0.18),
                      blurRadius: 16 * scale,
                      offset: Offset(0, 4 * scale),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 缩略图
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Consumer(
                        builder: (context, ref, child) {
                          final api = ref.read(apiClientProvider);
                          final imageUrls = resolveEpisodeImageUrls(
                            api,
                            widget.episode,
                            maxWidth: 400,
                          );
                          return MediaImage(
                            imageUrl: imageUrls.isNotEmpty
                                ? imageUrls.first
                                : null,
                            width: 200 * scale,
                            height: 112 * scale,
                            fit: BoxFit.cover,
                            placeholder: Container(
                              color: _detailPlaceholderSurface(context),
                            ),
                          );
                        },
                      ),

                      // 集数标签
                      Positioned(
                        top: 8 * scale,
                        left: 8 * scale,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6 * scale,
                            vertical: 2 * scale,
                          ),
                          decoration: BoxDecoration(
                            color: _detailImageOverlay(
                              context,
                              darkAlpha: 0.56,
                              lightAlpha: 0.44,
                            ),
                            borderRadius: BorderRadius.circular(4 * scale),
                          ),
                          child: Text(
                            'E${widget.episode.indexNumber ?? '?'}',
                            style: TextStyle(
                              fontSize: 11 * scale,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),

                      // 已看标记
                      if (isWatched)
                        Positioned(
                          top: 8 * scale,
                          right: 8 * scale,
                          child: Icon(
                            Icons.check_circle,
                            size: 18 * scale,
                            color: Colors.white,
                          ),
                        ),

                      // 进度条
                      if (progress != null && progress > 0 && progress < 1)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: _detailBorder(context, emphasis: 0.12),
                            valueColor: AlwaysStoppedAnimation(
                              widget.primaryColor,
                            ),
                            minHeight: 3 * scale,
                          ),
                        ),

                      // 悬停遮罩
                      if (_isHovered)
                        Container(
                          color: _detailImageOverlay(context),
                          child: Center(
                            child: Icon(
                              Icons.play_circle_outline,
                              size: 40 * scale,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // 信息区
                Padding(
                  padding: EdgeInsets.all(8 * scale),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.episode.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13 * scale,
                          fontWeight: FontWeight.w500,
                          color: _detailPrimaryText(context),
                        ),
                      ),
                      SizedBox(height: 2 * scale),
                      if (widget.episode.formattedRuntime != null)
                        Text(
                          widget.episode.formattedRuntime!,
                          style: TextStyle(
                            fontSize: 11 * scale,
                            color: _detailHintText(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeStripTile extends StatefulWidget {
  final Episode episode;
  final double scaleFactor;
  final Color primaryColor;
  final bool isWatched;
  final VoidCallback onTap;

  const _EpisodeStripTile({
    required this.episode,
    required this.scaleFactor,
    required this.primaryColor,
    required this.isWatched,
    required this.onTap,
  });

  @override
  State<_EpisodeStripTile> createState() => _EpisodeStripTileState();
}

class _EpisodeStripTileState extends State<_EpisodeStripTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final progress = widget.episode.userData?.playbackPositionTicks != null &&
            widget.episode.runTimeTicks != null
        ? widget.episode.userData!.playbackPositionTicks! /
            widget.episode.runTimeTicks!
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: 92 * scale,
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 12 * scale,
          ),
          decoration: BoxDecoration(
            color: widget.isWatched
                ? widget.primaryColor.withValues(alpha: 0.14)
                : _isHovered
                    ? _detailCardSurface(context, hovered: true)
                    : _detailCardSurface(context),
            borderRadius: BorderRadius.circular(12 * scale),
            border: Border.all(
              color: widget.isWatched
                  ? widget.primaryColor.withValues(alpha: 0.34)
                  : _detailBorder(context, emphasis: 0.08),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.episode.indexNumber ?? '?'}',
                style: TextStyle(
                  fontSize: 22 * scale,
                  fontWeight: FontWeight.w800,
                  color: _detailPrimaryText(context).withValues(alpha: 0.94),
                ),
              ),
              SizedBox(height: 6 * scale),
              Text(
                widget.episode.formattedRuntime ?? '未播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11 * scale,
                  color: _detailHintText(context),
                ),
              ),
              if (progress != null) ...[
                SizedBox(height: 8 * scale),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 3 * scale,
                    backgroundColor: _detailBorder(context, emphasis: 0.08),
                    valueColor: AlwaysStoppedAnimation(widget.primaryColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 分季区域
// ============================================================================

class _SeasonsSection extends ConsumerStatefulWidget {
  final String seriesId;
  final String? selectedSeasonId;
  final Color primaryColor;
  final double scaleFactor;
  final Function(Season) onSeasonTap;

  const _SeasonsSection({
    required this.seriesId,
    this.selectedSeasonId,
    required this.primaryColor,
    required this.scaleFactor,
    required this.onSeasonTap,
  });

  @override
  ConsumerState<_SeasonsSection> createState() => _SeasonsSectionState();
}

class _SeasonsSectionState extends ConsumerState<_SeasonsSection> {
  @override
  Widget build(BuildContext context) {
    final seasonsAsync = ref.watch(seasonsProvider(widget.seriesId));

    return seasonsAsync.when(
      data: (seasons) {
        if (seasons.isEmpty) return const SizedBox.shrink();

        // 排序：特别篇放最后
        final sorted = [...seasons];
        sorted.sort((a, b) {
          final aSpecial = (a.indexNumber ?? 0) == 0;
          final bSpecial = (b.indexNumber ?? 0) == 0;
          if (aSpecial && !bSpecial) return 1;
          if (!aSpecial && bSpecial) return -1;
          return (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
        });

        return _HorizontalScrollList(
          title: '分季',
          primaryColor: widget.primaryColor,
          scaleFactor: widget.scaleFactor,
          itemWidth: 120 * widget.scaleFactor,
          itemHeight: 200 * widget.scaleFactor,
          children: sorted.map((season) {
            final isSelected = season.id == widget.selectedSeasonId;
            final isSpecial = (season.indexNumber ?? 0) == 0;

            return _SeasonCard(
              season: season,
              isSelected: isSelected,
              isSpecial: isSpecial,
              scaleFactor: widget.scaleFactor,
              primaryColor: widget.primaryColor,
              onTap: () => widget.onSeasonTap(season),
            );
          }).toList(),
        );
      },
      loading: () => _buildSkeleton(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildSkeleton() {
    final scale = widget.scaleFactor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '分季',
          scaleFactor: scale,
          primaryColor: widget.primaryColor,
        ),
        SizedBox(height: 16 * scale),
        SizedBox(
          height: 200 * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 3,
            separatorBuilder: (_, __) => SizedBox(width: 16 * scale),
            itemBuilder: (_, __) => Container(
              width: 120 * scale,
              decoration: BoxDecoration(
                color: _detailPlaceholderSurface(context),
                borderRadius: BorderRadius.circular(8 * scale),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 分季卡片
// ============================================================================

class _SeasonCard extends StatefulWidget {
  final Season season;
  final bool isSelected;
  final bool isSpecial;
  final double scaleFactor;
  final Color primaryColor;
  final VoidCallback onTap;

  const _SeasonCard({
    required this.season,
    required this.isSelected,
    required this.isSpecial,
    required this.scaleFactor,
    required this.primaryColor,
    required this.onTap,
  });

  @override
  State<_SeasonCard> createState() => _SeasonCardState();
}

class _SeasonCardState extends State<_SeasonCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final opacity = widget.isSelected
        ? 1.0
        : _isHovered
            ? 1.0
            : 0.7;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: opacity,
          child: Container(
            width: 120 * scale,
            decoration: BoxDecoration(
              color: _detailCardSurface(context, hovered: _isHovered),
              borderRadius: BorderRadius.circular(8 * scale),
              border: widget.isSelected
                  ? Border.all(
                      color: widget.primaryColor,
                      width: 2,
                    )
                  : null,
              boxShadow: widget.isSelected
                  ? [
                      BoxShadow(
                        color: widget.primaryColor.withValues(alpha: 0.3),
                        blurRadius: 12 * scale,
                        offset: Offset(0, 2 * scale),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 海报
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8 * scale),
                    child: Consumer(
                      builder: (context, ref, child) {
                        final api = ref.read(apiClientProvider);
                        final imageUrls = resolveSeasonImageUrls(
                          api,
                          widget.season,
                          maxWidth: 300,
                        );
                        return MediaImage(
                          imageUrl: imageUrls.isNotEmpty
                              ? imageUrls.first
                              : null,
                          width: 120 * scale,
                          height: 180 * scale,
                          fit: BoxFit.cover,
                          placeholder: Container(
                            color: _detailPlaceholderSurface(context),
                            child: Center(
                              child: Text(
                                widget.season.name.isNotEmpty
                                    ? widget.season.name.substring(0, 1)
                                    : '?',
                                style: TextStyle(
                                  fontSize: 32 * scale,
                                  fontWeight: FontWeight.bold,
                                  color: _detailHintText(context),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                SizedBox(height: 8 * scale),
                // 季名称
                Text(
                  widget.isSpecial ? '特别篇' : widget.season.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13 * scale,
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: _detailPrimaryText(context),
                  ),
                ),
                // 选中指示器
                if (widget.isSelected)
                  Container(
                    margin: EdgeInsets.only(top: 4 * scale),
                    width: 16 * scale,
                    height: 3 * scale,
                    decoration: BoxDecoration(
                      color: widget.primaryColor,
                      borderRadius: BorderRadius.circular(2 * scale),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 演职人员区域
// ============================================================================

class _CastSection extends StatelessWidget {
  final List<Person> persons;
  final Color primaryColor;
  final double scaleFactor;

  const _CastSection({
    required this.persons,
    required this.primaryColor,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context) {
    if (persons.isEmpty) {
      return const SizedBox.shrink();
    }

    final displayPersons = persons.take(15).toList(growable: false);
    return _HorizontalScrollList(
      title: '演职人员',
      primaryColor: primaryColor,
      scaleFactor: scaleFactor,
      itemWidth: 90 * scaleFactor,
      itemHeight: 130 * scaleFactor,
      children: displayPersons.map((person) {
        return _PersonCard(
          person: person,
          scaleFactor: scaleFactor,
          onTap: () {
            context.push('/search?q=${Uri.encodeComponent(person.name)}');
          },
        );
      }).toList(growable: false),
    );
  }
}

// ============================================================================
// 演职人员卡片
// ============================================================================

class _PersonCard extends StatefulWidget {
  final Person person;
  final double scaleFactor;
  final VoidCallback onTap;

  const _PersonCard({
    required this.person,
    required this.scaleFactor,
    required this.onTap,
  });

  @override
  State<_PersonCard> createState() => _PersonCardState();
}

class _PersonCardState extends State<_PersonCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 90 * scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像
              ClipRRect(
                borderRadius: BorderRadius.circular(4 * scale),
                child: Container(
                  width: 90 * scale,
                  height: 100 * scale,
                  color: _detailPlaceholderSurface(context),
                  child: Consumer(
                    builder: (context, ref, child) {
                      if (widget.person.primaryImageTag == null) {
                        return Center(
                          child: Text(
                            widget.person.name.isNotEmpty
                                ? widget.person.name.substring(0, 1)
                                : '?',
                            style: TextStyle(
                              fontSize: 28 * scale,
                              fontWeight: FontWeight.bold,
                              color: _detailHintText(context),
                            ),
                          ),
                        );
                      }
                      final api = ref.read(apiClientProvider);
                      final imageUrl = api.image.getPrimaryImageUrl(
                        widget.person.id,
                        tag: widget.person.primaryImageTag,
                        maxWidth: 200,
                      );
                      return MediaImage(
                        imageUrl: imageUrl,
                        width: 90 * scale,
                        height: 100 * scale,
                        fit: BoxFit.cover,
                        placeholder: Container(
                          color: _detailPlaceholderSurface(context),
                        ),
                      );
                    },
                  ),
                ),
              ),
              SizedBox(height: 6 * scale),
              // 姓名
              Tooltip(
                message: widget.person.name,
                waitDuration: const Duration(milliseconds: 500),
                child: Text(
                  widget.person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14 * scale,
                    fontWeight: _isHovered ? FontWeight.w600 : FontWeight.w400,
                    color: _detailPrimaryText(context),
                  ),
                ),
              ),
              // 职位
              if (widget.person.role != null)
                Tooltip(
                  message: widget.person.role!,
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text(
                    widget.person.role!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12 * scale,
                      color: _detailHintText(context),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 相关推荐区域
// ============================================================================

class _RelatedSection extends ConsumerStatefulWidget {
  final String itemId;
  final Color primaryColor;
  final double scaleFactor;

  const _RelatedSection({
    required this.itemId,
    required this.primaryColor,
    required this.scaleFactor,
  });

  @override
  ConsumerState<_RelatedSection> createState() => _RelatedSectionState();
}

class _RelatedSectionState extends ConsumerState<_RelatedSection> {
  @override
  Widget build(BuildContext context) {
    final relatedAsync = ref.watch(similarItemsProvider(widget.itemId));

    return relatedAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        final scale = widget.scaleFactor;
        final crossAxisCount = (items.length >= 6) ? 6 : items.length;
        final cardWidth = (1400 - (crossAxisCount - 1) * 16) / crossAxisCount;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(
              title: '相关推荐',
              scaleFactor: scale,
              primaryColor: widget.primaryColor,
            ),
            SizedBox(height: 16 * scale),
            Wrap(
              spacing: 16 * scale,
              runSpacing: 16 * scale,
              children: items.take(crossAxisCount).map((item) {
                return DesktopMediaCard(
                  item: item,
                  width: cardWidth * scale,
                  showProgress: false,
                );
              }).toList(),
            ),
          ],
        );
      },
      loading: () => _buildSkeleton(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildSkeleton() {
    final scale = widget.scaleFactor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '相关推荐',
          scaleFactor: scale,
          primaryColor: widget.primaryColor,
        ),
        SizedBox(height: 16 * scale),
        Wrap(
          spacing: 16 * scale,
          children: List.generate(
            6,
            (_) => Container(
              width: 160 * scale,
              height: 240 * scale,
              decoration: BoxDecoration(
                color: _detailPlaceholderSurface(context),
                borderRadius: BorderRadius.circular(8 * scale),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 骨架屏
// ============================================================================

class _SkeletonView extends StatelessWidget {
  const _SkeletonView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Hero骨架
          Container(
            height: 400,
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: 6,
              itemBuilder: (_, __) => Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 错误视图
// ============================================================================

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              '加载详情失败',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString().replaceAll('Exception: ', '').replaceAll('DioException ', ''),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: _detailSecondaryText(context),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 图片 URL 解析辅助函数（Episode / Season 专用）
// ============================================================================

List<String> resolveEpisodeImageUrls(
  ApiClientFactory api,
  Episode episode, {
  int? maxWidth,
}) {
  final urls = <String>[];
  if (episode.primaryImageTag != null) {
    urls.add(api.image.getPrimaryImageUrl(
      episode.id,
      tag: episode.primaryImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (episode.thumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      episode.id,
      tag: episode.thumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (episode.parentThumbItemId != null && episode.parentThumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      episode.parentThumbItemId!,
      tag: episode.parentThumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (episode.seriesId.isNotEmpty && episode.seriesThumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      episode.seriesId,
      tag: episode.seriesThumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  return urls.where((u) => u.isNotEmpty).toList();
}

List<String> resolveSeasonImageUrls(
  ApiClientFactory api,
  Season season, {
  int? maxWidth,
}) {
  final urls = <String>[];
  if (season.primaryImageTag != null) {
    urls.add(api.image.getPrimaryImageUrl(
      season.id,
      tag: season.primaryImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (season.thumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      season.id,
      tag: season.thumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (season.seriesId.isNotEmpty && season.seriesPrimaryImageTag != null) {
    urls.add(api.image.getPrimaryImageUrl(
      season.seriesId,
      tag: season.seriesPrimaryImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (season.seriesId.isNotEmpty && season.seriesThumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      season.seriesId,
      tag: season.seriesThumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  return urls.where((u) => u.isNotEmpty).toList();
}
