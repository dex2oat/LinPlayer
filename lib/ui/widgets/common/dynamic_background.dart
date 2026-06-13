import 'package:flutter/material.dart';
import '../../utils/media_helpers.dart';

/// 动态背景包装器 — 确保内容文字在提取的深色背景上始终可读。
///
/// 同时设置五维：
/// 1. [Theme] `brightness: Brightness.dark` — 让 Material 组件走暗色路径
/// 2. [Theme] `colorScheme` — 基于品牌色生成暗色 variant，确保 surface/onSurface 正确
/// 3. [Theme] `textTheme.apply()` — 让显式读取主题颜色的 widget 拿到前景色
/// 4. [Theme] `iconTheme` — 让 Icon/IconButton 图标可见
/// 5. [DefaultTextStyle.merge] — 让不含显式颜色的 [Text] widget 继承前景色
class DynamicBackground extends StatelessWidget {
  final Color backgroundColor;
  final Widget child;

  const DynamicBackground({
    required this.backgroundColor,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final parentTheme = Theme.of(context);
    final foregroundColor = readableTextColorForBackground(backgroundColor);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: parentTheme.colorScheme.primary,
      brightness: Brightness.dark,
    );
    return DefaultTextStyle.merge(
      style: TextStyle(color: foregroundColor),
      child: Theme(
        data: parentTheme.copyWith(
          brightness: Brightness.dark,
          colorScheme: darkScheme,
          scaffoldBackgroundColor: backgroundColor,
          cardTheme: parentTheme.cardTheme.copyWith(color: darkScheme.surface),
          textTheme: parentTheme.textTheme.apply(
                bodyColor: foregroundColor,
                displayColor: foregroundColor,
              ),
          iconTheme: parentTheme.iconTheme.copyWith(
                color: foregroundColor,
              ),
          appBarTheme: parentTheme.appBarTheme.copyWith(
                backgroundColor: backgroundColor,
                foregroundColor: foregroundColor,
                titleTextStyle: parentTheme.appBarTheme.titleTextStyle?.copyWith(
                  color: foregroundColor,
                ),
              ),
        ),
        child: child,
      ),
    );
  }
}
