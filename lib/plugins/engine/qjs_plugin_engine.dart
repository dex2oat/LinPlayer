import 'dart:async';

import 'package:flutter_qjs/flutter_qjs.dart';

import '../../core/services/app_logger.dart';
import 'plugin_js_engine.dart';

/// 基于 `flutter_qjs` 的 QuickJS 引擎实现。
///
/// 采用 [IsolateQjs]：每个插件运行在**独立 isolate** 中，获得：
///  - 真正的内存/CPU 隔离（memoryLimit 限制堆大小）；
///  - 崩溃隔离：插件 JS 抛异常/栈溢出只影响该 isolate，主程序不受影响；
///  - 失控隔离：即便 JS 陷入死循环卡住自己的 isolate，主 isolate 依旧响应，
///    由主 isolate 侧的 [Future] 超时判定为失控并禁用插件（停止与之通信）。
///
/// 宿主桥 `__lp_host` 用 [IsolateFunction] 包装：插件 isolate 调用它时，会通过
/// SendPort 回到**主 isolate** 执行真正的 ctx 能力（可访问 Riverpod/网络），
/// 再把结果（Promise）回传。这样既隔离又能复用主程序能力。
///
/// 注意：对 `flutter_qjs` 的依赖全部集中在本文件。
class QjsPluginEngine implements PluginJsEngine {
  static final AppLogger _log = AppLogger();

  /// 单个插件 isolate 的内存上限（字节）。
  static const int _memoryLimit = 64 * 1024 * 1024;

  final String pluginId;
  QjsPluginEngine(this.pluginId);

  IsolateQjs? _engine;
  IsolateFunction? _hostFn;
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> start({
    required String bootstrapJs,
    required String pluginJs,
    required PluginHostDispatcher dispatcher,
  }) async {
    if (_disposed) throw PluginEngineError('引擎已销毁');

    final engine = IsolateQjs(
      memoryLimit: _memoryLimit,
      // 禁止任意模块加载（不暴露文件系统）。
      moduleHandler: (String path) async =>
          throw Exception('插件不允许 import 外部模块: $path'),
    );
    _engine = engine;

    // 注入宿主桥：包装为 IsolateFunction，调用时在主 isolate 执行 dispatcher。
    // 形参顺序对应 JS 侧 __lp_host(channel, method, argsJson)。
    final hostFn = IsolateFunction(
      (channel, method, argsJson) =>
          dispatcher('$channel', '$method', '$argsJson'),
    );
    _hostFn = hostFn;

    final setter = await engine.evaluate('(k, v) => { globalThis[k] = v; }');
    await (setter as dynamic).invoke(['__lp_host', hostFn]);
    _free(setter);

    // 先执行引导脚本搭建 ctx，再执行插件主脚本。
    await engine.evaluate(bootstrapJs, name: '$pluginId/bootstrap.js');
    await engine.evaluate(pluginJs, name: '$pluginId/main.js');
  }

  @override
  Future<String> invoke(String name, String argsJson,
      {Duration? timeout}) async {
    final code = '__lp_invoke(${_jsString(name)}, ${_jsString(argsJson)})';
    final result = await evaluate(code, timeout: timeout);
    return result == null ? 'null' : '$result';
  }

  @override
  Future<dynamic> evaluate(String code, {Duration? timeout}) async {
    final engine = _engine;
    if (_disposed || engine == null) {
      throw PluginEngineError('引擎不可用');
    }
    final future = engine.evaluate(code);
    if (timeout == null) return future;

    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      _log.w('PluginEngine', '插件 $pluginId 调用超时（>${timeout.inMilliseconds}ms）');
      // 失控：销毁该 isolate，调用方据此禁用插件。
      unawaited(dispose());
      throw PluginTimeoutError('调用超时 ${timeout.inMilliseconds}ms');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final engine = _engine;
    _engine = null;
    _free(_hostFn);
    _hostFn = null;
    try {
      engine?.close();
    } catch (e) {
      _log.w('PluginEngine', '关闭插件 $pluginId 引擎失败: $e');
    }
  }

  void _free(dynamic ref) {
    try {
      (ref as dynamic)?.free();
    } catch (_) {
      // 某些对象无需手动释放，忽略。
    }
  }

  /// 生成安全的 JS 字符串字面量（转义引号、反斜杠、控制字符及 JS 行/段分隔符）。
  static String _jsString(String s) {
    final sb = StringBuffer('"');
    for (final rune in s.runes) {
      switch (rune) {
        case 0x5C: // backslash
          sb.write(r'\\');
          break;
        case 0x22: // double quote
          sb.write(r'\"');
          break;
        case 0x0A:
          sb.write(r'\n');
          break;
        case 0x0D:
          sb.write(r'\r');
          break;
        case 0x09:
          sb.write(r'\t');
          break;
        case 0x2028: // line separator
        case 0x2029: // paragraph separator
          sb.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          break;
        default:
          if (rune < 0x20) {
            sb.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            sb.writeCharCode(rune);
          }
      }
    }
    sb.write('"');
    return sb.toString();
  }
}
