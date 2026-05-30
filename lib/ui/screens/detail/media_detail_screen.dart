import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/cast_service.dart';
import '../../screens/download/download_screen.dart';
import '../../widgets/common/media_widgets.dart';

/// 媒体详情页（剧/电影通用）
class MediaDetailScreen extends ConsumerWidget {
  final String itemId;

  const MediaDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemAsync = ref.watch(mediaItemProvider(itemId));

    return Scaffold(
      body: itemAsync.when(
        data: (item) => _DetailContent(item: item, itemId: itemId),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorView(
          error: error,
          onRetry: () => ref.invalidate(mediaItemProvider(itemId)),
        ),
      ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  final MediaItem item;
  final String itemId;

  const _DetailContent({required this.item, required this.itemId});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // 封面区域
        SliverToBoxAdapter(
          child: _DetailHeader(item: item),
        ),

        // 简介
        if (item.overview != null && item.overview!.isNotEmpty)
          SliverToBoxAdapter(
            child: _OverviewSection(overview: item.overview!),
          ),

        // 剧集相关区块
        if (item.type == 'Series') ...[
          SliverToBoxAdapter(
            child: _SeasonsAndEpisodesSection(
              itemId: itemId,
              onEpisodeTap: (episode) => context.push('/episode/${episode.id}'),
              onSeasonTap: (season) => context.push('/season/${season.id}'),
            ),
          ),
        ],

        // 电影播放按钮
        if (item.type == 'Movie') ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _MoviePlayButtons(itemId: itemId),
            ),
          ),
          SliverToBoxAdapter(
            child: _VersionInfoSection(itemId: itemId),
          ),
        ],

        const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
  }
}

class _SeasonsAndEpisodesSection extends ConsumerWidget {
  final String itemId;
  final Function(Episode) onEpisodeTap;
  final Function(Season) onSeasonTap;

  const _SeasonsAndEpisodesSection({
    required this.itemId,
    required this.onEpisodeTap,
    required this.onSeasonTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasonsAsync = ref.watch(seasonsProvider(itemId));
    final episodesAsync = ref.watch(episodesProvider((seriesId: itemId, seasonId: null)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SeasonsSection(
          seasonsAsync: seasonsAsync,
          onSeasonTap: onSeasonTap,
        ),
        _EpisodesSection(
          title: '集数选择',
          episodesAsync: episodesAsync,
          onEpisodeTap: onEpisodeTap,
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

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
              error.toString().replaceAll('Exception: ', '').replaceAll('DioException ', ''),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).textTheme.bodySmall?.color,
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

/// 详情页头部
class _DetailHeader extends ConsumerWidget {
  final MediaItem item;

  const _DetailHeader({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenWidth = MediaQuery.of(context).size.width;
    final headerHeight = screenWidth * 0.55;
    final api = ref.read(apiClientProvider);
    // 使用Primary封面图作为背景（2:3海报比例，显示效果更好）
    final imageUrl = item.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 600)
        : item.backdropImageTag != null
            ? api.image.getBackdropImageUrl(item.id, tag: item.backdropImageTag, maxWidth: 800)
            : null;
    
    return Stack(
      children: [
        SizedBox(
          height: headerHeight,
          width: double.infinity,
          child: MediaImage(
            imageUrl: imageUrl,
            width: double.infinity,
            height: headerHeight,
            fit: BoxFit.cover,
          ),
        ),
        
        // 底部渐变
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 150,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.9),
                  Theme.of(context).scaffoldBackgroundColor,
                ],
              ),
            ),
          ),
        ),
        
        // 返回按钮
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: CircleAvatar(
              backgroundColor: Colors.black.withValues(alpha: 0.4),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => context.pop(),
              ),
            ),
          ),
        ),
        
        // 标题信息
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.name,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (item.communityRating != null) ...[
                    RatingBadge(rating: item.communityRating),
                    const SizedBox(width: 12),
                  ],
                  ...?item.genres?.take(5).map((genre) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: TagBadge(text: genre),
                  )),
                ],
              ),
              if (item.type == 'Movie' && item.productionYear != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${item.productionYear} · ${item.formattedRuntime ?? ''}',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 简介区块
class _OverviewSection extends StatefulWidget {
  final String overview;
  
  const _OverviewSection({required this.overview});
  
  @override
  State<_OverviewSection> createState() => _OverviewSectionState();
}

class _OverviewSectionState extends State<_OverviewSection> {
  bool _expanded = false;
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.overview,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
          if (widget.overview.length > 100)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _expanded ? '收起' : '展开',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 季选择区块
class _SeasonsSection extends ConsumerWidget {
  final AsyncValue<List<Season>> seasonsAsync;
  final Function(Season) onSeasonTap;
  
  const _SeasonsSection({
    required this.seasonsAsync,
    required this.onSeasonTap,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return seasonsAsync.when(
      data: (seasons) {
        if (seasons.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '季度选择'),
            HorizontalList(
              height: 160,
              children: seasons.map((season) {
                return SizedBox(
                  width: 120,
                  child: InkWell(
                    onTap: () => onSeasonTap(season),
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      children: [
                        Expanded(
                          child: _SeasonCard(season: season),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          season.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _SeasonCard extends ConsumerWidget {
  final Season season;

  const _SeasonCard({required this.season});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = season.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(season.id, tag: season.primaryImageTag, maxWidth: 300)
        : null;

    if (imageUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: MediaImage(
          imageUrl: imageUrl,
          width: 120,
          height: 120,
          fit: BoxFit.cover,
          borderRadius: BorderRadius.circular(8),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          'S${season.indexNumber}',
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF5B8DEF),
          ),
        ),
      ),
    );
  }
}

/// 集数选择区块
class _EpisodesSection extends StatefulWidget {
  final String title;
  final AsyncValue<List<Episode>> episodesAsync;
  final Function(Episode) onEpisodeTap;
  
  const _EpisodesSection({
    required this.title,
    required this.episodesAsync,
    required this.onEpisodeTap,
  });
  
  @override
  State<_EpisodesSection> createState() => _EpisodesSectionState();
}

class _EpisodesSectionState extends State<_EpisodesSection> {
  bool _isGridView = false;
  
  @override
  Widget build(BuildContext context) {
    return widget.episodesAsync.when(
      data: (episodes) {
        if (episodes.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
                    onPressed: () => setState(() => _isGridView = !_isGridView),
                  ),
                ],
              ),
            ),
            if (_isGridView)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: episodes.map((episode) {
                    final isWatched = episode.userData?.played ?? false;
                    return GestureDetector(
                      onTap: () => widget.onEpisodeTap(episode),
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: isWatched
                              ? const Color(0xFF5B8DEF).withValues(alpha: 0.1)
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: isWatched
                              ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                              : Text(
                                  'E${episode.indexNumber}',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              )
            else
              ...episodes.map((episode) => _EpisodeListTile(
                episode: episode,
                onTap: () => widget.onEpisodeTap(episode),
              )),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _EpisodeListTile extends ConsumerWidget {
  final Episode episode;
  final VoidCallback onTap;
  
  const _EpisodeListTile({required this.episode, required this.onTap});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWatched = episode.userData?.played ?? false;
    final api = ref.read(apiClientProvider);
    // 剧集缩略图使用Primary类型，如果没有则尝试使用Thumb
    final imageUrl = episode.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(episode.id, tag: episode.primaryImageTag, maxWidth: 300)
        : null;
    
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 100,
        height: 60,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: imageUrl != null
            ? MediaImage(
                imageUrl: imageUrl,
                width: 100,
                height: 60,
                fit: BoxFit.cover,
              )
            : const Center(child: Icon(Icons.play_arrow)),
      ),
      title: Row(
        children: [
          if (isWatched)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.check_circle, size: 16, color: Color(0xFF5B8DEF)),
            ),
          Expanded(
            child: Text(
              'E${episode.indexNumber} ${episode.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        episode.formattedRuntime ?? '',
        style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
      ),
    );
  }
}

/// 电影播放按钮
class _MoviePlayButtons extends ConsumerWidget {
  final String itemId;
  
  const _MoviePlayButtons({required this.itemId});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: FilledButton.icon(
            onPressed: () => context.push('/player/$itemId'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('播放'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: OutlinedButton(
            onPressed: () => _showMoreMenu(context, ref),
            child: const Icon(Icons.more_vert),
          ),
        ),
      ],
    );
  }
  
  void _showMoreMenu(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cast),
              title: const Text('投屏'),
              subtitle: const Text('搜索局域网设备', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _showCastDialog(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索其他播放源'),
              onTap: () {
                Navigator.pop(context);
                context.push('/search');
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载'),
              onTap: () {
                Navigator.pop(context);
                _addToDownload(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('标记为已/未观看'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  final item = await api.media.getItemDetails(itemId);
                  final isWatched = item.userData?.played ?? false;
                  if (isWatched) {
                    await api.playback.reportPlaybackStopped(PlaybackStopInfo(
                      itemId: itemId,
                      mediaSourceId: '',
                      positionTicks: 0,
                    ));
                  } else {
                    await api.playback.reportPlaybackStart(PlaybackStartInfo(
                      itemId: itemId,
                      mediaSourceId: '',
                    ));
                    await api.playback.reportPlaybackStopped(PlaybackStopInfo(
                      itemId: itemId,
                      mediaSourceId: '',
                      positionTicks: item.runTimeTicks ?? 0,
                    ));
                  }
                  ref.invalidate(mediaItemProvider(itemId));
                } catch (_) {}
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('添加到喜欢'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  final item = await api.media.getItemDetails(itemId);
                  final isFav = item.userData?.isFavorite ?? false;
                  if (isFav) {
                    await api.favorite.removeFavorite(itemId);
                  } else {
                    await api.favorite.addFavorite(itemId);
                  }
                  ref.invalidate(mediaItemProvider(itemId));
                } catch (_) {}
              },
            ),
          ],
        ),
      ),
    );
  }

  void _addToDownload(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiClientProvider);
    final videoUrl = api.playback.getVideoStreamUrl(itemId);
    final item = await api.media.getItemDetails(itemId);
    
    final taskId = await ref.read(downloadServiceProvider).addDownload(
      itemId: itemId,
      title: item.name,
      url: videoUrl,
    );

    if (context.mounted) {
      if (taskId != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已添加到下载队列')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('添加下载失败')),
        );
      }
    }
  }

  void _showCastDialog(BuildContext context, WidgetRef ref) {
    final castService = CastService();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Text('投屏设备'),
            const Spacer(),
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: _CastDeviceList(
            castService: castService,
            onDeviceSelected: (device) async {
              Navigator.pop(context);
              final api = ref.read(apiClientProvider);
              final videoUrl = api.playback.getVideoStreamUrl(itemId);
              
              final connected = await castService.connect(device);
              if (connected) {
                final success = await castService.castVideo(videoUrl);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success 
                        ? '已投屏到 ${device.name}'
                        : '投屏失败，请重试'),
                    ),
                  );
                }
              } else {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('连接设备失败')),
                  );
                }
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              castService.dispose();
              Navigator.pop(context);
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    
    // 开始扫描
    castService.startDiscovery();
  }
}

/// 设备列表组件
class _CastDeviceList extends StatefulWidget {
  final CastService castService;
  final Function(CastDevice) onDeviceSelected;
  
  const _CastDeviceList({
    required this.castService,
    required this.onDeviceSelected,
  });
  
  @override
  State<_CastDeviceList> createState() => _CastDeviceListState();
}

class _CastDeviceListState extends State<_CastDeviceList> {
  @override
  void initState() {
    super.initState();
    widget.castService.addListener(_onUpdate);
  }
  
  @override
  void dispose() {
    widget.castService.removeListener(_onUpdate);
    super.dispose();
  }
  
  void _onUpdate() {
    setState(() {});
  }
  
  @override
  Widget build(BuildContext context) {
    final devices = widget.castService.devices;
    
    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cast_connected,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '正在搜索设备...',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请确保电视/投屏器与手机在同一WiFi下',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return ListTile(
          leading: const Icon(Icons.tv),
          title: Text(device.name),
          subtitle: Text('${device.host}:${device.port}'),
          trailing: device.isConnected 
              ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
              : null,
          onTap: () => widget.onDeviceSelected(device),
        );
      },
    );
  }
}

/// 版本信息区块
class _VersionInfoSection extends ConsumerWidget {
  final String itemId;
  
  const _VersionInfoSection({required this.itemId});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackAsync = ref.watch(playbackInfoProvider(itemId));
    
    return playbackAsync.when(
      data: (info) {
        if (info.mediaSources.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '版本信息'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: info.mediaSources.map((source) {
                  final video = source.mediaStreams.where((s) => s.isVideo).firstOrNull;
                  final audio = source.mediaStreams.where((s) => s.isAudio).firstOrNull;
                  final subtitle = source.mediaStreams.where((s) => s.isSubtitle).firstOrNull;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (source.name != null) ...[
                            Text(source.name!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            const SizedBox(height: 6),
                          ],
                          if (video != null)
                            Row(
                              children: [
                                Icon(Icons.videocam, size: 16, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 6),
                                Text(video.displayTitle ?? '${video.codec ?? ""} ${video.resolution}', style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          if (audio != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(Icons.audiotrack, size: 16, color: Theme.of(context).colorScheme.secondary),
                                const SizedBox(width: 6),
                                Text(audio.displayTitle ?? '${audio.language ?? ""} ${audio.codec ?? ""} ${audio.channels ?? 0}ch', style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ],
                          if (subtitle != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(Icons.subtitles, size: 16, color: Theme.of(context).colorScheme.tertiary),
                                const SizedBox(width: 6),
                                Text(subtitle.readableLabel(), style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
