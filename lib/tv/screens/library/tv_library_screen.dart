import '../../../core/widgets/app_shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/utils/library_filter_utils.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// TV 媒体库页 —— 顶部排序，下方 2:3 海报网格（真实数据）。
class TvLibraryScreen extends ConsumerStatefulWidget {
  /// 由首页/查看全部传入的目标媒体库；为空时取第一个媒体库。
  final String? initialLibraryId;

  /// 标题兜底：当 [initialLibraryId] 不是媒体库（如合集 BoxSet）时用它显示名字。
  final String? initialTitle;

  const TvLibraryScreen({super.key, this.initialLibraryId, this.initialTitle});

  @override
  ConsumerState<TvLibraryScreen> createState() => _TvLibraryScreenState();
}

class _TvLibraryScreenState extends ConsumerState<TvLibraryScreen> {
  /// 海报密度档位：决定单张海报的目标宽度倍率，配合 max-extent 网格
  /// 让列数随屏幕宽度自适应。三档对应「较密 / 中等 / 较疏」。
  static const List<double> _densityFactors = [0.85, 1.0, 1.3];
  int _densityIndex = 1;
  String? _libraryId;
  // 筛选 + 排序（服务端过滤；排序字段/升降序也并入 _filter）
  LibraryFilterValue _filter = const LibraryFilterValue();

  @override
  void initState() {
    super.initState();
    _libraryId = widget.initialLibraryId;
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final librariesAsync = ref.watch(librariesProvider);

    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Padding(
        padding: EdgeInsets.all(m.spacingXl),
        child: librariesAsync.when(
          data: (libs) {
            if (libs.isEmpty) {
              return _centerHint('暂无媒体库');
            }
            final libId = _libraryId ?? libs.first.id;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(m, libs, libId),
                SizedBox(height: m.spacingMd),
                _buildSortRow(m),
                _buildFilterRows(m, libId),
                SizedBox(height: m.spacingLg),
                Expanded(child: _buildGrid(m, libId)),
              ],
            );
          },
          loading: () =>
              const Center(child: AppLoadingIndicator(size: 48, color: TvDesignTokens.brand)),
          error: (e, _) => _centerHint('加载媒体库失败：$e'),
        ),
      ),
    );
  }

  Widget _buildHeader(TvMetrics m, List<Library> libs, String selectedId) {
    final dense = _densityIndex == 0;
    // selectedId 可能是合集(不在 libs 里)，匹配不到就用传入标题兜底。
    final match = libs.where((l) => l.id == selectedId).firstOrNull;
    final title = match?.name ?? widget.initialTitle ?? libs.first.name;
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: m.fontSizeXxl,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Spacer(),
        TvFocusable(
          onSelect: () => setState(() {
            _densityIndex = (_densityIndex + 1) % _densityFactors.length;
          }),
          child: _chip(
            m,
            icon: dense ? Icons.grid_on : Icons.grid_view,
            label: _densityIndex == 0
                ? '较密'
                : (_densityIndex == 1 ? '中等' : '较疏'),
            selected: false,
          ),
        ),
      ],
    );
  }

  /// 排序选项：更新时间 / 标题排序 / 官方评级。点选中项切升/降序，点未选中项切到该字段。
  static const List<({String label, String key})> _sortOptions = [
    (label: '更新时间', key: 'DateCreated'),
    (label: '标题排序', key: 'SortName'),
    (label: '官方评级', key: 'OfficialRating'),
  ];

  Widget _buildSortRow(TvMetrics m) {
    return Wrap(
      spacing: m.spacingSm,
      runSpacing: m.spacingSm,
      children: [
        for (final opt in _sortOptions)
          TvFocusable(
            onSelect: () => setState(() => _filter = _filter.toggledSort(opt.key)),
            child: _chip(
              m,
              icon: _filter.sortBy == opt.key
                  ? (_filter.sortDescending
                      ? Icons.arrow_downward
                      : Icons.arrow_upward)
                  : null,
              label: opt.label,
              selected: _filter.sortBy == opt.key,
            ),
          ),
      ],
    );
  }

  /// 类型/标签/时间：项不多，一行行铺开可点选胶囊（单选，再选取消）。工作室取值可能
  /// 很多，单独成一行回显当前值，点开焦点弹窗（拼音排序）选。下方网格服务端实时过滤。
  Widget _buildFilterRows(TvMetrics m, String libraryId) {
    final facetsAsync = ref.watch(filtersProvider(libraryId));
    return facetsAsync.maybeWhen(
      data: (f) {
        final years = buildYearChips(f.years, currentYear: DateTime.now().year);
        final rows = <Widget>[];
        // 顺序（自上而下）：时间 → 类型 → 标签 → 工作室。
        if (years.isNotEmpty) {
          rows.add(_facetChipRow(m, '时间', [
            for (final yc in years)
              _facetChip(m, yc.label, _filter.yearLabel == yc.label, () {
                final on = _filter.yearLabel == yc.label;
                _filter = _filter.withYear(
                    on ? null : yc.label, on ? null : yc.yearsCsv);
              }),
          ]));
        }
        if (f.genres.isNotEmpty) {
          rows.add(_facetChipRow(m, '类型', [
            for (final g in f.genres)
              _facetChip(m, g, _filter.genre == g,
                  () => _filter = _filter.withGenre(_filter.genre == g ? null : g)),
          ]));
        }
        if (f.tags.isNotEmpty) {
          rows.add(_facetChipRow(m, '标签', [
            for (final t in f.tags)
              _facetChip(m, t, _filter.tag == t,
                  () => _filter = _filter.withTag(_filter.tag == t ? null : t)),
          ]));
        }
        if (f.studios.isNotEmpty) {
          rows.add(_facetRow(m, '工作室', _filter.studio, () async {
            final p = await _showFacetPicker(
                m, '工作室', sortByPinyin(f.studios), _filter.studio);
            if (p != null) {
              // 工作室优先存 Id（StudioIds），服务端 GUID 严格时 API 层自动退回按名过滤。
              final name = p.isEmpty ? null : p;
              setState(() => _filter = _filter.withStudio(
                  name, name == null ? null : f.studioIds[name]));
            }
          }));
        }
        if (rows.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(top: m.spacingMd),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  /// 一行可点选胶囊（类型/标签/时间）。
  Widget _facetChipRow(TvMetrics m, String label, List<Widget> chips) {
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: m.spacingXs, right: m.spacingMd),
            child: SizedBox(
              width: m.s(64),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.textSecondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
                spacing: m.spacingSm, runSpacing: m.spacingSm, children: chips),
          ),
        ],
      ),
    );
  }

  Widget _facetChip(
      TvMetrics m, String label, bool selected, VoidCallback apply) {
    return TvFocusable(
      onSelect: () => setState(apply),
      child: _chip(m, label: label, selected: selected),
    );
  }

  /// 工作室一行：回显当前选中值（未选「全部」），点开焦点弹窗。
  Widget _facetRow(
      TvMetrics m, String label, String? selected, VoidCallback onTap) {
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: Row(
        children: [
          SizedBox(
            width: m.s(76),
            child: Text(
              label,
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.textSecondary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(width: m.spacingMd),
          TvFocusable(
            onSelect: onTap,
            child: _chip(m,
                icon: Icons.keyboard_arrow_down,
                label: selected ?? '全部',
                selected: selected != null),
          ),
        ],
      ),
    );
  }

  /// TV 焦点式单选弹窗：拼音排序取值 + 顶部「全部」。返回 null=未改、''=全部、其余=值。
  /// 当前值（或「全部」）autofocus，D-pad 在 Wrap 内移动、框架自动 ensureVisible 跟随滚动。
  Future<String?> _showFacetPicker(
      TvMetrics m, String title, List<String> options, String? current) {
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: TvDesignTokens.surfaceElevated,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(m.posterRadius)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: m.s(560),
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
            child: Padding(
              padding: EdgeInsets.all(m.spacingLg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontSize: m.fontSizeLg,
                        color: TvDesignTokens.textPrimary,
                        fontWeight: FontWeight.bold,
                      )),
                  SizedBox(height: m.spacingMd),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: m.spacingSm,
                        runSpacing: m.spacingSm,
                        children: [
                          TvFocusable(
                            autofocus: current == null,
                            onSelect: () => Navigator.pop(ctx, ''),
                            child:
                                _chip(m, label: '全部', selected: current == null),
                          ),
                          for (final o in options)
                            TvFocusable(
                              autofocus: o == current,
                              onSelect: () => Navigator.pop(ctx, o),
                              child: _chip(m, label: o, selected: o == current),
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
      },
    );
  }

  Widget _buildGrid(TvMetrics m, String libraryId) {
    final itemsAsync = ref.watch(libraryItemsProvider((
      libraryId: libraryId,
      sortBy: _filter.sortBy,
      sortOrder: _filter.sortDescending ? 'Descending' : 'Ascending',
      genres: _filter.genre,
      tags: _filter.tag,
      studioIds: _filter.studioId,
      studios: _filter.studio,
      years: _filter.yearsCsv,
      ratingMin: _filter.ratingMin,
      ratingMax: _filter.ratingMax,
    )));
    final api = ref.read(apiClientProvider);

    // 2:3 海报 + 下方标题；列数随屏幕宽度自适应，密度档位微调目标宽度。
    final double maxExtent =
        m.posterWidth2_3 * _densityFactors[_densityIndex];
    return itemsAsync.when(
      data: (items) {
        if (items.isEmpty) return _centerHint('该媒体库暂无内容');
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            childAspectRatio: 2 / 3.4,
            crossAxisSpacing: m.posterSpacing,
            mainAxisSpacing: m.posterSpacing,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final urls = resolveMediaItemImageUrls(api, item, maxWidth: 360);
            return TvFocusable(
              padding: EdgeInsets.all(m.s(6)),
              onSelect: () => context.push('/tv/detail/${item.id}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(m.posterRadius),
                      child: urls.isNotEmpty
                          ? MediaImage(
                              imageUrl: urls.first,
                              imageUrls: urls.length > 1 ? urls.sublist(1) : null,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                            )
                          : ColoredBox(
                              color: TvDesignTokens.surfaceElevated,
                              child: Icon(Icons.movie_outlined,
                                  color: TvDesignTokens.textDisabled,
                                  size: m.s(40)),
                            ),
                    ),
                  ),
                  SizedBox(height: m.spacingXs),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.fontSizeXs,
                      color: TvDesignTokens.textPrimary,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(
                  delay: Duration(milliseconds: 12 * (index % 6)),
                  duration: TvDesignTokens.contentFadeDuration,
                );
          },
        );
      },
      loading: () =>
          const Center(child: AppLoadingIndicator(size: 48, color: TvDesignTokens.brand)),
      error: (e, _) => _centerHint('加载失败：$e'),
    );
  }

  Widget _chip(TvMetrics m,
      {IconData? icon, required String label, required bool selected}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingMd,
        vertical: m.spacingXs,
      ),
      decoration: BoxDecoration(
        color: selected
            ? TvDesignTokens.brand.withValues(alpha: 0.18)
            : TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
        border:
            selected ? Border.all(color: TvDesignTokens.brand, width: 2) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: m.s(22),
                color: selected
                    ? TvDesignTokens.brand
                    : TvDesignTokens.textSecondary),
            SizedBox(width: m.spacingXs),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: m.fontSizeSm,
              color: selected ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _centerHint(String text) {
    final m = context.tv;
    return Center(
      child: Text(
        text,
        style: TextStyle(
          color: TvDesignTokens.textSecondary,
          fontSize: m.fontSizeMd,
        ),
      ),
    );
  }
}
