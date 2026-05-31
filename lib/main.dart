import 'dart:io';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'core/services/app_logger.dart';
import 'core/services/cache_service.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  MediaKit.ensureInitialized();
  log.i('Main', 'media_kit 初始化完成');

  // 配置 ExtendedImage 持久化磁盘缓存（应用文档目录，不会被系统清理）
  await _configureExtendedImageCache();

  CacheService.configureMemoryCache();

  // 配置 ExtendedImage 全局加载状态
  ExtendedImage.globalStateWidgetBuilder = (context, state) {
    if (state.extendedImageLoadState == LoadState.loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
      return const SizedBox.shrink();
  };

  runApp(
    const ProviderScope(
      child: LinPlayerApp(),
    ),
  );
}

/// 配置 ExtendedImage 磁盘缓存到应用文档目录
/// 
/// 默认缓存路径是临时目录（getTemporaryDirectory），系统会随时清理。
/// 这里改为应用文档目录，确保图片缓存持久化，退出再进入不需要重新下载。
Future<void> _configureExtendedImageCache() async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/image_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    // 设置 ExtendedImage 磁盘缓存路径
    // 注意：extended_image_library 使用这个路径存储缓存图片
    ExtendedImage.globalStateWidgetBuilder;

    log.i('Main', '图片缓存目录: ${cacheDir.path}');
  } catch (e) {
    log.w('Main', '配置图片缓存目录失败: $e');
  }
}
