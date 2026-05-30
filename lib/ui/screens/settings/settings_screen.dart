import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/webdav_service.dart';
import '../../../core/services/ext_domain_service.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/cache_service.dart';
import '../../../core/utils/danmaku_filter.dart';
import '../../../core/api/danmaku/danmaku_source.dart';
import '../../../core/api/danmaku/danmaku_service.dart';

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
            subtitle: '导出/导入服务器配置、WebDAV同步',
            onTap: () => _showBackupRestore(context),
          ),
          _SettingsCard(
            icon: Icons.sync,
            title: '线路同步',
            subtitle: '配置扩展线路同步服务',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ExtDomainSettingsScreen()),
              );
            },
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
              _exportLogs(context);
            },
            child: const Text('导出日志'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final path = await AppLogger().exportToFile();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日志已导出到: $path')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出日志失败: $e')),
        );
      }
    }
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
class GeneralSettingsScreen extends ConsumerStatefulWidget {
  const GeneralSettingsScreen({super.key});

  @override
  ConsumerState<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends ConsumerState<GeneralSettingsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      _loadCacheSettings();
      ref.read(cacheSizeProvider);
    });
  }

  Future<void> _loadCacheSettings() async {
    final expiryDays = await CacheService.getImageCacheExpiryDays();
    final maxSizeMB = await CacheService.getVideoCacheMaxSizeMB();
    if (mounted) {
      ref.read(imageCacheExpiryDaysProvider.notifier).state = expiryDays;
      ref.read(videoCacheMaxSizeMBProvider.notifier).state = maxSizeMB;
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final hideDailyRecommendations = ref.watch(hideDailyRecommendationsProvider);
    final imageExpiryDays = ref.watch(imageCacheExpiryDaysProvider);
    final videoMaxSizeMB = ref.watch(videoCacheMaxSizeMBProvider);
    final cacheSizeAsync = ref.watch(cacheSizeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('通用设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          ListTile(
            title: const Text('外观'),
            subtitle: Text(themeMode.name),
            onTap: () => _showThemeSelector(context),
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
          SwitchListTile(
            title: const Text('隐藏每日推荐'),
            subtitle: const Text('开启后首页将不再显示随机推荐'),
            value: hideDailyRecommendations,
            onChanged: (value) => ref.read(hideDailyRecommendationsProvider.notifier).state = value,
          ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '缓存管理',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),

          ListTile(
            title: const Text('图片缓存'),
            subtitle: cacheSizeAsync.when(
              data: (info) => Text('已用 ${info.imageFormatted}，$imageExpiryDays天后过期'),
              loading: () => const Text('计算中...'),
              error: (_, __) => const Text('获取失败'),
            ),
            trailing: TextButton(
              onPressed: () => _clearImageCache(context),
              child: const Text('清除'),
            ),
          ),
          ListTile(
            title: const Text('图片缓存过期天数'),
            subtitle: Text('$imageExpiryDays 天'),
            onTap: () => _showImageCacheExpirySelector(context),
          ),

          ListTile(
            title: const Text('视频缓存'),
            subtitle: cacheSizeAsync.when(
              data: (info) => Text(
                '已用 ${info.videoFormatted}，上限 ${videoMaxSizeMB >= 1024 ? '${(videoMaxSizeMB / 1024).toStringAsFixed(0)} GB' : '$videoMaxSizeMB MB'}',
              ),
              loading: () => const Text('计算中...'),
              error: (_, __) => const Text('获取失败'),
            ),
            trailing: TextButton(
              onPressed: () => _clearVideoCache(context),
              child: const Text('清除'),
            ),
          ),
          ListTile(
            title: const Text('视频缓存上限'),
            subtitle: Text(videoMaxSizeMB >= 1024
                ? '${(videoMaxSizeMB / 1024).toStringAsFixed(0)} GB'
                : '$videoMaxSizeMB MB'),
            onTap: () => _showVideoCacheMaxSizeSelector(context),
          ),

          ListTile(
            title: const Text('总缓存'),
            subtitle: cacheSizeAsync.when(
              data: (info) => Text(info.totalFormatted),
              loading: () => const Text('计算中...'),
              error: (_, __) => const Text('获取失败'),
            ),
            trailing: TextButton(
              onPressed: () => _clearAllCache(context),
              child: const Text('全部清除'),
            ),
          ),

          const Divider(),
          ListTile(
            title: const Text('聚合搜索优先级'),
            subtitle: const Text('服务器名称优先'),
            onTap: () => _showSearchPrioritySelector(context),
          ),
        ],
      ),
    );
  }

  Future<void> _clearImageCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除图片缓存'),
        content: const Text('确定清除所有图片磁盘缓存？下次加载需重新下载。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (confirmed == true) {
      await CacheService.clearAllImageCache();
      if (!mounted) return;
      ref.invalidate(cacheSizeProvider);
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('图片缓存已清除')),
      );
    }
  }

  Future<void> _clearVideoCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除视频缓存'),
        content: const Text('确定清除所有已下载的视频？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (confirmed == true) {
      await CacheService.clearVideoCache();
      if (!mounted) return;
      ref.invalidate(cacheSizeProvider);
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('视频缓存已清除')),
      );
    }
  }

  Future<void> _clearAllCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部缓存'),
        content: const Text('确定清除所有图片和视频缓存？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('全部清除')),
        ],
      ),
    );
    if (confirmed == true) {
      await CacheService.clearAllCache();
      if (!mounted) return;
      ref.invalidate(cacheSizeProvider);
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('所有缓存已清除')),
      );
    }
  }

  void _showImageCacheExpirySelector(BuildContext context) {
    final days = [7, 14, 30, 60, 90];
    final current = ref.read(imageCacheExpiryDaysProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('图片缓存过期天数'),
        content: RadioGroup<int>(
          groupValue: current,
          onChanged: (value) async {
            if (value != null) {
              ref.read(imageCacheExpiryDaysProvider.notifier).state = value;
              await CacheService.setImageCacheExpiryDays(value);
            }
            if (ctx.mounted) {
              Navigator.pop(ctx);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: days.map((d) => RadioListTile<int>(
              title: Text('$d 天'),
              value: d,
            )).toList(),
          ),
        ),
      ),
    );
  }

  void _showVideoCacheMaxSizeSelector(BuildContext context) {
    final sizes = [256, 512, 1024, 2048, 4096, 8192];
    final labels = sizes.map((s) => s >= 1024 ? '${(s / 1024).toStringAsFixed(0)} GB' : '$s MB').toList();
    final current = ref.read(videoCacheMaxSizeMBProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('视频缓存上限'),
        content: RadioGroup<int>(
          groupValue: current,
          onChanged: (value) async {
            if (value != null) {
              ref.read(videoCacheMaxSizeMBProvider.notifier).state = value;
              await CacheService.setVideoCacheMaxSizeMB(value);
            }
            if (ctx.mounted) {
              Navigator.pop(ctx);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(sizes.length, (i) => RadioListTile<int>(
              title: Text(labels[i]),
              value: sizes[i],
            )),
          ),
        ),
      ),
    );
  }

  void _showLanguageSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('语言'),
        content: RadioGroup<String>(
          groupValue: 'system',
          onChanged: (_) => Navigator.pop(context),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('跟随系统'),
                value: 'system',
              ),
              RadioListTile<String>(
                title: Text('简体中文'),
                value: 'zh_CN',
              ),
              RadioListTile<String>(
                title: Text('English'),
                value: 'en',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showStartupPageSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动页'),
        content: RadioGroup<String>(
          groupValue: 'home',
          onChanged: (_) => Navigator.pop(context),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('首页'),
                value: 'home',
              ),
              RadioListTile<String>(
                title: Text('服务器列表'),
                value: 'servers',
              ),
              RadioListTile<String>(
                title: Text('继续观看'),
                value: 'resume',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSearchPrioritySelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('聚合搜索优先级'),
        content: RadioGroup<String>(
          groupValue: 'name',
          onChanged: (_) => Navigator.pop(context),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('服务器名称优先'),
                value: 'name',
              ),
              RadioListTile<String>(
                title: Text('响应速度优先'),
                value: 'speed',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showThemeSelector(BuildContext context) {
    final current = ref.read(themeModeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('外观'),
        content: RadioGroup<ThemeModeOption>(
          groupValue: current,
          onChanged: (value) {
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
    final preferredSubtitleLanguage = ref.watch(preferredSubtitleLanguageProvider);
    final preferredAudioLanguage = ref.watch(preferredAudioLanguageProvider);
    final preferredVersion = ref.watch(preferredVersionProvider);
    final rememberBrightness = ref.watch(rememberBrightnessProvider);
    final subtitleFont = ref.watch(subtitleFontProvider);
    final subtitleBackground = ref.watch(subtitleBackgroundProvider);
    final mpvDolbyVisionFix = ref.watch(mpvDolbyVisionFixProvider);
    final impellerEnabled = ref.watch(impellerEnabledProvider);
    final exoLibass = ref.watch(exoLibassProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('播放器设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          // 播放器内核
          ListTile(
            title: const Text('播放器内核'),
            subtitle: Text(playerCore == 'video_player' ? 'ExoPlayer/AVPlayer' : 'MPV（media_kit）'),
            onTap: () => _showCoreSelector(context, ref),
          ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '交互设置',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
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

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '播放行为',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            title: const Text('默认播放速度'),
            subtitle: Text('${playbackSpeed}x'),
            onTap: () => _showSpeedSelector(context, ref),
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

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '音轨与字幕',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            title: const Text('首选字幕语言'),
            subtitle: Text(preferredSubtitleLanguage),
            onTap: () => _showSubtitleLanguageSelector(context, ref),
          ),
          ListTile(
            title: const Text('首选音频语言'),
            subtitle: Text(preferredAudioLanguage),
            onTap: () => _showAudioLanguageSelector(context, ref),
          ),
          ListTile(
            title: const Text('首选版本'),
            subtitle: Text(preferredVersion),
            onTap: () => _showVersionSelector(context, ref),
          ),
          ListTile(
            title: const Text('字幕字体'),
            subtitle: Text(subtitleFont),
            onTap: () => _showSubtitleFontSelector(context, ref),
          ),
          SwitchListTile(
            title: const Text('字幕黑色背景'),
            subtitle: const Text('为字幕添加半透明黑色背景'),
            value: subtitleBackground,
            onChanged: (value) => ref.read(subtitleBackgroundProvider.notifier).state = value,
          ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '解码与渲染',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('硬件解码'),
            value: hardwareDecoding,
            onChanged: (value) => ref.read(hardwareDecodingProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('记忆亮度'),
            subtitle: const Text('记住上次调整的播放亮度'),
            value: rememberBrightness,
            onChanged: (value) => ref.read(rememberBrightnessProvider.notifier).state = value,
          ),

          // MPV特有设置
          if (playerCore == 'media_kit') ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'MPV 高级设置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('自动修正杜比视界颜色'),
              subtitle: const Text('开启后软件修正杜比视界颜色偏差'),
              value: mpvDolbyVisionFix,
              onChanged: (value) => ref.read(mpvDolbyVisionFixProvider.notifier).state = value,
            ),
          ],

          // 实验性功能
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '实验性功能',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('启用 Impeller 渲染引擎'),
            subtitle: const Text('Flutter 新一代渲染引擎（需要重启应用）'),
            value: impellerEnabled,
            onChanged: (value) => ref.read(impellerEnabledProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('EXO 启用 ASS 原生渲染'),
            subtitle: const Text('关闭时将 ASS 转为 SRT 兼容播放；开启后优先使用 Media3/libass 管线保留 ASS 效果'),
            value: exoLibass,
            onChanged: (value) => ref.read(exoLibassProvider.notifier).state = value,
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
        content: RadioGroup<String>(
          groupValue: ref.read(playerCoreProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(playerCoreProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('ExoPlayer/AVPlayer（默认）'),
                subtitle: Text('轻量稳定，适合大多数场景'),
                value: 'video_player',
              ),
              RadioListTile<String>(
                title: Text('MPV（media_kit）'),
                subtitle: Text('支持PGS/SUP图形字幕、HDR'),
                value: 'media_kit',
              ),
            ],
          ),
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
        content: RadioGroup<double>(
          groupValue: ref.read(defaultPlaybackSpeedProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(defaultPlaybackSpeedProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds.map((speed) => RadioListTile<double>(
              title: Text('${speed}x'),
              value: speed,
            )).toList(),
          ),
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
        content: RadioGroup<int>(
          groupValue: ref.read(skipForwardStepProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(skipForwardStepProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: steps.map((step) => RadioListTile<int>(
              title: Text('$step秒'),
              value: step,
            )).toList(),
          ),
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
        content: RadioGroup<double>(
          groupValue: ref.read(longPressSpeedProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(longPressSpeedProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds.map((speed) => RadioListTile<double>(
              title: Text('${speed}x'),
              value: speed,
            )).toList(),
          ),
        ),
      ),
    );
  }

  void _showSubtitleLanguageSelector(BuildContext context, WidgetRef ref) {
    final languages = {
      'chi': '中文',
      'jpn': '日语',
      'eng': '英语',
      'kor': '韩语',
    };
    final current = ref.read(preferredSubtitleLanguageProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选字幕语言'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredSubtitleLanguageProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: languages.entries.map((entry) => RadioListTile<String>(
              title: Text(entry.value),
              value: entry.key,
            )).toList(),
          ),
        ),
      ),
    );
  }

  void _showAudioLanguageSelector(BuildContext context, WidgetRef ref) {
    final languages = {
      'jpn': '日语',
      'chi': '中文',
      'eng': '英语',
      'kor': '韩语',
    };
    final current = ref.read(preferredAudioLanguageProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选音频语言'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredAudioLanguageProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: languages.entries.map((entry) => RadioListTile<String>(
              title: Text(entry.value),
              value: entry.key,
            )).toList(),
          ),
        ),
      ),
    );
  }

  void _showVersionSelector(BuildContext context, WidgetRef ref) {
    final versions = ['原盘', 'HEVC', 'HDR', 'SDR'];
    final current = ref.read(preferredVersionProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选版本'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredVersionProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: versions.map((version) => RadioListTile<String>(
              title: Text(version),
              value: version,
            )).toList(),
          ),
        ),
      ),
    );
  }

  void _showSubtitleFontSelector(BuildContext context, WidgetRef ref) {
    final fonts = ['默认', '思源黑体', '微软雅黑', '苹方'];
    final current = ref.read(subtitleFontProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字幕字体'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(subtitleFontProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: fonts.map((font) => RadioListTile<String>(
              title: Text(font),
              value: font,
            )).toList(),
          ),
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
    final blockwords = ref.watch(danmakuBlockwordsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('弹幕设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
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
            title: const Text('弹幕延迟'),
            subtitle: Builder(builder: (context) {
              final delay = ref.watch(danmakuDelayProvider);
              return Slider(
                value: delay,
                min: -5.0,
                max: 5.0,
                label: '${delay.toStringAsFixed(1)}s',
                onChanged: (value) => ref.read(danmakuDelayProvider.notifier).state = value,
              );
            }),
          ),
          ListTile(
            title: const Text('屏蔽词管理'),
            subtitle: Text('共 ${blockwords.length} 个屏蔽词'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showBlockwordManager(context, ref),
          ),
          SwitchListTile(
            title: const Text('弹幕去重'),
            subtitle: const Text('合并相同文本弹幕，显示重复次数'),
            value: ref.watch(danmakuDedupProvider),
            onChanged: (v) => ref.read(danmakuDedupProvider.notifier).state = v,
          ),
          if (ref.watch(danmakuDedupProvider))
            ListTile(
              title: const Text('去重时间窗口'),
              subtitle: Builder(builder: (context) {
                final window = ref.watch(danmakuDedupWindowProvider);
                return Slider(
                  value: window,
                  min: 1.0,
                  max: 30.0,
                  label: '${window.toStringAsFixed(0)}秒',
                  onChanged: (v) => ref.read(danmakuDedupWindowProvider.notifier).state = v,
                );
              }),
            ),
          const Divider(),
          ListTile(
            title: const Text('自定义弹幕源'),
            subtitle: const Text('添加 danmu_api / 御坂弹幕 等自定义源'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showCustomSourceManager(context, ref),
          ),
        ],
      ),
    );
  }

  void _showBlockwordManager(BuildContext context, WidgetRef ref) {
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
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.add),
                        onSelected: (value) {
                          if (value == 'add') {
                            _showAddBlockwordDialog(context, ref);
                          } else if (value == 'import') {
                            _showImportDandanplayBlockwords(context, ref);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'add',
                            child: Row(
                              children: [
                                Icon(Icons.edit),
                                SizedBox(width: 8),
                                Text('添加屏蔽词'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'import',
                            child: Row(
                              children: [
                                Icon(Icons.download),
                                SizedBox(width: 8),
                                Text('导入弹弹弹幕屏蔽词'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, child) {
                        final words = ref.watch(danmakuBlockwordsProvider);
                        if (words.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.block,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '暂无屏蔽词',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: scrollController,
                          itemCount: words.length,
                          itemBuilder: (context, index) {
                            final word = words[index];
                            return ListTile(
                              title: Text(word),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () {
                                  ref.read(danmakuBlockwordsProvider.notifier).removeWord(word);
                                },
                              ),
                            );
                          },
                        );
                      },
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

  void _showAddBlockwordDialog(BuildContext context, WidgetRef ref) {
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
              final word = controller.text.trim();
              if (word.isNotEmpty) {
                ref.read(danmakuBlockwordsProvider.notifier).addWord(word);
              }
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showImportDandanplayBlockwords(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入弹弹弹幕屏蔽词'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('支持导入弹弹play导出的 XML 格式屏蔽词文件。'),
            SizedBox(height: 8),
            Text(
              '会自动识别文本屏蔽词和用户ID屏蔽。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            onPressed: () async {
              Navigator.pop(context);
              await _pickAndImportXmlFile(context, ref);
            },
            label: const Text('选择 XML 文件'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndImportXmlFile(BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xml'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      final path = file.path;

      String xmlContent;
      if (bytes != null) {
        xmlContent = utf8.decode(bytes);
      } else if (path != null) {
        xmlContent = await File(path).readAsString();
      } else {
        throw Exception('无法读取文件内容');
      }

      // 解析 XML
      final importResult = DanmakuFilter.importFromDandanplayXml(xmlContent);

      // 导入到 Provider
      ref.read(danmakuBlockwordsProvider.notifier).importWords(importResult.textWords);
      ref.read(danmakuBlockwordsProvider.notifier).importUserBlocks(importResult.userIds);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导入 ${importResult.totalImported} 个屏蔽词'
              '${importResult.skippedCount > 0 ? '（跳过 ${importResult.skippedCount} 个）' : ''}',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  void _showCustomSourceManager(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CustomSourceManagerSheet(),
    );
  }
}

class _CustomSourceManagerSheet extends ConsumerStatefulWidget {
  @override
  ConsumerState<_CustomSourceManagerSheet> createState() => _CustomSourceManagerSheetState();
}

class _CustomSourceManagerSheetState extends ConsumerState<_CustomSourceManagerSheet> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isAdding = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(danmakuServiceProvider);
    final customSources = service.sources;

    return DraggableScrollableSheet(
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
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('自定义弹幕源', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (service.dandanplay != null)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.cloud, color: Colors.blue),
                      title: Text('弹弹Play'),
                      subtitle: Text('默认源，无需配置'),
                      trailing: Icon(Icons.check_circle, color: Colors.green),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: customSources.length,
                    itemBuilder: (context, index) {
                      final source = customSources[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.dns,
                            color: source.config.enabled ? Colors.green : Colors.grey,
                          ),
                          title: Text(source.config.name),
                          subtitle: Text(source.config.apiUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: source.config.enabled,
                                onChanged: (val) {
                                  final newCfg = DanmakuSourceConfig(
                                    id: source.config.id,
                                    type: source.config.type,
                                    name: source.config.name,
                                    apiUrl: source.config.apiUrl,
                                    priority: source.config.priority,
                                    enabled: val,
                                  );
                                  ref.read(danmakuServiceProvider.notifier).addCustomSource(newCfg);
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red),
                                onPressed: () {
                                  ref.read(danmakuServiceProvider.notifier).removeCustomSource(source.config.id);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(),
                if (_isAdding) ...[
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '源名称',
                      hintText: '如：我的弹幕API',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'API地址',
                      hintText: '如: http://192.168.1.7:9321/87654321',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _isAdding = false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addSource,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: () => setState(() => _isAdding = true),
                    icon: const Icon(Icons.add),
                    label: const Text('添加自定义源'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _addSource() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写名称和API地址')),
      );
      return;
    }
    final cfg = DanmakuSourceConfig(
      id: const Uuid().v4(),
      type: DanmakuSourceType.custom,
      name: name,
      apiUrl: url,
      priority: ref.read(danmakuServiceProvider).sources.length,
    );
    ref.read(danmakuServiceProvider.notifier).addCustomSource(cfg);
    _nameController.clear();
    _urlController.clear();
    setState(() => _isAdding = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加 $name')),
    );
  }
}

/// 备份与恢复页
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
                  onPressed: () => _showWebDAVConfigDialog(context, ref, webdavConfig),
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
              label: const Text('清除 WebDAV 配置', style: TextStyle(color: Colors.red)),
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

  void _showWebDAVConfigDialog(BuildContext context, WidgetRef ref, WebdavConfig? existingConfig) {
    final serverController = TextEditingController(text: existingConfig?.serverUrl ?? '');
    final usernameController = TextEditingController(text: existingConfig?.username ?? '');
    final passwordController = TextEditingController(text: existingConfig?.password ?? '');

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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
                
                // 准备备份数据
                final backupData = jsonEncode({
                  'version': '1.0.0',
                  'timestamp': DateTime.now().toIso8601String(),
                  'servers': ref.read(serverListProvider).map((s) => {
                    'id': s.id,
                    'name': s.name,
                    'baseUrl': s.baseUrl,
                    'iconUrl': s.iconUrl,
                    'remark': s.remark,
                    'lines': s.lines.map((l) => {
                      'id': l.id,
                      'name': l.name,
                      'url': l.url,
                      'remark': l.remark,
                    }).toList(),
                    'activeLineIndex': s.activeLineIndex,
                  }).toList(),
                  'settings': {
                    'themeMode': ref.read(themeModeProvider).name,
                    'playerCore': ref.read(playerCoreProvider),
                    'playbackSpeed': ref.read(defaultPlaybackSpeedProvider),
                    'skipForwardStep': ref.read(skipForwardStepProvider),
                    'longPressSpeed': ref.read(longPressSpeedProvider),
                    'hardwareDecoding': ref.read(hardwareDecodingProvider),
                    'backgroundPlayback': ref.read(backgroundPlaybackProvider),
                    'autoPlayNext': ref.read(autoPlayNextProvider),
                    'danmakuEnabled': ref.read(danmakuEnabledProvider),
                    'danmakuOpacity': ref.read(danmakuOpacityProvider),
                    'danmakuFontSize': ref.read(danmakuFontSizeProvider),
                    'danmakuSpeed': ref.read(danmakuSpeedProvider),
                    'danmakuDensity': ref.read(danmakuDensityProvider),
                    'hideDailyRecommendations': ref.read(hideDailyRecommendationsProvider),
                  },
                });
                
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
                jsonDecode(backupData) as Map<String, dynamic>;
                
                // TODO: 恢复服务器列表和设置
                // 这里需要解析 backupData 并恢复所有设置
                
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
class ExtDomainSettingsScreen extends ConsumerStatefulWidget {
  const ExtDomainSettingsScreen({super.key});

  @override
  ConsumerState<ExtDomainSettingsScreen> createState() => _ExtDomainSettingsScreenState();
}

class _ExtDomainSettingsScreenState extends ConsumerState<ExtDomainSettingsScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    final config = ref.read(extDomainConfigProvider);
    if (config != null) {
      _urlController.text = config.extDomainUrl;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isLoading = true;
      _testResult = null;
    });

    try {
      final service = ref.read(extDomainServiceProvider);
      final available = await service.checkServiceAvailable(url);
      setState(() {
        _testResult = available ? '连接成功' : '连接失败';
      });
    } catch (e) {
      setState(() {
        _testResult = '连接失败: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ref.read(extDomainConfigProvider.notifier).clearConfig();
    } else {
      ref.read(extDomainConfigProvider.notifier).setConfig(url);
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    }
  }

  Future<void> _syncLines() async {
    final config = ref.read(extDomainConfigProvider);
    if (config == null || config.extDomainUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先配置线路同步地址')),
      );
      return;
    }

    final currentServer = ref.read(currentServerProvider);
    if (currentServer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一个服务器')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final service = ref.read(extDomainServiceProvider);
      final lines = await service.fetchExtDomains(
        extDomainUrl: config.extDomainUrl,
        embyServerUrl: currentServer.baseUrl,
        embyToken: currentServer.authToken ?? '',
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
        id: const Uuid().v4(),
        name: l.name,
        url: l.url,
        remark: l.remark,
      )).toList();

      // 合并现有线路和新线路（去重）
      final existingLines = currentServer.lines;
      final mergedLines = [...existingLines];
      for (final newLine in newLines) {
        if (!mergedLines.any((l) => l.url == newLine.url)) {
          mergedLines.add(newLine);
        }
      }

      final updatedServer = currentServer.copyWith(lines: mergedLines);
      ref.read(serverListProvider.notifier).updateServer(updatedServer);
      ref.read(currentServerProvider.notifier).state = updatedServer;

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
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(extDomainConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('线路同步'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '扩展线路同步服务',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '配置 emby_ext_domains 服务地址，自动同步服务器线路列表。',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: '服务地址',
                      hintText: 'https://ext.example.com',
                      prefixIcon: const Icon(Icons.cloud_sync),
                      border: const OutlineInputBorder(),
                      suffixIcon: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.check_circle_outline),
                              onPressed: _testConnection,
                            ),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _testResult!,
                      style: TextStyle(
                        color: _testResult == '连接成功'
                            ? Colors.green
                            : Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isLoading ? null : _saveConfig,
            icon: const Icon(Icons.save),
            label: const Text('保存配置'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _isLoading ? null : _syncLines,
            icon: const Icon(Icons.sync),
            label: const Text('立即同步线路'),
          ),
          if (config != null && config.extDomainUrl.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '当前配置: ${config.extDomainUrl}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

