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

  /// 居中弹窗选择器：胶囊网格 + 右上角搜索框。返回 null=未改、''=全部、其余=选中值。
  Future<String?> _pick(BuildContext context, String title,
      List<String> options, String? current) {
    return showDialog<String>(
      context: context,
      builder: (ctx) =>
          _FacetPickerDialog(title: title, options: options, current: current),
    );
  }
}

/// 居中的筛选取值选择器：标题 + 右上角实时搜索框（中文按拼音匹配），下方一个个胶囊，
/// 选中即返回。「全部」固定在最前用于清除。
class _FacetPickerDialog extends StatefulWidget {
  final String title;
  final List<String> options;
  final String? current;

  const _FacetPickerDialog({
    required this.title,
    required this.options,
    required this.current,
  });

  @override
  State<_FacetPickerDialog> createState() => _FacetPickerDialogState();
}

class _FacetPickerDialogState extends State<_FacetPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.options
        : widget.options
            .where((o) =>
                o.toLowerCase().contains(q) || pinyinOf(o).contains(q))
            .toList();

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(widget.title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  SizedBox(
                    width: 160,
                    height: 36,
                    child: TextField(
                      autofocus: false,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (q.isEmpty)
                        _capsule(theme, '全部', widget.current == null,
                            () => Navigator.pop(context, '')),
                      for (final o in filtered)
                        _capsule(theme, o, o == widget.current,
                            () => Navigator.pop(context, o)),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text('无匹配项',
                              style: TextStyle(
                                  fontSize: 13, color: theme.hintColor)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _capsule(
      ThemeData theme, String label, bool selected, VoidCallback onTap) {
    final primary = theme.colorScheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? primary.withValues(alpha: 0.14)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: selected ? primary : theme.textTheme.bodyMedium?.color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
