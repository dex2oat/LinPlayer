part of 'settings_screen.dart';

class PlayerSettingsScreen extends ConsumerWidget {
  const PlayerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerCore = normalizePlayerCore(ref.watch(playerCoreProvider));
    final playbackSpeed = ref.watch(defaultPlaybackSpeedProvider);
    final skipStep = ref.watch(skipForwardStepProvider);
    final longPressSpeed = ref.watch(longPressSpeedProvider);
    final hardwareDecoding = ref.watch(hardwareDecodingProvider);
    final backgroundPlayback = ref.watch(backgroundPlaybackProvider);
    final autoPlayNext = ref.watch(autoPlayNextProvider);
    final preferredSubtitleLanguage =
        ref.watch(preferredSubtitleLanguageProvider);
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
          ListTile(
            title: const Text('播放器内核'),
            subtitle: Text(
                playerCore == 'mpv' ? 'MPV (libmpv)' : 'ExoPlayer/AVPlayer'),
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
            onChanged: (value) =>
                ref.read(backgroundPlaybackProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('自动播放下一集'),
            value: autoPlayNext,
            onChanged: (value) =>
                ref.read(autoPlayNextProvider.notifier).state = value,
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
            onChanged: (value) =>
                ref.read(subtitleBackgroundProvider.notifier).state = value,
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
            onChanged: (value) =>
                ref.read(hardwareDecodingProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('记忆亮度'),
            subtitle: const Text('记住上次调整的播放亮度'),
            value: rememberBrightness,
            onChanged: (value) =>
                ref.read(rememberBrightnessProvider.notifier).state = value,
          ),

          // MPV特有设置
          if (playerCore == 'mpv') ...[
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
              onChanged: (value) =>
                  ref.read(mpvDolbyVisionFixProvider.notifier).state = value,
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
            onChanged: (value) =>
                ref.read(impellerEnabledProvider.notifier).state = value,
          ),
          if (!isDesktopPlatform && playerCore == 'exoPlayer')
            SwitchListTile(
              title: const Text('EXO 启用 ASS 原生渲染'),
              subtitle: const Text(
                  '关闭时将 ASS 转为 SRT 兼容播放；开启后优先使用 Media3/libass 管线保留 ASS 效果'),
              value: exoLibass,
              onChanged: (value) =>
                  ref.read(exoLibassProvider.notifier).state = value,
            ),
        ],
      ),
    );
  }

  void _showCoreSelector(BuildContext context, WidgetRef ref) {
    final children = <Widget>[
      const RadioListTile<String>(
        title: Text('ExoPlayer/AVPlayer'),
        subtitle: Text('轻量稳定，适合大多数场景'),
        value: 'exoPlayer',
      ),
      const RadioListTile<String>(
        title: Text('MPV'),
        subtitle: Text('libmpv，支持 HDR/着色器/PGS/SUP'),
        value: 'mpv',
      ),
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放器内核'),
        content: RadioGroup<String>(
          groupValue: normalizePlayerCore(ref.read(playerCoreProvider)),
          onChanged: (value) {
            if (value != null) {
              ref.read(playerCoreProvider.notifier).state =
                  normalizePlayerCore(value);
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
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
            children: speeds
                .map((speed) => RadioListTile<double>(
                      title: Text('${speed}x'),
                      value: speed,
                    ))
                .toList(),
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
            children: steps
                .map((step) => RadioListTile<int>(
                      title: Text('$step秒'),
                      value: step,
                    ))
                .toList(),
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
            children: speeds
                .map((speed) => RadioListTile<double>(
                      title: Text('${speed}x'),
                      value: speed,
                    ))
                .toList(),
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
              ref.read(preferredSubtitleLanguageProvider.notifier).state =
                  value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: languages.entries
                .map((entry) => RadioListTile<String>(
                      title: Text(entry.value),
                      value: entry.key,
                    ))
                .toList(),
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
            children: languages.entries
                .map((entry) => RadioListTile<String>(
                      title: Text(entry.value),
                      value: entry.key,
                    ))
                .toList(),
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
            children: versions
                .map((version) => RadioListTile<String>(
                      title: Text(version),
                      value: version,
                    ))
                .toList(),
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
            children: fonts
                .map((font) => RadioListTile<String>(
                      title: Text(font),
                      value: font,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}

/// 弹幕设置页
