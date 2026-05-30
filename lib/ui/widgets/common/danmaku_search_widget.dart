import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/danmaku_filter.dart';

class DanmakuSearchContent extends ConsumerStatefulWidget {
  final MediaItem? item;
  const DanmakuSearchContent({super.key, this.item});

  @override
  ConsumerState<DanmakuSearchContent> createState() => _DanmakuSearchContentState();
}

class _DanmakuSearchContentState extends ConsumerState<DanmakuSearchContent> {
  final _searchController = TextEditingController();
  final _bgmtvIdController = TextEditingController();
  List<DanmakuAnime> _searchResults = [];
  List<DanmakuEpisode> _selectedEpisodes = [];
  DanmakuAnime? _selectedAnime;
  bool _isSearching = false;
  bool _isAutoMatching = false;
  bool _isBgmtvSearching = false;
  String? _autoMatchStatus;

  @override
  void initState() {
    super.initState();
    _tryAutoMatch();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _bgmtvIdController.dispose();
    super.dispose();
  }

  Future<void> _tryAutoMatch() async {
    final item = widget.item;
    if (item == null) return;

    final service = ref.read(danmakuServiceProvider);
    final title = item.name.isNotEmpty ? item.name : (item.seriesName ?? '');
    if (title.isEmpty) return;

    setState(() {
      _isAutoMatching = true;
      _autoMatchStatus = '正在自动匹配...';
    });

    try {
      final result = await service.matchFromAll(fileName: title);
      if (result.isMatched && result.matches.isNotEmpty) {
        final match = result.matches.first;
        if (mounted) {
          setState(() {
            _isAutoMatching = false;
            _autoMatchStatus = '已匹配: ${match.animeTitle} - ${match.episodeTitle}';
          });
          _loadComments(match.episodeId, match.animeTitle);
        }
        return;
      }
    } catch (_) {}

    try {
      final searchResult = await service.searchFromAll(title);
      if (searchResult.animes.isNotEmpty && mounted) {
        setState(() {
          _isAutoMatching = false;
          _autoMatchStatus = null;
          _searchResults = searchResult.animes;
        });
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _isAutoMatching = false;
        _autoMatchStatus = '未找到弹幕，请手动搜索';
      });
    }
  }

  Future<void> _search() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;

    setState(() => _isSearching = true);
    try {
      final service = ref.read(danmakuServiceProvider);
      final result = await service.searchFromAll(keyword);
      if (mounted) {
        setState(() {
          _searchResults = result.animes;
          _isSearching = false;
          _selectedAnime = null;
          _selectedEpisodes = [];
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _searchByBgmtvId(String idStr) async {
    final bgmtvId = int.tryParse(idStr.trim());
    if (bgmtvId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的Bangumi数字ID')),
      );
      return;
    }
    setState(() => _isBgmtvSearching = true);
    try {
      final service = ref.read(danmakuServiceProvider);
      final dandanplay = service.dandanplay;
      if (dandanplay == null) {
        if (mounted) {
          setState(() => _isBgmtvSearching = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bangumi联动仅支持弹弹Play源')),
          );
        }
        return;
      }
      final anime = await dandanplay.getBangumiByBgmtvId(bgmtvSubjectId: bgmtvId);
      if (mounted) {
        setState(() {
          _isBgmtvSearching = false;
          _selectedAnime = anime;
          _selectedEpisodes = anime.episodes ?? [];
          _searchResults = [];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isBgmtvSearching = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Bangumi搜索失败: $e')),
        );
      }
    }
  }

  Future<void> _loadComments(String episodeId, String animeTitle) async {
    final service = ref.read(danmakuServiceProvider);
    var items = await service.getCommentsFromAll(episodeId);

    final blockwords = ref.read(danmakuBlockwordsProvider);
    if (blockwords.isNotEmpty) {
      final filter = DanmakuFilter()..importBlockwords(blockwords);
      items = items.where((item) => !filter.shouldFilter(item.text, userId: item.userId)).toList();
    }

    final dedupEnabled = ref.read(danmakuDedupProvider);
    if (dedupEnabled) {
      final window = ref.read(danmakuDedupWindowProvider);
      items = _deduplicateDanmaku(items, window);
    }

    if (!mounted) return;

    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该集没有弹幕')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加载 ${items.length} 条弹幕 - $animeTitle')),
      );
      ref.read(loadedDanmakuProvider.notifier).state = items;
    }
  }

  List<DanmakuItem> _deduplicateDanmaku(List<DanmakuItem> items, double windowSeconds) {
    items.sort((a, b) => a.time.compareTo(b.time));
    final result = <DanmakuItem>[];
    final used = List<bool>.filled(items.length, false);
    for (var i = 0; i < items.length; i++) {
      if (used[i]) continue;
      var count = 1;
      for (var j = i + 1; j < items.length; j++) {
        if (used[j]) continue;
        if (items[j].time - items[i].time > windowSeconds) break;
        if (items[j].text == items[i].text && items[j].type == items[i].type) {
          count++;
          used[j] = true;
        }
      }
      result.add(DanmakuItem(
        time: items[i].time,
        text: items[i].text,
        type: items[i].type,
        color: items[i].color,
        size: items[i].size,
        source: items[i].source,
        cid: items[i].cid,
        userId: items[i].userId,
        count: count,
      ));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isAutoMatching && _autoMatchStatus != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text(_autoMatchStatus!, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
        if (!_isAutoMatching) ...[
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '搜索动漫名称',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              suffixIcon: _isSearching
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(
                      icon: const Icon(Icons.send, color: Color(0xFF5B8DEF)),
                      onPressed: _search,
                    ),
              filled: true,
              fillColor: Colors.white10,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bgmtvIdController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Bangumi条目ID (如 975)',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                    filled: true,
                    fillColor: Colors.white10,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _searchByBgmtvId(_bgmtvIdController.text),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: _isBgmtvSearching
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link, color: Color(0xFF5B8DEF), size: 20),
                onPressed: _isBgmtvSearching ? null : () => _searchByBgmtvId(_bgmtvIdController.text),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ],
          ),
          if (_autoMatchStatus != null && _searchResults.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_autoMatchStatus!, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
        ],
        if (_searchResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('搜索结果', style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 4),
          ..._searchResults.map((anime) => ListTile(
            dense: true,
            title: Text(anime.animeTitle, style: const TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              '${anime.typeDescription ?? ''} ${anime.year != null ? anime.year!.toString() : ''}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            selected: _selectedAnime?.animeId == anime.animeId,
            selectedTileColor: Colors.white10,
            onTap: () {
              setState(() {
                _selectedAnime = anime;
                _selectedEpisodes = anime.episodes ?? [];
              });
            },
          )),
        ],
        if (_selectedEpisodes.isNotEmpty) ...[
          const Divider(color: Colors.white12),
          const Text('选择集数', style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 4),
          ..._selectedEpisodes.map((ep) => ListTile(
            dense: true,
            title: Text(ep.episodeTitle, style: const TextStyle(color: Colors.white, fontSize: 14)),
            trailing: const Icon(Icons.download, color: Color(0xFF5B8DEF), size: 20),
            onTap: () => _loadComments(ep.episodeId, _selectedAnime?.animeTitle ?? ''),
          )),
        ],
      ],
    );
  }
}
