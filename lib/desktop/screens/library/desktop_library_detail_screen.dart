import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/library_filter_utils.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/widgets/common/library_filter_bar.dart';
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
  LibraryFilterValue _filter = const LibraryFilterValue();
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
      sortBy: 'SortName',
      sortOrder: 'Ascending',
      genres: _filter.genre,
      tags: _filter.tag,
      studioIds: _filter.studioId,
      years: _filter.yearsCsv,
      ratingMin: _filter.ratingMin,
      ratingMax: _filter.ratingMax,
    )));
    final filtersAsync = ref.watch(filtersProvider(widget.libraryId));
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
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: filtersAsync.when(
              data: (facets) => LibraryFilterBar(
                facets: facets,
                value: _filter,
                currentYear: DateTime.now().year,
                onChanged: (v) => setState(() => _filter = v),
              ),
              // 加载/失败不再静默隐藏，明确显示状态便于排查"看不到筛选"的归因。
              loading: () => const Padding(
                padding: EdgeInsets.fromLTRB(24, 6, 24, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('筛选项加载中…',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
                child: Text('筛选项加载失败：$e',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.error)),
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

}
