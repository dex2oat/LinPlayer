import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../utils/media_helpers.dart';

class MediaImage extends StatelessWidget {
  final String? imageUrl;
  final List<String>? imageUrls;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final String? heroTag;
  final int? cacheWidth;
  final int? cacheHeight;

  const MediaImage({
    super.key,
    required this.imageUrl,
    this.imageUrls,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.heroTag,
    this.cacheWidth,
    this.cacheHeight,
  });

  @override
  Widget build(BuildContext context) {
    final candidates = {
      if (imageUrl != null && imageUrl!.isNotEmpty) imageUrl!,
      ...?imageUrls?.where((url) => url.isNotEmpty),
    }.toList();

    Widget image = candidates.isEmpty
        ? _buildPlaceholder(context)
        : _FallbackNetworkImage(
            imageUrls: candidates,
            width: width,
            height: height,
            fit: fit,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            placeholderBuilder: () => placeholder ?? _buildPlaceholder(context),
            errorBuilder: () => errorWidget ?? _buildError(context),
          );

    if (borderRadius != null) {
      image = ClipRRect(
        borderRadius: borderRadius!,
        child: image,
      );
    }

    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        child: image,
      );
    }

    return image;
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.image_outlined, size: 32, color: Colors.grey),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.errorContainer,
      child: const Center(
        child: Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey),
      ),
    );
  }
}

class _FallbackNetworkImage extends StatefulWidget {
  final List<String> imageUrls;
  final double? width;
  final double? height;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final Widget Function() placeholderBuilder;
  final Widget Function() errorBuilder;

  const _FallbackNetworkImage({
    required this.imageUrls,
    required this.width,
    required this.height,
    required this.fit,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.placeholderBuilder,
    required this.errorBuilder,
  });

  @override
  State<_FallbackNetworkImage> createState() => _FallbackNetworkImageState();
}

class _FallbackNetworkImageState extends State<_FallbackNetworkImage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // 修复：当width/height为无限时，使用屏幕尺寸作为缓存尺寸上限
    final cw = widget.cacheWidth ??
        (widget.width != null && widget.width!.isFinite && widget.width! > 0
            ? (widget.width! * dpr).ceil()
            : (screenWidth * dpr).ceil());
    final ch = widget.cacheHeight ??
        (widget.height != null && widget.height!.isFinite && widget.height! > 0
            ? (widget.height! * dpr).ceil()
            : (screenHeight * dpr).ceil());

    return ExtendedImage.network(
      widget.imageUrls[_currentIndex],
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      cache: true,
      cacheWidth: cw,
      cacheHeight: ch,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return widget.placeholderBuilder();
          case LoadState.completed:
            return state.completedWidget;
          case LoadState.failed:
            if (_currentIndex < widget.imageUrls.length - 1) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() {
                  _currentIndex += 1;
                });
              });
              return widget.placeholderBuilder();
            }
            return widget.errorBuilder();
        }
      },
    );
  }
}

/// 媒体封面组件 - 带有播放进度指示
class MediaPoster extends ConsumerWidget {
  final MediaItem item;
  final double width;
  final double height;
  final VoidCallback? onTap;
  final String? heroTag;

  const MediaPoster({
    super.key,
    required this.item,
    required this.width,
    required this.height,
    this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemImageUrls(api, item, maxWidth: 300);

    final useFill = !width.isFinite || !height.isFinite;

    Widget imageWidget = MediaImage(
      imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
      imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
      width: width.isFinite ? width : null,
      height: height.isFinite ? height : null,
      fit: BoxFit.contain,
      borderRadius: BorderRadius.circular(8),
      heroTag: heroTag,
    );

    if (useFill) {
      imageWidget = AspectRatio(
        aspectRatio: 2 / 3,
        child: imageWidget,
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: useFill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          useFill
              ? Expanded(
                  child: Stack(
                    children: [
                      imageWidget,
                      if (item.userData?.playbackPositionTicks != null &&
                          item.runTimeTicks != null)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(8),
                            ),
                            child: LinearProgressIndicator(
                              value: item.progress,
                              backgroundColor: Colors.black.withValues(alpha: 0.3),
                              valueColor: const AlwaysStoppedAnimation(
                                Color(0xFF5B8DEF),
                              ),
                              minHeight: 3,
                            ),
                          ),
                        ),
                      if (item.isWatched)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    imageWidget,
                    if (item.userData?.playbackPositionTicks != null &&
                        item.runTimeTicks != null)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(8),
                          ),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor: Colors.black.withValues(alpha: 0.3),
                            valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF5B8DEF),
                            ),
                            minHeight: 3,
                          ),
                        ),
                      ),
                    if (item.isWatched)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
          const SizedBox(height: 6),
          SizedBox(
            width: width.isFinite ? width : double.infinity,
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          if (item.seriesName != null)
            SizedBox(
              width: width.isFinite ? width : double.infinity,
              child: Text(
                '${item.seriesName} | S${item.parentIndexNumber}E${item.indexNumber}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 骨架屏组件
class Skeleton extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;

  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: borderRadius ?? BorderRadius.circular(8),
      ),
    );
  }
}

/// 横向滑条组件
class HorizontalList extends StatelessWidget {
  final List<Widget> children;
  final double spacing;
  final EdgeInsets padding;
  final double? height;

  const HorizontalList({
    super.key,
    required this.children,
    this.spacing = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: children.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        separatorBuilder: (_, __) => SizedBox(width: spacing),
        itemBuilder: (_, index) => RepaintBoundary(
          child: children[index],
        ),
      ),
    );
  }
}

/// 带标题的横向滑条区块
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMoreTap;

  const SectionHeader({
    super.key,
    required this.title,
    this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onMoreTap != null)
            GestureDetector(
              onTap: onMoreTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '查看更多',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 评分组件
class RatingBadge extends StatelessWidget {
  final double? rating;
  final double size;

  const RatingBadge({
    super.key,
    this.rating,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    if (rating == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star, size: size, color: Colors.amber),
        const SizedBox(width: 2),
        Text(
          rating!.toStringAsFixed(1),
          style: TextStyle(
            fontSize: size - 1,
            fontWeight: FontWeight.w600,
            color: Colors.amber.shade700,
          ),
        ),
      ],
    );
  }
}

/// 标签组件
class TagBadge extends StatelessWidget {
  final String text;
  final Color? backgroundColor;
  final Color? textColor;

  const TagBadge({
    super.key,
    required this.text,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: textColor ?? Theme.of(context).textTheme.bodySmall?.color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
