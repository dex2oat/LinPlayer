import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'player_adapter.dart';
import 'app_logger.dart';
import 'mpv_config_manager.dart';
import 'subtitle_track_matcher.dart';
import 'subtitle_processor.dart';

class MpvPlayerAdapter implements PlayerAdapter {
  static final _logger = AppLogger();
  static final _configManager = MpvConfigManager();
  static const _subtitleTrackTypes = <String>{'subtitle', 'text', 'bitmap'};

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
  bool _usingExternalSubtitle = false;

  List<Map<String, dynamic>> _tracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  List<AudioTrack> _audioTracks = [];
  String? _selectedSubtitleTrackId;
  String? _selectedAudioTrackId;

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
    bool hardwareDecoding = true,
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
      _usingExternalSubtitle = false;

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

      // 禁用 media_kit 内置的 libass，使用 MPV 原生字幕渲染管线
      // 原因：
      // 1. media_kit 的 libass 仅支持 ASS/SSA，不支持 PGS/SUP 位图字幕
      // 2. MPV 原生渲染支持所有字幕格式，且能通过 blend-subtitles=video 混合到帧中
      // 3. 用户通过 UI 调节字幕大小/位置时，MPV 原生配置更灵活
      _player = Player(
        configuration: const PlayerConfiguration(
          libass: false,
          logLevel: MPVLogLevel.warn,
        ),
      );
      _videoController = VideoController(_player!);
      _setupStreamListeners();

      final np = _nativePlayer;
      if (np != null) {
        final fontsDir = _configManager.fontsDirectory;
        const systemFontsDir = '/system/fonts';
        final dir = Directory(fontsDir);
        if (dir.listSync().isNotEmpty) {
          await np.setProperty('sub-fonts-dir', fontsDir);
        } else {
          await np.setProperty('sub-fonts-dir', systemFontsDir);
        }
        // 默认关闭次字幕可见性，只有用户明确选择次字幕时才开启
        // 避免同时显示两个字幕（主字幕+次字幕）
        await np.setProperty('secondary-sub-visibility', 'no');
        // 保持 mpv 默认字幕合成路径，避免强制视频混合导致字幕/视频一起掉帧。
        await np.setProperty('blend-subtitles', 'no');
        await np.setProperty('sub-visibility', 'yes');
        await np.setProperty('hwdec', hardwareDecoding ? 'auto-safe' : 'no');
        if (_isHttpUrl(videoUrl)) {
          await np.setProperty('cache', 'yes');
          await np.setProperty('cache-pause', 'yes');
          await np.setProperty('cache-pause-wait', '8');
          await np.setProperty('cache-secs', '300');
          await np.setProperty('demuxer-max-bytes', '536870912');
          await np.setProperty('demuxer-max-back-bytes', '268435456');
          await np.setProperty('demuxer-readahead-secs', '180');
          await np.setProperty('network-timeout', '20');
          await np.setProperty('stream-buffer-size', '33554432');
          await np.setProperty('cache-on-disk', 'no');
          await np.setProperty('interpolation', 'no');
          await np.setProperty('prefetch-playlist', 'no');
        }
      }

      final media = Media(videoUrl);
      await _player!.open(media, play: false);

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
      _hasBitmapSubtitle = false;
      _usingExternalSubtitle = false;

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
          'selected': _trackIdEquals(track.id, _selectedAudioTrackId),
        });
      }
      for (final track in tracks.subtitle) {
        final id = track.id;
        if (id == 'auto' || id == 'no') continue;
        final kind = SubtitleTrackMatcher.classifyKind(
          codec: track.codec,
          title: track.title,
        );
        final isBitmap = kind == SubtitleKind.bitmap;
        final isAss = kind == SubtitleKind.ass;
        trackList.add({
          'id': track.id,
          'type': isBitmap ? 'bitmap' : 'text',
          'title': track.title ?? '', 'language': track.language ?? '',
          'codec': track.codec ?? '',
          'isBitmap': isBitmap,
          'isAss': isAss,
          'selected': _trackIdEquals(track.id, _selectedSubtitleTrackId),
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
  String? _pendingSubtitleTitle;

  void setPendingSubtitle(String codec, {String? title}) {
    _pendingSubtitleLang = null;
    setSubtitleSelectionHint(codec, title: title);
  }

  @override
  void setSubtitleSelectionHint(String? codec, {String? title}) {
    _pendingSubtitleCodec = codec?.toLowerCase();
    _pendingSubtitleTitle = title;
  }

  SubtitleKind _classifySubtitleTrackKind(
    SubtitleTrack track, {
    String? hintedCodec,
    String? hintedTitle,
  }) {
    final trackInfo = _tracks.where((t) => t['id']?.toString() == track.id).firstOrNull;
    return SubtitleTrackMatcher.classifyKind(
      codec: track.codec,
      title: track.title,
      isBitmap: trackInfo?['isBitmap'] == true || trackInfo?['type'] == 'bitmap',
      isAss: trackInfo?['isAss'] == true,
      expectedCodec: hintedCodec,
      expectedTitle: hintedTitle,
    );
  }

  bool _trackIdEquals(dynamic rawId, String? targetId) {
    if (targetId == null) {
      return false;
    }
    return rawId?.toString() == targetId;
  }

  void _markTrackSelected({
    String? subtitleTrackId,
    String? audioTrackId,
  }) {
    if (subtitleTrackId != null) {
      _selectedSubtitleTrackId = subtitleTrackId;
    }
    if (audioTrackId != null) {
      _selectedAudioTrackId = audioTrackId;
    }
    for (final track in _tracks) {
      final type = track['type']?.toString();
      if (_subtitleTrackTypes.contains(type)) {
        track['selected'] = _trackIdEquals(track['id'], _selectedSubtitleTrackId);
      } else if (type == 'audio') {
        track['selected'] = _trackIdEquals(track['id'], _selectedAudioTrackId);
      }
    }
  }

  @override
  Future<void> selectSubtitleTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    _logger.i('MpvAdapter', '选择字幕轨道: id=$trackId, 已知轨道数=${_subtitleTracks.length}');
    try {
      final hintedCodec = _pendingSubtitleCodec;
      final hintedTitle = _pendingSubtitleTitle;
      final realTracks = _subtitleTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
      if (realTracks.isEmpty) {
        _logger.w('MpvAdapter', '轨道列表为空，先用SubtitleTrack.auto()兜底');
        await _player!.setSubtitleTrack(SubtitleTrack.auto());
        _pendingSubtitleLang = trackId;
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
        final kind = _classifySubtitleTrackKind(
          target,
          hintedCodec: hintedCodec,
          hintedTitle: hintedTitle,
        );
        _hasBitmapSubtitle = kind == SubtitleKind.bitmap;
        _currentSubIsAss = kind == SubtitleKind.ass;
        _usingExternalSubtitle = false;
        _logger.i('MpvAdapter', '字幕轨道已选择: id=${target.id}, title=${target.title}, lang=${target.language}, codec=${target.codec}, bitmap=$_hasBitmapSubtitle, ass=$_currentSubIsAss');
        await _player!.setSubtitleTrack(target);
        _markTrackSelected(subtitleTrackId: target.id.toString());
      } else {
        _logger.w('MpvAdapter', '未找到字幕轨道: id=$trackId, 可用: ${realTracks.map((t) => '${t.id}/${t.language}/${t.codec}').toList()}');
        await _player!.setSubtitleTrack(SubtitleTrack.auto());
        _selectedSubtitleTrackId = null;
        _usingExternalSubtitle = false;
        _markTrackSelected();
      }
      _pendingSubtitleCodec = null;
      _pendingSubtitleTitle = null;
      await _applySubtitleRuntimeProperties();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择字幕轨道失败', e, stackTrace);
    }
  }

  Future<void> _tryPendingSubtitleSelection() async {
    if (_pendingSubtitleLang == null) return;
    final realTracks = _subtitleTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (realTracks.isEmpty) return;
    final targetId = _pendingSubtitleLang;
    final targetCodec = _pendingSubtitleCodec;
    final targetTitle = _pendingSubtitleTitle;
    _pendingSubtitleLang = null;
    _pendingSubtitleCodec = null;
    _pendingSubtitleTitle = null;
    _logger.i('MpvAdapter', '延迟选择字幕轨道: id=$targetId, codec=$targetCodec, title=$targetTitle, 可用=${realTracks.length}个');

    var target = realTracks.where((t) => t.id == targetId).firstOrNull;
    if (target == null) {
      final trackInfo = _tracks.where((t) =>
          (t['type'] == 'text' || t['type'] == 'bitmap') &&
          t['id']?.toString() == targetId).firstOrNull;
      if (trackInfo != null) {
        target = realTracks.where((t) => t.id == trackInfo['id']).firstOrNull;
      }
    }

    if (target == null && targetTitle != null && targetTitle.isNotEmpty) {
      for (final t in realTracks) {
        final tTitle = t.title?.toLowerCase() ?? '';
        if (tTitle.isNotEmpty && _matchTitles(targetTitle, tTitle)) {
          target = t;
          break;
        }
      }
    }

    if (target == null && targetCodec != null) {
      final isBitmap = SubtitleTrackMatcher.isGraphicalSubtitleCodec(targetCodec);
      final isAss = SubtitleTrackMatcher.isAssSubtitleCodec(targetCodec);
      final candidates = <SubtitleTrack>[];
      for (final t in realTracks) {
        final kind = _classifySubtitleTrackKind(
          t,
          hintedCodec: targetCodec,
          hintedTitle: targetTitle,
        );
        final tIsBitmap = kind == SubtitleKind.bitmap;
        final tIsAss = kind == SubtitleKind.ass;
        if (isBitmap && tIsBitmap) candidates.add(t);
        if (isAss && tIsAss) candidates.add(t);
      }
      if (candidates.length == 1) {
        target = candidates.first;
      } else if (candidates.length > 1 && targetTitle != null && targetTitle.isNotEmpty) {
        for (final t in candidates) {
          final tTitle = t.title?.toLowerCase() ?? '';
          if (tTitle.isNotEmpty && _matchTitles(targetTitle, tTitle)) {
            target = t;
            break;
          }
        }
        target ??= candidates.first;
      }
      target ??= realTracks.first;
    }

    if (target != null) {
      final kind = _classifySubtitleTrackKind(
        target,
        hintedCodec: targetCodec,
        hintedTitle: targetTitle,
      );
      _hasBitmapSubtitle = kind == SubtitleKind.bitmap;
      _currentSubIsAss = kind == SubtitleKind.ass;
      _usingExternalSubtitle = false;
      await _player!.setSubtitleTrack(target);
      _markTrackSelected(subtitleTrackId: target.id.toString());
      await _applySubtitleRuntimeProperties();
      _logger.i('MpvAdapter', '延迟字幕选择成功: id=${target.id}, title=${target.title}, codec=${target.codec}');
    }
  }

  bool _matchTitles(String embyTitle, String playerTitle) {
    final e = embyTitle.toLowerCase();
    final p = playerTitle.toLowerCase();
    if (e == p) return true;
    if (p.contains(e) || e.contains(p)) return true;
    final simpKeywords = ['简', 'chs', '简体', '简日', 'gb', '简中'];
    final tradKeywords = ['繁', 'cht', '繁体', '繁日', 'big5', '繁中'];
    final eIsSimp = simpKeywords.any((k) => e.contains(k));
    final eIsTrad = tradKeywords.any((k) => e.contains(k));
    final pIsSimp = simpKeywords.any((k) => p.contains(k));
    final pIsTrad = tradKeywords.any((k) => p.contains(k));
    if (eIsSimp && pIsSimp) return true;
    if (eIsTrad && pIsTrad) return true;
    return false;
  }

  @override
  Future<void> deselectSubtitleTrack() async {
    if (_player == null || !_isInitialized) return;
    try {
      await _player!.setSubtitleTrack(SubtitleTrack.no());
      _selectedSubtitleTrackId = null;
      _hasBitmapSubtitle = false;
      _currentSubIsAss = false;
      _usingExternalSubtitle = false;
      _markTrackSelected();
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '关闭字幕失败', e, stackTrace);
    }
  }
  @override
  Future<void> selectAudioTrack(String trackId) async {
    if (_player == null || !_isInitialized) return;
    try {
      final target = _audioTracks.where((t) => _trackIdEquals(t.id, trackId)).firstOrNull;
      if (target != null) {
        await _player!.setAudioTrack(target);
        _markTrackSelected(audioTrackId: target.id.toString());
      }
    } catch (e, stackTrace) {
      _logger.eWithStack('MpvAdapter', '选择音频轨道失败', e, stackTrace);
    }
  }

  @override
  Future<void> loadLibassSubtitle(String path) async {
    _logger.i('MpvAdapter', '加载外挂字幕: $path');
    if (_player == null || !_isInitialized) return;

    try {
      if (_isHttpUrl(path)) {
        _logger.i('MpvAdapter', 'HTTP URL字幕，直接传给mpv加载');
        final ext = _extractExtension(path);
        final isAss = ext == 'ass' || ext == 'ssa' || path.contains('format=ass') || path.contains('Codec=ass');
        final isPgs = ext == 'pgs' || ext == 'sup' || path.contains('format=pgs') || path.contains('Codec=pgs');
        _currentSubIsAss = isAss;
        _hasBitmapSubtitle = isPgs;
        _usingExternalSubtitle = true;
        _logger.i('MpvAdapter', 'HTTP字幕类型: ext=$ext, isAss=$_currentSubIsAss, isBitmap=$_hasBitmapSubtitle');
        final np = _nativePlayer;
        if (_hasBitmapSubtitle && np != null) {
          await np.command(['sub-add', path, 'select', 'External Subtitle', 'und']);
        } else {
          await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        }
        _selectedSubtitleTrackId = 'external';
        await _applySubtitleRuntimeProperties();
        _logger.i('MpvAdapter', 'HTTP外挂字幕加载成功');
        return;
      }

      final ext = _extractExtension(path);

      if (ext == 'pgs' || ext == 'sup') {
        _logger.i('MpvAdapter', '图形字幕 (PGS/SUP)，直接加载: $path');
        _hasBitmapSubtitle = true;
        _currentSubIsAss = false;
        _usingExternalSubtitle = true;
        // 强制关闭 libass 以允许 MPV 原生渲染位图字幕
        final np = _nativePlayer;
        if (np != null) {
          await np.setProperty('sub-ass', 'no');
          await np.setProperty('sub-ass-override', 'no');
          await np.command(['sub-add', path, 'select', 'External Subtitle', 'und']);
        } else {
          await _player!.setSubtitleTrack(SubtitleTrack.uri(path));
        }
        _selectedSubtitleTrackId = 'external';
        await _applySubtitleRuntimeProperties();
        _logger.i('MpvAdapter', '图形字幕加载完成，等待渲染');
        return;
      }

      var processedPath = path;

      if (_subtitleDelay != 0.0) {
        processedPath = await SubtitleProcessor.adjustTiming(processedPath, _subtitleDelay);
      }

      if (ext == 'ass' || ext == 'ssa') {
        _currentSubIsAss = true;
        _hasBitmapSubtitle = false;
        _usingExternalSubtitle = true;
        if (_subtitleFont != null && _subtitleFont != '默认') {
          processedPath = await SubtitleProcessor.modifyAssStyle(
            processedPath,
            fontName: _subtitleFont,
          );
        }
      } else {
        _currentSubIsAss = false;
        _hasBitmapSubtitle = false;
        _usingExternalSubtitle = true;
        _logger.i('MpvAdapter', '文本字幕 (SRT/VTT等)，isAss=false');
      }

      await _player!.setSubtitleTrack(SubtitleTrack.uri(processedPath));
      _selectedSubtitleTrackId = 'external';
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
      await np.setProperty('sub-delay', _subtitleDelay.toStringAsFixed(3));

      if (_hasBitmapSubtitle) {
        // PGS/SUP 等位图字幕：关闭 ASS 处理，避免 libass 干扰原生渲染
        await np.setProperty('sub-ass', 'no');
        await np.setProperty('sub-ass-override', 'no');
        await np.setProperty('sub-back-color', '#00000000');
        await np.setProperty('sub-visibility', 'yes');
        if (_usingExternalSubtitle) {
          await np.setProperty('sub-pos', '100');
        }
        // 位图字幕保留轨道原生布局，只应用缩放。
        await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
        _logger.i('MpvAdapter', '已应用图形字幕(PGS/SUP)配置: scale=$_subtitleScale, ass=no');
      } else if (_currentSubIsAss) {
        await np.setProperty('sub-ass', 'yes');
        // 保留 ASS 原始样式、层级与布局，不用 sub-pos 覆盖内封排版。
        await np.setProperty('sub-ass-override', 'no');
        await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
        if (_subtitleFont != null && _subtitleFont!.isNotEmpty && _subtitleFont != '默认') {
          await np.setProperty('sub-font', _subtitleFont!);
        }
        if (_subtitleBackground) {
          await np.setProperty('sub-back-color', '#000000C0');
        } else {
          await np.setProperty('sub-back-color', '#00000000');
        }
      } else {
        // 普通文本字幕 (SRT/VTT)
        await np.setProperty('sub-ass', 'yes');
        await np.setProperty('sub-ass-override', 'strip');
        await np.setProperty('sub-scale', _subtitleScale.toStringAsFixed(2));
        await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
        if (_subtitleFont != null && _subtitleFont!.isNotEmpty && _subtitleFont != '默认') {
          await np.setProperty('sub-font', _subtitleFont!);
        }
        if (_subtitleBackground) {
          await np.setProperty('sub-back-color', '#000000C0');
        } else {
          await np.setProperty('sub-back-color', '#00000000');
        }
      }

      if (_secondarySid != null) {
        await np.setProperty('secondary-sid', _secondarySid!);
        await np.setProperty('secondary-sub-visibility', 'yes');
      } else {
        // 确保没有次字幕时关闭次字幕显示，避免双字幕问题
        await np.setProperty('secondary-sub-visibility', 'no');
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
        await np.setProperty('secondary-sub-visibility', 'no');
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
    _subtitlePosition = (100 - position * 100).clamp(0.0, 100.0);
    _logger.i('MpvAdapter', '设置字幕位置: pos=$_subtitlePosition');
    final np = _nativePlayer;
    if (np != null) {
      // PGS/SUP 与 ASS 保留轨道自身布局，只有普通文本字幕才覆盖位置。
      if (!_hasBitmapSubtitle && !_currentSubIsAss) {
        await np.setProperty('sub-pos', _subtitlePosition.toStringAsFixed(1));
      }
    }
    await _configManager.updateConfigValue('sub-pos', _subtitlePosition.toStringAsFixed(1));
  }

  @override
  Future<void> setSubtitleBackground(bool enabled) async {
    _subtitleBackground = enabled;
    await _applySubtitleRuntimeProperties();
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

  static final Map<String, List<String>> _anime4KShaderPresets = {
    'modeA': [
      '~~/shaders/Anime4K_Clamp_Highlights.glsl',
      '~~/shaders/Anime4K_Restore_CNN_S.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    'modeB': [
      '~~/shaders/Anime4K_Clamp_Highlights.glsl',
      '~~/shaders/Anime4K_Restore_CNN_M.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl',
      '~~/shaders/Anime4K_AutoDownscalePre_x2.glsl',
      '~~/shaders/Anime4K_AutoDownscalePre_x4.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    'modeC': [
      '~~/shaders/Anime4K_Clamp_Highlights.glsl',
      '~~/shaders/Anime4K_Restore_CNN_VL.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_VL.glsl',
      '~~/shaders/Anime4K_AutoDownscalePre_x2.glsl',
      '~~/shaders/Anime4K_AutoDownscalePre_x4.glsl',
      '~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl',
    ],
  };

  @override
  Future<void> applySuperResolution(bool enable) async {
    _glslShaders = enable ? _anime4KShaderPresets['modeB'] : null;
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('glsl-shaders', _glslShaders?.join(':') ?? '');
    }
  }

  @override
  Future<void> applySuperResolutionLevel(String level) async {
    _glslShaders = level == 'off' ? null : (_anime4KShaderPresets[level] ?? _anime4KShaderPresets['modeB']);
    final np = _nativePlayer;
    if (np != null) {
      await np.setProperty('glsl-shaders', _glslShaders?.join(':') ?? '');
    }
  }

  @override
  Future<Map<String, String>> getPlaybackStats() async {
    final np = _nativePlayer;
    if (np == null) return {};

    final props = [
      'width',
      'height',
      'fps',
      'container-fps',
      'video-bitrate',
      'audio-bitrate',
      'video-codec',
      'audio-codec',
      'audio-params/channel-count',
      'audio-params/sample-rate',
      'file-size',
      'path',
      'demuxer-cache-duration',
      'cache-speed',
      'paused-for-cache',
      'cache-buffering-state',
      'demuxer-cache-state',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'hwdec-current',
      'video-params/pixelformat',
      'estimated-vf-fps',
      'vo-drop-frame-count',
      'vo-delayed-frame-count',
      'current-tracks/video/codec',
      'current-tracks/audio/codec',
      'current-tracks/video/default-bitrate',
      'current-tracks/audio/default-bitrate',
    ];

    final stats = <String, String>{};
    for (final prop in props) {
      try {
        final value = await np.getProperty(prop);
        if (value.isNotEmpty && value != 'null') {
          stats[prop] = value;
        }
      } catch (_) {
        // 某些属性可能不存在，忽略错误
      }
    }
    return stats;
  }

  @override
  Widget buildVideo() {
    if (_videoController != null) {
      return Video(
        controller: _videoController!,
        fit: BoxFit.contain,
        controls: null,
        // Keep Flutter's text subtitle overlay disabled.
        // We rely on mpv's native subtitle pipeline to avoid duplicate ASS
        // rendering and to preserve bitmap subtitle support.
        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
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
    _secondarySid = null;
    _hasBitmapSubtitle = false;
    _currentSubIsAss = false;
    _selectedSubtitleTrackId = null;
    _selectedAudioTrackId = null;
  }
}
