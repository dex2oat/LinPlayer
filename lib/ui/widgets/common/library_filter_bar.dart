import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/utils/library_filter_utils.dart';

/// 媒体库筛选面板（移动端 + 桌面端共用，Material）。
///
/// 分面取值（类型 / 标签 / 工作室 / 时间）来自 Emby 各分面专用端点。每个维度**一行**，
/// 默认空（显示「全部」），点该行弹出底部选择器（按拼音首字母排序）选一个值，选中后
/// 在该行回显，下方媒体库实时服务端过滤。再选「全部」即清除。标签承载「地区」等信息
/// ——Emby 无独立地区分面，国产刮削器通常写进 Tags。
class LibraryFilterBar extends StatelessWidget {
  final Filters facets;
  final LibraryFilterValue value;
  final int currentYear;
  final ValueChanged<LibraryFilterValue> onChanged;

  const LibraryFilterBar({
    super.key,
    required this.facets,
    required this.value,
    required this.currentYear,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final f = facets;
    final v = value;
    final yearChips = buildYearChips(f.years, currentYear: currentYear);

    final rows = <Widget>[];
    if (f.genres.isNotEmpty) {
      rows.add(_row(context, '类型', v.genre, () async {
        final picked = await _pick(context, '类型', sortByPinyin(f.genres), v.genre);
        if (picked != null) onChanged(v.withGenre(picked.isEmpty ? null : picked));
      }));
    }
    if (f.tags.isNotEmpty) {
      rows.add(_row(context, '标签', v.tag, () async {
        final picked = await _pick(context, '标签', sortByPinyin(f.tags), v.tag);
        if (picked != null) onChanged(v.withTag(picked.isEmpty ? null : picked));
      }));
    }
    if (f.studios.isNotEmpty) {
      rows.add(_row(context, '工作室', v.studio, () async {
        final picked =
            await _pick(context, '工作室', sortByPinyin(f.studios), v.studio);
        if (picked != null) onChanged(v.withStudio(picked.isEmpty ? null : picked));
      }));
    }
    if (yearChips.isNotEmpty) {
      rows.add(_row(context, '时间', v.yearLabel, () async {
        final picked = await _pick(
            context, '时间', yearChips.map((e) => e.label).toList(), v.yearLabel);
        if (picked == null) return;
        if (picked.isEmpty) {
          onChanged(v.withYear(null, null));
        } else {
          final csv = yearChips.firstWhere((e) => e.label == picked).yearsCsv;
          onChanged(v.withYear(picked, csv));
        }
      }));
    }

    // 服务器对该库没有返回任何分面时，给个明确提示而非空白（避免误以为"功能没做"）。
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Text('该媒体库暂无可筛选项',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v.activeCount > 0)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => onChanged(v.cleared()),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('重置'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ),
          ...rows,
        ],
      ),
    );
  }

  /// 一行筛选维度：左侧标签，右侧当前选中值（未选显示「全部」），整行可点开选择器。
  Widget _row(BuildContext context, String label, String? selected,
      VoidCallback onTap) {
    final theme = Theme.of(context);
    final active = selected != null;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                selected ?? '全部',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: active
                      ? theme.textTheme.bodyLarge?.color
                      : theme.hintColor,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_right, size: 18, color: theme.hintColor),
          ],
        ),
      ),
    );
  }

  /// 底部选择器：拼音排序后的取值列表 + 顶部「全部」。返回 null=未改、''=全部、其余=选中值。
  Future<String?> _pick(BuildContext context, String title,
      List<String> options, String? current) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _option(ctx, '全部', current == null, () => Navigator.pop(ctx, '')),
                      for (final o in options)
                        _option(ctx, o, o == current,
                            () => Navigator.pop(ctx, o)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _option(
      BuildContext context, String label, bool selected, VoidCallback onTap) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(label,
          style: TextStyle(
            color: selected ? theme.colorScheme.primary : null,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          )),
      trailing: selected
          ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
