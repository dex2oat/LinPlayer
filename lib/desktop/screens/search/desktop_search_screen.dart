import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/media_providers.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/desktop_media_card.dart';

/// 桌面端搜索页
class DesktopSearchScreen extends ConsumerStatefulWidget {
  const DesktopSearchScreen({super.key});

  @override
  ConsumerState<DesktopSearchScreen> createState() =>
      _DesktopSearchScreenState();
}

class _DesktopSearchScreenState extends ConsumerState<DesktopSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _resultsScrollController =
      DesktopSmoothScrollController();
  bool _isAggregateSearch = false;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.requestFocus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  void _performSearch(String query) {
    ref.read(searchQueryProvider.notifier).state = query;
    ref.read(aggregateSearchProvider.notifier).state = _isAggregateSearch;
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(searchQueryProvider);
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final searchHistory = ref.watch(searchHistoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.pop(),
                ),
                const SizedBox(width: 8),
                Text(
                  '搜索',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      hintText: '搜索电影、剧集、演员或合集',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                _performSearch('');
                                setState(() {});
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surface,
                    ),
                    onSubmitted: (value) {
                      if (value.isNotEmpty) {
                        ref.read(searchHistoryProvider.notifier).addQuery(value);
                        _performSearch(value);
                      }
                    },
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: theme.dividerColor.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('聚合搜索'),
                      const SizedBox(width: 8),
                      Switch(
                        value: _isAggregateSearch,
                        onChanged: (value) {
                          setState(() => _isAggregateSearch = value);
                          if (_searchController.text.isNotEmpty) {
                            _performSearch(_searchController.text);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (searchQuery.isEmpty && searchHistory.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '搜索历史',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () =>
                            ref.read(searchHistoryProvider.notifier).clear(),
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: searchHistory.map((query) {
                      return ActionChip(
                        label: Text(query),
                        onPressed: () {
                          _searchController.text = query;
                          _performSearch(query);
                          setState(() {});
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          const Divider(),
          Expanded(
            child: searchResultsAsync.when(
              data: (items) {
                if (searchQuery.isEmpty) {
                  return Center(
                    child: Text(
                      '输入关键词开始搜索',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  );
                }
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      '没有找到匹配结果',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  );
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    const cardWidth = 156.0;
                    const crossAxisSpacing = 20.0;
                    const mainAxisSpacing = 24.0;
                    final crossAxisCount = ((constraints.maxWidth +
                                crossAxisSpacing) /
                            (cardWidth + crossAxisSpacing))
                        .floor()
                        .clamp(2, 8);

                    return GridView.builder(
                      controller: _resultsScrollController,
                      padding: const EdgeInsets.all(24),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.66,
                        crossAxisSpacing: crossAxisSpacing,
                        mainAxisSpacing: mainAxisSpacing,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        return DesktopMediaCard(
                          item: items[index],
                          width: cardWidth,
                        );
                      },
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => Center(
                child: Text(
                  '搜索失败',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
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
