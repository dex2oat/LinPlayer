import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_interfaces.dart';
import '../providers/app_providers.dart';

/// ==========================================
/// 首页数据Providers
/// ==========================================

/// 继续观看
final resumeItemsProvider = FutureProvider<List<MediaItem>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.home.getResumeItems();
});

/// 下一集
final nextUpProvider = FutureProvider<List<MediaItem>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.home.getNextUp();
});

/// 媒体库列表（已过滤被屏蔽的）
final librariesProvider = FutureProvider<List<Library>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);
  final allLibraries = await api.home.getLibraries();
  return allLibraries.where((lib) => !hiddenLibraries.contains(lib.id)).toList();
});

/// 最新添加（按媒体库）
final latestItemsProvider = FutureProvider.family<List<MediaItem>, String>((ref, libraryId) async {
  final api = ref.watch(apiClientProvider);
  return await api.home.getLatestItems(libraryId, limit: 20);
});

/// 随机推荐
final randomRecommendationsProvider = FutureProvider<List<MediaItem>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.home.getRandomRecommendations();
});

/// ==========================================
/// 媒体详情Providers
/// ==========================================

/// 媒体项详情
final mediaItemProvider = FutureProvider.family<MediaItem, String>((ref, itemId) async {
  final api = ref.watch(apiClientProvider);
  return await api.media.getItemDetails(itemId);
});

/// 相似推荐
final similarItemsProvider = FutureProvider.family<List<MediaItem>, String>((ref, itemId) async {
  final api = ref.watch(apiClientProvider);
  return await api.media.getSimilarItems(itemId);
});

/// 季列表
final seasonsProvider = FutureProvider.family<List<Season>, String>((ref, seriesId) async {
  final api = ref.watch(apiClientProvider);
  return await api.media.getSeasons(seriesId);
});

/// 集列表
final episodesProvider = FutureProvider.family<List<Episode>, ({String seriesId, String? seasonId})>(
  (ref, params) async {
    final api = ref.watch(apiClientProvider);
    return await api.media.getEpisodes(params.seriesId, seasonId: params.seasonId);
  },
);

/// 演职人员
final personsProvider = FutureProvider.family<List<Person>, String>((ref, itemId) async {
  final api = ref.watch(apiClientProvider);
  return await api.media.getPersonItems(itemId);
});

/// ==========================================
/// 媒体库详情Providers
/// ==========================================

/// 媒体库内容
final libraryItemsProvider = FutureProvider.family<List<MediaItem>, ({String libraryId, String? sortBy, String? sortOrder})>(
  (ref, params) async {
    final api = ref.watch(apiClientProvider);
    return await api.library.getLibraryItems(
      libraryId: params.libraryId,
      sortBy: params.sortBy,
      sortOrder: params.sortOrder,
    );
  },
);

/// 筛选条件
final filtersProvider = FutureProvider.family<Filters, String>((ref, libraryId) async {
  final api = ref.watch(apiClientProvider);
  return await api.library.getFilters(libraryId);
});

/// ==========================================
/// 搜索Providers
/// ==========================================

/// 搜索关键词
final searchQueryProvider = StateProvider<String>((ref) => '');

/// 聚合搜索开关
final aggregateSearchProvider = StateProvider<bool>((ref) => false);

/// 搜索结果
final searchResultsProvider = FutureProvider<List<MediaItem>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final isAggregate = ref.watch(aggregateSearchProvider);
  final hiddenLibraries = ref.watch(hiddenLibrariesProvider);

  if (query.isEmpty) return [];

  final api = ref.watch(apiClientProvider);

  List<MediaItem> results;
  if (isAggregate) {
    final aggregateResults = await api.search.searchAggregate(query);
    results = aggregateResults.values.expand((list) => list).toList();
  } else {
    results = await api.search.search(query);
  }

  // 排除被屏蔽媒体库的结果（通过parentId匹配）
  return results.where((item) {
    if (item.parentId != null && hiddenLibraries.contains(item.parentId)) return false;
    return true;
  }).toList();
});

/// 搜索历史
final searchHistoryProvider = StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
  return SearchHistoryNotifier();
});

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier() : super([]);
  
  void addQuery(String query) {
    if (query.isEmpty) return;
    state = [
      query,
      ...state.where((q) => q != query),
    ].take(20).toList();
  }
  
  void removeQuery(String query) {
    state = state.where((q) => q != query).toList();
  }
  
  void clear() {
    state = [];
  }
}

/// ==========================================
/// 播放Providers
/// ==========================================

/// 播放信息
final playbackInfoProvider = FutureProvider.family<PlaybackInfo, String>((ref, itemId) async {
  final api = ref.watch(apiClientProvider);
  return await api.playback.getPlaybackInfo(itemId);
});

/// 当前播放项
final currentPlayingItemProvider = StateProvider<MediaItem?>((ref) => null);

/// 播放进度
final playbackProgressProvider = StateProvider<double>((ref) => 0.0);

/// 播放状态
final isPlayingProvider = StateProvider<bool>((ref) => false);

/// 音量
final volumeProvider = StateProvider<double>((ref) => 1.0);

/// 播放速度
final playbackSpeedProvider = StateProvider<double>((ref) => 1.0);

/// 字幕轨道
final subtitleTrackProvider = StateProvider<int?>((ref) => null);

/// 次字幕轨道（第二个字幕）
final secondarySubtitleTrackProvider = StateProvider<int?>((ref) => null);

/// 音频轨道
final audioTrackProvider = StateProvider<int?>((ref) => null);

/// 当前选择的媒体源
final selectedMediaSourceProvider = StateProvider<String?>((ref) => null);
