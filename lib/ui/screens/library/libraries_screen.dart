import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/common/media_widgets.dart';

enum LibraryViewMode { grid, list }

/// 媒体库列表页面
class LibrariesScreen extends ConsumerStatefulWidget {
  const LibrariesScreen({super.key});

  @override
  ConsumerState<LibrariesScreen> createState() => _LibrariesScreenState();
}

class _LibrariesScreenState extends ConsumerState<LibrariesScreen> {
  LibraryViewMode _viewMode = LibraryViewMode.grid;
  final Set<String> _selectedLibraryIds = {};
  bool _isSelecting = false;

  void _toggleSelection(String libraryId) {
    setState(() {
      if (_selectedLibraryIds.contains(libraryId)) {
        _selectedLibraryIds.remove(libraryId);
      } else {
        _selectedLibraryIds.add(libraryId);
      }
    });
  }

  void _applyBlock() {
    if (_selectedLibraryIds.isEmpty) return;
    final notifier = ref.read(hiddenLibrariesProvider.notifier);
    for (final id in _selectedLibraryIds) {
      notifier.toggle(id);
    }
    setState(() {
      _isSelecting = false;
      _selectedLibraryIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已屏蔽选中的媒体库')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final librariesAsync = ref.watch(librariesProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('媒体库'),
        actions: [
          // 屏蔽按钮
          if (_isSelecting) ...[
            TextButton(
              onPressed: () {
                setState(() {
                  _isSelecting = false;
                  _selectedLibraryIds.clear();
                });
              },
              child: const Text('取消'),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _selectedLibraryIds.isNotEmpty ? _applyBlock : null,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('屏蔽'),
              ),
            ),
          ] else ...[
            // 切换显示模式
            IconButton(
              icon: Icon(
                _viewMode == LibraryViewMode.grid
                    ? Icons.view_list
                    : Icons.grid_view,
              ),
              onPressed: () {
                setState(() {
                  _viewMode = _viewMode == LibraryViewMode.grid
                      ? LibraryViewMode.list
                      : LibraryViewMode.grid;
                });
              },
            ),
            // 屏蔽选择按钮
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonal(
                onPressed: () {
                  setState(() {
                    _isSelecting = true;
                  });
                },
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('屏蔽'),
              ),
            ),
          ],
        ],
      ),
      body: librariesAsync.when(
        data: (libraries) {
          if (libraries.isEmpty) {
            return const Center(child: Text('暂无媒体库'));
          }

          if (_viewMode == LibraryViewMode.grid) {
            return _GridView(
              libraries: libraries,
              isSelecting: _isSelecting,
              selectedIds: _selectedLibraryIds,
              onToggleSelection: _toggleSelection,
              onTap: (library) {
                if (_isSelecting) {
                  _toggleSelection(library.id);
                } else {
                  context.push('/library/${library.id}');
                }
              },
            );
          } else {
            return _ListView(
              libraries: libraries,
              isSelecting: _isSelecting,
              selectedIds: _selectedLibraryIds,
              onToggleSelection: _toggleSelection,
              onTap: (library) {
                if (_isSelecting) {
                  _toggleSelection(library.id);
                } else {
                  context.push('/library/${library.id}');
                }
              },
            );
          }
        },
        loading: () => const AppLoadingIndicator(),
        error: (error, _) => Center(child: Text('加载失败: $error')),
      ),
    );
  }
}

class _GridView extends ConsumerWidget {
  final List<Library> libraries;
  final bool isSelecting;
  final Set<String> selectedIds;
  final Function(String) onToggleSelection;
  final Function(Library) onTap;

  const _GridView({
    required this.libraries,
    required this.isSelecting,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: libraries.length,
      itemBuilder: (context, index) {
        final library = libraries[index];
        final isSelected = selectedIds.contains(library.id);
        final imageUrl = library.primaryImageTag != null
            ? api.image.getPrimaryImageUrl(library.id,
                tag: library.primaryImageTag, maxWidth: 400)
            : null;
        final borderRadius = BorderRadius.circular(16);

        return GestureDetector(
          onTap: () => onTap(library),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: borderRadius,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: imageUrl != null
                          ? ColoredBox(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: SizedBox.expand(
                                child: Transform.scale(
                                  scale: 1.04,
                                  child: MediaImage(
                                    imageUrl: imageUrl,
                                    width: double.infinity,
                                    height: double.infinity,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                              child: const Center(
                                child: Icon(
                                  Icons.folder,
                                  size: 48,
                                  color: Color(0xFF5B8DEF),
                                ),
                              ),
                            ),
                    ),
                    if (isSelecting)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF5B8DEF)
                                : Colors.white.withValues(alpha: 0.8),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isSelected ? Icons.check : null,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                library.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ).appEntrance(index: index);
      },
    );
  }
}

class _ListView extends StatelessWidget {
  final List<Library> libraries;
  final bool isSelecting;
  final Set<String> selectedIds;
  final Function(String) onToggleSelection;
  final Function(Library) onTap;

  const _ListView({
    required this.libraries,
    required this.isSelecting,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: libraries.length,
      itemBuilder: (context, index) {
        final library = libraries[index];
        final isSelected = selectedIds.contains(library.id);

        return ListTile(
          leading: Icon(
            library.collectionType == 'movies' ? Icons.movie : Icons.tv,
            color: const Color(0xFF5B8DEF),
          ),
          title: Text(library.name),
          trailing: isSelecting
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => onToggleSelection(library.id),
                )
              : const Icon(Icons.chevron_right),
          onTap: () => onTap(library),
        );
      },
    );
  }
}
