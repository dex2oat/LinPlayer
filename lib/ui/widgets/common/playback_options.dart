import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';

/// 播放选项组件（线路/版本/音频/字幕/次字幕）
class PlaybackOptions extends ConsumerWidget {
  final String itemId;
  final PlaybackInfo info;

  const PlaybackOptions({super.key, required this.itemId, required this.info});

  MediaSource? _resolveMediaSource(PlaybackInfo info, String? selectedSourceId) {
    if (info.mediaSources.isEmpty) {
      return null;
    }
    if (selectedSourceId == null || selectedSourceId.isEmpty) {
      return info.mediaSources.firstOrNull;
    }
    return info.mediaSources.where((source) => source.id == selectedSourceId).firstOrNull ??
        info.mediaSources.firstOrNull;
  }

  MediaStream? _resolveSelectedStream(List<MediaStream> streams, int? selectedIndex) {
    if (streams.isEmpty) {
      return null;
    }
    if (selectedIndex == null) {
      return streams.where((stream) => stream.isDefault == true).firstOrNull ??
          streams.firstOrNull;
    }
    // 先尝试精确匹配 index，找不到则回退到默认或第一个
    return streams.where((stream) => stream.index == selectedIndex).firstOrNull ??
        streams.where((stream) => stream.isDefault == true).firstOrNull ??
        streams.firstOrNull;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(currentServerProvider);
    final selectedLineIndex = server?.activeLineIndex ?? 0;
    final selectedAudioIndex = ref.watch(audioTrackProvider);
    final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
    final selectedSecondarySubtitleIndex = ref.watch(secondarySubtitleTrackProvider);
    final selectedSourceId = ref.watch(selectedMediaSourceProvider);

    final mediaSource = _resolveMediaSource(info, selectedSourceId);
    if (mediaSource == null) {
      return const SizedBox.shrink();
    }
    if (selectedSourceId != null && selectedSourceId != mediaSource.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(selectedMediaSourceProvider) == selectedSourceId) {
          ref.read(selectedMediaSourceProvider.notifier).state = mediaSource.id;
        }
      });
    }

    final audioStreams = mediaSource.mediaStreams.where((s) => s.isAudio).toList();
    final subtitleStreams = mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();

    final selectedAudio = _resolveSelectedStream(audioStreams, selectedAudioIndex);

    final selectedSubtitle =
        _resolveSelectedStream(subtitleStreams, selectedSubtitleIndex);

    final availableSecondarySubs = subtitleStreams.where((s) =>
      selectedSubtitle == null || s.index != selectedSubtitle.index
    ).toList();
    final selectedSecondarySubtitle = _resolveSelectedStream(
      availableSecondarySubs,
      selectedSecondarySubtitleIndex,
    );
    if (selectedAudioIndex == null && selectedAudio?.index != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(audioTrackProvider) == null) {
          ref.read(audioTrackProvider.notifier).state = selectedAudio!.index;
        }
      });
    }
    if (selectedSubtitleIndex == null && selectedSubtitle?.index != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(subtitleTrackProvider) == null) {
          ref.read(subtitleTrackProvider.notifier).state = selectedSubtitle!.index;
        }
      });
    }

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
          Consumer(
            builder: (context, ref, _) {
              final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
              final selectedSubtitle = _resolveSelectedStream(subtitleStreams, selectedSubtitleIndex);
              return _buildDropdownTile(
                context,
                icon: Icons.subtitles,
                title: '字幕选择',
                value: selectedSubtitle?.displayTitle ?? '无字幕',
                onTap: () => _showStreamSelector(context, ref, subtitleStreams, 'Subtitle'),
              );
            },
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
      builder: (ctx) => Consumer(
        builder: (context, ref, _) {
          final currentServer = ref.watch(currentServerProvider) ?? server;
          return SafeArea(
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
                ...currentServer.lines.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final line = entry.value;
                  return ListTile(
                    title: Text(line.name),
                    trailing: idx == currentServer.activeLineIndex
                        ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                        : null,
                    onTap: () {
                      ref.read(serverListProvider.notifier).setActiveLine(currentServer.id, idx);
                      final updatedServer = ref.read(serverListProvider).firstWhere((s) => s.id == currentServer.id);
                      ref.read(currentServerProvider.notifier).state = updatedServer;
                      ref.read(selectedMediaSourceProvider.notifier).state = null;
                      ref.read(audioTrackProvider.notifier).state = null;
                      ref.read(subtitleTrackProvider.notifier).state = null;
                      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                      ref.invalidate(playbackInfoProvider(itemId));
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showSourceSelector(BuildContext context, WidgetRef ref, PlaybackInfo info, String currentSourceId) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Consumer(
        builder: (context, ref, _) {
          final selectedSourceId = ref.watch(selectedMediaSourceProvider) ?? currentSourceId;
          return SafeArea(
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
                    trailing: source.id == selectedSourceId
                        ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                        : null,
                    onTap: () {
                      ref.read(selectedMediaSourceProvider.notifier).state = source.id;
                      ref.read(audioTrackProvider.notifier).state = null;
                      ref.read(subtitleTrackProvider.notifier).state = null;
                      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showStreamSelector(BuildContext context, WidgetRef ref, List<MediaStream> streams, String type) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Consumer(
        builder: (context, ref, _) {
          final currentIndex = type == 'Audio'
              ? ref.watch(audioTrackProvider)
              : ref.watch(subtitleTrackProvider);
          final secondaryIndex = ref.watch(secondarySubtitleTrackProvider);
          return SafeArea(
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
                      title: Text(stream.readableLabel(siblings: streams)),
                      subtitle: stream.codec != null ? Text('编码: ${stream.codec}') : null,
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                          : null,
                      onTap: () {
                        if (type == 'Audio') {
                          ref.read(audioTrackProvider.notifier).state = stream.index;
                        } else {
                          ref.read(subtitleTrackProvider.notifier).state = stream.index;
                          if (secondaryIndex == stream.index) {
                            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                          }
                        }
                        Navigator.pop(ctx);
                      },
                    );
                  }),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showSecondarySubtitleSelector(BuildContext context, WidgetRef ref, List<MediaStream> streams) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Consumer(
        builder: (context, ref, _) {
          final secondaryIndex = ref.watch(secondarySubtitleTrackProvider);
          return SafeArea(
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
                  trailing: secondaryIndex == null
                      ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                      : null,
                  onTap: () {
                    ref.read(secondarySubtitleTrackProvider.notifier).state = null;
                    Navigator.pop(ctx);
                  },
                ),
                const Divider(height: 1),
                if (streams.isEmpty)
                  const ListTile(title: Text('无可用轨道'))
                else
                  ...streams.map((stream) {
                    final isSelected = secondaryIndex == stream.index;
                    return ListTile(
                      title: Text(stream.readableLabel(siblings: streams)),
                      subtitle: stream.codec != null ? Text('编码: ${stream.codec}') : null,
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                          : null,
                      onTap: () {
                        ref.read(secondarySubtitleTrackProvider.notifier).state = stream.index;
                        Navigator.pop(ctx);
                      },
                    );
                  }),
              ],
            ),
          );
        },
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 第一行：选项名称（放大字体）
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // 第二行：选项内容（缩小字体）
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}
