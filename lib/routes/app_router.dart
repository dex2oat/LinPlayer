import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/providers/app_providers.dart';
import '../core/theme/app_motion.dart';
import '../ui/screens/detail/media_detail_screen.dart';
import '../ui/screens/detail/season_detail_screen.dart';
import '../ui/screens/download/download_screen.dart';
import '../ui/screens/favorites/favorites_screen.dart';
import '../ui/screens/home/home_screen.dart';
import '../ui/screens/library/libraries_screen.dart';
import '../ui/screens/library/library_detail_screen.dart';
import '../ui/screens/player/player_screen.dart';
import '../ui/screens/search/search_screen.dart';
import '../ui/screens/server/add_server_screen.dart';
import '../ui/screens/server/edit_server_screen.dart';
import '../ui/screens/server/icon_select_screen.dart';
import '../ui/screens/server/server_lines_screen.dart';
import '../ui/screens/server/server_list_screen.dart';
import '../ui/screens/settings/settings_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  final startupPage = ref.watch(startupPageProvider);
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: mobileStartupLocationFor(startupPage),
    redirect: (context, state) {
      final servers = ref.read(serverListProvider);
      final path = state.uri.path;

      if (servers.isEmpty) {
        if (path == '/home' || path == resumeRoutePath) {
          return '/';
        }
        return null;
      }

      return null;
    },
    onException: (context, state, router) {
      router.go('/');
    },
    routes: [
      StatefulShellRoute(
        navigatorContainerBuilder: (context, navigationShell, children) {
          return _AnimatedBranchContainer(
            currentIndex: navigationShell.currentIndex,
            children: children,
          );
        },
        builder: (context, state, navigationShell) {
          return MainShell(
            navigationShell: navigationShell,
            currentPath: state.uri.path,
          );
        },
        branches: [
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/',
                pageBuilder: (context, state) => _buildHorizontalPage(
                  child: const ServerListScreen(),
                  state: state,
                ),
                routes: [
                  GoRoute(
                    path: 'home',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: const HomeScreen(),
                      state: state,
                      direction: _PageTransitionDirection.forward,
                    ),
                  ),
                  GoRoute(
                    path: 'resume',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: const _ResumeRouteScreen(),
                      state: state,
                      direction: _PageTransitionDirection.forward,
                    ),
                  ),
                  GoRoute(
                    path: 'add',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: const AddServerScreen(),
                      state: state,
                    ),
                  ),
                  GoRoute(
                    path: 'edit/:serverId',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: EditServerScreen(
                        serverId: state.pathParameters['serverId']!,
                      ),
                      state: state,
                    ),
                  ),
                  GoRoute(
                    path: 'lines/:serverId',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: ServerLinesScreen(
                        serverId: state.pathParameters['serverId']!,
                      ),
                      state: state,
                    ),
                  ),
                  GoRoute(
                    path: 'icons/:serverId',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: IconSelectScreen(
                        serverId: state.pathParameters['serverId']!,
                      ),
                      state: state,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/favorites',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const FavoritesScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const SettingsScreen(),
                  state: state,
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/search',
        pageBuilder: (context, state) => _buildHorizontalPage(
          child: const SearchScreen(),
          state: state,
          direction: _PageTransitionDirection.forward,
        ),
      ),
      GoRoute(
        path: '/detail/:id',
        builder: (context, state) => MediaDetailScreen(
          itemId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/season/:id',
        builder: (context, state) => SeasonDetailScreen(
          seasonId: state.pathParameters['id']!,
          backgroundColor: state.extra is Color ? state.extra as Color : null,
        ),
      ),
      GoRoute(
        path: '/episode/:id',
        builder: (context, state) => EpisodeDetailScreen(
          episodeId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/libraries',
        builder: (context, state) => const LibrariesScreen(),
      ),
      GoRoute(
        path: '/library/:id',
        builder: (context, state) => LibraryDetailScreen(
          libraryId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (context, state) => PlayerScreen(
          itemId: state.pathParameters['id']!,
          mediaSourceId: state.uri.queryParameters['mediaSourceId'],
        ),
      ),
      GoRoute(
        path: '/downloads',
        builder: (context, state) => const DownloadScreen(),
      ),
    ],
  );
});

enum _PageTransitionDirection { neutral, forward, backward }

CustomTransitionPage<void> _buildBranchRootPage({
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
          curve: AppMotion.standard,
        ),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
  );
}

CustomTransitionPage<void> _buildHorizontalPage({
  required Widget child,
  required GoRouterState state,
  _PageTransitionDirection direction = _PageTransitionDirection.neutral,
}) {
  final Offset begin = switch (direction) {
    _PageTransitionDirection.backward => const Offset(-0.18, 0),
    _PageTransitionDirection.forward => const Offset(0.16, 0),
    _PageTransitionDirection.neutral => const Offset(0.08, 0),
  };

  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.reverse,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: begin,
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
  );
}

class _AnimatedBranchContainer extends StatefulWidget {
  const _AnimatedBranchContainer({
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  State<_AnimatedBranchContainer> createState() =>
      _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<_AnimatedBranchContainer> {
  int _previousIndex = 0;

  @override
  void didUpdateWidget(covariant _AnimatedBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _previousIndex = oldWidget.currentIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool moveRight = widget.currentIndex > _previousIndex;
    return Stack(
      fit: StackFit.expand,
      children: List<Widget>.generate(widget.children.length, (index) {
        final bool isActive = index == widget.currentIndex;
        final bool isLeaving = index == _previousIndex && !isActive;
        // 收敛位移、去掉叠加的 AnimatedOpacity（每个分支一次 saveLayer），
        // Tab 切换只做单层轻量滑动。
        final double targetOffset = isActive
            ? 0
            : isLeaving
                ? (moveRight ? -0.04 : 0.04)
                : (index > widget.currentIndex ? 0.04 : -0.04);

        return IgnorePointer(
          ignoring: !isActive,
          child: TickerMode(
            enabled: isActive || isLeaving,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              offset: Offset(targetOffset, 0),
              child: Offstage(
                offstage: !isActive && !isLeaving,
                child: widget.children[index],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.navigationShell,
    required this.currentPath,
  });

  final StatefulNavigationShell navigationShell;
  final String currentPath;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // 性能要点：滚动时只更新 ValueNotifier，由 ValueListenableBuilder 局部重建
  // 浮动 TabBar 的透明度，避免每个滚动事件 setState 整个 shell（含 navigationShell）。
  final ValueNotifier<double> _tabOpacity = ValueNotifier<double>(1.0);

  bool get _isHomePage => widget.currentPath == '/home';
  bool get _isServerListPage => widget.currentPath == '/';
  bool get _supportsFloatingTabBar => switch (widget.currentPath) {
        '/' || '/home' || '/resume' || '/favorites' || '/settings' => true,
        _ => false,
      };

  bool _onScrollNotification(ScrollNotification notification) {
    if (!_isHomePage) return false;

    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta.abs() > 1.5) {
        _tabOpacity.value = (_tabOpacity.value - delta / 150).clamp(0.0, 1.0);
      }
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPath != widget.currentPath && _isServerListPage) {
      _tabOpacity.value = 1.0;
    }
  }

  @override
  void dispose() {
    _tabOpacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isKeyboardVisible = mediaQuery.viewInsets.bottom > 0;
    final showFloatingTabBar = _supportsFloatingTabBar && !isKeyboardVisible;
    final bottomPadding = mediaQuery.padding.bottom;
    final tabHeight = showFloatingTabBar ? 64.0 + bottomPadding : 0.0;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Scaffold(
        resizeToAvoidBottomInset: true, // 显式设置以确保键盘正确处理
        body: isKeyboardVisible
            ? widget.navigationShell // 键盘显示时不修改 MediaQuery，让系统自动处理
            : MediaQuery(
                data: mediaQuery.copyWith(
                  padding: mediaQuery.padding.copyWith(
                    bottom: mediaQuery.padding.bottom + tabHeight,
                  ),
                ),
                child: widget.navigationShell,
              ),
        bottomNavigationBar: const SizedBox.shrink(),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: showFloatingTabBar
            ? ValueListenableBuilder<double>(
                valueListenable: _tabOpacity,
                child: _FloatingTabBar(
                  navigationShell: widget.navigationShell,
                ),
                builder: (context, value, child) => Opacity(
                  opacity: _isServerListPage ? 1.0 : value,
                  child: child,
                ),
              )
            : null,
      ),
    );
  }
}

class _FloatingTabBar extends StatelessWidget {
  const _FloatingTabBar({
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

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
            _buildNavItem(1, Icons.favorite_rounded, '收藏'),
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
          color: isSelected
              ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
              : Colors.transparent,
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

class _ResumeRouteScreen extends StatelessWidget {
  const _ResumeRouteScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(top: 8, bottom: 24),
          child: ContinueWatchingSection(),
        ),
      ),
    );
  }
}
