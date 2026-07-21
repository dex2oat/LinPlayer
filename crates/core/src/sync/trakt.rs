// Trakt 同步内核 —— 迁自 Dart trakt_sync_service.dart。
// 设备码登录(三端一致:展示 URL+code,浏览器授权,轮询拿令牌)+ 令牌刷新 + scrobble + 追剧日历。
// 需 secret 的换/刷令牌走已部署 CF 代理;scrobble/calendar/profile 直连 api.trakt.tv 带 Bearer。

use serde::Serialize;
use serde_json::Value;

use super::calendar::{date_str_days_ago, CalendarEntry};
use super::{proxy_headers, trakt_client_id, use_sync_proxy, SyncAccount, SYNC_PROXY_BASE};

const API_BASE: &str = "https://api.trakt.tv";

/// Trakt **自己不发图**(响应里只有 ids.tmdb)—— 这就是「trakt 放送表图片加载不出来」的根因:
/// 旧代码直接 `image_url: None`,前端只能画占位方块。这里拿 tmdb_id 去 TMDB 查海报。
/// ⚠️ 需要编译期注入 `TMDB_API_KEY`(与排行榜同源)。没 key 就返回 None —— 不假装有图。
/// TMDB 一次请求能拿到的三样东西。
/// ★ 海报/简介/评分**同一个 `/3/tv/{id}` 响应里全都有** —— 以前只取了 poster_path,
/// 白扔了另外两个。补简介/评分**零额外请求**,别再为它们各发一次。
struct TmdbShow {
    poster: Option<String>,
    overview: Option<String>,
    rating: Option<f64>,
}

async fn tmdb_show(tmdb_id: i64) -> Option<TmdbShow> {
    let key = crate::secrets::tmdb_key();
    if key.is_empty() {
        return None;
    }
    let use_bearer = key.contains('.'); // v4 JWT 含点;v3 为 32 位十六进制
    let url = format!("https://api.themoviedb.org/3/tv/{tmdb_id}");
    let mut req = crate::http::client()
        .get(&url)
        .header("Accept", "application/json");
    if use_bearer {
        req = req.header("Authorization", format!("Bearer {key}"));
    } else {
        req = req.query(&[("api_key", key.as_str())]);
    }
    let j = req.send().await.ok()?.json::<Value>().await.ok()?;
    Some(TmdbShow {
        poster: j
            .get("poster_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(|p| format!("https://image.tmdb.org/t/p/w342{p}")),
        overview: j
            .get("overview")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|o| !o.is_empty())
            .map(str::to_string),
        // 0 = TMDB 表示「没人评过」,不是零分 —— 滤掉,别让前端画出诽谤。
        rating: j
            .get("vote_average")
            .and_then(Value::as_f64)
            .filter(|r| *r > 0.0),
    })
}

/// 给日历条目补 TMDB 海报。同一部剧一周内常有多集 → **按 tmdb_id 去重**,一部只查一次。
/// 没 key 时每个 tmdb_poster 立即返回 None,不打网络,几乎零开销。
/// 按 tmdb_id 去重后并发拉 TMDB,回填海报 + 简介 + 评分。
/// Trakt 自己不发图、不发简介,只给 ids.tmdb —— 这三样只能从 TMDB 来。
async fn fill_tmdb(out: &mut [CalendarEntry]) {
    let mut ids: Vec<i64> = out.iter().filter_map(|e| e.tmdb_id).collect();
    ids.sort_unstable();
    ids.dedup();
    if ids.is_empty() {
        return;
    }
    let mut handles = Vec::new();
    for id in ids {
        handles.push(tokio::spawn(async move { (id, tmdb_show(id).await) }));
    }
    let mut map = std::collections::HashMap::new();
    for h in handles {
        if let Ok((id, Some(sh))) = h.await {
            map.insert(id, sh);
        }
    }
    for e in out.iter_mut() {
        if let Some(sh) = e.tmdb_id.and_then(|id| map.get(&id)) {
            e.image_url = sh.poster.clone();
            e.summary = sh.overview.clone();
            e.rating = sh.rating;
        }
    }
}

#[derive(Serialize, Clone)]
pub struct TraktDeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub interval: i64,
    pub expires_in: i64,
}

#[derive(Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TraktPollState {
    Pending,
    SlowDown,
    Authorized,
    Expired,
    Denied,
    Error,
}

#[derive(Serialize, Clone)]
pub struct TraktPollResult {
    pub state: TraktPollState,
    pub account: Option<SyncAccount>,
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn api_headers(access: &str) -> Vec<(String, String)> {
    vec![
        ("Authorization".into(), format!("Bearer {access}")),
        ("trakt-api-version".into(), "2".into()),
        ("trakt-api-key".into(), trakt_client_id()),
    ]
}

/// 第一步:申请设备码(走代理)。
pub async fn request_device_code() -> Result<TraktDeviceCode, String> {
    if !use_sync_proxy() {
        return Err("未配置同步代理".into());
    }
    let mut req = crate::http::client().post(format!("{SYNC_PROXY_BASE}/trakt/device"));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("Trakt 申请设备码失败: HTTP {}", resp.status().as_u16()));
    }
    let j: Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(TraktDeviceCode {
        device_code: j["device_code"].as_str().unwrap_or("").to_string(),
        user_code: j["user_code"].as_str().unwrap_or("").to_string(),
        verification_url: j["verification_url"].as_str().unwrap_or("").to_string(),
        interval: j["interval"].as_i64().unwrap_or(5),
        expires_in: j["expires_in"].as_i64().unwrap_or(600),
    })
}

/// 第二步:轮询一次(走代理)。状态码语义同 Trakt 设备码流程。
pub async fn poll_once(device_code: &str) -> TraktPollResult {
    let none = |s| TraktPollResult { state: s, account: None };
    if !use_sync_proxy() {
        return none(TraktPollState::Error);
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/trakt/token"))
        .json(&serde_json::json!({ "device_code": device_code }));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    let resp = match req.send().await {
        Ok(r) => r,
        Err(_) => return none(TraktPollState::Error),
    };
    match resp.status().as_u16() {
        200 => match resp.json::<Value>().await {
            Ok(tok) => {
                let account = account_from_token(&tok, None).await;
                TraktPollResult { state: TraktPollState::Authorized, account: Some(account) }
            }
            Err(_) => none(TraktPollState::Error),
        },
        400 => none(TraktPollState::Pending),  // 仍在等待授权
        429 => none(TraktPollState::SlowDown), // 轮询过快
        404 | 410 | 409 => none(TraktPollState::Expired),
        418 => none(TraktPollState::Denied),
        _ => none(TraktPollState::Error),
    }
}

/// 用 refresh_token 换新令牌(走代理)。失败 None(通常需重登)。
pub async fn refresh(account: &SyncAccount) -> Option<SyncAccount> {
    let rt = account.refresh_token.as_deref().filter(|s| !s.is_empty())?;
    if !use_sync_proxy() {
        return None;
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/trakt/refresh"))
        .json(&serde_json::json!({ "refresh_token": rt }));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let tok: Value = resp.json().await.ok()?;
    Some(account_from_token(&tok, Some(account)).await)
}

/// 确保令牌有效:过期则刷新。返回可用账号或 None。
pub async fn ensure_valid(account: &SyncAccount) -> Option<SyncAccount> {
    if !account.is_expired(now_ms()) {
        return Some(account.clone());
    }
    refresh(account).await
}

fn build_account(tok: &Value, fallback: Option<&SyncAccount>) -> SyncAccount {
    let access = tok["access_token"]
        .as_str()
        .map(String::from)
        .or_else(|| fallback.map(|f| f.access_token.clone()))
        .unwrap_or_default();
    let created_at = tok["created_at"].as_i64();
    let expires_in = tok["expires_in"].as_i64();
    let expires_at = match (created_at, expires_in) {
        (Some(c), Some(e)) => Some((c + e) * 1000),
        (None, Some(e)) => Some(now_ms() + e * 1000),
        _ => fallback.and_then(|f| f.expires_at),
    };
    SyncAccount {
        service: "trakt".into(),
        access_token: access,
        refresh_token: tok["refresh_token"]
            .as_str()
            .map(String::from)
            .or_else(|| fallback.and_then(|f| f.refresh_token.clone())),
        expires_at,
        username: fallback.and_then(|f| f.username.clone()),
        user_id: fallback.and_then(|f| f.user_id.clone()),
    }
}

async fn account_from_token(tok: &Value, fallback: Option<&SyncAccount>) -> SyncAccount {
    let mut account = build_account(tok, fallback);
    if account.username.is_none() && !account.access_token.is_empty() {
        if let Some((username, user_id)) = fetch_profile(&account.access_token).await {
            account.username = username;
            account.user_id = user_id;
        }
    }
    account
}

async fn fetch_profile(access: &str) -> Option<(Option<String>, Option<String>)> {
    let mut req = crate::http::client().get(format!("{API_BASE}/users/me"));
    for (k, v) in api_headers(access) {
        req = req.header(k, v);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: Value = resp.json().await.ok()?;
    let user_id = j["ids"]["slug"].as_str().map(String::from);
    Some((j["username"].as_str().map(String::from), user_id))
}

/// 直接写入观看历史(`POST /sync/history`)。
///
/// ★ 为什么 scrobble 之外还要这个:`/scrobble/stop` 只在 Trakt **认可这次会话**时才落历史 ——
/// progress<80%、没有先 start、或 ids 形态不合它口味,都会静默不入库,于是「继续观看有、
/// 历史观看空」。`/sync/history` 是幂等的显式写入,不依赖会话状态,看完就一定进历史。
///
/// `item` 用 `ScrobbleInfo::trakt_body()` 的形状(movie / show+episode)。
pub async fn add_to_history(account: &SyncAccount, item: &Value) -> bool {
    let Some(valid) = ensure_valid(account).await else {
        return false;
    };
    // watched_at=now:不给的话 Trakt 用服务端时间,基本等价,但显式给更可控。
    let mut entry = item.clone();
    if let Some(o) = entry.as_object_mut() {
        o.insert("watched_at".into(), Value::String(iso_now()));
    }
    // movie 走 movies[],episode/show+episode 走 episodes[]/shows[]。
    let body = if entry.get("movie").is_some() {
        let m = merge_watched_at(&entry["movie"], &entry);
        serde_json::json!({ "movies": [m] })
    } else if entry.get("show").is_some() {
        // shows[].seasons[].episodes[] —— 这是 Trakt 对「只有剧 ID + 季集号」唯一接受的形状。
        serde_json::json!({ "shows": [{
            "ids": entry["show"]["ids"],
            "seasons": [{
                "number": entry["episode"]["season"],
                "episodes": [{ "number": entry["episode"]["number"], "watched_at": iso_now() }],
            }],
        }]})
    } else {
        let e = merge_watched_at(&entry["episode"], &entry);
        serde_json::json!({ "episodes": [e] })
    };
    let mut req = crate::http::client()
        .post(format!("{API_BASE}/sync/history"))
        .header("Content-Type", "application/json")
        .json(&body);
    for (k, v) in api_headers(&valid.access_token) {
        req = req.header(k, v);
    }
    match req.send().await {
        Ok(r) => r.status().is_success(),
        Err(_) => false,
    }
}

fn merge_watched_at(node: &Value, src: &Value) -> Value {
    let mut n = node.clone();
    if let (Some(o), Some(w)) = (n.as_object_mut(), src.get("watched_at")) {
        o.insert("watched_at".into(), w.clone());
    }
    n
}

/// RFC3339 UTC 时间戳(Trakt 要这个格式)。
fn iso_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    // 手算 civil date,不为一个时间戳拉 chrono。
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant 的 civil_from_days(纪元日 → 年月日),公认写法。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Scrobble 一次(start/pause/stop)。action ∈ {"start","pause","stop"};
/// `item` 为 `ScrobbleInfo::trakt_body()` 产出的条目节点;progress 0~100。
pub async fn scrobble(account: &SyncAccount, item: &Value, progress: f64, action: &str) -> bool {
    let Some(valid) = ensure_valid(account).await else {
        return false;
    };
    let mut body = item.clone();
    if let Some(o) = body.as_object_mut() {
        o.insert("progress".into(), Value::from(progress.clamp(0.0, 100.0)));
    }
    let mut req = crate::http::client()
        .post(format!("{API_BASE}/scrobble/{action}"))
        .header("Content-Type", "application/json")
        .json(&body);
    for (k, v) in api_headers(&valid.access_token) {
        req = req.header(k, v);
    }
    match req.send().await {
        // 409 = 已有进行中的 scrobble(重复 start),对播放器视作成功。
        Ok(r) => r.status().is_success() || r.status().as_u16() == 409,
        Err(_) => false,
    }
}

/// 拉追剧日历:从 start_offset_days 天前起、共 days 天。only_mine=只看我追的(/my)否则全站(/all)。
pub async fn fetch_shows_calendar(
    account: &SyncAccount,
    start_offset_days: i64,
    days: i64,
    only_mine: bool,
) -> Vec<CalendarEntry> {
    let Some(valid) = ensure_valid(account).await else {
        return vec![];
    };
    let start = date_str_days_ago(start_offset_days);
    let scope = if only_mine { "my" } else { "all" };
    const ALL_CAP: usize = 200; // /all 是全站火喉,截断防爆炸
    let url = format!("{API_BASE}/calendars/{scope}/shows/{start}/{days}");
    let mut req = crate::http::client().get(&url);
    for (k, v) in api_headers(&valid.access_token) {
        req = req.header(k, v);
    }
    let Ok(resp) = req.send().await else { return vec![] };
    if !resp.status().is_success() {
        return vec![];
    }
    let Ok(Value::Array(list)) = resp.json::<Value>().await else {
        return vec![];
    };
    let mut out = Vec::new();
    for raw in list {
        if !only_mine && out.len() >= ALL_CAP {
            break;
        }
        let show = &raw["show"];
        let title = show["title"].as_str().unwrap_or("未知剧集").to_string();
        let tmdb_id = show["ids"]["tmdb"].as_i64();
        let air_date = raw["first_aired"].as_str().map(String::from);
        let ep = &raw["episode"];
        let subtitle = {
            let s = ep["season"].as_i64();
            let n = ep["number"].as_i64();
            let code = match (s, n) {
                (Some(s), Some(n)) => Some(format!("S{s:02}E{n:02}")),
                _ => None,
            };
            let ep_title = ep["title"].as_str().filter(|t| !t.is_empty());
            let parts: Vec<String> = [code, ep_title.map(String::from)].into_iter().flatten().collect();
            if parts.is_empty() { None } else { Some(parts.join(" · ")) }
        };
        out.push(CalendarEntry {
            title,
            subtitle,
            air_date,
            weekday: None,
            broadcast_at: None, // Trakt 的 air_date(first_aired)本身就是精确时刻,不需要
            image_url: None, // 下面 fill_tmdb 用 tmdb_id 统一补(海报/简介/评分一次拉齐)
            tmdb_id,
            rating: None,
            summary: None,
            bangumi_id: None,
            source: "trakt".into(),
        });
    }
    fill_tmdb(&mut out).await;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_from_days_matches_known_dates() {
        // 纪元日 0 = 1970-01-01;闰年边界与世纪非闰年是这个算法最容易写错的地方。
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(59), (1970, 3, 1));
        assert_eq!(civil_from_days(365), (1971, 1, 1));
        assert_eq!(civil_from_days(730), (1972, 1, 1));
        assert_eq!(civil_from_days(789), (1972, 2, 29)); // 1972 是闰年
        assert_eq!(civil_from_days(11016), (2000, 2, 29)); // 2000 闰(整400)
        assert_eq!(civil_from_days(20513), (2026, 3, 1)); // 2026 平年:2/28 后直接 3/1
        assert_eq!(civil_from_days(20512), (2026, 2, 28));
    }

    #[test]
    fn iso_now_is_rfc3339_utc() {
        let s = iso_now();
        assert_eq!(s.len(), 20, "{s}");
        assert!(s.ends_with('Z'), "{s}");
        assert_eq!(&s[4..5], "-");
        assert_eq!(&s[10..11], "T");
    }

    /// 分集没有自己的 ProviderIds 时,必须退到 show + 季集号,而不是发一个空 ids。
    #[test]
    fn trakt_body_falls_back_to_show_and_episode_number() {
        let info = crate::emby::ScrobbleInfo {
            media_type: "episode".into(),
            ids: serde_json::json!({}),
            show_ids: serde_json::json!({ "tvdb": 1234 }),
            runtime_secs: 1440.0,
            title: "某剧".into(),
            original_title: None,
            air_date: None,
            season: 2,
            episode: 7,
        };
        assert!(info.has_trakt_ids(), "有剧 ID 就该允许上报");
        let b = info.trakt_body();
        assert_eq!(b["show"]["ids"]["tvdb"], 1234);
        assert_eq!(b["episode"]["season"], 2);
        assert_eq!(b["episode"]["number"], 7);
        assert!(b.get("movie").is_none());
    }
}
