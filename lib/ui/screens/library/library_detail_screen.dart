import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/media_widgets.dart';

/// 媒体库详情页
class LibraryDetailScreen extends ConsumerStatefulWidget {
  final String libraryId;
  
  const LibraryDetailScreen({super.key, required this.libraryId});
  
  @override
  ConsumerState<LibraryDetailScreen> createState() => _LibraryDetailScreenState();
}

class _LibraryDetailScreenState extends ConsumerState<LibraryDetailScreen> {
  String? _sortBy;
  String? _sortOrder = 'Ascending';
  
  final List<Map<String, String>> _sortOptions = [
    {'value': 'DateCreated', 'label': '加入日期'},
    {'value': 'SortName', 'label': '标题'},
    {'value': 'PremiereDate', 'label': '首映日期'},
    {'value': 'OfficialRating', 'label': '官方评级'},
    {'value': 'CommunityRating', 'label': '评分'},
  ];
  
  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(libraryItemsProvider((
      libraryId: widget.libraryId,
      sortBy: _sortBy,
      sortOrder: _sortOrder,
    )));
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体库'),
      ),
      body: Column(
        children: [
          // 筛选栏
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: _sortOptions.map((option) {
                  final isSelected = _sortBy == option['value'];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(option['label']!),
                          if (isSelected)
                            Icon(
                              _sortOrder == 'Ascending' ? Icons.arrow_upward : Icons.arrow_downward,
                              size: 14,
                            ),
                        ],
                      ),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          if (isSelected) {
                            // 切换排序方向
                            _sortOrder = _sortOrder == 'Ascending' ? 'Descending' : 'Ascending';
                          } else {
                            _sortBy = option['value'];
                            _sortOrder = 'Ascending';
                          }
                        });
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
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
