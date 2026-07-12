import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tv_design_tokens.dart';
import '../theme/tv_metrics.dart';

/// TV 安全文本输入框——修复「聚焦输入框后遥控器彻底失灵」的死锁。
///
/// 根因：Android TV 上原生 [TextField]/EditableText 会把 D-pad 方向键当成
/// 光标移动**吞掉**，焦点永远出不来。TV 上打字本来就是按 OK 弹全屏系统输入法
/// (leanback IME)，方向键在框内移光标毫无意义。
///
/// 修法：用 [Shortcuts] 把四个方向键强制映射成 [DirectionalFocusIntent]，
/// 让方向键一律移动焦点（离开输入框、在字段间导航），OK/确认才唤起输入法。
/// [Shortcuts] 挂在 [TextField] 之上、比 `DefaultTextEditingShortcuts` 更近，
/// 按键就近优先命中，从而屏蔽掉默认的光标移动。
const Map<ShortcutActivator, Intent> _kTvFieldNav = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.arrowUp):
      DirectionalFocusIntent(TraversalDirection.up),
  SingleActivator(LogicalKeyboardKey.arrowDown):
      DirectionalFocusIntent(TraversalDirection.down),
  SingleActivator(LogicalKeyboardKey.arrowLeft):
      DirectionalFocusIntent(TraversalDirection.left),
  SingleActivator(LogicalKeyboardKey.arrowRight):
      DirectionalFocusIntent(TraversalDirection.right),
};

class TvTextField extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final bool obscureText;
  final bool autofocus;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  const TvTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.obscureText = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.prefixIcon,
    this.suffixIcon,
  });

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  late FocusNode _node;
  bool _ownsNode = false;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode();
    _ownsNode = widget.focusNode == null;
    _node.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(TvTextField old) {
    super.didUpdateWidget(old);
    if (widget.focusNode != old.focusNode) {
      _node.removeListener(_onFocusChange);
      if (_ownsNode) _node.dispose();
      _node = widget.focusNode ?? FocusNode();
      _ownsNode = widget.focusNode == null;
      _node.addListener(_onFocusChange);
    }
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final focused = _node.hasFocus;
    return Shortcuts(
      shortcuts: _kTvFieldNav,
      child: Container(
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
          border: Border.all(
            color: focused ? TvDesignTokens.focusRing : TvDesignTokens.divider,
            width: focused ? TvDesignTokens.focusRingWidth : 1.5,
          ),
          boxShadow: focused
              ? const [
                  BoxShadow(
                    color: TvDesignTokens.focusGlow,
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        padding: EdgeInsets.symmetric(horizontal: m.spacingMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.prefixIcon != null) ...[
              widget.prefixIcon!,
              SizedBox(width: m.spacingSm),
            ],
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _node,
                autofocus: widget.autofocus,
                obscureText: widget.obscureText,
                maxLines: widget.obscureText ? 1 : widget.maxLines,
                keyboardType: widget.keyboardType,
                textInputAction: widget.textInputAction,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                style: TextStyle(
                  fontSize: m.fontSizeMd,
                  color: TvDesignTokens.textPrimary,
                ),
                cursorColor: TvDesignTokens.brand,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: widget.hint,
                  hintStyle: TextStyle(
                    color: TvDesignTokens.textDisabled,
                    fontSize: m.fontSizeSm,
                  ),
                  contentPadding: EdgeInsets.symmetric(vertical: m.spacingMd),
                ),
              ),
            ),
            if (widget.suffixIcon != null) widget.suffixIcon!,
          ],
        ),
      ),
    );
  }
}
