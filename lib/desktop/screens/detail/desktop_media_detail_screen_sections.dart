part of 'desktop_media_detail_screen.dart';

class _HorizontalScrollList extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Color primaryColor;
  final double scaleFactor;
  final double itemWidth;
  final double itemHeight;
  final Widget? trailing;

  const _HorizontalScrollList({
    required this.title,
    this.subtitle,
    required this.children,
    required this.primaryColor,
    required this.scaleFactor,
    required this.itemWidth,
    required this.itemHeight,
    this.trailing,
  });

  @override
  State<_HorizontalScrollList> createState() => _HorizontalScrollListState();
}

class _HorizontalScrollListState extends State<_HorizontalScrollList> {
  final ScrollController _controller = ScrollController();
  bool _showLeftArrow = false;
  bool _showRightArrow = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void dispose() {
    _controller.removeListener(_updateArrows);
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted) return;
    setState(() {
      _showLeftArrow = _controller.offset > 0;
      _showRightArrow =
          _controller.offset < (_controller.position.maxScrollExtent - 1);
    });
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) {
      return;
    }

    _controller.animateTo(
      (_controller.offset + delta).clamp(
        0,
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行
        Row(
          children: [
            _SectionTitle(
              title: widget.title,
              scaleFactor: scale,
              primaryColor: widget.primaryColor,
            ),
            if (widget.subtitle != null) ...[
              SizedBox(width: 12 * scale),
              Text(
                widget.subtitle!,
                style: TextStyle(
                  fontSize: 13 * scale,
                  color: _detailHintText(context),
                ),
              ),
            ],
            const Spacer(),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
        SizedBox(height: 16 * scale),

        // 滚动区域
        Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(event, (
                resolvedEvent,
              ) {
                if (resolvedEvent is! PointerScrollEvent) {
                  return;
                }

                final delta = resolvedEvent.scrollDelta.dx != 0
                    ? resolvedEvent.scrollDelta.dx
                    : resolvedEvent.scrollDelta.dy;
                if (delta == 0) {
                  return;
                }

                _scrollBy(delta * 2);
              });
            }
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: Stack(
              children: [
                // 列表
                SizedBox(
                  height: widget.itemHeight,
                  child: ListView.separated(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    primary: false,
                    physics: const ClampingScrollPhysics(
                      parent: _SnapScrollPhysics(),
                    ),
                    itemCount: widget.children.length,
                    separatorBuilder: (_, __) => SizedBox(width: 12 * scale),
                    itemBuilder: (context, index) => widget.children[index],
                  ),
                ),

                // 左箭头
                if (_showLeftArrow)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: _ScrollArrow(
                      icon: Icons.chevron_left,
                      onPressed: () => _scrollBy(-widget.itemWidth * 4),
                      scaleFactor: scale,
                    ),
                  ),

                // 右箭头
                if (_showRightArrow)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: _ScrollArrow(
                      icon: Icons.chevron_right,
                      onPressed: () => _scrollBy(widget.itemWidth * 4),
                      scaleFactor: scale,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScrollArrow extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double scaleFactor;

  const _ScrollArrow({
    required this.icon,
    required this.onPressed,
    required this.scaleFactor,
  });

  @override
  State<_ScrollArrow> createState() => _ScrollArrowState();
}

class _ScrollArrowState extends State<_ScrollArrow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _isHovered ? 0.8 : 0,
          child: Container(
            width: 40 * scale,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: widget.icon == Icons.chevron_left
                    ? [
                        _detailSurface(context, level: 0.84)
                            .withValues(alpha: 0.92),
                        Colors.transparent,
                      ]
                    : [
                        Colors.transparent,
                        _detailSurface(context, level: 0.84)
                            .withValues(alpha: 0.92),
                      ],
              ),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                color: _detailPrimaryText(context),
                size: 28 * scale,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SnapScrollPhysics extends ScrollPhysics {
  const _SnapScrollPhysics({super.parent});

  @override
  _SnapScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _SnapScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final simulation = super.createBallisticSimulation(position, velocity);
    if (simulation == null) return null;
    return _SnapSimulation(
      delegateSimulation: simulation,
      position: position,
      itemWidth: 212.0,
    );
  }
}

class _SnapSimulation extends Simulation {
  final Simulation delegateSimulation;
  final ScrollMetrics position;
  final double itemWidth;

  _SnapSimulation({
    required this.delegateSimulation,
    required this.position,
    required this.itemWidth,
  });

  @override
  double x(double time) {
    final value = delegateSimulation.x(time);
    final snapped = (value / itemWidth).round() * itemWidth;
    return snapped.clamp(0.0, position.maxScrollExtent);
  }

  @override
  double dx(double time) => delegateSimulation.dx(time);

  @override
  bool isDone(double time) => delegateSimulation.isDone(time);
}

// ============================================================================
// 区块标题
// ============================================================================

class _SectionTitle extends StatelessWidget {
  final String title;
  final double scaleFactor;
  final Color primaryColor;

  const _SectionTitle({
    required this.title,
    required this.scaleFactor,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final scale = scaleFactor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 4 * scale,
          height: 20 * scale,
          decoration: BoxDecoration(
            color: primaryColor,
            borderRadius: BorderRadius.circular(2 * scale),
          ),
        ),
        SizedBox(width: 10 * scale),
        Text(
          title,
          style: TextStyle(
            fontSize: 18 * scale,
            fontWeight: FontWeight.w700,
            color: _detailPrimaryText(context),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 分集区域
// ============================================================================

class _EpisodesSection extends ConsumerStatefulWidget {
  final String seriesId;
  final String? selectedSeasonId;
  final Color primaryColor;
  final double scaleFactor;
  final bool isGridView;
  final VoidCallback onToggleView;
  final Function(Episode) onEpisodeTap;

  const _EpisodesSection({
    required this.seriesId,
    this.selectedSeasonId,
    required this.primaryColor,
    required this.scaleFactor,
    required this.isGridView,
    required this.onToggleView,
    required this.onEpisodeTap,
  });

  @override
  ConsumerState<_EpisodesSection> createState() => _EpisodesSectionState();
}

class _EpisodesSectionState extends ConsumerState<_EpisodesSection> {
  @override
  Widget build(BuildContext context) {
    final episodesAsync = ref.watch(episodesProvider((
      seriesId: widget.seriesId,
      seasonId: widget.selectedSeasonId,
    )));

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: episodesAsync.when(
        data: (episodes) {
          if (episodes.isEmpty) return const SizedBox.shrink();

          if (widget.isGridView) {
            final scale = widget.scaleFactor;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SectionTitle(
                      title: '分集',
                      scaleFactor: scale,
                      primaryColor: widget.primaryColor,
                    ),
                    SizedBox(width: 12 * scale),
                    Text(
                      '共${episodes.length}集',
                      style: TextStyle(
                        fontSize: 13 * scale,
                        color: _detailHintText(context),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        Icons.list_rounded,
                        size: 20 * scale,
                        color: _detailSecondaryText(context),
                      ),
                      onPressed: widget.onToggleView,
                      tooltip: '切换为海报视图',
                    ),
                  ],
                ),
                SizedBox(height: 16 * scale),
                Wrap(
                  spacing: 10 * scale,
                  runSpacing: 10 * scale,
                  children: episodes.map((episode) {
                    final isWatched = episode.userData?.played ?? false;
                    return _EpisodeStripTile(
                      episode: episode,
                      scaleFactor: scale,
                      primaryColor: widget.primaryColor,
                      isWatched: isWatched,
                      onTap: () => widget.onEpisodeTap(episode),
                    );
                  }).toList(),
                ),
              ],
            );
          }

          return _HorizontalScrollList(
            title: '分集',
            subtitle: '共${episodes.length}集',
            primaryColor: widget.primaryColor,
            scaleFactor: widget.scaleFactor,
            itemWidth: 200 * widget.scaleFactor,
            itemHeight: 160 * widget.scaleFactor,
            trailing: Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.grid_view_rounded,
                    size: 20 * widget.scaleFactor,
                    color: _detailSecondaryText(context),
                  ),
                  onPressed: widget.onToggleView,
                  tooltip: '切换为条形视图',
                ),
              ],
            ),
            children: episodes.map((episode) {
              return _EpisodeCard(
                episode: episode,
                scaleFactor: widget.scaleFactor,
                primaryColor: widget.primaryColor,
                isSelected: false, // TODO: 根据当前播放状态判断
                onTap: () => widget.onEpisodeTap(episode),
              );
            }).toList(),
          );
        },
        loading: () => _buildSkeleton(),
        error: (_, __) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildSkeleton() {
    final scale = widget.scaleFactor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '分集',
          scaleFactor: scale,
          primaryColor: widget.primaryColor,
        ),
        SizedBox(height: 16 * scale),
        SizedBox(
          height: 160 * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 4,
            separatorBuilder: (_, __) => SizedBox(width: 12 * scale),
            itemBuilder: (_, __) => ShimmerBox(
              width: 200 * scale,
              borderRadius: BorderRadius.circular(8 * scale),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 分集卡片
// ============================================================================

class _EpisodeCard extends StatefulWidget {
  final Episode episode;
  final double scaleFactor;
  final Color primaryColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _EpisodeCard({
    required this.episode,
    required this.scaleFactor,
    required this.primaryColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final isWatched = widget.episode.userData?.played ?? false;
    final progress = widget.episode.userData?.playbackPositionTicks != null &&
            widget.episode.runTimeTicks != null
        ? widget.episode.userData!.playbackPositionTicks! /
            widget.episode.runTimeTicks!
        : null;
    final isActive = widget.isSelected || _isHovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: 200 * scale,
          transform: isActive
              ? (Matrix4.identity()..scaleByDouble(1.04, 1.04, 1.0, 1.0))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8 * scale),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 缩略图
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Consumer(
                        builder: (context, ref, child) {
                          final api = ref.read(apiClientProvider);
                          final imageUrls = resolveEpisodeImageUrls(
                            api,
                            widget.episode,
                            maxWidth: 400,
                          );
                          return MediaImage(
                            imageUrl:
                                imageUrls.isNotEmpty ? imageUrls.first : null,
                            imageUrls: imageUrls.length > 1
                                ? imageUrls.sublist(1)
                                : null,
                            width: 200 * scale,
                            height: 112 * scale,
                            fit: BoxFit.cover,
                            placeholder: Container(
                              color: _detailPlaceholderSurface(context),
                            ),
                          );
                        },
                      ),

                      // 集数标签
                      Positioned(
                        top: 8 * scale,
                        left: 8 * scale,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6 * scale,
                            vertical: 2 * scale,
                          ),
                          decoration: BoxDecoration(
                            color: _detailImageOverlay(
                              context,
                              darkAlpha: 0.56,
                              lightAlpha: 0.44,
                            ),
                            borderRadius: BorderRadius.circular(4 * scale),
                          ),
                          child: Text(
                            'E${widget.episode.indexNumber ?? '?'}',
                            style: TextStyle(
                              fontSize: 11 * scale,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),

                      // 已看标记
                      if (isWatched)
                        Positioned(
                          top: 8 * scale,
                          right: 8 * scale,
                          child: Icon(
                            Icons.check_circle,
                            size: 18 * scale,
                            color: Colors.white,
                          ),
                        ),

                      // 进度条
                      if (progress != null && progress > 0 && progress < 1)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor:
                                _detailBorder(context, emphasis: 0.12),
                            valueColor: AlwaysStoppedAnimation(
                              widget.primaryColor,
                            ),
                            minHeight: 3 * scale,
                          ),
                        ),

                      // 悬停遮罩
                      if (_isHovered)
                        Container(
                          color: _detailImageOverlay(context),
                          child: Center(
                            child: Icon(
                              Icons.play_circle_outline,
                              size: 40 * scale,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // 信息区
                Padding(
                  padding: EdgeInsets.all(8 * scale),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        widget.episode.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13 * scale,
                          fontWeight: widget.isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: widget.isSelected
                              ? widget.primaryColor
                              : _detailPrimaryText(context),
                        ),
                      ),
                      SizedBox(height: 2 * scale),
                      Text(
                        '第 ${widget.episode.indexNumber ?? '?'} 集',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11 * scale,
                          color: _detailHintText(context),
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

class _EpisodeStripTile extends StatefulWidget {
  final Episode episode;
  final double scaleFactor;
  final Color primaryColor;
  final bool isWatched;
  final VoidCallback onTap;

  const _EpisodeStripTile({
    required this.episode,
    required this.scaleFactor,
    required this.primaryColor,
    required this.isWatched,
    required this.onTap,
  });

  @override
  State<_EpisodeStripTile> createState() => _EpisodeStripTileState();
}

class _EpisodeStripTileState extends State<_EpisodeStripTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final progress = widget.episode.userData?.playbackPositionTicks != null &&
            widget.episode.runTimeTicks != null
        ? widget.episode.userData!.playbackPositionTicks! /
            widget.episode.runTimeTicks!
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: 92 * scale,
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 12 * scale,
          ),
          decoration: BoxDecoration(
            color: widget.isWatched
                ? widget.primaryColor.withValues(alpha: 0.14)
                : _isHovered
                    ? _detailCardSurface(context, hovered: true)
                    : _detailCardSurface(context),
            borderRadius: BorderRadius.circular(12 * scale),
            border: Border.all(
              color: widget.isWatched
                  ? widget.primaryColor.withValues(alpha: 0.34)
                  : _detailBorder(context, emphasis: 0.08),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.episode.indexNumber ?? '?'}',
                style: TextStyle(
                  fontSize: 22 * scale,
                  fontWeight: FontWeight.w800,
                  color: _detailPrimaryText(context).withValues(alpha: 0.94),
                ),
              ),
              SizedBox(height: 6 * scale),
              Text(
                widget.episode.formattedRuntime ?? '未播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11 * scale,
                  color: _detailHintText(context),
                ),
              ),
              if (progress != null) ...[
                SizedBox(height: 8 * scale),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 3 * scale,
                    backgroundColor: _detailBorder(context, emphasis: 0.08),
                    valueColor: AlwaysStoppedAnimation(widget.primaryColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 分季区域
// ============================================================================

class _SeasonsSection extends ConsumerStatefulWidget {
  final String seriesId;
  final String? selectedSeasonId;
  final Color primaryColor;
  final double scaleFactor;
  final Function(Season) onSeasonTap;

  const _SeasonsSection({
    required this.seriesId,
    this.selectedSeasonId,
    required this.primaryColor,
    required this.scaleFactor,
    required this.onSeasonTap,
  });

  @override
  ConsumerState<_SeasonsSection> createState() => _SeasonsSectionState();
}

class _SeasonsSectionState extends ConsumerState<_SeasonsSection> {
  @override
  Widget build(BuildContext context) {
    final seasonsAsync = ref.watch(seasonsProvider(widget.seriesId));

    return seasonsAsync.when(
      data: (seasons) {
        if (seasons.isEmpty) return const SizedBox.shrink();

        // 排序：特别篇放最后
        final sorted = [...seasons];
        sorted.sort((a, b) {
          final aSpecial = (a.indexNumber ?? 0) == 0;
          final bSpecial = (b.indexNumber ?? 0) == 0;
          if (aSpecial && !bSpecial) return 1;
          if (!aSpecial && bSpecial) return -1;
          return (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
        });

        return _HorizontalScrollList(
          title: '分季',
          primaryColor: widget.primaryColor,
          scaleFactor: widget.scaleFactor,
          itemWidth: 150 * widget.scaleFactor,
          itemHeight: 240 * widget.scaleFactor,
          children: sorted.map((season) {
            final isSelected = season.id == widget.selectedSeasonId;
            final isSpecial = (season.indexNumber ?? 0) == 0;

            return _SeasonCard(
              season: season,
              isSelected: isSelected,
              isSpecial: isSpecial,
              scaleFactor: widget.scaleFactor,
              primaryColor: widget.primaryColor,
              itemHeight: 240 * widget.scaleFactor,
              onTap: () => widget.onSeasonTap(season),
            );
          }).toList(),
        );
      },
      loading: () => _buildSkeleton(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildSkeleton() {
    final scale = widget.scaleFactor;
    const cardWidth = 150.0;
    const cardHeight = 240.0;
    const count = 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '分季',
          scaleFactor: scale,
          primaryColor: widget.primaryColor,
        ),
        SizedBox(height: 16 * scale),
        SizedBox(
          height: cardHeight * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            primary: false,
            physics: const ClampingScrollPhysics(),
            itemCount: count,
            separatorBuilder: (_, __) => SizedBox(width: 16 * scale),
            itemBuilder: (_, __) => ShimmerBox(
              width: cardWidth * scale,
              height: cardHeight * scale,
              borderRadius: BorderRadius.circular(8 * scale),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 分季卡片
// ============================================================================

class _SeasonCard extends StatefulWidget {
  final Season season;
  final bool isSelected;
  final bool isSpecial;
  final double scaleFactor;
  final Color primaryColor;
  final VoidCallback onTap;
  final double itemHeight;

  const _SeasonCard({
    required this.season,
    required this.isSelected,
    required this.isSpecial,
    required this.scaleFactor,
    required this.primaryColor,
    required this.onTap,
    required this.itemHeight,
  });

  @override
  State<_SeasonCard> createState() => _SeasonCardState();
}

class _SeasonCardState extends State<_SeasonCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    const cardWidth = 150.0;
    const posterHeight = 200.0;
    final isActive = widget.isSelected || _isHovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: cardWidth * scale,
          height: widget.itemHeight,
          transform: isActive
              ? (Matrix4.identity()..scaleByDouble(1.04, 1.04, 1.0, 1.0))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8 * scale),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 海报
              ClipRRect(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(8 * scale),
                  topRight: Radius.circular(8 * scale),
                ),
                child: Consumer(
                  builder: (context, ref, child) {
                    final api = ref.read(apiClientProvider);
                    final imageUrls = resolveSeasonImageUrls(
                      api,
                      widget.season,
                      maxWidth: 400,
                    );
                    return MediaImage(
                      imageUrl:
                          imageUrls.isNotEmpty ? imageUrls.first : null,
                      width: cardWidth * scale,
                      height: posterHeight * scale,
                      fit: BoxFit.cover,
                      placeholder: Container(
                        width: cardWidth * scale,
                        height: posterHeight * scale,
                        color: _detailPlaceholderSurface(context),
                        child: Center(
                          child: Text(
                            widget.season.name.isNotEmpty
                                ? widget.season.name.substring(0, 1)
                                : '?',
                            style: TextStyle(
                              fontSize: 32 * scale,
                              fontWeight: FontWeight.bold,
                              color: _detailHintText(context),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // 文字区域
              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(8 * scale),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.isSpecial ? '特别篇' : widget.season.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13 * scale,
                          fontWeight: widget.isSelected ? FontWeight.w700 : FontWeight.w500,
                          color: widget.isSelected
                              ? widget.primaryColor
                              : _detailPrimaryText(context),
                        ),
                      ),
                    ],
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

// ============================================================================
// 演职人员区域
// ============================================================================

class _CastSection extends StatelessWidget {
  final List<Person> persons;
  final Color primaryColor;
  final double scaleFactor;

  const _CastSection({
    required this.persons,
    required this.primaryColor,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context) {
    if (persons.isEmpty) {
      return const SizedBox.shrink();
    }

    final displayPersons = persons.take(15).toList(growable: false);
    return _HorizontalScrollList(
      title: '演职人员',
      primaryColor: primaryColor,
      scaleFactor: scaleFactor,
      itemWidth: 90 * scaleFactor,
      itemHeight: 130 * scaleFactor,
      children: displayPersons.asMap().entries.map((entry) {
        final person = entry.value;
        return _PersonCard(
          person: person,
          scaleFactor: scaleFactor,
          onTap: () {
            context.push('/search?q=${Uri.encodeComponent(person.name)}');
          },
        ).appEntrance(index: entry.key);
      }).toList(growable: false),
    );
  }
}

// ============================================================================
// 演职人员卡片
// ============================================================================

class _PersonCard extends StatefulWidget {
  final Person person;
  final double scaleFactor;
  final VoidCallback onTap;

  const _PersonCard({
    required this.person,
    required this.scaleFactor,
    required this.onTap,
  });

  @override
  State<_PersonCard> createState() => _PersonCardState();
}

class _PersonCardState extends State<_PersonCard> {
  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 90 * scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像
              ClipRRect(
                borderRadius: BorderRadius.circular(4 * scale),
                child: Container(
                  width: 90 * scale,
                  height: 100 * scale,
                  color: _detailPlaceholderSurface(context),
                  child: Consumer(
                    builder: (context, ref, child) {
                      if (widget.person.primaryImageTag == null) {
                        return Center(
                          child: Text(
                            widget.person.name.isNotEmpty
                                ? widget.person.name.substring(0, 1)
                                : '?',
                            style: TextStyle(
                              fontSize: 28 * scale,
                              fontWeight: FontWeight.bold,
                              color: _detailHintText(context),
                            ),
                          ),
                        );
                      }
                      final api = ref.read(apiClientProvider);
                      final imageUrl = api.image.getPrimaryImageUrl(
                        widget.person.id,
                        tag: widget.person.primaryImageTag,
                        maxWidth: 200,
                      );
                      return MediaImage(
                        imageUrl: imageUrl,
                        width: 90 * scale,
                        height: 100 * scale,
                        fit: BoxFit.cover,
                        placeholder: Container(
                          color: _detailPlaceholderSurface(context),
                        ),
                      );
                    },
                  ),
                ),
              ),
              SizedBox(height: 6 * scale),
              // 姓名
              Tooltip(
                message: widget.person.name,
                waitDuration: const Duration(milliseconds: 500),
                child: Text(
                  widget.person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14 * scale,
                    fontWeight: FontWeight.w500,
                    color: _detailPrimaryText(context),
                  ),
                ),
              ),
              // 职位
              if (widget.person.role != null)
                Tooltip(
                  message: widget.person.role!,
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text(
                    widget.person.role!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12 * scale,
                      color: _detailHintText(context),
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

// ============================================================================
// 相关推荐区域
// ============================================================================

class _RelatedSection extends ConsumerStatefulWidget {
  final String itemId;
  final Color primaryColor;
  final double scaleFactor;

  const _RelatedSection({
    required this.itemId,
    required this.primaryColor,
    required this.scaleFactor,
  });

  @override
  ConsumerState<_RelatedSection> createState() => _RelatedSectionState();
}

class _RelatedSectionState extends ConsumerState<_RelatedSection> {
  @override
  Widget build(BuildContext context) {
    final relatedAsync = ref.watch(similarItemsProvider(widget.itemId));

    return relatedAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        final scale = widget.scaleFactor;

        return _HorizontalScrollList(
          title: '相关推荐',
          primaryColor: widget.primaryColor,
          scaleFactor: scale,
          itemWidth: 160 * scale,
          itemHeight: 260 * scale,
          children: items.asMap().entries.map((entry) {
            return DesktopMediaCard(
              item: entry.value,
              width: 160 * scale,
              height: 200 * scale,
              showProgress: false,
            ).appEntrance(index: entry.key);
          }).toList(),
        );
      },
      loading: () => _buildSkeleton(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildSkeleton() {
    final scale = widget.scaleFactor;
    const cardWidth = 160.0;
    const cardHeight = 260.0;
    const spacing = 12.0;
    const count = 8;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '相关推荐',
          scaleFactor: scale,
          primaryColor: widget.primaryColor,
        ),
        SizedBox(height: 16 * scale),
        SizedBox(
          height: cardHeight * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            primary: false,
            physics: const ClampingScrollPhysics(),
            itemCount: count,
            separatorBuilder: (_, __) => SizedBox(width: spacing * scale),
            itemBuilder: (_, __) => ShimmerBox(
              width: cardWidth * scale,
              height: cardHeight * scale,
              borderRadius: BorderRadius.circular(8 * scale),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 骨架屏
// ============================================================================

class _SkeletonView extends StatelessWidget {
  const _SkeletonView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Hero骨架
          Container(
            height: 400,
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.55),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: 6,
              itemBuilder: (_, __) => Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
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

// ============================================================================
// 错误视图
// ============================================================================

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              '加载详情失败',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error
                  .toString()
                  .replaceAll('Exception: ', '')
                  .replaceAll('DioException ', ''),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: _detailSecondaryText(context),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 图片 URL 解析辅助函数（Episode / Season 专用）
// ============================================================================

List<String> resolveEpisodeImageUrls(
  ApiClientFactory api,
  Episode episode, {
  int? maxWidth,
}) {
  final urls = <String>[];
  if (episode.primaryImageTag != null) {
    urls.add(api.image.getPrimaryImageUrl(
      episode.id,
      tag: episode.primaryImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (episode.thumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      episode.id,
      tag: episode.thumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (episode.parentThumbItemId != null &&
      episode.parentThumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      episode.parentThumbItemId!,
      tag: episode.parentThumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (episode.seriesId.isNotEmpty && episode.seriesThumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      episode.seriesId,
      tag: episode.seriesThumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  return urls.where((u) => u.isNotEmpty).toList();
}

List<String> resolveSeasonImageUrls(
  ApiClientFactory api,
  Season season, {
  int? maxWidth,
}) {
  final urls = <String>[];
  if (season.primaryImageTag != null) {
    urls.add(api.image.getPrimaryImageUrl(
      season.id,
      tag: season.primaryImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (season.thumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      season.id,
      tag: season.thumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (season.seriesId.isNotEmpty && season.seriesPrimaryImageTag != null) {
    urls.add(api.image.getPrimaryImageUrl(
      season.seriesId,
      tag: season.seriesPrimaryImageTag,
      maxWidth: maxWidth,
    ));
  }
  if (season.seriesId.isNotEmpty && season.seriesThumbImageTag != null) {
    urls.add(api.image.getThumbImageUrl(
      season.seriesId,
      tag: season.seriesThumbImageTag,
      maxWidth: maxWidth,
    ));
  }
  return urls.where((u) => u.isNotEmpty).toList();
}
