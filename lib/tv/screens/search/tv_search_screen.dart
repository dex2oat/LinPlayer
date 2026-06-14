import 'package:flutter/material.dart';
import '../../../core/theme/app_motion.dart';
import '../../theme/tv_design_tokens.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_toast.dart';

/// TV 搜索页
/// 左侧虚拟键盘 + 右侧搜索结果/搜索历史
class TvSearchScreen extends StatefulWidget {
  const TvSearchScreen({super.key});

  @override
  State<TvSearchScreen> createState() => _TvSearchScreenState();
}

class _TvSearchScreenState extends State<TvSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _query = '';
  bool _hasSearched = false;
  List<String> _searchHistory = [];

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    if (query.trim().isEmpty) return;
    setState(() {
      _query = query;
      _hasSearched = true;
      if (!_searchHistory.contains(query)) {
        _searchHistory.insert(0, query);
        if (_searchHistory.length > 20) {
          _searchHistory.removeLast();
        }
      }
    });
  }

  void _onClearHistory() {
    setState(() => _searchHistory.clear());
    TvToast.show(context, '搜索历史已清除');
  }

  void _onKeyPress(String key) {
    final text = _searchController.text;
    final selection = _searchController.selection;
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      key,
    );
    _searchController.text = newText;
    _searchController.selection = TextSelection.collapsed(
      offset: selection.start + key.length,
    );
  }

  void _onBackspace() {
    final text = _searchController.text;
    final selection = _searchController.selection;
    if (selection.start > 0) {
      final newText = text.replaceRange(
        selection.start - 1,
        selection.start,
        '',
      );
      _searchController.text = newText;
      _searchController.selection = TextSelection.collapsed(
        offset: selection.start - 1,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Row(
        children: [
          // 左侧搜索区域
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(TvDesignTokens.spacingXl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 搜索标题
                  const Text(
                    '搜索',
                    style: TextStyle(
                      fontSize: TvDesignTokens.fontSizeXxl,
                      color: TvDesignTokens.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: TvDesignTokens.spacingLg),
                  // 搜索输入框
                  TvFocusable(
                    autofocus: true,
                    onSelect: () => _searchFocusNode.requestFocus(),
                    child: Container(
                      padding: const EdgeInsets.all(TvDesignTokens.spacingMd),
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surface,
                        borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.search,
                            color: TvDesignTokens.textSecondary,
                            size: 32,
                          ),
                          const SizedBox(width: TvDesignTokens.spacingMd),
                          Expanded(
                            child: Text(
                              _searchController.text.isEmpty
                                  ? '输入搜索内容...'
                                  : _searchController.text,
                              style: TextStyle(
                                fontSize: TvDesignTokens.fontSizeMd,
                                color: _searchController.text.isEmpty
                                    ? TvDesignTokens.textDisabled
                                    : TvDesignTokens.textPrimary,
                              ),
                            ),
                          ),
                          if (_searchController.text.isNotEmpty)
                            TvFocusable(
                              onSelect: () {
                                _searchController.clear();
                                setState(() {});
                              },
                              child: const Icon(
                                Icons.clear,
                                color: TvDesignTokens.textSecondary,
                                size: 28,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: TvDesignTokens.spacingLg),
                  // 虚拟键盘
                  Expanded(
                    child: _buildVirtualKeyboard(),
                  ),
                ],
              ),
            ),
          ),
          // 右侧结果区域
          Expanded(
            flex: 3,
            child: Container(
              color: TvDesignTokens.surface,
              child: _hasSearched
                  ? _buildSearchResults()
                  : _buildSearchHistory(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVirtualKeyboard() {
    final rows = [
      ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
      ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
      ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
    ];

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ...rows.map((row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: TvDesignTokens.keyboardKeySpacing),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: row.map((key) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TvDesignTokens.keyboardKeySpacing,
                  ),
                  child: TvFocusable(
                    onSelect: () => _onKeyPress(key),
                    child: Container(
                      width: TvDesignTokens.keyboardKeyWidth,
                      height: TvDesignTokens.keyboardKeyHeight,
                      decoration: BoxDecoration(
                        color: TvDesignTokens.surfaceElevated,
                        borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                      ),
                      child: Center(
                        child: Text(
                          key.toUpperCase(),
                          style: const TextStyle(
                            fontSize: TvDesignTokens.keyboardFontSize,
                            color: TvDesignTokens.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }),
        // 功能行
        Padding(
          padding: const EdgeInsets.only(top: TvDesignTokens.spacingMd),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TvFocusable(
                onSelect: _onBackspace,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TvDesignTokens.spacingMd,
                    vertical: TvDesignTokens.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                  ),
                  child: const Icon(
                    Icons.backspace,
                    color: TvDesignTokens.textPrimary,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(width: TvDesignTokens.spacingMd),
              TvFocusable(
                onSelect: () {
                  _searchController.clear();
                  setState(() {});
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TvDesignTokens.spacingMd,
                    vertical: TvDesignTokens.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                  ),
                  child: const Text(
                    '清除',
                    style: TextStyle(
                      fontSize: TvDesignTokens.fontSizeSm,
                      color: TvDesignTokens.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: TvDesignTokens.spacingMd),
              TvFocusable(
                onSelect: () => _onSearch(_searchController.text),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TvDesignTokens.spacingLg,
                    vertical: TvDesignTokens.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.brand,
                    borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                  ),
                  child: const Text(
                    '搜索',
                    style: TextStyle(
                      fontSize: TvDesignTokens.fontSizeMd,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchHistory() {
    if (_searchHistory.isEmpty) {
      return const Center(
        child: Text(
          '暂无搜索历史',
          style: TextStyle(
            fontSize: TvDesignTokens.fontSizeMd,
            color: TvDesignTokens.textDisabled,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(TvDesignTokens.spacingLg),
      children: [
        Row(
          children: [
            const Text(
              '搜索历史',
              style: TextStyle(
                fontSize: TvDesignTokens.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            TvFocusable(
              onSelect: _onClearHistory,
              child: const Text(
                '清除全部',
                style: TextStyle(
                  fontSize: TvDesignTokens.fontSizeSm,
                  color: TvDesignTokens.brand,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: TvDesignTokens.spacingLg),
        ..._searchHistory.map((query) {
          return TvFocusable(
            onSelect: () {
              _searchController.text = query;
              _onSearch(query);
            },
            child: Container(
              padding: const EdgeInsets.all(TvDesignTokens.spacingMd),
              margin: const EdgeInsets.only(bottom: TvDesignTokens.spacingSm),
              decoration: BoxDecoration(
                color: TvDesignTokens.background,
                borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.history,
                    color: TvDesignTokens.textSecondary,
                    size: 24,
                  ),
                  const SizedBox(width: TvDesignTokens.spacingMd),
                  Expanded(
                    child: Text(
                      query,
                      style: const TextStyle(
                        fontSize: TvDesignTokens.fontSizeMd,
                        color: TvDesignTokens.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildSearchResults() {
    // TODO: 从 Provider 获取真实搜索结果
    return ListView(
      padding: const EdgeInsets.all(TvDesignTokens.spacingLg),
      children: [
        Text(
          '"$_query" 的搜索结果',
          style: const TextStyle(
            fontSize: TvDesignTokens.fontSizeLg,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: TvDesignTokens.spacingLg),
        // 占位结果
        ...List.generate(5, (index) {
          return TvFocusable(
            onSelect: () => TvToast.show(context, '选择结果 $index'),
            child: Container(
              padding: const EdgeInsets.all(TvDesignTokens.spacingMd),
              margin: const EdgeInsets.only(bottom: TvDesignTokens.spacingSm),
              decoration: BoxDecoration(
                color: TvDesignTokens.background,
                borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
              ),
              child: Row(
                children: [
                  Container(
                    width: 120,
                    height: 67,
                    decoration: BoxDecoration(
                      color: TvDesignTokens.surfaceElevated,
                      borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
                    ),
                  ),
                  const SizedBox(width: TvDesignTokens.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '搜索结果 $index',
                          style: const TextStyle(
                            fontSize: TvDesignTokens.fontSizeMd,
                            color: TvDesignTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: TvDesignTokens.spacingXs),
                        Text(
                          '电影 · 2024',
                          style: const TextStyle(
                            fontSize: TvDesignTokens.fontSizeSm,
                            color: TvDesignTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ).appEntrance(index: index);
        }),
      ],
    );
  }
}
