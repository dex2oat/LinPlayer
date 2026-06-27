import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/utils/library_filter_utils.dart';

/// 媒体库筛选面板（移动端 + 桌面端共用，Material）。
///
/// 数据来自 Emby `/Items/Filters` 的一次性返回（Genres / Years / Tags）+ `/Studios`，
/// 选中值经服务端过滤，不在本地分页拉全量。每组单选，再点一次取消。默认全部展开
/// （类型/标签/工作室/时间 行直接铺开，不折叠）。标签组承载「地区」等信息——Emby
/// 无独立地区分面，国产刮削器通常写进 Tags。
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
    final theme = Theme.of(context);
    final f = facets;
    final v = value;
    final yearChips = buildYearChips(f.years, currentYear: currentYear);
    final hasAny = f.genres.isNotEmpty ||
        f.tags.isNotEmpty ||
        f.studios.isNotEmpty ||
        yearChips.isNotEmpty;
    // 服务器对该库没有返回任何分面时，给个明确提示而非空白（避免误以为"功能没做"）。
    if (!hasAny) {
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
          if (f.genres.isNotEmpty)
            _row(theme, '类型', [
              for (final g in f.genres)
                _chip(theme, g, v.genre == g,
                    () => onChanged(v.withGenre(v.genre == g ? null : g))),
            ]),
          if (f.tags.isNotEmpty)
            _row(theme, '标签', [
              for (final t in f.tags)
                _chip(theme, t, v.tag == t,
                    () => onChanged(v.withTag(v.tag == t ? null : t))),
            ]),
          if (f.studios.isNotEmpty)
            _row(theme, '工作室', [
              for (final s in f.studios)
                _chip(theme, s, v.studio == s,
                    () => onChanged(v.withStudio(v.studio == s ? null : s))),
            ]),
          if (yearChips.isNotEmpty)
            _row(theme, '时间', [
              for (final yc in yearChips)
                _chip(theme, yc.label, v.yearLabel == yc.label, () {
                  final on = v.yearLabel == yc.label;
                  onChanged(
                      v.withYear(on ? null : yc.label, on ? null : yc.yearsCsv));
                }),
            ]),
        ],
      ),
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
          Expanded(child: _ExpandableChips(chips: chips)),
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

/// 单组芯片：项太多时默认折叠（约两行），点「展开」放开到约五行并可上下滚动，
/// 避免工作室/类型等高基数分面把整个面板撑爆。少于阈值则原样平铺、不显示按钮。
class _ExpandableChips extends StatefulWidget {
  final List<Widget> chips;
  const _ExpandableChips({required this.chips});

  @override
  State<_ExpandableChips> createState() => _ExpandableChipsState();
}

class _ExpandableChipsState extends State<_ExpandableChips> {
  bool _expanded = false;
  static const _threshold = 14; // 超过这么多项才折叠
  static const _collapsedH = 68.0; // 约两行
  static const _expandedH = 168.0; // 约五行（可滚）

  @override
  Widget build(BuildContext context) {
    final chips = widget.chips;
    final wrap = Wrap(spacing: 6, runSpacing: 4, children: chips);
    if (chips.length <= _threshold) return wrap;

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: _expanded ? _expandedH : _collapsedH),
            child: _expanded
                ? SingleChildScrollView(child: wrap)
                : ClipRect(
                    child: Align(
                        alignment: Alignment.topLeft,
                        heightFactor: 1,
                        child: wrap)),
          ),
        ),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_expanded ? '收起' : '展开',
                    style:
                        TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
