import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';

import '../app_identity.dart';

/// 匿名遥测（Sentry）：只做两件事——崩溃/错误上报 + Release Health 匿名活跃
/// 用户统计（「有多少人在用」）。全平台（Win/Linux/macOS/Android/iOS/TV）由
/// sentry_flutter 的 native 层 + Dart 层统一覆盖。
///
/// 隐私底线：
/// - [SentryFlutterOptions.sendDefaultPii] = false —— 不采账号/IP/服务器地址等 PII。
/// - 不开性能追踪（tracesSampleRate = 0），不录屏。
/// - 用户 id 由 Sentry 匿名 installId 承担（只数人头、不认身份）。
class Telemetry {
  Telemetry._();

  static const String _dsn =
      'https://7ea0381776746dcddd6d499d8e9e5d45@o4511717250433024.ingest.us.sentry.io/4511717262032896';

  /// 初始化 Sentry 并运行 App。
  static Future<void> runGuarded(FutureOr<void> Function() appRunner) {
    return SentryFlutter.init(
      (o) {
        o.dsn = _dsn;
        o.sendDefaultPii = false; // 不采 PII
        o.tracesSampleRate = 0; // 只要崩溃 + release health，不要性能追踪
        o.tracePropagationTargets.clear(); // 绝不给用户服务器/CDN 的出站请求塞遥测头
        o.release = 'linplayer@$kAppVersion';
        o.enableAutoSessionTracking = true; // 「多少人在用」= 匿名会话统计
      },
      appRunner: () => appRunner(),
    );
  }
}
