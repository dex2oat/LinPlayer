import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_interfaces.dart';
import 'player_adapter.dart';
import 'exo_player_adapter.dart';
import 'mpv_player_adapter.dart';

/// 播放器内核类型
enum PlayerCoreType {
  exoPlayer,  // ExoPlayer（Android 原生）
  mpv,        // MPV（libmpv FFI）
}

/// 视频播放器服务
///
/// 支持动态切换播放器内核：
/// - ExoPlayer: Android 原生，轻量稳定
/// - MPV: libmpv FFI，全格式支持、HDR、高级字幕控制
class VideoPlayerService extends ChangeNotifier {
  PlayerAdapter? _adapter;
  PlayerCoreType _coreType = PlayerCoreType.exoPlayer;

  Timer? _progressTimer;
  Timer? _hideControlsTimer;

  // 手势状态
  bool _showControls = true;
  bool _isLocked = false;
  bool _isDragging = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  Duration _dragStartPosition = Duration.zero;
  double _dragStartVolume = 1.0;
  double _currentBrightness = 1.0;
  double _dragStartBrightness = 1.0;

  // 播放上报
  String? _currentItemId;
  String? _mediaSourceId;
  Function(PlaybackProgressInfo)? _onProgressReport;
  Function(PlaybackStartInfo)? _onStartReport;
  Function(PlaybackStopInfo)? _onStopReport;

  // Getters
  bool get isPlaying => _adapter?.isPlaying ?? false;
  bool get isBuffering => _adapter?.isBuffering ?? false;
  bool get isInitialized => _adapter?.isInitialized ?? false;
  bool get hasError => _adapter?.hasError ?? false;
  String? get errorMessage => _adapter?.errorMessage;
  Duration get position => _adapter?.position ?? Duration.zero;
  Duration get duration => _adapter?.duration ?? Duration.zero;
  double get speed => _adapter?.speed ?? 1.0;
  double get volume => _adapter?.volume ?? 1.0;
  bool get showControls => _showControls;
  bool get isLocked => _isLocked;
  bool get isDragging => _isDragging;
  bool get isCompleted => _adapter?.isCompleted ?? false;
  double get progress => _adapter?.progress ?? 0.0;
  PlayerCoreType get coreType => _coreType;

  /// 当前播放器适配器（用于内核特定操作）
  PlayerAdapter? get adapter => _adapter;

  double get brightness => _currentBrightness;

  /// 手势起始 X 坐标（用于判断亮度/音量区域）
  double get dragStartX => _dragStartX;

  /// 拖动方向：1=向前, -1=向后, 0=无
  int get dragDirection {
    if (!_isDragging) return 0;
    final currentPos = _adapter?.position.inMilliseconds ?? 0;
    final dx = _dragStartPosition.inMilliseconds - currentPos;
    if (dx < -500) return 1; // 向后拖 = 快进
    if (dx > 500) return -1; // 向前拖 = 快退
    return 0;
  }

  /// Flutter Texture ID（用于 Texture widget 渲染视频，旧架构）
  int? get textureId => _adapter?.textureId;

  /// 构建视频渲染 Widget
  ///
  /// ExoPlayer 返回 Texture widget，media_kit 返回 Video widget
  Widget buildVideo() {
    return _adapter?.buildVideo() ?? const Center(
      child: CircularProgressIndicator(),
    );
  }

  /// libass 是否已就绪
  bool get libassReady => _adapter?.libassReady ?? false;

  /// 获取当前可用轨道列表
  List<Map<String, dynamic>> get tracksInfo => _adapter?.getTracksInfo() ?? [];

  /// 设置播放器内核
  void setCoreType(PlayerCoreType type) {
    if (_coreType == type) return;
    _coreType = type;
    if (_adapter?.isInitialized ?? false) {
      // TODO: 重新加载当前视频
    }
    notifyListeners();
  }

  /// 创建适配器
  PlayerAdapter _createAdapter() {
    switch (_coreType) {
      case PlayerCoreType.exoPlayer:
        return ExoPlayerAdapter();
      case PlayerCoreType.mpv:
        return MpvPlayerAdapter();
    }
  }

  /// 初始化播放器
  Future<void> initialize({
    required String videoUrl,
    required String itemId,
    String? mediaSourceId,
    Duration? startPosition,
    PlayerCoreType? coreType,
    Function(PlaybackStartInfo)? onStart,
    Function(PlaybackProgressInfo)? onProgress,
    Function(PlaybackStopInfo)? onStop,
    bool? dolbyVisionFix,
    bool? useLibass,
    String? preferredSubtitleLanguage,
  }) async {
    _currentItemId = itemId;
    _mediaSourceId = mediaSourceId ?? itemId;
    _onStartReport = onStart;
    _onProgressReport = onProgress;
    _onStopReport = onStop;

    if (coreType != null) {
      _coreType = coreType;
    }

    // 释放旧适配器
    await _adapter?.dispose();

    // 创建新适配器
    _adapter = _createAdapter();

    // 设置回调
    _adapter!.setCallbacks(PlayerStateCallbacks(
      onPositionChanged: () => notifyListeners(),
      onDurationChanged: () => notifyListeners(),
      onPlayingStateChanged: () {
        if (_adapter?.isPlaying ?? false) {
          _startHideControlsTimer();
        } else {
          _cancelHideControlsTimer();
        }
        notifyListeners();
      },
      onBufferingStateChanged: () => notifyListeners(),
      onCompleted: () {
        notifyListeners();
        // TODO: 自动播放下一集
      },
      onError: () => notifyListeners(),
    ));

    // 初始化
    await _adapter!.initialize(
      videoUrl: videoUrl,
      startPosition: startPosition,
      dolbyVisionFix: dolbyVisionFix ?? false,
      useLibass: useLibass ?? false,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
    );

    // 开始播放
    await _adapter!.play();

    // 上报开始
    _reportStart();

    // 加载 libass 字幕（如果启用）
    if (useLibass ?? false) {
      // 由调用方在 initialize 后手动加载字幕
    }

    // 启动进度定时器
    _startProgressTimer();

    notifyListeners();
  }

  /// 加载外部字幕文件（通过 libass）
  Future<void> loadLibassSubtitle(String path) async {
    await _adapter?.loadLibassSubtitle(path);
  }

  /// 加载字幕数据到内存（通过 libass）
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    await _adapter?.loadLibassSubtitleMemory(data, codec: codec);
  }

  /// 选择字幕轨道（内封字幕切换）
  Future<void> selectSubtitleTrack(String trackId) async {
    await _adapter?.selectSubtitleTrack(trackId);
    notifyListeners();
  }

  /// 关闭字幕
  Future<void> deselectSubtitleTrack() async {
    await _adapter?.deselectSubtitleTrack();
    notifyListeners();
  }

  /// 选择音频轨道
  Future<void> selectAudioTrack(String trackId) async {
    await _adapter?.selectAudioTrack(trackId);
    notifyListeners();
  }

  /// 加载次字幕文件
  Future<void> loadSecondarySubtitle(String path) async {
    await _adapter?.loadSecondarySubtitle(path);
    notifyListeners();
  }

  /// 通过轨道ID选择内封字幕作为次字幕
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    await _adapter?.selectSecondarySubtitleTrack(trackId);
    notifyListeners();
  }

  /// 取消次字幕
  Future<void> deselectSecondarySubtitle() async {
    await _adapter?.deselectSecondarySubtitle();
    notifyListeners();
  }

  /// 播放
  Future<void> play() async {
    await _adapter?.play();
    _startHideControlsTimer();
    notifyListeners();
  }

  /// 暂停
  Future<void> pause() async {
    await _adapter?.pause();
    _cancelHideControlsTimer();
    notifyListeners();
  }

  /// 播放/暂停切换
  Future<void> togglePlay() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position) async {
    await _adapter?.seekTo(position);
    notifyListeners();
  }

  /// 快进/快退
  Future<void> seekBy(Duration offset) async {
    await seekTo(position + offset);
  }

  /// 设置播放速度
  Future<void> setSpeed(double speed) async {
    await _adapter?.setSpeed(speed);
    notifyListeners();
  }

  /// 设置音量
  Future<void> setVolume(double volume) async {
    await _adapter?.setVolume(volume);
    notifyListeners();
  }

  /// 截图
  Future<Uint8List?> screenshot() async {
    return await _adapter?.screenshot();
  }

  /// 设置字幕同步偏移
  Future<void> setSubtitleDelay(double seconds) async {
    await _adapter?.setSubtitleDelay(seconds);
    notifyListeners();
  }

  /// 设置音频同步偏移
  Future<void> setAudioDelay(double seconds) async {
    await _adapter?.setAudioDelay(seconds);
    notifyListeners();
  }

  /// 设置字幕字体
  Future<void> setSubtitleFont(String fontName) async {
    await _adapter?.setSubtitleFont(fontName);
    notifyListeners();
  }

  /// 设置字幕大小
  Future<void> setSubtitleSize(double size) async {
    await _adapter?.setSubtitleSize(size);
    notifyListeners();
  }

  /// 设置字幕位置
  Future<void> setSubtitlePosition(double position) async {
    await _adapter?.setSubtitlePosition(position);
    notifyListeners();
  }

  /// 设置字幕黑色背景
  Future<void> setSubtitleBackground(bool enabled) async {
    await _adapter?.setSubtitleBackground(enabled);
    notifyListeners();
  }

  /// 设置画面比例
  Future<void> setAspectRatio(String ratio) async {
    await _adapter?.setAspectRatio(ratio);
    notifyListeners();
  }

  /// 应用超分辨率
  Future<void> applySuperResolution(bool enable) async {
    await _adapter?.applySuperResolution(enable);
    notifyListeners();
  }

  /// 应用超分辨率档位
  Future<void> applySuperResolutionLevel(String level) async {
    await _adapter?.applySuperResolutionLevel(level);
    notifyListeners();
  }

  /// 获取播放统计信息
  Future<Map<String, String>> getPlaybackStats() async {
    return await _adapter?.getPlaybackStats() ?? {};
  }

  /// 设置亮度
  void setBrightness(double brightness) {
    _currentBrightness = brightness.clamp(0.1, 1.0);
    notifyListeners();
  }

  /// 保存亮度到本地
  Future<void> saveBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('player_brightness', _currentBrightness);
  }

  /// 从本地加载亮度
  Future<void> loadBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBrightness = prefs.getDouble('player_brightness');
    if (savedBrightness != null) {
      _currentBrightness = savedBrightness;
      notifyListeners();
    }
  }

  /// 显示/隐藏控制栏
  void toggleControls() {
    if (_isLocked) return;
    _showControls = !_showControls;
    if (_showControls) {
      _startHideControlsTimer();
    } else {
      _cancelHideControlsTimer();
    }
    notifyListeners();
  }

  /// 锁定/解锁屏幕
  void toggleLock() {
    _isLocked = !_isLocked;
    if (_isLocked) {
      _showControls = false;
      _cancelHideControlsTimer();
    }
    notifyListeners();
  }

  // ========== 手势控制 ==========

  void onDragStart(DragStartDetails details, BoxConstraints constraints) {
    if (_isLocked || !isInitialized) return;
    _isDragging = true;
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _dragStartPosition = position;
    _dragStartVolume = volume;
    _dragStartBrightness = _currentBrightness;
    _cancelHideControlsTimer();
    notifyListeners();
  }

  void onDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (!_isDragging || _isLocked) return;

    final dx = details.globalPosition.dx - _dragStartX;
    final dy = details.globalPosition.dy - _dragStartY;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;

    // 手势灵敏度阈值：至少移动 10 个逻辑像素才开始响应
    const threshold = 10.0;
    if (dx.abs() < threshold && dy.abs() < threshold) return;

    if (dx.abs() > dy.abs() * 1.5) {
      // 水平滑动（进度调节）：需要水平移动明显大于垂直移动
      final progressDelta = dx / width * duration.inMilliseconds * 0.5; // 降低灵敏度系数
      final newPositionMs = max(0, min(
        _dragStartPosition.inMilliseconds + progressDelta.round(),
        duration.inMilliseconds,
      ));
      _dragStartPosition = Duration(milliseconds: newPositionMs);
      notifyListeners();
    } else if (dy.abs() > dx.abs() * 1.5) {
      // 垂直滑动（亮度/音量）：需要垂直移动明显大于水平移动
      if (_dragStartX < width / 2) {
        // 左侧：亮度
        final brightnessDelta = -dy / height * 0.7; // 降低灵敏度系数
        final newBrightness = (_dragStartBrightness + brightnessDelta).clamp(0.1, 1.0);
        setBrightness(newBrightness);
      } else {
        // 右侧：音量
        final volumeDelta = -dy / height * 0.7; // 降低灵敏度系数
        final newVolume = (_dragStartVolume + volumeDelta).clamp(0.0, 1.0);
        setVolume(newVolume);
      }
    }
    // 如果移动方向不明确（水平和垂直移动差不多），则不响应，避免误触
  }

  void onDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    seekTo(_dragStartPosition);
    _startHideControlsTimer();
    notifyListeners();
  }

  // ========== 内部方法 ==========

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _reportProgress();
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (isPlaying && !_isDragging) {
        _showControls = false;
        notifyListeners();
      }
    });
  }

  void _cancelHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  // ========== 播放上报 ==========

  void _reportStart() {
    if (_onStartReport == null || _currentItemId == null) return;
    _onStartReport!(PlaybackStartInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
    ));
  }

  void _reportProgress() {
    if (_onProgressReport == null || _currentItemId == null) return;
    _onProgressReport!(PlaybackProgressInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      positionTicks: (position.inMilliseconds * 10000).round(),
      isPaused: !isPlaying,
      volumeLevel: volume,
    ));
  }

  void _reportStop() {
    if (_onStopReport == null || _currentItemId == null) return;
    _onStopReport!(PlaybackStopInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      positionTicks: (position.inMilliseconds * 10000).round(),
    ));
  }

  /// 释放资源
  @override
  Future<void> dispose() async {
    _reportStop();
    _stopProgressTimer();
    _cancelHideControlsTimer();
    await _adapter?.dispose();
    _adapter = null;
    super.dispose();
  }
}
