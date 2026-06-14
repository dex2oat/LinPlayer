import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/desktop_smooth_scroll.dart';
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
  static const Map<String, String> _sortMap = {
    '加入日期': 'DateCreated',
    '标题': 'SortName',
    '首映日期': 'PremiereDate',
    '评分': 'CommunityRating',
  };

  String _sortBy = 'DateCreated';
  String _sortOrder = 'Descending';
  final ScrollController _scrollController = DesktopSmoothScrollController();

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
                  _buildSortDropdown(theme),
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
                    const crossAxisSpacing = 18.0;
                    const mainAxisSpacing = 28.0;
                    const targetCardWidth = 168.0;

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
                    final cardHeight = actualWidth / (2 / 3) + 58;

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
                            titleMaxLines: 2,
                          ).appEntrance(index: index);
                        },
                        childCount: items.length,
                      ),
                    );
                  },
                ),
              );
            },
            loading: () => const SliverFillRemaining(
              child: AppLoadingIndicator(),
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
          value: _currentSortLabel,
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
                final mappedValue = _sortMap[newValue] ?? _sortBy;
                if (_sortBy == mappedValue) {
                  _sortOrder =
                      _sortOrder == 'Descending' ? 'Ascending' : 'Descending';
                } else {
                  _sortBy = mappedValue;
                  _sortOrder = 'Descending';
                }
              });
            }
          },
        ),
      ),
    );
  }

  String get _currentSortLabel {
    return _sortMap.entries
            .where((entry) => entry.value == _sortBy)
            .firstOrNull
            ?.key ??
        '加入日期';
  }
}
