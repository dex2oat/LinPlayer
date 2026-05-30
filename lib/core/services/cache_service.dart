import 'dart:io';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

class CacheService {
  static const _imageCacheExpiryDaysKey = 'linplayer_image_cache_expiry_days';
  static const _videoCacheMaxSizeMBKey = 'linplayer_video_cache_max_size_mb';

  static Future<String> get _imageCacheDirPath async {
    final tempDir = await getTemporaryDirectory();
    return path.join(tempDir.path, 'libCachedImageData');
  }

  static Future<String> get _videoCacheDirPath async {
    final appDir = await getApplicationDocumentsDirectory();
    return path.join(appDir.path, 'downloads');
  }

  static Future<int> getImageCacheExpiryDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_imageCacheExpiryDaysKey) ?? 14;
  }

  static Future<void> setImageCacheExpiryDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_imageCacheExpiryDaysKey, days);
  }

  static Future<int> getVideoCacheMaxSizeMB() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_videoCacheMaxSizeMBKey) ?? 1024;
  }

  static Future<void> setVideoCacheMaxSizeMB(int mb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_videoCacheMaxSizeMBKey, mb);
  }

  static Future<int> getImageCacheSize() async {
    return _calculateDirectorySize(await _imageCacheDirPath);
  }

  static Future<int> getVideoCacheSize() async {
    return _calculateDirectorySize(await _videoCacheDirPath);
  }

  static Future<int> getTotalCacheSize() async {
    return await getImageCacheSize() + await getVideoCacheSize();
  }

  static Future<int> _calculateDirectorySize(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;

    int totalSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          totalSize += await entity.length();
        } catch (_) {}
      }
    }
    return totalSize;
  }

  static Future<void> clearExpiredImageCache() async {
    final days = await getImageCacheExpiryDays();
    final dirPath = await _imageCacheDirPath;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    final cutoff = DateTime.now().subtract(Duration(days: days));
    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          final lastMod = await entity.lastModified();
          if (lastMod.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
    }
  }

  static Future<void> clearAllImageCache() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    final dirPath = await _imageCacheDirPath;
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  static Future<void> clearVideoCache() async {
    final dirPath = await _videoCacheDirPath;
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }

  static Future<void> clearAllCache() async {
    await clearAllImageCache();
    await clearVideoCache();
  }

  static Future<void> enforceVideoCacheLimit() async {
    final maxMB = await getVideoCacheMaxSizeMB();
    final maxSizeBytes = maxMB * 1024 * 1024;
    final currentSize = await getVideoCacheSize();
    if (currentSize <= maxSizeBytes) return;

    final dirPath = await _videoCacheDirPath;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    final files = <MapEntry<File, DateTime>>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          files.add(MapEntry(entity, await entity.lastModified()));
        } catch (_) {}
      }
    }

    files.sort((a, b) => a.value.compareTo(b.value));

    int freedSize = 0;
    final targetFree = currentSize - maxSizeBytes;
    for (final entry in files) {
      if (freedSize >= targetFree) break;
      try {
        final fileSize = await entry.key.length();
        await entry.key.delete();
        freedSize += fileSize;
      } catch (_) {}
    }
  }

  static Future<void> runStartupCleanup() async {
    await clearExpiredImageCache();
    await enforceVideoCacheLimit();
  }

  static Future<void> configureMemoryCache() async {
    PaintingBinding.instance.imageCache.maximumSize = 100;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 80 * 1024 * 1024;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }
}
