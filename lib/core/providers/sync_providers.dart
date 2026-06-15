import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_preferences.dart';
import '../api/api_interfaces.dart' show MediaItem;
import '../api/danmaku/danmaku_service.dart';
import '../services/sync/bangumi_sync_service.dart';
import '../services/sync/sync_models.dart';
import '../services/sync/sync_scrobble_service.dart';
import '../services/sync/sync_secure_store.dart';
import '../services/sync/trakt_sync_service.dart';

/// 同步功能的全局状态：每个服务的已连接账号 + Bangumi 回调地址。
class SyncState {
  final SyncAccount? trakt;
  final SyncAccount? bangumi;
  final String bangumiRedirectUri;

  const SyncState({
    this.trakt,
    this.bangumi,
    required this.bangumiRedirectUri,
  });

  SyncAccount? account(SyncService service) {
    switch (service) {
      case SyncService.trakt:
        return trakt;
      case SyncService.bangumi:
        return bangumi;
    }
  }

  bool isConnected(SyncService service) => account(service) != null;

  SyncState copyWith({
    SyncAccount? trakt,
    SyncAccount? bangumi,
    String? bangumiRedirectUri,
    bool clearTrakt = false,
    bool clearBangumi = false,
  }) {
    return SyncState(
      trakt: clearTrakt ? null : (trakt ?? this.trakt),
      bangumi: clearBangumi ? null : (bangumi ?? this.bangumi),
      bangumiRedirectUri: bangumiRedirectUri ?? this.bangumiRedirectUri,
    );
  }
}

const String _bangumiRedirectPrefKey = 'bangumi_redirect_uri';

class SyncController extends StateNotifier<SyncState> {
  SyncController(this._ref)
      : super(SyncState(
          bangumiRedirectUri:
              AppPreferencesStore.instance.getString(_bangumiRedirectPrefKey) ??
                  kDefaultBangumiRedirectUri,
        )) {
    _restore();
  }

  final Ref _ref;

  final TraktSyncService trakt = TraktSyncService();
  final BangumiSyncService bangumi = BangumiSyncService();
  late final SyncScrobbleService _scrobble =
      SyncScrobbleService(trakt: trakt, bangumi: bangumi);

  /// 启动时从存储恢复账号，并回填到 [SyncSession]（供 service 层调用）。
  void _restore() {
    final t = SyncSecureStore.read(SyncService.trakt);
    final b = SyncSecureStore.read(SyncService.bangumi);
    SyncSession.set(SyncService.trakt, t);
    SyncSession.set(SyncService.bangumi, b);
    state = state.copyWith(trakt: t, bangumi: b);
  }

  Future<void> _persist(SyncAccount account) async {
    await SyncSecureStore.write(account);
    SyncSession.set(account.service, account);
  }

  // ---- Trakt 设备码流程 ----

  Future<TraktDeviceCode> startTraktDeviceAuth() {
    return trakt.requestDeviceCode();
  }

  /// 轮询一次；授权成功时落盘并更新状态。
  Future<TraktPollResult> pollTrakt(String deviceCode) async {
    final result = await trakt.pollOnce(deviceCode);
    if (result.state == TraktPollState.authorized && result.account != null) {
      await _persist(result.account!);
      state = state.copyWith(trakt: result.account);
    }
    return result;
  }

  // ---- Bangumi 授权码流程 ----

  String buildBangumiAuthorizeUrl() {
    return bangumi.buildAuthorizeUrl(redirectUri: state.bangumiRedirectUri);
  }

  Future<void> setBangumiRedirectUri(String uri) async {
    final trimmed = uri.trim();
    if (trimmed.isEmpty) return;
    await AppPreferencesStore.instance
        .setString(_bangumiRedirectPrefKey, trimmed);
    state = state.copyWith(bangumiRedirectUri: trimmed);
  }

  /// 用粘贴的授权码完成登录；成功落盘并更新状态。
  Future<void> connectBangumiWithCode(String code) async {
    final account = await bangumi.exchangeCode(
      code: code,
      redirectUri: state.bangumiRedirectUri,
    );
    await _persist(account);
    state = state.copyWith(bangumi: account);
  }

  // ---- 观看记录自动同步 ----

  /// 播放达到完成阈值后调用：把「看过」写入已连接的 Trakt/Bangumi。
  /// 未连接任何服务时直接返回，不产生网络请求。
  Future<void> scrobbleWatched(
    MediaItem item, {
    Map<String, String>? seriesProviderIds,
  }) async {
    if (!state.isConnected(SyncService.trakt) &&
        !state.isConnected(SyncService.bangumi)) {
      return;
    }
    // 弹弹play 在线时作为 Bangumi 反查首选（需配置 DANDANPLAY 凭据，与弹幕同一套）。
    final dandanplay = _ref.read(danmakuServiceProvider).dandanplay;
    await _scrobble.scrobbleWatched(
      item,
      seriesProviderIds: seriesProviderIds,
      dandanplay: dandanplay,
    );
  }

  // ---- 断开连接 ----

  Future<void> disconnect(SyncService service) async {
    await SyncSecureStore.clear(service);
    SyncSession.set(service, null);
    switch (service) {
      case SyncService.trakt:
        state = state.copyWith(clearTrakt: true);
      case SyncService.bangumi:
        state = state.copyWith(clearBangumi: true);
    }
  }
}

final syncControllerProvider =
    StateNotifierProvider<SyncController, SyncState>((ref) {
  return SyncController(ref);
});
