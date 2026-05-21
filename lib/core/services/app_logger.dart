import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel { verbose, debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  @override
  String toString() {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}.${timestamp.millisecond.toString().padLeft(3, '0')}';
    final levelStr = level.name.toUpperCase().padRight(7);
    return '[$time] $levelStr [$tag] $message';
  }
}

/// 应用日志系统
/// 
/// 收集所有运行时日志，支持导出为文件。
/// 在设置页中可导出完整日志用于问题排查。
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  final List<LogEntry> _logs = [];
  static const int _maxLogs = 5000;

  final List<void Function(LogEntry)> _listeners = [];

  void addListener(void Function(LogEntry) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(LogEntry) listener) {
    _listeners.remove(listener);
  }

  void _log(LogLevel level, String tag, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    for (final listener in _listeners) {
      listener(entry);
    }
    if (kDebugMode) {
      debugPrint(entry.toString());
    }
  }

  void v(String tag, String message) => _log(LogLevel.verbose, tag, message);
  void d(String tag, String message) => _log(LogLevel.debug, tag, message);
  void i(String tag, String message) => _log(LogLevel.info, tag, message);
  void w(String tag, String message) => _log(LogLevel.warning, tag, message);
  void e(String tag, String message) => _log(LogLevel.error, tag, message);

  void eWithStack(String tag, String message, Object error, [StackTrace? stackTrace]) {
    final fullMessage = '$message\n  Error: $error${stackTrace != null ? '\n$stackTrace' : ''}';
    _log(LogLevel.error, tag, fullMessage);
  }

  List<LogEntry> getLogs({LogLevel? minLevel}) {
    if (minLevel == null) return List.unmodifiable(_logs);
    return List.unmodifiable(_logs.where((l) => l.level.index >= minLevel.index));
  }

  void clear() => _logs.clear();

  /// 导出日志为字符串
  String exportAsString() {
    final buffer = StringBuffer();
    buffer.writeln('============================================');
    buffer.writeln('  LinPlayer 日志导出');
    buffer.writeln('  时间: ${DateTime.now().toIso8601String()}');
    buffer.writeln('  平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('  日志条数: ${_logs.length}');
    buffer.writeln('============================================');
    buffer.writeln();
    for (final entry in _logs) {
      buffer.writeln(entry.toString());
    }
    buffer.writeln();
    buffer.writeln('============================================');
    buffer.writeln('  日志结束');
    buffer.writeln('============================================');
    return buffer.toString();
  }

  /// 导出日志到文件，返回文件路径
  Future<String> exportToFile() async {
    final content = exportAsString();
    
    // 优先保存到 Download 目录
    try {
      final downloadsDir = Directory('/storage/emulated/0/Download');
      if (downloadsDir.existsSync()) {
        final fileName = 'linplayer_logs_${DateTime.now().millisecondsSinceEpoch}.txt';
        final file = File('${downloadsDir.path}/$fileName');
        await file.writeAsString(content);
        i('AppLogger', '日志已导出到: ${file.path}');
        return file.path;
      }
    } catch (_) {}

    // 回退到应用文档目录
    final appDir = await getApplicationDocumentsDirectory();
    final fileName = 'linplayer_logs_${DateTime.now().millisecondsSinceEpoch}.txt';
    final file = File('${appDir.path}/$fileName');
    await file.writeAsString(content);
    i('AppLogger', '日志已保存到应用目录: ${file.path}');
    return file.path;
  }
}
