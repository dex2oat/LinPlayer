import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/desktop_ui_style.dart';

/// 桌面端窗口初始化：无边框窗口 + 自绘标题栏 + 最小尺寸。
///
/// 在 [runApp] 之前调用（仅桌面平台）。macOS 保留原生交通灯按钮，
/// Windows/Linux 隐藏系统标题栏，由 [AppTitleBar] 自绘窗口按钮。
Future<void> initDesktopWindow() async {
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(900, 600),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    // hidden: 隐藏系统标题栏文本；macOS 仍保留左上角交通灯按钮。
    titleBarStyle: TitleBarStyle.hidden,
    title: 'LinPlayer',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // macOS: 让内容延伸到标题栏区域，交通灯悬浮其上。
    if (Platform.isMacOS) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: true,
      );
    }
    await windowManager.show();
    await windowManager.focus();
  });
}

/// 标题栏高度（逻辑像素）。macOS 略矮以贴近原生。
double get appTitleBarHeight => Platform.isMacOS ? 28.0 : 40.0;

/// macOS 左上角交通灯按钮所需的预留宽度。
const double _macTrafficLightInset = 72.0;

/// 跨平台自绘标题栏。
///
/// - macOS：薄拖拽条，左侧为交通灯预留空白，标题居中，无自绘按钮。
/// - Windows/Linux：左侧标题，右侧最小化/最大化/关闭按钮（Fluent 风格悬停）。
class AppTitleBar extends StatefulWidget {
  final Brightness brightness;
  final String title;
  final Color? backgroundColor;

  /// 标题栏起始处的控件（如侧边栏汉堡按钮）。macOS 上排在交通灯之后。
  final Widget? leading;

  const AppTitleBar({
    super.key,
    required this.brightness,
    this.title = 'LinPlayer',
    this.backgroundColor,
    this.leading,
  });

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _isMaximized) {
      setState(() => _isMaximized = maximized);
    }
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  bool get _isDark => widget.brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final isMac = isMacosStyle;
    final foreground = _isDark
        ? Colors.white.withValues(alpha: 0.92)
        : Colors.black.withValues(alpha: 0.85);

    final titleStyle = TextStyle(
      fontSize: isMac ? 13 : 12.5,
      fontWeight: FontWeight.w600,
      color: foreground.withValues(alpha: 0.78),
      letterSpacing: 0.1,
    );

    final Widget content = Row(
      children: [
        if (isMac) ...[
          const SizedBox(width: _macTrafficLightInset),
          if (widget.leading != null) widget.leading!,
          Expanded(
            child: Center(
              child: Text(widget.title, style: titleStyle),
            ),
          ),
          const SizedBox(width: _macTrafficLightInset),
        ] else ...[
          if (widget.leading != null) ...[
            const SizedBox(width: 4),
            widget.leading!,
            const SizedBox(width: 4),
          ] else
            const SizedBox(width: 14),
          Text(widget.title, style: titleStyle),
          const Spacer(),
          _CaptionButton(
            type: _CaptionType.minimize,
            isDark: _isDark,
            onPressed: () => windowManager.minimize(),
          ),
          _CaptionButton(
            type: _isMaximized
                ? _CaptionType.restore
                : _CaptionType.maximize,
            isDark: _isDark,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _CaptionButton(
            type: _CaptionType.close,
            isDark: _isDark,
            onPressed: () => windowManager.close(),
          ),
        ],
      ],
    );

    return SizedBox(
      height: appTitleBarHeight,
      child: Container(
        color: widget.backgroundColor ?? Colors.transparent,
        child: DragToMoveArea(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
            child: content,
          ),
        ),
      ),
    );
  }
}

enum _CaptionType { minimize, maximize, restore, close }

/// Windows/Linux 窗口控制按钮（Fluent 风格：悬停浅色，关闭悬停变红）。
class _CaptionButton extends StatefulWidget {
  final _CaptionType type;
  final bool isDark;
  final VoidCallback onPressed;

  const _CaptionButton({
    required this.type,
    required this.isDark,
    required this.onPressed,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isClose = widget.type == _CaptionType.close;
    final baseColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.86)
        : Colors.black.withValues(alpha: 0.78);

    Color? hoverBg;
    Color iconColor = baseColor;
    if (_hovered) {
      if (isClose) {
        hoverBg = const Color(0xFFC42B1C);
        iconColor = Colors.white;
      } else {
        hoverBg = widget.isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.06);
      }
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: appTitleBarHeight,
          color: hoverBg ?? Colors.transparent,
          child: Center(
            child: CustomPaint(
              size: const Size(10, 10),
              painter: _CaptionIconPainter(
                type: widget.type,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptionIconPainter extends CustomPainter {
  final _CaptionType type;
  final Color color;

  _CaptionIconPainter({required this.type, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;

    switch (type) {
      case _CaptionType.minimize:
        final y = h / 2;
        canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        break;
      case _CaptionType.maximize:
        canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);
        break;
      case _CaptionType.restore:
        // 后置小方块 + 前置小方块，表示“还原”。
        final offset = w * 0.25;
        canvas.drawRect(
          Rect.fromLTWH(offset, 0, w - offset, h - offset),
          paint,
        );
        canvas.drawRect(
          Rect.fromLTWH(0, offset, w - offset, h - offset),
          Paint()
            ..color = color
            ..strokeWidth = 1.0
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true,
        );
        break;
      case _CaptionType.close:
        canvas.drawLine(const Offset(0, 0), Offset(w, h), paint);
        canvas.drawLine(Offset(w, 0), Offset(0, h), paint);
        break;
    }
  }

  @override
  bool shouldRepaint(_CaptionIconPainter old) =>
      old.type != type || old.color != color;
}
