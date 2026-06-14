import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/download_service.dart';
import '../../../core/theme/app_motion.dart';

/// 下载服务Provider
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService();
  service.initialize();
  ref.onDispose(() => service.dispose());
  return service;
});

/// 本地下载页
class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});
  
  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  @override
  void initState() {
    super.initState();
    // 加载已有任务
    Future.microtask(() => ref.read(downloadServiceProvider).loadTasks());
  }
  
  @override
  Widget build(BuildContext context) {
    final downloadService = ref.watch(downloadServiceProvider);
    final tasks = downloadService.tasks;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地下载'),
        actions: [
          if (tasks.any((d) => d.status == 'completed'))
            TextButton(
              onPressed: () => _clearCompleted(context),
              child: const Text('清除已完成'),
            ),
        ],
      ),
      body: tasks.isEmpty
          ? _buildEmptyState(context)
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: tasks.length,
              itemBuilder: (context, index) {
                final task = tasks[index];
                return _DownloadItemCard(task: task).appEntrance(index: index);
              },
            ),
    );
  }
  
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_done,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无下载内容',
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '在媒体详情页点击"下载"开始',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }
  
  void _clearCompleted(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除已完成'),
        content: const Text('确定要清除所有已完成的下载任务吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final service = ref.read(downloadServiceProvider);
              final completed = service.tasks.where((t) => t.status == 'completed').toList();
              for (final task in completed) {
                service.removeDownload(task.taskId);
              }
              Navigator.pop(context);
            },
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }
}

class _DownloadItemCard extends ConsumerWidget {
  final DownloadTask task;
  
  const _DownloadItemCard({required this.task});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCompleted = task.status == 'completed';
    final isPaused = task.status == 'paused';
    final isFailed = task.status == 'failed' || task.status == 'canceled';
    final isPending = task.status == 'pending';
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: isCompleted ? () => _openFile(ref) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 80,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.movie),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (task.episode != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        task.episode!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (isFailed) ...[
                      Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 14,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '下载失败',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ] else if (!isCompleted && !isPending) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: task.progress / 100,
                          backgroundColor: Colors.grey.shade300,
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${task.progress}%',
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            _getStatusText(task.status),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).textTheme.bodySmall?.color,
                            ),
                          ),
                        ],
                      ),
                    ] else if (isPending) ...[
                      Row(
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '等待中...',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).textTheme.bodySmall?.color,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '已完成',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 操作按钮
              if (isCompleted)
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => _playDownload(context, ref),
                )
              else if (isFailed)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _retryDownload(ref),
                )
              else if (isPaused)
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => _resumeDownload(ref),
                )
              else if (!isPending)
                IconButton(
                  icon: const Icon(Icons.pause),
                  onPressed: () => _pauseDownload(ref),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteDownload(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  String _getStatusText(String status) {
    switch (status) {
      case 'pending':
        return '等待中';
      case 'downloading':
        return '下载中';
      case 'paused':
        return '已暂停';
      case 'completed':
        return '已完成';
      case 'failed':
        return '失败';
      case 'canceled':
        return '已取消';
      default:
        return status;
    }
  }
  
  void _playDownload(BuildContext context, WidgetRef ref) {
    // 播放本地文件或在线播放
    context.push('/player/${task.itemId}');
  }
  
  void _openFile(WidgetRef ref) {
    ref.read(downloadServiceProvider).openDownloadedFile(task.taskId);
  }
  
  void _pauseDownload(WidgetRef ref) {
    ref.read(downloadServiceProvider).pauseDownload(task.taskId);
  }
  
  void _resumeDownload(WidgetRef ref) {
    ref.read(downloadServiceProvider).resumeDownload(task.taskId);
  }
  
  void _retryDownload(WidgetRef ref) {
    ref.read(downloadServiceProvider).retryDownload(task.taskId);
  }
  
  void _deleteDownload(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 "${task.title}" 的下载任务吗？文件也会被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              ref.read(downloadServiceProvider).removeDownload(task.taskId);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
