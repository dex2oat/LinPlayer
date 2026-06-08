import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/media_providers.dart';
import '../../widgets/desktop_media_card.dart';

/// Desktop library detail page.
class DesktopLibraryDetailScreen extends ConsumerStatefulWidget {
  final String libraryId;

  const DesktopLibraryDetailScreen({super.key, required this.libraryId});

  @override
  ConsumerState<DesktopLibraryDetailScreen> createState() =>
      _DesktopLibraryDetailScreenState();
}

class _DesktopLibraryDetailScreenState
    extends ConsumerState<DesktopLibraryDetailScreen> {
  String _sortBy = '加入日期';
  final String _sortOrder = '降序';
  final ScrollController _scrollController = ScrollController();
  bool _isGridMode = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final librariesAsync = ref.watch(librariesProvider);
    final libraryItemsAsync = ref.watch(libraryItemsProvider((
      libraryId: widget.libraryId,
      sortBy: _sortBy,
      sortOrder: _sortOrder,
    )));
    final theme = Theme.of(context);

    final libraryName = librariesAsync.maybeWhen(
      data: (libraries) {
        for (final library in libraries) {
          if (library.id == widget.libraryId) {
            return library.name;
          }
        }
        return '媒体库';
      },
      orElse: () => '媒体库',
    );

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      libraryName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _isGridMode ? '网格视图' : '列表视图',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildSortDropdown(theme),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.grid_view_rounded),
                    onPressed: () => setState(() => _isGridMode = true),
                    tooltip: '网格视图',
                    color: _isGridMode ? theme.colorScheme.primary : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.view_list_rounded),
                    onPressed: () => setState(() => _isGridMode = false),
                    tooltip: '列表视图',
                    color: !_isGridMode ? theme.colorScheme.primary : null,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildFilterChip(context, '全部'),
                  _buildFilterChip(context, '电影'),
                  _buildFilterChip(context, '剧集'),
                  _buildFilterChip(context, '动画'),
                ],
              ),
            ),
          ),
          libraryItemsAsync.when(
            data: (items) {
              if (items.isEmpty) {
                return SliverFillRemaining(
                  child: Center(
                    child: Text(
                      '这个媒体库里还没有内容',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    if (_isGridMode) {
                      const crossAxisSpacing = 18.0;
                      const mainAxisSpacing = 28.0;
                      const targetCardWidth = 144.0;

                      final availableWidth = constraints.crossAxisExtent;
                      final crossAxisCount =
                          ((availableWidth + crossAxisSpacing) /
                                  (targetCardWidth + crossAxisSpacing))
                              .floor()
                              .clamp(2, 8)
                              .toInt();
                      final actualWidth = (availableWidth -
                              crossAxisSpacing * (crossAxisCount - 1)) /
                          crossAxisCount;
                      final cardHeight = actualWidth / (2 / 3) + 42;

                      return SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: actualWidth / cardHeight,
                          crossAxisSpacing: crossAxisSpacing,
                          mainAxisSpacing: mainAxisSpacing,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final item = items[index];
                            return DesktopMediaCard(
                              item: item,
                              width: actualWidth,
                              compact: true,
                            );
                          },
                          childCount: items.length,
                        ),
                      );
                    }

                    return SliverList.separated(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return _DesktopLibraryListItem(item: item);
                      },
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 14),
                    );
                  },
                ),
              );
            },
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => SliverFillRemaining(
              child: Center(
                child: Text(
                  '加载媒体库失败',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortDropdown(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.3),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _sortBy,
          isDense: true,
          items: ['加入日期', '标题', '首映日期', '评分'].map((value) {
            return DropdownMenuItem<String>(
              value: value,
              child: Text(value, style: const TextStyle(fontSize: 13)),
            );
          }).toList(),
          onChanged: (newValue) {
            if (newValue != null) {
              setState(() {
                _sortBy = newValue;
              });
            }
          },
        ),
      ),
    );
  }

  Widget _buildFilterChip(BuildContext context, String label) {
    final theme = Theme.of(context);
    final isSelected = label == '全部';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {},
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.1)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.3)
                  : theme.dividerColor.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopLibraryListItem extends StatelessWidget {
  final MediaItem item;

  const _DesktopLibraryListItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          DesktopMediaCard(
            item: item,
            width: 72,
            height: 102,
            compact: true,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (item.type.isNotEmpty) item.type,
                    if (item.productionYear != null) '${item.productionYear}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
