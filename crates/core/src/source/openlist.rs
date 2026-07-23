// OpenList / AList 后端。对齐 Dart openlist_backend.dart。
// 账密登录拿 JWT -> /api/fs/list 列目录 -> /api/fs/get 取 raw_url 直链;401 自动重登。
use super::{
    is_video_file_name, normalize_base_url, sort_entries, MediaSourceBackend, ResolvedPlay,
    SourceEntry, SourceError, SourceKind, SourceServer,
};
use serde_json::json;
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct OpenListBackend {
    /// 内存 token 缓存(serverId -> token),避免每次请求都重登。
    token_cache: Mutex<HashMap<String, String>>,
}

impl OpenListBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// 账密登录拿 token。首次登录与 401 自动重登复用。
    pub async fn login(
        http: &reqwest::Client,
        base_url: &str,
        username: &str,
        password: &str,
    ) -> Result<String, SourceError> {
        let base = normalize_base_url(base_url);
        let resp = http
            .post(format!("{base}/api/auth/login"))
            .json(&json!({ "username": username, "password": password }))
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("无法连接服务器: {e}")))?;
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("登录响应异常: {e}")))?;
        if body["code"].as_i64() != Some(200) {
            let msg = body["message"].as_str().unwrap_or("登录失败").to_string();
            return Err(SourceError::auth(msg));
        }
        let token = body["data"]["token"].as_str().unwrap_or("").to_string();
        if token.is_empty() {
            return Err(SourceError::auth("登录未返回 token"));
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

    /// 带鉴权 POST,读 {code,message,data};code==401 自动重登一次。
    async fn authed(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        data: serde_json::Value,
    ) -> Result<serde_json::Value, SourceError> {
        let base = normalize_base_url(&server.base_url);
        let mut retried = false;
        loop {
            let token = self.ensure_token(http, server, retried).await?;
            let resp = http
                .post(format!("{base}{path}"))
                .header("Authorization", &token)
                .json(&data)
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("请求失败: {e}")))?;
            let body: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("解析失败: {e}")))?;
            let code = body["code"].as_i64();
            if code == Some(401) && !retried {
                self.token_cache.lock().unwrap().remove(&server.id);
                retried = true;
                continue;
            }
            if code != Some(200) {
                let msg = body["message"]
                    .as_str()
                    .unwrap_or("OpenList 请求失败")
                    .to_string();
                return Err(SourceError { message: msg, is_auth: code == Some(401) });
            }
            return Ok(body);
        }
    }
}

fn abs_thumb(base: &str, thumb: &str) -> String {
    if thumb.starts_with("http") {
        thumb.to_string()
    } else {
        format!("{base}{thumb}")
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for OpenListBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::openlist()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let path = match dir_id {
            Some(d) if !d.is_empty() => d.to_string(),
            _ => "/".to_string(),
        };
        let body = self
            .authed(
                http,
                server,
                "/api/fs/list",
                json!({ "path": path, "password": "", "page": 1, "per_page": 0, "refresh": false }),
            )
            .await?;
        let base = normalize_base_url(&server.base_url);
        let empty = vec![];
        let content = body["data"]["content"].as_array().unwrap_or(&empty);
        let mut entries: Vec<SourceEntry> = content
            .iter()
            .map(|m| {
                let name = m["name"].as_str().unwrap_or("").to_string();
                let is_dir = m["is_dir"].as_bool().unwrap_or(false);
                let child_path = if path == "/" {
                    format!("/{name}")
                } else {
                    format!("{path}/{name}")
                };
                let thumb = m["thumb"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(|t| abs_thumb(&base, t));
                SourceEntry {
                    id: child_path.clone(),
                    is_video: !is_dir && is_video_file_name(&name),
                    name,
                    is_dir,
                    size: m["size"].as_i64(),
                    thumb_url: thumb,
                    raw: Some(json!({ "path": child_path })),
                }
            })
            .collect();
        sort_entries(&mut entries);
        Ok(entries)
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let body = self
            .authed(
                http,
                server,
                "/api/fs/search",
                json!({ "parent": "/", "keywords": query, "scope": 0, "page": 1, "per_page": 100, "password": "" }),
            )
            .await?;
        let empty = vec![];
        let content = body["data"]["content"].as_array().unwrap_or(&empty);
        Ok(content
            .iter()
            .map(|m| {
                let parent = m["parent"].as_str().unwrap_or("/");
                let name = m["name"].as_str().unwrap_or("").to_string();
                let is_dir = m["is_dir"].as_bool().unwrap_or(false);
                let full = if parent.ends_with('/') {
                    format!("{parent}{name}")
                } else {
                    format!("{parent}/{name}")
                };
                SourceEntry {
                    id: full,
                    is_video: !is_dir && is_video_file_name(&name),
                    name,
                    is_dir,
                    size: m["size"].as_i64(),
                    thumb_url: None,
                    raw: None,
                }
            })
            .collect())
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let body = self
            .authed(
                http,
                server,
                "/api/fs/get",
                json!({ "path": entry.id, "password": "" }),
            )
            .await?;
        let raw_url = body["data"]["raw_url"].as_str().unwrap_or("").to_string();
        if raw_url.is_empty() {
            return Err(SourceError::msg("未获取到播放地址"));
        }
        // 仅当直链回指本服务器时附带 Authorization 兜底,避免把 token 泄露给第三方 CDN。
        let mut headers = HashMap::new();
        let base = normalize_base_url(&server.base_url);
        if let Some(t) = self.cached_token(server) {
            if raw_url.starts_with(&base) {
                headers.insert("Authorization".to_string(), t);
            }
        }
        Ok(ResolvedPlay::simple(raw_url, entry.name.clone(), headers))
    }
}
