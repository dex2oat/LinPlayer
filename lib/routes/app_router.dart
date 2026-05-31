import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../ui/screens/home/home_screen.dart';
import '../ui/screens/server/server_list_screen.dart';
import '../ui/screens/server/add_server_screen.dart';
import '../ui/screens/server/edit_server_screen.dart';
import '../ui/screens/server/server_lines_screen.dart';
import '../ui/screens/server/icon_select_screen.dart';
import '../ui/screens/search/search_screen.dart';
import '../ui/screens/settings/settings_screen.dart';
import '../ui/screens/detail/media_detail_screen.dart';
import '../ui/screens/detail/season_detail_screen.dart';
// Episode detail is in season_detail_screen.dart
import '../ui/screens/library/library_detail_screen.dart';
import '../ui/screens/library/libraries_screen.dart';
import '../ui/screens/player/player_screen.dart';
import '../ui/screens/download/download_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    // 处理导航异常，避免闪退
    onException: (context, state, router) {
      // 安全地回到根路由
      router.go('/');
    },
    routes: [
      // 主页（含底部Tab）
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainShell(
            navigationShell: navigationShell,
            currentPath: state.uri.path,
          );
        },
        branches: [
          // 服务器Tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const ServerListScreen(),
                routes: [
                  GoRoute(
                    path: 'home',
                    builder: (context, state) => const HomeScreen(),
                  ),
                  GoRoute(
                    path: 'add',
                    builder: (context, state) => const AddServerScreen(),
                  ),
                  GoRoute(
                    path: 'edit/:serverId',
                    builder: (context, state) => EditServerScreen(
                      serverId: state.pathParameters['serverId']!,
                    ),
                  ),
                  GoRoute(
                    path: 'lines/:serverId',
                    builder: (context, state) => ServerLinesScreen(
                      serverId: state.pathParameters['serverId']!,
                    ),
                  ),
                  GoRoute(
                    path: 'icons/:serverId',
                    builder: (context, state) => IconSelectScreen(
                      serverId: state.pathParameters['serverId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // 搜索Tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
          // 设置Tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      
      // 媒体详情
      GoRoute(
        path: '/detail/:id',
        builder: (context, state) => MediaDetailScreen(
          itemId: state.pathParameters['id']!,
        ),
      ),
      
      // 季详情
      GoRoute(
        path: '/season/:id',
        builder: (context, state) => SeasonDetailScreen(
          seasonId: state.pathParameters['id']!,
        ),
      ),
      
      // 集详情
      GoRoute(
        path: '/episode/:id',
        builder: (context, state) => EpisodeDetailScreen(
          episodeId: state.pathParameters['id']!,
        ),
      ),
      
      // 媒体库列表
      GoRoute(
        path: '/libraries',
        builder: (context, state) => const LibrariesScreen(),
      ),

      // 媒体库详情
      GoRoute(
        path: '/library/:id',
        builder: (context, state) => LibraryDetailScreen(
          libraryId: state.pathParameters['id']!,
        ),
      ),
      
      // 播放页
      GoRoute(
        path: '/player/:id',
        builder: (context, state) => PlayerScreen(
          itemId: state.pathParameters['id']!,
          mediaSourceId: state.uri.queryParameters['mediaSourceId'],
        ),
      ),
      
      // 下载页
      GoRoute(
        path: '/downloads',
        builder: (context, state) => const DownloadScreen(),
      ),
    ],
  );
});

/// 底部Tab外壳（悬浮样式）
class MainShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;
  final String currentPath;

  const MainShell({
    super.key,
    required this.navigationShell,
    required this.currentPath,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  double _tabOpacity = 1.0;

  bool get _isHomePage => widget.currentPath == '/home';
  bool get _isServerListPage => widget.currentPath == '/';
  bool _onScrollNotification(ScrollNotification notification) {
    // 只有在首页才响应滚动渐隐
    if (!_isHomePage) return false;
    
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      setState(() {
        if (delta > 0) {
          // 向下滑动，渐隐
          _tabOpacity = (_tabOpacity - delta / 150).clamp(0.0, 1.0);
        } else if (delta < 0) {
          // 向上滑动，渐显
          _tabOpacity = (_tabOpacity - delta / 150).clamp(0.0, 1.0);
        }
      });
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当从首页切回服务器页时，重置Tab透明度为1.0
    if (oldWidget.currentPath != widget.currentPath) {
      if (_isServerListPage) {
        setState(() {
          _tabOpacity = 1.0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final tabHeight = 64.0 + bottomPadding;
    // 服务器页常驻显示Tab，首页根据滚动状态
    final effectiveOpacity = _isServerListPage ? 1.0 : _tabOpacity;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Scaffold(
        body: MediaQuery(
          // 为底部Tab留出安全区域，避免遮挡页面内容
          data: MediaQuery.of(context).copyWith(
            padding: MediaQuery.of(context).padding.copyWith(
              bottom: MediaQuery.of(context).padding.bottom + tabHeight,
            ),
          ),
          child: widget.navigationShell,
        ),
        bottomNavigationBar: const SizedBox.shrink(),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: AnimatedOpacity(
          opacity: effectiveOpacity,
          duration: const Duration(milliseconds: 200),
          child: _FloatingTabBar(
            navigationShell: widget.navigationShell,
          ),
        ),
      ),
    );
  }
}

/// 悬浮Tab栏
class _FloatingTabBar extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const _FloatingTabBar({
    required this.navigationShell,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNavItem(0, Icons.dns_rounded, '服务器'),
            const SizedBox(width: 24),
            _buildNavItem(1, Icons.search_rounded, '聚合搜索'),
            const SizedBox(width: 24),
            _buildNavItem(2, Icons.settings_rounded, '设置'),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = navigationShell.currentIndex == index;

    return GestureDetector(
      onTap: () => navigationShell.goBranch(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF5B8DEF).withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: isSelected ? const Color(0xFF5B8DEF) : Colors.grey,
            ),
            if (isSelected) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF5B8DEF),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
