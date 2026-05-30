import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/media_providers.dart';
import '../../widgets/common/media_widgets.dart';

/// 首页
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final ScrollController _scrollController = ScrollController();
  double _appBarOpacity = 1.0;
  double _lastScrollOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final delta = offset - _lastScrollOffset;

    setState(() {
      if (delta > 0) {
        // 向下滑动，渐隐
        _appBarOpacity = (_appBarOpacity - delta / 100).clamp(0.0, 1.0);
      } else if (delta < 0) {
        // 向上滑动，渐显
        _appBarOpacity = (_appBarOpacity - delta / 100).clamp(0.0, 1.0);
      }
    });

    _lastScrollOffset = offset;
  }
  
  @override
  Widget build(BuildContext context) {
    final currentServer = ref.watch(currentServerProvider);
    final hideDailyRecommendations = ref.watch(hideDailyRecommendationsProvider);
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 占位区域（顶栏高度）
              const SliverToBoxAdapter(
                child: SizedBox(height: 60),
              ),

              // 随机推荐轮播（可被隐藏）
              if (!hideDailyRecommendations)
                const SliverToBoxAdapter(
                  child: RandomRecommendationCarousel(),
                ),

              // 继续观看
              const SliverToBoxAdapter(child: ContinueWatchingSection()),

              // 媒体库
              const SliverToBoxAdapter(child: LibrariesSection()),

              // 各媒体库最新内容
              const SliverToBoxAdapter(child: LatestItemsSections()),

              const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
            ],
          ),
          // 顶部栏（悬浮，透明背景+封面）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _appBarOpacity,
              duration: const Duration(milliseconds: 150),
              child: _HomeAppBar(
                serverName: currentServer?.name ?? '服务器',
                backgroundImage: recommendationsAsync.when(
                  data: (items) => items.isNotEmpty ? items.first : null,
                  loading: () => null,
                  error: (_, __) => null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// 首页顶部栏
class _HomeAppBar extends ConsumerStatefulWidget {
  final String serverName;
  final MediaItem? backgroundImage;

  const _HomeAppBar({required this.serverName, this.backgroundImage});

  @override
  ConsumerState<_HomeAppBar> createState() => _HomeAppBarState();
}

class _HomeAppBarState extends ConsumerState<_HomeAppBar> {
  OverlayEntry? _serverMenuOverlay;
  final GlobalKey _serverButtonKey = GlobalKey();

  void _showServerSelector() {
    final servers = ref.read(serverListProvider);
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无服务器')),
      );
      return;
    }

    _hideServerMenu();

    final renderBox = _serverButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;

    _serverMenuOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          GestureDetector(
            onTap: _hideServerMenu,
            child: Container(color: Colors.black54),
          ),
          Positioned(
            left: 16,
            top: position.dy + size.height + 8,
            width: screenWidth - 32,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surface,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '切换服务器',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Divider(height: 1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 350),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: servers.length,
                        itemBuilder: (context, index) {
                          final server = servers[index];
                          final isCurrent = server.id == ref.read(currentServerProvider)?.id;
                          return ListTile(
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: server.iconUrl != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: MediaImage(imageUrl: server.iconUrl, width: 36, height: 36, fit: BoxFit.cover),
                                    )
                                  : const Icon(Icons.dns, size: 18, color: Color(0xFF5B8DEF)),
                            ),
                            title: Text(server.name),
                            subtitle: Text(
                              server.activeLineUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: isCurrent
                                ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                                : null,
                            onTap: () {
                              _hideServerMenu();
                              ref.read(currentServerProvider.notifier).state = server;
                              if (server.authToken != null) {
                                ref.read(authStateProvider.notifier).state = AuthState.authenticated;
                              }
                              ref.invalidate(librariesProvider);
                              ref.invalidate(resumeItemsProvider);
                              ref.invalidate(randomRecommendationsProvider);
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_serverMenuOverlay!);
  }

  void _hideServerMenu() {
    _serverMenuOverlay?.remove();
    _serverMenuOverlay = null;
  }

  @override
  void dispose() {
    _hideServerMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // 服务器名称（可点击切换）
              GestureDetector(
                key: _serverButtonKey,
                onTap: _showServerSelector,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.dns, size: 18, color: Color(0xFF5B8DEF)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.serverName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.grey),
                  ],
                ),
              ),
              const Spacer(),
              // 媒体库按钮
              IconButton(
                icon: const Icon(Icons.collections_bookmark),
                onPressed: () {
                  context.push('/libraries');
                },
              ),
              // 搜索按钮
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {
                  context.push('/search');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 随机推荐轮播
class RandomRecommendationCarousel extends ConsumerStatefulWidget {
  const RandomRecommendationCarousel({super.key});
  
  @override
  ConsumerState<RandomRecommendationCarousel> createState() => _RandomRecommendationCarouselState();
}

class _RandomRecommendationCarouselState extends ConsumerState<RandomRecommendationCarousel> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  
  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    final carouselHeight = screenHeight * 0.6;
    
    return recommendationsAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        
        return SizedBox(
          height: carouselHeight,
          child: Stack(
            children: [
              // 轮播内容
              PageView.builder(
                controller: _pageController,
                itemCount: items.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _CarouselItem(
                    item: item,
                    onTap: () => context.push('/detail/${item.id}'),
                  );
                },
              ),
              
              // 指示器
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(items.length, (index) {
                    return Container(
                      width: index == _currentPage ? 20 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: index == _currentPage
                            ? const Color(0xFF5B8DEF)
                            : Colors.white.withValues(alpha: 0.5),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => SizedBox(
        height: carouselHeight,
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _CarouselItem extends ConsumerWidget {
  final MediaItem item;
  final VoidCallback onTap;
  
  const _CarouselItem({required this.item, required this.onTap});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = item.backdropImageTag != null
        ? api.image.getBackdropImageUrl(item.id, tag: item.backdropImageTag, maxWidth: 800)
        : item.primaryImageTag != null
            ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 800)
            : null;
    
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaImage(
            imageUrl: imageUrl,
            width: double.infinity,
            height: double.infinity,
          ),

          // 底部渐变遮罩（过渡到页面背景色）
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 280,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.3),
                    Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
                    Theme.of(context).scaffoldBackgroundColor,
                  ],
                  stops: const [0.0, 0.3, 0.8, 1.0],
                ),
              ),
            ),
          ),

          // 底部信息
          Positioned(
            bottom: 40,
            left: 16,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    shadows: [
                      Shadow(blurRadius: 8, color: Colors.black54),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (item.communityRating != null) ...[
                      const Icon(Icons.star, size: 18, color: Colors.amber),
                      const SizedBox(width: 4),
                      Text(
                        item.communityRating!.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    ...?item.genres?.take(5).map((genre) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          genre,
                          style: const TextStyle(fontSize: 12, color: Colors.white),
                        ),
                      ),
                    )),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 继续观看区块
class ContinueWatchingSection extends ConsumerWidget {
  const ContinueWatchingSection({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeAsync = ref.watch(resumeItemsProvider);
    
    return resumeAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '继续观看',
              onMoreTap: () => _showContinueWatchingSheet(context, ref),
            ),
            HorizontalList(
              height: 140,
              children: items.where((item) => !(item.userData?.played ?? false)).map((item) {
                return _ContinueWatchingCard(item: item);
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  void _showContinueWatchingSheet(BuildContext context, WidgetRef ref) {
    final resumeAsync = ref.read(resumeItemsProvider);
    resumeAsync.when(
      data: (items) {
        if (items.isEmpty) return;
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (context) => DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) {
              return SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Text(
                            '继续观看',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: GridView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 1.5,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return _ContinueWatchingCard(item: item);
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
      loading: () {},
      error: (_, __) {},
    );
  }
}

class _ContinueWatchingCard extends ConsumerWidget {
  final MediaItem item;

  const _ContinueWatchingCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    // 使用集封面（横向缩略图）
    final imageUrl = item.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 400)
        : null;

    final isEpisode = item.type == 'Episode';
    final seasonEpisodeText = isEpisode && item.parentIndexNumber != null && item.indexNumber != null
        ? 'S${item.parentIndexNumber}E${item.indexNumber}'
        : null;

    return GestureDetector(
      onTap: () {
        if (isEpisode && item.seriesId != null) {
          context.push('/detail/${item.seriesId}');
        } else {
          context.push('/detail/${item.id}');
        }
      },
      child: SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面图 + 进度条（横向16:9，保持原始比例）
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      imageUrl: imageUrl,
                      width: 160,
                      height: 90,
                      fit: BoxFit.contain,
                    ),
                    // 底部渐变（增强进度条可读性）
                    if (item.progress != null)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 24,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.6),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // 进度条
                    if (item.progress != null)
                      Positioned(
                        bottom: 6,
                        left: 8,
                        right: 8,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor: Colors.white.withValues(alpha: 0.3),
                            valueColor: const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
                            minHeight: 3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 标题
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            // 季集信息
            if (seasonEpisodeText != null)
              Text(
                seasonEpisodeText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 媒体库区块
class LibrariesSection extends ConsumerWidget {
  const LibrariesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);

    return librariesAsync.when(
      data: (libraries) {
        if (libraries.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '媒体库',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.push('/libraries'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '查看全部',
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
            ),
            HorizontalList(
              height: 145,
              children: libraries.map((library) {
                return SizedBox(
                  width: 135,
                  child: _LibraryCard(library: library),
                );
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _LibraryCard extends ConsumerWidget {
  final Library library;

  const _LibraryCard({required this.library});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = library.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(library.id, tag: library.primaryImageTag, maxWidth: 400)
        : null;

    return GestureDetector(
      onTap: () => context.push('/library/${library.id}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 135,
            height: 100,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: imageUrl != null
                ? MediaImage(
                    imageUrl: imageUrl,
                    width: 135,
                    height: 100,
                    fit: BoxFit.contain,
                    borderRadius: BorderRadius.circular(12),
                  )
                : Container(
                    color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                    child: const Center(
                      child: Icon(
                        Icons.folder,
                        size: 36,
                        color: Color(0xFF5B8DEF),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 135,
            child: Text(
              library.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// 各媒体库最新内容区块
class LatestItemsSections extends ConsumerWidget {
  const LatestItemsSections({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);
    
    return librariesAsync.when(
      data: (libraries) {
        return Column(
          children: libraries.map((library) {
            return _LibraryLatestSection(library: library);
          }).toList(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _LibraryLatestSection extends ConsumerWidget {
  final Library library;
  
  const _LibraryLatestSection({required this.library});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latestAsync = ref.watch(latestItemsProvider(library.id));
    
    return latestAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    library.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.push('/library/${library.id}'),
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
            ),
            HorizontalList(
              height: 200,
              children: items.map((item) {
                return SizedBox(
                  width: 120,
                  child: MediaPoster(
                    item: item,
                    width: 120,
                    height: 160,
                    onTap: () => context.push('/detail/${item.id}'),
                  ),
                );
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
