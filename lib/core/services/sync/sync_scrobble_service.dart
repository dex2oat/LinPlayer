import '../../api/api_interfaces.dart';
import '../../api/danmaku/danmaku_source.dart';
import '../app_logger.dart';
import 'bangumi_matcher.dart';
import 'bangumi_sync_service.dart';
import 'sync_models.dart';
import 'trakt_sync_service.dart';

/// 一次观看上报的结果：每个已连接服务是否成功写入。
class SyncScrobbleResult {
  final Map<SyncService, bool> results;
  const SyncScrobbleResult(this.results);

  bool get anySucceeded => results.values.any((ok) => ok);
  bool succeeded(SyncService service) => results[service] ?? false;
}

/// 观看记录自动同步：把「已看完的影片/剧集」映射成 Trakt/Bangumi 的写入调用。
///
<<<<<<< HEAD
/// 仅对「已连接」的服务上报（连接与否 = 用户的开关）。
/// - Trakt：直接用 Emby ProviderIds——影片 imdb/tmdb，剧集 tvdb/tmdb/imdb。
/// - Bangumi 反查 subject/episode，三级回退：
///   1. Emby 自带 Bangumi providerId（最快）；
///   2. 弹弹play：文件名/剧名匹配作品 → 详情 `bangumiUrl` 抠 subject id（首选）；
///   3. Bangumi API：`/v0/search/subjects` + 开播日期择优 + 续集链（兜底）。
///   全部失败则静默跳过，不影响播放与 Trakt。
=======
/// 仅对「已连接」的服务上报（连接与否 = 用户的开关）。映射依赖 Emby 项目自带的
/// ProviderIds：
/// - Trakt：影片用 imdb/tmdb，剧集用 tvdb/tmdb/imdb（剧集级 id）。
/// - Bangumi：需要 subject_id + episode_id，二者均取自 ProviderIds 的 `Bangumi`
///   键（剧集自身给 episode_id，其所属剧给 subject_id）。Emby 未刮削 Bangumi 时
///   自然跳过，不报错。
>>>>>>> c69d95d4735af41e13586a08cd2bc4fdc74ca8f5
class SyncScrobbleService {
  static final _logger = AppLogger();

  final TraktSyncService trakt;
  final BangumiSyncService bangumi;
<<<<<<< HEAD
  final BangumiMatcher bangumiMatcher;

  SyncScrobbleService({
    TraktSyncService? trakt,
    BangumiSyncService? bangumi,
    BangumiMatcher? bangumiMatcher,
  })  : trakt = trakt ?? TraktSyncService(),
        bangumi = bangumi ?? BangumiSyncService(),
        bangumiMatcher = bangumiMatcher ?? BangumiMatcher();

  /// 上报「看过」。[seriesProviderIds] 为剧集所属剧的 ProviderIds（Bangumi 取
  /// subject_id 用；影片可不传）。[dandanplay] 在线时作为 Bangumi 反查的首选来源。
  /// 只会对已连接的服务发起调用。
  Future<SyncScrobbleResult> scrobbleWatched(
    MediaItem item, {
    Map<String, String>? seriesProviderIds,
    DandanplaySource? dandanplay,
=======

  SyncScrobbleService({TraktSyncService? trakt, BangumiSyncService? bangumi})
      : trakt = trakt ?? TraktSyncService(),
        bangumi = bangumi ?? BangumiSyncService();

  /// 上报「看过」。[seriesProviderIds] 为剧集所属剧的 ProviderIds（Bangumi 取
  /// subject_id 用；影片可不传）。只会对已连接的服务发起调用。
  Future<SyncScrobbleResult> scrobbleWatched(
    MediaItem item, {
    Map<String, String>? seriesProviderIds,
>>>>>>> c69d95d4735af41e13586a08cd2bc4fdc74ca8f5
  }) async {
    final out = <SyncService, bool>{};

    if (SyncSession.current(SyncService.trakt) != null) {
      final ok = await _scrobbleTrakt(item);
      if (ok != null) out[SyncService.trakt] = ok;
    }
    if (SyncSession.current(SyncService.bangumi) != null) {
<<<<<<< HEAD
      final ok = await _scrobbleBangumi(item, seriesProviderIds, dandanplay);
=======
      final ok = await _scrobbleBangumi(item, seriesProviderIds);
>>>>>>> c69d95d4735af41e13586a08cd2bc4fdc74ca8f5
      if (ok != null) out[SyncService.bangumi] = ok;
    }

    if (out.isNotEmpty) {
      _logger.i('SyncScrobble', '观看上报 ${item.name}: $out');
    }
    return SyncScrobbleResult(out);
  }

  // ---- Trakt ----

  Future<bool?> _scrobbleTrakt(MediaItem item) async {
    final type = switch (item.type) {
      'Movie' => 'movie',
      'Episode' => 'episode',
      _ => null,
    };
    if (type == null) return null;
    final ids = _traktIds(item.providerIds);
    if (ids.isEmpty) {
      _logger.w('SyncScrobble', 'Trakt 跳过 ${item.name}: 无可用 ProviderIds');
      return null;
    }
    return trakt.addToHistory(type: type, ids: ids, watchedAt: DateTime.now());
  }

  /// Emby ProviderIds（如 {'Tmdb':'123','Imdb':'tt...'}）→ Trakt ids 对象。
  Map<String, dynamic> _traktIds(Map<String, String>? p) {
    final out = <String, dynamic>{};
    if (p == null) return out;
    p.forEach((k, v) {
      if (v.isEmpty) return;
      switch (k.toLowerCase()) {
        case 'imdb':
          out['imdb'] = v;
          break;
        case 'tmdb':
          out['tmdb'] = int.tryParse(v) ?? v;
          break;
        case 'tvdb':
          out['tvdb'] = int.tryParse(v) ?? v;
          break;
        case 'trakt':
          out['trakt'] = int.tryParse(v) ?? v;
          break;
      }
    });
    return out;
  }

  // ---- Bangumi ----

  Future<bool?> _scrobbleBangumi(
    MediaItem item,
    Map<String, String>? seriesProviderIds,
<<<<<<< HEAD
    DandanplaySource? dandanplay,
  ) async {
    // Bangumi 以「单集」为粒度，需要 subject_id + episode_id。
    if (item.type != 'Episode') return null;

    // 一级：Emby 自带 Bangumi providerId（剧给 subject、集给 episode），最快最准。
    final directEp = _bangumiId(item.providerIds);
    final directSubject = _bangumiId(seriesProviderIds);
    if (directEp != null && directSubject != null) {
      return bangumi.updateEpisodeStatus(
        subjectId: directSubject,
        episodeId: directEp,
        type: 2,
      );
    }

    final episode = item.indexNumber;
    if (episode == null) return null;

    // 二级（首选）：弹弹play 反查 —— 文件名/剧名匹配作品 → 作品详情的 bangumiUrl
    // 抠出 bgm subject id（弹弹play 作品按季拆分、直链 bgm，省去续集链猜测）。
    if (dandanplay != null) {
      final subjectId = await _resolveSubjectViaDandanplay(item, dandanplay);
      if (subjectId != null) {
        final epId = await bangumiMatcher.findEpisodeId(subjectId, episode);
        if (epId != null) {
          return bangumi.updateEpisodeStatus(
            subjectId: subjectId,
            episodeId: epId,
            type: 2,
          );
        }
      }
    }

    // 三级（兜底）：纯 Bangumi API 搜索（剧名 + 开播日期）+ 续集链定位季度。
    final ref = await bangumiMatcher.resolveEpisode(
      title: item.seriesName ?? item.name,
      airDate: item.premiereDate,
      season: item.parentIndexNumber ?? 1,
      episode: episode,
    );
    if (ref == null) {
      _logger.w('SyncScrobble', 'Bangumi 跳过 ${item.name}: 未匹配到条目');
      return null;
    }
    return bangumi.updateEpisodeStatus(
      subjectId: ref.subjectId,
      episodeId: ref.episodeId,
      type: 2,
    );
  }

  /// 用弹弹play 反查 bgm.tv subject id：先按文件名匹配作品（最准），失败再按剧名
  /// 搜索；拿到弹弹play animeId 后取作品详情，从 `bangumiUrl` 解析出 subject id。
  Future<int?> _resolveSubjectViaDandanplay(
    MediaItem item,
    DandanplaySource ddp,
  ) async {
    try {
      String? animeId;

      final fileName = _baseName(item.path);
      if (fileName != null && fileName.isNotEmpty) {
        final m = await ddp.match(fileName: fileName);
        if (m.isMatched && m.matches.isNotEmpty) {
          animeId = m.matches.first.animeId;
        }
      }

      if (animeId == null || animeId.isEmpty) {
        final title = item.seriesName ?? item.name;
        final r = await ddp.searchAnime(keyword: title);
        animeId = _pickAnime(r.animes, title, item.productionYear)?.animeId;
      }

      if (animeId == null || animeId.isEmpty) return null;
      final detail = await ddp.getBangumiDetails(bangumiId: animeId);
      return _extractBgmSubjectId(detail.bangumiUrl);
    } catch (e) {
      _logger.w('SyncScrobble', '弹弹play 反查失败 ${item.name}: $e');
      return null;
    }
  }

  /// 从搜索结果里挑最贴近的作品：标题完全相同优先，其次年份吻合，再退第一个。
  DanmakuAnime? _pickAnime(List<DanmakuAnime> animes, String title, int? year) {
    if (animes.isEmpty) return null;
    DanmakuAnime? yearHit;
    for (final a in animes) {
      if (a.animeTitle == title) return a;
      if (year != null && a.year == year) yearHit ??= a;
    }
    return yearHit ?? animes.first;
  }

  int? _extractBgmSubjectId(String? bangumiUrl) {
    if (bangumiUrl == null || bangumiUrl.isEmpty) return null;
    final m = RegExp(r'/subject/(\d+)').firstMatch(bangumiUrl);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  String? _baseName(String? path) {
    if (path == null || path.isEmpty) return null;
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

=======
  ) async {
    // Bangumi 以「单集」为粒度，需要 subject_id + episode_id。
    if (item.type != 'Episode') return null;
    final episodeId = _bangumiId(item.providerIds);
    final subjectId = _bangumiId(seriesProviderIds);
    if (episodeId == null || subjectId == null) {
      _logger.w('SyncScrobble', 'Bangumi 跳过 ${item.name}: 缺 subject/episode id');
      return null;
    }
    return bangumi.updateEpisodeStatus(
      subjectId: subjectId,
      episodeId: episodeId,
      type: 2, // 看过
    );
  }

>>>>>>> c69d95d4735af41e13586a08cd2bc4fdc74ca8f5
  int? _bangumiId(Map<String, String>? p) {
    if (p == null) return null;
    for (final e in p.entries) {
      if (e.key.toLowerCase() == 'bangumi' && e.value.isNotEmpty) {
        return int.tryParse(e.value);
      }
    }
    return null;
  }
}
