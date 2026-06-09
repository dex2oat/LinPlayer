import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/video_player_service.dart';

/// 桌面端播放器 - 全新设计
///
/// 专为桌面端（Windows/Linux）优化的沉浸式播放器界面：
/// - 独立的桌面控制栏布局（顶栏、底栏、侧边浮动按钮）
/// - 鼠标移动自动显示/隐藏控制栏
/// - 丰富的键盘快捷键支持
/// - 视频区域热区点击交互
class DesktopPlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final String? mediaSourceId;

  const DesktopPlayerScreen({
    super.key,
    required this.itemId,
    this.mediaSourceId,
  });

  @override
  ConsumerState<DesktopPlayerScreen> createState() => _DesktopPlayerScreenState();
}

class _DesktopPlayerScreenState extends ConsumerState<DesktopPlayerScreen> {
  late VideoPlayerService _playerService;
  final FocusNode _focusNode = FocusNode();
  bool _initializingPlayer = false;
  bool _autoPlayAttempted = false;

  // 控制栏显隐状态
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // 全屏状态
  bool _isFullscreen = false;

  // 倍速按钮长按状态
  bool _isSpeedLongPressing = false;
  Timer? _speedLongPressTimer;

  // 跳过片头按钮
  bool _showSkipButton = false;
  Timer? _skipButtonTimer;

  // 鼠标是否在控制栏区域内
  bool _mouseInControlsArea = false;

  // 音量滑块显示
  bool _showVolumeSlider = false;
  Timer? _volumeSliderTimer;

  // 统计信息显示
  bool _showStatsOverlay = false;
  Map<String, String> _playbackStats = {};
  Timer? _statsRefreshTimer;

  @override
  void initState() {
    super.initState();
    _playerService = VideoPlayerService();
    _playerService.addListener(_onPlayerUpdate);
    _initializePlayer();
    _focusNode.requestFocus();
  }

  void _onPlayerUpdate() {
    if (!_autoPlayAttempted &&
        !_initializingPlayer &&
        _playerService.isInitialized &&
        !_playerService.isPlaying &&
        !_playerService.hasError) {
      _autoPlayAttempted = true;
      unawaited(_playerService.play());
    }
    setState(() {});
    _checkSkipOpening();
  }

  void _checkSkipOpening() {
    final openingStart = ref.read(skipOpeningStartProvider);
    final openingEnd = ref.read(skipOpeningEndProvider);
    final autoSkip = ref.read(skipAutoModeProvider);
    if (openingStart <= 0 || openingEnd <= 0 || openingEnd <= openingStart) return;

    final pos = _playerService.position.inSeconds;
    final inOpening = pos >= openingStart && pos < openingEnd;

    if (inOpening && autoSkip) {
      _playerService.seekTo(Duration(seconds: openingEnd));
    } else if (inOpening && !_showSkipButton) {
      setState(() => _showSkipButton = true);
      _skipButtonTimer?.cancel();
      _skipButtonTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _showSkipButton = false);
      });
    } else if (!inOpening && _showSkipButton) {
      setState(() => _showSkipButton = false);
      _skipButtonTimer?.cancel();
    }
  }

  Future<void> _initializePlayer() async {
    if (_initializingPlayer) return;
    _initializingPlayer = true;
    _autoPlayAttempted = false;
    final api = ref.read(apiClientProvider);
    try {
      final item = await api.media.getItemDetails(widget.itemId);

      final playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
      final mediaSource = _resolveMediaSource(playbackInfo);
      final videoStream = mediaSource?.mediaStreams.where((s) => s.isVideo).firstOrNull;

      final videoUrl = api.playback.getVideoStreamUrl(
        widget.itemId,
        mediaSourceId: mediaSource?.id,
        container: mediaSource?.container ?? videoStream?.codec,
        playSessionId: '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
      );

      Duration? startPosition;
      if (item.userData?.playbackPositionTicks != null) {
        startPosition = Duration(
          milliseconds: (item.userData!.playbackPositionTicks! / 10000).round(),
        );
      }

      ref.read(currentPlayingItemProvider.notifier).state = item;
      ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;

      final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
      final coreType = coreString == 'mpv' ? PlayerCoreType.mpv : PlayerCoreType.exoPlayer;

      final dolbyVisionFix = coreType == PlayerCoreType.mpv ? ref.read(mpvDolbyVisionFixProvider) : false;
      final useLibass = coreType == PlayerCoreType.exoPlayer ? ref.read(exoLibassProvider) : false;
      final preferredSubtitleLanguage = ref.read(preferredSubtitleLanguageProvider);

      await _playerService.initialize(
        videoUrl: videoUrl,
        itemId: widget.itemId,
        mediaSourceId: mediaSource?.id,
        startPosition: startPosition,
        coreType: coreType,
        dolbyVisionFix: dolbyVisionFix,
        useLibass: useLibass,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        onStart: (info) async {
          try { await api.playback.reportPlaybackStart(info); } catch (_) {}
        },
        onProgress: (info) async {
          try { await api.playback.reportPlaybackProgress(info); } catch (_) {}
        },
        onStop: (info) async {
          try { await api.playback.reportPlaybackStopped(info); } catch (_) {}
        },
      );

      _playerService.setSubtitleSize(ref.read(subtitleSizeProvider));
      _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider));
      _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider));
      _playerService.setSubtitleFont(ref.read(subtitleFontProvider));
      _playerService.setSubtitleBackground(ref.read(subtitleBackgroundProvider));
      _playerService.setAspectRatio(ref.read(aspectRatioProvider));

      final audioStreams = mediaSource?.mediaStreams.where((s) => s.isAudio).toList() ?? [];
      final selectedAudioIndex = ref.read(audioTrackProvider);
      if (selectedAudioIndex != null) {
        await _applyInitialAudioTrack(audioStreams, selectedAudioIndex);
      }

      final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
      if (selectedSubtitleIndex != null) {
        await _applyInitialSubtitleTrack(selectedSubtitleIndex);
      }

      await _playerService.play();
      _autoPlayAttempted = true;
      _startHideControlsTimer();
    } finally {
      _initializingPlayer = false;
    }
  }

  MediaSource? _resolveMediaSource(PlaybackInfo playbackInfo) {
    final mediaSources = playbackInfo.mediaSources;
    if (mediaSources.isEmpty) return null;

    final targetSourceId = widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider);
    if (targetSourceId == null || targetSourceId.isEmpty) {
      return mediaSources.firstOrNull;
    }
    return mediaSources.where((s) => s.id == targetSourceId).firstOrNull ?? mediaSources.firstOrNull;
  }

  Future<void> _applyInitialAudioTrack(List<MediaStream> audioStreams, int selectedIndex) async {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    final position = audioStreams.indexWhere((s) => s.index == selectedIndex);
    if (position < 0 || position >= audioTracks.length) return;
    final trackId = audioTracks[position]['id']?.toString();
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  Future<void> _applyInitialSubtitleTrack(int selectedIndex) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) => t['type'] == 'subtitle').toList();
    if (selectedIndex < 0 || selectedIndex >= subtitleTracks.length) return;
    final trackId = subtitleTracks[selectedIndex]['id']?.toString();
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectSubtitleTrack(trackId);
    }
  }

  // ========== 控制栏显隐 ==========

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (_playerService.isPlaying && !_mouseInControlsArea && mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _cancelHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  void _onMouseMoved() {
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    if (_playerService.isPlaying) {
      _startHideControlsTimer();
    }
  }

  // ========== 键盘快捷键 ==========

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
        _playerService.togglePlay();
        break;
      case LogicalKeyboardKey.arrowLeft:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _playerService.seekBy(const Duration(seconds: -60));
        } else {
          _playerService.seekBy(const Duration(seconds: -15));
        }
        break;
      case LogicalKeyboardKey.arrowRight:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _playerService.seekBy(const Duration(seconds: 60));
        } else {
          _playerService.seekBy(const Duration(seconds: 15));
        }
        break;
      case LogicalKeyboardKey.keyJ:
        _playerService.seekBy(const Duration(seconds: -15));
        break;
      case LogicalKeyboardKey.keyL:
        _playerService.seekBy(const Duration(seconds: 15));
        break;
      case LogicalKeyboardKey.arrowUp:
        _adjustVolume(0.05);
        break;
      case LogicalKeyboardKey.arrowDown:
        _adjustVolume(-0.05);
        break;
      case LogicalKeyboardKey.bracketLeft:
        _adjustSpeed(-0.25);
        break;
      case LogicalKeyboardKey.bracketRight:
        _adjustSpeed(0.25);
        break;
      case LogicalKeyboardKey.backspace:
        _playerService.setSpeed(1.0);
        break;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.keyS:
        _cycleSubtitleTrack();
        break;
      case LogicalKeyboardKey.keyA:
        _cycleAudioTrack();
        break;
      case LogicalKeyboardKey.keyM:
        _toggleMute();
        break;
      case LogicalKeyboardKey.controlLeft:
      case LogicalKeyboardKey.controlRight:
        break;
      default:
        if (event.logicalKey == LogicalKeyboardKey.keyH && HardwareKeyboard.instance.isControlPressed) {
          _toggleControlsVisibility();
        } else if (event.logicalKey == LogicalKeyboardKey.keyS && HardwareKeyboard.instance.isControlPressed) {
          _takeScreenshot();
        }
    }
  }

  void _adjustVolume(double delta) {
    final newVolume = (_playerService.volume + delta).clamp(0.0, 1.0);
    _playerService.setVolume(newVolume);
  }

  void _adjustSpeed(double delta) {
    final newSpeed = (_playerService.speed + delta).clamp(0.25, 4.0);
    _playerService.setSpeed(newSpeed);
  }

  void _toggleMute() {
    if (_playerService.volume > 0) {
      _playerService.setVolume(0.0);
    } else {
      _playerService.setVolume(1.0);
    }
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    // TODO: 使用 window_manager 实现真正的窗口全屏
  }

  void _toggleControlsVisibility() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _startHideControlsTimer();
    }
  }

  void _cycleSubtitleTrack() {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) => t['type'] == 'subtitle').toList();
    if (subtitleTracks.isEmpty) return;

    final currentIndex = subtitleTracks.indexWhere((t) => t['selected'] == true);
    final nextIndex = (currentIndex + 1) % (subtitleTracks.length + 1);

    if (nextIndex >= subtitleTracks.length) {
      _playerService.deselectSubtitleTrack();
    } else {
      final trackId = subtitleTracks[nextIndex]['id']?.toString();
      if (trackId != null) _playerService.selectSubtitleTrack(trackId);
    }
  }

  void _cycleAudioTrack() {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    if (audioTracks.length <= 1) return;

    final currentIndex = audioTracks.indexWhere((t) => t['selected'] == true);
    final nextIndex = (currentIndex + 1) % audioTracks.length;
    final trackId = audioTracks[nextIndex]['id']?.toString();
    if (trackId != null) _playerService.selectAudioTrack(trackId);
  }

  // ========== 截图 ==========

  Future<void> _takeScreenshot() async {
    try {
      final data = await _playerService.screenshot();
      if (!mounted) return;
      if (data != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图已保存')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图功能暂不支持当前播放器内核')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图失败: $e')),
        );
      }
    }
  }

  // ========== 视频热区 ==========

  void _onVideoTapUp(TapUpDetails details) {
    final width = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < width * 0.25) {
      _playerService.seekBy(const Duration(seconds: -15));
    } else if (tapX > width * 0.75) {
      _playerService.seekBy(const Duration(seconds: 15));
    } else {
      _playerService.togglePlay();
    }
  }

  // ========== 倍速长按 ==========

  void _onSpeedButtonDown(bool increase) {
    _adjustSpeed(increase ? 0.25 : -0.25);
    _isSpeedLongPressing = true;
    _speedLongPressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_isSpeedLongPressing) {
        _adjustSpeed(increase ? 0.05 : -0.05);
      }
    });
  }

  void _onSpeedButtonUp() {
    _isSpeedLongPressing = false;
    _speedLongPressTimer?.cancel();
    _speedLongPressTimer = null;
  }

  // ========== 上一集/下一集 ==========

  Future<void> _playPrevious() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return;
    try {
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
        currentItem!.seriesId!,
        seasonId: currentItem.seasonId,
      );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex > 0) {
        if (mounted) context.replace('/player/${episodes[currentIndex - 1].id}');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是第一集了')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  Future<void> _playNext() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return;
    try {
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
        currentItem!.seriesId!,
        seasonId: currentItem.seasonId,
      );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
        if (mounted) context.replace('/player/${episodes[currentIndex + 1].id}');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是最后一集了')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  // ========== Anime4K ==========

  Future<void> _showAnime4KMenu() async {
    final currentLevel = ref.read(anime4KLevelProvider);
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _Anime4KLevelDialog(currentLevel: currentLevel),
    );
    if (result != null && mounted) {
      ref.read(anime4KLevelProvider.notifier).state = result;
      if (result == 'off') {
        await _playerService.applySuperResolution(false);
      } else {
        await _playerService.applySuperResolutionLevel(result);
      }
    }
  }

  // ========== 跳过片头 ==========

  void _onSkipOpeningPressed() {
    final openingEnd = ref.read(skipOpeningEndProvider);
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  // ========== 更多菜单 ==========

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _MoreMenuSheet(
        onShowAspectRatio: _showAspectRatioDialog,
        onToggleStats: _toggleStatsOverlay,
      ),
    );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自动', '16:9', '4:3', '21:9', '全屏', '原始'];
    final currentRatio = ref.read(aspectRatioProvider);

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('画面比例', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const Divider(color: Colors.white12, height: 1),
              ...ratios.map((ratio) => ListTile(
                title: Text(ratio, style: const TextStyle(color: Colors.white)),
                trailing: currentRatio == ratio
                    ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                    : null,
                onTap: () {
                  ref.read(aspectRatioProvider.notifier).state = ratio;
                  _playerService.setAspectRatio(ratio);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('画面比例: $ratio')),
                  );
                },
              )),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 选集弹窗 ==========

  void _showEpisodeSelector() {
    final item = ref.read(currentPlayingItemProvider);
    if (item?.seriesId == null) return;

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _EpisodeSelectorDialog(
        seriesId: item!.seriesId!,
        currentEpisodeId: item.id,
        currentMediaSourceId: ref.read(selectedMediaSourceProvider),
      ),
    );
  }

  // ========== 字幕/音轨弹窗 ==========

  void _showSubtitleSelector() {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks.where((t) => t['type'] == 'subtitle').toList();
    _showTrackSelectorDialog('字幕选择', subtitleTracks, (trackId) {
      _playerService.selectSubtitleTrack(trackId);
    }, canDisable: true);
  }

  void _showAudioSelector() {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    _showTrackSelectorDialog('音轨选择', audioTracks, (trackId) {
      _playerService.selectAudioTrack(trackId);
    });
  }

  void _showTrackSelectorDialog(
    String title,
    List<Map<String, dynamic>> tracks,
    void Function(String trackId) onSelect, {
    bool canDisable = false,
  }) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: canDisable ? tracks.length + 1 : tracks.length,
                  itemBuilder: (context, index) {
                    if (canDisable && index == 0) {
                      final isSelected = tracks.every((t) => t['selected'] != true);
                      return ListTile(
                        title: const Text('关闭字幕', style: TextStyle(color: Colors.white)),
                        trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF5B8DEF)) : null,
                        onTap: () {
                          _playerService.deselectSubtitleTrack();
                          Navigator.pop(context);
                        },
                      );
                    }
                    final trackIndex = canDisable ? index - 1 : index;
                    final track = tracks[trackIndex];
                    final isSelected = track['selected'] == true;
                    final label = track['title']?.toString() ?? track['language']?.toString() ?? '轨道 ${trackIndex + 1}';
                    return ListTile(
                      title: Text(label, style: const TextStyle(color: Colors.white)),
                      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF5B8DEF)) : null,
                      onTap: () {
                        final trackId = track['id']?.toString();
                        if (trackId != null) onSelect(trackId);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 格式化时间 ==========

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // ========== 鼠标滚轮音量 ==========

  void _onMouseWheelScroll(PointerScrollEvent event) {
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    _adjustVolume(delta);
  }

  // ========== 统计信息行 ==========

  List<Widget> _buildStatsRows() {
    final rows = <Widget>[];

    // 文件信息
    final path = _playbackStats['path'] ?? '';
    if (path.isNotEmpty) {
      rows.add(_buildStatRow('文件', path.split('/').last.split('\\').last));
    }

    final fileSize = _playbackStats['file-size'];
    if (fileSize != null && fileSize != 'null') {
      final size = int.tryParse(fileSize);
      if (size != null) {
        rows.add(_buildStatRow('大小', _formatFileSize(size)));
      }
    }

    // 视频信息
    final width = _playbackStats['width'];
    final height = _playbackStats['height'];
    if (width != null && height != null) {
      rows.add(_buildStatRow('分辨率', '$width x $height'));
    }

    final fps = _playbackStats['container-fps'] ?? _playbackStats['fps'];
    if (fps != null) {
      rows.add(_buildStatRow('帧率', '$fps fps'));
    }

    final videoBitrate = _playbackStats['video-bitrate'];
    if (videoBitrate != null) {
      final bitrate = int.tryParse(videoBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('视频码率', _formatBitrate(bitrate)));
      }
    }

    final videoCodec = _playbackStats['video-codec'] ?? _playbackStats['current-tracks/video/codec'];
    if (videoCodec != null && videoCodec.isNotEmpty) {
      rows.add(_buildStatRow('视频编码', videoCodec));
    }

    final pixelFormat = _playbackStats['video-params/pixelformat'];
    if (pixelFormat != null && pixelFormat.isNotEmpty) {
      rows.add(_buildStatRow('像素格式', pixelFormat));
    }

    // 音频信息
    final audioCodec = _playbackStats['audio-codec'] ?? _playbackStats['current-tracks/audio/codec'];
    if (audioCodec != null && audioCodec.isNotEmpty) {
      rows.add(_buildStatRow('音频编码', audioCodec));
    }

    final audioBitrate = _playbackStats['audio-bitrate'];
    if (audioBitrate != null) {
      final bitrate = int.tryParse(audioBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('音频码率', _formatBitrate(bitrate)));
      }
    }

    final sampleRate = _playbackStats['audio-params/sample-rate'];
    if (sampleRate != null) {
      rows.add(_buildStatRow('采样率', '${sampleRate}Hz'));
    }

    final channels = _playbackStats['audio-params/channel-count'];
    if (channels != null) {
      rows.add(_buildStatRow('声道', '${channels}ch'));
    }

    // 渲染信息
    final hwdec = _playbackStats['hwdec-current'];
    if (hwdec != null && hwdec.isNotEmpty && hwdec != 'no') {
      rows.add(_buildStatRow('硬解', hwdec));
    }

    final voFps = _playbackStats['estimated-vf-fps'];
    if (voFps != null) {
      rows.add(_buildStatRow('渲染帧率', '${voFps}fps'));
    }

    final dropCount = _playbackStats['frame-drop-count'] ?? _playbackStats['vo-drop-frame-count'];
    if (dropCount != null && dropCount != '0') {
      rows.add(_buildStatRow('丢帧', dropCount));
    }

    final cacheDuration = _playbackStats['demuxer-cache-duration'];
    if (cacheDuration != null) {
      rows.add(_buildStatRow('缓冲', '${cacheDuration}s'));
    }

    // 播放状态
    rows.add(_buildStatRow('速度', '${_playerService.speed.toStringAsFixed(2)}x'));
    rows.add(_buildStatRow('位置', '${_formatDuration(_playerService.position)} / ${_formatDuration(_playerService.duration)}'));

    return rows;
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        Text(value),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _formatBitrate(int bps) {
    if (bps < 1000) return '${bps}bps';
    if (bps < 1000000) return '${(bps / 1000).toStringAsFixed(0)}Kbps';
    return '${(bps / 1000000).toStringAsFixed(2)}Mbps';
  }

  // ========== 生命周期 ==========

  @override
  void dispose() {
    _cancelHideControlsTimer();
    _skipButtonTimer?.cancel();
    _speedLongPressTimer?.cancel();
    _volumeSliderTimer?.cancel();
    _statsRefreshTimer?.cancel();
    _focusNode.dispose();
    _playerService.removeListener(_onPlayerUpdate);
    _playerService.dispose();
    super.dispose();
  }

  // ========== 统计信息显示 ==========

  void _toggleStatsOverlay() {
    setState(() {
      _showStatsOverlay = !_showStatsOverlay;
      if (_showStatsOverlay) {
        _refreshStats();
        _statsRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          _refreshStats();
        });
      } else {
        _statsRefreshTimer?.cancel();
        _statsRefreshTimer = null;
        _playbackStats = {};
      }
    });
  }

  Future<void> _refreshStats() async {
    if (!_showStatsOverlay || !mounted) return;
    final stats = await _playerService.getPlaybackStats();
    if (mounted) {
      setState(() {
        _playbackStats = stats;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final isMpv = normalizePlayerCore(ref.read(playerCoreProvider)) == 'mpv';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) {
          _handleKeyEvent(event);
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          onHover: (_) => _onMouseMoved(),
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _onMouseWheelScroll(event);
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 视频区域
                _playerService.buildVideo(),

                // 缓冲指示器
                if (_playerService.isBuffering)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),

                // 错误显示
                if (_playerService.hasError)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          '播放失败: ${_playerService.errorMessage}',
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _initializePlayer,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),

                // 视频热区点击层
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: _onVideoTapUp,
                  onDoubleTap: _toggleFullscreen,
                ),

                // 统计信息覆盖层（MPV式OSD）
                if (_showStatsOverlay)
                  Positioned(
                    top: 80,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DefaultTextStyle(
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace',
                          height: 1.5,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_playbackStats.isEmpty)
                              const Text('正在获取统计信息...')
                            else
                              ..._buildStatsRows(),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 跳过片头按钮
                if (_showSkipButton)
                  Positioned(
                    top: 80,
                    right: 24,
                    child: ElevatedButton.icon(
                      onPressed: _onSkipOpeningPressed,
                      icon: const Icon(Icons.skip_next, size: 18),
                      label: const Text('跳过片头'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),

                // 控制栏覆盖层
                if (_showControls && !_playerService.isLocked)
                  _buildControlsOverlay(item, isMpv),

                // 锁定状态指示
                if (_playerService.isLocked)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: IconButton(
                      icon: const Icon(Icons.lock, color: Colors.white),
                      tooltip: '已锁定',
                      onPressed: _playerService.toggleLock,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 控制栏覆盖层 ==========

  Widget _buildControlsOverlay(MediaItem? item, bool isMpv) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 顶栏渐变背景
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.8),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: _buildTopBar(item, isMpv),
              ),
            ),
          ),
        ),

        // 左侧浮动按钮
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 60,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconButton(
                    icon: Icons.camera_alt,
                    tooltip: '截图 (Ctrl+S)',
                    onPressed: _takeScreenshot,
                  ),
                  const SizedBox(height: 16),
                  _buildIconButton(
                    icon: _playerService.isLocked ? Icons.lock : Icons.lock_open,
                    tooltip: '锁定',
                    onPressed: _playerService.toggleLock,
                  ),
                ],
              ),
            ),
          ),
        ),

        // 右侧浮动按钮（倍速）
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 60,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTapDown: (_) => _onSpeedButtonDown(true),
                    onTapUp: (_) => _onSpeedButtonUp(),
                    onTapCancel: _onSpeedButtonUp,
                    child: _buildIconButton(
                      icon: Icons.add,
                      tooltip: '加速',
                      onPressed: () {},
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_playerService.speed.toStringAsFixed(2)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTapDown: (_) => _onSpeedButtonDown(false),
                    onTapUp: (_) => _onSpeedButtonUp(),
                    onTapCancel: _onSpeedButtonUp,
                    child: _buildIconButton(
                      icon: Icons.remove,
                      tooltip: '减速',
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 底栏渐变背景
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildProgressBar(),
                    _buildBottomBar(item),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ========== 顶栏 ==========

  Widget _buildTopBar(MediaItem? item, bool isMpv) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 返回按钮
          _buildIconButton(
            icon: Icons.arrow_back,
            tooltip: '返回',
            onPressed: () => context.pop(),
          ),
          const SizedBox(width: 12),
          // 标题
          Expanded(
            child: _MarqueeText(
              text: item?.name ?? widget.itemId,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          // Anime4K
          if (isMpv)
            _buildIconButton(
              icon: Icons.hd,
              tooltip: 'Anime4K 超分',
              color: ref.watch(anime4KLevelProvider) != 'off' ? const Color(0xFF5B8DEF) : Colors.white,
              onPressed: _showAnime4KMenu,
            ),
          // 跳过片头
          _buildIconButton(
            icon: Icons.skip_next,
            tooltip: '跳过片头设置',
            onPressed: _showSkipDialog,
          ),
          // 硬解开关
          _buildIconButton(
            icon: ref.watch(hardwareDecodingProvider) ? Icons.memory : Icons.slow_motion_video,
            tooltip: '硬件解码',
            onPressed: _toggleHardwareDecoding,
          ),
          // 更多菜单
          _buildIconButton(
            icon: Icons.more_vert,
            tooltip: '更多',
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  // ========== 进度条 ==========

  Widget _buildProgressBar() {
    final currentTime = _formatDuration(_playerService.position);
    final totalTime = _formatDuration(_playerService.duration);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // 当前时间
          Text(
            currentTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 12),
          // 进度条
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF5B8DEF),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                thumbColor: const Color(0xFF5B8DEF),
                overlayColor: const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: _playerService.progress.clamp(0.0, 1.0),
                onChanged: (value) {
                  final position = Duration(
                    milliseconds: (value * _playerService.duration.inMilliseconds).round(),
                  );
                  _playerService.seekTo(position);
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 总时间
          Text(
            totalTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ========== 底栏 ==========

  Widget _buildBottomBar(MediaItem? item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          // 左侧：音量
          _buildVolumeControl(),
          const Spacer(),
          // 中间：播放控制
          _buildPlaybackControls(),
          const Spacer(),
          // 右侧：功能按钮
          _buildFunctionControls(item),
        ],
      ),
    );
  }

  Widget _buildVolumeControl() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) {
            setState(() => _showVolumeSlider = true);
            _volumeSliderTimer?.cancel();
          },
          onExit: (_) {
            _volumeSliderTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _showVolumeSlider = false);
            });
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconButton(
                icon: _playerService.volume == 0
                    ? Icons.volume_off
                    : _playerService.volume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
                tooltip: '音量',
                onPressed: _toggleMute,
              ),
              if (_showVolumeSlider)
                SizedBox(
                  width: 100,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF5B8DEF),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                      thumbColor: const Color(0xFF5B8DEF),
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    ),
                    child: Slider(
                      value: _playerService.volume.clamp(0.0, 1.0),
                      onChanged: (value) => _playerService.setVolume(value),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaybackControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          icon: Icons.skip_previous,
          tooltip: '上一集',
          onPressed: _playPrevious,
        ),
        const SizedBox(width: 16),
        GestureDetector(
          onTap: _playerService.togglePlay,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _playerService.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 28,
            ),
          ),
        ),
        const SizedBox(width: 16),
        _buildIconButton(
          icon: Icons.skip_next,
          tooltip: '下一集',
          onPressed: _playNext,
        ),
      ],
    );
  }

  Widget _buildFunctionControls(MediaItem? item) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          icon: Icons.subtitles,
          tooltip: '字幕',
          onPressed: _showSubtitleSelector,
        ),
        _buildIconButton(
          icon: Icons.audiotrack,
          tooltip: '音轨',
          onPressed: _showAudioSelector,
        ),
        _buildIconButton(
          icon: _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: '全屏 (F)',
          onPressed: _toggleFullscreen,
        ),
        _buildIconButton(
          icon: Icons.playlist_play,
          tooltip: '选集',
          onPressed: _showEpisodeSelector,
        ),
      ],
    );
  }

  // ========== 通用按钮 ==========

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: color ?? Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  // ========== 跳过片头设置 ==========

  void _showSkipDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('跳过片头设置', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                _SkipTimeField(label: '片头开始 (秒)', provider: skipOpeningStartProvider),
                const SizedBox(height: 12),
                _SkipTimeField(label: '片头结束 (秒)', provider: skipOpeningEndProvider),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('自动跳过', style: TextStyle(color: Colors.white)),
                    const Spacer(),
                    Switch(
                      value: ref.read(skipAutoModeProvider),
                      onChanged: (value) {
                        ref.read(skipAutoModeProvider.notifier).state = value;
                        Navigator.pop(context);
                      },
                      activeThumbColor: const Color(0xFF5B8DEF),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('确定', style: TextStyle(color: Color(0xFF5B8DEF))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 硬解切换 ==========

  void _toggleHardwareDecoding() async {
    final current = ref.read(hardwareDecodingProvider);
    ref.read(hardwareDecodingProvider.notifier).state = !current;
    final savedPosition = _playerService.position;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer();
    if (savedPosition > Duration.zero) {
      await _playerService.seekTo(savedPosition);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(!current ? '已切换硬件解码' : '已切换软件解码')),
      );
    }
  }
}

// ========== 辅助组件 ==========

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _needsScroll = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
  }

  @override
  void didUpdateWidget(_MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.stop();
      _controller.reset();
      _needsScroll = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _checkOverflow(BoxConstraints constraints) {
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: double.infinity);
    _needsScroll = textPainter.width > constraints.maxWidth;
    if (_needsScroll && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!_needsScroll && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _checkOverflow(constraints);
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              if (!_needsScroll) return child!;
              final textPainter = TextPainter(
                text: TextSpan(text: widget.text, style: widget.style),
                textDirection: TextDirection.ltr,
              );
              textPainter.layout(maxWidth: double.infinity);
              final offset = (textPainter.width - constraints.maxWidth) * _controller.value;
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: child,
              );
            },
            child: Text(widget.text, style: widget.style, overflow: TextOverflow.ellipsis),
          ),
        );
      },
    );
  }
}

class _Anime4KLevelDialog extends StatelessWidget {
  final String currentLevel;

  const _Anime4KLevelDialog({required this.currentLevel});

  static const List<Map<String, String>> levels = [
    {'value': 'off', 'label': '关闭'},
    {'value': 'modeA', 'label': '模式 A - 性能优先'},
    {'value': 'modeB', 'label': '模式 B - 平衡'},
    {'value': 'modeC', 'label': '模式 C - 质量优先'},
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Anime4K 超分设置', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(color: Colors.white12, height: 1),
            ...levels.map((level) => ListTile(
              title: Text(level['label']!, style: const TextStyle(color: Colors.white)),
              trailing: currentLevel == level['value']
                  ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                  : null,
              onTap: () => Navigator.pop(context, level['value']),
            )),
          ],
        ),
      ),
    );
  }
}

class _MoreMenuSheet extends StatelessWidget {
  final VoidCallback onShowAspectRatio;
  final VoidCallback onToggleStats;

  const _MoreMenuSheet({
    required this.onShowAspectRatio,
    required this.onToggleStats,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.aspect_ratio, color: Colors.white),
            title: const Text('画面比例', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              onShowAspectRatio();
            },
          ),
          ListTile(
            leading: const Icon(Icons.analytics, color: Colors.white),
            title: const Text('统计信息', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              onToggleStats();
            },
          ),
        ],
      ),
    );
  }
}

class _EpisodeSelectorDialog extends ConsumerWidget {
  final String seriesId;
  final String currentEpisodeId;
  final String? currentMediaSourceId;

  const _EpisodeSelectorDialog({
    required this.seriesId,
    required this.currentEpisodeId,
    this.currentMediaSourceId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodesAsync = ref.watch(episodesProvider((seriesId: seriesId, seasonId: null)));

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('选集', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Flexible(
              child: episodesAsync.when(
                data: (episodes) => ListView.builder(
                  itemCount: episodes.length,
                  itemBuilder: (context, index) {
                    final episode = episodes[index];
                    final isCurrent = episode.id == currentEpisodeId;
                    return ListTile(
                      title: Text(
                        '第 ${episode.indexNumber ?? index + 1} 集: ${episode.name}',
                        style: TextStyle(
                          color: isCurrent ? const Color(0xFF5B8DEF) : Colors.white,
                          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      trailing: isCurrent ? const Icon(Icons.play_arrow, color: Color(0xFF5B8DEF)) : null,
                      onTap: () {
                        if (!isCurrent) {
                          context.replace('/player/${episode.id}${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}');
                        }
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(
                  child: Text('加载失败: $error', style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkipTimeField extends ConsumerWidget {
  final String label;
  final StateProvider<int> provider;

  const _SkipTimeField({required this.label, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.1),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (text) {
              final val = int.tryParse(text);
              if (val != null && val >= 0) {
                ref.read(provider.notifier).state = val;
              }
            },
          ),
        ),
      ],
    );
  }
}
