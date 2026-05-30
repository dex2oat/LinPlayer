import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/ext_domain_service.dart';

/// 服务器线路管理页面
class ServerLinesScreen extends ConsumerStatefulWidget {
  final String serverId;
  
  const ServerLinesScreen({super.key, required this.serverId});
  
  @override
  ConsumerState<ServerLinesScreen> createState() => _ServerLinesScreenState();
}

class _ServerLinesScreenState extends ConsumerState<ServerLinesScreen> {
  bool _isSyncing = false;
  
  Future<void> _syncLines() async {
    final config = ref.read(extDomainConfigProvider);
    if (config == null || config.extDomainUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先配置线路同步地址')),
      );
      return;
    }

    final servers = ref.read(serverListProvider);
    final server = servers.firstWhere((s) => s.id == widget.serverId);
    
    if (server.authToken == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务器未登录，无法同步')),
      );
      return;
    }

    setState(() {
      _isSyncing = true;
    });

    try {
      final service = ref.read(extDomainServiceProvider);
      final lines = await service.fetchExtDomains(
        extDomainUrl: config.extDomainUrl,
        embyServerUrl: server.baseUrl,
        embyToken: server.authToken!,
      );

      if (lines.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未获取到线路列表')),
          );
        }
        return;
      }

      // 将获取的线路转换为 ServerLine 并更新到当前服务器
      final newLines = lines.map((l) => ServerLine(
        id: '${DateTime.now().millisecondsSinceEpoch}_${l.name}',
        name: l.name,
        url: l.url,
        remark: l.remark,
      )).toList();

      // 合并现有线路和新线路（去重）
      final existingLines = server.lines;
      final mergedLines = [...existingLines];
      for (final newLine in newLines) {
        if (!mergedLines.any((l) => l.url == newLine.url)) {
          mergedLines.add(newLine);
        }
      }

      final updatedServer = server.copyWith(lines: mergedLines);
      ref.read(serverListProvider.notifier).updateServer(updatedServer);
      
      // 如果当前选中的就是这个服务器，也更新当前服务器
      final currentServer = ref.read(currentServerProvider);
      if (currentServer?.id == widget.serverId) {
        ref.read(currentServerProvider.notifier).state = updatedServer;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功同步 ${lines.length} 条线路')),
        );
      }
    } on ExtDomainException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: ${e.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final server = servers.firstWhere((s) => s.id == widget.serverId);
    
    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            const Text('服务器线路'),
            Text(
              server.name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _isSyncing ? null : _syncLines,
            tooltip: '同步线路',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: server.lines.length,
              itemBuilder: (context, index) {
                final line = server.lines[index];
                final isActive = index == server.activeLineIndex;
                
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: isActive 
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    onTap: () {
                      ref.read(serverListProvider.notifier).setActiveLine(widget.serverId, index);
                    },
                    title: Text(line.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(line.url),
                        if (line.remark != null)
                          Text('备注：${line.remark}', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isActive)
                          Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () => _editLine(context, ref, widget.serverId, line),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, size: 20, color: Theme.of(context).colorScheme.error),
                          onPressed: () => _deleteLine(context, ref, widget.serverId, line),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: () => _addLine(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('添加线路'),
            ),
          ),
        ],
      ),
    );
  }
  
  void _addLine(BuildContext context, WidgetRef ref) {
    final serverId = widget.serverId;
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final remarkController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加线路'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '线路名称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: remarkController,
              decoration: const InputDecoration(labelText: '备注'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final servers = ref.read(serverListProvider);
              final server = servers.firstWhere((s) => s.id == serverId);
              final newLine = ServerLine(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: nameController.text,
                url: urlController.text,
                remark: remarkController.text.isEmpty ? null : remarkController.text,
              );
              ref.read(serverListProvider.notifier).updateServer(
                server.copyWith(lines: [...server.lines, newLine]),
              );
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
  
  void _editLine(BuildContext context, WidgetRef ref, String serverId, ServerLine line) {
    final nameController = TextEditingController(text: line.name);
    final urlController = TextEditingController(text: line.url);
    final remarkController = TextEditingController(text: line.remark ?? '');
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑线路'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '线路名称')),
            const SizedBox(height: 8),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: 'URL')),
            const SizedBox(height: 8),
            TextField(controller: remarkController, decoration: const InputDecoration(labelText: '备注')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final servers = ref.read(serverListProvider);
              final server = servers.firstWhere((s) => s.id == serverId);
              final updatedLines = server.lines.map((l) {
                if (l.id == line.id) {
                  return ServerLine(
                    id: l.id,
                    name: nameController.text,
                    url: urlController.text,
                    remark: remarkController.text.isEmpty ? null : remarkController.text,
                  );
                }
                return l;
              }).toList();
              ref.read(serverListProvider.notifier).updateServer(
                server.copyWith(lines: updatedLines),
              );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
  
  void _deleteLine(BuildContext context, WidgetRef ref, String serverId, ServerLine line) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除线路 "${line.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final servers = ref.read(serverListProvider);
              final server = servers.firstWhere((s) => s.id == serverId);
              ref.read(serverListProvider.notifier).updateServer(
                server.copyWith(lines: server.lines.where((l) => l.id != line.id).toList()),
              );
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
