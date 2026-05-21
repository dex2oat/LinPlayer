import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'player_adapter.dart';
import 'app_logger.dart';

// ============================================================================
// libmpv FFI 绑定
// ============================================================================

DynamicLibrary? _mpvLib;
DynamicLibrary _loadMpvLib() {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libmpv.so');
    } else if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.open('libmpv.dylib');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('mpv-1.dll');
    }
  } catch (e) {
    AppLogger().e('MpvAdapter', '加载 libmpv 动态库失败: $e');
    rethrow;
  }
  throw UnsupportedError('Unsupported platform for libmpv: ${Platform.operatingSystem}');
}

DynamicLibrary get _mpvLibInstance {
  _mpvLib ??= _loadMpvLib();
  return _mpvLib!;
}

// mpv_handle 不透明指针
typedef MpvHandle = Pointer<Void>;

// mpv_create
typedef MpvCreateC = MpvHandle Function();
typedef MpvCreate = MpvHandle Function();

// mpv_initialize
typedef MpvInitializeC = Int32 Function(MpvHandle ctx);
typedef MpvInitialize = int Function(MpvHandle ctx);

// mpv_terminate_destroy
typedef MpvTerminateDestroyC = Void Function(MpvHandle ctx);
typedef MpvTerminateDestroy = void Function(MpvHandle ctx);

// mpv_command_string
typedef MpvCommandStringC = Int32 Function(MpvHandle ctx, Pointer<Utf8> args);
typedef MpvCommandString = int Function(MpvHandle ctx, Pointer<Utf8> args);

// mpv_set_property_string
typedef MpvSetPropertyStringC = Int32 Function(MpvHandle ctx, Pointer<Utf8> name, Pointer<Utf8> data);
typedef MpvSetPropertyString = int Function(MpvHandle ctx, Pointer<Utf8> name, Pointer<Utf8> data);

// mpv_get_property_string
typedef MpvGetPropertyStringC = Pointer<Utf8> Function(MpvHandle ctx, Pointer<Utf8> name);
typedef MpvGetPropertyString = Pointer<Utf8> Function(MpvHandle ctx, Pointer<Utf8> name);

// mpv_free
typedef MpvFreeC = Void Function(Pointer<Void> ptr);
typedef MpvFree = void Function(Pointer<Void> ptr);

// mpv_observe_property
typedef MpvObservePropertyC = Int32 Function(MpvHandle ctx, Uint64 replyUserdata, Pointer<Utf8> name, Int32 format);
typedef MpvObserveProperty = int Function(MpvHandle ctx, int replyUserdata, Pointer<Utf8> name, int format);

// mpv_wait_event
typedef MpvWaitEventC = Pointer<MpvEvent> Function(MpvHandle ctx, Double timeout);
typedef MpvWaitEvent = Pointer<MpvEvent> Function(MpvHandle ctx, double timeout);

// Event format constants
const int MPV_FORMAT_NONE = 0;
const int MPV_FORMAT_STRING = 1;
const int MPV_FORMAT_OSD_STRING = 2;
const int MPV_FORMAT_FLAG = 3;
const int MPV_FORMAT_INT64 = 4;
const int MPV_FORMAT_DOUBLE = 5;

// Event IDs
const int MPV_EVENT_NONE = 0;
const int MPV_EVENT_SHUTDOWN = 1;
const int MPV_EVENT_LOG_MESSAGE = 2;
const int MPV_EVENT_GET_PROPERTY_REPLY = 3;
const int MPV_EVENT_SET_PROPERTY_REPLY = 4;
const int MPV_EVENT_COMMAND_REPLY = 5;
const int MPV_EVENT_START_FILE = 6;
const int MPV_EVENT_END_FILE = 7;
const int MPV_EVENT_FILE_LOADED = 8;
const int MPV_EVENT_TRACKS_CHANGED = 9;
const int MPV_EVENT_TRACK_SWITCHED = 10;
const int MPV_EVENT_IDLE = 11;
const int MPV_EVENT_PAUSE = 12;
const int MPV_EVENT_UNPAUSE = 13;
const int MPV_EVENT_TICK = 14;
const int MPV_EVENT_SCRIPT_INPUT_DISPATCH = 15;
const int MPV_EVENT_CLIENT_MESSAGE = 16;
const int MPV_EVENT_VIDEO_RECONFIG = 17;
const int MPV_EVENT_AUDIO_RECONFIG = 18;
const int MPV_EVENT_SEEK = 20;
const int MPV_EVENT_PLAYBACK_RESTART = 21;
const int MPV_EVENT_PROPERTY_CHANGE = 22;

/// mpv_event 结构体（简化版）
base class MpvEvent extends Struct {
  @Int32()
  external int eventId;

  @Int32()
  external int error;

  @Uint64()
  external int replyUserdata;

  external Pointer<Void> data;
}

// ============================================================================
// MPV Player Adapter
// ============================================================================

/// MPV 原生适配器
///
/// 通过 Dart FFI 直接调用 libmpv C API，
/// 视频渲染通过 Platform Channel 交由原生侧管理（EGL/Texture）。
///
/// **注意**：需要自行提供 libmpv.so（Android）或 libmpv.dylib（macOS/iOS）
/// 或 mpv-1.dll（Windows）。
class MpvPlayerAdapter implements PlayerAdapter {
  static const _textureChannel = MethodChannel('com.linplayer/mpv_texture');
  static final _logger = AppLogger();

  MpvHandle? _ctx;
  int? _textureId;

  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 1.0;
  String? _errorMessage;

  PlayerStateCallbacks? _callbacks;
  Timer? _positionTimer;
  Isolate? _eventIsolate;
  ReceivePort? _eventPort;

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
  int? get textureId => _textureId;

  @override
  bool get libassReady => true;

  @override
  void setCallbacks(PlayerStateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    _logger.i('MpvAdapter', '加载字幕: $path');
    _command('sub-add', path, 'select');
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    // MPV 内存字幕加载较复杂，需写入临时文件后加载
    _logger.w('MpvAdapter', '内存字幕加载尚未实现');
  }

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
  }) async {
    _logger.i('MpvAdapter', '开始初始化 - videoUrl=$videoUrl');
    try {
      await dispose();

      _errorMessage = null;
      _isCompleted = false;

      // 验证 libmpv 是否可用
      try {
        _mpvLibInstance.handle;
        _logger.i('MpvAdapter', 'libmpv 动态库加载成功');
      } catch (e) {
        throw Exception('libmpv 不可用。请确保 libmpv.so 已放置到 jniLibs/arm64-v8a 目录。错误: $e');
      }

      // 创建 mpv 实例
      final mpvCreate = _mpvLibInstance.lookupFunction<MpvCreateC, MpvCreate>('mpv_create');
      _ctx = mpvCreate();
      if (_ctx == null || _ctx!.address == 0) {
        throw Exception('mpv_create 返回 null');
      }
      _logger.i('MpvAdapter', 'mpv 实例创建成功');

      // 配置 mpv
      _setPropertyString('vo', 'gpu');
      _setPropertyString('hwdec', 'auto');
      _setPropertyString('cache', 'yes');
      _setPropertyString('cache-secs', '30');
      _setPropertyString('demuxer-max-bytes', '50M');
      _setPropertyString('demuxer-max-back-bytes', '25M');
      if (dolbyVisionFix) {
        _setPropertyString('target-trc', 'pq');
      }
      _logger.d('MpvAdapter', 'mpv 基础配置完成');

      // 初始化 mpv
      final mpvInitialize = _mpvLibInstance.lookupFunction<MpvInitializeC, MpvInitialize>('mpv_initialize');
      final initResult = mpvInitialize(_ctx!);
      if (initResult < 0) {
        throw Exception('mpv_initialize 失败，错误码: $initResult');
      }
      _logger.i('MpvAdapter', 'mpv 初始化成功');

      // 通过 Platform Channel 创建 Texture（原生侧负责 EGL + FBO）
      _logger.d('MpvAdapter', '请求创建 Texture...');
      final textureResult = await _textureChannel.invokeMethod<Map<dynamic, dynamic>>('createMpvTexture', {
        'width': 1920,
        'height': 1080,
      });
      _textureId = textureResult?['textureId'] as int?;

      if (_textureId == null) {
        throw Exception('创建 MPV Texture 失败：原生通道返回 null。请确保 Android 原生代码已正确实现 com.linplayer/mpv_texture Channel。');
      }
      _logger.i('MpvAdapter', 'Texture 创建成功 - textureId=$_textureId');

      // 将 mpv 渲染绑定到 Texture（通过 Platform Channel 传递 mpv 指针地址）
      _logger.d('MpvAdapter', '绑定 mpv 到 Texture...');
      await _textureChannel.invokeMethod('attachMpvToTexture', {
        'mpvHandle': _ctx!.address,
        'textureId': _textureId,
      });
      _logger.i('MpvAdapter', 'mpv 已绑定到 Texture');

      // 加载视频
      _logger.i('MpvAdapter', '加载视频: $videoUrl');
      _command('loadfile', videoUrl);

      // 监听属性变化
      _observeProperty('time-pos');
      _observeProperty('duration');
      _observeProperty('pause');
      _observeProperty('core-idle');
      _observeProperty('eof-reached');

      // 启动事件循环 Isolate
      await _startEventLoop();

      // 设置初始位置
      if (startPosition != null && startPosition > Duration.zero) {
        _setPropertyDouble('time-pos', startPosition.inMilliseconds / 1000.0);
      }

      _isInitialized = true;

      // 轮询位置
      _positionTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _pollPosition(),
      );

      _callbacks?.onDurationChanged?.call();
      _logger.i('MpvAdapter', '初始化完成');
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('MpvAdapter', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  void _setPropertyString(String name, String value) {
    if (_ctx == null) return;
    final mpvSetPropertyString = _mpvLibInstance.lookupFunction<MpvSetPropertyStringC, MpvSetPropertyString>('mpv_set_property_string');
    final namePtr = name.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      mpvSetPropertyString(_ctx!, namePtr, valuePtr);
    } finally {
      malloc.free(namePtr);
      malloc.free(valuePtr);
    }
  }

  void _setPropertyDouble(String name, double value) {
    _command('set', name, value.toString());
  }

  void _command(String cmd, [String? arg1, String? arg2]) {
    if (_ctx == null) return;
    final mpvCommandString = _mpvLibInstance.lookupFunction<MpvCommandStringC, MpvCommandString>('mpv_command_string');
    final cmdPtr = cmd.toNativeUtf8();
    try {
      if (arg1 == null) {
        mpvCommandString(_ctx!, cmdPtr);
      } else {
        final arg1Ptr = arg1.toNativeUtf8();
        try {
          if (arg2 == null) {
            final full = '$cmd "$arg1"';
            final fullPtr = full.toNativeUtf8();
            try {
              mpvCommandString(_ctx!, fullPtr);
            } finally {
              malloc.free(fullPtr);
            }
          } else {
            final full = '$cmd "$arg1" "$arg2"';
            final fullPtr = full.toNativeUtf8();
            try {
              mpvCommandString(_ctx!, fullPtr);
            } finally {
              malloc.free(fullPtr);
            }
          }
        } finally {
          malloc.free(arg1Ptr);
        }
      }
    } finally {
      malloc.free(cmdPtr);
    }
  }

  void _observeProperty(String name) {
    if (_ctx == null) return;
    final mpvObserveProperty = _mpvLibInstance.lookupFunction<MpvObservePropertyC, MpvObserveProperty>('mpv_observe_property');
    final namePtr = name.toNativeUtf8();
    try {
      mpvObserveProperty(_ctx!, 0, namePtr, MPV_FORMAT_DOUBLE);
    } finally {
      malloc.free(namePtr);
    }
  }

  Future<void> _startEventLoop() async {
    _eventPort = ReceivePort();
    _eventIsolate = await Isolate.spawn(
      _mpvEventLoop,
      _MpvEventLoopArgs(
        ctxAddress: _ctx!.address,
        sendPort: _eventPort!.sendPort,
      ),
    );

    _eventPort!.listen((message) {
      if (message is Map) {
        final eventId = message['eventId'] as int?;
        _handleEvent(eventId, message);
      }
    });
  }

  void _handleEvent(int? eventId, Map<dynamic, dynamic> message) {
    switch (eventId) {
      case MPV_EVENT_PROPERTY_CHANGE:
        final name = message['name'] as String?;
        final value = message['value'] as double?;
        if (name == 'time-pos' && value != null) {
          _position = Duration(milliseconds: (value * 1000).round());
          _callbacks?.onPositionChanged?.call();
        } else if (name == 'duration' && value != null) {
          _duration = Duration(milliseconds: (value * 1000).round());
          _callbacks?.onDurationChanged?.call();
        } else if (name == 'pause') {
          _isPlaying = value != 1;
          _callbacks?.onPlayingStateChanged?.call();
        } else if (name == 'core-idle') {
          _isBuffering = value == 1;
          _callbacks?.onBufferingStateChanged?.call();
        } else if (name == 'eof-reached') {
          if (value == 1) {
            _isCompleted = true;
            _callbacks?.onCompleted?.call();
          }
        }
        break;
      case MPV_EVENT_START_FILE:
        _isBuffering = true;
        _callbacks?.onBufferingStateChanged?.call();
        break;
      case MPV_EVENT_END_FILE:
        _isBuffering = false;
        _callbacks?.onBufferingStateChanged?.call();
        break;
      case MPV_EVENT_SHUTDOWN:
        _isInitialized = false;
        break;
    }
  }

  void _pollPosition() {
    if (_ctx == null) return;
    final mpvGetPropertyString = _mpvLibInstance.lookupFunction<MpvGetPropertyStringC, MpvGetPropertyString>('mpv_get_property_string');
    final mpvFree = _mpvLibInstance.lookupFunction<MpvFreeC, MpvFree>('mpv_free');
    final namePtr = 'time-pos'.toNativeUtf8();
    try {
      final result = mpvGetPropertyString(_ctx!, namePtr);
      if (result.address != 0) {
        final valueStr = result.cast<Utf8>().toDartString();
        mpvFree(result.cast());
        final value = double.tryParse(valueStr);
        if (value != null) {
          _position = Duration(milliseconds: (value * 1000).round());
        }
      }
    } finally {
      malloc.free(namePtr);
    }
  }

  @override
  Future<void> play() async {
    _setPropertyString('pause', 'no');
    _isCompleted = false;
  }

  @override
  Future<void> pause() async {
    _setPropertyString('pause', 'yes');
  }

  @override
  Future<void> seekTo(Duration position) async {
    final clamped = Duration(
      milliseconds: max(0, min(position.inMilliseconds, _duration.inMilliseconds)),
    );
    _command('seek', '${clamped.inMilliseconds / 1000.0}', 'absolute');
    _isCompleted = false;
  }

  @override
  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.25, 4.0);
    _setPropertyString('speed', clamped.toString());
    _speed = clamped;
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _setPropertyString('volume', (clamped * 100).toString());
    _volume = clamped;
  }

  @override
  Future<Uint8List?> screenshot() async {
    return null;
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    _setPropertyString('sub-delay', seconds.toString());
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    _setPropertyString('audio-delay', seconds.toString());
  }

  @override
  Future<void> setSubtitleFont(String fontName) async {
    _setPropertyString('sub-font', fontName);
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    _setPropertyString('sub-scale', (0.5 + size).toString());
  }

  @override
  Future<void> setSubtitlePosition(double position) async {
    _setPropertyString('sub-pos', (100 - position * 100).toString());
  }

  @override
  Future<void> setAspectRatio(String ratio) async {
    switch (ratio) {
      case '16:9':
        _setPropertyString('video-aspect-override', '16/9');
      case '4:3':
        _setPropertyString('video-aspect-override', '4/3');
      case '21:9':
        _setPropertyString('video-aspect-override', '21/9');
      case '全屏':
        _setPropertyString('video-aspect-override', '-1');
      case '原始':
        _setPropertyString('video-aspect-override', '0');
      default:
        _setPropertyString('video-aspect-override', '-1');
    }
  }

  @override
  Future<void> applySuperResolution(bool enable) async {
    if (enable) {
      _setPropertyString('glsl-shaders', '~~/shaders/Anime4K_Clamp_Highlights.glsl:~~/shaders/Anime4K_Restore_CNN_M.glsl:~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl:~~/shaders/Anime4K_AutoDownscalePre_x2.glsl:~~/shaders/Anime4K_AutoDownscalePre_x4.glsl:~~/shaders/Anime4K_Upscale_CNN_x2_S.glsl');
    } else {
      _setPropertyString('glsl-shaders', '');
    }
  }

  @override
  Future<void> dispose() async {
    _positionTimer?.cancel();
    _positionTimer = null;

    _eventIsolate?.kill(priority: Isolate.immediate);
    _eventIsolate = null;
    _eventPort?.close();
    _eventPort = null;

    if (_textureId != null) {
      try {
        await _textureChannel.invokeMethod('disposeMpvTexture', {
          'textureId': _textureId,
        });
      } catch (_) {}
      _textureId = null;
    }

    if (_ctx != null) {
      final mpvTerminateDestroy = _mpvLibInstance.lookupFunction<MpvTerminateDestroyC, MpvTerminateDestroy>('mpv_terminate_destroy');
      mpvTerminateDestroy(_ctx!);
      _ctx = null;
    }

    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
  }
}

// ============================================================================
// Isolate 事件循环
// ============================================================================

class _MpvEventLoopArgs {
  final int ctxAddress;
  final SendPort sendPort;

  _MpvEventLoopArgs({required this.ctxAddress, required this.sendPort});
}

void _mpvEventLoop(_MpvEventLoopArgs args) {
  final ctx = Pointer<Void>.fromAddress(args.ctxAddress);

  while (true) {
    try {
      final mpvWaitEvent = _mpvLibInstance.lookupFunction<MpvWaitEventC, MpvWaitEvent>('mpv_wait_event');
      final event = mpvWaitEvent(ctx, 0.1);
      if (event.address == 0) continue;

      final eventId = event.ref.eventId;
      if (eventId == MPV_EVENT_NONE) continue;

      final message = <String, dynamic>{'eventId': eventId};

      if (eventId == MPV_EVENT_PROPERTY_CHANGE) {
        // 解析 property change 事件
      }

      args.sendPort.send(message);

      if (eventId == MPV_EVENT_SHUTDOWN) break;
    } catch (_) {
      break;
    }
  }
}
