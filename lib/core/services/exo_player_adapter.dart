import 'dart:async';
import 'dart:math' show max, min;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'player_adapter.dart';
import 'app_logger.dart';

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

  List<Map<dynamic, dynamic>> _tracks = [];

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
  bool get libassReady => false;

  @override
  int? get textureId => _textureId;

  @override
  List<Map<String, dynamic>> getTracksInfo() =>
      _tracks.map((e) => e.map((k, v) => MapEntry(k.toString(), v))).toList();

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
    String? preferredSubtitleLanguage,
  }) async {
    _logger.i('ExoPlayer', '开始初始化 - videoUrl=$videoUrl');
    try {
      await dispose();

      _errorMessage = null;
      _isCompleted = false;
      _tracks = [];

      _logger.d('ExoPlayer', '调用原生 createPlayer...');
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('createPlayer', {
        'videoUrl': videoUrl,
        'startPositionMs': startPosition?.inMilliseconds ?? 0,
        'dolbyVisionFix': dolbyVisionFix,
        'preferredSubtitleLanguage': preferredSubtitleLanguage,
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

      _callbacks?.onDurationChanged?.call();
      _logger.i('ExoPlayer', '初始化完成');
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('ExoPlayer', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  Future<List<Map<dynamic, dynamic>>> getTracks() async {
    if (_playerId == null || !_isInitialized) return [];
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getTracks', {
        'playerId': _playerId,
      });
      return result?.cast<Map<dynamic, dynamic>>() ?? [];
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('ExoPlayer', '选择字幕轨道: $trackId');
    try {
      final trackInfo = _tracks.where((t) =>
          t['id']?.toString() == trackId || t['trackIndex']?.toString() == trackId).toList();

      if (trackInfo.isNotEmpty) {
        final track = trackInfo.first;
        final groupIndex = track['groupIndex'] ?? 0;
        final trackIndex = track['trackIndex'] ?? 0;
        await _channel.invokeMethod('selectTrack', {
          'playerId': _playerId,
          'groupIndex': groupIndex,
          'trackIndex': trackIndex,
          'trackType': 3,
        });
      } else {
        final tracks = await getTracks();
        final textTracks = tracks.where((t) => t['type'] == 'text').toList();
        final targetTrack = textTracks.where((t) =>
            t['id']?.toString() == trackId || t['trackIndex']?.toString() == trackId).toList();

        if (targetTrack.isNotEmpty) {
          final track = targetTrack.first;
          await _channel.invokeMethod('selectTrack', {
            'playerId': _playerId,
            'groupIndex': track['groupIndex'] ?? 0,
            'trackIndex': track['trackIndex'] ?? 0,
            'trackType': 3,
          });
        }
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '选择字幕轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('ExoPlayer', '关闭字幕');
    try {
      await _channel.invokeMethod('deselectSubtitleTrack', {
        'playerId': _playerId,
      });
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '关闭字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_playerId == null || !_isInitialized) return;
    _logger.i('ExoPlayer', '选择音频轨道: $trackId');
    try {
      final trackInfo = _tracks.where((t) =>
          (t['type'] == 'audio') &&
          (t['id']?.toString() == trackId || t['trackIndex']?.toString() == trackId)).toList();

      if (trackInfo.isNotEmpty) {
        final track = trackInfo.first;
        await _channel.invokeMethod('selectTrack', {
          'playerId': _playerId,
          'groupIndex': track['groupIndex'] ?? 0,
          'trackIndex': track['trackIndex'] ?? 0,
          'trackType': 2,
        });
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '选择音频轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadSecondarySubtitle(String path) async {
    _logger.w('ExoPlayer', '次字幕暂不支持，请使用 MPV 内核');
  }

  @override
  Future<void> deselectSecondarySubtitle() async {
    _logger.w('ExoPlayer', '次字幕暂不支持，请使用 MPV 内核');
  }

  bool supportsSubtitleFormat(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.srt') ||
        lower.endsWith('.ass') ||
        lower.endsWith('.ssa') ||
        lower.endsWith('.vtt') ||
        lower.endsWith('.ttml')) {
      return true;
    }
    return false;
  }

  Future<void> loadSubtitle({
    required String subtitleUrl,
    String? mimeType,
    String? language,
  }) async {
    if (_playerId == null || !_isInitialized) return;

    final lowerUrl = subtitleUrl.toLowerCase();
    if (lowerUrl.endsWith('.pgs') || lowerUrl.endsWith('.sup')) {
      _logger.w('ExoPlayer', 'PGS/SUP 图形字幕需要 FFmpeg 扩展支持，请切换到 MPV 内核');
      throw Exception('PGS/SUP subtitles are not supported by ExoPlayer. Please switch to MPV kernel.');
    }

    _logger.i('ExoPlayer', '加载外挂字幕: $subtitleUrl (mime=$mimeType, lang=$language)');
    try {
      await _channel.invokeMethod('loadSubtitle', {
        'playerId': _playerId,
        'subtitleUrl': subtitleUrl,
        'subtitleMimeType': mimeType,
        'subtitleLanguage': language,
      });
    } catch (e, stackTrace) {
      _logger.eWithStack('ExoPlayer', '加载字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    await loadSubtitle(subtitleUrl: path);
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    _logger.w('ExoPlayer', 'loadLibassSubtitleMemory 已废弃');
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'playing':
        _isPlaying = event['value'] as bool? ?? false;
        _callbacks?.onPlayingStateChanged?.call();
        break;
      case 'buffering':
        _isBuffering = event['value'] as bool? ?? false;
        _callbacks?.onBufferingStateChanged?.call();
        break;
      case 'completed':
        _isCompleted = true;
        _callbacks?.onCompleted?.call();
        break;
      case 'error':
        _errorMessage = event['value'] as String?;
        _callbacks?.onError?.call();
        break;
      case 'duration':
        _duration = Duration(milliseconds: (event['value'] as num).toInt());
        _callbacks?.onDurationChanged?.call();
        break;
      case 'tracksChanged':
        final tracksList = event['value'] as List<dynamic>?;
        if (tracksList != null) {
          _tracks = tracksList.cast<Map<dynamic, dynamic>>();
          _logger.d('ExoPlayer', '轨道变更: ${_tracks.length} 条轨道');
        }
        break;
      case 'subtitle':
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
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置字幕字体: $fontName');
    await _channel.invokeMethod('setSubtitleFont', {
      'playerId': _playerId,
      'fontName': fontName,
    });
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置字幕大小: $size');
    await _channel.invokeMethod('setSubtitleSize', {
      'playerId': _playerId,
      'size': size,
    });
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
  Future<void> setSubtitleBackground(bool enabled) async {
    if (_playerId == null) return;
    _logger.d('ExoPlayer', '设置字幕黑色背景: $enabled');
    await _channel.invokeMethod('setSubtitleBackground', {
      'playerId': _playerId,
      'enabled': enabled,
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
  Widget buildVideo() {
    if (_textureId != null) {
      return Texture(textureId: _textureId!);
    }
    return const Center(
      child: CircularProgressIndicator(),
    );
  }

  @override
  Future<void> applySuperResolution(bool enable) async {
  }

  @override
  Future<void> dispose() async {
    _logger.i('ExoPlayer', '释放资源...');

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
    _tracks = [];
    _logger.i('ExoPlayer', '资源已释放');
  }
}
