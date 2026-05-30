import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../api_interfaces.dart';

enum DanmakuSourceType { dandanplay, custom }

class DanmakuSourceConfig {
  final String id;
  final DanmakuSourceType type;
  final String name;
  final String apiUrl;
  final int priority;
  final bool enabled;

  DanmakuSourceConfig({
    required this.id,
    required this.type,
    required this.name,
    required this.apiUrl,
    this.priority = 0,
    this.enabled = true,
  });

  String get baseUrl {
    var url = apiUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/api/v2')) return url;
    if (url.endsWith('/api/v1')) return '$url/api/v2';
    return url;
  }
}

abstract class DanmakuSource {
  DanmakuSourceConfig get config;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));
  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  });

  Future<DanmakuSearchResult> searchAnime({required String keyword});

  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  });

  Future<DanmakuAnime> getBangumiDetails({required String bangumiId});

  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  });

  DanmakuItem _parseComment(Map<String, dynamic> d, {String? sourceName}) {
    final p = (d['p'] as String?)?.split(',') ?? [];
    return DanmakuItem(
      time: double.tryParse(p.isNotEmpty ? p[0] : '0') ?? 0.0,
      text: d['m'] as String? ?? '',
      type: p.length > 1 ? (int.tryParse(p[1]) ?? 1) : 1,
      color: p.length > 2 ? (int.tryParse(p[2]) ?? 16777215) : 16777215,
      size: p.length > 3 ? (double.tryParse(p[3]) ?? 25) : 25,
      source: sourceName,
      cid: d['cid']?.toString(),
      userId: p.length > 3 ? p[3] : null,
    );
  }
}

class DandanplaySource extends DanmakuSource {
  @override
  final DanmakuSourceConfig config;
  final String appId;
  final List<String> _appSecrets;
  static const String _baseUrl = 'https://api.dandanplay.net';
  static final _random = Random();

  DandanplaySource({
    required this.config,
    required String appSecret,
    required this.appId,
  }) : _appSecrets = appSecret.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  String get _currentSecret => _appSecrets[_random.nextInt(_appSecrets.length)];

  String _generateSignature(String path, int timestamp, String secret) {
    final data = '$appId$timestamp$path$secret';
    final bytes = utf8.encode(data);
    final hash = sha256.convert(bytes);
    return base64.encode(hash.bytes);
  }

  Options _authOptions(String path) {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final secret = _currentSecret;
    final signature = _generateSignature(path, timestamp, secret);
    return Options(headers: {
      'X-AppId': appId,
      'X-Timestamp': timestamp.toString(),
      'X-Signature': signature,
    });
  }

  @override
  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async {
    const path = '/api/v2/match';
    final resp = await _dio.post(
      '$_baseUrl$path',
      data: {
        'fileName': fileName,
        'fileHash': fileHash ?? '',
        'fileSize': fileSize ?? 0,
        'videoDuration': videoDuration ?? 0,
      },
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final isMatched = data['isMatched'] as bool? ?? false;
    final matches = (data['matches'] as List<dynamic>? ?? [])
        .map((m) {
      final item = m as Map<String, dynamic>;
      return DanmakuMatchItem(
        episodeId: item['episodeId']?.toString() ?? '',
        animeId: item['animeId']?.toString() ?? '',
        animeTitle: item['animeTitle'] as String? ?? '',
        episodeTitle: item['episodeTitle'] as String? ?? '',
        type: item['type']?.toString(),
        typeDescription: item['typeDescription'] as String?,
        shift: item['shift'] as int?,
      );
    }).toList();
    return DanmakuMatchResult(isMatched: isMatched, matches: matches);
  }

  @override
  Future<DanmakuSearchResult> searchAnime({required String keyword}) async {
    const path = '/api/v2/search/anime';
    final resp = await _dio.get(
      '$_baseUrl$path',
      queryParameters: {'keyword': keyword},
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final animes = (data['animes'] as List<dynamic>? ?? [])
        .map((a) => _parseAnime(a as Map<String, dynamic>))
        .toList();
    return DanmakuSearchResult(animes: animes);
  }

  @override
  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  }) async {
    const path = '/api/v2/search/episodes';
    final params = <String, dynamic>{};
    if (anime != null) params['anime'] = anime;
    if (tmdbId != null) params['tmdbId'] = tmdbId;
    if (episode != null) params['episode'] = episode;
    final resp = await _dio.get(
      '$_baseUrl$path',
      queryParameters: params,
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final hasMore = data['hasMore'] as bool? ?? false;
    final animes = (data['animes'] as List<dynamic>? ?? [])
        .map((a) => _parseAnimeWithEpisodes(a as Map<String, dynamic>))
        .toList();
    return DanmakuSearchResult(animes: animes, hasMore: hasMore);
  }

  @override
  Future<DanmakuAnime> getBangumiDetails({required String bangumiId}) async {
    final path = '/api/v2/bangumi/$bangumiId';
    final resp = await _dio.get(
      '$_baseUrl$path',
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final bangumi = data['bangumi'] as Map<String, dynamic>? ?? data;
    return _parseAnimeWithEpisodes(bangumi);
  }

  Future<DanmakuAnime> getBangumiByBgmtvId({required int bgmtvSubjectId}) async {
    final path = '/api/v2/bangumi/bgmtv/$bgmtvSubjectId';
    final resp = await _dio.get(
      '$_baseUrl$path',
      options: _authOptions(path),
    );
    final data = resp.data as Map<String, dynamic>;
    final bangumi = data['bangumi'] as Map<String, dynamic>? ?? data;
    return _parseAnimeWithEpisodes(bangumi);
  }

  @override
  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  }) async {
    final path = '/api/v2/comment/$episodeId';
    final params = <String, dynamic>{
      'withRelated': withRelated,
      'chConvert': chConvert,
    };
    if (from != null) params['from'] = from;
    try {
      final resp = await _dio.get(
        '$_baseUrl$path',
        queryParameters: params,
        options: _authOptions(path),
      );
      final data = resp.data as Map<String, dynamic>;
      final comments = data['comments'] as List<dynamic>? ?? [];
      return comments
          .map((c) => _parseComment(c as Map<String, dynamic>, sourceName: 'dandanplay'))
          .toList();
    } catch (_) {
      return [];
    }
  }

  DanmakuAnime _parseAnime(Map<String, dynamic> a) {
    return DanmakuAnime(
      animeId: a['animeId']?.toString() ?? '',
      animeTitle: a['animeTitle'] as String? ?? '',
      bangumiId: a['bangumiId']?.toString(),
      type: a['type']?.toString(),
      typeDescription: a['typeDescription'] as String?,
      imageUrl: a['imageUrl'] as String?,
      year: a['year'] as int?,
      episodeCount: a['episodeCount'] as int?,
    );
  }

  DanmakuAnime _parseAnimeWithEpisodes(Map<String, dynamic> a) {
    final episodes = (a['episodes'] as List<dynamic>? ?? [])
        .map((e) {
      final ep = e as Map<String, dynamic>;
      return DanmakuEpisode(
        episodeId: ep['episodeId']?.toString() ?? '',
        episodeTitle: ep['episodeTitle'] as String? ?? '',
        episodeNumber: ep['episodeNumber']?.toString(),
      );
    }).toList();
    return DanmakuAnime(
      animeId: a['animeId']?.toString() ?? '',
      animeTitle: a['animeTitle'] as String? ?? '',
      bangumiId: a['bangumiId']?.toString(),
      type: a['type']?.toString(),
      typeDescription: a['typeDescription'] as String?,
      imageUrl: a['imageUrl'] as String?,
      year: a['year'] as int?,
      episodeCount: a['episodeCount'] as int?,
      episodes: episodes,
    );
  }
}

class CustomDanmakuSource extends DanmakuSource {
  @override
  final DanmakuSourceConfig config;

  CustomDanmakuSource({required this.config});

  @override
  Future<DanmakuMatchResult> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    double? videoDuration,
  }) async {
    final url = config.baseUrl;
    try {
      final resp = await _dio.post(
        '$url/match',
        data: {
          'fileName': fileName,
          'fileHash': fileHash ?? '',
          'fileSize': fileSize ?? 0,
          'videoDuration': videoDuration ?? 0,
        },
      );
      final data = resp.data as Map<String, dynamic>;
      final isMatched = data['isMatched'] as bool? ?? false;
      final matches = (data['matches'] as List<dynamic>? ?? [])
          .map((m) {
        final item = m as Map<String, dynamic>;
        return DanmakuMatchItem(
          episodeId: item['episodeId']?.toString() ?? '',
          animeId: item['animeId']?.toString() ?? '',
          animeTitle: item['animeTitle'] as String? ?? '',
          episodeTitle: item['episodeTitle'] as String? ?? '',
          type: item['type']?.toString(),
          typeDescription: item['typeDescription'] as String?,
          shift: item['shift'] as int?,
        );
      }).toList();
      return DanmakuMatchResult(isMatched: isMatched, matches: matches);
    } catch (_) {
      return DanmakuMatchResult(isMatched: false, matches: []);
    }
  }

  @override
  Future<DanmakuSearchResult> searchAnime({required String keyword}) async {
    final url = config.baseUrl;
    try {
      final resp = await _dio.get('$url/search/anime', queryParameters: {
        'keyword': keyword,
      });
      final data = resp.data as Map<String, dynamic>;
      final animes = (data['animes'] as List<dynamic>? ?? [])
          .map((a) => _parseAnime(a as Map<String, dynamic>))
          .toList();
      return DanmakuSearchResult(animes: animes);
    } catch (_) {
      return DanmakuSearchResult(animes: []);
    }
  }

  @override
  Future<DanmakuSearchResult> searchEpisodes({
    String? anime,
    int? tmdbId,
    String? episode,
  }) async {
    final url = config.baseUrl;
    final params = <String, dynamic>{};
    if (anime != null) params['anime'] = anime;
    if (episode != null) params['episode'] = episode;
    try {
      final resp = await _dio.get('$url/search/episodes', queryParameters: params);
      final data = resp.data as Map<String, dynamic>;
      final hasMore = data['hasMore'] as bool? ?? false;
      final animes = (data['animes'] as List<dynamic>? ?? [])
          .map((a) => _parseAnimeWithEpisodes(a as Map<String, dynamic>))
          .toList();
      return DanmakuSearchResult(animes: animes, hasMore: hasMore);
    } catch (_) {
      return DanmakuSearchResult(animes: []);
    }
  }

  @override
  Future<DanmakuAnime> getBangumiDetails({required String bangumiId}) async {
    final url = config.baseUrl;
    final resp = await _dio.get('$url/bangumi/$bangumiId');
    final data = resp.data as Map<String, dynamic>;
    final bangumi = data['bangumi'] as Map<String, dynamic>? ?? data;
    return _parseAnimeWithEpisodes(bangumi);
  }

  @override
  Future<List<DanmakuItem>> getComments({
    required String episodeId,
    int? from,
    bool withRelated = true,
    int chConvert = 0,
  }) async {
    final url = config.baseUrl;
    final params = <String, dynamic>{
      'async': '1',
    };
    if (from != null) params['from'] = from;
    if (withRelated) params['withRelated'] = 'true';
    if (chConvert != 0) params['chConvert'] = chConvert;
    params['format'] = 'json';
    try {
      final resp = await _dio.get('$url/comment/$episodeId', queryParameters: params);
      final data = resp.data as Map<String, dynamic>;

      final taskId = data['taskId']?.toString();
      if (taskId != null && taskId.isNotEmpty) {
        return _pollAsyncComments(url, taskId);
      }

      final comments = data['comments'] as List<dynamic>? ?? [];
      return comments
          .map((c) => _parseComment(c as Map<String, dynamic>, sourceName: config.name))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<DanmakuItem>> _pollAsyncComments(String url, String taskId) async {
    const interval = Duration(seconds: 2);
    const maxAttempts = 15;
    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(interval);
      try {
        final resp = await _dio.get('$url/taskcomment/$taskId');
        final data = resp.data as Map<String, dynamic>;

        final status = data['status']?.toString();
        if (status == 'pending' || status == 'processing') continue;

        final comments = data['comments'] as List<dynamic>? ?? [];
        return comments
            .map((c) => _parseComment(c as Map<String, dynamic>, sourceName: config.name))
            .toList();
      } catch (_) {
        continue;
      }
    }
    return [];
  }

  DanmakuAnime _parseAnime(Map<String, dynamic> a) {
    return DanmakuAnime(
      animeId: a['animeId']?.toString() ?? '',
      animeTitle: a['animeTitle'] as String? ?? '',
      bangumiId: a['bangumiId']?.toString(),
      type: a['type']?.toString(),
      typeDescription: a['typeDescription'] as String?,
      imageUrl: a['imageUrl'] as String?,
      year: a['year'] as int?,
      episodeCount: a['episodeCount'] as int?,
    );
  }

  DanmakuAnime _parseAnimeWithEpisodes(Map<String, dynamic> a) {
    final episodes = (a['episodes'] as List<dynamic>? ?? [])
        .map((e) {
      final ep = e as Map<String, dynamic>;
      return DanmakuEpisode(
        episodeId: ep['episodeId']?.toString() ?? '',
        episodeTitle: ep['episodeTitle'] as String? ?? '',
        episodeNumber: ep['episodeNumber']?.toString(),
      );
    }).toList();
    return DanmakuAnime(
      animeId: a['animeId']?.toString() ?? '',
      animeTitle: a['animeTitle'] as String? ?? '',
      bangumiId: a['bangumiId']?.toString(),
      type: a['type']?.toString(),
      typeDescription: a['typeDescription'] as String?,
      imageUrl: a['imageUrl'] as String?,
      year: a['year'] as int?,
      episodeCount: a['episodeCount'] as int?,
      episodes: episodes,
    );
  }
}
