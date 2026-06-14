import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import '../../core/theme/app_colors.dart';

/// 把品牌色桥接到各原生主题。
///
/// Material（Linux + 内容层）继续使用 [AppTheme]；这里只负责 Windows(fluent)
/// 与 macOS(macos_ui) 的原生主题，统一以品牌色 [AppColors.brand] 为强调色。

/// Windows / Fluent 强调色（七档色阶）。
fluent.AccentColor get _brandAccent => fluent.AccentColor.swatch(const <String, material.Color>{
      'darkest': AppColors.brandDark,
      'darker': AppColors.brandDark,
      'dark': AppColors.brandDark,
      'normal': AppColors.brand,
      'light': AppColors.brandLight,
      'lighter': AppColors.brandLight,
      'lightest': AppColors.brandLight,
    });

/// 构建 Windows 的 FluentThemeData。
///
/// 中文导航文案需要中文字形，使用 Windows 原生中文 UI 字体 “Microsoft YaHei UI”
/// 既符合系统观感又能正确渲染中英文。
fluent.FluentThemeData buildFluentTheme(material.Brightness brightness) {
  final isDark = brightness == material.Brightness.dark;
  // 统一侧边栏与内容区背景：与 Material 内容页的 scaffoldBackgroundColor 一致，
  // 避免导航面板与页面颜色不一致的割裂感。
  final background =
      isDark ? AppColors.darkBackground : AppColors.lightBackground;
  return fluent.FluentThemeData(
    brightness: brightness,
    accentColor: _brandAccent,
    scaffoldBackgroundColor: background,
    fontFamily: 'Microsoft YaHei UI',
    visualDensity: material.VisualDensity.standard,
    focusTheme: const fluent.FocusThemeData(
      glowFactor: 0,
    ),
    navigationPaneTheme: fluent.NavigationPaneThemeData(
      backgroundColor: background,
      overlayBackgroundColor: background,
    ),
  );
}

/// 构建 macOS 的 MacosThemeData。
macos.MacosThemeData buildMacosTheme(material.Brightness brightness) {
  final base = brightness == material.Brightness.dark
      ? macos.MacosThemeData.dark()
      : macos.MacosThemeData.light();
  return base.copyWith(
    primaryColor: AppColors.brand,
  );
}
