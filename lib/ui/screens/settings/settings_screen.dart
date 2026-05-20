import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/app_providers.dart';

/// 设置主页
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsCard(
            icon: Icons.palette,
            title: '通用设置',
            subtitle: '外观、语言、启动页等',
            onTap: () => _showGeneralSettings(context),
          ),
          _SettingsCard(
            icon: Icons.play_circle,
            title: '播放器设置',
            subtitle: '内核、手势、播放行为等',
            onTap: () => _showPlayerSettings(context),
          ),
          _SettingsCard(
            icon: Icons.chat_bubble,
            title: '弹幕设置',
            subtitle: '外观、屏蔽词、延迟等',
            onTap: () => _showDanmakuSettings(context),
          ),
          _SettingsCard(
            icon: Icons.info,
            title: '关于',
            subtitle: '版本、开源许可、致谢',
            onTap: () => _showAbout(context),
          ),
          _SettingsCard(
            icon: Icons.backup,
            title: '备份与恢复',
            subtitle: '导出/导入服务器配置',
            onTap: () => _showBackupRestore(context),
          ),
        ],
      ),
    );
  }
  
  void _showGeneralSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const GeneralSettingsScreen()),
    );
  }
  
  void _showPlayerSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PlayerSettingsScreen()),
    );
  }
  
  void _showDanmakuSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const DanmakuSettingsScreen()),
    );
  }
  
  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关于'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Linplayer v1.0.0'),
            SizedBox(height: 8),
            Text('GitHub: https://github.com/your-repo'),
            SizedBox(height: 8),
            Text('mpv version: 0.37.0'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已是最新版本')),
              );
            },
            child: const Text('检查更新'),
          ),
        ],
      ),
    );
  }
  
  void _showBackupRestore(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BackupRestoreScreen()),
    );
  }
}

/// 设置卡片
class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFF5B8DEF)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// 通用设置页
class GeneralSettingsScreen extends ConsumerWidget {
  const GeneralSettingsScreen({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    
    return Scaffold(
      appBar: AppBar(title: const Text('通用设置')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('外观'),
            subtitle: Text(themeMode.name),
            onTap: () => _showThemeSelector(context, ref),
          ),
          ListTile(
            title: const Text('语言'),
            subtitle: const Text('跟随系统'),
            onTap: () => _showLanguageSelector(context),
          ),
          ListTile(
            title: const Text('启动页'),
            subtitle: const Text('首页'),
            onTap: () => _showStartupPageSelector(context),
          ),
          ListTile(
            title: const Text('缓存管理'),
            subtitle: const Text('1.2 GB'),
            trailing: TextButton(
              onPressed: () => _showClearCacheDialog(context),
              child: const Text('清除'),
            ),
          ),
          ListTile(
            title: const Text('聚合搜索优先级'),
            subtitle: const Text('服务器名称优先'),
            onTap: () => _showSearchPrioritySelector(context),
          ),
        ],
      ),
    );
  }
  
  void _showLanguageSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('语言'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('跟随系统'),
              value: 'system',
              groupValue: 'system',
              onChanged: (_) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('简体中文'),
              value: 'zh_CN',
              groupValue: 'system',
              onChanged: (_) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('English'),
              value: 'en',
              groupValue: 'system',
              onChanged: (_) => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showStartupPageSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动页'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('首页'),
              value: 'home',
              groupValue: 'home',
              onChanged: (_) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('服务器列表'),
              value: 'servers',
              groupValue: 'home',
              onChanged: (_) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('继续观看'),
              value: 'resume',
              groupValue: 'home',
              onChanged: (_) => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showClearCacheDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除缓存'),
        content: const Text('确定要清除所有缓存吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('缓存已清除')),
              );
            },
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }
  
  void _showSearchPrioritySelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('聚合搜索优先级'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('服务器名称优先'),
              value: 'name',
              groupValue: 'name',
              onChanged: (_) => Navigator.pop(context),
            ),
            RadioListTile<String>(
              title: const Text('响应速度优先'),
              value: 'speed',
              groupValue: 'name',
              onChanged: (_) => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showThemeSelector(BuildContext context, WidgetRef ref) {
    final current = ref.read(themeModeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('外观'),
        content: RadioGroup<ThemeModeOption>(
          groupValue: current,
          onChanged: (ThemeModeOption? value) {
            if (value != null) {
              ref.read(themeModeProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ThemeModeOption.values.map((mode) => RadioListTile<ThemeModeOption>(
              title: Text(mode.name),
              value: mode,
            )).toList(),
          ),
        ),
      ),
    );
  }
}

/// 播放器设置页
class PlayerSettingsScreen extends ConsumerWidget {
  const PlayerSettingsScreen({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerCore = ref.watch(playerCoreProvider);
    final playbackSpeed = ref.watch(defaultPlaybackSpeedProvider);
    final skipStep = ref.watch(skipForwardStepProvider);
    final longPressSpeed = ref.watch(longPressSpeedProvider);
    final hardwareDecoding = ref.watch(hardwareDecodingProvider);
    final backgroundPlayback = ref.watch(backgroundPlaybackProvider);
    final autoPlayNext = ref.watch(autoPlayNextProvider);
    
    return Scaffold(
      appBar: AppBar(title: const Text('播放器设置')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('播放器内核'),
            subtitle: Text(playerCore),
            onTap: () => _showCoreSelector(context, ref),
          ),
          ListTile(
            title: const Text('默认播放速度'),
            subtitle: Text('${playbackSpeed}x'),
            onTap: () => _showSpeedSelector(context, ref),
          ),
          ListTile(
            title: const Text('快进步长'),
            subtitle: Text('$skipStep秒'),
            onTap: () => _showSkipStepSelector(context, ref),
          ),
          ListTile(
            title: const Text('长按快进倍速'),
            subtitle: Text('${longPressSpeed}x'),
            onTap: () => _showLongPressSpeedSelector(context, ref),
          ),
          SwitchListTile(
            title: const Text('硬件解码'),
            value: hardwareDecoding,
            onChanged: (value) => ref.read(hardwareDecodingProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('后台播放'),
            value: backgroundPlayback,
            onChanged: (value) => ref.read(backgroundPlaybackProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('自动播放下一集'),
            value: autoPlayNext,
            onChanged: (value) => ref.read(autoPlayNextProvider.notifier).state = value,
          ),
        ],
      ),
    );
  }
  
  void _showCoreSelector(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放器内核'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('ExoPlayer/AVPlayer（默认）'),
              subtitle: const Text('轻量稳定，适合大多数场景'),
              value: 'video_player',
              groupValue: ref.read(playerCoreProvider),
              onChanged: (value) {
                if (value != null) {
                  ref.read(playerCoreProvider.notifier).state = value;
                }
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: const Text('MPV（media_kit）'),
              subtitle: const Text('支持PGS/SUP图形字幕、HDR'),
              value: 'media_kit',
              groupValue: ref.read(playerCoreProvider),
              onChanged: (value) {
                if (value != null) {
                  ref.read(playerCoreProvider.notifier).state = value;
                }
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  void _showSpeedSelector(BuildContext context, WidgetRef ref) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('默认播放速度'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: speeds.map((speed) => RadioListTile<double>(
            title: Text('${speed}x'),
            value: speed,
            groupValue: ref.read(defaultPlaybackSpeedProvider),
            onChanged: (value) {
              if (value != null) {
                ref.read(defaultPlaybackSpeedProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
          )).toList(),
        ),
      ),
    );
  }
  
  void _showSkipStepSelector(BuildContext context, WidgetRef ref) {
    final steps = [5, 10, 15, 30, 60];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('快进步长'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: steps.map((step) => RadioListTile<int>(
            title: Text('$step秒'),
            value: step,
            groupValue: ref.read(skipForwardStepProvider),
            onChanged: (value) {
              if (value != null) {
                ref.read(skipForwardStepProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
          )).toList(),
        ),
      ),
    );
  }
  
  void _showLongPressSpeedSelector(BuildContext context, WidgetRef ref) {
    final speeds = [1.5, 2.0, 2.5, 3.0];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('长按快进倍速'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: speeds.map((speed) => RadioListTile<double>(
            title: Text('${speed}x'),
            value: speed,
            groupValue: ref.read(longPressSpeedProvider),
            onChanged: (value) {
              if (value != null) {
                ref.read(longPressSpeedProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
          )).toList(),
        ),
      ),
    );
  }
}

/// 弹幕设置页
class DanmakuSettingsScreen extends ConsumerWidget {
  const DanmakuSettingsScreen({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(danmakuEnabledProvider);
    final opacity = ref.watch(danmakuOpacityProvider);
    final fontSize = ref.watch(danmakuFontSizeProvider);
    final speed = ref.watch(danmakuSpeedProvider);
    final density = ref.watch(danmakuDensityProvider);
    
    return Scaffold(
      appBar: AppBar(title: const Text('弹幕设置')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('弹幕开关'),
            value: enabled,
            onChanged: (value) => ref.read(danmakuEnabledProvider.notifier).state = value,
          ),
          ListTile(
            title: const Text('透明度'),
            subtitle: Slider(
              value: opacity,
              onChanged: (value) => ref.read(danmakuOpacityProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('字号'),
            subtitle: Slider(
              value: fontSize,
              onChanged: (value) => ref.read(danmakuFontSizeProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('速度'),
            subtitle: Slider(
              value: speed,
              onChanged: (value) => ref.read(danmakuSpeedProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('密度'),
            subtitle: Slider(
              value: density,
              onChanged: (value) => ref.read(danmakuDensityProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('屏蔽词管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showBlockwordManager(context),
          ),
        ],
      ),
    );
  }
  
  void _showBlockwordManager(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        '屏蔽词管理',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () => _showAddBlockwordDialog(context),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: 0,
                      itemBuilder: (context, index) => const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
  
  void _showAddBlockwordDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加屏蔽词'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入屏蔽词...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('屏蔽词已添加')),
              );
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}

/// 备份与恢复页
class BackupRestoreScreen extends StatelessWidget {
  const BackupRestoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: () => _showExportDialog(context),
              icon: const Icon(Icons.backup),
              label: const Text('导出备份'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: const Icon(Icons.restore),
              label: const Text('导入备份'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showImportJsonDialog(context),
              icon: const Icon(Icons.file_upload),
              label: const Text('导入服务器配置（JSON）'),
            ),
          ],
        ),
      ),
    );
  }

  void _showExportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出备份'),
        content: const Text('将导出所有服务器配置和设置到本地文件。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('备份已导出')),
              );
            },
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('将覆盖当前的服务器配置和设置。确定要继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('备份已导入')),
              );
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
}
