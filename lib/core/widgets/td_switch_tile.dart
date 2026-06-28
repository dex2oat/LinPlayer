import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

/// TDesign 风格的「开关行」，作为 Material [SwitchListTile] 的 drop-in 替代：
/// 字段名与 SwitchListTile 对齐（secondary/title/subtitle/value/onChanged），
/// 三端统一开关观感时，调用处只需把 `SwitchListTile` 改名为 `TdSwitchTile`。
class TdSwitchTile extends StatelessWidget {
  /// 左侧图标（对应 SwitchListTile.secondary）。
  final Widget? secondary;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;

  /// ponytail: 接住 SwitchListTile.dense 以便机械替换；TDCell 自带紧凑高度，这里不再细分。
  final bool dense;

  const TdSwitchTile({
    super.key,
    this.secondary,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.contentPadding,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    // 开关尺寸随端走：从环境 TD 字号推断（移动~16/PC~15/TV~25+），TV 用大号。
    final bodySize = TDTheme.of(context).fontBodyLarge?.size ?? 16;
    final switchSize = bodySize >= 22
        ? TDSwitchSize.large
        : (bodySize <= 15 ? TDSwitchSize.small : TDSwitchSize.medium);
    final cell = TDCell(
      bordered: false,
      hover: false,
      leftIconWidget: secondary,
      titleWidget: title,
      descriptionWidget: subtitle,
      noteWidget: TDSwitch(
        size: switchSize,
        isOn: value,
        enable: onChanged != null,
        onChanged: onChanged == null
            ? null
            : (v) {
                onChanged!(v);
                return true; // 状态由外部 provider 持有，始终接受切换。
              },
      ),
      onClick:
          onChanged == null ? null : (_) => onChanged!(!value),
    );
    return contentPadding == null
        ? cell
        : Padding(padding: contentPadding!, child: cell);
  }
}
