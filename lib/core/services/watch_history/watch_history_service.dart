import '../../api/api_interfaces.dart';
import 'watch_history_matcher.dart';
import 'watch_history_models.dart';
import 'watch_history_store.dart';

class WatchHistoryService {
  WatchHistoryService({
    required WatchHistoryStore store,
  }) : _store = store;

  final WatchHistoryStore _store;
  final Map<String, DateTime> _lastProgressWriteAt = <String, DateTime>{};
  final Map<String, Future<String?>> _seriesTmdbCache =
      <String, Future<String?>>{};

  Future<List<WatchHistoryRecord>> loadScope(String scopeKey) {
    return _store.loadScope(scopeKey);
  }

  Future<void> deleteRecord(String recordId) {
    _lastProgressWriteAt.remove(recordId);
    return _store.deleteRecord(recordId);
  }

  Future<WatchHistoryFingerprint?> buildFingerprint(
    ApiClientFactory api,
    MediaItem item,
  ) async {
    final seriesTmdbId = await resolveSeriesTmdbId(api, item);
    return buildWatchHistoryFingerprintFromItem(
      item,
      seriesTmdbId: seriesTmdbId,
    );
  }

  Future<String?> resolveSeriesTmdbId(
    ApiClientFactory api,
    MediaItem item,
  ) async {
    if (item.type.toLowerCase() != 'episode') {
      return null;
    }
    final seriesId = item.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return null;
    }
    final pending = _seriesTmdbCache.putIfAbsent(seriesId, () async {
      try {
        final seriesItem = await api.media.getItemDetails(seriesId);
        return extractProviderId(seriesItem.providerIds, 'tmdb');
      } catch (_) {
        return null;
      }
    });
    return pending;
  }

  Future<WatchHistoryRecord?> capturePlayback({
    required String scopeKey,
    required ApiClientFactory api,
    required MediaItem item,
    required int positionTicks,
    required WatchHistoryWriteSource source,
    required int watchedThresholdPercent,
    bool incrementPlayCount = false,
    bool force = false,
  }) async {
    final fingerprint = await buildFingerprint(api, item);
    if (fingerprint == null) {
      return null;
    }

    final records = await _store.loadScope(scopeKey);
    final existing = _findExistingRecord(records, fingerprint, item.id);
    final recordId = buildWatchHistoryRecordId(
      scopeKey: scopeKey,
      mediaKind: fingerprint.mediaKind,
      canonicalKey: fingerprint.canonicalKey,
    );

    if (!force &&
        existing != null &&
        !incrementPlayCount &&
        !_shouldPersistProgress(recordId)) {
      return existing;
    }

    final now = DateTime.now().toUtc();
    final played = _isPlayed(
      positionTicks: positionTicks,
      runTimeTicks: item.runTimeTicks,
      watchedThresholdPercent: watchedThresholdPercent,
    );
    final nextPlayCount = (existing?.playCount ?? 0) +
        (incrementPlayCount || existing == null ? 1 : 0);

    final record = WatchHistoryRecord(
      recordId: recordId,
      scopeKey: scopeKey,
      mediaKind: fingerprint.mediaKind,
      canonicalKey: fingerprint.canonicalKey,
      tmdbId: fingerprint.tmdbId,
      seriesTmdbId: fingerprint.seriesTmdbId,
      title: item.name,
      seriesTitle: item.seriesName,
      seasonNumber: item.parentIndexNumber,
      episodeNumber: item.indexNumber,
      year: item.productionYear,
      lastPositionTicks: positionTicks.clamp(
        0,
        item.runTimeTicks ?? positionTicks,
      ),
      runTimeTicks: item.runTimeTicks,
      played: played,
      playCount: nextPlayCount,
      lastPlayedAt: now,
      lastEmbyItemId: item.id,
      matchConfidence:
          existing?.matchConfidence ?? WatchHistoryMatchConfidence.none,
      restoredAt: existing?.restoredAt,
      lastWriteSource: source,
      presentationUniqueKey: item.presentationUniqueKey,
      mediaPath: item.path,
    );

    final replacedIds = <String>[
      if (existing != null && existing.recordId != record.recordId)
        existing.recordId,
    ];
    await _store.saveRecord(record, replaceRecordIds: replacedIds);
    _lastProgressWriteAt[recordId] = now;
    if (existing != null && existing.recordId != recordId) {
      _lastProgressWriteAt.remove(existing.recordId);
    }
    return record;
  }

  bool _isPlayed({
    required int positionTicks,
    required int? runTimeTicks,
    required int watchedThresholdPercent,
  }) {
    final runtime = runTimeTicks;
    if (runtime == null || runtime <= 0) {
      return false;
    }
    final ratio = positionTicks / runtime;
    return ratio >= watchedThresholdPercent / 100;
  }

  bool _shouldPersistProgress(String recordId) {
    final lastWriteAt = _lastProgressWriteAt[recordId];
    if (lastWriteAt == null) {
      return true;
    }
    return DateTime.now().toUtc().difference(lastWriteAt).inSeconds >= 10;
  }

  WatchHistoryRecord? _findExistingRecord(
    List<WatchHistoryRecord> records,
    WatchHistoryFingerprint fingerprint,
    String itemId,
  ) {
    for (final record in records) {
      if (record.canonicalKey == fingerprint.canonicalKey) {
        return record;
      }
    }
    for (final record in records) {
      if (record.lastEmbyItemId == itemId) {
        return record;
      }
    }
    final candidatePuk = fingerprint.normalizedPresentationUniqueKey;
    if (candidatePuk != null && candidatePuk.isNotEmpty) {
      for (final record in records) {
        final recordPuk =
            normalizePresentationUniqueKey(record.presentationUniqueKey);
        if (recordPuk == candidatePuk) {
          return record;
        }
      }
    }
    return null;
  }
}
