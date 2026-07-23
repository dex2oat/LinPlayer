// 飞牛影视(trimemedia / fnOS 视频)后端。对齐 Dart feiniu_backend.dart。
// {host}/v/api/v1/... ;账密 POST /login 拿 token 走 Authorization,每请求另带 authx 签名头。
// 浏览:媒体库/季当文件夹,电影/分集当可播文件,直连 media/range 走 Range(保留内封轨)。
use super::{
    normalize_base_url, MediaSourceBackend, PlayQuality, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer, SourceSubtitle,
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

/// 封面。服务端在 `poster` 里就给了**完整可直接取的 URL**,不需要拼、不需要 token。
/// 此前这里恒为 None —— 不是接口没有,是没去读这个字段。
fn poster(m: &Value) -> Option<String> {
    m["poster"]
        .as_str()
        .or_else(|| m["posters"].as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// 服务端已记录的观看进度,随列表一起回来 —— 不必为了续播多打一次接口。
/// 前端拿 raw.ts 当起播位置;watched=1 时归零,否则看完的片子会从末尾几秒起播。
fn progress_raw(m: &Value) -> Option<Value> {
    let ts = m["ts"].as_f64().unwrap_or(0.0);
    let duration = m["duration"].as_f64().unwrap_or(0.0);
    let watched = m["watched"].as_i64().unwrap_or(0);
    if ts <= 0.0 && duration <= 0.0 && watched == 0 {
        return None;
    }
    Some(json!({
        "ts": if watched == 1 { 0.0 } else { ts },
        "duration": duration,
        "watched": watched,
    }))
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
        thumb_url: poster(m),
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
            thumb_url: poster(m),
            raw: progress_raw(m),
        },
    }
}

/// 直链档位排序按**码率**,不按分辨率名 —— 分辨率是自由文本(1080P/1080p/FHD 各服务端不一),
/// 按名字映射迟早漏一种然后静默排错;码率是数字,永远可比。
fn direct_link_qualities(v: &Value) -> Vec<(PlayQuality, String, bool)> {
    let empty = vec![];
    let mut out: Vec<(PlayQuality, String, bool)> = v["direct_link_qualities"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter_map(|q| {
            let url = q["url"].as_str().filter(|s| !s.is_empty())?;
            let res = q["resolution"].as_str().unwrap_or("");
            let bitrate = q["bitrate"].as_i64().unwrap_or(0);
            let label = if res.is_empty() {
                format!("{} kbps", bitrate / 1000)
            } else {
                res.to_string()
            };
            Some((
                PlayQuality {
                    id: if res.is_empty() { bitrate.to_string() } else { res.to_string() },
                    label,
                    rank: (bitrate / 1000) as i32,
                },
                url.to_string(),
                q["is_m3u8"].as_bool() == Some(true),
            ))
        })
        .collect();
    out.sort_by(|a, b| b.0.rank.cmp(&a.0.rank));
    out
}

/// 外挂字幕轨 → 可挂载的 URL。
/// is_external=1 才是外挂(内封由 mpv 直接读原文件,重复挂会出现两条同样的轨);
/// is_bitmap=1 是 PGS/VOBSUB 位图字幕,下载成文本挂给 mpv 只会得到乱码,一并排除。
fn external_subtitles(v: &Value, base: &str, token: &str) -> Vec<SourceSubtitle> {
    let empty = vec![];
    v["subtitle_streams"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|s| s["is_external"].as_i64() == Some(1) && s["is_bitmap"].as_i64() != Some(1))
        .filter_map(|s| {
            let guid = s["guid"].as_str().filter(|g| !g.is_empty())?;
            let path = format!("{API_PREFIX}/subtitle/dl/{guid}");
            let mut headers = HashMap::new();
            headers.insert("Authorization".to_string(), token.to_string());
            headers.insert("Cookie".to_string(), "mode=relay".to_string());
            // 这里的静态 authx 是安全的:字幕是**一次性下载**,签完立刻用掉。
            // (媒体流不行 —— 那是几小时的长连接,见 resolve_play 里的说明。)
            headers.insert("authx".to_string(), authx(&path, ""));
            Some(SourceSubtitle {
                url: format!("{base}{path}"),
                title: s["title"]
                    .as_str()
                    .filter(|t| !t.is_empty())
                    .map(|t| t.to_string())
                    .or_else(|| s["language"].as_str().map(|l| l.to_string())),
                language: s["language"].as_str().map(|l| l.to_string()),
                http_headers: headers,
            })
        })
        .collect()
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
        SourceKind::feiniu()
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
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let info = self
            .authed(http, server, "/play/info", Some(json!({ "item_guid": entry.id })))
            .await?;
        let media_guid = info["media_guid"].as_str().unwrap_or("").to_string();
        if media_guid.is_empty() {
            return Err(SourceError::msg("未获取到播放媒体"));
        }
        let token = self.cached_token(server).unwrap_or_default();
        let base = normalize_base_url(&server.base_url);

        // /stream 一次拿齐:云盘直链档位 + 字幕轨 + 音轨。
        // 拿不到不致命 —— 本地文件走下面的 media/range 那条路照样能播。
        let stream = self
            .authed(
                http,
                server,
                "/stream",
                Some(json!({
                    "header": { "User-Agent": ["trim_player"] },
                    "level": 1,
                    "media_guid": media_guid,
                    "ip": stable_client_id(server),
                })),
            )
            .await
            .unwrap_or(Value::Null);

        let subtitles = external_subtitles(&stream, &base, &token);
        let links = direct_link_qualities(&stream);

        // ★ 挂了网盘的片子走云盘直链,本地文件走 media/range。
        //   判据抄自客户端源码里那个 if:direct_link_qualities 非空即用直链。
        //   此前无条件走 media/range —— 飞牛挂网盘的片子很可能根本播不了。
        if !links.is_empty() {
            let chosen = quality_id
                .and_then(|q| links.iter().find(|(pq, _, _)| pq.id == q))
                .unwrap_or(&links[0]);
            let mut headers = HashMap::new();
            // 云盘直链要带服务端指定的 Cookie(网盘鉴权),不带就 403。
            if let Some(c) = stream["header"]["Cookie"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str())
                        .collect::<Vec<_>>()
                        .join("; ")
                })
                .filter(|s| !s.is_empty())
            {
                headers.insert("Cookie".to_string(), c);
            }
            return Ok(ResolvedPlay {
                url: chosen.1.clone(),
                title: entry.name.clone(),
                http_headers: headers,
                user_agent_override: None,
                subtitles,
                qualities: links.iter().map(|(q, _, _)| q.clone()).collect(),
                selected_quality_id: Some(chosen.0.id.clone()),
            });
        }

        // 本地文件:直连 media/range 取原文件(保留内封轨)。
        //
        // ★ 这里**不能带 authx**。它是构造时算死的一次性签名,而取流是几小时的长连接 ——
        //   过期后服务端拒收,表现为"看着看着断流"。官方客户端的 media/range 本就
        //   只发 Authorization + Cookie,authx 是多发的,发了才是病根。
        //   (字幕那种一次性下载带静态 authx 没问题,见 external_subtitles。)
        let stream_path = format!("{API_PREFIX}/media/range/{media_guid}");
        let headers = media_range_headers(&token);

        // 本地文件的可选清晰度另有接口(转码档),取不到就只有原画一档。
        let qualities: Vec<PlayQuality> = self
            .authed(http, server, "/play/quality", Some(json!({ "media_guid": media_guid })))
            .await
            .ok()
            .and_then(|q| q.as_array().cloned())
            .map(|arr| {
                let mut qs: Vec<PlayQuality> = arr
                    .iter()
                    .filter_map(|q| {
                        let res = q["resolution"].as_str()?;
                        let bitrate = q["bitrate"].as_i64().unwrap_or(0);
                        Some(PlayQuality {
                            id: res.to_string(),
                            label: res.to_string(),
                            rank: (bitrate / 1000) as i32,
                        })
                    })
                    .collect();
                qs.sort_by(|a, b| b.rank.cmp(&a.rank));
                qs
            })
            .unwrap_or_default();

        Ok(ResolvedPlay {
            url: format!("{base}{stream_path}"),
            title: entry.name.clone(),
            http_headers: headers,
            user_agent_override: None,
            subtitles,
            qualities,
            selected_quality_id: None,
        })
    }

    /// 进度上报 → 服务端观看记录,退出后再进来能接着看。
    /// 各轨 guid 缺省留空:服务端只用它们回填"上次选的音轨/字幕",空值不影响进度本身。
    async fn report_progress(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        position_secs: f64,
        duration_secs: f64,
        finished: bool,
    ) -> Result<(), SourceError> {
        // 目录条目没有播放进度可言。
        if entry.is_dir || entry.id.is_empty() || entry.id.contains(':') {
            return Ok(());
        }
        let media_guid = self
            .authed(http, server, "/play/info", Some(json!({ "item_guid": entry.id })))
            .await
            .ok()
            .and_then(|i| i["media_guid"].as_str().map(|s| s.to_string()))
            .unwrap_or_default();

        let _ = self
            .authed(
                http,
                server,
                "/play/record",
                Some(json!({
                    "item_guid": entry.id,
                    "media_guid": media_guid,
                    "video_guid": "",
                    "audio_guid": "",
                    "subtitle_guid": "",
                    "play_link": "",
                    "ts": position_secs,
                    "duration": duration_secs,
                })),
            )
            .await;

        // 播完额外打一次已看标记 —— /play/record 只记进度,不置"已观看"。
        if finished {
            let _ = self
                .authed(http, server, "/item/watched", Some(json!({ "item_guid": entry.id })))
                .await;
        }
        Ok(())
    }
}

/// media/range 取流头。**只有这两个,不许加 authx** —— 单独成函数就是为了让
/// `media_range_headers_must_not_carry_authx` 能把这条钉死,防止有人"顺手补齐签名"把病根加回来。
fn media_range_headers(token: &str) -> HashMap<String, String> {
    let mut h = HashMap::new();
    h.insert("Authorization".to_string(), token.to_string());
    h.insert("Cookie".to_string(), "mode=relay".to_string());
    h
}

/// `/stream` 的 ip 参数在官方客户端里是**由账号派生的稳定标识**,不是真 IP。
/// 用用户名的 md5 排成 UUID 形状:同一账号恒定,不同账号不同。
fn stable_client_id(server: &SourceServer) -> String {
    let seed = server
        .username
        .clone()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| server.id.clone());
    let h = md5_hex(&seed);
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
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

    /// ★ 长播断流的病根。authx 是**构造时算死的一次性签名**,而 media/range 是几小时的长连接,
    /// 签名过期后服务端拒收 —— 表现为"看着看着断流",且没有任何一行日志指向签名。
    /// 官方客户端的这个请求本就只发 Authorization + Cookie。这条钉住"别再把它加回来"。
    #[test]
    fn media_range_headers_must_not_carry_authx() {
        let h = media_range_headers("tok123");
        assert_eq!(h.get("Authorization").map(String::as_str), Some("tok123"));
        assert_eq!(h.get("Cookie").map(String::as_str), Some("mode=relay"));
        assert!(
            !h.keys().any(|k| k.eq_ignore_ascii_case("authx")),
            "media/range 不能带 authx —— 静态签名会在长播途中过期导致断流"
        );
        assert_eq!(h.len(), 2, "多发任何一个头都可能被服务端拒");
    }

    /// 封面此前恒为 None,不是接口没有而是没读字段。poster 已是完整 URL,不许再拼。
    #[test]
    fn poster_is_taken_as_a_complete_url() {
        let m = json!({"guid":"g","type":"Movie","poster":"https://nas/img/a.jpg"});
        assert_eq!(item_to_entry(&m).thumb_url.as_deref(), Some("https://nas/img/a.jpg"));
        // 目录也要有封面(媒体库/季的海报)。
        let tv = json!({"guid":"g","type":"TV","title":"剧","poster":"https://nas/t.jpg"});
        let e = item_to_entry(&tv);
        assert!(e.is_dir && e.thumb_url.as_deref() == Some("https://nas/t.jpg"));
        // 空串等于没有,别让 UI 去加载一个空 URL。
        let blank = json!({"guid":"g","type":"Movie","poster":""});
        assert_eq!(item_to_entry(&blank).thumb_url, None);
    }

    /// 看完的片子必须从 0 起播。不归零的话 watched=1 且 ts 停在末尾,
    /// 重看时会直接跳到最后几秒然后立刻结束。
    #[test]
    fn watched_items_resume_from_zero() {
        let half = json!({"guid":"g","type":"Movie","ts":1200.0,"duration":3600.0,"watched":0});
        let r = item_to_entry(&half).raw.unwrap();
        assert_eq!(r["ts"], 1200.0);
        assert_eq!(r["duration"], 3600.0);

        let done = json!({"guid":"g","type":"Movie","ts":3590.0,"duration":3600.0,"watched":1});
        let r = item_to_entry(&done).raw.unwrap();
        assert_eq!(r["ts"], 0.0, "看完的片子要从头播");
        assert_eq!(r["watched"], 1);

        // 全无进度信息时不产出 raw,免得前端拿到一堆全零对象。
        let fresh = json!({"guid":"g","type":"Movie"});
        assert!(item_to_entry(&fresh).raw.is_none());
    }

    /// 档位按码率排序 —— 分辨率是自由文本,按名字映射迟早漏一种然后静默排错。
    #[test]
    fn direct_links_sort_by_bitrate_descending() {
        let v = json!({"direct_link_qualities":[
            {"resolution":"720P","bitrate":2_000_000,"url":"u720","is_m3u8":false},
            {"resolution":"4K","bitrate":40_000_000,"url":"u4k","is_m3u8":true},
            {"resolution":"1080P","bitrate":8_000_000,"url":"u1080","is_m3u8":false},
            {"resolution":"坏的","bitrate":1,"url":""}
        ]});
        let q = direct_link_qualities(&v);
        assert_eq!(q.len(), 3, "url 为空的档位必须丢掉(选中就是黑屏)");
        assert_eq!(q[0].0.id, "4K");
        assert_eq!(q[1].0.id, "1080P");
        assert_eq!(q[2].0.id, "720P");
        assert_eq!(q[0].1, "u4k");
        assert!(q[0].2, "is_m3u8 要带出来");

        // 没有直链档位 = 本地文件,上层据此走 media/range。
        assert!(direct_link_qualities(&json!({})).is_empty());
    }

    /// 只挂外挂字幕:内封轨 mpv 自己会从原文件读,重复挂会出现两条一模一样的轨;
    /// 位图字幕(PGS)下成文本挂上去只会是乱码。
    #[test]
    fn only_external_non_bitmap_subtitles_are_attached() {
        let v = json!({"subtitle_streams":[
            {"guid":"s1","title":"简体中文","language":"chi","is_external":1,"is_bitmap":0},
            {"guid":"s2","title":"内封英文","language":"eng","is_external":0,"is_bitmap":0},
            {"guid":"s3","title":"PGS","language":"chi","is_external":1,"is_bitmap":1},
            {"guid":"","title":"无guid","is_external":1,"is_bitmap":0}
        ]});
        let subs = external_subtitles(&v, "https://nas", "tok");
        assert_eq!(subs.len(), 1, "只有 s1 该被挂上");
        assert_eq!(subs[0].url, "https://nas/v/api/v1/subtitle/dl/s1");
        assert_eq!(subs[0].title.as_deref(), Some("简体中文"));
        assert_eq!(subs[0].language.as_deref(), Some("chi"));
        // 字幕是一次性下载,带静态 authx 是安全的(与 media/range 的长连接不同)。
        assert!(subs[0].http_headers.contains_key("authx"));
        assert_eq!(subs[0].http_headers.get("Authorization").map(String::as_str), Some("tok"));
    }

    /// ip 参数是账号派生的稳定标识:同账号恒定、不同账号不同、形状是 UUID。
    #[test]
    fn stable_client_id_is_deterministic_per_account() {
        let mk = |u: &str| SourceServer {
            id: "srv".into(),
            username: Some(u.into()),
            ..Default::default()
        };
        let a = stable_client_id(&mk("alice"));
        assert_eq!(a, stable_client_id(&mk("alice")), "同账号必须恒定");
        assert_ne!(a, stable_client_id(&mk("bob")));
        let parts: Vec<&str> = a.split('-').collect();
        assert_eq!(
            parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12]
        );
    }
}
