import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/widgets/common/media_widgets.dart';

/// 桌面端服务器管理页
class DesktopServerScreen extends ConsumerStatefulWidget {
  const DesktopServerScreen({super.key});
  
  @override
  ConsumerState<DesktopServerScreen> createState() => _DesktopServerScreenState();
}

class _DesktopServerScreenState extends ConsumerState<DesktopServerScreen> {
  bool _isGridView = true;
  
  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final currentServer = ref.watch(currentServerProvider);
    
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // 顶部栏
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Row(
                children: [
                  const Text(
                    '服务器管理',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  
                  // 视图切换
                  IconButton(
                    icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
                    onPressed: () => setState(() => _isGridView = !_isGridView),
                    tooltip: _isGridView ? '列表视图' : '网格视图',
                  ),
                ],
              ),
            ),
          ),
          
          // 服务器列表
          if (servers.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.dns_outlined, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      '暂无服务器',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => context.push('/add-server'),
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
                                '添加服务器',
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
              ),
            )
          else if (_isGridView)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  childAspectRatio: 2.2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final server = servers[index];
                    final isCurrent = server.id == currentServer?.id;
                    return _ServerGridCard(
                      server: server,
                      isCurrent: isCurrent,
                      onTap: () => _selectServer(server),
                    );
                  },
                  childCount: servers.length,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final server = servers[index];
                    final isCurrent = server.id == currentServer?.id;
                    return _ServerListTile(
                      server: server,
                      isCurrent: isCurrent,
                      onTap: () => _selectServer(server),
                    );
                  },
                  childCount: servers.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
  
  void _selectServer(ServerConfig server) {
    ref.read(currentServerProvider.notifier).state = server;
    if (server.authToken != null) {
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;
    }
    ref.invalidate(librariesProvider);
    ref.invalidate(resumeItemsProvider);
  }
}

/// 服务器网格卡片
class _ServerGridCard extends StatefulWidget {
  final ServerConfig server;
  final bool isCurrent;
  final VoidCallback onTap;
  
  const _ServerGridCard({
    required this.server,
    required this.isCurrent,
    required this.onTap,
  });
  
  @override
  State<_ServerGridCard> createState() => _ServerGridCardState();
}

class _ServerGridCardState extends State<_ServerGridCard> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;
  
  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.96,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.fastOutSlowIn,
    ));
  }
  
  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }
  
  void _onTapDown(TapDownDetails details) {
    _scaleController.forward();
  }
  
  void _onTapUp(TapUpDetails details) {
    _scaleController.reverse();
  }
  
  void _onTapCancel() {
    _scaleController.reverse();
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        child: AnimatedBuilder(
          animation: _scaleController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.fastOutSlowIn,
            decoration: BoxDecoration(
              color: widget.isCurrent
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.08)
                  : _isHovered
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: widget.isCurrent
                  ? Border.all(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.5),
                      width: 2,
                    )
                  : _isHovered
                      ? Border.all(
                          color: theme.colorScheme.primary.withValues(alpha: 0.2),
                          width: 1,
                        )
                      : null,
              boxShadow: widget.isCurrent
                  ? [
                      BoxShadow(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : _isHovered
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  // 服务器图标
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: widget.isCurrent
                          ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                          : const Color(0xFF5B8DEF).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: widget.server.iconUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: MediaImage(
                              imageUrl: widget.server.iconUrl,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Icon(
                            Icons.dns,
                            size: 20,
                            color: widget.isCurrent
                                ? const Color(0xFF5B8DEF)
                                : const Color(0xFF5B8DEF).withValues(alpha: 0.7),
                          ),
                  ),
                  
                  const SizedBox(width: 12),
                  
                  // 服务器信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.server.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: widget.isCurrent ? FontWeight.w700 : FontWeight.w600,
                            color: widget.isCurrent
                                ? const Color(0xFF5B8DEF)
                                : theme.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.server.baseUrl,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  
                  // 当前选中标记
                  if (widget.isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 12,
                            color: Color(0xFF5B8DEF),
                          ),
                          SizedBox(width: 4),
                          Text(
                            '当前',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF5B8DEF),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 服务器列表项
class _ServerListTile extends StatefulWidget {
  final ServerConfig server;
  final bool isCurrent;
  final VoidCallback onTap;
  
  const _ServerListTile({
    required this.server,
    required this.isCurrent,
    required this.onTap,
  });
  
  @override
  State<_ServerListTile> createState() => _ServerListTileState();
}

class _ServerListTileState extends State<_ServerListTile> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;
  
  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.98,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.fastOutSlowIn,
    ));
  }
  
  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }
  
  void _onTapDown(TapDownDetails details) {
    _scaleController.forward();
  }
  
  void _onTapUp(TapUpDetails details) {
    _scaleController.reverse();
  }
  
  void _onTapCancel() {
    _scaleController.reverse();
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        child: AnimatedBuilder(
          animation: _scaleController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.fastOutSlowIn,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.isCurrent
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.08)
                  : _isHovered
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: widget.isCurrent
                  ? Border.all(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.4),
                      width: 1.5,
                    )
                  : null,
            ),
            child: Row(
              children: [
                // 图标
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                        : const Color(0xFF5B8DEF).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: widget.server.iconUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: MediaImage(
                            imageUrl: widget.server.iconUrl,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                          ),
                        )
                      : Icon(
                          Icons.dns,
                          size: 18,
                          color: widget.isCurrent
                              ? const Color(0xFF5B8DEF)
                              : const Color(0xFF5B8DEF).withValues(alpha: 0.7),
                        ),
                ),
                
                const SizedBox(width: 12),
                
                // 信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.server.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.isCurrent ? FontWeight.w700 : FontWeight.w600,
                          color: widget.isCurrent
                              ? const Color(0xFF5B8DEF)
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.server.baseUrl,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // 当前标记
                if (widget.isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 12,
                          color: Color(0xFF5B8DEF),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '当前',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5B8DEF),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
