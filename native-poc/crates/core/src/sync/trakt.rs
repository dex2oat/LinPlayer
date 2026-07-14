// Trakt 同步内核 —— 迁自 Dart trakt_sync_service.dart。
// 设备码登录(三端一致:展示 URL+code,浏览器授权,轮询拿令牌)+ 令牌刷新 + scrobble + 追剧日历。
// 需 secret 的换/刷令牌走已部署 CF 代理;scrobble/calendar/profile 直连 api.trakt.tv 带 Bearer。

use serde::Serialize;
use serde_json::Value;

use super::calendar::{date_str_days_ago, CalendarEntry};
use super::{proxy_headers, trakt_client_id, use_sync_proxy, SyncAccount, SYNC_PROXY_BASE};

const API_BASE: &str = "https://api.trakt.tv";

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

/// Scrobble 一次(start/pause/stop)。action ∈ {"start","pause","stop"};type_ ∈ {"movie","episode"};
/// ids 如 {"imdb":"tt..","tmdb":123};progress 0~100。stop 且 progress≥80% Trakt 自动标记看过。
pub async fn scrobble(
    account: &SyncAccount,
    type_: &str,
    ids: Value,
    progress: f64,
    action: &str,
) -> bool {
    let Some(valid) = ensure_valid(account).await else {
        return false;
    };
    let body = serde_json::json!({
        type_: { "ids": ids },
        "progress": progress.clamp(0.0, 100.0),
    });
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
            image_url: None,
            tmdb_id,
            source: "trakt".into(),
        });
    }
    out
}
