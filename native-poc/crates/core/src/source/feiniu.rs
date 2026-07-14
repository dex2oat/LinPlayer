// 飞牛影视(trimemedia / fnOS 视频)后端。对齐 Dart feiniu_backend.dart。
// {host}/v/api/v1/... ;账密 POST /login 拿 token 走 Authorization,每请求另带 authx 签名头。
// 浏览:媒体库/季当文件夹,电影/分集当可播文件,直连 media/range 走 Range(保留内封轨)。
use super::{
    normalize_base_url, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError, SourceKind,
    SourceServer,
};
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

// 签名常量(飞牛客户端硬编码,非用户密钥)。
const SIGN_SECRET: &str = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh";
const API_KEY: &str = "16CCEB3D-AB42-077D-36A1-F355324E4237";
const API_PREFIX: &str = "/v/api/v1";

#[derive(Default)]
pub struct FeiniuBackend {
    token_cache: Mutex<HashMap<String, String>>,
}

fn md5_hex(s: &str) -> String {
    let mut h = Md5::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn now_millis() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
        .to_string()
}

// ponytail: 用纳秒派生 6 位 nonce 代替 RNG —— 服务端只校验 sign 内一致性,不验随机质量。
fn nonce() -> String {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    (100000 + (n % 900000)).to_string()
}

/// authx 签名头。path=带 /v/api/v1 前缀的 API 路径;body=请求体字符串(GET 传空串)。
fn authx(path: &str, body: &str) -> String {
    let nonce = nonce();
    let ts = now_millis();
    let data_hash = md5_hex(body);
    let sign = md5_hex(
        &[
            SIGN_SECRET,
            path,
            nonce.as_str(),
            ts.as_str(),
            data_hash.as_str(),
            API_KEY,
        ]
        .join("_"),
    );
    format!("nonce={nonce}&timestamp={ts}&sign={sign}")
}

/// 拆 {code,msg,data} 信封,非零为错。
fn unwrap(body: &Value, auth: bool) -> Result<Value, SourceError> {
    if body["code"].as_i64() != Some(0) {
        let msg = body["msg"].as_str().unwrap_or("飞牛请求失败").to_string();
        return Err(SourceError { message: msg, is_auth: auth });
    }
    Ok(body["data"].clone())
}

fn title(m: &Value) -> String {
    m["title"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| m["original_title"].as_str())
        .unwrap_or("未命名")
        .to_string()
}

/// 分集名带上季/集号,便于列表区分。
fn episode_title(m: &Value) -> String {
    let t = title(m);
    if m["type"].as_str() == Some("Episode") {
        if let Some(ep) = m["episode_number"].as_i64() {
            let prefix = match m["season_number"].as_i64() {
                Some(se) => format!("S{se}E{ep}"),
                None => format!("E{ep}"),
            };
            return if t == "未命名" { prefix } else { format!("{prefix} {t}") };
        }
    }
    t
}

/// 单个 item → 目录(TV/季/Directory)或可播文件(电影/视频/分集)。
fn item_to_entry(m: &Value) -> SourceEntry {
    let guid = m["guid"].as_str().unwrap_or("").to_string();
    let dir = |prefix: &str| SourceEntry {
        id: format!("{prefix}:{guid}"),
        name: title(m),
        is_dir: true,
        is_video: false,
        size: None,
        thumb_url: None,
        raw: None,
    };
    match m["type"].as_str().unwrap_or("Video") {
        "TV" => dir("tv"),
        "Directory" => dir("dir"),
        "Season" => dir("season"),
        _ => SourceEntry {
            id: guid,
            name: episode_title(m),
            is_dir: false,
            is_video: true,
            size: m["file_size"].as_i64(),
            thumb_url: None,
            raw: None,
        },
    }
}

impl FeiniuBackend {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn login(
        http: &reqwest::Client,
        base_url: &str,
        username: &str,
        password: &str,
    ) -> Result<String, SourceError> {
        let base = normalize_base_url(base_url);
        let path = format!("{API_PREFIX}/login");
        // 密码明文(与飞牛 web/PC 一致,无 RSA/MD5 预处理)。
        let body = serde_json::to_string(&json!({
            "app_name": "trimemedia-web",
            "username": username,
            "password": password,
            "nonce": nonce(),
        }))
        .unwrap_or_default();
        let resp = http
            .post(format!("{base}{path}"))
            .header("Content-Type", "application/json")
            .header("Cookie", "mode=relay")
            .header("authx", authx(&path, &body))
            .body(body)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("无法连接飞牛服务器: {e}")))?;
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("飞牛响应异常: {e}")))?;
        let data = unwrap(&v, true)?;
        let token = data["token"].as_str().unwrap_or("").to_string();
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
        if u.is_empty() {
            return Err(SourceError::auth("登录已过期，请重新登录"));
        }
        let token = Self::login(
            http,
            &server.base_url,
            &u,
            &server.password.clone().unwrap_or_default(),
        )
        .await?;
        self.token_cache
            .lock()
            .unwrap()
            .insert(server.id.clone(), token.clone());
        Ok(token)
    }

    /// 带鉴权请求。suffix 不含 /v/api/v1 前缀;data=Some 走 POST(体内并入 nonce),None 走 GET。
    /// 飞牛不明确区分鉴权错误码,非零 code 统一重登兜底一次。
    async fn authed(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        suffix: &str,
        data: Option<Value>,
    ) -> Result<Value, SourceError> {
        let base = normalize_base_url(&server.base_url);
        let path = format!("{API_PREFIX}{suffix}");
        let mut retried = false;
        loop {
            let token = self.ensure_token(http, server, retried).await?;
            let body = match &data {
                Some(d) => {
                    let mut obj = d.clone();
                    if let Some(map) = obj.as_object_mut() {
                        map.insert("nonce".into(), json!(nonce()));
                    }
                    serde_json::to_string(&obj).unwrap_or_default()
                }
                None => String::new(),
            };
            let ax = authx(&path, &body);
            let url = format!("{base}{path}");
            let req = if data.is_some() {
                http.post(&url)
                    .header("Content-Type", "application/json")
                    .header("Authorization", &token)
                    .header("Cookie", "mode=relay")
                    .header("authx", ax)
                    .body(body)
            } else {
                http.get(&url)
                    .header("Authorization", &token)
                    .header("Cookie", "mode=relay")
                    .header("authx", ax)
            };
            let resp = req
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("飞牛请求失败: {e}")))?;
            let v: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("解析失败: {e}")))?;
            if v["code"].as_i64() != Some(0) && !retried {
                self.token_cache.lock().unwrap().remove(&server.id);
                retried = true;
                continue;
            }
            return unwrap(&v, true);
        }
    }

    async fn list_items(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        guid: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let data = self
            .authed(
                http,
                server,
                "/item/list",
                Some(json!({
                    "ancestor_guid": guid,
                    "tags": { "type": ["Movie", "TV", "Directory", "Video"] },
                    "exclude_grouped_video": 1,
                    "sort_type": "DESC",
                    "sort_column": "create_time",
                    "page": 1,
                    "page_size": 500,
                })),
            )
            .await?;
        let empty = vec![];
        Ok(data["list"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .map(item_to_entry)
            .collect())
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for FeiniuBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::Feiniu
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let d = match dir_id {
            Some(d) if !d.is_empty() => d,
            _ => {
                // 根:列媒体库
                let data = self.authed(http, server, "/mediadb/list", None).await?;
                let empty = vec![];
                return Ok(data
                    .as_array()
                    .unwrap_or(&empty)
                    .iter()
                    .map(|m| SourceEntry {
                        id: format!("lib:{}", m["guid"].as_str().unwrap_or("")),
                        name: m["title"]
                            .as_str()
                            .or_else(|| m["name"].as_str())
                            .unwrap_or("未命名媒体库")
                            .to_string(),
                        is_dir: true,
                        is_video: false,
                        size: None,
                        thumb_url: None,
                        raw: None,
                    })
                    .collect());
            }
        };
        let (kind, guid) = d.split_once(':').unwrap_or(("", d));
        match kind {
            "tv" => {
                // 季列表
                let data = self
                    .authed(http, server, &format!("/season/list/{guid}"), None)
                    .await?;
                let empty = vec![];
                Ok(data
                    .as_array()
                    .unwrap_or(&empty)
                    .iter()
                    .map(|m| SourceEntry {
                        id: format!("season:{}", m["guid"].as_str().unwrap_or("")),
                        name: match m["title"].as_str().filter(|s| !s.is_empty()) {
                            Some(t) => t.to_string(),
                            None => match m["season_number"].as_i64() {
                                Some(n) => format!("第 {n} 季"),
                                None => "季".to_string(),
                            },
                        },
                        is_dir: true,
                        is_video: false,
                        size: None,
                        thumb_url: None,
                        raw: None,
                    })
                    .collect())
            }
            "season" => {
                // 分集列表
                let data = self
                    .authed(http, server, &format!("/episode/list/{guid}"), None)
                    .await?;
                let empty = vec![];
                Ok(data
                    .as_array()
                    .unwrap_or(&empty)
                    .iter()
                    .map(item_to_entry)
                    .collect())
            }
            _ => self.list_items(http, server, guid).await, // lib / dir / 默认
        }
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let suffix = format!("/search/list?q={}", urlencoding::encode(query));
        let data = self.authed(http, server, &suffix, None).await?;
        let empty = vec![];
        Ok(data
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .map(item_to_entry)
            .filter(|e| !e.is_dir || e.id.starts_with("tv:"))
            .collect())
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let info = self
            .authed(http, server, "/play/info", Some(json!({ "item_guid": entry.id })))
            .await?;
        let media_guid = info["media_guid"].as_str().unwrap_or("");
        if media_guid.is_empty() {
            return Err(SourceError::msg("未获取到播放媒体"));
        }
        let token = self.cached_token(server).unwrap_or_default();
        let base = normalize_base_url(&server.base_url);
        let stream_path = format!("{API_PREFIX}/media/range/{media_guid}");
        // ponytail: 静态 authx(构造时算一次);若长播断流,升级为本地重签代理(见 Dart 类注释)。
        // ponytail: 外挂字幕(/stream/list)未接,内封由 mpv 直接读原文件;需外挂时补。
        let mut headers = HashMap::new();
        headers.insert("Authorization".to_string(), token);
        headers.insert("Cookie".to_string(), "mode=relay".to_string());
        headers.insert("authx".to_string(), authx(&stream_path, ""));
        Ok(ResolvedPlay::simple(
            format!("{base}{stream_path}"),
            entry.name.clone(),
            headers,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn md5_and_sign_shape() {
        // 已知向量,守住 authx 用的 md5 原语。
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        // authx 结构:三段 nonce/timestamp/sign,sign 为 32 位 hex。
        let ax = authx("/v/api/v1/login", "{}");
        let parts: Vec<&str> = ax.split('&').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts[0].starts_with("nonce="));
        assert!(parts[2].starts_with("sign="));
        assert_eq!(parts[2].trim_start_matches("sign=").len(), 32);
    }
}
