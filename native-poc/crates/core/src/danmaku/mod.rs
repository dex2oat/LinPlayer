// 弹幕核:弹弹Play 官方源(签名)+ 自建源(none/pathToken/headerToken/queryToken)统一由 config 驱动。
// 对齐 Dart lib/core/api/danmaku/(dandan_signing + danmaku_source)。
// 签名:X-Signature = Base64(SHA256(AppId + Timestamp + Path + AppSecret))。
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum DanmakuAuthType {
    None,
    DandanplaySignature,
    PathToken,
    HeaderToken,
    QueryToken,
}

#[derive(Clone, Default)]
pub struct DanmakuSourceConfig {
    pub id: String,
    pub name: String,
    pub api_url: String,
    /// 弹弹Play 官方源(固定 base + 强制签名)。
    pub official: bool,
    pub auth_type: Option<DanmakuAuthType>,
    pub token: Option<String>,
    pub app_id: Option<String>,
    pub app_secret: Option<String>,
}

/// 一条弹幕(归一化)。
#[derive(Serialize, Clone)]
pub struct DanmakuComment {
    pub time: f64,
    pub text: String,
    pub mode: i32,  // 1=滚动 4=底 5=顶
    pub color: i32, // RGB int
    pub source: String,
    pub cid: Option<String>,
    pub user_id: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct DanmakuEpisode {
    pub episode_id: String,
    pub episode_title: String,
    pub episode_number: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct DanmakuAnime {
    pub anime_id: String,
    pub anime_title: String,
    pub type_: Option<String>,
    pub type_description: Option<String>,
    pub image_url: Option<String>,
    pub year: Option<i64>,
    pub episode_count: Option<i64>,
    pub episodes: Vec<DanmakuEpisode>,
}

const OFFICIAL_BASE: &str = "https://api.dandanplay.net";

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn signature(app_id: &str, path: &str, ts: i64, secret: &str) -> String {
    let mut h = Sha256::new();
    h.update(format!("{app_id}{ts}{path}{secret}").as_bytes());
    base64::engine::general_purpose::STANDARD.encode(h.finalize())
}

impl DanmakuSourceConfig {
    fn auth(&self) -> DanmakuAuthType {
        self.auth_type.unwrap_or(DanmakuAuthType::None)
    }

    /// 归一化到以 /api/v2 结尾的基础地址。
    fn base_url(&self) -> String {
        let url = self.api_url.trim().trim_end_matches('/').to_string();
        if url.ends_with("/api/v2") {
            url
        } else if url.ends_with("/api/v1") {
            format!("{}/api/v2", &url[..url.len() - 7])
        } else {
            format!("{url}/api/v2")
        }
    }

    /// pathToken 插入后的真正请求基址。
    fn request_base_url(&self) -> String {
        let base = self.base_url();
        if self.auth() != DanmakuAuthType::PathToken {
            return base;
        }
        let t = self.token.as_deref().unwrap_or("").trim();
        if t.is_empty() || base.contains(&format!("/{t}/")) {
            return base;
        }
        if let Some(host) = base.strip_suffix("/api/v2") {
            format!("{host}/{t}/api/v2")
        } else {
            format!("{base}/{t}")
        }
    }

    /// endpoint 形如 "/search/anime"。
    fn endpoint_url(&self, endpoint: &str) -> String {
        if self.official {
            format!("{OFFICIAL_BASE}/api/v2{endpoint}")
        } else {
            format!("{}{}", self.request_base_url(), endpoint)
        }
    }

    /// 返回 (headers, query 追加项)。官方或 dandanplaySignature 走签名;其余按 authType。
    fn auth_parts(&self, endpoint: &str) -> (Vec<(String, String)>, Vec<(String, String)>) {
        let mut headers = Vec::new();
        let mut query = Vec::new();
        let sign_path = format!("/api/v2{endpoint}");

        let mut sign_with = |app_id: &str, secret: &str| {
            let ts = now_secs();
            headers.push(("X-AppId".into(), app_id.to_string()));
            headers.push(("X-Timestamp".into(), ts.to_string()));
            headers.push(("X-Signature".into(), signature(app_id, &sign_path, ts, secret)));
        };

        if self.official || self.auth() == DanmakuAuthType::DandanplaySignature {
            let app_id = self.app_id.as_deref().unwrap_or("").trim().to_string();
            // 多 secret 换行分隔;取首个非空(轮换是配额分摊,不影响正确性)。
            let secret = self
                .app_secret
                .as_deref()
                .unwrap_or("")
                .split('\n')
                .map(|s| s.trim())
                .find(|s| !s.is_empty())
                .unwrap_or("")
                .to_string();
            if !app_id.is_empty() && !secret.is_empty() {
                sign_with(&app_id, &secret);
            }
            return (headers, query);
        }

        match self.auth() {
            DanmakuAuthType::HeaderToken => {
                if let Some(t) = self.token.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
                    headers.push(("Authorization".into(), format!("Bearer {t}")));
                    headers.push(("X-Token".into(), t.to_string()));
                    headers.push(("X-Api-Key".into(), t.to_string()));
                }
            }
            DanmakuAuthType::QueryToken => {
                if let Some(t) = self.token.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
                    query.push(("token".into(), t.to_string()));
                }
            }
            _ => {}
        }
        (headers, query)
    }
}

// ---------- 解析 ----------

fn parse_comment(d: &Value, source: &str) -> DanmakuComment {
    // 弹弹Play p 字段: time,mode,color,userId
    let p: Vec<&str> = d["p"].as_str().unwrap_or("").split(',').collect();
    DanmakuComment {
        time: p.first().and_then(|s| s.parse().ok()).unwrap_or(0.0),
        text: d["m"].as_str().unwrap_or("").to_string(),
        mode: p.get(1).and_then(|s| s.parse().ok()).unwrap_or(1),
        color: p.get(2).and_then(|s| s.parse().ok()).unwrap_or(16777215),
        source: source.to_string(),
        cid: d["cid"].as_str().map(|s| s.to_string()),
        user_id: p.get(3).map(|s| s.to_string()),
    }
}

fn parse_comments(raw: &Value, source: &str) -> Vec<DanmakuComment> {
    raw.as_array()
        .map(|a| a.iter().map(|d| parse_comment(d, source)).collect())
        .unwrap_or_default()
}

fn parse_anime(a: &Value) -> DanmakuAnime {
    let episodes = a["episodes"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .map(|ep| DanmakuEpisode {
                    episode_id: ep["episodeId"].as_str().map(String::from).unwrap_or_else(|| {
                        ep["episodeId"].as_i64().map(|n| n.to_string()).unwrap_or_default()
                    }),
                    episode_title: ep["episodeTitle"].as_str().unwrap_or("").to_string(),
                    episode_number: ep["episodeNumber"].as_str().map(String::from),
                })
                .collect()
        })
        .unwrap_or_default();
    DanmakuAnime {
        anime_id: a["animeId"]
            .as_str()
            .map(String::from)
            .or_else(|| a["animeId"].as_i64().map(|n| n.to_string()))
            .unwrap_or_default(),
        anime_title: a["animeTitle"].as_str().unwrap_or("").to_string(),
        type_: a["type"].as_str().map(String::from),
        type_description: a["typeDescription"].as_str().map(String::from),
        image_url: a["imageUrl"].as_str().map(String::from),
        year: a["year"].as_i64(),
        episode_count: a["episodeCount"].as_i64(),
        episodes,
    }
}

// ---------- 请求 ----------

async fn get_json(
    http: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    query: &[(String, String)],
) -> Result<Value, String> {
    let mut req = http.get(url);
    for (k, v) in headers {
        req = req.header(k.as_str(), v);
    }
    if !query.is_empty() {
        req = req.query(query);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| format!("弹幕请求失败: {e}"))?;
    resp.json().await.map_err(|e| format!("弹幕解析失败: {e}"))
}

/// 搜番:GET /search/anime?keyword= → animes[]。
pub async fn search_anime(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    keyword: &str,
) -> Result<Vec<DanmakuAnime>, String> {
    let (headers, mut query) = cfg.auth_parts("/search/anime");
    query.push(("keyword".into(), keyword.to_string()));
    let v = get_json(http, &cfg.endpoint_url("/search/anime"), &headers, &query).await?;
    Ok(v["animes"]
        .as_array()
        .map(|a| a.iter().map(parse_anime).collect())
        .unwrap_or_default())
}

/// 搜集:GET /search/episodes?anime=&episode= → animes[](带 episodes)。
pub async fn search_episodes(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    anime: Option<&str>,
    episode: Option<&str>,
) -> Result<Vec<DanmakuAnime>, String> {
    let (headers, mut query) = cfg.auth_parts("/search/episodes");
    if let Some(a) = anime {
        query.push(("anime".into(), a.to_string()));
    }
    if let Some(e) = episode {
        query.push(("episode".into(), e.to_string()));
    }
    let v = get_json(http, &cfg.endpoint_url("/search/episodes"), &headers, &query).await?;
    Ok(v["animes"]
        .as_array()
        .map(|a| a.iter().map(parse_anime).collect())
        .unwrap_or_default())
}

/// 取评论:GET /comment/{episodeId}?withRelated&chConvert → comments[]。
/// ponytail: 自建源的 taskId 异步轮询(misaka 风格)未接 —— 直返 comments;需异步时在桌面层加轮询。
pub async fn get_comments(
    http: &reqwest::Client,
    cfg: &DanmakuSourceConfig,
    episode_id: &str,
    ch_convert: i32,
) -> Result<Vec<DanmakuComment>, String> {
    let endpoint = format!("/comment/{episode_id}");
    let (headers, mut query) = cfg.auth_parts(&endpoint);
    query.push(("withRelated".into(), "true".into()));
    if ch_convert != 0 {
        query.push(("chConvert".into(), ch_convert.to_string()));
    }
    let v = get_json(http, &cfg.endpoint_url(&endpoint), &headers, &query).await?;
    Ok(parse_comments(&v["comments"], &cfg.name))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse_and_sign() {
        let d = serde_json::json!({ "p": "12.5,5,16711680,user9", "m": "顶部红字", "cid": "88" });
        let c = parse_comment(&d, "弹弹play");
        assert_eq!(c.time, 12.5);
        assert_eq!(c.mode, 5);
        assert_eq!(c.color, 16711680);
        assert_eq!(c.text, "顶部红字");
        assert_eq!(c.user_id.as_deref(), Some("user9"));
        assert_eq!(c.cid.as_deref(), Some("88"));
        // 签名 = base64(sha256(...)) = 32 字节 → 44 字符 base64
        assert_eq!(signature("appid", "/api/v2/x", 0, "secret").len(), 44);
    }

    #[test]
    fn base_url_and_pathtoken() {
        let mut cfg = DanmakuSourceConfig {
            api_url: "https://d.example.com/".into(),
            ..Default::default()
        };
        assert_eq!(cfg.base_url(), "https://d.example.com/api/v2");
        cfg.auth_type = Some(DanmakuAuthType::PathToken);
        cfg.token = Some("tok123".into());
        assert_eq!(cfg.request_base_url(), "https://d.example.com/tok123/api/v2");
    }
}
