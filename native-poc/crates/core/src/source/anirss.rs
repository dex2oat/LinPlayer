// Ani-rss(wushuo894/ani-rss)后端。对齐 Dart anirss_backend.dart + anirss_token.dart。
// 登录:POST /api/login {username, password=MD5} → data=token(sha256 登录令牌)。
// 鉴权:Authorization 头;流 URL 用 ?s=<token> 查询鉴权。失效码 401/403 自动重登。
// 浏览映射:根=列番剧(当文件夹) → 番剧=playList 列剧集 → 点文件取流。
use super::{
    normalize_base_url, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError, SourceKind,
    SourceServer, SourceSubtitle,
};
use base64::Engine;
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

#[derive(Default)]
pub struct AniRssBackend {
    token_cache: Mutex<HashMap<String, String>>,
}

impl AniRssBackend {
    pub fn new() -> Self {
        Self::default()
    }

    fn md5_hex(input: &str) -> String {
        let mut h = Md5::new();
        h.update(input.as_bytes());
        h.finalize().iter().map(|b| format!("{b:02x}")).collect()
    }

    pub async fn login(
        http: &reqwest::Client,
        base_url: &str,
        username: &str,
        password: &str,
    ) -> Result<String, SourceError> {
        let base = normalize_base_url(base_url);
        let resp = http
            .post(format!("{base}/api/login"))
            .json(&json!({ "username": username, "password": Self::md5_hex(password) }))
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("无法连接服务器: {e}")))?;
        let body: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("登录响应异常: {e}")))?;
        if body["code"].as_i64() != Some(200) {
            return Err(SourceError::auth(
                body["message"].as_str().unwrap_or("登录失败").to_string(),
            ));
        }
        let token = body["data"].as_str().unwrap_or("").to_string();
        if token.is_empty() {
            return Err(SourceError::auth("登录未返回令牌"));
        }
        Ok(token)
    }

    fn cached_token(&self, server: &SourceServer) -> Option<String> {
        self.token_cache
            .lock()
            .unwrap()
            .get(&server.id)
            .cloned()
            .filter(|t| !t.is_empty())
            .or_else(|| server.token.clone().filter(|t| !t.is_empty()))
    }

    async fn ensure_token(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        force: bool,
    ) -> Result<String, SourceError> {
        if !force {
            if let Some(t) = self.cached_token(server) {
                return Ok(t);
            }
        }
        let u = server.username.clone().unwrap_or_default();
        let p = server.password.clone().unwrap_or_default();
        if u.is_empty() {
            return Err(SourceError::auth("登录已过期，请重新登录"));
        }
        let token = Self::login(http, &server.base_url, &u, &p).await?;
        self.token_cache
            .lock()
            .unwrap()
            .insert(server.id.clone(), token.clone());
        Ok(token)
    }

    /// 带 Authorization 头 POST(data 为 Null 时不带 body);code 401/403 自动重登一次。
    async fn authed(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        data: Value,
    ) -> Result<Value, SourceError> {
        let base = normalize_base_url(&server.base_url);
        let mut retried = false;
        loop {
            let token = self.ensure_token(http, server, retried).await?;
            let mut req = http
                .post(format!("{base}{path}"))
                .header("Authorization", &token);
            if !data.is_null() {
                req = req.json(&data);
            }
            let resp = req
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("请求失败: {e}")))?;
            let body: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("解析失败: {e}")))?;
            let code = body["code"].as_i64();
            if matches!(code, Some(401) | Some(403)) && !retried {
                self.token_cache.lock().unwrap().remove(&server.id);
                retried = true;
                continue;
            }
            if let Some(c) = code {
                if c != 200 {
                    return Err(SourceError {
                        message: body["message"]
                            .as_str()
                            .unwrap_or("Ani-rss 请求失败")
                            .to_string(),
                        is_auth: c == 401 || c == 403,
                    });
                }
            }
            return Ok(body);
        }
    }
}

/// base64 解码取末段文件名,失败回退原串(仅当 PlayItem 无 title/name 时的显示兜底)。
fn safe_decode(b64: &str) -> String {
    base64::engine::general_purpose::STANDARD
        .decode(b64)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .map(|s| s.rsplit('/').next().unwrap_or(&s).to_string())
        .unwrap_or_else(|| b64.to_string())
}

fn episode_of(e: &SourceEntry) -> f64 {
    e.raw
        .as_ref()
        .and_then(|r| r["episode"].as_f64())
        .unwrap_or(f64::INFINITY)
}

#[async_trait::async_trait]
impl MediaSourceBackend for AniRssBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::Anirss
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        match dir_id {
            // 根目录:列番剧(当文件夹)。data=ListAni{weekList:[{items:Ani[]}]}
            None | Some("") => {
                let body = self.authed(http, server, "/api/listAni", Value::Null).await?;
                let empty = vec![];
                let week = body["data"]["weekList"].as_array().unwrap_or(&empty);
                let mut seen = HashSet::new();
                let mut entries = Vec::new();
                for w in week {
                    for a in w["items"].as_array().unwrap_or(&empty) {
                        let id = a["id"]
                            .as_str()
                            .or_else(|| a["title"].as_str())
                            .unwrap_or("");
                        if id.is_empty() || !seen.insert(id.to_string()) {
                            continue;
                        }
                        let image = a["image"]
                            .as_str()
                            .filter(|s| s.starts_with("http"))
                            .map(|s| s.to_string());
                        entries.push(SourceEntry {
                            id: format!("ani:{}", serde_json::to_string(a).unwrap_or_default()),
                            name: a["title"].as_str().unwrap_or("未命名").to_string(),
                            is_dir: true,
                            is_video: false,
                            size: None,
                            thumb_url: image,
                            raw: Some(a.clone()),
                        });
                    }
                }
                entries.sort_by(|x, y| x.name.cmp(&y.name));
                Ok(entries)
            }
            // 番剧层:用该 Ani 调 playList 列剧集文件
            Some(d) if d.starts_with("ani:") => {
                let ani: Value = serde_json::from_str(&d[4..])
                    .map_err(|e| SourceError::msg(format!("番剧数据解析失败: {e}")))?;
                let body = self.authed(http, server, "/api/playList", ani).await?;
                let empty = vec![];
                let list = body["data"].as_array().unwrap_or(&empty);
                let mut entries: Vec<SourceEntry> = list
                    .iter()
                    .map(|p| {
                        let b64 = p["filename"].as_str().unwrap_or("").to_string();
                        let display = p["title"]
                            .as_str()
                            .or_else(|| p["name"].as_str())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| safe_decode(&b64));
                        SourceEntry {
                            id: format!("file:{b64}"),
                            name: display,
                            is_dir: false,
                            is_video: true,
                            size: None,
                            thumb_url: None,
                            raw: Some(
                                json!({ "filename": b64, "episode": p["episode"], "subtitles": p["subtitles"] }),
                            ),
                        }
                    })
                    .collect();
                entries.sort_by(|a, b| {
                    episode_of(a)
                        .partial_cmp(&episode_of(b))
                        .unwrap_or(Ordering::Equal)
                        .then_with(|| a.name.cmp(&b.name))
                });
                Ok(entries)
            }
            _ => Ok(vec![]),
        }
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        // filename 已是 base64(路径+文件名);优先 raw,回退从 id("file:<b64>")取。
        let b64 = entry
            .raw
            .as_ref()
            .and_then(|r| r["filename"].as_str().map(|s| s.to_string()))
            .or_else(|| entry.id.strip_prefix("file:").map(|s| s.to_string()))
            .unwrap_or_default();
        if b64.is_empty() {
            return Err(SourceError::msg("缺少文件信息"));
        }
        let token = self.ensure_token(http, server, false).await?;
        let base = normalize_base_url(&server.base_url);
        // URL 无法带请求头 → 用 s=<token> 查询鉴权;filename 已是 base64,交给 Url 正确转义。
        let url = reqwest::Url::parse_with_params(
            &format!("{base}/api/file"),
            &[("filename", b64.as_str()), ("s", token.as_str())],
        )
        .map_err(|e| SourceError::msg(format!("URL 构造失败: {e}")))?
        .to_string();
        // 外挂字幕:playList.subtitles(URL 自带 ?s=token 自鉴权,mpv 可直接挂)。
        // ponytail: getSubtitles 异步兜底未接;内封字幕 mpv 原生读。
        let subtitles: Vec<SourceSubtitle> = entry
            .raw
            .as_ref()
            .and_then(|r| r["subtitles"].as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|s| {
                        let u = s["url"].as_str().filter(|u| !u.is_empty())?;
                        let full = if u.starts_with("http") {
                            u.to_string()
                        } else {
                            format!("{base}{}{u}", if u.starts_with('/') { "" } else { "/" })
                        };
                        let sep = if full.contains('?') { "&" } else { "?" };
                        Some(SourceSubtitle {
                            url: format!("{full}{sep}s={}", urlencoding::encode(&token)),
                            title: s["name"].as_str().map(String::from),
                            language: None,
                            http_headers: HashMap::new(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let mut headers = HashMap::new();
        headers.insert("Authorization".to_string(), token);
        Ok(ResolvedPlay {
            url,
            title: entry.name.clone(),
            http_headers: headers,
            user_agent_override: None,
            subtitles,
            qualities: vec![],
            selected_quality_id: None,
        })
    }
}
