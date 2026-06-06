import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/utils/color_extractor.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/media_widgets.dart';

/// 首页构建性能优化
/// 
/// 减少首次构建开销的策略：
/// 1. 使用 RepaintBoundary 隔离复杂区域的重绘
/// 2. 延迟加载非首屏内容（通过 Visibility 或 Future.delayed）
/// 3. 降低轮播图图片分辨率

/// 首页
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  double _appBarOpacity = 1.0;
  double _lastScrollOffset = 0.0;
  Color _backgroundColor = const Color(0xFF121212);

  @override
  bool get wantKeepAlive => true;

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

    // 使用微任务避免setState过于频繁导致掉帧
    if (delta.abs() > 2) {
      setState(() {
        if (delta > 0) {
          _appBarOpacity = (_appBarOpacity - delta / 100).clamp(0.0, 1.0);
        } else if (delta < 0) {
          _appBarOpacity = (_appBarOpacity - delta / 100).clamp(0.0, 1.0);
        }
      });
    }

    _lastScrollOffset = offset;
  }

  void _onBackgroundColorChanged(Color color) {
    if (_backgroundColor != color) {
      setState(() {
        _backgroundColor = color;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentServer = ref.watch(currentServerProvider);
    final hideDailyRecommendations = ref.watch(hideDailyRecommendationsProvider);
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);
    final foregroundColor = readableTextColorForBackground(_backgroundColor);

    return Scaffold(
      backgroundColor: _backgroundColor,
      body: Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(context).textTheme.apply(
                bodyColor: foregroundColor,
                displayColor: foregroundColor,
              ),
        ),
        child: Stack(
          children: [
            CustomScrollView(
              controller: _scrollController,
              slivers: [
                // 随机推荐轮播（可被隐藏）- 直接顶到最上方
                if (!hideDailyRecommendations)
                  SliverToBoxAdapter(
                    child: RandomRecommendationCarousel(
                      onColorChanged: _onBackgroundColorChanged,
                    ),
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
            // 顶部栏（悬浮，透明背景）
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
      ),
    );
  }
}

/// 服务器选择器覆盖层（带动画和透明效果）
class _ServerSelectorOverlay extends StatefulWidget {
  final List<ServerConfig> servers;
  final Offset buttonPosition;
  final Size buttonSize;
  final double screenWidth;
  final double screenHeight;
  final VoidCallback onDismiss;

  const _ServerSelectorOverlay({
    required this.servers,
    required this.buttonPosition,
    required this.buttonSize,
    required this.screenWidth,
    required this.screenHeight,
    required this.onDismiss,
  });

  @override
  State<_ServerSelectorOverlay> createState() => _ServerSelectorOverlayState();
}

class _ServerSelectorOverlayState extends State<_ServerSelectorOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _dismiss() {
    _animationController.reverse().then((_) {
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 计算最大文本宽度：基于最长服务器名字
    final maxTextWidth = widget.servers
        .map((s) => s.name.length * 16.0) // 估计每个字符16px
        .reduce((a, b) => a > b ? a : b);
    final containerWidth = (56 + maxTextWidth + 48).clamp(180.0, widget.screenWidth * 0.7);

    return GestureDetector(
      onTap: _dismiss,
      child: AnimatedBuilder(
        animation: _fadeAnimation,
        builder: (context, child) {
          return Container(
            color: Colors.transparent,
            child: child,
          );
        },
        child: Stack(
          children: [
            Positioned(
              left: widget.buttonPosition.dx,
              top: widget.buttonPosition.dy + widget.buttonSize.height,
              child: SlideTransition(
                position: _slideAnimation,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final currentServerId = ref.watch(currentServerProvider)?.id;
                      return Container(
                        width: containerWidth,
                        decoration: const BoxDecoration(
                          color: Colors.transparent,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: widget.servers.length,
                            itemBuilder: (context, index) {
                              final server = widget.servers[index];
                              final isCurrent = server.id == currentServerId;
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    _dismiss();
                                    Future.delayed(const Duration(milliseconds: 150), () {
                                      ref.read(currentServerProvider.notifier).state = server;
                                      if (server.authToken != null) {
                                        ref.read(authStateProvider.notifier).state = AuthState.authenticated;
                                      }
                                      ref.invalidate(librariesProvider);
                                      ref.invalidate(resumeItemsProvider);
                                      ref.invalidate(randomRecommendationsProvider);
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: server.iconUrl != null
                                              ? ClipRRect(
                                                  borderRadius: BorderRadius.circular(8),
                                                  child: MediaImage(
                                                    imageUrl: server.iconUrl,
                                                    width: 32,
                                                    height: 32,
                                                    fit: BoxFit.cover,
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.dns,
                                                  size: 16,
                                                  color: Color(0xFF5B8DEF),
                                                ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            server.name,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: isCurrent
                                                  ? const Color(0xFF5B8DEF)
                                                  : Colors.black,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (isCurrent)
                                          const Icon(
                                            Icons.check_circle,
                                            color: Color(0xFF5B8DEF),
                                            size: 18,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
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
    final screenHeight = MediaQuery.of(context).size.height;

    _serverMenuOverlay = OverlayEntry(
      builder: (context) => _ServerSelectorOverlay(
        servers: servers,
        buttonPosition: position,
        buttonSize: size,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        onDismiss: _hideServerMenu,
      ),
    );

    Overlay.of(context).insert(_serverMenuOverlay!);
  }

  void _hideServerMenu() {
    _serverMenuOverlay?.remove();
    _serverMenuOverlay = null;
  }

  @override
  void deactivate() {
    _hideServerMenu();
    super.deactivate();
  }

  @override
  void dispose() {
    _hideServerMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentServer = ref.watch(currentServerProvider);

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
                      child: currentServer?.iconUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: MediaImage(
                                imageUrl: currentServer!.iconUrl,
                                width: 32,
                                height: 32,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Icon(Icons.dns, size: 18, color: Color(0xFF5B8DEF)),
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
                  context.go('/libraries');
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
  final ValueChanged<Color>? onColorChanged;

  const RandomRecommendationCarousel({super.key, this.onColorChanged});

  @override
  ConsumerState<RandomRecommendationCarousel> createState() => _RandomRecommendationCarouselState();
}

class _RandomRecommendationCarouselState extends ConsumerState<RandomRecommendationCarousel> {
  PageController? _pageController;
  int _currentPage = 0;
  Color _dominantColor = Colors.transparent;
  Color _backgroundColor = const Color(0xFF121212);
  String? _itemsSignature;
  int _colorPrefetchToken = 0;
  // 颜色缓存：itemId -> ExtractedColors
  final Map<String, ExtractedColors> _colorCache = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _colorPrefetchToken++;
    _colorCache.clear();
    _pageController?.dispose();
    _pageController = null;
    super.dispose();
  }

  /// 只预取当前页附近的颜色，避免离开首页后仍有大量任务排队。
  Future<void> _precacheColors(List<MediaItem> items, int centerIndex) async {
    if (items.isEmpty) return;

    final api = ref.read(apiClientProvider);
    final int sessionId = ++_colorPrefetchToken;
    final int safeIndex = centerIndex.clamp(0, items.length - 1);

    for (final index in _buildPrefetchIndexes(safeIndex, items.length)) {
      if (!mounted || sessionId != _colorPrefetchToken) return;

      final item = items[index];
      if (!_colorCache.containsKey(item.id)) {
        final imageUrl = item.backdropImageTag != null
            ? api.image.getBackdropImageUrl(item.id, tag: item.backdropImageTag, maxWidth: 400)
            : item.primaryImageTag != null
                ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 400)
                : null;

        if (imageUrl != null) {
          await _extractColorForItem(item.id, imageUrl, sessionId);
        }
      }

      if (index == safeIndex && mounted && sessionId == _colorPrefetchToken) {
        _applyColorForItem(item);
      }

      if (!mounted || sessionId != _colorPrefetchToken) return;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  List<int> _buildPrefetchIndexes(int centerIndex, int itemCount) {
    final indexes = <int>[];

    void addIndex(int index) {
      if (index >= 0 && index < itemCount && !indexes.contains(index)) {
        indexes.add(index);
      }
    }

    addIndex(centerIndex);
    addIndex(centerIndex + 1);
    addIndex(centerIndex - 1);
    return indexes;
  }

  Future<void> _extractColorForItem(
    String itemId,
    String imageUrl,
    int sessionId,
  ) async {
    try {
      final colors = await ColorExtractor.extractFromUrl(imageUrl);
      if (mounted && sessionId == _colorPrefetchToken) {
        _colorCache[itemId] = colors;
      }
    } catch (e) {
      // 颜色提取失败不影响图片显示
      debugPrint('Color extraction failed for $itemId: $e');
    }
  }

  void _applyColorForItem(MediaItem item) {
    if (_colorCache.containsKey(item.id)) {
      final colors = _colorCache[item.id]!;
      if (mounted) {
        setState(() {
          _dominantColor = colors.gradientStart;
          _backgroundColor = colors.background;
        });
        widget.onColorChanged?.call(colors.background);
      }
    }
  }

  void _onPageChanged(int index, List<MediaItem> items) {
    if (_currentPage != index) {
      setState(() {
        _currentPage = index;
      });
    }

    if (index < items.length) {
      _applyColorForItem(items[index]);
      _precacheColors(items, index);
    }
  }

  void _syncColorExtraction(List<MediaItem> items) {
    if (items.isEmpty) return;

    final signature = items.map((item) => item.id).join('|');
    if (_itemsSignature == signature) return;

    _itemsSignature = signature;
    _currentPage = 0;
    _dominantColor = Colors.transparent;
    _backgroundColor = const Color(0xFF121212);
    _colorCache.clear();
    _colorPrefetchToken++;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _pageController;
      if (controller != null && controller.hasClients) {
        controller.jumpToPage(0);
      }
      _precacheColors(items, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    // 降低轮播图高度以减少渲染开销
    final carouselHeight = screenHeight * 0.55;

    return recommendationsAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        _syncColorExtraction(items);

        final currentPage = _currentPage.clamp(0, items.length - 1);
        if (_currentPage != currentPage) {
          _currentPage = currentPage;
        }

        final controller = _pageController;
        if (controller == null) return const SizedBox.shrink();

        return SizedBox(
          height: carouselHeight,
          child: Stack(
            children: [
              // 轮播内容
              PageView.builder(
                controller: controller,
                itemCount: items.length,
                allowImplicitScrolling: false,
                physics: const ClampingScrollPhysics(),
                onPageChanged: (index) => _onPageChanged(index, items),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return RepaintBoundary(
                    child: _CarouselItem(
                      item: item,
                      dominantColor: _dominantColor,
                      backgroundColor: _backgroundColor,
                      onTap: () => context.push(mediaRouteForItem(item)),
                    ),
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
                      width: index == currentPage ? 20 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: index == currentPage
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
  final Color dominantColor;
  final Color backgroundColor;

  const _CarouselItem({
    required this.item,
    required this.onTap,
    required this.dominantColor,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    // 降低轮播图图片分辨率以减少内存占用
    final imageUrl = item.backdropImageTag != null
        ? api.image.getBackdropImageUrl(item.id, tag: item.backdropImageTag, maxWidth: 400)
        : item.primaryImageTag != null
            ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 400)
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

          // 顶部渐变遮罩（确保顶栏文字可见）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black54,
                  ],
                ),
              ),
            ),
          ),

          // 底部渐变遮罩（平滑过渡到背景色，消除细线）
          Positioned(
            bottom: -1, // 向下延伸1像素消除细线
            left: 0,
            right: 0,
            height: 340,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    dominantColor.withValues(alpha: 0.3),
                    dominantColor.withValues(alpha: 0.7),
                    backgroundColor.withValues(alpha: 0.95),
                    backgroundColor,
                    backgroundColor,
                  ],
                  stops: const [0.0, 0.35, 0.55, 0.75, 0.9, 0.98, 1.0],
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
    final imageUrls = resolveMediaItemImageUrls(
      api,
      item,
      maxWidth: 400,
      preferThumb: true,
    );

    final isEpisode = item.type == 'Episode';
    final seasonEpisodeText = isEpisode && item.parentIndexNumber != null && item.indexNumber != null
        ? 'S${item.parentIndexNumber}E${item.indexNumber}'
        : null;

    return GestureDetector(
      onTap: () {
        context.push(mediaRouteForItem(item));
      },
      onLongPress: () => _showLongPressMenu(context, ref),
      child: SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面图 + 进度条（横向16:9，保持原始比例）
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                      imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
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

  void _showLongPressMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('从继续观看中移除'),
              onTap: () {
                Navigator.pop(context);
                _removeFromContinueWatching(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite_border),
              title: const Text('添加到收藏'),
              onTap: () {
                Navigator.pop(context);
                _addToFavorites(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('标记为已播放'),
              onTap: () {
                Navigator.pop(context);
                _markAsPlayed(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeFromContinueWatching(BuildContext context, WidgetRef ref) {
    // 通过API标记为未播放来移除继续观看记录
    _showConfirmDialog(
      context,
      title: '移除记录',
      content: '确定要从继续观看中移除 "${item.name}" 吗？',
      onConfirm: () async {
        try {
          final api = ref.read(apiClientProvider);
          await api.user.markAsUnplayed(item.id);
          ref.invalidate(resumeItemsProvider);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已移除')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('移除失败: $e')),
            );
          }
        }
      },
    );
  }

  void _addToFavorites(BuildContext context, WidgetRef ref) {
    _showConfirmDialog(
      context,
      title: '添加到收藏',
      content: '将 "${item.name}" 添加到收藏？',
      onConfirm: () async {
        try {
          final api = ref.read(apiClientProvider);
          await api.favorite.addFavorite(item.id);
          refreshFavorites(ref);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已添加到收藏')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('添加失败: $e')),
            );
          }
        }
      },
    );
  }

  void _markAsPlayed(BuildContext context, WidgetRef ref) {
    _showConfirmDialog(
      context,
      title: '标记为已播放',
      content: '将 "${item.name}" 标记为已播放？',
      onConfirm: () async {
        try {
          final api = ref.read(apiClientProvider);
          await api.user.markAsPlayed(item.id);
          ref.invalidate(resumeItemsProvider);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已标记为已播放')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('标记失败: $e')),
            );
          }
        }
      },
    );
  }

  void _showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              onConfirm();
            },
            child: const Text('确定'),
          ),
        ],
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
                    onTap: () => context.go('/libraries'),
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
              height: 178,
              children: libraries.map((library) {
                return SizedBox(
                  width: 168,
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
    final imageUrls = resolveLibraryImageUrls(api, library, maxWidth: 400);
    const borderRadius = BorderRadius.all(Radius.circular(20));

    return GestureDetector(
      onTap: () => context.push('/library/${library.id}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 168,
            height: 124,
            decoration: const BoxDecoration(
              borderRadius: borderRadius,
            ),
            clipBehavior: Clip.antiAlias,
            child: imageUrls.isNotEmpty
                ? MediaImage(
                    imageUrl: imageUrls.first,
                    imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                    width: 168,
                    height: 124,
                    fit: BoxFit.cover,
                    borderRadius: borderRadius,
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
            width: 168,
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
                    onTap: () => context.push(mediaRouteForItem(item)),
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
