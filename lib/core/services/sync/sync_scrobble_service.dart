import '../../api/api_interfaces.dart' show MediaItem;
import '../app_logger.dart';
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
/// 仅对「已连接」的服务上报（连接与否 = 用户的开关）。映射依赖 Emby 项目自带的
/// ProviderIds：
/// - Trakt：影片用 imdb/tmdb，剧集用 tvdb/tmdb/imdb（剧集级 id）。
/// - Bangumi：需要 subject_id + episode_id，二者均取自 ProviderIds 的 `Bangumi`
///   键（剧集自身给 episode_id，其所属剧给 subject_id）。Emby 未刮削 Bangumi 时
///   自然跳过，不报错。
class SyncScrobbleService {
  static final _logger = AppLogger();

  final TraktSyncService trakt;
  final BangumiSyncService bangumi;

  SyncScrobbleService({TraktSyncService? trakt, BangumiSyncService? bangumi})
      : trakt = trakt ?? TraktSyncService(),
        bangumi = bangumi ?? BangumiSyncService();

  /// 上报「看过」。[seriesProviderIds] 为剧集所属剧的 ProviderIds（Bangumi 取
  /// subject_id 用；影片可不传）。只会对已连接的服务发起调用。
  Future<SyncScrobbleResult> scrobbleWatched(
    MediaItem item, {
    Map<String, String>? seriesProviderIds,
  }) async {
    final out = <SyncService, bool>{};

    if (SyncSession.current(SyncService.trakt) != null) {
      final ok = await _scrobbleTrakt(item);
      if (ok != null) out[SyncService.trakt] = ok;
    }
    if (SyncSession.current(SyncService.bangumi) != null) {
      final ok = await _scrobbleBangumi(item, seriesProviderIds);
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
