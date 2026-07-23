// 夸克网盘后端(Cookie / 网页 API)。对齐 Dart quark_backend.dart 的 Cookie 模式。
// 鉴权:Cookie 头 + Referer + 客户端 UA;固定云端 API(不用 server.base_url)。
// 列目录 /file/sort 分页;取流优先 /file/v2/play/project(转码多档),回退 /file/download 原文件直链。
// 夸克经 Set-Cookie 轮换 __puus/__pus → 实时回写内存 Cookie。
// ponytail: TV(扫码)模式(refresh_token/device_id + 开放 API)未接;走 Cookie 模式,扫码留后续增量。
use super::quark_tv;
use super::{
    is_video_file_name, MediaSourceBackend, PlayQuality, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

const API: &str = "https://drive.quark.cn/1/clouddrive";
const REFERER: &str = "https://pan.quark.cn";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch";
const PAGE_SIZE: usize = 100;
const MAX_PAGES: usize = 200;

#[derive(Default)]
pub struct QuarkBackend {
    // 含轮换后 __puus 的最新 Cookie(serverId -> cookie)。
    cookie_cache: Mutex<HashMap<String, String>>,
    // TV(扫码)模式:access_token 缓存(serverId -> access_token)。
    tv_access: Mutex<HashMap<String, String>>,
    // TV 模式刷新后轮换出的新 refresh_token,等宿主层取走落盘(serverId -> refresh_token)。
    tv_rotated: Mutex<HashMap<String, String>>,
    // 自上次取走以来 refresh_token 变过的 serverId。没有它,每个请求后都会重写一次配置文件。
    tv_dirty: Mutex<std::collections::HashSet<String>>,
}

fn replace_cookie(cookie: &str, key: &str, value: &str) -> String {
    let mut parts: Vec<String> = cookie
        .split(';')
        .map(|e| e.trim().to_string())
        .filter(|e| !e.is_empty())
        .collect();
    let mut found = false;
    for p in parts.iter_mut() {
        if p.starts_with(&format!("{key}=")) {
            *p = format!("{key}={value}");
            found = true;
        }
    }
    if !found {
        parts.push(format!("{key}={value}"));
    }
    parts.join("; ")
}

/// 夸克转码档位 → 展示名 + 排序权重(越大越清晰)。
fn quality_meta(res: &str) -> (String, i32) {
    match res.to_lowercase().as_str() {
        "low" => ("流畅".into(), 1),
        "normal" => ("标清".into(), 2),
        "high" => ("高清".into(), 3),
        "super" => ("超清".into(), 4),
        "2k" => ("2K".into(), 5),
        "4k" => ("4K".into(), 6),
        "dolby_vision" | "dolby" => ("杜比视界".into(), 7),
        "origin" | "original" | "originalsource" => ("原画".into(), 8),
        _ => (if res.is_empty() { "默认".into() } else { res.to_string() }, 0),
    }
}

/// 转码各档归一为 PlayQuality(按清晰度降序)并按 quality_id 选档,缺省选最高档。
/// infos = [(resolution, url)]。无可用档返回 None(上层回退原文件直链)。
fn pick_quality(
    infos: &[(String, String)],
    quality_id: Option<&str>,
) -> Option<(String, Vec<PlayQuality>, String)> {
    if infos.is_empty() {
        return None;
    }
    let mut cands: Vec<(PlayQuality, String)> = infos
        .iter()
        .map(|(res, url)| {
            let (label, rank) = quality_meta(res);
            let id = if res.is_empty() { label.clone() } else { res.clone() };
            (PlayQuality { id, label, rank }, url.clone())
        })
        .collect();
    cands.sort_by(|a, b| b.0.rank.cmp(&a.0.rank));
    let chosen = match quality_id {
        Some(qid) => cands
            .iter()
            .find(|c| c.0.id == qid)
            .cloned()
            .unwrap_or_else(|| cands[0].clone()),
        None => cands[0].clone(),
    };
    let qualities = cands.into_iter().map(|c| c.0).collect();
    Some((chosen.1, qualities, chosen.0.id))
}

/// 一行 file 记录 → SourceEntry。列目录与搜索共用 —— 两处各写一份的话,
/// 字段判定迟早分叉(搜索结果里目录变文件之类),且只有真机点进去才发现。
fn file_to_entry(f: &Value) -> SourceEntry {
    let is_dir = f["dir"].as_bool() == Some(true) || f["file"].as_bool() == Some(false);
    let name = f["file_name"].as_str().unwrap_or("").to_string();
    let is_video = !is_dir && (f["category"].as_i64() == Some(1) || is_video_file_name(&name));
    let thumb = f["thumbnail"]
        .as_str()
        .or_else(|| f["big_thumbnail"].as_str())
        .filter(|s| s.starts_with("http"))
        .map(|s| s.to_string());
    SourceEntry {
        id: f["fid"].as_str().unwrap_or("").to_string(),
        name,
        is_dir,
        is_video,
        size: f["size"].as_i64(),
        thumb_url: thumb,
        raw: None,
    }
}

impl QuarkBackend {
    pub fn new() -> Self {
        Self::default()
    }

    fn cookie_of(&self, server: &SourceServer) -> String {
        self.cookie_cache
            .lock()
            .unwrap()
            .get(&server.id)
            .cloned()
            .or_else(|| server.token.clone())
            .unwrap_or_default()
    }

    fn absorb_rotated_cookie(&self, server: &SourceServer, set_cookies: &[String]) {
        if set_cookies.is_empty() {
            return;
        }
        let mut cookie = self.cookie_of(server);
        for sc in set_cookies {
            let first = sc.split(';').next().unwrap_or("").trim();
            if let Some((k, val)) = first.split_once('=') {
                if k == "__puus" || k == "__pus" {
                    cookie = replace_cookie(&cookie, k, val);
                }
            }
        }
        self.cookie_cache
            .lock()
            .unwrap()
            .insert(server.id.clone(), cookie);
    }

    /// 发请求:附 pr/fr 查询 + Cookie/Referer/UA;吸收轮换 Cookie;校验 data.status==200。
    async fn request(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        post_body: Option<Value>,
        extra_query: &[(&str, String)],
    ) -> Result<Value, SourceError> {
        let cookie = self.cookie_of(server);
        if cookie.is_empty() {
            return Err(SourceError::auth("夸克未登录，请重新添加 Cookie"));
        }
        let url = format!("{API}{path}");
        let mut query: Vec<(&str, String)> = vec![("pr", "ucpro".into()), ("fr", "pc".into())];
        query.extend(extra_query.iter().map(|(k, v)| (*k, v.clone())));

        let mut req = match &post_body {
            Some(_) => http.post(&url),
            None => http.get(&url),
        }
        .query(&query)
        .header("Cookie", &cookie)
        .header("Referer", REFERER)
        .header("User-Agent", UA)
        .header("Accept", "application/json, text/plain, */*");
        if let Some(b) = &post_body {
            req = req.header("Content-Type", "application/json").json(b);
        }

        let resp = req
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("夸克请求失败: {e}")))?;
        let set_cookies: Vec<String> = resp
            .headers()
            .get_all(reqwest::header::SET_COOKIE)
            .iter()
            .filter_map(|v| v.to_str().ok().map(|s| s.to_string()))
            .collect();
        self.absorb_rotated_cookie(server, &set_cookies);
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("夸克解析失败: {e}")))?;
        if v["status"].as_i64() == Some(200) {
            return Ok(v);
        }
        let code = v["code"].as_i64();
        let is_auth = v["status"].as_i64() == Some(400)
            && matches!(code, Some(31001) | Some(31002) | Some(31003) | Some(31023));
        Err(SourceError {
            message: v["message"]
                .as_str()
                .unwrap_or("夸克请求失败")
                .to_string(),
            is_auth,
        })
    }

    /// TV(扫码)模式:凭据里存了 refresh_token 即是。否则走 Cookie 网页 API。
    fn is_tv(&self, server: &SourceServer) -> bool {
        server
            .extra
            .get("refresh_token")
            .map(|t| !t.is_empty())
            .unwrap_or(false)
    }

    /// 取 TV 模式 (access_token, device_id);force 或缓存空时用 refresh_token 刷新。
    /// 轮换出的新 refresh_token 记进 tv_rotated,由宿主层经 take_rotated_credentials 落盘 ——
    /// 不落盘的话会话内没事,一重启就拿着旧值去刷,表现为"扫过码了还要再扫"。
    async fn tv_auth(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        force: bool,
    ) -> Result<(String, String), SourceError> {
        let device_id = server.extra.get("device_id").cloned().unwrap_or_default();
        // 内存里轮换后的新值优先 —— 存盘那份刷过一次就可能失效了。
        let refresh = self
            .tv_rotated
            .lock()
            .unwrap()
            .get(&server.id)
            .cloned()
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| server.extra.get("refresh_token").cloned().unwrap_or_default());
        if device_id.is_empty() || refresh.is_empty() {
            return Err(SourceError::auth("夸克未扫码登录，请重新扫码"));
        }
        if !force {
            if let Some(a) = self.tv_access.lock().unwrap().get(&server.id).cloned() {
                if !a.is_empty() {
                    return Ok((a, device_id));
                }
            }
        }
        let (access, new_refresh) =
            quark_tv::exchange_token(http, &device_id, &refresh, true).await?;
        self.tv_access
            .lock()
            .unwrap()
            .insert(server.id.clone(), access.clone());
        if !new_refresh.is_empty() && new_refresh != refresh {
            self.tv_rotated
                .lock()
                .unwrap()
                .insert(server.id.clone(), new_refresh);
            self.tv_dirty.lock().unwrap().insert(server.id.clone());
        }
        Ok((access, device_id))
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for QuarkBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::quark()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let fid = match dir_id {
            Some(d) if !d.is_empty() => d,
            _ => "0",
        };
        // TV(扫码)模式走开放 API;失效自动刷新重试一次。
        if self.is_tv(server) {
            let (access, device_id) = self.tv_auth(http, server, false).await?;
            return match quark_tv::list_files(http, &device_id, &access, fid).await {
                Err(e) if e.is_auth => {
                    let (access, device_id) = self.tv_auth(http, server, true).await?;
                    quark_tv::list_files(http, &device_id, &access, fid).await
                }
                other => other,
            };
        }
        let mut entries = Vec::new();
        let mut page = 1;
        while page <= MAX_PAGES {
            let v = self
                .request(
                    http,
                    server,
                    "/file/sort",
                    None,
                    &[
                        ("pdir_fid", fid.to_string()),
                        ("_page", page.to_string()),
                        ("_size", PAGE_SIZE.to_string()),
                        ("_fetch_total", "1".into()),
                        ("fetch_all_file", "1".into()),
                        ("fetch_risk_file_name", "1".into()),
                        ("_sort", "file_type:asc,updated_at:desc".into()),
                    ],
                )
                .await?;
            let empty = vec![];
            let list = v["data"]["list"].as_array().unwrap_or(&empty);
            let count = list.len();
            entries.extend(list.iter().map(file_to_entry));
            if count < PAGE_SIZE {
                break;
            }
            page += 1;
        }
        Ok(entries)
    }

    /// 源端搜索(Cookie 模式)。此前夸克走 trait 默认的 unsupported,UI 只能在当前目录本地过滤 ——
    /// 网盘里翻几层找一部片子时那等于没有搜索。
    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        // 扫码(TV)模式的开放 API 没有搜索端点,如实返回 unsupported 让 UI 退回本地过滤,
        // 而不是编一个端点出来静默返回空列表。
        if self.is_tv(server) {
            return Err(SourceError::unsupported());
        }
        let mut entries = Vec::new();
        let mut page = 1;
        while page <= MAX_PAGES {
            let v = self
                .request(
                    http,
                    server,
                    "/file/search",
                    None,
                    &[
                        ("q", query.to_string()),
                        ("_page", page.to_string()),
                        ("_size", PAGE_SIZE.to_string()),
                        ("_fetch_total", "1".into()),
                        ("_sort", "file_type:asc,updated_at:desc".into()),
                    ],
                )
                .await?;
            let empty = vec![];
            let list = v["data"]["list"].as_array().unwrap_or(&empty);
            let count = list.len();
            entries.extend(list.iter().map(file_to_entry));
            if count < PAGE_SIZE {
                break;
            }
            page += 1;
        }
        Ok(entries)
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let fid = &entry.id;

        // TV(扫码)模式:开放 API 取转码各档,失败回退原文件直链(URL 已签名,无需 headers)。
        if self.is_tv(server) {
            let (access, device_id) = self.tv_auth(http, server, false).await?;
            if let Ok(infos) = quark_tv::streaming_infos(http, &device_id, &access, fid).await {
                if let Some((url, qualities, selected)) = pick_quality(&infos, quality_id) {
                    return Ok(ResolvedPlay {
                        url,
                        title: entry.name.clone(),
                        http_headers: HashMap::new(),
                        user_agent_override: None,
                        subtitles: vec![],
                        qualities,
                        selected_quality_id: Some(selected),
                    });
                }
            }
            let url = quark_tv::download_link(http, &device_id, &access, fid).await?;
            return Ok(ResolvedPlay::simple(url, entry.name.clone(), HashMap::new()));
        }

        let cookie = self.cookie_of(server);
        let mut headers = HashMap::new();
        headers.insert("Cookie".to_string(), cookie);
        headers.insert("Referer".to_string(), REFERER.to_string());
        headers.insert("User-Agent".to_string(), UA.to_string());

        // 优先转码自适应播放地址(多档,默认最高)。
        if let Ok(v) = self
            .request(
                http,
                server,
                "/file/v2/play/project",
                Some(json!({
                    "fid": fid,
                    "resolutions": "low,normal,high,super,2k,4k",
                    "supports": "fmp4_av,m3u8,dolby_vision",
                })),
                &[],
            )
            .await
        {
            let empty = vec![];
            let infos: Vec<(String, String)> = v["data"]["video_list"]
                .as_array()
                .unwrap_or(&empty)
                .iter()
                .filter_map(|vi| {
                    let url = vi["video_info"]["url"].as_str().unwrap_or("");
                    if url.is_empty() {
                        None
                    } else {
                        Some((vi["resolution"].as_str().unwrap_or("").to_string(), url.to_string()))
                    }
                })
                .collect();
            if let Some((url, qualities, selected)) = pick_quality(&infos, quality_id) {
                return Ok(ResolvedPlay {
                    url,
                    title: entry.name.clone(),
                    http_headers: headers,
                    user_agent_override: Some(UA.to_string()),
                    subtitles: vec![],
                    qualities,
                    selected_quality_id: Some(selected),
                });
            }
        }

        // 回退原文件直链。
        let v = self
            .request(http, server, "/file/download", Some(json!({ "fids": [fid] })), &[])
            .await?;
        let url = v["data"][0]["download_url"].as_str().unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("未获取到下载地址"));
        }
        Ok(ResolvedPlay {
            url: url.to_string(),
            title: entry.name.clone(),
            http_headers: headers,
            user_agent_override: Some(UA.to_string()),
            subtitles: vec![],
            qualities: vec![],
            selected_quality_id: None,
        })
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        if !self.tv_dirty.lock().unwrap().remove(server_id) {
            return None;
        }
        let t = self.tv_rotated.lock().unwrap().get(server_id).cloned()?;
        Some(HashMap::from([("refresh_token".to_string(), t)]))
    }
}
