import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'api_interfaces.dart';
import '../utils/danmaku_filter.dart';

class EmbyApiClient implements ApiClientFactory {
  late Dio _dio;
  String _currentLine;
  String? _authToken;
  String? _userId;

  EmbyApiClient({required String baseUrl, String? authToken, String? userId})
      : _currentLine = baseUrl,
        _authToken = authToken,
        _userId = userId {
    _dio = _createDio(baseUrl, authToken);
  }

  static Dio _createDio(String baseUrl, String? authToken) {
    // 确保 baseUrl 以 / 结尾，避免 Dio 拼接路径时丢失子路径
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final dio = Dio(BaseOptions(
      baseUrl: normalizedBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'Linplayer/1.0.0',
        'X-Emby-Authorization': 'MediaBrowser Client="Linplayer", Device="Mobile", DeviceId="linplayer-mobile", Version="1.0.0"',
        'X-Emby-Device-Name': 'Mobile',
        'X-Emby-Device-Id': 'linplayer-mobile',
        'X-Emby-Client': 'Linplayer',
        'X-Emby-Client-Version': '1.0.0',
        if (authToken != null) 'X-Emby-Token': authToken,
      },
    ));
    dio.interceptors.add(LogInterceptor(requestBody: true, responseBody: false));
    return dio;
  }

  void _rebuildDio() {
    _dio = _createDio(_currentLine, _authToken);
  }

  String? get userId => _userId;

  @override
  AuthApi get auth => EmbyAuthApi(this);

  @override
  UserApi get user => EmbyUserApi(this);

  @override
  ServerApi get server => EmbyServerApi(this);

  @override
  HomeApi get home => EmbyHomeApi(this);

  @override
  LibraryApi get library => EmbyLibraryApi(this);

  @override
  MediaApi get media => EmbyMediaApi(this);

  @override
  SearchApi get search => EmbySearchApi(this);

  @override
  PlaybackApi get playback => EmbyPlaybackApi(this);

  @override
  FavoriteApi get favorite => EmbyFavoriteApi(this);

  @override
  SessionApi get session => EmbySessionApi(this);

  @override
  ImageApi get image => EmbyImageApi(this);

  @override
  DanmakuApi get danmaku => EmbyDanmakuApi();

  @override
  void switchLine(String lineUrl) {
    _currentLine = lineUrl;
    _rebuildDio();
  }

  @override
  String get currentLine => _currentLine;

  @override
  void setAuthToken(String token) {
    _authToken = token;
    _dio.options.headers['X-Emby-Token'] = token;
  }

  @override
  void clearAuth() {
    _authToken = null;
    _userId = null;
    _dio.options.headers.remove('X-Emby-Token');
  }

  /// 包装 Dio.get，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> get<T>(String path, {Map<String, dynamic>? queryParameters, Options? options}) {
    return _dio.get<T>(
      path.startsWith('/') ? path.substring(1) : path,
      queryParameters: queryParameters,
      options: options,
    );
  }

  /// 包装 Dio.post，自动去掉路径开头的 /，确保 baseUrl 子路径不被丢弃
  Future<Response<T>> post<T>(String path, {dynamic data, Map<String, dynamic>? queryParameters, Options? options}) {
    return _dio.post<T>(
      path.startsWith('/') ? path.substring(1) : path,
      data: data,
      queryParameters: queryParameters,
      options: options,
    );
  }
}

// ==================== Auth ====================

class EmbyAuthApi implements AuthApi {
  final EmbyApiClient _client;
  EmbyAuthApi(this._client);

  @override
  Future<AuthResult> login({required String username, required String password}) async {
    debugPrint('[EmbyAPI] login: username=$username, baseUrl=${_client.currentLine}');
    
    try {
      final resp = await _client.post('/Users/AuthenticateByName', data: {
        'Username': username,
        'Pw': password,
      });
      debugPrint('[EmbyAPI] login success: ${resp.statusCode}');
      final d = resp.data as Map<String, dynamic>;
      final user = _parseUser(d['User'] as Map<String, dynamic>);
      _client._userId = user.id;
      final token = d['AccessToken'] as String;
      _client.setAuthToken(token);
      return AuthResult(
        accessToken: token,
        userId: user.id,
        serverId: d['ServerId'] as String? ?? '',
        user: user,
      );
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] login failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint('[EmbyAPI] request headers: ${e.requestOptions.headers}');
      debugPrint('[EmbyAPI] request data: ${e.requestOptions.data}');
      debugPrint('[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    try {
      await _client.post('/Sessions/Logout');
    } finally {
      _client.clearAuth();
    }
  }

  @override
  Future<User> getCurrentUser() async {
    final uid = _client._userId;
    if (uid == null) throw Exception('Not authenticated');
    final resp = await _client.get('/Users/$uid');
    return _parseUser(resp.data as Map<String, dynamic>);
  }

  @override
  Future<AuthResult> refreshToken() async {
    return await login(
      username: _client._userId ?? '',
      password: '',
    );
  }
}

// ==================== User ====================

class EmbyUserApi implements UserApi {
  final EmbyApiClient _client;
  EmbyUserApi(this._client);

  @override
  Future<User> getUser(String userId) async {
    final resp = await _client.get('/Users/$userId');
    return _parseUser(resp.data as Map<String, dynamic>);
  }
}

// ==================== Server ====================

class EmbyServerApi implements ServerApi {
  final EmbyApiClient _client;
  EmbyServerApi(this._client);

  @override
  Future<ServerInfo> getPublicInfo(String baseUrl) async {
    // 确保 baseUrl 以 / 结尾
    final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final dio = Dio(BaseOptions(
      baseUrl: normalizedBaseUrl,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'Linplayer/1.0.0',
        'X-Emby-Authorization': 'MediaBrowser Client="Linplayer", Device="Mobile", DeviceId="linplayer-mobile", Version="1.0.0"',
        'X-Emby-Device-Name': 'Mobile',
        'X-Emby-Device-Id': 'linplayer-mobile',
        'X-Emby-Client': 'Linplayer',
        'X-Emby-Client-Version': '1.0.0',
      },
    ));
    
    debugPrint('[EmbyAPI] getPublicInfo: baseUrl=$normalizedBaseUrl');
    
    try {
      final resp = await dio.get('System/Info/Public');
      debugPrint('[EmbyAPI] getPublicInfo success: ${resp.statusCode}');
      return _parseServerInfo(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      debugPrint('[EmbyAPI] getPublicInfo failed: ${e.type} | ${e.message}');
      debugPrint('[EmbyAPI] request URL: ${e.requestOptions.uri}');
      debugPrint('[EmbyAPI] response: ${e.response?.statusCode} | ${e.response?.data}');
      rethrow;
    }
  }

  @override
  Future<ServerInfo> getSystemInfo() async {
    final resp = await _client.get('/System/Info');
    return _parseServerInfo(resp.data as Map<String, dynamic>);
  }

  @override
  Future<bool> testConnection(String baseUrl) async {
    try {
      // 确保 baseUrl 以 / 结尾
      final normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
      final dio = Dio(BaseOptions(
        baseUrl: normalizedBaseUrl,
        connectTimeout: const Duration(seconds: 5),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'User-Agent': 'Linplayer/1.0.0',
          'X-Emby-Authorization': 'MediaBrowser Client="Linplayer", Device="Mobile", DeviceId="linplayer-mobile", Version="1.0.0"',
          'X-Emby-Device-Name': 'Mobile',
          'X-Emby-Device-Id': 'linplayer-mobile',
          'X-Emby-Client': 'Linplayer',
          'X-Emby-Client-Version': '1.0.0',
        },
      ));
      await dio.get('System/Info/Public');
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ==================== Home ====================

class EmbyHomeApi implements HomeApi {
  final EmbyApiClient _client;
  EmbyHomeApi(this._client);

  @override
  Future<List<MediaItem>> getResumeItems() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items/Resume', queryParameters: {
      'Limit': 12,
      'MediaTypes': 'Video',
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber',
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<List<MediaItem>> getNextUp() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Shows/NextUp', queryParameters: {
      'UserId': uid,
      'Limit': 12,
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber',
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<List<Library>> getLibraries() async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Views');
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseLibrary(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<MediaItem>> getLatestItems(String libraryId, {int limit = 20}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items/Latest', queryParameters: {
      'ParentId': libraryId,
      'Limit': limit,
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber',
    });
    final items = resp.data as List<dynamic>;
    return items.map((e) => _parseMediaItem(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<MediaItem>> getRandomRecommendations({int limit = 8}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'Limit': limit,
      'SortBy': 'Random',
      'IncludeItemTypes': 'Movie,Series',
      'Recursive': true,
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,BackdropImageTags',
    });
    return _parseItemList(resp.data);
  }
}

// ==================== Library ====================

class EmbyLibraryApi implements LibraryApi {
  final EmbyApiClient _client;
  EmbyLibraryApi(this._client);

  @override
  Future<List<MediaItem>> getLibraryItems({
    required String libraryId,
    String? sortBy,
    String? sortOrder,
    int startIndex = 0,
    int limit = 50,
  }) async {
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'ParentId': libraryId,
      'UserId': uid,
      'StartIndex': startIndex,
      'Limit': limit,
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series',
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber',
    };
    if (sortBy != null) {
      params['SortBy'] = sortBy;
      params['SortOrder'] = sortOrder ?? 'Ascending';
    }
    final resp = await _client.get('/Users/$uid/Items', queryParameters: params);
    return _parseItemList(resp.data);
  }

  @override
  Future<Filters> getFilters(String libraryId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Items/Filters', queryParameters: {
      'UserId': uid,
      'ParentId': libraryId,
    });
    final d = resp.data as Map<String, dynamic>;
    return Filters(
      genres: (d['Genres'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      years: (d['Years'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      officialRatings: (d['OfficialRatings'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
    );
  }
}

// ==================== Media ====================

class EmbyMediaApi implements MediaApi {
  final EmbyApiClient _client;
  EmbyMediaApi(this._client);

  @override
  Future<MediaItem> getItemDetails(String itemId) async {
    if (itemId.isEmpty) {
      throw Exception('无效的媒体ID');
    }
    final uid = _client._userId;
    final params = <String, dynamic>{
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber,People,Studios',
    };
    if (uid != null) params['UserId'] = uid;
    try {
      final resp = await _client.get('/Items/$itemId', queryParameters: params);
      return _parseMediaItem(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 && uid != null) {
        try {
          final resp = await _client.get('/Users/$uid/Items/$itemId', queryParameters: params);
          return _parseMediaItem(resp.data as Map<String, dynamic>);
        } catch (_) {
          // fallback 失败，继续抛出原始错误
        }
      }
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> getSimilarItems(String itemId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Items/$itemId/Similar', queryParameters: {
      'UserId': uid,
      'Limit': 12,
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags',
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseMediaItem(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Season>> getSeasons(String seriesId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Shows/$seriesId/Seasons', queryParameters: {
      'UserId': uid,
      'Fields': 'Overview',
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseSeason(e as Map<String, dynamic>, seriesId)).toList();
  }

  @override
  Future<List<Episode>> getEpisodes(String seriesId, {String? seasonId}) async {
    final uid = _requireUserId(_client);
    final params = <String, dynamic>{
      'UserId': uid,
      'Fields': 'Overview,RunTimeTicks',
    };
    if (seasonId != null) params['SeasonId'] = seasonId;
    final resp = await _client.get('/Shows/$seriesId/Episodes', queryParameters: params);
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parseEpisode(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Person>> getPersonItems(String personName) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Persons/$personName/Items', queryParameters: {
      'UserId': uid,
      'Limit': 20,
    });
    final items = (resp.data as Map<String, dynamic>)['Items'] as List<dynamic>;
    return items.map((e) => _parsePersonFromItem(e as Map<String, dynamic>)).toList();
  }
}

// ==================== Search ====================

class EmbySearchApi implements SearchApi {
  final EmbyApiClient _client;
  EmbySearchApi(this._client);

  @override
  Future<List<MediaItem>> getSearchHints(String query) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Search/Hints', queryParameters: {
      'UserId': uid,
      'SearchTerm': query,
      'Limit': 20,
    });
    final hints = (resp.data as Map<String, dynamic>)['SearchHints'] as List<dynamic>;
    return hints.map((e) => _parseMediaItem(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<MediaItem>> search(String query, {bool recursive = true}) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'SearchTerm': query,
      'Recursive': recursive,
      'Limit': 50,
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber',
    });
    return _parseItemList(resp.data);
  }

  @override
  Future<Map<String, List<MediaItem>>> searchAggregate(String query) async {
    final uid = _requireUserId(_client);
    final resp = await _client.get('/Users/$uid/Items', queryParameters: {
      'SearchTerm': query,
      'Recursive': true,
      'Limit': 50,
      'Fields': 'Overview,Genres,CommunityRating,OfficialRating,PremiereDate,RunTimeTicks,ProductionYear,Tags,SeriesName,IndexNumber,ParentIndexNumber',
    });
    final items = _parseItemList(resp.data);
    final serverName = _client._dio.options.baseUrl;
    return {serverName: items};
  }
}

// ==================== Playback ====================

class EmbyPlaybackApi implements PlaybackApi {
  final EmbyApiClient _client;
  EmbyPlaybackApi(this._client);

  @override
  Future<PlaybackInfo> getPlaybackInfo(String itemId) async {
    final uid = _requireUserId(_client);
    final resp = await _client.post('/Items/$itemId/PlaybackInfo', data: {
      'UserId': uid,
      'StartTimeTicks': 0,
      'IsPlayback': true,
      'AutoOpenLiveStream': true,
    });
    return _parsePlaybackInfo(resp.data as Map<String, dynamic>, itemId);
  }

  @override
  String getVideoStreamUrl(String itemId) {
    final base = _client._currentLine;
    final token = _client._authToken;
    return '$base/Videos/$itemId/stream?static=true${token != null ? '&api_key=$token' : ''}';
  }

  @override
  String getSubtitleStreamUrl(String itemId, String mediaSourceId, int index, String codec) {
    final base = _client._currentLine;
    final token = _client._authToken;
    return '$base/Videos/$itemId/$mediaSourceId/Subtitles/$index/Stream.$codec${token != null ? '?api_key=$token' : ''}';
  }

  @override
  Future<void> reportPlaybackStart(PlaybackStartInfo info) async {
    await _client.post('/Sessions/Playing', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'AudioStreamIndex': info.audioStreamIndex,
      'SubtitleStreamIndex': info.subtitleStreamIndex,
      'PlayMethod': info.playMethod ?? 'DirectStream',
    });
  }

  @override
  Future<void> reportPlaybackProgress(PlaybackProgressInfo info) async {
    await _client.post('/Sessions/Playing/Progress', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'PositionTicks': info.positionTicks,
      'IsPaused': info.isPaused,
      'IsMuted': info.isMuted,
      'VolumeLevel': (info.volumeLevel * 100).round(),
    });
  }

  @override
  Future<void> reportPlaybackStopped(PlaybackStopInfo info) async {
    await _client.post('/Sessions/Playing/Stopped', data: {
      'ItemId': info.itemId,
      'MediaSourceId': info.mediaSourceId,
      'PositionTicks': info.positionTicks,
    });
  }
}

// ==================== Favorite ====================

class EmbyFavoriteApi implements FavoriteApi {
  final EmbyApiClient _client;
  EmbyFavoriteApi(this._client);

  @override
  Future<void> addFavorite(String itemId) async {
    final uid = _requireUserId(_client);
    await _client.post('/Users/$uid/FavoriteItems/$itemId');
  }

  @override
  Future<void> removeFavorite(String itemId) async {
    final uid = _requireUserId(_client);
    await _client._dio.delete('/Users/$uid/FavoriteItems/$itemId');
  }
}

// ==================== Session ====================

class EmbySessionApi implements SessionApi {
  final EmbyApiClient _client;
  EmbySessionApi(this._client);

  @override
  Future<List<Session>> getSessions() async {
    final resp = await _client.get('/Sessions');
    final items = resp.data as List<dynamic>;
    return items.map((e) => _parseSession(e as Map<String, dynamic>)).toList();
  }
}

// ==================== Image ====================

class EmbyImageApi implements ImageApi {
  final EmbyApiClient _client;
  EmbyImageApi(this._client);

  @override
  String getImageUrl({
    required String itemId,
    String? imageTag,
    String imageType = 'Primary',
    int? maxWidth,
    int? maxHeight,
    double quality = 90,
  }) {
    final base = _client._currentLine;
    final buf = StringBuffer('$base/Items/$itemId/Images/$imageType');
    final params = <String, String>{};
    if (maxWidth != null) params['maxWidth'] = maxWidth.toString();
    if (maxHeight != null) params['maxHeight'] = maxHeight.toString();
    params['quality'] = quality.round().toString();
    if (_client._authToken != null) params['tag'] = _client._authToken!;
    if (imageTag != null) params['tag'] = imageTag;
    if (params.isNotEmpty) {
      buf.write('?');
      buf.write(params.entries.map((e) => '${e.key}=${e.value}').join('&'));
    }
    return buf.toString();
  }

  @override
  String getPrimaryImageUrl(String itemId, {String? tag, int? maxWidth}) {
    return getImageUrl(itemId: itemId, imageTag: tag, imageType: 'Primary', maxWidth: maxWidth);
  }

  @override
  String getBackdropImageUrl(String itemId, {String? tag, int? maxWidth}) {
    return getImageUrl(
      itemId: itemId,
      imageTag: tag,
      imageType: 'Backdrop',
      maxWidth: maxWidth ?? 800,
      maxHeight: 450,
    );
  }
}

// ==================== Danmaku ====================

class EmbyDanmakuApi implements DanmakuApi {
  DanmakuFilter? _filter;

  /// 设置弹幕过滤器
  void setFilter(DanmakuFilter filter) {
    _filter = filter;
  }

  @override
  Future<List<DanmakuItem>> searchDanmaku({
    required String title,
    int? episode,
    String? source,
  }) async {
    final src = source ?? 'dandanplay';
    switch (src) {
      case 'dandanplay':
        return _searchDandanplay(title, episode);
      case 'danmu_api':
        return _searchDanmuApi(title, episode);
      case 'misaka':
        return _searchMisaka(title, episode);
      default:
        return [];
    }
  }

  @override
  Future<List<DanmakuItem>> getDanmakuComments(String episodeId) async {
    try {
      final dio = Dio();
      final resp = await dio.get('https://api.dandanplay.com/api/v2/comment/$episodeId');
      final comments = (resp.data as Map<String, dynamic>)['comments'] as List<dynamic>;
      final items = comments.map((e) {
        final d = e as Map<String, dynamic>;
        final p = (d['p'] as String?)?.split(',') ?? [];
        return DanmakuItem(
          time: double.tryParse(p.isNotEmpty ? p[0] : '0') ?? 0.0,
          text: d['m'] as String? ?? '',
          type: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0,
          color: int.tryParse(p.length > 2 ? p[2] : '0xFFFFFFFF') ?? 0xFFFFFFFF,
          size: double.tryParse(p.length > 3 ? p[3] : '25') ?? 25,
        );
      }).toList();

      // 应用屏蔽词过滤
      if (_filter != null) {
        return items.where((item) {
          return !_filter!.shouldFilter(item.text);
        }).toList();
      }

      return items;
    } catch (_) {
      return [];
    }
  }

  Future<List<DanmakuItem>> _searchDandanplay(String title, int? episode) async {
    try {
      final dio = Dio();
      final resp = await dio.get('https://api.dandanplay.com/api/v2/search/episodes', queryParameters: {
        'anime': title,
      });
      final animes = (resp.data as Map<String, dynamic>)['animes'] as List<dynamic>;
      if (animes.isEmpty) return [];
      final first = animes.first as Map<String, dynamic>;
      final eps = first['episodes'] as List<dynamic>;
      if (eps.isEmpty) return [];
      final targetEp = episode != null
          ? eps.cast<Map<String, dynamic>>().firstWhere(
              (e) => e['episodeTitle']?.toString().contains(episode.toString()) ?? false,
              orElse: () => eps.first as Map<String, dynamic>,
            )
          : eps.first as Map<String, dynamic>;
      final epId = targetEp['episodeId'].toString();
      return await getDanmakuComments(epId);
    } catch (_) {
      return [];
    }
  }

  Future<List<DanmakuItem>> _searchDanmuApi(String title, int? episode) async {
    return [];
  }

  Future<List<DanmakuItem>> _searchMisaka(String title, int? episode) async {
    return [];
  }
}

// ==================== Parse Helpers ====================

String _requireUserId(EmbyApiClient c) {
  final uid = c._userId;
  if (uid == null) throw Exception('Not authenticated: userId missing');
  return uid;
}

User _parseUser(Map<String, dynamic> d) {
  return User(
    id: d['Id'] ?? d['UserId'] ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: d['PrimaryImageTag']?.toString(),
    hasPassword: d['HasPassword'] as bool?,
    configuration: (d['Configuration'] as Map<String, dynamic>?)?.keys.toList(),
  );
}

ServerInfo _parseServerInfo(Map<String, dynamic> d) {
  return ServerInfo(
    id: d['Id']?.toString() ?? '',
    serverName: d['ServerName'] ?? '',
    version: d['Version'] ?? '',
    productName: d['ProductName']?.toString(),
    operatingSystem: d['OperatingSystem']?.toString(),
  );
}

List<MediaItem> _parseItemList(dynamic data) {
  final d = data as Map<String, dynamic>;
  final items = (d['Items'] ?? d) as List<dynamic>;
  return items.map((e) => _parseMediaItem(e as Map<String, dynamic>)).toList();
}

MediaItem _parseMediaItem(Map<String, dynamic> d) {
  final ud = d['UserData'] as Map<String, dynamic>?;
  return MediaItem(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    type: d['Type'] ?? '',
    overview: d['Overview']?.toString(),
    primaryImageTag: _extractImageTag(d, 'Primary'),
    backdropImageTag: _extractImageTag(d, 'Backdrop'),
    communityRating: (d['CommunityRating'] as num?)?.toDouble(),
    officialRating: d['OfficialRating']?.toString(),
    premiereDate: _parseDate(d['PremiereDate']),
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    productionYear: d['ProductionYear'] as int?,
    genres: (d['Genres'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    tags: (d['Tags'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
    userData: ud != null
        ? UserData(
            playbackPositionTicks: _parseTicksDouble(ud['PlaybackPositionTicks']),
            played: ud['Played'] as bool?,
            isFavorite: ud['IsFavorite'] as bool?,
            playCount: (ud['PlayCount'] as num?)?.toDouble(),
          )
        : null,
    seriesName: d['SeriesName']?.toString(),
    indexNumber: d['IndexNumber'] as int?,
    parentIndexNumber: d['ParentIndexNumber'] as int?,
    seriesId: d['SeriesId']?.toString(),
    seasonId: d['SeasonId']?.toString(),
    mediaType: d['MediaType']?.toString(),
    parentId: d['ParentId']?.toString(),
  );
}

String? _extractImageTag(Map<String, dynamic> d, String type) {
  final tags = d['ImageTags'] as Map<String, dynamic>?;
  return tags?[type]?.toString();
}

int? _parseTicks(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}

double? _parseTicksDouble(dynamic v) {
  final t = _parseTicks(v);
  return t?.toDouble();
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

Library _parseLibrary(Map<String, dynamic> d) {
  return Library(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: _extractImageTag(d, 'Primary'),
    collectionType: d['CollectionType']?.toString() ?? 'mixed',
  );
}

Season _parseSeason(Map<String, dynamic> d, String seriesId) {
  return Season(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    indexNumber: d['IndexNumber'] as int?,
    primaryImageTag: _extractImageTag(d, 'Primary'),
    seriesId: d['SeriesId']?.toString() ?? seriesId,
  );
}

Episode _parseEpisode(Map<String, dynamic> d) {
  final ud = d['UserData'] as Map<String, dynamic>?;
  return Episode(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    indexNumber: d['IndexNumber'] as int?,
    primaryImageTag: _extractImageTag(d, 'Primary'),
    seriesId: d['SeriesId']?.toString() ?? '',
    seasonId: d['SeasonId']?.toString() ?? '',
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    userData: ud != null
        ? UserData(
            playbackPositionTicks: _parseTicksDouble(ud['PlaybackPositionTicks']),
            played: ud['Played'] as bool?,
            isFavorite: ud['IsFavorite'] as bool?,
          )
        : null,
    overview: d['Overview']?.toString(),
  );
}

Person _parsePersonFromItem(Map<String, dynamic> d) {
  return Person(
    id: d['Id']?.toString() ?? '',
    name: d['Name'] ?? '',
    primaryImageTag: _extractImageTag(d, 'Primary'),
    role: d['Role']?.toString(),
    type: d['Type']?.toString(),
  );
}

Session _parseSession(Map<String, dynamic> d) {
  final npi = d['NowPlayingItem'] as Map<String, dynamic>?;
  return Session(
    id: d['Id']?.toString() ?? '',
    userName: d['UserName']?.toString(),
    client: d['Client']?.toString(),
    deviceName: d['DeviceName']?.toString(),
    isNowPlaying: d['IsNowPlaying'] as bool?,
    nowPlayingItem: npi != null
        ? NowPlayingItem(
            id: npi['Id']?.toString() ?? '',
            name: npi['Name'] ?? '',
            seriesName: npi['SeriesName']?.toString(),
            runTimeTicks: _parseTicks(npi['RunTimeTicks']),
            playbackPositionTicks: _parseTicks(npi['PlaybackPositionTicks']),
          )
        : null,
  );
}

PlaybackInfo _parsePlaybackInfo(Map<String, dynamic> d, String itemId) {
  final sources = (d['MediaSources'] as List<dynamic>?) ?? [];
  return PlaybackInfo(
    itemId: d['ItemId']?.toString() ?? itemId,
    mediaSources: sources.map((e) => _parseMediaSource(e as Map<String, dynamic>)).toList(),
  );
}

MediaSource _parseMediaSource(Map<String, dynamic> d) {
  final streams = (d['MediaStreams'] as List<dynamic>?) ?? [];
  return MediaSource(
    id: d['Id']?.toString() ?? '',
    name: d['Name']?.toString(),
    path: d['Path']?.toString(),
    container: d['Container']?.toString(),
    size: d['Size'] as int?,
    runTimeTicks: _parseTicks(d['RunTimeTicks']),
    mediaStreams: streams.map((e) => _parseMediaStream(e as Map<String, dynamic>)).toList(),
  );
}

MediaStream _parseMediaStream(Map<String, dynamic> d) {
  return MediaStream(
    index: d['Index'] as int? ?? 0,
    type: d['Type'] ?? '',
    codec: d['Codec']?.toString(),
    language: d['Language']?.toString(),
    title: d['Title']?.toString(),
    isDefault: d['IsDefault'] as bool?,
    isExternal: d['IsExternal'] as bool?,
    displayTitle: d['DisplayTitle']?.toString(),
    videoCodec: d['VideoCodec']?.toString() ?? d['Codec']?.toString(),
    width: d['Width'] as int?,
    height: d['Height'] as int?,
    channels: d['Channels'] as int?,
  );
}
