import 'dart:typed_data';

/// 播放器适配器接口
///
/// 抽象所有播放器内核的通用操作。
/// 视频渲染统一通过 [textureId] 交给 Flutter Texture widget，
/// 不再由 adapter 自行构建 widget。
abstract class PlayerAdapter {
  /// 是否已初始化
  bool get isInitialized;

  /// 是否正在播放
  bool get isPlaying;

  /// 是否缓冲中
  bool get isBuffering;

  /// 是否播放完成
  bool get isCompleted;

  /// 当前位置
  Duration get position;

  /// 总时长
  Duration get duration;

  /// 当前播放速度
  double get speed;

  /// 当前音量
  double get volume;

  /// 播放进度 0.0-1.0
  double get progress;

  /// 是否有错误
  bool get hasError;

  /// 错误信息
  String? get errorMessage;

  /// libass 是否已就绪
  bool get libassReady => false;

  /// Flutter Texture ID（渲染视频用）
  int? get textureId;

  /// 初始化播放器
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
  });

  /// 加载外部字幕文件（通过 libass）
  Future<void> loadLibassSubtitle(String path) async {}

  /// 加载字幕数据到内存（通过 libass）
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {}

  /// 播放
  Future<void> play();

  /// 暂停
  Future<void> pause();

  /// 跳转到指定位置
  Future<void> seekTo(Duration position);

  /// 设置播放速度
  Future<void> setSpeed(double speed);

  /// 设置音量
  Future<void> setVolume(double volume);

  /// 设置状态回调
  void setCallbacks(PlayerStateCallbacks callbacks);

  /// 截图（返回图片字节数据）
  Future<Uint8List?> screenshot() async => null;

  /// 设置字幕同步偏移（秒）
  Future<void> setSubtitleDelay(double seconds) async {}

  /// 设置音频同步偏移（秒）
  Future<void> setAudioDelay(double seconds) async {}

  /// 设置字幕字体
  Future<void> setSubtitleFont(String fontName) async {}

  /// 设置字幕大小（0.0 - 1.0）
  Future<void> setSubtitleSize(double size) async {}

  /// 设置字幕位置（0.0 - 1.0）
  Future<void> setSubtitlePosition(double position) async {}

  /// 设置画面比例
  Future<void> setAspectRatio(String ratio) async {}

  /// 应用超分辨率（Anime4K）
  Future<void> applySuperResolution(bool enable) async {}

  /// 释放资源
  Future<void> dispose();
}

/// 播放器状态回调
class PlayerStateCallbacks {
  final VoidCallback? onPositionChanged;
  final VoidCallback? onDurationChanged;
  final VoidCallback? onPlayingStateChanged;
  final VoidCallback? onBufferingStateChanged;
  final VoidCallback? onCompleted;
  final VoidCallback? onError;

  const PlayerStateCallbacks({
    this.onPositionChanged,
    this.onDurationChanged,
    this.onPlayingStateChanged,
    this.onBufferingStateChanged,
    this.onCompleted,
    this.onError,
  });
}

typedef VoidCallback = void Function();
