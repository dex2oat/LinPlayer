import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 颜色提取工具类
class ColorExtractor {
  /// 从图片URL提取主色调和暗色背景
  static Future<ExtractedColors> extractFromUrl(String imageUrl) async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(imageUrl),
        size: const Size(100, 100),
        maximumColorCount: 10,
      );

    final dominant = palette.dominantColor?.color ?? Colors.black;
    final vibrant = palette.vibrantColor?.color ?? dominant;
    final muted = palette.mutedColor?.color ?? _mute(dominant);
    final darkMuted = palette.darkMutedColor?.color ?? _darken(muted);

      return ExtractedColors(
        primary: vibrant,
        background: darkMuted,
        gradientStart: muted.withValues(alpha: 0.6),
        gradientEnd: darkMuted,
      );
    } catch (e) {
      return ExtractedColors.fallback();
    }
  }

  /// 加深颜色
  static Color _darken(Color color, [double amount = 0.4]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// 降低饱和度
  static Color _mute(Color color, [double amount = 0.3]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation - amount).clamp(0.0, 1.0))
        .toColor();
  }
}

/// 提取的颜色集合
class ExtractedColors {
  final Color primary;
  final Color background;
  final Color gradientStart;
  final Color gradientEnd;

  const ExtractedColors({
    required this.primary,
    required this.background,
    required this.gradientStart,
    required this.gradientEnd,
  });

  factory ExtractedColors.fallback() {
    return const ExtractedColors(
      primary: Color(0xFF5B8DEF),
      background: Color(0xFF121212),
      gradientStart: Color(0x99121212),
      gradientEnd: Color(0xFF121212),
    );
  }
}
