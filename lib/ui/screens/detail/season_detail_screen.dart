import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/cast_service.dart';
import '../../../core/services/download_service.dart';
import '../../screens/download/download_screen.dart';
import '../../widgets/common/media_widgets.dart';

/// 季详情页
class SeasonDetailScreen extends ConsumerStatefulWidget {
  final String seasonId;

  const SeasonDetailScreen({super.key, required this.seasonId});

  @override
  ConsumerState<SeasonDetailScreen> createState() => _SeasonDetailScreenState();
}

class _SeasonDetailScreenState extends ConsumerState<SeasonDetailScreen> {
  String? _seriesId;
  String? _seasonName;

  @override
  void initState() {
    super.initState();
    _loadSeasonInfo();
  }

  Future<void> _loadSeasonInfo() async {
    try {
      final api = ref.read(apiClientProvider);
      final season = await api.media.getItemDetails(widget.seasonId);
      if (mounted) {
        setState(() {
          _seriesId = season.seriesId;
          _seasonName = season.name;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _seasonName = '加载失败';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载季信息失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiClientProvider);

    if (_seriesId == null) {
      return Scaffold(
        appBar: AppBar(title: Text(_seasonName ?? '季详情')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final episodesAsync = ref.watch(episodesProvider((seriesId: _seriesId!, seasonId: widget.seasonId)));

    return Scaffold(
      appBar: AppBar(
        title: Text(_seasonName ?? '季详情'),
      ),
      body: episodesAsync.when(
        data: (episodes) {
          if (episodes.isEmpty) {
            return const Center(child: Text('暂无集数'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              final imageUrl = episode.primaryImageTag != null
                  ? api.image.getPrimaryImageUrl(episode.id, tag: episode.primaryImageTag, maxWidth: 200)
                  : null;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  onTap: () => context.push('/player/${episode.id}'),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 100,
                      height: 60,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: imageUrl != null
                          ? Image.network(imageUrl, fit: BoxFit.cover)
                          : const Center(child: Icon(Icons.play_arrow)),
                    ),
                  ),
                  title: Text('E${episode.indexNumber} ${episode.name}'),
                  subtitle: Text(
                    episode.formattedRuntime ?? '',
                    style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                  trailing: episode.userData?.played ?? false
                      ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
                      : null,
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('错误: $error')),
      ),
    );
  }
}

/// 集详情页（电影/单集通用播放准备页）
class EpisodeDetailScreen extends ConsumerStatefulWidget {
  final String episodeId;

  const EpisodeDetailScreen({super.key, required this.episodeId});

  @override
  ConsumerState<EpisodeDetailScreen> createState() => _EpisodeDetailScreenState();
}

class _EpisodeDetailScreenState extends ConsumerState<EpisodeDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final itemAsync = ref.watch(mediaItemProvider(widget.episodeId));
    final playbackAsync = ref.watch(playbackInfoProvider(widget.episodeId));

    return Scaffold(
      body: itemAsync.when(
        data: (item) => CustomScrollView(
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

            // 播放选项
            SliverToBoxAdapter(
              child: playbackAsync.when(
                data: (info) => _PlaybackOptions(
                  episodeId: widget.episodeId,
                  info: info,
                ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, __) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('加载播放信息失败'),
                ),
              ),
            ),

            // 播放按钮
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _PlayButtons(itemId: widget.episodeId),
              ),
            ),

            // 演职人员
            SliverToBoxAdapter(
              child: _CastSection(itemId: widget.episodeId),
            ),

            // 版本信息
            SliverToBoxAdapter(
              child: playbackAsync.when(
                data: (info) => _VersionInfoSection(info: info),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ),

            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        ),
        loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => Scaffold(
          body: Center(child: Text('错误: $error')),
        ),
      ),
    );
  }
}

/// 详情页头部封面
class _DetailHeader extends ConsumerWidget {
  final MediaItem item;

  const _DetailHeader({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenHeight = MediaQuery.of(context).size.height;
    final headerHeight = screenHeight * 0.30;
    final api = ref.read(apiClientProvider);
    final imageUrl = item.backdropImageTag != null
        ? api.image.getBackdropImageUrl(item.id, tag: item.backdropImageTag, maxWidth: 800)
        : item.primaryImageTag != null
            ? api.image.getPrimaryImageUrl(item.id, tag: item.primaryImageTag, maxWidth: 600)
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
            height: 120,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.5),
                  Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
                  Theme.of(context).scaffoldBackgroundColor,
                ],
                stops: const [0.0, 0.3, 0.8, 1.0],
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
                  color: Colors.white,
                  shadows: [
                    Shadow(blurRadius: 8, color: Colors.black54),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (item.communityRating != null) ...[
                    const Icon(Icons.star, size: 16, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      item.communityRating!.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (item.productionYear != null)
                    Text(
                      '${item.productionYear}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                      ),
                    ),
                  if (item.productionYear != null && item.formattedRuntime != null)
                    const Text(
                      ' · ',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                      ),
                    ),
                  if (item.formattedRuntime != null)
                    Text(
                      item.formattedRuntime!,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                      ),
                    ),
                  const SizedBox(width: 12),
                  ...?item.genres?.take(5).map((genre) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        genre,
                        style: const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ),
                  )),
                ],
              ),
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

/// 播放选项区块
class _PlaybackOptions extends ConsumerWidget {
  final String episodeId;
  final PlaybackInfo info;

  const _PlaybackOptions({required this.episodeId, required this.info});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(currentServerProvider);
    final selectedLineIndex = server?.activeLineIndex ?? 0;
    final selectedAudioIndex = ref.watch(audioTrackProvider);
    final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
    final selectedSecondarySubtitleIndex = ref.watch(secondarySubtitleTrackProvider);
    final selectedSourceId = ref.watch(selectedMediaSourceProvider);

    final mediaSource = selectedSourceId != null
        ? info.mediaSources.firstWhere(
            (s) => s.id == selectedSourceId,
            orElse: () => info.mediaSources.firstOrNull!,
          )
        : info.mediaSources.firstOrNull!;

    final audioStreams = mediaSource.mediaStreams.where((s) => s.isAudio).toList();
    final subtitleStreams = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();

    final selectedAudio = selectedAudioIndex != null
        ? audioStreams.firstWhere(
            (s) => s.index == selectedAudioIndex,
            orElse: () => audioStreams.firstOrNull!,
          )
        : audioStreams.firstOrNull;

    final selectedSubtitle = selectedSubtitleIndex != null
        ? subtitleStreams.firstWhere(
            (s) => s.index == selectedSubtitleIndex,
            orElse: () => subtitleStreams.firstOrNull!,
          )
        : subtitleStreams.firstOrNull;

    final availableSecondarySubs = subtitleStreams.where((s) =>
      selectedSubtitle == null || s.index != selectedSubtitle.index
    ).toList();
    final selectedSecondarySubtitle = selectedSecondarySubtitleIndex != null
        ? availableSecondarySubs.firstWhere(
            (s) => s.index == selectedSecondarySubtitleIndex,
            orElse: () => availableSecondarySubs.firstOrNull!,
          )
        : availableSecondarySubs.firstOrNull;

    final currentLine = server?.lines.isNotEmpty == true
        ? server!.lines[selectedLineIndex.clamp(0, server.lines.length - 1)]
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDropdownTile(
            context,
            icon: Icons.route,
            title: '线路选择',
            value: currentLine?.name ?? '当前线路',
            onTap: () => _showLineSelector(context, ref),
          ),
          if (info.mediaSources.length > 1)
            _buildDropdownTile(
              context,
              icon: Icons.layers,
              title: '版本选择',
              value: mediaSource.name ?? '默认',
              onTap: () => _showSourceSelector(context, ref, info, mediaSource.id),
            ),
          _buildDropdownTile(
            context,
            icon: Icons.audiotrack,
            title: '音频选择',
            value: selectedAudio?.displayTitle ?? '默认音轨',
            onTap: () => _showStreamSelector(context, ref, audioStreams, 'Audio'),
          ),
          _buildDropdownTile(
            context,
            icon: Icons.subtitles,
            title: '字幕选择',
            value: selectedSubtitle?.displayTitle ?? '无字幕',
            onTap: () => _showStreamSelector(context, ref, subtitleStreams, 'Subtitle'),
          ),
          _buildDropdownTile(
            context,
            icon: Icons.subtitles_outlined,
            title: '次字幕选择',
            value: selectedSecondarySubtitle?.displayTitle ?? '无',
            onTap: () => _showSecondarySubtitleSelector(context, ref, availableSecondarySubs),
          ),
        ],
      ),
    );
  }

  void _showLineSelector(BuildContext context, WidgetRef ref) {
    final server = ref.read(currentServerProvider);
    if (server == null) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选择线路',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const Divider(height: 1),
            ...server.lines.asMap().entries.map((entry) {
              final idx = entry.key;
              final line = entry.value;
              return ListTile(
                title: Text(line.name),
                trailing: idx == server.activeLineIndex
                    ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                    : null,
                onTap: () {
                  ref.read(serverListProvider.notifier).setActiveLine(server.id, idx);
                  // 同步更新 currentServerProvider，确保 UI 实时刷新
                  final updatedServer = ref.read(serverListProvider).firstWhere((s) => s.id == server.id);
                  ref.read(currentServerProvider.notifier).state = updatedServer;
                  ref.invalidate(playbackInfoProvider(episodeId));
                  Navigator.pop(ctx);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  void _showSourceSelector(BuildContext context, WidgetRef ref, PlaybackInfo info, String currentSourceId) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选择版本',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const Divider(height: 1),
            ...info.mediaSources.map((source) {
              return ListTile(
                title: Text(source.name ?? '默认'),
                subtitle: Text(source.container ?? ''),
                trailing: source.id == currentSourceId
                    ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                    : null,
                onTap: () {
                  ref.read(selectedMediaSourceProvider.notifier).state = source.id;
                  // 重置音频和字幕选择（因为不同版本的轨道可能不同）
                  ref.read(audioTrackProvider.notifier).state = null;
                  ref.read(subtitleTrackProvider.notifier).state = null;
                  ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                  ref.invalidate(playbackInfoProvider(episodeId));
                  Navigator.pop(ctx);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  void _showStreamSelector(BuildContext context, WidgetRef ref, List<MediaStream> streams, String type) {
    final currentIndex = type == 'Audio'
        ? ref.read(audioTrackProvider)
        : ref.read(subtitleTrackProvider);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    type == 'Audio' ? '选择音频轨道' : '选择字幕轨道',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (streams.isEmpty)
              const ListTile(title: Text('无可用轨道'))
            else
              ...streams.map((stream) {
                final isSelected = currentIndex == stream.index;
                return ListTile(
                  title: Text(stream.displayTitle ?? stream.language ?? '轨道 ${stream.index}'),
                  subtitle: stream.codec != null ? Text('编码: ${stream.codec}') : null,
                  trailing: isSelected
                      ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                      : null,
                  onTap: () {
                    if (type == 'Audio') {
                      ref.read(audioTrackProvider.notifier).state = stream.index;
                    } else {
                      ref.read(subtitleTrackProvider.notifier).state = stream.index;
                      if (ref.read(secondarySubtitleTrackProvider) == stream.index) {
                        ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                      }
                    }
                    ref.invalidate(playbackInfoProvider(episodeId));
                    Navigator.pop(ctx);
                  },
                );
              }),
          ],
        ),
      ),
    );
  }

  void _showSecondarySubtitleSelector(BuildContext context, WidgetRef ref, List<MediaStream> streams) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text(
                    '选择次字幕轨道',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              title: const Text('关闭次字幕'),
              trailing: ref.read(secondarySubtitleTrackProvider) == null
                  ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                  : null,
              onTap: () {
                ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                ref.invalidate(playbackInfoProvider(episodeId));
                Navigator.pop(ctx);
              },
            ),
            const Divider(height: 1),
            if (streams.isEmpty)
              const ListTile(title: Text('无可用轨道'))
            else
              ...streams.map((stream) {
                final isSelected = ref.read(secondarySubtitleTrackProvider) == stream.index;
                return ListTile(
                  title: Text(stream.displayTitle ?? stream.language ?? '轨道 ${stream.index}'),
                  subtitle: stream.codec != null ? Text('编码: ${stream.codec}') : null,
                  trailing: isSelected
                      ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                      : null,
                  onTap: () {
                    ref.read(secondarySubtitleTrackProvider.notifier).state = stream.index;
                    ref.invalidate(playbackInfoProvider(episodeId));
                    Navigator.pop(ctx);
                  },
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                value,
                style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

/// 播放按钮组（播放 5/6 + 更多 1/6）
class _PlayButtons extends ConsumerWidget {
  final String itemId;

  const _PlayButtons({required this.itemId});

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
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: OutlinedButton(
            onPressed: () => _showMoreMenu(context, ref),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
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
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cast),
              title: const Text('投屏'),
              subtitle: const Text('搜索局域网设备', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showCastDialog(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索其他播放源'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/search');
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载'),
              onTap: () async {
                Navigator.pop(ctx);
                final videoUrl = api.playback.getVideoStreamUrl(itemId);
                final item = await api.media.getItemDetails(itemId);
                final taskId = await ref.read(downloadServiceProvider).addDownload(
                  itemId: itemId,
                  title: item.name,
                  url: videoUrl,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(taskId != null ? '已添加到下载队列' : '添加下载失败')),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('标记为已/未观看'),
              onTap: () async {
                Navigator.pop(ctx);
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
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(isWatched ? '已标记为未观看' : '已标记为已观看')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('操作失败: $e')),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('添加到喜欢'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  final item = await api.media.getItemDetails(itemId);
                  final isFav = item.userData?.isFavorite ?? false;
                  if (isFav) {
                    await api.favorite.removeFavorite(itemId);
                  } else {
                    await api.favorite.addFavorite(itemId);
                  }
                  ref.invalidate(mediaItemProvider(itemId));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(isFav ? '已取消喜欢' : '已添加到喜欢')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('操作失败: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCastDialog(BuildContext context, WidgetRef ref) {
    final castService = CastService();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
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
          child: AnimatedBuilder(
            animation: castService,
            builder: (context, _) {
              final devices = castService.devices;
              if (devices.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cast_connected, size: 48, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('正在搜索设备...'),
                      SizedBox(height: 8),
                      Text(
                        '请确保电视/投屏器与手机在同一WiFi下',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
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
                    trailing: device.isConnected
                        ? const Icon(Icons.check_circle, color: Color(0xFF5B8DEF))
                        : null,
                    onTap: () async {
                      final api = ref.read(apiClientProvider);
                      final videoUrl = api.playback.getVideoStreamUrl(itemId);
                      final connected = await castService.connect(device);
                      if (connected) {
                        final success = await castService.castVideo(videoUrl);
                        if (context.mounted) {
                          Navigator.pop(ctx);
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
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              castService.dispose();
              Navigator.pop(ctx);
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    castService.startDiscovery();
  }
}

/// 演职人员区块
class _CastSection extends ConsumerWidget {
  final String itemId;

  const _CastSection({required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personsAsync = ref.watch(personsProvider(itemId));

    return personsAsync.when(
      data: (persons) {
        if (persons.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '演职人员'),
            HorizontalList(
              height: 140,
              children: persons.map((person) {
                return SizedBox(
                  width: 80,
                  child: _PersonCard(person: person),
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

class _PersonCard extends ConsumerWidget {
  final Person person;

  const _PersonCard({required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = person.primaryImageTag != null
        ? api.image.getPrimaryImageUrl(person.id, tag: person.primaryImageTag, maxWidth: 200)
        : null;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(40),
          child: Container(
            width: 72,
            height: 72,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: imageUrl != null
                ? Image.network(imageUrl, fit: BoxFit.cover)
                : const Icon(Icons.person, size: 32, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          person.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        if (person.role != null)
          Text(
            person.role!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
      ],
    );
  }
}

/// 版本信息区块
class _VersionInfoSection extends StatelessWidget {
  final PlaybackInfo info;

  const _VersionInfoSection({required this.info});

  @override
  Widget build(BuildContext context) {
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
                            Text(subtitle.displayTitle ?? subtitle.language ?? '', style: const TextStyle(fontSize: 13)),
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
  }
}
