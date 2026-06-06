import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../widgets/desktop_media_card.dart';
import '../../widgets/desktop_section_header.dart';

/// 桌面端首页 - 宽屏布局
/// 
/// 布局特点：
/// - 左侧大轮播图（占40%宽度）
/// - 右侧继续观看列表
/// - 下方多列网格展示媒体库内容
/// - 支持键盘快捷键导航
class DesktopHomeScreen extends ConsumerStatefulWidget {
  const DesktopHomeScreen({super.key});
  
  @override
  ConsumerState<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends ConsumerState<DesktopHomeScreen> {
  final ScrollController _scrollController = ScrollController();
  
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final hideDailyRecommendations = ref.watch(hideDailyRecommendationsProvider);
    final servers = ref.watch(serverListProvider);
    
    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // 顶部工具栏
          const SliverToBoxAdapter(child: _DesktopTopBar()),
          
          if (servers.isEmpty)
            // 无服务器引导
            const SliverFillRemaining(
              child: _EmptyServerGuide(),
            )
          else ...[
            // 主内容区（轮播 + 继续观看）
            if (!hideDailyRecommendations)
              const SliverToBoxAdapter(child: _HeroSection()),
            
            // 媒体库
            const SliverToBoxAdapter(child: _LibrariesSection()),
            
            // 各媒体库最新内容
            const SliverToBoxAdapter(child: _LatestItemsSection()),
            
            const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
          ],
        ],
      ),
    );
  }
}

/// 桌面端顶部工具栏
class _DesktopTopBar extends ConsumerWidget {
  const _DesktopTopBar();
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentServer = ref.watch(currentServerProvider);
    
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          // 服务器选择器
          _buildServerSelector(context, ref, currentServer),
          
          const Spacer(),
          
          // 搜索按钮
          _buildIconButton(
            icon: Icons.search,
            tooltip: '搜索 (Ctrl+K)',
            onTap: () => context.push('/search'),
          ),
          
          const SizedBox(width: 8),
          
          // 刷新按钮
          _buildIconButton(
            icon: Icons.refresh,
            tooltip: '刷新 (F5)',
            onTap: () {
              ref.invalidate(resumeItemsProvider);
              ref.invalidate(librariesProvider);
              ref.invalidate(randomRecommendationsProvider);
            },
          ),
        ],
      ),
    );
  }
  
  Widget _buildServerSelector(BuildContext context, WidgetRef ref, ServerConfig? server) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _showServerMenu(context, ref),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: server?.iconUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: MediaImage(
                          imageUrl: server!.iconUrl,
                          width: 28,
                          height: 28,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const Icon(Icons.dns, size: 14, color: Color(0xFF5B8DEF)),
              ),
              const SizedBox(width: 8),
              Text(
                server?.name ?? '未连接服务器',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
  
  void _showServerMenu(BuildContext context, WidgetRef ref) {
    final servers = ref.read(serverListProvider);
    final currentServerId = ref.read(currentServerProvider)?.id;
    
    showMenu(
      context: context,
      position: const RelativeRect.fromLTRB(200, 80, 0, 0),
      items: servers.map((server) {
        final isCurrent = server.id == currentServerId;
        return PopupMenuItem(
          value: server,
          child: Row(
            children: [
              Icon(
                Icons.dns,
                size: 18,
                color: isCurrent ? const Color(0xFF5B8DEF) : null,
              ),
              const SizedBox(width: 8),
              Text(
                server.name,
                style: TextStyle(
                  color: isCurrent ? const Color(0xFF5B8DEF) : null,
                  fontWeight: isCurrent ? FontWeight.w600 : null,
                ),
              ),
              if (isCurrent) ...[
                const Spacer(),
                const Icon(Icons.check, size: 16, color: Color(0xFF5B8DEF)),
              ],
            ],
          ),
          onTap: () {
            ref.read(currentServerProvider.notifier).state = server;
            if (server.authToken != null) {
              ref.read(authStateProvider.notifier).state = AuthState.authenticated;
            }
            ref.invalidate(librariesProvider);
            ref.invalidate(resumeItemsProvider);
            ref.invalidate(randomRecommendationsProvider);
          },
        );
      }).toList(),
    );
  }
  
  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: Colors.grey),
          ),
        ),
      ),
    );
  }
}

/// 主视觉区 - 左侧轮播 + 右侧继续观看
class _HeroSection extends ConsumerWidget {
  const _HeroSection();
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);
    
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧大轮播
          Expanded(
            flex: 3,
            child: _DesktopCarousel(recommendationsAsync: recommendationsAsync),
          ),
          
          const SizedBox(width: 24),
          
          // 右侧继续观看
          Expanded(
            flex: 2,
            child: _DesktopContinueWatching(),
          ),
        ],
      ),
    );
  }
}

/// 桌面端轮播图
class _DesktopCarousel extends StatefulWidget {
  final AsyncValue<List<MediaItem>> recommendationsAsync;
  
  const _DesktopCarousel({required this.recommendationsAsync});
  
  @override
  State<_DesktopCarousel> createState() => _DesktopCarouselState();
}

class _DesktopCarouselState extends State<_DesktopCarousel> {
  int _currentIndex = 0;
  
  @override
  Widget build(BuildContext context) {
    return widget.recommendationsAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        
        final currentItem = items[_currentIndex.clamp(0, items.length - 1)];
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 轮播图
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 背景图
                    _CarouselImage(item: currentItem),
                    
                    // 底部渐变
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 200,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.7),
                            ],
                          ),
                        ),
                      ),
                    ),
                    
                    // 信息叠加
                    Positioned(
                      bottom: 20,
                      left: 24,
                      right: 24,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentItem.name,
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
                              if (currentItem.communityRating != null) ...[
                                const Icon(Icons.star, size: 16, color: Colors.amber),
                                const SizedBox(width: 4),
                                Text(
                                  currentItem.communityRating!.toStringAsFixed(1),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 16),
                              ],
                              ...?(currentItem.genres?.take(4).map((genre) =>
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
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
                                ),
                              )),
                            ],
                          ),
                        ],
                      ),
                    ),
                    
                    // 左右切换按钮
                    if (items.length > 1) ...[
                      Positioned(
                        left: 12,
                        top: 0,
                        bottom: 0,
                        child: _buildArrowButton(
                          icon: Icons.chevron_left,
                          onTap: () => setState(() {
                            _currentIndex = (_currentIndex - 1 + items.length) % items.length;
                          }),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 0,
                        bottom: 0,
                        child: _buildArrowButton(
                          icon: Icons.chevron_right,
                          onTap: () => setState(() {
                            _currentIndex = (_currentIndex + 1) % items.length;
                          }),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 12),
            
            // 指示器
            if (items.length > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(items.length, (index) {
                  return Container(
                    width: index == _currentIndex ? 24 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: index == _currentIndex
                          ? const Color(0xFF5B8DEF)
                          : Colors.grey.withValues(alpha: 0.4),
                    ),
                  );
                }),
              ),
          ],
        );
      },
      loading: () => const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) {
        debugPrint('[_DesktopCarousel] Error: $error');
        return const SizedBox.shrink();
      },
    );
  }
  
  Widget _buildArrowButton({required IconData icon, required VoidCallback onTap}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                icon == Icons.chevron_left
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.transparent,
                icon == Icons.chevron_right
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.transparent,
              ],
            ),
          ),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
      ),
    );
  }
}

class _CarouselImage extends ConsumerWidget {
  final MediaItem item;
  
  const _CarouselImage({required this.item});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = item.backdropImageTag != null
        ? api.image.getBackdropImageUrl(item.id, tag: item.backdropImageTag, maxWidth: 800)
        : item.primaryImageTag != null
            ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 800)
            : null;
    
    return MediaImage(
      imageUrl: imageUrl,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
    );
  }
}

/// 桌面端继续观看
class _DesktopContinueWatching extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeAsync = ref.watch(resumeItemsProvider);
    
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Text(
                  '继续观看',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    // 查看更多
                  },
                  child: const Text('查看全部'),
                ),
              ],
            ),
          ),
          
          const Divider(height: 1),
          
          Expanded(
            child: resumeAsync.when(
              data: (items) {
                if (items.isEmpty) {
                  return const Center(
                    child: Text('没有继续观看的内容', style: TextStyle(color: Colors.grey)),
                  );
                }
                
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.take(5).length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _DesktopContinueItem(item: item);
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '加载失败: $error',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
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

class _DesktopContinueItem extends ConsumerWidget {
  final MediaItem item;
  
  const _DesktopContinueItem({required this.item});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemImageUrls(api, item, maxWidth: 200, preferThumb: true);
    
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push(mediaRouteForItem(item)),
        child: Container(
          padding: const EdgeInsets.all(8),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: MediaImage(
                  imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                  width: 80,
                  height: 45,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (item.progress != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor: Colors.grey.withValues(alpha: 0.2),
                            valueColor: const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
                            minHeight: 3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 媒体库区
class _LibrariesSection extends ConsumerWidget {
  const _LibrariesSection();
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);
    
    return librariesAsync.when(
      data: (libraries) {
        if (libraries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('暂无媒体库', style: TextStyle(color: Colors.grey)),
            ),
          );
        }
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DesktopSectionHeader(
              title: '媒体库',
              onMoreTap: () => context.go('/libraries'),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              height: 200,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: libraries.length,
                itemBuilder: (context, index) {
                  final library = libraries[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: _DesktopLibraryCard(library: library),
                  );
                },
              ),
            ),
          ],
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                '加载媒体库失败',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => ref.invalidate(librariesProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopLibraryCard extends ConsumerWidget {
  final Library library;
  
  const _DesktopLibraryCard({required this.library});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveLibraryImageUrls(api, library, maxWidth: 400);
    
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push('/library/${library.id}'),
        child: Container(
          width: 240,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MediaImage(
                  imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                  width: 240,
                  height: 140,
                  fit: BoxFit.cover,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  library.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

/// 各媒体库最新内容
class _LatestItemsSection extends ConsumerWidget {
  const _LatestItemsSection();
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);
    
    return librariesAsync.when(
      data: (libraries) {
        return Column(
          children: libraries.map((library) {
            return _LibraryLatestItems(library: library);
          }).toList(),
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '加载失败: $error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    );
  }
}

class _LibraryLatestItems extends ConsumerWidget {
  final Library library;
  
  const _LibraryLatestItems({required this.library});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latestAsync = ref.watch(latestItemsProvider(library.id));
    
    return latestAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DesktopSectionHeader(
              title: library.name,
              onMoreTap: () => context.push('/library/${library.id}'),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              height: 240,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: DesktopMediaCard(
                      item: items[index],
                      width: 150,
                      height: 200,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, _) {
        debugPrint('[_LibraryLatestItems] Error loading ${library.name}: $error');
        return const SizedBox.shrink();
      },
    );
  }
}

/// 无服务器引导组件
class _EmptyServerGuide extends StatelessWidget {
  const _EmptyServerGuide();
  
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 24),
          Text(
            '尚未添加服务器',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '添加 Emby 服务器后即可浏览媒体库',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(height: 32),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => context.go('/servers'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF5B8DEF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '前往服务器管理',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
