import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_motion.dart';
import '../theme/tv_design_tokens.dart';
import 'tv_focusable.dart';

/// TV Hero Banner
/// 自动轮播（10秒），支持遥控器左右切换
class TvHeroBanner extends StatefulWidget {
  final List<TvHeroItem> items;
  final VoidCallback? onAutoPlayStarted;
  final VoidCallback? onAutoPlayStopped;

  const TvHeroBanner({
    super.key,
    required this.items,
    this.onAutoPlayStarted,
    this.onAutoPlayStopped,
  });

  @override
  State<TvHeroBanner> createState() => _TvHeroBannerState();
}

class _TvHeroBannerState extends State<TvHeroBanner> {
  int _currentIndex = 0;
  Timer? _autoPlayTimer;
  bool _isPaused = false;
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    _autoPlayTimer?.cancel();
    _autoPlayTimer = Timer.periodic(
      TvDesignTokens.heroAutoPlayInterval,
      (_) => _nextPage(),
    );
    widget.onAutoPlayStarted?.call();
  }

  void _stopAutoPlay() {
    _autoPlayTimer?.cancel();
    widget.onAutoPlayStopped?.call();
  }

  void _nextPage() {
    if (_isPaused || widget.items.length <= 1) return;
    final nextIndex = (_currentIndex + 1) % widget.items.length;
    _pageController.animateToPage(
      nextIndex,
      duration: TvDesignTokens.heroTransitionDuration,
      curve: TvDesignTokens.heroTransitionCurve,
    );
  }

  void _previousPage() {
    if (widget.items.length <= 1) return;
    final prevIndex = (_currentIndex - 1 + widget.items.length) % widget.items.length;
    _pageController.animateToPage(
      prevIndex,
      duration: TvDesignTokens.heroTransitionDuration,
      curve: TvDesignTokens.heroTransitionCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    return Focus(
      onFocusChange: (focused) {
        setState(() => _isPaused = !focused);
        if (focused) {
          _startAutoPlay();
        } else {
          _stopAutoPlay();
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _nextPage();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _previousPage();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: TvDesignTokens.heroHeight,
        child: Stack(
          children: [
            // PageView 轮播
            PageView.builder(
              controller: _pageController,
              itemCount: widget.items.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) => _buildHeroItem(widget.items[index]),
            ),
            // 底部渐变遮罩
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: TvDesignTokens.heroOverlayHeight,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      TvDesignTokens.background.withOpacity(0.7),
                      TvDesignTokens.background,
                    ],
                  ),
                ),
              ),
            ),
            // 指示器
            Positioned(
              bottom: TvDesignTokens.spacingLg,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.items.length,
                  (index) => AnimatedContainer(
                    duration: TvDesignTokens.focusAnimationDuration,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentIndex == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentIndex == index
                          ? TvDesignTokens.brand
                          : const Color(0x40FFFFFF),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroItem(TvHeroItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景图
        item.imageUrl != null
            ? Image.network(
                item.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
              )
            : _buildPlaceholder(),
        // 渐变遮罩
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                TvDesignTokens.background.withOpacity(0.8),
                Colors.transparent,
              ],
            ),
          ),
        ),
        // 内容信息（随每张轮播淡入上滑）
        Positioned(
          left: TvDesignTokens.spacingXxl,
          bottom: TvDesignTokens.spacingXxl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLogoOrTitle(item),
              if (item.subtitle != null) ...[
                const SizedBox(height: TvDesignTokens.spacingSm),
                Text(
                  item.subtitle!,
                  style: const TextStyle(
                    fontSize: TvDesignTokens.heroSubtitleSize,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
              if (item.tags != null && item.tags!.isNotEmpty) ...[
                const SizedBox(height: TvDesignTokens.spacingSm),
                Row(
                  children: item.tags!.map((tag) {
                    return Container(
                      margin: const EdgeInsets.only(right: TvDesignTokens.spacingSm),
                      padding: const EdgeInsets.symmetric(
                        horizontal: TvDesignTokens.spacingSm,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surface,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(
                          fontSize: TvDesignTokens.fontSizeXs,
                          color: TvDesignTokens.textSecondary,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
              const SizedBox(height: TvDesignTokens.spacingLg),
              // 播放按钮
              if (item.onPlay != null)
                TvFocusable(
                  onSelect: item.onPlay,
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
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 32,
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
            ],
          ).appEntrance(),
        ),
      ],
    );
  }

  /// 优先使用 Logo 艺术字图片，无 Logo 时回退到文字标题
  Widget _buildLogoOrTitle(TvHeroItem item) {
    if (item.logoUrl != null && item.logoUrl!.isNotEmpty) {
      return Image.network(
        item.logoUrl!,
        height: 48,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, __, ___) => _buildTitleText(item.title),
        frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return _buildTitleText(item.title);
        },
      );
    }
    return _buildTitleText(item.title);
  }

  Widget _buildTitleText(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: TvDesignTokens.heroTitleSize,
        color: TvDesignTokens.textPrimary,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: TvDesignTokens.surfaceElevated,
      child: const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: TvDesignTokens.textDisabled,
          size: 64,
        ),
      ),
    );
  }
}

/// Hero Banner 数据模型
class TvHeroItem {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final List<String>? tags;
  final VoidCallback? onPlay;
  final VoidCallback? onDetail;
  final String? logoUrl;      // Logo 艺术字图片 URL

  const TvHeroItem({
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.tags,
    this.onPlay,
    this.onDetail,
    this.logoUrl,
  });
}
