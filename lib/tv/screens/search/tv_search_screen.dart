import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/server_group_header.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_media_card.dart';
import '../../widgets/tv_poster_card.dart';
import '../../widgets/tv_text_field.dart';

/// TV / Pad 搜索页
///
/// 观感对齐移动端 [SearchScreen]：搜索栏 → 历史标签 → 结果（普通=海报网格；
/// 聚合=每服务器一组 [ServerGroupHeader] + 横向海报行），交互换成焦点驱动。
/// 直接使用系统输入法（支持中文与语音输入），不再内置软键盘。
class TvSearchScreen extends ConsumerStatefulWidget {
  const TvSearchScreen({super.key});

  @override
  ConsumerState<TvSearchScreen> createState() => _TvSearchScreenState();
}

class _TvSearchScreenState extends ConsumerState<TvSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();
  bool _hasSearched = false;

  @override
  void dispose() {
    _searchController.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    ref.read(searchQueryProvider.notifier).state = q;
    ref.read(searchHistoryProvider.notifier).addQuery(q);
    setState(() => _hasSearched = true);
  }

  void _clear() {
    _searchController.clear();
    ref.read(searchQueryProvider.notifier).state = '';
    setState(() => _hasSearched = false);
    _fieldFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(m.spacingXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '搜索',
                style: TextStyle(
                  fontSize: m.fontSizeXxl,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: m.spacingLg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: _buildSearchField(m)),
                  SizedBox(width: m.spacingMd),
                  _buildAggregateToggle(m),
                ],
              ),
              SizedBox(height: m.spacingLg),
              Expanded(
                child: _hasSearched
                    ? _buildSearchResults(m)
                    : _buildSearchHistory(m),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 聚合搜索开关：开启后跨所有已登录服务器并行搜索并合并结果。
  Widget _buildAggregateToggle(TvMetrics m) {
    final isAggregate = ref.watch(aggregateSearchProvider);
    return TvFocusable(
      padding: const EdgeInsets.all(4),
      onSelect: () =>
          ref.read(aggregateSearchProvider.notifier).state = !isAggregate,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.spacingMd,
          vertical: m.spacingSm,
        ),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
          border: Border.all(
            color: isAggregate
                ? TvDesignTokens.brand
                : TvDesignTokens.textDisabled,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isAggregate ? Icons.check_box : Icons.check_box_outline_blank,
              color: isAggregate
                  ? TvDesignTokens.brand
                  : TvDesignTokens.textSecondary,
              size: m.s(24),
            ),
            SizedBox(width: m.spacingSm),
            Text(
              '聚合搜索',
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(TvMetrics m) {
    final hasText = _searchController.text.isNotEmpty;
    return TvTextField(
      controller: _searchController,
      focusNode: _fieldFocus,
      autofocus: true,
      hint: '搜索影片、剧集……（支持中文 / 语音输入）',
      textInputAction: TextInputAction.search,
      onSubmitted: _submit,
      onChanged: (_) => setState(() {}),
      prefixIcon: Icon(Icons.search,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
      suffixIcon: hasText
          ? IconButton(
              icon: Icon(Icons.close,
                  color: TvDesignTokens.textSecondary, size: m.s(26)),
              onPressed: _clear,
            )
          : null,
    );
  }

  Widget _buildSearchHistory(TvMetrics m) {
    final history = ref.watch(searchHistoryProvider);
    if (history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search,
                size: m.s(64), color: TvDesignTokens.textDisabled),
            SizedBox(height: m.spacingMd),
            Text(
              '输入关键词开始搜索',
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textDisabled,
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      children: [
        Row(
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            TvFocusable(
              padding: const EdgeInsets.all(6),
              onSelect: () => ref.read(searchHistoryProvider.notifier).clear(),
              child: Text(
                '清除全部',
                style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.brand,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: m.spacingMd),
        Wrap(
          spacing: m.spacingSm,
          runSpacing: m.spacingSm,
          children: [
            for (final query in history)
              TvFocusable(
                padding: const EdgeInsets.all(4),
                onSelect: () {
                  _searchController.text = query;
                  _submit(query);
                },
                // 菜单键 / 长按删除单条历史（对齐移动端 InputChip 的删除）。
                onLongPress: () =>
                    ref.read(searchHistoryProvider.notifier).removeQuery(query),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingMd,
                    vertical: m.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surface,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history,
                          color: TvDesignTokens.textSecondary, size: m.s(22)),
                      SizedBox(width: m.spacingSm),
                      Text(
                        query,
                        style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSearchResults(TvMetrics m) {
    if (ref.watch(aggregateSearchProvider)) return _buildAggregateResults(m);
    final resultsAsync = ref.watch(searchResultsProvider);
    final query = ref.watch(searchQueryProvider);

    return resultsAsync.when(
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              '未找到“$query”的结果',
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textDisabled,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“$query” 的搜索结果（${items.length}）',
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingMd),
            Expanded(
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: m.posterWidth2_3,
                  childAspectRatio: 2 / 3.4,
                  crossAxisSpacing: m.posterSpacing,
                  mainAxisSpacing: m.posterSpacing,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return TvMediaCard(
                    item: item,
                    autofocus: index == 0,
                    onSelect: () => _openResult(item),
                  ).animate().fadeIn(
                        delay: Duration(milliseconds: 20 * (index % 8)),
                        duration: TvDesignTokens.contentFadeDuration,
                      );
                },
              ),
            ),
          ],
        );
      },
      loading: () => const Center(
        child: AppLoadingIndicator(size: 48, color: TvDesignTokens.brand),
      ),
      error: (e, _) => Center(
        child: Text(
          '搜索失败：$e',
          style: TextStyle(
            fontSize: m.fontSizeSm,
            color: TvDesignTokens.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 聚合搜索：每台服务器一组（[ServerGroupHeader]），下面封面横向排列，
  /// 遥控器左右切换浏览、上下跨行。跨服务器结果的封面必须用来源服务器解析。
  Widget _buildAggregateResults(TvMetrics m) {
    final aggregateAsync = ref.watch(aggregateSearchResultsProvider);
    return aggregateAsync.when(
      loading: () => const Center(
        child: AppLoadingIndicator(size: 48, color: TvDesignTokens.brand),
      ),
      error: (e, _) => Center(
        child: Text('搜索失败：$e',
            style: TextStyle(
                fontSize: m.fontSizeSm, color: TvDesignTokens.textSecondary)),
      ),
      data: (aggregateData) {
        if (aggregateData.isEmpty) {
          return Center(
            child: Text('没有找到结果',
                style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.textDisabled)),
          );
        }
        final servers = aggregateData.keys.toList(growable: false);
        return ListView(
          children: [
            for (var s = 0; s < servers.length; s++)
              _buildAggregateRow(
                  m, servers[s], aggregateData[servers[s]]!, s == 0),
          ],
        );
      },
    );
  }

  Widget _buildAggregateRow(
      TvMetrics m, String serverName, List<MediaItem> items, bool first) {
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ServerGroupHeader(
            serverId: items.first.sourceServerId,
            serverName: serverName,
            iconSize: m.s(32),
          ),
          SizedBox(height: m.spacingMd),
          SizedBox(
            height: m.posterHeight2_3 + m.s(56),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              itemBuilder: (_, i) =>
                  _buildAggregatePoster(m, items[i], first && i == 0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAggregatePoster(TvMetrics m, MediaItem item, bool autofocus) {
    // 跨服务器：用来源服务器解析封面（不能走默认 apiClientProvider / MediaPoster）。
    final api = apiClientForItem(ref, item);
    final urls = resolveMediaItemImageUrls(api, item, maxWidth: 320);
    return TvFocusable(
      autofocus: autofocus,
      padding: EdgeInsets.all(m.spacingSm),
      onSelect: () => _openResult(item),
      child: TvPosterCard(
        imageUrl: urls.isNotEmpty ? urls.first : null,
        title: item.name,
        subtitle: _resultSubtitle(item),
        width: m.posterWidth2_3,
        height: m.posterHeight2_3,
      ),
    );
  }

  /// 打开一条结果：聚合搜索的跨服务器结果先把当前服务器切到来源服务器，再走
  /// TV 详情路由，否则详情页用错服务器取 itemId 会失败。
  void _openResult(MediaItem item) {
    final origin = item.sourceServerId;
    if (origin != null && origin != ref.read(currentServerProvider)?.id) {
      ref.read(currentServerProvider.notifier).syncWithAvailableServers(
            ref.read(serverListProvider),
            preferredServerId: origin,
          );
    }
    context.push('/tv/detail/${item.id}');
  }

  String _resultSubtitle(MediaItem item) {
    final type = switch (item.type) {
      'Movie' => '电影',
      'Series' => '剧集',
      'Episode' => '单集',
      _ => item.type,
    };
    final parts = <String>[type];
    if (item.productionYear != null) parts.add('${item.productionYear}');
    return parts.join(' · ');
  }
}
