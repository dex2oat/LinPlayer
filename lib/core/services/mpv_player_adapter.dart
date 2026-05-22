import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'player_adapter.dart';
import 'app_logger.dart';
import 'mpv_config_manager.dart';
import 'subtitle_processor.dart';

class MpvPlayerAdapter implements PlayerAdapter {
  static final _logger = AppLogger();
  static final _configManager = MpvConfigManager();

  Player? _player;
  VideoController? _videoController;

  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 1.0;
  String? _errorMessage;

  double _subtitleDelay = 0.0;
  double _audioDelay = 0.0;
  double _subtitleScale = 1.0;
  double _subtitlePosition = 100.0;
  String? _subtitleFont;
  String? _aspectRatio;
  List<String>? _glslShaders;
  bool _subtitleBackground = false;

  String? _lastSubtitlePath;

  List<Map<String, dynamic>> _tracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  List<AudioTrack> _audioTracks = [];

  PlayerStateCallbacks? _callbacks;
  final List<StreamSubscription> _subscriptions = [];

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
  bool get libassReady => true;

  @override
  int? get textureId => null;

  @override
  List<Map<String, dynamic>> getTracksInfo() => _tracks;

  @override
  void setCallbacks(PlayerStateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  NativePlayer? get _nativePlayer {
    final platform = _player?.platform;
    if (platform is NativePlayer) return platform;
    return null;
  }

  @override
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
    String? preferredSubtitleLanguage,
  }) async {
    _logger.i('MpvAdapter', '开始初始化 media_kit 内核');
    try {
      await dispose();

      _errorMessage = null;
      _isCompleted = false;
      _tracks = [];
      _subtitleTracks = [];
      _audioTracks = [];
      _lastSubtitlePath = null;

      await _configManager.initialize();

      await _configManager.writeConfig(
        subtitleFont: _subtitleFont,
        subtitleScale: _subtitleScale,
        subtitlePosition: _subtitlePosition,
        subtitleDelay: _subtitleDelay,
        audioDelay: _audioDelay,
        aspectRatio: _aspectRatio,
        glslShaders: _glslShaders,
        subtitleBackground: _subtitleBackground,
      );

      _player = Player();
      _videoController = VideoController(_player!);

      _setupStreamListeners();

      final media = Media(videoUrl);
      await _player!.open(media);

      if (startPosition != null && startPosition > Duration.zero) {
        await _player!.seek(startPosition);
      }

      _isInitialized = true;
      _callbacks?.onDurationChanged?.call();
      _logger.i('MpvAdapter', 'media_kit 初始化完成');
    } catch (e, stackTrace) {
      _errorMessage = e.toString();
      _isInitialized = false;
      _logger.eWithStack('MpvAdapter', '初始化失败', e, stackTrace);
      _callbacks?.onError?.call();
    }
  }

  void _setupStreamListeners() {
    if (_player == null) return;

    _subscriptions.add(_player!.stream.playing.listen((playing) {
      _isPlaying = playing;
      _callbacks?.onPlayingStateChanged?.call();
    }));

    _subscriptions.add(_player!.stream.position.listen((position) {
      _position = position;
      _callbacks?.onPositionChanged?.call();
    }));

    _subscriptions.add(_player!.stream.duration.listen((duration) {
      _duration = duration;
      _callbacks?.onDurationChanged?.call();
    }));

    _subscriptions.add(_player!.stream.buffering.listen((buffering) {
      _isBuffering = buffering;
      _callbacks?.onBufferingStateChanged?.call();
    }));

    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed) {
        _isCompleted = true;
        _callbacks?.onCompleted?.call();
      }
    }));

    _subscriptions.add(_player!.stream.error.listen((error) {
      _errorMessage = error.toString();
      _logger.e('MpvAdapter', '播放器错误: $_errorMessage');
      _callbacks?.onError?.call();
    }));

    _subscriptions.add(_player!.stream.tracks.listen((tracks) {
      _subtitleTracks = tracks.subtitle;
      _audioTracks = tracks.audio;

      final trackList = <Map<String, dynamic>>[];

      for (final track in tracks.video) {
        trackList.add({
          'id': track.id,
          'type': 'video',
          'title': track.title ?? '',
          'language': track.language ?? '',
          'codec': track.codec ?? '',
        });
      }

      for (final track in tracks.audio) {
        trackList.add({
          'id': track.id,
          'type': 'audio',
          'title': track.title ?? '',
          'language': track.language ?? '',
          'codec': track.codec ?? '',
        });
      }

      for (final track in tracks.subtitle) {
        trackList.add({
          'id': track.id,
          'type': 'text',
          'title': track.title ?? '',
          'language': track.language ?? '',
          'codec': track.codec ?? '',
        });
      }

      _tracks = trackList;
      _logger.d('MpvAdapter', '轨道变更: video=${tracks.video.length}, audio=${tracks.audio.length}, subtitle=${tracks.subtitle.length}');
    }));
  }

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '选择字幕轨道: id=$trackId');

    try {
      final target = _subtitleTracks.where((t) => t.id == trackId).firstOrNull;
      if (target != null) {
        await _player!.setSubtitleTrack(target);
        _logger.i('MpvAdapter', '字幕轨道已选择: id=${target.id}, title=${target.title}, lang=${target.language}');
      } else {
        _logger.w('MpvAdapter', '未找到字幕轨道: id=$trackId, 可用: ${_subtitleTracks.map((t) => t.id).toList()}');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择字幕轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '关闭字幕');
    try {
      await _player!.setSubtitleTrack(SubtitleTrack.no());
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '关闭字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '选择音频轨道: id=$trackId');
    try {
      final target = _audioTracks.where((t) => t.id == trackId).firstOrNull;
      if (target != null) {
        await _player!.setAudioTrack(target);
      } else {
        _logger.w('MpvAdapter', '未找到音频轨道: id=$trackId');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择音频轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    _logger.i('MpvAdapter', '加载外挂字幕: $path');
    if (_player == null) return;

    try {
      _lastSubtitlePath = path;

      if (SubtitleProcessor.isGraphicalSubtitle(path)) {
        _logger.i('MpvAdapter', '图形字幕 (PGS/SUP)，直接加载');
        await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        return;
      }

      var processedPath = path;

      if (_subtitleDelay != 0.0) {
        processedPath = await SubtitleProcessor.adjustTiming(processedPath, _subtitleDelay);
      }

      final format = SubtitleProcessor.detectFormat(path);
      if (format == 'ass') {
        final marginV = _subtitlePosition != 100.0
            ? ((100.0 - _subtitlePosition) * 10).round()
            : null;
        final fontSize = _subtitleScale != 1.0
            ? (24 * _subtitleScale).round()
            : null;

        if (_subtitleFont != null || fontSize != null || marginV != null) {
          processedPath = await SubtitleProcessor.modifyAssStyle(
            processedPath,
            fontName: _subtitleFont,
            fontSize: fontSize,
            marginV: marginV,
          );
        }
      }

      await _player!.setSubtitleTrack(SubtitleTrack.uri(processedPath));

      if (format == 'subrip' || format == 'webvtt') {
        final np = _nativePlayer;
        if (np != null) {
          await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
          await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
          if (_subtitleFont != null && _subtitleFont!.isNotEmpty && _subtitleFont != '默认') {
            await np.setProperty('sub-font', _subtitleFont!);
          }
          if (_subtitleBackground) {
            await np.setProperty('sub-back-color', '0.0/0.0/0.0/0.75');
          } else {
            await np.setProperty('sub-back-color', '0.0/0.0/0.0/0.0');
          }
        }
      }

      _logger.i('MpvAdapter', '外挂字幕加载成功: $processedPath');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '外挂字幕加载失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    _logger.i('MpvAdapter', '加载内存字幕 - codec=$codec, size=${data.length} bytes');
    if (_player == null) return;
    try {
      final dataStr = String.fromCharCodes(data);
      await _player!.setSubtitleTrack(
        SubtitleTrack.data(dataStr, title: 'subtitle', language: 'und'),
      );
      _logger.i('MpvAdapter', '内存字幕加载成功');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '内存字幕加载失败', e, stackTrace);
    }
  }

  Future<void> loadSubtitle(String url) async {
    await loadLibassSubtitle(url);
  }

  @override
  Future<void> loadSecondarySubtitle(String path) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '加载次字幕: $path');
    try {
      final np = _nativePlayer;
      if (np != null) {
        await np.command(['sub-add', path, 'select', 'secondary', 'und']);
        await np.setProperty('secondary-sid', 'auto');
      }
      _logger.i('MpvAdapter', '次字幕加载成功: $path');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '次字幕加载失败', e, stackTrace);
    }
  }

  @override
  Future<void> deselectSecondarySubtitle() async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '取消次字幕');
    try {
      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('secondary-sid', 'no');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '取消次字幕失败', e, stackTrace);
    }
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    _subtitleDelay = seconds;
    _logger.i('MpvAdapter', '设置字幕延迟: ${seconds}s');

    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('sub-delay', seconds.toStringAsFixed(3));
    }

    if (_lastSubtitlePath != null && _player != null) {
      await loadLibassSubtitle(_lastSubtitlePath!);
    }

    await _configManager.updateConfigValue('sub-delay', seconds.toStringAsFixed(3));
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    _audioDelay = seconds;
    _logger.i('MpvAdapter', '设置音频延迟: ${seconds}s');
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('audio-delay', seconds.toStringAsFixed(3));
    }
    await _configManager.updateConfigValue('audio-delay', seconds.toStringAsFixed(3));
  }

  @override
  Future<void> setSubtitleFont(String fontName) async {
    _subtitleFont = fontName == '默认' ? null : fontName;
    _logger.i('MpvAdapter', '设置字幕字体: $fontName');

    final np = _nativePlayer;
    if (np != null && _subtitleFont != null && _subtitleFont!.isNotEmpty) {
      await np.setProperty('sub-font', _subtitleFont!);
    }

    if (_lastSubtitlePath != null &&
        SubtitleProcessor.detectFormat(_lastSubtitlePath!) == 'ass') {
      await loadLibassSubtitle(_lastSubtitlePath!);
    }

    if (fontName.isNotEmpty && fontName != '默认') {
      await _configManager.updateConfigValue('sub-font', '"$fontName"');
    }
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    _subtitleScale = 0.5 + size;
    _logger.i('MpvAdapter', '设置字幕大小: scale=$_subtitleScale');

    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
    }

    if (_lastSubtitlePath != null &&
        SubtitleProcessor.detectFormat(_lastSubtitlePath!) == 'ass') {
      await loadLibassSubtitle(_lastSubtitlePath!);
    }

    await _configManager.updateConfigValue('sub-scale', _subtitleScale.toStringAsFixed(2));
  }

  @override
  Future<void> setSubtitlePosition(double position) async {
    _subtitlePosition = 100 - position * 100;
    _logger.i('MpvAdapter', '设置字幕位置: pos=$_subtitlePosition');

    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
    }

    if (_lastSubtitlePath != null &&
        SubtitleProcessor.detectFormat(_lastSubtitlePath!) == 'ass') {
      await loadLibassSubtitle(_lastSubtitlePath!);
    }

    await _configManager.updateConfigValue('sub-pos', _subtitlePosition.toStringAsFixed(1));
  }

  @override
  Future<void> setSubtitleBackground(bool enabled) async {
    _subtitleBackground = enabled;
    _logger.i('MpvAdapter', '设置字幕黑色背景: $enabled');

    final np = _nativePlayer;
    if (np != null) {
      if (enabled) {
        await np.setProperty('sub-back-color', '0.0/0.0/0.0/0.75');
      } else {
        await np.setProperty('sub-back-color', '0.0/0.0/0.0/0.0');
      }
    }

    await _configManager.updateConfigValue(
      'sub-back-color',
      enabled ? '0.0/0.0/0.0/0.75' : '0.0/0.0/0.0/0.0',
    );
  }

  @override
  Future<void> setAspectRatio(String ratio) async {
    _aspectRatio = ratio;
    _logger.i('MpvAdapter', '设置画面比例: $ratio');
    String value;
    switch (ratio) {
      case '16:9':
        value = '16/9';
      case '4:3':
        value = '4/3';
      case '21:9':
        value = '21/9';
      case '全屏':
        value = '-1';
      case '原始':
        value = '0';
      default:
        value = '-1';
    }
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('video-aspect-override', value);
    }
    await _configManager.updateConfigValue('video-aspect-override', value);
  }

  @override
  Future<void> applySuperResolution(bool enable) async {
    _logger.i('MpvAdapter', '设置超分辨率: $enable');
    if (enable) {
      _glslShaders = [
        '~~/shaders/Anime4K_Clamp_Highlights.glsl',
        '~~/shaders/Anime4K_Restore_CNN_M.glsl',
        '~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl',
        '~~/shaders/Anime4K_AutoDownscalePre_x2.glsl',
        '~~/shaders/Anime4K_AutoDownscalePre_x4.glsl',
        '~~/shaders/Anime4K_Upscale_CNN_x2_S.glsl',
      ];
    } else {
      _glslShaders = null;
    }
    if (_glslShaders != null) {
      final paths = _glslShaders!.join(':');
      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('glsl-shaders', paths);
      }
    } else {
      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('glsl-shaders', '');
      }
    }
  }

  @override
  Widget buildVideo() {
    if (_videoController != null) {
      return Video(
        controller: _videoController!,
        fit: BoxFit.contain,
        controls: null,
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  @override
  Future<void> play() async {
    if (_player == null) return;
    await _player!.play();
    _isCompleted = false;
  }

  @override
  Future<void> pause() async {
    if (_player == null) return;
    await _player!.pause();
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_player == null || !_isInitialized) return;
    final clamped = Duration(
      milliseconds: max(0, min(position.inMilliseconds, _duration.inMilliseconds)),
    );
    await _player!.seek(clamped);
    _isCompleted = false;
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_player == null || !_isInitialized) return;
    final clamped = speed.clamp(0.25, 4.0);
    await _player!.setRate(clamped);
    _speed = clamped;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_player == null || !_isInitialized) return;
    final clamped = volume.clamp(0.0, 1.0);
    await _player!.setVolume(clamped * 100);
    _volume = clamped;
  }

  @override
  Future<Uint8List?> screenshot() async {
    if (_player == null) return null;
    try {
      final image = await _player!.screenshot();
      return image;
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '截图失败', e, stackTrace);
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _logger.i('MpvAdapter', '释放资源...');

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    if (_player != null) {
      await _player!.dispose();
      _player = null;
    }
    _videoController = null;

    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _tracks = [];
    _subtitleTracks = [];
    _audioTracks = [];
    _lastSubtitlePath = null;
    _logger.i('MpvAdapter', '资源已释放');
  }
}
