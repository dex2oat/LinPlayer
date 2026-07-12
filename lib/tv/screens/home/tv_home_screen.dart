import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/screens/home/home_screen.dart' show RandomRecommendationCarousel;
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/dynamic_background.dart';
import '../anirss/tv_anirss_view.dart';
import '../source/tv_source_browse_screen.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_media_card.dart';

/// TV 首页
///
/// 观感对齐移动端：沉浸式 Hero 轮播（每日推荐，遥控器左右翻页 + 取色染背景）+
/// 继续观看 + 媒体库 + 各库最新 + 合集，卡片全部复用移动端 MediaPoster/MediaImage，
/// 交互换成焦点驱动。
class TvHomeScreen extends ConsumerStatefulWidget {
  const TvHomeScreen({super.key});

  @override
  ConsumerState<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends ConsumerState<TvHomeScreen> {
  /// Hero 取色 → 整页沉浸背景（对齐移动端）。默认深色。
  Color _bgColor = const Color(0xFF121212);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  void _refresh() {
    ref.invalidate(resumeItemsProvider);
    ref.invalidate(librariesProvider);
    ref.invalidate(randomRecommendationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final servers = ref.watch(serverListProvider);
    if (servers.isEmpty) {
      return _buildEmptyServers(m);
    }

    // 网盘/聚合源：首页改渲染对应视图（保留侧边栏）。
    final currentServer = ref.watch(currentServerProvider);
    if (currentServer != null && currentServer.sourceKind == SourceKind.anirss) {
      return TvAniRssView(server: currentServer);
    }
    if (currentServer != null && currentServer.isFileBrowse) {
      return TvSourceBrowseView(server: currentServer);
    }

    final api = ref.read(apiClientProvider);
    final resumeAsync = ref.watch(resumeItemsProvider);
    final librariesAsync = ref.watch(librariesProvider);
    final hideDaily = ref.watch(hideDailyRecommendationsProvider);

    return DynamicBackground(
      backgroundColor: _bgColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero 轮播（每日推荐）——复用移动端组件 + 遥控器方向键翻页 + 取色。
              if (!hideDaily)
                RandomRecommendationCarousel(
                  dpadFocus: true,
                  autofocus: true,
                  onColorChanged: (c) {
                    if (mounted && c != _bgColor) {
                      setState(() => _bgColor = c);
                    }
                  },
                ),
              SizedBox(height: m.spacingMd),

              // 继续观看
              resumeAsync.when(
                data: (items) {
                  final visible = items
                      .where((i) => !(i.userData?.played ?? false))
                      .toList(growable: false);
                  if (visible.isEmpty) return const SizedBox.shrink();
                  return TvRow(
                    title: '继续观看',
                    rowHeight: m.posterHeight16_9 + m.s(80),
                    cards: [
                      for (final it in visible)
                        TvLandscapeCard(
                          imageUrl: _first(resolveMediaItemLandscapeImageUrls(
                              api, it,
                              maxWidth: 720)),
                          title: _continueTitle(it),
                          subtitle: _continueSubtitle(it),
                          badge: _continueBadge(it),
                          progress: it.progress,
                          onSelect: () => context.push('/tv/detail/${_detailId(it)}'),
                        ),
                    ],
                  );
                },
                loading: () => _rowPlaceholder('继续观看', m),
                error: (_, __) => const SizedBox.shrink(),
              ),
              SizedBox(height: m.spacingMd),

              // 媒体库快捷入口
              librariesAsync.when(
                data: (libs) {
                  if (libs.isEmpty) return const SizedBox.shrink();
                  return TvRow(
                    title: '媒体库',
                    rowHeight: m.posterHeight16_9 + m.s(64),
                    onSeeAll: () => context.go('/tv/library'),
                    cards: [
                      for (final lib in libs)
                        TvLandscapeCard(
                          imageUrl: _first(
                              resolveLibraryImageUrls(api, lib, maxWidth: 400)),
                          title: lib.name,
                          onSelect: () =>
                              context.go('/tv/library?libraryId=${lib.id}'),
                        ),
                    ],
                  );
                },
                loading: () => _rowPlaceholder('媒体库', m),
                error: (_, __) => const SizedBox.shrink(),
              ),
              SizedBox(height: m.spacingMd),

              // 各媒体库最新内容（每库一行 2:3 海报）
              librariesAsync.when(
                data: (libs) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final lib in libs)
                      Padding(
                        padding: EdgeInsets.only(bottom: m.spacingSm),
                        child: _TvLibraryLatestRow(library: lib),
                      ),
                  ],
                ),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
              SizedBox(height: m.spacingMd),

              // 合集（最底部）
              ref.watch(collectionsProvider).maybeWhen(
                    data: (cols) {
                      if (cols.isEmpty) return const SizedBox.shrink();
                      return TvRow(
                        title: '合集',
                        rowHeight: m.posterHeight2_3 + m.s(80),
                        cards: [
                          for (final c in cols)
                            TvMediaCard(
                              item: c,
                              onSelect: () => context.go(
                                  '/tv/library?libraryId=${c.id}&title=${Uri.encodeComponent(c.name)}'),
                            ),
                        ],
                      );
                    },
                    orElse: () => const SizedBox.shrink(),
                  ),
              SizedBox(height: m.spacingXxl),
            ],
          ),
        ),
      ),
    );
  }

  // ============ 辅助 ============

  String? _first(List<String> urls) => urls.isNotEmpty ? urls.first : null;

  String _detailId(MediaItem it) =>
      (it.type == 'Episode' && (it.seriesId?.isNotEmpty ?? false))
          ? it.seriesId!
          : it.id;

  String _continueTitle(MediaItem it) {
    if (it.type == 'Episode') {
      final s = it.seriesName?.trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return it.name;
  }

  String? _continueSubtitle(MediaItem it) {
    if (it.type != 'Episode') return null;
    final parts = <String>[];
    if (it.parentIndexNumber != null) parts.add('第${it.parentIndexNumber}季');
    if (it.indexNumber != null) parts.add('第${it.indexNumber}集');
    if (it.name.trim().isNotEmpty) parts.add(it.name);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String? _continueBadge(MediaItem it) {
    if (it.type != 'Episode') return null;
    final s = it.parentIndexNumber;
    final e = it.indexNumber;
    if (s == null && e == null) return null;
    final sb = StringBuffer();
    if (s != null) sb.write('S$s');
    if (e != null) sb.write('E$e');
    return sb.toString();
  }

  // ============ 占位 / 空态 ============

  Widget _rowPlaceholder(String title, TvMetrics m) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingXl,
        vertical: m.spacingMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: m.fontSizeLg,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: m.spacingMd),
          SizedBox(
            height: m.posterHeight16_9,
            child: Row(
              children: List.generate(
                4,
                (i) => Container(
                  width: m.posterWidth16_9,
                  height: m.posterHeight16_9,
                  margin: EdgeInsets.only(right: m.posterSpacing),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                ),
              ),
            ),
          ).animate(onPlay: (c) => c.repeat()).shimmer(
                duration: TvDesignTokens.shimmerDuration,
                color: Colors.white10,
              ),
        ],
      ),
    );
  }

  Widget _buildEmptyServers(TvMetrics m) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              color: TvDesignTokens.textSecondary,
              size: m.s(96),
            ),
            SizedBox(height: m.spacingLg),
            Text(
              '还没有连接服务器',
              style: TextStyle(
                fontSize: m.fontSizeXl,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingSm),
            Text(
              '连接 Emby 服务器后即可浏览媒体库',
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.textSecondary,
              ),
            ),
            SizedBox(height: m.spacingXl),
            // 首启无服务器时，除了手动添加，还要能扫码导入配置、进设置——
            // 否则遥控器只有一个按钮可去，批量导入无路可走。
            Wrap(
              spacing: m.spacingMd,
              runSpacing: m.spacingMd,
              alignment: WrapAlignment.center,
              children: [
                TvButton(
                  text: '添加服务器',
                  icon: Icons.add,
                  autofocus: true,
                  onPressed: () => context.go('/tv/server'),
                ),
                TvButton(
                  text: '手机扫码导入',
                  icon: Icons.qr_code_scanner,
                  outlined: true,
                  onPressed: () => context.go('/tv/scan'),
                ),
                TvButton(
                  text: '设置',
                  icon: Icons.settings,
                  outlined: true,
                  onPressed: () => context.go('/tv/settings'),
                ),
              ],
            ),
          ],
        ).animate().fadeIn(duration: TvDesignTokens.contentFadeDuration).moveY(
              begin: 12,
              end: 0,
              duration: TvDesignTokens.contentFadeDuration,
              curve: Curves.easeOut,
            ),
      ),
    );
  }
}

/// 单个媒体库的「最新内容」横向行（每库一行 2:3 海报）。
class _TvLibraryLatestRow extends ConsumerWidget {
  final Library library;

  const _TvLibraryLatestRow({required this.library});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final latestAsync = ref.watch(latestItemsProvider(library.id));

    return latestAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return TvRow(
          title: library.name,
          rowHeight: m.posterHeight2_3 + m.s(80),
          onSeeAll: () => context.go('/tv/library?libraryId=${library.id}'),
          cards: [
            for (final it in items)
              TvMediaCard(
                item: it,
                onSelect: () => context.push('/tv/detail/${it.id}'),
              ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
