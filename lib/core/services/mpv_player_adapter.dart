import 'dart:async';
import 'dart:convert';
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
  String? _secondarySid;
  bool _hasBitmapSubtitle = false;
  bool _currentSubIsAss = false;

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

  bool _isHttpUrl(String path) =>
      path.startsWith('http://') || path.startsWith('https://');

  String _extractExtension(String path) {
    var clean = path;
    final qIndex = clean.indexOf('?');
    if (qIndex >= 0) clean = clean.substring(0, qIndex);
    final hashIndex = clean.indexOf('#');
    if (hashIndex >= 0) clean = clean.substring(0, hashIndex);
    final dotIndex = clean.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex < clean.lastIndexOf('/')) return '';
    return clean.substring(dotIndex + 1).toLowerCase();
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
      _secondarySid = null;

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

      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('secondary-sub-visibility', 'yes');
      }

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
          'id': track.id, 'type': 'video',
          'title': track.title ?? '', 'language': track.language ?? '',
          'codec': track.codec ?? '',
        });
      }
      for (final track in tracks.audio) {
        trackList.add({
          'id': track.id, 'type': 'audio',
          'title': track.title ?? '', 'language': track.language ?? '',
          'codec': track.codec ?? '',
        });
      }
      for (final track in tracks.subtitle) {
        final id = track.id;
        if (id == 'auto' || id == 'no') continue;
        final codec = track.codec?.toLowerCase() ?? '';
        final isBitmap = codec.contains('pgs') || codec.contains('hdmv') ||
            codec.contains('dvd') || codec.contains('vobsub') ||
            codec.contains('dvbsub') ||
            (codec.contains('sub') && !codec.contains('ass') && !codec.contains('srt') && !codec.contains('subrip'));
        final isAss = codec.contains('ass') || codec.contains('ssa');
        if (isBitmap) _hasBitmapSubtitle = true;
        trackList.add({
          'id': track.id,
          'type': isBitmap ? 'bitmap' : 'text',
          'title': track.title ?? '', 'language': track.language ?? '',
          'codec': track.codec ?? '',
          'isBitmap': isBitmap,
          'isAss': isAss,
        });
      }
      _tracks = trackList;
      _logger.d('MpvAdapter',
          '轨道变更: video=${tracks.video.length}, audio=${tracks.audio.length}, subtitle=${tracks.subtitle.length}');
      _tryPendingSubtitleSelection();
    }));
  }

  String? _pendingSubtitleLang;
  String? _pendingSubtitleCodec;

  void setPendingSubtitle(String codec) {
    _pendingSubtitleLang = null;
    _pendingSubtitleCodec = codec;
  }

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '选择字幕轨道: id=$trackId, 已知轨道数=${_subtitleTracks.length}');
    try {
      final realTracks = _subtitleTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
      if (realTracks.isEmpty) {
        _logger.w('MpvAdapter', '轨道列表为空，先用SubtitleTrack.auto()兜底');
        await _player!.setSubtitleTrack(SubtitleTrack.auto());
        _pendingSubtitleLang = trackId;
        _pendingSubtitleCodec = null;
        return;
      }
      var target = realTracks.where((t) => t.id == trackId).firstOrNull;
      if (target == null) {
        final trackInfo = _tracks.where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id']?.toString() == trackId).firstOrNull;
        if (trackInfo != null) {
          target = realTracks.where((t) =>
              t.id == trackInfo['id']).firstOrNull;
        }
      }
      if (target != null) {
        final codec = target.codec?.toLowerCase() ?? '';
        _hasBitmapSubtitle = codec.contains('pgs') || codec.contains('hdmv') ||
            codec.contains('dvd') || codec.contains('vobsub') || codec.contains('dvbsub');
        _currentSubIsAss = _detectAssCodec(target);
        _logger.i('MpvAdapter', '字幕轨道已选择: id=${target.id}, title=${target.title}, lang=${target.language}, codec=${target.codec}, bitmap=$_hasBitmapSubtitle, ass=$_currentSubIsAss');
        await _player!.setSubtitleTrack(target);
      } else {
        _logger.w('MpvAdapter', '未找到字幕轨道: id=$trackId, 可用: ${realTracks.map((t) => '${t.id}/${t.language}/${t.codec}').toList()}');
        await _player!.setSubtitleTrack(SubtitleTrack.auto());
      }
      await _applySubtitleRuntimeProperties();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择字幕轨道失败', e, stackTrace);
    }
  }

  bool _detectAssCodec(SubtitleTrack track) {
    final codec = track.codec?.toLowerCase() ?? '';
    if (codec.contains('ass') || codec.contains('ssa')) return true;
    if (codec.contains('pgs') || codec.contains('hdmv') ||
        codec.contains('dvd') || codec.contains('vobsub') ||
        codec.contains('dvbsub')) return false;
    if (codec.contains('srt') || codec.contains('subrip') ||
        codec.contains('vtt') || codec.contains('webvtt')) return false;
    final trackInfo = _tracks.where((t) => t['id']?.toString() == track.id).firstOrNull;
    if (trackInfo != null) {
      final isAss = trackInfo['isAss'] == true;
      if (isAss) return true;
      final isBitmap = trackInfo['isBitmap'] == true;
      if (isBitmap) return false;
      final tCodec = (trackInfo['codec'] ?? '').toString().toLowerCase();
      if (tCodec.contains('ass') || tCodec.contains('ssa')) return true;
    }
    final title = track.title?.toLowerCase() ?? '';
    if (title.contains('ass') || title.contains('ssa')) return true;
    return false;
  }

  Future<void> _tryPendingSubtitleSelection() async {
    if (_pendingSubtitleLang == null) return;
    final realTracks = _subtitleTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (realTracks.isEmpty) return;
    final targetId = _pendingSubtitleLang;
    final targetCodec = _pendingSubtitleCodec;
    _pendingSubtitleLang = null;
    _pendingSubtitleCodec = null;
    _logger.i('MpvAdapter', '延迟选择字幕轨道: id=$targetId, codec=$targetCodec, 可用=${realTracks.length}个');

    var target = realTracks.where((t) => t.id == targetId).firstOrNull;
    if (target == null) {
      final trackInfo = _tracks.where((t) =>
          (t['type'] == 'text' || t['type'] == 'bitmap') &&
          t['id']?.toString() == targetId).firstOrNull;
      if (trackInfo != null) {
        target = realTracks.where((t) => t.id == trackInfo['id']).firstOrNull;
      }
    }

    if (target == null && targetCodec != null) {
      final isBitmap = targetCodec.contains('pgs') || targetCodec.contains('hdmv');
      final isAss = targetCodec.contains('ass') || targetCodec.contains('ssa');
      for (final t in realTracks) {
        final c = t.codec?.toLowerCase() ?? '';
        final tIsBitmap = c.contains('pgs') || c.contains('hdmv');
        final tIsAss = c.contains('ass') || c.contains('ssa');
        if (isBitmap && tIsBitmap) { target = t; break; }
        if (isAss && tIsAss) { target = t; break; }
      }
      target ??= realTracks.first;
    }

    if (target != null) {
      final codec = target.codec?.toLowerCase() ?? '';
      _hasBitmapSubtitle = codec.contains('pgs') || codec.contains('hdmv') ||
          codec.contains('dvd') || codec.contains('vobsub') || codec.contains('dvbsub');
      _currentSubIsAss = _detectAssCodec(target);
      await _player!.setSubtitleTrack(target);
      await _applySubtitleRuntimeProperties();
      _logger.i('MpvAdapter', '延迟字幕选择成功: id=${target.id}, codec=${target.codec}');
    }
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_player == null || !_isInitialized) return;
    try {
      await _player!.setSubtitleTrack(SubtitleTrack.no());
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '关闭字幕失败', e, stackTrace);
    }
  }
  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    try {
      final target = _audioTracks.where((t) => t.id == trackId).firstOrNull;
      if (target != null) {
        await _player!.setAudioTrack(target);
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
      if (_isHttpUrl(path)) {
        _logger.i('MpvAdapter', 'HTTP URL字幕，直接传给mpv加载');
        final ext = _extractExtension(path);
        _currentSubIsAss = ext == 'ass' || ext == 'ssa';
        _hasBitmapSubtitle = ext == 'pgs' || ext == 'sup';
        _logger.i('MpvAdapter', 'HTTP字幕类型: ext=$ext, isAss=$_currentSubIsAss, isBitmap=$_hasBitmapSubtitle');
        await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        await _applySubtitleRuntimeProperties();
        _logger.i('MpvAdapter', 'HTTP外挂字幕加载成功');
        return;
      }

      final ext = _extractExtension(path);

      if (ext == 'pgs' || ext == 'sup') {
        _logger.i('MpvAdapter', '图形字幕 (PGS/SUP)，直接加载');
        _hasBitmapSubtitle = true;
        _currentSubIsAss = false;
        await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        await _applySubtitleRuntimeProperties();
        _logger.i('MpvAdapter', '图形字幕加载成功');
        return;
      }

      var processedPath = path;

      if (_subtitleDelay != 0.0) {
        processedPath = await SubtitleProcessor.adjustTiming(processedPath, _subtitleDelay);
      }

      if (ext == 'ass' || ext == 'ssa') {
        _currentSubIsAss = true;
        _hasBitmapSubtitle = false;
        if (_subtitleFont != null && _subtitleFont != '默认') {
          processedPath = await SubtitleProcessor.modifyAssStyle(
            processedPath,
            fontName: _subtitleFont,
          );
        }
      } else {
        _currentSubIsAss = false;
        _hasBitmapSubtitle = false;
        _logger.i('MpvAdapter', '文本字幕 (SRT/VTT等)，isAss=false');
      }

      await _player!.setSubtitleTrack(SubtitleTrack.uri(processedPath));
      await _applySubtitleRuntimeProperties();

      _logger.i('MpvAdapter', '外挂字幕加载成功: $processedPath');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '外挂字幕加载失败', e, stackTrace);
    }
  }

  Future<void> _applySubtitleRuntimeProperties() async {
    final np = _nativePlayer;
    if (np == null) return;
    try {
      await np.setProperty('sub-visibility', 'yes');
      await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
      await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
      if (_subtitleFont != null && _subtitleFont!.isNotEmpty && _subtitleFont != '默认') {
        await np.setProperty('sub-font', _subtitleFont!);
      }
      await np.setProperty('sub-back-color',
          _subtitleBackground ? '#000000C0' : '#00000000');
      await np.setProperty('sub-delay', _subtitleDelay.toStringAsFixed(3));

      if (_hasBitmapSubtitle) {
        await np.setProperty('sub-ass', 'no');
        await np.setProperty('sub-ass-override', 'no');
      } else if (_currentSubIsAss) {
        await np.setProperty('sub-ass', 'yes');
        await np.setProperty('sub-ass-override', 'no');
        if (_subtitleFont != null && _subtitleFont!.isNotEmpty && _subtitleFont != '默认') {
          await np.setProperty('sub-ass-override', 'scale');
        }
      } else {
        await np.setProperty('sub-ass', 'yes');
        await np.setProperty('sub-ass-override', 'strip');
      }

      if (_secondarySid != null) {
        await np.setProperty('secondary-sid', _secondarySid!);
        await np.setProperty('secondary-sub-visibility', 'yes');
      }
    } catch (e) {
      _logger.e('MpvAdapter', '设置运行时字幕属性失败: $e');
    }
  }

  @override
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {
    _logger.i('MpvAdapter', '加载内存字幕 - codec=$codec, size=${data.length} bytes');
    if (_player == null) return;
    try {
      final dataStr = utf8.decode(data, allowMalformed: true);
      _currentSubIsAss = codec.contains('ass') || codec.contains('ssa');
      _hasBitmapSubtitle = codec.contains('pgs') || codec.contains('sup') ||
          codec.contains('hdmv');
      if (!_currentSubIsAss && !_hasBitmapSubtitle) {
        _currentSubIsAss = dataStr.contains('[V4+ Styles]') || dataStr.contains('[V4 Styles]');
      }
      await _player!.setSubtitleTrack(
        SubtitleTrack.data(dataStr, title: 'subtitle', language: 'und'),
      );
      await _applySubtitleRuntimeProperties();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '内存字幕加载失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadSecondarySubtitle(String path) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '加载次字幕: $path');
    try {
      final np = _nativePlayer;
      if (np != null) {
        await np.setProperty('secondary-sub-visibility', 'yes');

        final subtitleTracks = _player!.state.tracks.subtitle;
        final beforeCount = subtitleTracks.length;
        await np.command(['sub-add', path, 'auto', 'secondary', 'und']);

        SubtitleTrack? newTrack;
        for (int i = 0; i < 20; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          final afterTracks = _player!.state.tracks.subtitle;
          if (afterTracks.length > beforeCount) {
            newTrack = afterTracks.last;
            break;
          }
        }

        if (newTrack != null) {
          final sid = newTrack.id;
          _secondarySid = sid;
          _logger.i('MpvAdapter', '次字幕轨道ID: $sid, 设置secondary-sid=$sid');
          await np.setProperty('secondary-sid', sid);
        } else {
          _logger.w('MpvAdapter', '次字幕添加后未检测到新轨道，使用secondary-sid=auto兜底');
          await np.setProperty('secondary-sid', 'auto');
          _secondarySid = 'auto';
        }
      }
      _logger.i('MpvAdapter', '次字幕加载成功: $path');
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '次字幕加载失败', e, stackTrace);
    }
  }

  @override
  Future<void> deselectSecondarySubtitle() async {
    if (_player == null || !_isInitialized) return;
    _secondarySid = null;
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
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '选择内封次字幕轨道: id=$trackId');
    try {
      final np = _nativePlayer;
      if (np != null) {
        _secondarySid = trackId;
        await np.setProperty('secondary-sub-visibility', 'yes');
        await np.setProperty('secondary-sid', trackId);
        _logger.i('MpvAdapter', '内封次字幕已设置: secondary-sid=$trackId');
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '设置内封次字幕失败', e, stackTrace);
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
    await _configManager.updateConfigValue('sub-delay', seconds.toStringAsFixed(3));
  }

  @override
  Future<void> setAudioDelay(double seconds) async {
    _audioDelay = seconds;
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('audio-delay', seconds.toStringAsFixed(3));
    }
    await _configManager.updateConfigValue('audio-delay', seconds.toStringAsFixed(3));
  }

  @override
  Future<void> setSubtitleFont(String fontName) async {
    _subtitleFont = fontName == '默认' ? null : fontName;
    final np = _nativePlayer;
    if (np != null && _subtitleFont != null && _subtitleFont!.isNotEmpty) {
      await np.setProperty('sub-font', _subtitleFont!);
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
    await _configManager.updateConfigValue('sub-pos', _subtitlePosition.toStringAsFixed(1));
  }

  @override
  Future<void> setSubtitleBackground(bool enabled) async {
    _subtitleBackground = enabled;
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('sub-back-color',
          enabled ? '#000000C0' : '#00000000');
    }
    await _configManager.updateConfigValue(
      'sub-back-color', enabled ? '#000000C0' : '#00000000',
    );
  }

  @override
  Future<void> setAspectRatio(String ratio) async {
    _aspectRatio = ratio;
    String value;
    switch (ratio) {
      case '16:9': value = '16/9';
      case '4:3': value = '4/3';
      case '21:9': value = '21/9';
      case '全屏': value = '-1';
      case '原始': value = '0';
      default: value = '-1';
    }
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('video-aspect-override', value);
    }
    await _configManager.updateConfigValue('video-aspect-override', value);
  }

  @override
  Future<void> applySuperResolution(bool enable) async {
    _glslShaders = enable ? [
      '~~/shaders/Anime4K_Clamp_Highlights.glsl',
      '~~/shaders/Anime4K_Restore_CNN_M.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl',
      '~~/shaders/Anime4K_AutoDownscalePre_x2.glsl',
      '~~/shaders/Anime4K_AutoDownscalePre_x4.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_S.glsl',
    ] : null;
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('glsl-shaders', _glslShaders?.join(':') ?? '');
    }
  }

  @override
  Widget buildVideo() {
    if (_videoController != null) {
      return Video(controller: _videoController!, fit: BoxFit.contain, controls: null);
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
      return await _player!.screenshot();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '截图失败', e, stackTrace);
      return null;
    }
  }

  @override
  Future<void> dispose() async {
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
  }
}
