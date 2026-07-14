// Emby 客户端:登录、取媒体库(Views)、列条目、解析直连播放地址。
use crate::http::{device_name, APP_VERSION, CLIENT_NAME};
use serde::{Deserialize, Serialize};

/// X-Emby-Authorization 头:身份用真实应用标识(非 PoC 名),DeviceId 用持久化设备 ID。
fn auth_header(device_id: &str) -> String {
    format!(
        "MediaBrowser Client=\"{CLIENT_NAME}\", Device=\"{}\", DeviceId=\"{device_id}\", Version=\"{APP_VERSION}\"",
        device_name()
    )
}

#[derive(Clone)]
pub struct Session {
    pub server: String, // 归一化后不带尾斜杠
    pub token: String,
    pub user_id: String,
    pub device_id: String,
}

#[derive(Serialize)]
pub struct LoginResult {
    pub server: String,
    pub token: String,
    pub user_id: String,
    pub user_name: String,
}

#[derive(Deserialize)]
struct AuthResponse {
    #[serde(rename = "AccessToken")]
    access_token: String,
    #[serde(rename = "User")]
    user: AuthUser,
}
#[derive(Deserialize)]
struct AuthUser {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: String,
}

#[derive(Deserialize)]
struct ItemsResponse {
    #[serde(rename = "Items")]
    items: Vec<RawItem>,
}
#[derive(Deserialize)]
struct RawItem {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "Type")]
    type_: Option<String>,
    #[serde(rename = "IsFolder")]
    is_folder: Option<bool>,
    #[serde(rename = "CollectionType")]
    collection_type: Option<String>,
    #[serde(rename = "ImageTags")]
    image_tags: Option<serde_json::Value>,
    #[serde(rename = "RunTimeTicks")]
    runtime_ticks: Option<i64>,
    #[serde(rename = "UserData")]
    user_data: Option<UserData>,
}
#[derive(Deserialize)]
struct UserData {
    #[serde(rename = "PlaybackPositionTicks")]
    position_ticks: Option<i64>,
}

#[derive(Serialize)]
pub struct Item {
    pub id: String,
    pub name: String,
    pub type_: String,
    pub is_folder: bool,
    pub has_primary: bool,
    pub runtime_secs: f64,
    pub resume_secs: f64,
}

impl From<RawItem> for Item {
    fn from(r: RawItem) -> Self {
        let has_primary = r
            .image_tags
            .as_ref()
            .and_then(|v| v.get("Primary"))
            .is_some();
        let is_folder = r.is_folder.unwrap_or(false) || r.collection_type.is_some();
        Item {
            id: r.id,
            name: r.name.unwrap_or_default(),
            type_: r.type_.unwrap_or_default(),
            is_folder,
            has_primary,
            runtime_secs: r.runtime_ticks.unwrap_or(0) as f64 / 1e7,
            resume_secs: r.user_data.and_then(|u| u.position_ticks).unwrap_or(0) as f64 / 1e7,
        }
    }
}

fn norm(server: &str) -> String {
    server.trim().trim_end_matches('/').to_string()
}

pub async fn login(
    http: &reqwest::Client,
    server: &str,
    username: &str,
    password: &str,
    device_id: &str,
) -> Result<(Session, LoginResult), String> {
    let server = norm(server);
    let url = format!("{server}/Users/AuthenticateByName");
    let body = serde_json::json!({ "Username": username, "Pw": password });
    let resp = http
        .post(&url)
        .header("X-Emby-Authorization", auth_header(device_id))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("登录失败: HTTP {}", resp.status()));
    }
    let auth: AuthResponse = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let session = Session {
        server: server.clone(),
        token: auth.access_token,
        user_id: auth.user.id.clone(),
        device_id: device_id.to_string(),
    };
    let result = LoginResult {
        server,
        token: session.token.clone(),
        user_id: auth.user.id,
        user_name: auth.user.name,
    };
    Ok((session, result))
}

pub async fn views(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let url = format!("{}/Users/{}/Views", s.server, s.user_id);
    fetch_items(http, s, &url).await
}

pub async fn items(
    http: &reqwest::Client,
    s: &Session,
    parent_id: &str,
) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items?ParentId={}&SortBy=SortName&SortOrder=Ascending&Fields=PrimaryImageAspectRatio&Limit=200",
        s.server, s.user_id, parent_id
    );
    fetch_items(http, s, &url).await
}

async fn fetch_items(http: &reqwest::Client, s: &Session, url: &str) -> Result<Vec<Item>, String> {
    let resp = http
        .get(url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let data: ItemsResponse = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(data.items.into_iter().map(Item::from).collect())
}

#[derive(Deserialize)]
struct PlaybackInfoResp {
    #[serde(rename = "MediaSources")]
    media_sources: Vec<MediaSource>,
    #[serde(rename = "PlaySessionId")]
    play_session_id: Option<String>,
}
#[derive(Deserialize)]
struct MediaSource {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Container")]
    container: Option<String>,
    #[serde(rename = "DirectStreamUrl")]
    direct_stream_url: Option<String>,
    #[serde(rename = "TranscodingUrl")]
    transcoding_url: Option<String>,
}

/// 一次播放会话的目标 + 上报三件套共享的 id。
/// ★ PlaySessionId 必须贯穿 start/progress/stopped 三次上报(续播落地老坑)。
#[derive(Clone, Serialize)]
pub struct PlaybackTarget {
    pub url: String,
    pub item_id: String,
    pub media_source_id: String,
    pub play_session_id: String,
    pub play_method: String, // "DirectStream" | "Transcode"
}

fn secs_to_ticks(secs: f64) -> i64 {
    (secs.max(0.0) * 1e7) as i64
}

/// 补全 server 前缀与 api_key。
fn abs_url(s: &Session, path: &str) -> String {
    let mut u = if path.starts_with("http") {
        path.to_string()
    } else {
        format!("{}{}", s.server, path)
    };
    if !u.contains("api_key=") {
        u.push(if u.contains('?') { '&' } else { '?' });
        u.push_str(&format!("api_key={}", s.token));
    }
    u
}

/// 正确解析播放地址:POST PlaybackInfo -> 用服务器给的 DirectStreamUrl/TranscodingUrl。
/// 返回 PlaybackTarget(含 PlaySessionId,供上报三件套贯穿使用)。
pub async fn resolve_stream(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Result<PlaybackTarget, String> {
    let url = format!(
        "{}/Items/{}/PlaybackInfo?UserId={}",
        s.server, item_id, s.user_id
    );
    // 宽松 DeviceProfile:声明啥都能直连,促使服务器返回 DirectStreamUrl
    let profile = serde_json::json!({
        "DeviceProfile": {
            "MaxStreamingBitrate": 120000000i64,
            "MaxStaticBitrate": 100000000i64,
            "DirectPlayProfiles": [ { "Type": "Video" }, { "Type": "Audio" } ],
            "TranscodingProfiles": [],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": []
        }
    });
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&profile)
        .send()
        .await
        .map_err(|e| format!("PlaybackInfo 网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("PlaybackInfo 失败: HTTP {}", resp.status()));
    }
    let info: PlaybackInfoResp = resp
        .json()
        .await
        .map_err(|e| format!("PlaybackInfo 解析失败: {e}"))?;
    // 服务器发的 PlaySessionId 优先;缺则本地兜底生成(但同一次播放内保持一致)。
    let play_session_id = info
        .play_session_id
        .filter(|x| !x.is_empty())
        .unwrap_or_else(|| format!("{}-{}", s.device_id, item_id));
    let ms = info
        .media_sources
        .into_iter()
        .next()
        .ok_or("该条目无可播放源")?;
    let media_source_id = ms.id.clone();

    let (url, play_method) = if let Some(d) = ms.direct_stream_url.filter(|x| !x.is_empty()) {
        (abs_url(s, &d), "DirectStream")
    } else if let Some(t) = ms.transcoding_url.filter(|x| !x.is_empty()) {
        (abs_url(s, &t), "Transcode")
    } else {
        // 兜底:用真实 mediaSourceId + container 直拼
        let container = ms.container.unwrap_or_default();
        let ext = if container.is_empty() {
            String::new()
        } else {
            format!(".{container}")
        };
        (
            format!(
                "{}/Videos/{}/stream{}?static=true&mediaSourceId={}&api_key={}",
                s.server, item_id, ext, media_source_id, s.token
            ),
            "DirectStream",
        )
    };

    Ok(PlaybackTarget {
        url,
        item_id: item_id.to_string(),
        media_source_id,
        play_session_id,
        play_method: play_method.to_string(),
    })
}

// ---------- 播放上报三件套(start / progress / stopped,同 PlaySessionId)----------

async fn post_report(
    http: &reqwest::Client,
    s: &Session,
    endpoint: &str,
    body: serde_json::Value,
) -> Result<(), String> {
    let url = format!("{}/Sessions/Playing{}", s.server, endpoint);
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("上报网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("上报失败: HTTP {}", resp.status()));
    }
    Ok(())
}

pub async fn report_start(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PlayMethod": t.play_method,
        "PositionTicks": secs_to_ticks(position_secs),
        "CanSeek": true,
        "IsPaused": false,
    });
    post_report(http, s, "", body).await
}

pub async fn report_progress(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
    paused: bool,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PlayMethod": t.play_method,
        "PositionTicks": secs_to_ticks(position_secs),
        "IsPaused": paused,
        "EventName": "timeupdate",
    });
    post_report(http, s, "/Progress", body).await
}

pub async fn report_stopped(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PositionTicks": secs_to_ticks(position_secs),
    });
    post_report(http, s, "/Stopped", body).await
}

/// 海报地址(前端展示用)。
pub fn image_url(s: &Session, item_id: &str) -> String {
    format!(
        "{}/Items/{}/Images/Primary?maxHeight=360&api_key={}",
        s.server, item_id, s.token
    )
}
