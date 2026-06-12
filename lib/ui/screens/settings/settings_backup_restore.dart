part of 'settings_screen.dart';

class BackupRestoreScreen extends ConsumerWidget {
  const BackupRestoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final webdavConfig = ref.watch(webdavConfigProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16).copyWith(bottom: 120),
        children: [
          // 本地备份
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Text(
              '本地备份',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: () => _showExportDialog(context, ref),
            icon: const Icon(Icons.backup),
            label: const Text('导出备份'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showImportDialog(context, ref),
            icon: const Icon(Icons.restore),
            label: const Text('导入备份'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showImportJsonDialog(context),
            icon: const Icon(Icons.file_upload),
            label: const Text('导入服务器配置（JSON）'),
          ),

          // WebDAV配置
          const Divider(height: 32),
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Text(
              'WebDAV 同步',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          if (webdavConfig != null) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_done, color: Color(0xFF5B8DEF)),
                title: const Text('WebDAV 已配置'),
                subtitle: Text(webdavConfig.serverUrl),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () =>
                      _showWebDAVConfigDialog(context, ref, webdavConfig),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _showWebDAVBackupDialog(context, ref),
              icon: const Icon(Icons.cloud_upload),
              label: const Text('备份到 WebDAV'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showWebDAVRestoreDialog(context, ref),
              icon: const Icon(Icons.cloud_download),
              label: const Text('从 WebDAV 还原'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                ref.read(webdavConfigProvider.notifier).clearConfig();
              },
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              label: const Text('清除 WebDAV 配置',
                  style: TextStyle(color: Colors.red)),
            ),
          ] else ...[
            OutlinedButton.icon(
              onPressed: () => _showWebDAVConfigDialog(context, ref, null),
              icon: const Icon(Icons.cloud),
              label: const Text('配置 WebDAV'),
            ),
          ],
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出备份'),
        content: const Text('将导出所有服务器配置和设置到本地文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final path = await FilePicker.platform.saveFile(
                dialogTitle: '导出备份',
                fileName: 'linplayer-backup.json',
                type: FileType.custom,
                allowedExtensions: const ['json'],
              );
              if (path == null) return;
              try {
                final payload = jsonEncode(_buildBackupPayload(ref));
                await File(path).writeAsString(payload);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('备份已导出到: $path')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('导出失败: $e')),
                  );
                }
              }
            },
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('将覆盖当前的服务器配置和设置。确定要继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final result = await FilePicker.platform.pickFiles(
                dialogTitle: '导入备份',
                type: FileType.custom,
                allowedExtensions: const ['json'],
              );
              final path = result?.files.single.path;
              if (path == null) return;
              try {
                final content = await File(path).readAsString();
                final payload = jsonDecode(content) as Map<String, dynamic>;
                await _restoreBackupPayload(ref, payload);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('备份已导入')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('导入失败: $e')),
                  );
                }
              }
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showImportJsonDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入服务器配置'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '粘贴 JSON 配置...',
            border: OutlineInputBorder(),
          ),
          maxLines: 5,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('配置已导入')),
              );
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showWebDAVConfigDialog(
      BuildContext context, WidgetRef ref, WebdavConfig? existingConfig) {
    final serverController =
        TextEditingController(text: existingConfig?.serverUrl ?? '');
    final usernameController =
        TextEditingController(text: existingConfig?.username ?? '');
    final passwordController =
        TextEditingController(text: existingConfig?.password ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('WebDAV 配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: serverController,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://dav.example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(
                labelText: '账户',
                hintText: '用户名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: '密码',
                hintText: '密码',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              ref.read(webdavConfigProvider.notifier).setConfig(
                    serverController.text.trim(),
                    usernameController.text.trim(),
                    passwordController.text,
                  );
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('WebDAV 配置已保存')),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showWebDAVBackupDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('备份到 WebDAV'),
        content: const Text('将当前所有设置和服务器配置备份到 WebDAV 服务器。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);

              final config = ref.read(webdavConfigProvider);
              if (config == null) return;

              try {
                final service = WebDAVService(
                  serverUrl: config.serverUrl,
                  username: config.username,
                  password: config.password,
                );

                final backupData = jsonEncode(_buildBackupPayload(ref));

                await service.backupApp(backupData);

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已成功备份到 WebDAV')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('备份失败: $e')),
                  );
                }
              }
            },
            child: const Text('备份'),
          ),
        ],
      ),
    );
  }

  void _showWebDAVRestoreDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从 WebDAV 还原'),
        content: const Text('将从 WebDAV 服务器下载备份并覆盖当前设置。确定要继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);

              final config = ref.read(webdavConfigProvider);
              if (config == null) return;

              try {
                final service = WebDAVService(
                  serverUrl: config.serverUrl,
                  username: config.username,
                  password: config.password,
                );

                final backupData = await service.restoreApp();
                final payload = jsonDecode(backupData) as Map<String, dynamic>;
                await _restoreBackupPayload(ref, payload);

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已成功从 WebDAV 还原设置')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('还原失败: $e')),
                  );
                }
              }
            },
            child: const Text('还原'),
          ),
        ],
      ),
    );
  }
}

/// 扩展线路同步设置页面
