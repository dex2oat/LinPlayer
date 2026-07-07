import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/library_filter_utils.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/library_filter_bar.dart';
import '../../widgets/common/media_widgets.dart';

/// 媒体库详情页
class LibraryDetailScreen extends ConsumerStatefulWidget {
  final String libraryId;
  
  const LibraryDetailScreen({super.key, required this.libraryId});
  
  @override
  ConsumerState<LibraryDetailScreen> createState() => _LibraryDetailScreenState();
}

class _LibraryDetailScreenState extends ConsumerState<LibraryDetailScreen> {
  late LibraryFilterValue _filter;

  @override
  void initState() {
    super.initState();
    // 排序从持久化偏好恢复；其它筛选（类型/标签/年份）保持每次进页面重置。
    final sort = ref.read(librarySortProvider);
    _filter = LibraryFilterValue(
      sortBy: sort.sortBy,
      sortDescending: sort.descending,
    );
  }

  void _onFilterChanged(LibraryFilterValue v) {
    setState(() => _filter = v);
    // 排序变化落盘，退出播放器返回后仍生效。
    ref.read(librarySortProvider.notifier).state =
        LibrarySortPref(sortBy: v.sortBy, descending: v.sortDescending);
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(libraryItemsProvider((
      libraryId: widget.libraryId,
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
    final filtersAsync = ref.watch(filtersProvider(widget.libraryId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体库'),
      ),
      body: Column(
        children: [
          // 筛选面板（类型/标签/工作室/时间/评分，服务端过滤）
          filtersAsync.maybeWhen(
            data: (facets) => LibraryFilterBar(
              facets: facets,
              value: _filter,
              currentYear: DateTime.now().year,
              compact: true, // 移动端：类型/标签走搜索弹窗，避免筛选面板占满屏幕
              onChanged: _onFilterChanged,
            ),
            orElse: () => const SizedBox.shrink(),
          ),

          // 内容网格
          Expanded(
            child: itemsAsync.when(
              data: (items) {
                if (items.isEmpty) {
                  return const Center(child: Text('暂无内容'));
                }
                
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.55,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                  return MediaPoster(
                      item: item,
                      width: double.infinity,
                      height: double.infinity,
                      onTap: () => context.push(mediaRouteForItem(item)),
                      heroTag: 'library_${item.id}',
                    ).appEntrance(index: index);
                  },
                );
              },
              loading: () => const AppLoadingIndicator(),
              error: (error, _) => Center(child: Text('加载失败: $error')),
            ),
          ),
        ],
      ),
    );
  }
}
