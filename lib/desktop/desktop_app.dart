import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers/app_providers.dart';
import '../core/theme/app_theme.dart';
import 'routes/desktop_router.dart';
import 'utils/desktop_shortcuts.dart';

const _desktopFontFamily = 'Microsoft YaHei UI';
const _desktopFontFallback = <String>[
  'Microsoft YaHei',
  'Segoe UI',
  'PingFang SC',
  'Hiragino Sans GB',
];

/// 桌面端应用入口
class LinPlayerDesktopApp extends ConsumerWidget {
  const LinPlayerDesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(desktopRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    
    return MaterialApp.router(
      title: 'Linplayer',
      debugShowCheckedModeBanner: false,
      theme: _desktopTheme(AppTheme.lightTheme),
      darkTheme: _desktopTheme(AppTheme.darkTheme),
      themeMode: switch (themeMode) {
        ThemeModeOption.light => ThemeMode.light,
        ThemeModeOption.dark => ThemeMode.dark,
        ThemeModeOption.system => ThemeMode.system,
      },
      routerConfig: router,
      builder: (context, child) {
        return DesktopShortcutsWrapper(child: child!);
      },
    );
  }
}

ThemeData _desktopTheme(ThemeData base) {
  final textTheme = base.textTheme.copyWith(
    displayLarge: _desktopTextStyle(base.textTheme.displayLarge),
    displayMedium: _desktopTextStyle(base.textTheme.displayMedium),
    displaySmall: _desktopTextStyle(
      base.textTheme.displaySmall,
      fontSize: 30,
      height: 1.08,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    headlineLarge: _desktopTextStyle(base.textTheme.headlineLarge),
    headlineMedium: _desktopTextStyle(base.textTheme.headlineMedium),
    headlineSmall: _desktopTextStyle(
      base.textTheme.headlineSmall,
      fontSize: 20,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleLarge: _desktopTextStyle(
      base.textTheme.titleLarge,
      fontSize: 18,
      height: 1.18,
      fontWeight: FontWeight.w700,
    ),
    titleMedium: _desktopTextStyle(
      base.textTheme.titleMedium,
      fontSize: 16,
      height: 1.22,
      fontWeight: FontWeight.w700,
    ),
    titleSmall: _desktopTextStyle(
      base.textTheme.titleSmall,
      fontSize: 14,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: _desktopTextStyle(
      base.textTheme.bodyLarge,
      fontSize: 16,
      height: 1.45,
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: _desktopTextStyle(
      base.textTheme.bodyMedium,
      fontSize: 14,
      height: 1.42,
      fontWeight: FontWeight.w600,
    ),
    bodySmall: _desktopTextStyle(
      base.textTheme.bodySmall,
      fontSize: 12,
      height: 1.36,
      fontWeight: FontWeight.w500,
    ),
    labelLarge: _desktopTextStyle(
      base.textTheme.labelLarge,
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w700,
    ),
    labelMedium: _desktopTextStyle(
      base.textTheme.labelMedium,
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: _desktopTextStyle(
      base.textTheme.labelSmall,
      fontSize: 11,
      height: 1.18,
      fontWeight: FontWeight.w500,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: base.scaffoldBackgroundColor,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: textTheme.titleLarge,
    ),
  );
}

TextStyle? _desktopTextStyle(
  TextStyle? style, {
  double? fontSize,
  double? height,
  FontWeight? fontWeight,
  double? letterSpacing,
}) {
  return style?.copyWith(
    fontFamily: _desktopFontFamily,
    fontFamilyFallback: _desktopFontFallback,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
  );
}
