import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../widgets/desktop_cover_radii.dart';

/// 桌面端媒体库列表页
class DesktopLibraryScreen extends ConsumerWidget {
  const DesktopLibraryScreen({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);
    final servers = ref.watch(serverListProvider);
    final theme = Theme.of(context);
    
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // 顶部栏
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Row(
                children: [
                  Text(
                    '媒体库',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.view_list),
                    onPressed: () {},
                    tooltip: '列表视图',
                  ),
                  IconButton(
                    icon: const Icon(Icons.grid_view),
                    onPressed: () {},
                    tooltip: '网格视图',
                  ),
                ],
              ),
            ),
          ),
          
          if (servers.isEmpty)
            const SliverFillRemaining(
              child: _EmptyServerGuide(),
            )
          else
            // 媒体库网格
            librariesAsync.when(
            data: (libraries) {
              if (libraries.isEmpty) {
                return const SliverFillRemaining(
                  child: Center(
                    child: Text('暂无媒体库', style: TextStyle(color: Colors.grey)),
                  ),
                );
              }
              
              return SliverPadding(
                padding: const EdgeInsets.all(24),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 1.4,
                    crossAxisSpacing: 20,
                    mainAxisSpacing: 20,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final library = libraries[index];
                      return _DesktopLibraryGridCard(library: library);
                    },
                    childCount: libraries.length,
                  ),
                ),
              );
            },
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => const SliverFillRemaining(
              child: Center(
                child: Text('加载失败', style: TextStyle(color: Colors.grey)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopLibraryGridCard extends ConsumerStatefulWidget {
  final Library library;
  
  const _DesktopLibraryGridCard({required this.library});
  
  @override
  ConsumerState<_DesktopLibraryGridCard> createState() => _DesktopLibraryGridCardState();
}

class _DesktopLibraryGridCardState extends ConsumerState<_DesktopLibraryGridCard> {
  bool _isHovered = false;
  
  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveLibraryImageUrls(api, widget.library, maxWidth: 600);
    final theme = Theme.of(context);
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push('/library/${widget.library.id}'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.fastOutSlowIn,
          transform: _isHovered
              ? (Matrix4.identity()..translateByDouble(0.0, -6.0, 0.0, 1.0))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: desktopLandscapeCoverRadius,
                  child: MediaImage(
                    imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.library.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
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
