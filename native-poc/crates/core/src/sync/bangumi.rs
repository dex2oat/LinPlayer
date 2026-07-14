// Bangumi 同步内核 —— 迁自 Dart bangumi_sync_service.dart。
// 授权码(浏览器授权后手动粘贴 code)登录 + 令牌刷新 + 收藏/单集进度写入 + 追番日历。
// 换/刷令牌走已部署 CF 代理;其余直连 Bangumi(默认国内加速反代,官方常慢/不通)。
//
// ponytail: 反代/官方切换在 Dart 是 prefs 开关,PoC 默认反代(与 Dart 默认一致);切官方待前端补。

use serde_json::Value;

use super::calendar::CalendarEntry;
use super::{
    bangumi_app_id, proxy_headers, use_sync_proxy, SyncAccount, BANGUMI_API_MIRROR, SYNC_PROXY_BASE,
};

const API_BASE: &str = BANGUMI_API_MIRROR;
pub const DEFAULT_REDIRECT_URI: &str = "https://291277.xyz/oauth/bangumi";

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// 构造授权页 URL(用户浏览器打开授权,拿回 code 粘贴)。授权页也走反代免梯子。
pub fn build_authorize_url(redirect_uri: &str) -> String {
    format!(
        "{API_BASE}/oauth/authorize?client_id={}&response_type=code&redirect_uri={}",
        urlencoding::encode(&bangumi_app_id()),
        urlencoding::encode(redirect_uri)
    )
}

/// 用授权码换令牌(走代理)。
pub async fn exchange_code(code: &str, redirect_uri: &str) -> Result<SyncAccount, String> {
    if !use_sync_proxy() {
        return Err("未配置同步代理".into());
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/bangumi/token"))
        .json(&serde_json::json!({ "code": code.trim(), "redirect_uri": redirect_uri }));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("Bangumi 令牌交换失败: HTTP {}", resp.status().as_u16()));
    }
    let tok: Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(account_from_token(&tok, None).await)
}

/// 刷新令牌(走代理)。失败 None。
pub async fn refresh(account: &SyncAccount, redirect_uri: &str) -> Option<SyncAccount> {
    let rt = account.refresh_token.as_deref().filter(|s| !s.is_empty())?;
    if !use_sync_proxy() {
        return None;
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/bangumi/refresh"))
        .json(&serde_json::json!({ "refresh_token": rt, "redirect_uri": redirect_uri }));
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

pub async fn ensure_valid(account: &SyncAccount) -> Option<SyncAccount> {
    if !account.is_expired(now_ms()) {
        return Some(account.clone());
    }
    refresh(account, DEFAULT_REDIRECT_URI).await
}

fn build_account(tok: &Value, fallback: Option<&SyncAccount>) -> SyncAccount {
    let access = tok["access_token"]
        .as_str()
        .map(String::from)
        .or_else(|| fallback.map(|f| f.access_token.clone()))
        .unwrap_or_default();
    let expires_at = tok["expires_in"]
        .as_i64()
        .map(|e| now_ms() + e * 1000)
        .or_else(|| fallback.and_then(|f| f.expires_at));
    SyncAccount {
        service: "bangumi".into(),
        access_token: access,
        refresh_token: tok["refresh_token"]
            .as_str()
            .map(String::from)
            .or_else(|| fallback.and_then(|f| f.refresh_token.clone())),
        expires_at,
        username: fallback.and_then(|f| f.username.clone()),
        user_id: tok["user_id"]
            .as_str()
            .map(String::from)
            .or_else(|| fallback.and_then(|f| f.user_id.clone())),
    }
}

async fn account_from_token(tok: &Value, fallback: Option<&SyncAccount>) -> SyncAccount {
    let mut account = build_account(tok, fallback);
    if !account.access_token.is_empty() && account.username.is_none() {
        if let Some((name, uid)) = fetch_profile(&account.access_token).await {
            account.username = name;
            if account.user_id.is_none() {
                account.user_id = uid;
            }
        }
    }
    account
}

async fn fetch_profile(access: &str) -> Option<(Option<String>, Option<String>)> {
    let resp = crate::http::client()
        .get(format!("{API_BASE}/v0/me"))
        .header("Authorization", format!("Bearer {access}"))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: Value = resp.json().await.ok()?;
    let name = j["nickname"].as_str().or_else(|| j["username"].as_str()).map(String::from);
    Some((name, j["id"].as_str().map(String::from).or_else(|| j["id"].as_i64().map(|n| n.to_string()))))
}

/// 设置条目收藏状态(type: 1=想看 2=看过 3=在看 4=搁置 5=抛弃)。
/// 更新单集进度前必须先确保条目已收藏,否则未收藏的番更新单集会失败。
pub async fn set_collection_type(account: &SyncAccount, subject_id: i64, type_: i32) -> bool {
    let Some(valid) = ensure_valid(account).await else {
        return false;
    };
    crate::http::client()
        .post(format!("{API_BASE}/v0/users/-/collections/{subject_id}"))
        .header("Authorization", format!("Bearer {}", valid.access_token))
        .json(&serde_json::json!({ "type": type_ }))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// 更新单集观看状态(type: 2=看过)。
pub async fn update_episode_status(
    account: &SyncAccount,
    subject_id: i64,
    episode_id: i64,
    type_: i32,
) -> bool {
    let Some(valid) = ensure_valid(account).await else {
        return false;
    };
    crate::http::client()
        .put(format!("{API_BASE}/v0/users/-/collections/{subject_id}/episodes/{episode_id}"))
        .header("Authorization", format!("Bearer {}", valid.access_token))
        .json(&serde_json::json!({ "type": type_ }))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// 追番日历:当季放送表按每周放送日归组。only_mine=只保留我在看的番。
pub async fn fetch_anime_calendar(account: &SyncAccount, only_mine: bool) -> Vec<CalendarEntry> {
    let Some(valid) = ensure_valid(account).await else {
        return vec![];
    };
    let client = crate::http::client();

    // 1) 只看我追的:先取在看动画(subject_type=2,type=3)的 subject id 集合。
    let mut watching = std::collections::HashSet::new();
    if only_mine {
        let col = client
            .get(format!("{API_BASE}/v0/users/-/collections"))
            .header("Authorization", format!("Bearer {}", valid.access_token))
            .query(&[("subject_type", "2"), ("type", "3"), ("limit", "50")])
            .send()
            .await;
        if let Ok(r) = col {
            if let Ok(j) = r.json::<Value>().await {
                if let Some(arr) = j["data"].as_array() {
                    for it in arr {
                        if let Some(id) = it["subject_id"].as_i64() {
                            watching.insert(id);
                        }
                    }
                }
            }
        }
        if watching.is_empty() {
            return vec![];
        }
    }

    // 2) 当季放送表(onlyMine 时过滤出在看的)。
    let Ok(resp) = client.get(format!("{API_BASE}/calendar")).send().await else {
        return vec![];
    };
    let Ok(Value::Array(groups)) = resp.json::<Value>().await else {
        return vec![];
    };
    let mut out = Vec::new();
    for group in groups {
        let weekday = group["weekday"]["id"].as_i64().map(|w| w as i32);
        let Some(items) = group["items"].as_array() else {
            continue;
        };
        for item in items {
            let Some(id) = item["id"].as_i64() else { continue };
            if only_mine && !watching.contains(&id) {
                continue;
            }
            let name_cn = item["name_cn"].as_str().filter(|s| !s.is_empty());
            let title = name_cn
                .or_else(|| item["name"].as_str())
                .unwrap_or("未知番剧")
                .to_string();
            let img = ["common", "medium", "large"]
                .iter()
                .find_map(|k| item["images"][k].as_str())
                .map(String::from);
            let rating = item["rating"]["score"].as_f64();
            out.push(CalendarEntry {
                title,
                subtitle: rating.map(|r| format!("评分 {r}")),
                air_date: None,
                weekday,
                image_url: img,
                tmdb_id: None,
                source: "bangumi".into(),
            });
        }
    }
    out
}
