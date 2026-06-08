import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/app_providers.dart';

/// 桌面端侧边栏宽度
const double _kSidebarWidth = 220;
const double _kSidebarCollapsedWidth = 72;
/// 桌面端导航项
class _NavItem {
  final String path;
  final IconData icon;
  final String label;
  
  const _NavItem({
    required this.path,
    required this.icon,
    required this.label,
  });
}

const _navItems = [
  _NavItem(path: '/', icon: Icons.home_rounded, label: '首页'),
  _NavItem(path: '/libraries', icon: Icons.collections_bookmark_rounded, label: '媒体库'),
  _NavItem(path: '/favorites', icon: Icons.favorite_rounded, label: '收藏'),
  _NavItem(path: '/servers', icon: Icons.dns_rounded, label: '服务器'),
  _NavItem(path: '/settings', icon: Icons.settings_rounded, label: '设置'),
];

/// 桌面端外壳 - 侧边栏 + 内容区
class DesktopShell extends ConsumerStatefulWidget {
  final Widget child;
  
  const DesktopShell({super.key, required this.child});
  
  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  bool _isSidebarCollapsed = false;
  bool _hasAttemptedRestore = false;
  
  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final currentServer = ref.watch(currentServerProvider);
    
    // 服务器列表已加载且当前服务器未恢复时，尝试恢复
    if (servers.isNotEmpty && currentServer == null && !_hasAttemptedRestore) {
      _hasAttemptedRestore = true;
      Future.microtask(() async {
        await ref.read(currentServerProvider.notifier).loadFromSaved(servers);
      });
    }

    final currentPath = GoRouterState.of(context).uri.path;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sidebarWidth = _isSidebarCollapsed ? _kSidebarCollapsedWidth : _kSidebarWidth;
    
    return Scaffold(
      body: Row(
        children: [
          // 侧边栏
          AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.fastOutSlowIn,
              width: sidebarWidth,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF8F9FA),
                border: Border(
                  right: BorderSide(
                    color: isDark ? const Color(0xFF333333) : const Color(0xFFE8EAED),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                children: [
                  SizedBox(height: _isSidebarCollapsed ? 12 : 20),
                  
                  // 导航项
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _navItems.length,
                      itemBuilder: (context, index) {
                        final item = _navItems[index];
                        final isSelected = currentPath == item.path ||
                            (item.path == '/' && currentPath == '/home');
                        return _buildNavItem(item, isSelected, isDark, currentPath);
                      },
                    ),
                  ),
                  
                  // 服务器状态
                  _buildServerStatus(isDark),
                  
                  const SizedBox(height: 8),
                  
                  // 折叠按钮
                  _buildCollapseButton(isDark),
                  
                  const SizedBox(height: 16),
                ],
              ),
            ),
          
          // 内容区
          Expanded(
            child: Container(
              color: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildNavItem(_NavItem item, bool isSelected, bool isDark, String currentPath) {
    final theme = Theme.of(context);
    final bgColor = isSelected
        ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
        : Colors.transparent;
    final iconColor = isSelected
        ? const Color(0xFF5B8DEF)
        : isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666);
    final textColor = isSelected
        ? const Color(0xFF5B8DEF)
        : isDark ? const Color(0xFFFFFFFF) : const Color(0xFF1A1A1A);
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (currentPath != item.path) {
              context.go(item.path);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.fastOutSlowIn,
            padding: EdgeInsets.symmetric(
              horizontal: _isSidebarCollapsed ? 0 : 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _isSidebarCollapsed
                ? Center(
                    child: Tooltip(
                      message: item.label,
                      child: Icon(item.icon, color: iconColor, size: 22),
                    ),
                  )
                : Row(
                    children: [
                      Icon(item.icon, color: iconColor, size: 22),
                      const SizedBox(width: 12),
                      Text(
                        item.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                          color: textColor,
                        ),
                      ),
                      if (isSelected) ...[
                        const Spacer(),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: Color(0xFF5B8DEF),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildServerStatus(bool isDark) {
    final currentServer = ref.watch(currentServerProvider);
    final authState = ref.watch(authStateProvider);
    final theme = Theme.of(context);
    
    if (currentServer == null) return const SizedBox.shrink();
    
    final isConnected = authState == AuthState.authenticated;
    final statusColor = isConnected ? const Color(0xFF4CAF50) : const Color(0xFFFFA726);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : const Color(0xFFE8EAED),
        ),
      ),
      child: _isSidebarCollapsed
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentServer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
  
  Widget _buildCollapseButton(bool isDark) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _isSidebarCollapsed = !_isSidebarCollapsed;
          });
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _isSidebarCollapsed ? Icons.chevron_right : Icons.chevron_left,
            size: 18,
            color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666),
          ),
        ),
      ),
    );
  }
}
