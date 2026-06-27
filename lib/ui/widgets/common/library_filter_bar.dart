import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/utils/library_filter_utils.dart';

/// 媒体库筛选面板（移动端 + 桌面端共用，Material）。
///
/// 数据来自 Emby `/Items/Filters` 的一次性返回（Genres / Years / Tags），
/// 选中值经服务端过滤，不在本地分页拉全量。每组单选，再点一次取消。
/// 标签组承载「地区」等信息——Emby 无独立地区分面，国产刮削器通常写进 Tags。
class LibraryFilterBar extends StatefulWidget {
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
  State<LibraryFilterBar> createState() => _LibraryFilterBarState();
}

class _LibraryFilterBarState extends State<LibraryFilterBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = widget.facets;
    final v = widget.value;
    final yearChips = buildYearChips(f.years, currentYear: widget.currentYear);
    final hasAny = f.genres.isNotEmpty ||
        f.tags.isNotEmpty ||
        f.studios.isNotEmpty ||
        yearChips.isNotEmpty;
    if (!hasAny) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        v.activeCount > 0 ? '筛选 · ${v.activeCount}' : '筛选',
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18, color: theme.colorScheme.primary),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (v.activeCount > 0)
                TextButton(
                  onPressed: () => widget.onChanged(v.cleared()),
                  child: const Text('重置'),
                ),
            ],
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (f.genres.isNotEmpty)
                  _row(theme, '类型', [
                    for (final g in f.genres)
                      _chip(theme, g, v.genre == g,
                          () => widget.onChanged(v.withGenre(v.genre == g ? null : g))),
                  ]),
                if (f.tags.isNotEmpty)
                  _row(theme, '标签', [
                    for (final t in f.tags)
                      _chip(theme, t, v.tag == t,
                          () => widget.onChanged(v.withTag(v.tag == t ? null : t))),
                  ]),
                if (f.studios.isNotEmpty)
                  _row(theme, '工作室', [
                    for (final s in f.studios)
                      _chip(theme, s, v.studio == s,
                          () => widget.onChanged(v.withStudio(v.studio == s ? null : s))),
                  ]),
                if (yearChips.isNotEmpty)
                  _row(theme, '时间', [
                    for (final yc in yearChips)
                      _chip(theme, yc.label, v.yearLabel == yc.label, () {
                        final on = v.yearLabel == yc.label;
                        widget.onChanged(
                            v.withYear(on ? null : yc.label, on ? null : yc.yearsCsv));
                      }),
                  ]),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(ThemeData theme, String label, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: chips,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(ThemeData theme, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected
                ? theme.colorScheme.primary
                : theme.textTheme.bodyMedium?.color,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
