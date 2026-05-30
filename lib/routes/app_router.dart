import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../ui/screens/home/home_screen.dart';
import '../ui/screens/server/server_list_screen.dart';
import '../ui/screens/server/add_server_screen.dart';
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
    onException: (context, state, router) {
      // 处理导航异常，防止根路由pop导致闪退
      if (state.uri.path == '/' || state.uri.path == '/home') {
        // 在根路由时不做任何操作，避免闪退
        return;
      }
      router.go('/');
    },
    routes: [
      // 主页（含底部Tab）
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainShell(navigationShell: navigationShell);
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
                    path: 'add',
                    builder: (context, state) => const AddServerScreen(),
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
      
      // 首页（从服务器进入）
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeScreen(),
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
class MainShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;
  
  const MainShell({super.key, required this.navigationShell});
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: const SizedBox.shrink(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _FloatingTabBar(navigationShell: navigationShell),
    );
  }
}

/// 悬浮Tab栏
class _FloatingTabBar extends StatelessWidget {
  final StatefulNavigationShell navigationShell;
  
  const _FloatingTabBar({required this.navigationShell});
  
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                style: TextStyle(
                  color: const Color(0xFF5B8DEF),
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
