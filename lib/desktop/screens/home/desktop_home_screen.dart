import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../widgets/desktop_cover_radii.dart';
import '../../widgets/desktop_media_card.dart';
import '../../widgets/desktop_section_header.dart';

/// 桌面端首页 - 宽屏布局
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
    final currentServer = ref.watch(currentServerProvider);
    final isUnauthenticated = currentServer != null && !serverHasUsableAuth(currentServer);

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SliverToBoxAdapter(child: _DesktopTopBar()),
          if (servers.isEmpty)
            const SliverFillRemaining(
              child: _EmptyServerGuide(),
            )
          else ...[
            if (isUnauthenticated)
              SliverToBoxAdapter(
                child: _UnauthenticatedBanner(server: currentServer),
              ),
            if (!hideDailyRecommendations)
              const SliverToBoxAdapter(child: _HeroSection()),
            const SliverToBoxAdapter(child: _LibrariesSection()),
            const SliverToBoxAdapter(child: _LatestItemsSection()),
            const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
          ],
        ],
      ),
    );
  }
}

class _DesktopTopBar extends ConsumerStatefulWidget {
  const _DesktopTopBar();

  @override
  ConsumerState<_DesktopTopBar> createState() => _DesktopTopBarState();
}

class _DesktopTopBarState extends ConsumerState<_DesktopTopBar> {
  final GlobalKey _serverButtonKey = GlobalKey();
  OverlayEntry? _serverMenuOverlay;

  @override
  void dispose() {
    _hideServerMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentServer = ref.watch(currentServerProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          _buildServerSelector(context, ref, currentServer),
          const Spacer(),
          _buildIconButton(
            icon: Icons.search,
            tooltip: '搜索 (Ctrl+K)',
            onTap: () => context.push('/search'),
          ),
          const SizedBox(width: 8),
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
        key: _serverButtonKey,
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
    if (servers.isEmpty) {
      return;
    }

    _hideServerMenu();

    final renderBox = _serverButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox;
    final buttonPosition = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final buttonSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    _serverMenuOverlay = OverlayEntry(
      builder: (overlayContext) => _DesktopServerMenuOverlay(
        servers: servers,
        currentServerId: currentServerId,
        buttonPosition: buttonPosition,
        buttonSize: buttonSize,
        screenSize: screenSize,
        onDismiss: _hideServerMenu,
        onSelect: (server) {
          ref.read(currentServerProvider.notifier).state = server;
          if (serverHasUsableAuth(server)) {
            ref.read(authStateProvider.notifier).state = AuthState.authenticated;
          } else {
            ref.read(authStateProvider.notifier).state = AuthState.unauthenticated;
          }
          ref.invalidate(librariesProvider);
          ref.invalidate(resumeItemsProvider);
          ref.invalidate(randomRecommendationsProvider);
        },
      ),
    );

    Overlay.of(context).insert(_serverMenuOverlay!);
  }

  void _hideServerMenu() {
    _serverMenuOverlay?.remove();
    _serverMenuOverlay = null;
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

class _DesktopServerMenuOverlay extends StatefulWidget {
  final List<ServerConfig> servers;
  final String? currentServerId;
  final Offset buttonPosition;
  final Size buttonSize;
  final Size screenSize;
  final ValueChanged<ServerConfig> onSelect;
  final VoidCallback onDismiss;

  const _DesktopServerMenuOverlay({
    required this.servers,
    required this.currentServerId,
    required this.buttonPosition,
    required this.buttonSize,
    required this.screenSize,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  State<_DesktopServerMenuOverlay> createState() => _DesktopServerMenuOverlayState();
}

class _DesktopServerMenuOverlayState extends State<_DesktopServerMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  String? _hoveredServerId;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _animationController.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    const menuWidth = 252.0;
    const screenPadding = 24.0;
    final left = widget.buttonPosition.dx.clamp(
      screenPadding,
      widget.screenSize.width - menuWidth - screenPadding,
    );
    final top = widget.buttonPosition.dy + widget.buttonSize.height + 8;
    final maxHeight = (widget.screenSize.height - top - screenPadding).clamp(120.0, 360.0);
    final theme = Theme.of(context);
    final surfaceTint = theme.brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.2);

    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismiss,
        child: Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: menuWidth,
              child: SlideTransition(
                position: _slideAnimation,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: GestureDetector(
                    onTap: () {},
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: surfaceTint,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 24,
                                offset: const Offset(0, 16),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxHeight: maxHeight),
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: widget.servers.map((server) {
                                    final isCurrent = server.id == widget.currentServerId;
                                    final isHovered = _hoveredServerId == server.id;
                                    return MouseRegion(
                                      onEnter: (_) => setState(() => _hoveredServerId = server.id),
                                      onExit: (_) => setState(() => _hoveredServerId = null),
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () async {
                                          await _dismiss();
                                          widget.onSelect(server);
                                        },
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 140),
                                          curve: Curves.easeOut,
                                          margin: const EdgeInsets.symmetric(vertical: 2),
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                          decoration: BoxDecoration(
                                            color: isCurrent
                                                ? const Color(0xFF5B8DEF).withValues(alpha: 0.22)
                                                : isHovered
                                                    ? Colors.white.withValues(alpha: 0.12)
                                                    : Colors.transparent,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF5B8DEF).withValues(alpha: 0.16),
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
                                                    : Icon(
                                                        Icons.dns_rounded,
                                                        size: 16,
                                                        color: isCurrent
                                                            ? const Color(0xFFB7D0FF)
                                                            : const Color(0xFF5B8DEF),
                                                      ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  server.name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: theme.textTheme.bodyMedium?.copyWith(
                                                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                                                    color: isCurrent
                                                        ? theme.colorScheme.onSurface
                                                        : theme.colorScheme.onSurface.withValues(alpha: 0.92),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(growable: false),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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

class _HeroSection extends ConsumerWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 24.0;
          const carouselFlex = 3;
          const continueFlex = 2;
          final carouselWidth =
              (constraints.maxWidth - spacing) * carouselFlex / (carouselFlex + continueFlex);
          final sharedHeight = carouselWidth / (16 / 9);

          return SizedBox(
            height: sharedHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: carouselFlex,
                  child: _DesktopCarousel(recommendationsAsync: recommendationsAsync),
                ),
                const SizedBox(width: spacing),
                Expanded(
                  flex: continueFlex,
                  child: _DesktopContinueWatching(panelHeight: sharedHeight),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DesktopCarousel extends ConsumerStatefulWidget {
  final AsyncValue<List<MediaItem>> recommendationsAsync;

  const _DesktopCarousel({required this.recommendationsAsync});

  @override
  ConsumerState<_DesktopCarousel> createState() => _DesktopCarouselState();
}

class _DesktopCarouselState extends ConsumerState<_DesktopCarousel> {
  final Map<String, String> _readyImageByItemId = <String, String>{};
  final Set<String> _startedItemIds = <String>{};
  List<String> _lastItemIds = const <String>[];
  String? _currentItemId;
  int _transitionDirection = 1;
  int _preloadGeneration = 0;

  @override
  Widget build(BuildContext context) {
    return widget.recommendationsAsync.when(
      data: (items) {
        final displayItems = items
            .where((item) => _imageCandidatesFor(item).isNotEmpty)
            .toList(growable: false);
        if (displayItems.isEmpty) {
          return const SizedBox.shrink();
        }

        _schedulePreload(context, displayItems);
        final currentItem = _currentItemFor(displayItems);
        final candidateUrls = _imageCandidatesFor(currentItem);
        final preferredUrl = _readyImageByItemId[currentItem.id];
        final fallbackUrls = candidateUrls.where((url) => url != preferredUrl).toList(growable: false);
        final canPaginate = displayItems.length > 1;

        return ClipRRect(
          borderRadius: desktopLandscapeCoverRadius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                layoutBuilder: (currentChild, previousChildren) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  );
                },
                transitionBuilder: (child, animation) {
                  final childId = (child.key as ValueKey<String>).value;
                  final isCurrent = childId == _currentItemId;
                  final curvedAnimation = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  );
                  final offsetTween = Tween<Offset>(
                    begin: Offset(
                      isCurrent ? _transitionDirection * 0.14 : -_transitionDirection * 0.14,
                      0,
                    ),
                    end: Offset.zero,
                  );
                  return ClipRect(
                    child: SlideTransition(
                      position: offsetTween.animate(curvedAnimation),
                      child: FadeTransition(
                        opacity: curvedAnimation,
                        child: child,
                      ),
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<String>(currentItem.id),
                  child: _CarouselImage(
                    imageUrl: preferredUrl ?? (candidateUrls.isNotEmpty ? candidateUrls.first : null),
                    imageUrls: fallbackUrls.isNotEmpty ? fallbackUrls : null,
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.08),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.46),
                        ],
                        stops: const [0.0, 0.42, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 34,
                child: _CarouselInfo(item: currentItem),
              ),
              if (canPaginate) ...[
                Positioned(
                  left: 14,
                  top: 0,
                  bottom: 0,
                  child: _buildArrowButton(
                    icon: Icons.chevron_left,
                    onTap: () => _stepCarousel(displayItems, -1),
                  ),
                ),
                Positioned(
                  right: 14,
                  top: 0,
                  bottom: 0,
                  child: _buildArrowButton(
                    icon: Icons.chevron_right,
                    onTap: () => _stepCarousel(displayItems, 1),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 16,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: displayItems.map((item) {
                      final isActive = item.id == _currentItemId;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: isActive ? 24 : 7,
                        height: 7,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: isActive
                              ? const Color(0xFF5B8DEF)
                              : Colors.white.withValues(alpha: 0.48),
                        ),
                      );
                    }).toList(growable: false),
                  ),
                ),
              ],
            ],
          ),
        );
      },
      loading: () => _buildLoadingState(context),
      error: (error, _) {
        debugPrint('[_DesktopCarousel] Error: $error');
        return _buildLoadingState(context, isError: true);
      },
    );
  }

  Widget _buildLoadingState(BuildContext context, {bool isError = false}) {
    return ClipRRect(
      borderRadius: desktopLandscapeCoverRadius,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: isError
              ? Icon(
                  Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.outline,
                  size: 36,
                )
              : const CircularProgressIndicator(),
        ),
      ),
    );
  }

  void _schedulePreload(BuildContext context, List<MediaItem> items) {
    final itemIds = items.map((item) => item.id).toList(growable: false);
    if (_sameItemIds(_lastItemIds, itemIds)) {
      return;
    }

    _lastItemIds = itemIds;
    _preloadGeneration += 1;
    _startedItemIds.clear();
    _currentItemId = itemIds.isNotEmpty ? itemIds.first : null;
    final generation = _preloadGeneration;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final item in items) {
        _preloadItem(context, item, generation);
      }
    });
  }

  Future<void> _preloadItem(BuildContext context, MediaItem item, int generation) async {
    if (!_startedItemIds.add(item.id)) {
      return;
    }

    final candidates = _imageCandidatesFor(item);
    if (candidates.isEmpty) {
      return;
    }

    if (mounted && generation == _preloadGeneration) {
      setState(() {
        _readyImageByItemId[item.id] = candidates.first;
        _currentItemId ??= item.id;
      });
    }

    await warmPersistentImageCache(context, candidates);
  }

  List<String> _imageCandidatesFor(MediaItem item) {
    final api = ref.read(apiClientProvider);
    return resolveMediaItemBannerImageUrls(
      api,
      item,
      maxWidth: 1600,
      allowPosterFallback: true,
    );
  }

  MediaItem _currentItemFor(List<MediaItem> readyItems) {
    final currentId = _currentItemId;
    if (currentId == null) {
      _currentItemId = readyItems.first.id;
      return readyItems.first;
    }

    for (final item in readyItems) {
      if (item.id == currentId) {
        return item;
      }
    }

    _currentItemId = readyItems.first.id;
    return readyItems.first;
  }

  void _stepCarousel(List<MediaItem> readyItems, int direction) {
    if (readyItems.length < 2) {
      return;
    }

    final currentIndex = readyItems.indexWhere((item) => item.id == _currentItemId);
    final nextIndex = currentIndex == -1
        ? 0
        : (currentIndex + direction + readyItems.length) % readyItems.length;

    setState(() {
      _transitionDirection = direction;
      _currentItemId = readyItems[nextIndex].id;
    });
  }

  bool _sameItemIds(List<String> previous, List<String> next) {
    if (identical(previous, next)) return true;
    if (previous.length != next.length) return false;
    for (var index = 0; index < previous.length; index++) {
      if (previous[index] != next[index]) {
        return false;
      }
    }
    return true;
  }

  Widget _buildArrowButton({required IconData icon, required VoidCallback onTap}) {
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
      ),
    );
  }
}

class _CarouselInfo extends StatelessWidget {
  final MediaItem item;

  const _CarouselInfo({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (item.communityRating != null)
              _CarouselMetaChip(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star, size: 16, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      item.communityRating!.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ...?(item.genres?.take(4).map((genre) {
              return _CarouselMetaChip(
                child: Text(
                  genre,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black,
                  ),
                ),
              );
            })),
          ],
        ),
      ],
    );
  }
}

class _CarouselMetaChip extends StatelessWidget {
  final Widget child;

  const _CarouselMetaChip({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.92),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: child,
      ),
    );
  }
}

class _CarouselImage extends StatelessWidget {
  final String? imageUrl;
  final List<String>? imageUrls;

  const _CarouselImage({
    required this.imageUrl,
    this.imageUrls,
  });

  @override
  Widget build(BuildContext context) {
    return MediaImage(
      imageUrl: imageUrl,
      imageUrls: imageUrls,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      borderRadius: desktopLandscapeCoverRadius,
    );
  }
}

class _DesktopContinueWatching extends ConsumerWidget {
  final double panelHeight;

  const _DesktopContinueWatching({required this.panelHeight});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeAsync = ref.watch(resumeItemsProvider);

    return Container(
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
                  onPressed: () {},
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

                final visibleCount = panelHeight >= 520 ? 4 : 3;
                final visibleItems = items.take(visibleCount).toList(growable: false);

                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      for (var index = 0; index < visibleItems.length; index++) ...[
                        Expanded(
                          child: _DesktopContinueItem(item: visibleItems[index]),
                        ),
                        if (index != visibleItems.length - 1)
                          const SizedBox(height: 12),
                      ],
                    ],
                  ),
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
    final imageUrls = resolveMediaItemLandscapeImageUrls(api, item, maxWidth: 720);
    final title = _continueTitle(item);
    final subtitle = _continueSubtitle(item);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push(mediaRouteForItem(item)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final posterHeight = (constraints.maxHeight - 20).clamp(78.0, 122.0).toDouble();
            final posterWidth = posterHeight * 16 / 9;

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
                borderRadius: desktopLandscapeCoverRadius,
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: desktopLandscapeCoverRadius,
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: MediaImage(
                        imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                        imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                        width: posterWidth,
                        height: posterHeight,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).textTheme.bodySmall?.color,
                            ),
                          ),
                        ],
                        if (item.progress != null) ...[
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: item.progress,
                              backgroundColor: Colors.grey.withValues(alpha: 0.2),
                              valueColor: const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
                              minHeight: 4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

String _continueTitle(MediaItem item) {
  if (item.type == 'Episode') {
    final seriesName = item.seriesName?.trim();
    if (seriesName != null && seriesName.isNotEmpty) {
      return seriesName;
    }
  }

  if (item.type == 'Movie' && item.productionYear != null) {
    return '${item.name} (${item.productionYear})';
  }

  return item.name;
}

String? _continueSubtitle(MediaItem item) {
  if (item.type != 'Episode') {
    return null;
  }

  final parts = <String>[];
  if (item.parentIndexNumber != null) {
    parts.add('第${item.parentIndexNumber}季');
  }
  if (item.indexNumber != null) {
    parts.add('第${item.indexNumber}集');
  }
  if (item.name.trim().isNotEmpty) {
    parts.add(item.name);
  }

  if (parts.isEmpty) {
    return null;
  }

  return parts.join(' · ');
}

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
            SizedBox(
              height: 194,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                scrollDirection: Axis.horizontal,
                itemCount: libraries.length,
                itemBuilder: (context, index) {
                  final library = libraries[index];
                  return Padding(
                    padding: EdgeInsets.only(right: index == libraries.length - 1 ? 0 : 14),
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
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push('/library/${library.id}'),
        child: SizedBox(
          width: 228,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 228,
                height: 144,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: desktopLandscapeCoverRadius,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
                ),
                child: MediaImage(
                  imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                  width: 228,
                  height: 144,
                  fit: BoxFit.contain,
                  borderRadius: desktopLandscapeCoverRadius,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text(
                  library.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.15,
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

class _UnauthenticatedBanner extends StatelessWidget {
  final ServerConfig server;

  const _UnauthenticatedBanner({required this.server});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF6B24A).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFF6B24A).withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange.shade700,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前服务器未认证',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${server.name} 需要登录后才能访问完整媒体内容',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonal(
            onPressed: () {
              context.push('/servers');
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange.withValues(alpha: 0.15),
              foregroundColor: Colors.orange.shade800,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: const Text('去认证'),
          ),
        ],
      ),
    );
  }
}

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
