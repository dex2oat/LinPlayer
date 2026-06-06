import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/app_providers.dart';
import '../../ui/screens/detail/media_detail_screen.dart';
import '../../ui/screens/detail/season_detail_screen.dart';
import '../screens/player/desktop_player_screen.dart';
import '../screens/search/desktop_search_screen.dart';
import '../../ui/screens/settings/settings_screen.dart';
import '../screens/favorites/desktop_favorites_screen.dart';
import '../screens/home/desktop_home_screen.dart';
import '../screens/library/desktop_library_screen.dart';
import '../screens/library/desktop_library_detail_screen.dart';
import '../screens/server/desktop_server_screen.dart';
import '../screens/server/desktop_add_server_screen.dart';
import '../shell/desktop_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final desktopRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    redirect: (context, state) {
      final servers = ref.read(serverListProvider);
      final isAuthRoute = state.uri.path == '/servers' || state.uri.path == '/add-server';
      if (servers.isEmpty && !isAuthRoute) {
        return '/servers';
      }
      return null;
    },
    routes: [
      // 主壳路由 - 带侧边栏
      ShellRoute(
        builder: (context, state, child) {
          return DesktopShell(child: child);
        },
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => _buildFadePage(
              child: const DesktopHomeScreen(),
              state: state,
            ),
          ),
          GoRoute(
            path: '/libraries',
            pageBuilder: (context, state) => _buildFadePage(
              child: const DesktopLibraryScreen(),
              state: state,
            ),
          ),
          GoRoute(
            path: '/library/:id',
            pageBuilder: (context, state) => _buildFadePage(
              child: DesktopLibraryDetailScreen(
                libraryId: state.pathParameters['id']!,
              ),
              state: state,
            ),
          ),
          GoRoute(
            path: '/servers',
            pageBuilder: (context, state) => _buildFadePage(
              child: const DesktopServerScreen(),
              state: state,
            ),
          ),
          GoRoute(
            path: '/favorites',
            pageBuilder: (context, state) => _buildFadePage(
              child: const DesktopFavoritesScreen(),
              state: state,
            ),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => _buildFadePage(
              child: const SettingsScreen(),
              state: state,
            ),
          ),
        ],
      ),
      // 全屏路由 - 无侧边栏
      GoRoute(
        path: '/detail/:id',
        pageBuilder: (context, state) => _buildSlidePage(
          child: MediaDetailScreen(
            itemId: state.pathParameters['id']!,
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/season/:id',
        pageBuilder: (context, state) => _buildSlidePage(
          child: SeasonDetailScreen(
            seasonId: state.pathParameters['id']!,
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/episode/:id',
        pageBuilder: (context, state) => _buildSlidePage(
          child: EpisodeDetailScreen(
            episodeId: state.pathParameters['id']!,
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/player/:id',
        pageBuilder: (context, state) => _buildFadePage(
          child: DesktopPlayerScreen(
            itemId: state.pathParameters['id']!,
            mediaSourceId: state.uri.queryParameters['mediaSourceId'],
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/search',
        pageBuilder: (context, state) => _buildSlidePage(
          child: const DesktopSearchScreen(),
          state: state,
          fromRight: true,
        ),
      ),
      GoRoute(
        path: '/add-server',
        pageBuilder: (context, state) => _buildSlidePage(
          child: const DesktopAddServerScreen(),
          state: state,
          fromRight: true,
        ),
      ),
    ],
  );
});

CustomTransitionPage<void> _buildFadePage({
  required Widget child,
  required GoRouterState state,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        ),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 120),
  );
}

CustomTransitionPage<void> _buildSlidePage({
  required Widget child,
  required GoRouterState state,
  bool fromRight = false,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: fromRight ? const Offset(0.1, 0) : const Offset(-0.1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.9, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 160),
  );
}
