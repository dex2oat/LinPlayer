import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'player_adapter.dart';
import 'libass_bridge.dart';
import 'app_logger.dart';

/// ExoPlayer 原生适配器
///
/// 通过 Platform Channel 与 Android 原生 ExoPlayer 通信，
/// 视频渲染使用 Flutter Texture widget。
/// 字幕通过 libass（从 libmpv.so 动态加载符号）渲染为位图叠加。
class ExoPlayerAdapter implements PlayerAdapter {
  static const _channel = MethodChannel('com.linplayer/exoplayer');
  static final _logger = AppLogger();

  String? _playerId;
  int? _textureId;
  EventChannel? _eventChannel;
  StreamSubscription? _eventSub;

  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 1.0;
  String? _errorMessage;
  bool _useLibass = false;
  bool _libassReady = false;

  PlayerStateCallbacks? _callbacks;
  Timer? _positionTimer;

  @override
  bool get isInitialized => _isInitialized;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isBuffering => _isBuffering;

  @override
  bool get isCompleted => _isCompleted;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  double get speed => _speed;

  @override
  double get volume => _volume;

  @override
  double get progress {
    final dur = _duration.inMilliseconds;
    if (dur <= 0) return 0.0;
    return _position.inMilliseconds / dur;
  }

  @override
  bool get hasError => _errorMessage != null;

  @override
  String? get errorMessage => _errorMessage;

  @override
  bool get libassReady => _libassReady;

  @override
  int? get textureId => _textureId;

  @override
  void setCallbacks(PlayerStateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
  }) async {
    _logger.i('ExoPlayer', '开始初始化 - useLibass=$useLibass, videoUrl=$videoUrl');
    try {
      await dispose();

      _errorMessage = null;
      _isCompleted = false;
      _useLibass = useLibass;
      _libassReady = false;

      _logger.d('ExoPlayer', '调用原生 createPlayer...');
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('createPlayer', {
        'videoUrl': videoUrl,
        'startPositionMs': startPosition?.inMilliseconds ?? 0,
        'dolbyVisionFix': dolbyVisionFix,
      });

      if (result == null) {
        throw Exception('Failed to create ExoPlayer: result is null');
      }

      _playerId = result['playerId'] as String?;
      _textureId = result['textureId'] as int?;
      _logger.i('ExoPlayer', '原生播放器创建成功 - playerId=$_playerId, textureId=$_textureId');

      if (_playerId == null || _textureId == null) {
        throw Exception('Invalid player creation result: playerId=$_playerId, textureId=$_textureId');
      }

      _isInitialized = true;

      _eventChannel = EventChannel('com.linplayer/exoplayer/events/$_playerId');
      _eventSub = _eventChannel!.receiveBroadcastStream().listen(
        _onEvent,
        onError: _onEventError,
      );
      _logger.d('ExoPlayer', '事件监听已启动');

      _positionTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _pollState(),
      );

      if (_useLibass) {
        _logger.i('ExoPlayer', 'libass 已启用，开始初始化...');
        await _initLibass();
        if (!_libassReady) {
          _logger.w('ExoPlayer', 'libass 初始化失败，将继续播放但不显示字幕');
        }
      }

      _callbacks?.onDurationChanged?.call();
      _logger.i('ExoPlayer', '初始化完成');
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('ExoPlayer', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  Future<void> _initLibass() async {
    try {
      final available = await LibassBridge.isAvailable();
      _logger.i('ExoPlayer', 'libass 可用性检查: $available');
      if (!available) {
        _useLibass = false;
        _logger.w('ExoPlayer', 'libass 不可用，可能缺少原生实现或 libmpv.so');
        return;
      }

      // 使用 PlatformDispatcher 替代 deprecated ui.window
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isEmpty) {
        _logger.w('ExoPlayer', '无法获取屏幕尺寸：没有可用的 FlutterView');
        _useLibass = false;
        return;
      }
      final view = views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      final width = size.width.toInt();
      final height = size.height.toInt();
      _logger.d('ExoPlayer', 'libass 初始化尺寸: ${width}x$height');

      if (width <= 0 || height <= 0) {
        _logger.w('ExoPlayer', '屏幕尺寸无效: ${width}x$height');
        _useLibass = false;
        return;
      }

      final ok = await LibassBridge.init(width: width, height: height);
      if (!ok) {
        _logger.e('ExoPlayer', 'LibassBridge.init() 返回 false');
        _useLibass = false;
        return;
      }

      _libassReady = true;
      _logger.i('ExoPlayer', 'libass 初始化成功');
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', 'libass 初始化异常', e, stackTrace);
      _useLibass = false;
      _libassReady = false;
    }
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    _logger.i('ExoPlayer', '加载字幕文件: $path');
    if (!_libassReady) {
      _logger.w('ExoPlayer', 'libass 未就绪，无法加载字幕');
      return;
    }
    try {
      final ok = await LibassBridge.loadSubFile(path);
      if (ok) {
        _logger.i('ExoPlayer', '字幕加载成功: $path');
      } else {
        _logger.e('ExoPlayer', '字幕加载失败: LibassBridge.loadSubFile 返回 false');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '字幕加载异常: $path', e, stackTrace);
    }
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    _logger.i('ExoPlayer', '加载内存字幕 - codec=$codec, size=${data.length} bytes');
    if (!_libassReady) {
      _logger.w('ExoPlayer', 'libass 未就绪，无法加载字幕');
      return;
    }
    try {
      final ok = await LibassBridge.loadSubMemory(data, codec: codec);
      if (ok) {
        _logger.i('ExoPlayer', '内存字幕加载成功');
      } else {
        _logger.e('ExoPlayer', '内存字幕加载失败: LibassBridge.loadSubMemory 返回 false');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '内存字幕加载异常', e, stackTrace);
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'playing':
        _isPlaying = event['value'] as bool? ?? false;
        _logger.d('ExoPlayer', '播放状态变更: playing=$_isPlaying');
        _callbacks?.onPlayingStateChanged?.call();
        break;
      case 'buffering':
        _isBuffering = event['value'] as bool? ?? false;
        _logger.d('ExoPlayer', '缓冲状态变更: buffering=$_isBuffering');
        _callbacks?.onBufferingStateChanged?.call();
        break;
      case 'completed':
        _isCompleted = true;
        _logger.i('ExoPlayer', '播放完成');
        _callbacks?.onCompleted?.call();
        break;
      case 'error':
        _errorMessage = event['message'] as String?;
        _logger.e('ExoPlayer', '播放器错误: $_errorMessage');
        _callbacks?.onError?.call();
        break;
      case 'duration':
        _duration = Duration(milliseconds: (event['value'] as num).toInt());
        _logger.d('ExoPlayer', '时长更新: ${_duration.inSeconds}s');
        _callbacks?.onDurationChanged?.call();
        break;
    }
  }

  void _onEventError(Object error) {
    _errorMessage = error.toString();
    _logger.e('ExoPlayer', '事件通道错误: $error');
    _callbacks?.onError?.call();
  }

  Future<void> _pollState() async {
    if (_playerId == null || !_isInitialized) return;
    try {
      final pos = await _channel.invokeMethod<int>('getPosition', {'playerId': _playerId});
      if (pos != null) {
        _position = Duration(milliseconds: pos);
        _callbacks?.onPositionChanged?.call();
      }
      final dur = await _channel.invokeMethod<int>('getDuration', {'playerId': _playerId});
      if (dur != null && dur > 0) {
        _duration = Duration(milliseconds: dur);
      }
    } catch (e) {
      // 轮询失败不记录，避免日志过多
    }
  }

  @override
  Future<void> play() async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '播放');
    await _channel.invokeMethod('play', {'playerId': _playerId});
    _isCompleted = false;
  }

  @override
  Future<void> pause() async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '暂停');
    await _channel.invokeMethod('pause', {'playerId': _playerId});
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_playerId == null || !_isInitialized) return;
    final clamped = Duration(
      milliseconds: max(0, min(position.inMilliseconds, _duration.inMilliseconds)),
    );
    _logger.d('ExoPlayer', '跳转: ${clamped.inMilliseconds}ms');
    await _channel.invokeMethod('seekTo', {
      'playerId': _playerId,
      'positionMs': clamped.inMilliseconds,
    });
    _isCompleted = false;
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_playerId == null || !_isInitialized) return;
    final clamped = speed.clamp(0.25, 4.0);
    _logger.d('ExoPlayer', '设置速度: ${clamped}x');
    await _channel.invokeMethod('setSpeed', {
      'playerId': _playerId,
      'speed': clamped,
    });
    _speed = clamped;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_playerId == null || !_isInitialized) return;
    final clamped = volume.clamp(0.0, 1.0);
    await _channel.invokeMethod('setVolume', {
      'playerId': _playerId,
      'volume': clamped,
    });
    _volume = clamped;
  }

  @override
  Future<Uint8List?> screenshot() async {
    if (_playerId == null) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('screenshot', {
        'playerId': _playerId,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置字幕延迟: ${seconds}s');
    await _channel.invokeMethod('setSubtitleDelay', {
      'playerId': _playerId,
      'seconds': seconds,
    });
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置音频延迟: ${seconds}s');
    await _channel.invokeMethod('setAudioDelay', {
      'playerId': _playerId,
      'seconds': seconds,
    });
  }

  @override
  Future<void> setSubtitleFont(String fontName) async {
    _logger.d('ExoPlayer', '设置字幕字体: $fontName');
    if (_libassReady) {
      await LibassBridge.setFontName(fontName);
    }
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置字幕大小: $size');
    await _channel.invokeMethod('setSubtitleSize', {
      'playerId': _playerId,
      'size': size,
    });
    if (_libassReady) {
      final pixelSize = (16 + (size * 32)).toInt();
      await LibassBridge.setFontSize(pixelSize);
    }
  }

  @override
  Future<void> setSubtitlePosition(double position) async {
    if (_playerId == null) return;
    await _channel.invokeMethod('setSubtitlePosition', {
      'playerId': _playerId,
      'position': position,
    });
  }

  @override
  Future<void> setAspectRatio(String ratio) async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置画面比例: $ratio');
    await _channel.invokeMethod('setAspectRatio', {
      'playerId': _playerId,
      'ratio': ratio,
    });
  }

  @override
  Future<void> applySuperResolution(bool enable) async {
    // ExoPlayer 不支持超分辨率
  }

  @override
  Future<void> dispose() async {
    _logger.i('ExoPlayer', '释放资源...');
    if (_libassReady) {
      try {
        await LibassBridge.dispose();
      } catch (e) {
        _logger.w('ExoPlayer', 'libass 释放失败: $e');
      }
      _libassReady = false;
    }

    _positionTimer?.cancel();
    _positionTimer = null;
    _eventSub?.cancel();
    _eventSub = null;
    _eventChannel = null;

    if (_playerId != null) {
      try {
        await _channel.invokeMethod('disposePlayer', {'playerId': _playerId});
      } catch (_) {}
      _playerId = null;
    }

    _textureId = null;
    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _logger.i('ExoPlayer', '资源已释放');
  }
}
