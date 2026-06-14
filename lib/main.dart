import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/providers/app_providers.dart';
import 'core/services/cache_service.dart';
import 'core/theme/app_motion.dart';
import 'core/utils/platform_utils.dart';
import 'desktop/desktop_app.dart';
import 'desktop/window/desktop_window_chrome.dart';
import 'tv/tv_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 统一三端动效基线（时长/曲线），见 core/theme/app_motion.dart
  AppMotion.applyGlobalDefaults();

  // media_kit 仅在非 Android 平台初始化
  // Android 使用原生 MPV (libplayer.so) 通过平台通道调用
  if (!Platform.isAndroid) {
    MediaKit.ensureInitialized();
  }

  await initializeAppPreferences();

  // 桌面端：初始化无边框窗口 + 自绘标题栏
  if (isDesktopPlatform && !isTvPlatform) {
    await initDesktopWindow();
  }

  // 缓存策略（全平台，对内存小的机器友好）：
  // - 内存只保留少量解码位图（~100MB/1000，LRU 回收），不常驻海量图。
  // - 磁盘持久化由 PersistentNetworkImageProvider 负责（图片 6GB 上限 + 14 天过期）。
  // - 视频播放缓存走 mpv 磁盘缓存（见 mpv 适配器），不占内存。
  CacheService.configureMemoryCache();
  // 启动清理放后台，不阻塞启动。
  unawaited(CacheService.runStartupCleanup());

  if (isTvPlatform) {
    // TV 端入口
    runApp(
      const ProviderScope(
        child: LinPlayerTvApp(),
      ),
    );
  } else if (isDesktopPlatform) {
    runApp(
      const ProviderScope(
        child: LinPlayerDesktopApp(),
      ),
    );
  } else {
    runApp(
      const ProviderScope(
        child: LinPlayerApp(),
      ),
    );
  }
}
