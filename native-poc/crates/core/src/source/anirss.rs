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

    /// 清掉某服务器的 token 缓存(重新登录/移除服务器时调用)。对齐 Dart AniRssAuth.clearToken。
    pub fn clear_token(&self, server_id: &str) {
        self.token_cache.lock().unwrap().remove(server_id);
    }

    /// 手动写入 token(如登录页拿到新 token 后同步缓存)。对齐 Dart AniRssAuth.cacheToken。
    pub fn cache_token(&self, server_id: &str, token: String) {
        self.token_cache
            .lock()
            .unwrap()
            .insert(server_id.to_string(), token);
    }

    /// 请求内核(浏览/播放/管理共用)。对齐 Dart AniRssAuth.authed:
    /// - method:ani-rss 绝大多数接口是 POST,仅 ping/downloadLogs 走 GET;
    /// - data:非 Null 时作 JSON body。可以是对象(Ani/Config),也可以是数组
    ///   (deleteAni/batchEnable 直接把 id 列表当 body);
    /// - query:bool 序列化成 "true"/"false",与 dio queryParameters 一致;
    /// - 返回响应体**原文**:JSON 包装体由调用方解;downloadLogs 那种纯文本直接透传
    ///   (对齐 Dart `code == null` 时不判错的分支);
    /// - code 401/403 → 清缓存 + 用账密重登一次。
    async fn request_text(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        method: reqwest::Method,
        path: &str,
        data: Value,
        query: &[(&str, String)],
    ) -> Result<String, SourceError> {
        let base = normalize_base_url(&server.base_url);
        // 注意:空 query 时不碰 query_pairs_mut,否则 URL 会被追加一个裸 "?"。
        let mut url = reqwest::Url::parse(&format!("{base}{path}"))
            .map_err(|e| SourceError::msg(format!("URL 构造失败: {e}")))?;
        if !query.is_empty() {
            url.query_pairs_mut()
                .extend_pairs(query.iter().map(|(k, v)| (*k, v.as_str())));
        }
        let mut retried = false;
        loop {
            let token = self.ensure_token(http, server, retried).await?;
            let mut req = http
                .request(method.clone(), url.clone())
                .header("Authorization", &token);
            if !data.is_null() {
                req = req.json(&data);
            }
            let resp = req
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("请求失败: {e}")))?;
            let text = resp
                .text()
                .await
                .map_err(|e| SourceError::msg(format!("读取响应失败: {e}")))?;
            if matches!(wrap_code(&text), Some(401) | Some(403)) && !retried {
                self.token_cache.lock().unwrap().remove(&server.id);
                retried = true;
                continue;
            }
            if let Some(e) = wrap_error(&text) {
                return Err(e);
            }
            return Ok(text);
        }
    }

    /// POST + 解出包装体的 `data` 字段(对齐 Dart authed + unwrap 的常见组合)。
    /// 缺 data 时返回 Value::Null,与 Dart 的 `body['data']` 取空一致。
    async fn call(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        data: Value,
        query: &[(&str, String)],
    ) -> Result<Value, SourceError> {
        let text = self
            .request_text(http, server, reqwest::Method::POST, path, data, query)
            .await?;
        let mut body: Value =
            serde_json::from_str(&text).map_err(|e| SourceError::msg(format!("解析失败: {e}")))?;
        Ok(body["data"].take())
    }
}

/// 取 ani-rss 包装体的 code。非 JSON / 无 code → None(对齐 Dart `code == null` 不判错)。
fn wrap_code(text: &str) -> Option<i64> {
    let body: Value = serde_json::from_str(text).ok()?;
    body["code"].as_i64()
}

/// 包装体 code → 错误。200 / 无 code / 非 JSON 均视为成功。
fn wrap_error(text: &str) -> Option<SourceError> {
    let body: Value = serde_json::from_str(text).ok()?;
    let code = body["code"].as_i64()?;
    if code == 200 {
        return None;
    }
    Some(SourceError {
        message: body["message"]
            .as_str()
            .unwrap_or("Ani-rss 请求失败")
            .to_string(),
        is_auth: code == 401 || code == 403,
    })
}

/// data → 整数。对齐 Dart `(unwrap(resp) as num?)?.toInt() ?? 0`:
/// Dart 的 num 同时含 int/double,故服务端回 8.5 也要截成 8(直接 as_i64 会漏成 0)。
fn as_int(v: &Value) -> i64 {
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)).unwrap_or(0)
}

/// data → 字符串。对齐 Dart `unwrap(resp)?.toString() ?? ''`:
/// JSON 字符串取原文(不带引号),null 取空串,其它类型取字面量。
fn as_text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// 展平 listAni 的 `weekList[].items[]`,按 id(空则回退 title)去重。
/// 对齐 Dart AniRssApi.listAni + AniModel.id/title 的取空语义。
fn flatten_week_list(data: &Value) -> Vec<Value> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for w in data["weekList"].as_array().into_iter().flatten() {
        for a in w["items"].as_array().into_iter().flatten() {
            let key = a["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or_else(|| a["title"].as_str())
                .unwrap_or("");
            if key.is_empty() || !seen.insert(key.to_string()) {
                continue;
            }
            out.push(a.clone());
        }
    }
    out
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
                let mut entries: Vec<SourceEntry> = self
                    .list_ani(http, server)
                    .await?
                    .into_iter()
                    .map(|a| SourceEntry {
                        id: format!("ani:{}", serde_json::to_string(&a).unwrap_or_default()),
                        name: a["title"].as_str().unwrap_or("未命名").to_string(),
                        is_dir: true,
                        is_video: false,
                        size: None,
                        thumb_url: a["image"]
                            .as_str()
                            .filter(|s| s.starts_with("http"))
                            .map(|s| s.to_string()),
                        raw: Some(a),
                    })
                    .collect();
                entries.sort_by(|x, y| x.name.cmp(&y.name));
                Ok(entries)
            }
            // 番剧层:用该 Ani 调 playList 列剧集文件
            Some(d) if d.starts_with("ani:") => {
                let ani: Value = serde_json::from_str(&d[4..])
                    .map_err(|e| SourceError::msg(format!("番剧数据解析失败: {e}")))?;
                let data = self.play_list(http, server, ani).await?;
                let empty = vec![];
                let list = data.as_array().unwrap_or(&empty);
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

// ============================ 管理接口 ============================
// 对齐 Dart `AniRssApi`(lib/core/sources/anirss/anirss_api.dart)全部端点。
//
// 为什么 Ani/Config 一律用 serde_json::Value 而不是类型化 struct:
// Dart 侧 `AniModel`/`ConfigModel` 本身就是**原始 Map 的薄包装**——注释写得很明白:
// Ani 有 55 字段、Config 有 ~123 字段且随服务端版本增删,`playList/addAni/setAni/
// setConfig` 都拿整个对象当 body 回传,存原 map 才能无损。若在此处收窄成 struct,
// 未覆盖的字段会在 setConfig/setAni 时被**静默丢弃**(服务端设置直接被抹)。
// 故 Value 进 Value 出既是最忠实的移植,也把字段表驱动的取舍留在 UI 层(与 Dart 同构)。
impl AniRssBackend {
    // ---- 浏览 / 详情 ----

    /// 订阅列表 → 展平 weekList[].items 去重。
    pub async fn list_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Vec<Value>, SourceError> {
        let data = self.call(http, server, "/api/listAni", Value::Null, &[]).await?;
        Ok(flatten_week_list(&data))
    }

    /// 某番剧的剧集文件列表(data=PlayItem[])。
    pub async fn play_list(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/playList", ani, &[]).await
    }

    /// TMDB 剧集组(进阶用)。
    pub async fn get_themoviedb_group(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/getThemoviedbGroup", ani, &[]).await
    }

    // ---- 下载进度 ----

    /// 下载中的种子进度(data=TorrentInfo[])。
    pub async fn torrents_infos(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/torrentsInfos", Value::Null, &[]).await
    }

    // ---- 订阅管理 ----

    /// BGM 搜索(添加订阅用)。
    pub async fn search_bgm(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        name: &str,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/searchBgm", Value::Null, &[("name", name.to_string())])
            .await
    }

    /// 由 BGM 条目 id 生成可添加的订阅 Ani。
    pub async fn get_ani_by_subject_id(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        id: &str,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/getAniBySubjectId", Value::Null, &[("id", id.to_string())])
            .await
    }

    pub async fn add_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/addAni", ani, &[]).await.map(drop)
    }

    pub async fn set_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/setAni", ani, &[]).await.map(drop)
    }

    /// 删除订阅。body 直接是 id 数组(不是对象),[delete_files] 决定是否连文件一起删。
    pub async fn delete_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ids: &[String],
        delete_files: bool,
    ) -> Result<(), SourceError> {
        self.call(
            http,
            server,
            "/api/deleteAni",
            json!(ids),
            &[("deleteFiles", delete_files.to_string())],
        )
        .await
        .map(drop)
    }

    pub async fn refresh_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        id: &str,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/refreshAni", json!({ "id": id }), &[])
            .await
            .map(drop)
    }

    pub async fn refresh_all(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/refreshAll", Value::Null, &[]).await.map(drop)
    }

    /// 重新拉取总集数。
    pub async fn update_total_episode_number(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ids: &[String],
        force: bool,
    ) -> Result<(), SourceError> {
        self.call(
            http,
            server,
            "/api/updateTotalEpisodeNumber",
            json!(ids),
            &[("force", force.to_string())],
        )
        .await
        .map(drop)
    }

    /// 批量启用/停用订阅。
    pub async fn batch_enable(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ids: &[String],
        value: bool,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/batchEnable", json!(ids), &[("value", value.to_string())])
            .await
            .map(drop)
    }

    // ---- 设置 / 关于 ----

    /// 服务端设置全量(~123 字段的原始 Map,原样交给 UI 表驱动读写)。
    pub async fn get_config(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/config", Value::Null, &[]).await
    }

    /// 回写设置。**必须回传 get_config 拿到的完整 map 改字段后的结果**,否则丢字段。
    pub async fn set_config(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        config: Value,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/setConfig", config, &[]).await.map(drop)
    }

    pub async fn about(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/about", Value::Null, &[]).await
    }

    // ---- 订阅预览 / 标题解析 / 刮削 / 下载位置 ----

    /// 预览订阅会匹配到的剧集(添加前确认)。返回服务端原始 Map。
    pub async fn preview_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/previewAni", ani, &[]).await
    }

    /// 获取该订阅的下载落地位置(服务端原始 Map)。
    pub async fn download_path(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/downloadPath", ani, &[]).await
    }

    /// 解析 BGM 标题(返回标题字符串)。
    pub async fn get_bgm_title(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<String, SourceError> {
        Ok(as_text(&self.call(http, server, "/api/getBgmTitle", ani, &[]).await?))
    }

    /// 解析 TMDB 标题(返回回填后的 Ani)。
    pub async fn get_themoviedb_name(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/getThemoviedbName", ani, &[]).await
    }

    /// 刷新封面(返回新封面地址)。
    pub async fn refresh_cover(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<String, SourceError> {
        Ok(as_text(&self.call(http, server, "/api/refreshCover", ani, &[]).await?))
    }

    /// 刮削单个订阅。
    pub async fn scrape(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
        force: bool,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/scrape", ani, &[("force", force.to_string())])
            .await
            .map(drop)
    }

    /// 批量刮削。
    pub async fn batch_scrape(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ids: &[String],
        force: bool,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/batchScrape", json!(ids), &[("force", force.to_string())])
            .await
            .map(drop)
    }

    // ---- BGM 评分 / 账号 ----

    /// 读取当前已记录的评分(0=未评)。
    pub async fn rate(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<i64, SourceError> {
        Ok(as_int(&self.call(http, server, "/api/rate", ani, &[]).await?))
    }

    /// 提交评分(1~10)。Ani 内带 score 字段。
    pub async fn set_rate(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        ani: Value,
    ) -> Result<i64, SourceError> {
        Ok(as_int(&self.call(http, server, "/api/setRate", ani, &[]).await?))
    }

    /// 当前 BGM 账号信息。
    pub async fn me_bgm(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/meBgm", Value::Null, &[]).await
    }

    // ---- 多搜索源(添加订阅):Mikan / AniBT / AnimeGarden ----

    /// Mikan 季度番表。[text] 关键词(空取全部),[season] 选定季度。
    /// 注意:season 缺省时 body 是 `{}` 而不是无 body(对齐 Dart `season?.toJson() ?? {}`)。
    pub async fn mikan(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        text: &str,
        season: Option<Value>,
    ) -> Result<Value, SourceError> {
        self.call(
            http,
            server,
            "/api/mikan",
            season.unwrap_or_else(|| json!({})),
            &[("text", text.to_string())],
        )
        .await
    }

    /// 某 Mikan 番剧的字幕组列表([url] = MikanInfo.url)。
    pub async fn mikan_group(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        url: &str,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/mikanGroup", Value::Null, &[("url", url.to_string())]).await
    }

    /// AniBT 番表。
    pub async fn ani_bt(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/aniBT", Value::Null, &[]).await
    }

    /// 某 AniBT 番剧的字幕组列表。
    pub async fn ani_bt_group(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        bgm_id: &str,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/aniBTGroup", Value::Null, &[("bgmId", bgm_id.to_string())])
            .await
    }

    /// AnimeGarden 番表(按星期分组)。
    pub async fn anime_garden_list(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/animeGardenList", Value::Null, &[]).await
    }

    /// 某 AnimeGarden 番剧的字幕组列表。
    pub async fn anime_garden_group(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        bgm_id: &str,
    ) -> Result<Value, SourceError> {
        self.call(
            http,
            server,
            "/api/animeGardenGroup",
            Value::Null,
            &[("bgmId", bgm_id.to_string())],
        )
        .await
    }

    /// 由 RSS 生成订阅 Ani(之后 add_ani 添加)。[kind] = mikan/ani-bt/anime-garden/other。
    pub async fn rss_to_ani(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        url: &str,
        kind: &str,
        bgm_url: Option<&str>,
        subgroup: &str,
        enable: bool,
    ) -> Result<Value, SourceError> {
        let mut body = json!({
            "url": url,
            "type": kind,
            "subgroup": subgroup,
            "enable": enable,
        });
        // 对齐 Dart 的 `if (bgmUrl != null)`:为空时整个 key 不出现。
        if let Some(b) = bgm_url {
            body["bgmUrl"] = json!(b);
        }
        self.call(http, server, "/api/rssToAni", body, &[]).await
    }

    // ---- 播放:内封/外挂字幕 ----

    /// 获取某文件的字幕([filename] = PlayItem.filename 的 base64,**勿再编码**)。
    pub async fn get_subtitles(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        filename: &str,
    ) -> Result<Value, SourceError> {
        self.call(
            http,
            server,
            "/api/getSubtitles",
            Value::Null,
            &[("filename", filename.to_string())],
        )
        .await
    }

    // ---- 诊断 / 日志 / 维护 ----

    /// 运行日志(data=LogEntry[])。
    pub async fn logs(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/logs", Value::Null, &[]).await
    }

    /// 下载日志(GET,纯文本)。服务端可能直接吐文本,也可能包一层 {data}。
    pub async fn download_logs(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<String, SourceError> {
        let text = self
            .request_text(http, server, reqwest::Method::GET, "/api/downloadLogs", Value::Null, &[])
            .await?;
        match serde_json::from_str::<Value>(&text) {
            Ok(v) if !v["data"].is_null() => Ok(as_text(&v["data"])),
            _ => Ok(text),
        }
    }

    pub async fn clear_logs(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/clearLogs", Value::Null, &[]).await.map(drop)
    }

    pub async fn clear_cache(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/clearCache", Value::Null, &[]).await.map(drop)
    }

    /// 存活测试(GET /api/ping)。失败返回 Err。
    pub async fn ping(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(), SourceError> {
        self.request_text(http, server, reqwest::Method::GET, "/api/ping", Value::Null, &[])
            .await
            .map(drop)
    }

    /// 下载器登录测试(用传入的服务端配置)。
    pub async fn download_login_test(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        config: Value,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/downloadLoginTest", config, &[]).await.map(drop)
    }

    /// 代理测试,返回 {status, time(ms)}。
    pub async fn test_proxy(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        url: &str,
        config: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/testProxy", config, &[("url", url.to_string())]).await
    }

    /// IP 白名单测试。
    pub async fn test_ip_whitelist(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/testIpWhitelist", Value::Null, &[]).await.map(drop)
    }

    /// 触发服务端自更新(升级 ani-rss 本体)。
    pub async fn server_update(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/update", Value::Null, &[]).await.map(drop)
    }

    /// 停止/重启服务([status] 由服务端定义,0 通常为停止)。
    pub async fn stop(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        status: i64,
    ) -> Result<(), SourceError> {
        self.call(http, server, "/api/stop", Value::Null, &[("status", status.to_string())])
            .await
            .map(drop)
    }

    /// 最新一条通知配置(用于「测试通知」预填等)。
    pub async fn new_notification(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/newNotification", Value::Null, &[]).await
    }

    /// Emby 媒体库列表(配置 Emby 通知时挑库用)。body 为通知配置 Map。
    pub async fn get_emby_views(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        notification_config: Value,
    ) -> Result<Value, SourceError> {
        self.call(http, server, "/api/getEmbyViews", notification_config, &[]).await
    }

    /// 导出设置的可下载 URL(带登录令牌查询参数;交给浏览器/系统打开)。
    pub async fn export_config_url(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<String, SourceError> {
        let token = self.ensure_token(http, server, false).await?;
        Ok(build_export_config_url(&server.base_url, &token))
    }

    /// 导入设置(上传配置文件字节)。对齐 Dart FormData{file: MultipartFile}。
    /// reqwest 未开 multipart feature(见 Cargo.toml),而这里只有一个固定字段,
    /// 手工拼 multipart/form-data 比加依赖便宜。
    /// ponytail: 不做 401 自动重登(一次性用户动作,失效直接抛 auth 让 UI 走重登)。
    pub async fn import_config(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        bytes: &[u8],
        filename: &str,
    ) -> Result<(), SourceError> {
        let token = self.ensure_token(http, server, false).await?;
        let base = normalize_base_url(&server.base_url);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let boundary = format!("----LinPlayerBoundary{nanos:x}");
        // 文件名里的引号会破坏 Content-Disposition 的分隔,直接剔除。
        let safe_name = filename.replace(['"', '\r', '\n'], "");
        let mut body = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{safe_name}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        )
        .into_bytes();
        body.extend_from_slice(bytes);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        let resp = http
            .post(format!("{base}/api/importConfig"))
            .header("Authorization", &token)
            .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
            .body(body)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("请求失败: {e}")))?;
        let text = resp
            .text()
            .await
            .map_err(|e| SourceError::msg(format!("读取响应失败: {e}")))?;
        match wrap_error(&text) {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    // ---- 图片代理 ----

    /// 经 ani-rss 服务端代理/缓存取图(TMDB 相对路径等)。需 token → async。
    pub async fn proxy_image_url(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        img_url: &str,
    ) -> Result<String, SourceError> {
        let token = self.ensure_token(http, server, false).await?;
        Ok(build_proxy_image_url(&server.base_url, img_url, &token))
    }
}

/// 同步构造 proxyImage URL(已有 token 时用)。对齐 Dart AniRssApi.buildProxyImageUrl。
///
/// 服务端 `ProxyImageController` 对 `imgUrl` 做 **Base64 解码**,故须先 base64 编码原始
/// 图片地址;鉴权用 `s=<登录令牌>` 走 Form 鉴权(URL 无法带 Authorization 头)。
pub fn build_proxy_image_url(base_url: &str, img_url: &str, token: &str) -> String {
    let base = normalize_base_url(base_url);
    let encoded = base64::engine::general_purpose::STANDARD.encode(img_url.as_bytes());
    format!(
        "{base}/api/proxyImage?imgUrl={}&s={}",
        urlencoding::encode(&encoded),
        urlencoding::encode(token)
    )
}

/// 同步构造 exportConfig 下载 URL。对齐 Dart AniRssApi.exportConfigUrl。
pub fn build_export_config_url(base_url: &str, token: &str) -> String {
    format!(
        "{}/api/exportConfig?s={}",
        normalize_base_url(base_url),
        urlencoding::encode(token)
    )
}

/// 从 previewAni 的返回里提取条目列表。对齐 Dart AniRssApi.itemsOf:
/// 服务端用哪个 key 装 List 不定,取第一个「元素是对象的非空数组」。
/// 注意:serde_json 默认 Map 是有序 BTreeMap(按 key 字典序),Dart Map 按插入序;
/// 若 data 里同时存在多个「对象数组」,选中的那个可能与 Dart 不同(实测只有一个)。
pub fn preview_items(preview: &Value) -> Vec<Value> {
    let Some(obj) = preview.as_object() else {
        return vec![];
    };
    for v in obj.values() {
        if let Some(arr) = v.as_array() {
            if arr.first().map(Value::is_object).unwrap_or(false) {
                return arr.iter().filter(|e| e.is_object()).cloned().collect();
            }
        }
    }
    vec![]
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// 起一个只应答一次的假 ani-rss:收下请求原文,回固定响应。
    /// 返回 (base_url, 请求原文接收端)——用它断言我们构造的请求长什么样。
    async fn fake_server(
        status_line: &'static str,
        content_type: &'static str,
        body: &'static str,
    ) -> (String, tokio::sync::oneshot::Receiver<String>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let req = read_request(&mut s).await;
            let resp = format!(
                "{status_line}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            s.write_all(resp.as_bytes()).await.unwrap();
            s.flush().await.unwrap();
            let _ = tx.send(req);
        });
        (format!("http://127.0.0.1:{port}"), rx)
    }

    /// 读到完整请求(头 + Content-Length 指定的 body),避免 header/body 分包导致漏读。
    async fn read_request(s: &mut tokio::net::TcpStream) -> String {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            let n = s.read(&mut tmp).await.unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
            let text = String::from_utf8_lossy(&buf).to_string();
            if let Some(h) = text.find("\r\n\r\n") {
                let len: usize = text[..h]
                    .lines()
                    .find_map(|l| {
                        let low = l.to_ascii_lowercase();
                        low.strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                    })
                    .unwrap_or(0);
                if buf.len() >= h + 4 + len {
                    return text;
                }
            }
        }
        String::from_utf8_lossy(&buf).to_string()
    }

    /// 预置 token 的 server,免掉测试里的登录往返。
    fn server_with_token(base: String) -> SourceServer {
        SourceServer {
            id: "s1".into(),
            base_url: base,
            token: Some("tok123".into()),
            ..Default::default()
        }
    }

    // ---------- 响应解析 ----------

    #[test]
    fn flattens_and_dedups_week_list() {
        // 形状取自 Dart AniRssApi.listAni:data.weekList[].items[] 是 Ani。
        let data = json!({
            "weekList": [
                { "week": 1, "items": [
                    { "id": "a1", "title": "番A", "image": "https://x/a.jpg" },
                    { "id": "a2", "title": "番B" }
                ]},
                { "week": 2, "items": [
                    { "id": "a1", "title": "番A(重复,同一部跨天出现)" },
                    { "id": "", "title": "无 id 回退标题" },
                    { "id": "", "title": "无 id 回退标题" },
                    { "title": "只有标题" }
                ]}
            ]
        });
        let out = flatten_week_list(&data);
        let titles: Vec<&str> = out.iter().map(|a| a["title"].as_str().unwrap()).collect();
        // a1 只留第一次;id 为空时按 title 去重(对齐 Dart `id.isNotEmpty ? id : title`)。
        assert_eq!(titles, vec!["番A", "番B", "无 id 回退标题", "只有标题"]);
    }

    #[test]
    fn flatten_tolerates_missing_fields() {
        assert!(flatten_week_list(&json!({})).is_empty());
        assert!(flatten_week_list(&json!({ "weekList": [] })).is_empty());
        assert!(flatten_week_list(&json!({ "weekList": [{ "items": [] }] })).is_empty());
        // 全是空 key 的条目一个都不留。
        assert!(flatten_week_list(&json!({ "weekList": [{ "items": [{ "id": "" }] }] })).is_empty());
    }

    #[test]
    fn wrap_error_follows_dart_code_semantics() {
        assert!(wrap_error(r#"{"code":200,"data":[]}"#).is_none());
        // 无 code / 非 JSON → 不判错(downloadLogs 纯文本走这条)。
        assert!(wrap_error(r#"{"data":1}"#).is_none());
        assert!(wrap_error("2026-07-15 INFO 日志正文").is_none());
        let e = wrap_error(r#"{"code":403,"message":"登录已失效"}"#).unwrap();
        assert_eq!(e.message, "登录已失效");
        assert!(e.is_auth); // 403 → UI 引导重登
        let e = wrap_error(r#"{"code":500,"message":"下载器连接失败"}"#).unwrap();
        assert!(!e.is_auth);
        assert_eq!(wrap_code(r#"{"code":401}"#), Some(401));
        assert_eq!(wrap_code("plain text"), None);
    }

    #[test]
    fn as_text_matches_dart_tostring() {
        assert_eq!(as_text(&json!("剧场版 标题")), "剧场版 标题"); // 不带引号
        assert_eq!(as_text(&Value::Null), "");
        assert_eq!(as_text(&json!(7)), "7");
    }

    #[test]
    fn as_int_matches_dart_num_toint() {
        assert_eq!(as_int(&json!(8)), 8);
        // Dart 的 `as num?` 收 double,`toInt()` 截断;直接 as_i64 会漏成 0(评分丢失)。
        assert_eq!(as_int(&json!(8.5)), 8);
        assert_eq!(as_int(&Value::Null), 0); // 未评分
        assert_eq!(as_int(&json!("x")), 0);
    }

    #[test]
    fn preview_items_picks_the_object_array() {
        // previewAni 的 data 用哪个 key 装 List 不定,故按形状找。
        let preview = json!({
            "count": 2,
            "message": "ok",
            "tags": ["1080P", "简日双语"],
            "items": [
                { "title": "[Sub] 番A - 01 [1080P].mkv", "episode": 1 },
                { "title": "[Sub] 番A - 02 [1080P].mkv", "episode": 2 }
            ]
        });
        let items = preview_items(&preview);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["episode"], json!(1));
        // 纯字符串数组(tags)不能被误选。
        assert!(preview_items(&json!({ "tags": ["a"] })).is_empty());
        assert!(preview_items(&json!({ "items": [] })).is_empty());
        assert!(preview_items(&json!([])).is_empty());
    }

    // ---------- URL 构造 ----------

    #[test]
    fn builds_proxy_image_url() {
        let u = build_proxy_image_url("http://nas:7789/", "https://image.tmdb.org/t/p/w500/x.jpg", "tok+/=");
        // imgUrl 必须是 base64 后再 URL 转义(服务端 ProxyImageController 会 base64 解码)。
        let b64 = base64::engine::general_purpose::STANDARD.encode("https://image.tmdb.org/t/p/w500/x.jpg");
        assert!(u.starts_with("http://nas:7789/api/proxyImage?imgUrl="));
        assert!(u.contains(&urlencoding::encode(&b64).to_string()));
        // token 里的 +/= 必须转义,否则服务端收到的 s 会被截断。
        assert!(u.ends_with("&s=tok%2B%2F%3D"));
    }

    #[test]
    fn builds_export_config_url() {
        assert_eq!(
            build_export_config_url("nas:7789", "a b"),
            "https://nas:7789/api/exportConfig?s=a%20b"
        );
    }

    // ---------- 请求构造(打真实 socket,断言线上原文)----------

    #[tokio::test]
    async fn delete_ani_sends_id_array_body_and_bool_query() {
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "application/json", r#"{"code":200}"#).await;
        let b = AniRssBackend::new();
        b.delete_ani(&reqwest::Client::new(), &server_with_token(base), &["id1".into(), "id2".into()], true)
            .await
            .unwrap();
        let req = rx.await.unwrap();
        // Dart: authed('/api/deleteAni', data: ids, queryParameters: {'deleteFiles': true})
        assert!(req.starts_with("POST /api/deleteAni?deleteFiles=true HTTP/1.1"), "{req}");
        assert!(req.contains("authorization: tok123"), "{req}");
        assert!(req.ends_with(r#"["id1","id2"]"#), "{req}"); // body 是裸数组,不是 {ids:[...]}
    }

    #[tokio::test]
    async fn batch_enable_sends_false_as_string() {
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "application/json", r#"{"code":200}"#).await;
        let b = AniRssBackend::new();
        b.batch_enable(&reqwest::Client::new(), &server_with_token(base), &["x".into()], false)
            .await
            .unwrap();
        let req = rx.await.unwrap();
        assert!(req.starts_with("POST /api/batchEnable?value=false HTTP/1.1"), "{req}");
    }

    #[tokio::test]
    async fn refresh_all_sends_no_body_and_no_query_marker() {
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "application/json", r#"{"code":200}"#).await;
        let b = AniRssBackend::new();
        b.refresh_all(&reqwest::Client::new(), &server_with_token(base)).await.unwrap();
        let req = rx.await.unwrap();
        // 无 query 时不能拼出裸 "?"。
        assert!(req.starts_with("POST /api/refreshAll HTTP/1.1"), "{req}");
        assert!(!req.contains("content-length: "), "无 body 不该带 content-length: {req}");
    }

    #[tokio::test]
    async fn search_bgm_escapes_query_and_parses_data() {
        let body = r#"{"code":200,"message":"","data":[{"id":123,"name":"チェンソーマン","nameCn":"电锯人"}]}"#;
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "application/json", body).await;
        let b = AniRssBackend::new();
        let data = b
            .search_bgm(&reqwest::Client::new(), &server_with_token(base), "电锯人 第二季")
            .await
            .unwrap();
        let req = rx.await.unwrap();
        // 中文/空格必须转义进 query。
        assert!(req.starts_with("POST /api/searchBgm?name=%E7%94%B5%E9%94%AF%E4%BA%BA+%E7%AC%AC%E4%BA%8C%E5%AD%A3 HTTP/1.1"), "{req}");
        // call() 剥掉包装体只给 data。
        assert_eq!(data[0]["nameCn"], json!("电锯人"));
    }

    #[tokio::test]
    async fn get_config_returns_raw_map_untouched() {
        // Config ~123 字段:断言未知字段原样保留(setConfig 回传才不丢)。
        let body = r#"{"code":200,"data":{"version":"1.2.3","sleep":5,"未来新增字段":true}}"#;
        let (base, _rx) = fake_server("HTTP/1.1 200 OK", "application/json", body).await;
        let b = AniRssBackend::new();
        let cfg = b.get_config(&reqwest::Client::new(), &server_with_token(base)).await.unwrap();
        assert_eq!(cfg["version"], json!("1.2.3"));
        assert_eq!(cfg["未来新增字段"], json!(true));
    }

    #[tokio::test]
    async fn get_bgm_title_unwraps_plain_string_data() {
        let (base, _rx) =
            fake_server("HTTP/1.1 200 OK", "application/json", r#"{"code":200,"data":"孤独摇滚!"}"#).await;
        let b = AniRssBackend::new();
        let t = b
            .get_bgm_title(&reqwest::Client::new(), &server_with_token(base), json!({"id": "a1"}))
            .await
            .unwrap();
        assert_eq!(t, "孤独摇滚!");
    }

    #[tokio::test]
    async fn download_logs_passes_through_plain_text_via_get() {
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "text/plain", "2026-07-15 INFO 启动完成\n").await;
        let b = AniRssBackend::new();
        let logs = b.download_logs(&reqwest::Client::new(), &server_with_token(base)).await.unwrap();
        let req = rx.await.unwrap();
        assert!(req.starts_with("GET /api/downloadLogs HTTP/1.1"), "{req}");
        // 非 JSON 不判错、不解包,原样返回(对齐 Dart `body is String → return body`)。
        assert_eq!(logs, "2026-07-15 INFO 启动完成\n");
    }

    #[tokio::test]
    async fn rss_to_ani_omits_bgm_url_when_absent() {
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "application/json", r#"{"code":200,"data":{}}"#).await;
        let b = AniRssBackend::new();
        b.rss_to_ani(&reqwest::Client::new(), &server_with_token(base), "https://mikan/rss", "mikan", None, "桜都字幕组", true)
            .await
            .unwrap();
        let req = rx.await.unwrap();
        assert!(!req.contains("bgmUrl"), "bgmUrl 为空时不应出现在 body: {req}");
        assert!(req.contains(r#""type":"mikan""#), "{req}");
        assert!(req.contains(r#""enable":true"#), "{req}");
    }

    #[tokio::test]
    async fn import_config_builds_multipart_body() {
        let (base, rx) = fake_server("HTTP/1.1 200 OK", "application/json", r#"{"code":200}"#).await;
        let b = AniRssBackend::new();
        b.import_config(&reqwest::Client::new(), &server_with_token(base), b"{\"sleep\":5}", "config.json")
            .await
            .unwrap();
        let req = rx.await.unwrap();
        assert!(req.starts_with("POST /api/importConfig HTTP/1.1"), "{req}");
        assert!(req.contains("content-type: multipart/form-data; boundary=----LinPlayerBoundary"), "{req}");
        assert!(req.contains(r#"Content-Disposition: form-data; name="file"; filename="config.json""#), "{req}");
        assert!(req.contains(r#"{"sleep":5}"#), "{req}");
    }

    #[tokio::test]
    async fn auth_failure_surfaces_as_auth_error() {
        // 没有账密 → 401 后无法重登,应把 auth 错误抛给 UI(而不是死循环重试)。
        let (base, _rx) = fake_server(
            "HTTP/1.1 200 OK",
            "application/json",
            r#"{"code":403,"message":"登录已失效"}"#,
        )
        .await;
        let b = AniRssBackend::new();
        let e = b.refresh_all(&reqwest::Client::new(), &server_with_token(base)).await.unwrap_err();
        assert!(e.is_auth, "{}", e.message);
    }

    #[test]
    fn cache_and_clear_token() {
        let b = AniRssBackend::new();
        let s = SourceServer { id: "s1".into(), ..Default::default() };
        assert!(b.cached_token(&s).is_none());
        b.cache_token("s1", "t".into());
        assert_eq!(b.cached_token(&s).as_deref(), Some("t"));
        b.clear_token("s1");
        assert!(b.cached_token(&s).is_none());
    }
}
