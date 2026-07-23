// 百度网盘后端。**双路线**,按用户填了哪种凭据自动分派:
//
//   A. 令牌路线(推荐):oplist 拿 access_token → 走官方开放平台 /rest/2.0/xpan/*。
//      有文档、不怕改版,取直链走 filemetas?dlink=1。
//   B. Cookie 路线(兜底):BDUSS/STOKEN 打网页版 /api/*。令牌服务挂了还能用。
//
// ★ 两条路线的**取直链**能力不对等,这是百度自身的限制,不是实现偷懒:
//   - A 路线 dlink 有官方文档,稳。
//   - B 路线的 /api/download 在社区脚本里广泛使用但**无官方文档**,且百度会按
//     Cookie 新鲜度/风控给不同结果。代码里保留这条尝试,失败时给一句能指导用户
//     切到 A 路线的人话,而不是抛一个看不懂的服务端错误。
//
// ★ 直链必须伪装 UA:≥20MB 的文件用别的 UA 会 403/被限速到不可用。
//   这是全项目 UA 口径的第四条(前三条见 http.rs:Emby / 预取 / 默认)。
use super::oplist::OplistAuth;
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use serde_json::Value;
use std::collections::HashMap;

const PROVIDER: &str = "baiduyun";
/// ★ 未经源码证实(OpenList 的百度 driver 未取到)。填错会 404,
/// 故用户可在表单里覆盖(extra.oplist_driver_txt),不必等我们发版。
const DRIVER_TXT: &str = "baiduyun_go";

const OPEN_API: &str = "https://pan.baidu.com/rest/2.0";
const WEB_API: &str = "https://pan.baidu.com/api";
const REFERER: &str = "https://pan.baidu.com/disk/home";
/// 取直链专用 UA。换成浏览器 UA,≥20MB 的文件直接 403 —— 表现为"小文件能播大文件不能"。
const DLINK_UA: &str = "pan.baidu.com";
const BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
const PAGE_LIMIT: i64 = 1000;
const MAX_PAGES: usize = 200;

#[derive(Default)]
pub struct BaiduBackend {
    auth: Option<OplistAuth>,
}

impl BaiduBackend {
    pub fn new() -> Self {
        Self { auth: Some(OplistAuth::new(PROVIDER, DRIVER_TXT)) }
    }

    fn auth(&self) -> &OplistAuth {
        self.auth.as_ref().expect("BaiduBackend 必须用 new() 构造")
    }

    /// Cookie 路线的凭据。存在即走 B 路线。
    fn cookie(server: &SourceServer) -> Option<String> {
        server
            .extra
            .get("cookie")
            .cloned()
            .or_else(|| server.token.clone())
            .filter(|c| c.contains("BDUSS"))
    }

    fn uses_cookie(server: &SourceServer) -> bool {
        Self::cookie(server).is_some()
    }

    async fn open_get(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Value, SourceError> {
        let mut forced = false;
        loop {
            let token = self.auth().access_token(http, server, forced).await?;
            let mut q: Vec<(&str, String)> = vec![("access_token", token.clone())];
            q.extend(query.iter().cloned());
            let resp = http
                .get(format!("{OPEN_API}{path}"))
                .query(&q)
                .header("User-Agent", DLINK_UA)
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("百度网盘请求失败: {e}")))?;
            let status = resp.status();
            let v: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("百度网盘响应解析失败({status}): {e}")))?;
            // errno 是百度自己的错误码,HTTP 一律 200。-6 = 鉴权失败。
            match v["errno"].as_i64().unwrap_or(0) {
                0 => return Ok(v),
                -6 | 111 if !forced => {
                    forced = true;
                    continue;
                }
                e => {
                    return Err(SourceError {
                        message: format!("百度网盘错误(errno={e})"),
                        is_auth: matches!(e, -6 | 111),
                    })
                }
            }
        }
    }

    async fn web_get(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Value, SourceError> {
        let cookie = Self::cookie(server)
            .ok_or_else(|| SourceError::auth("百度网盘未登录，请重新填写 Cookie"))?;
        let resp = http
            .get(format!("{WEB_API}{path}"))
            .query(query)
            .header("Cookie", cookie)
            .header("Referer", REFERER)
            .header("User-Agent", BROWSER_UA)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("百度网盘请求失败: {e}")))?;
        let status = resp.status();
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("百度网盘响应解析失败({status}): {e}")))?;
        match v["errno"].as_i64().unwrap_or(0) {
            0 => Ok(v),
            e => Err(SourceError {
                message: format!("百度网盘错误(errno={e})"),
                is_auth: matches!(e, -6 | 111 | -9),
            }),
        }
    }
}

fn item_to_entry(m: &Value) -> SourceEntry {
    let is_dir = m["isdir"].as_i64() == Some(1) || m["isdir"].as_str() == Some("1");
    // server_filename 是短名,path 是全路径。导航要用全路径。
    let name = m["server_filename"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            m["path"]
                .as_str()
                .unwrap_or("")
                .rsplit('/')
                .next()
                .unwrap_or("")
                .to_string()
        });
    let is_video = !is_dir && (m["category"].as_i64() == Some(1) || is_video_file_name(&name));
    SourceEntry {
        id: m["path"].as_str().unwrap_or("").to_string(),
        name,
        is_dir,
        is_video,
        size: m["size"].as_i64(),
        thumb_url: m["thumbs"]["url3"]
            .as_str()
            .or_else(|| m["thumbs"]["url2"].as_str())
            .or_else(|| m["thumbs"]["url1"].as_str())
            .map(|s| s.to_string()),
        // fs_id 取直链时必需,而 trait 只带得回一个 id 字符串 —— 塞进 raw 免得再查一次。
        raw: m["fs_id"].as_i64().map(|f| serde_json::json!({ "fs_id": f })),
    }
}

impl BaiduBackend {
    /// fs_id:优先用列表带回来的,没有就按路径反查一次。
    async fn fs_id_of(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
    ) -> Result<i64, SourceError> {
        if let Some(f) = entry.raw.as_ref().and_then(|r| r["fs_id"].as_i64()) {
            return Ok(f);
        }
        // 回放/重签路径上 raw 是空的(watchdog 不传),按父目录列一次找回来。
        let parent = entry.id.rsplit_once('/').map(|(p, _)| p).unwrap_or("");
        let dir = if parent.is_empty() { "/" } else { parent };
        let list = self.list_dir(http, server, Some(dir)).await?;
        list.iter()
            .find(|e| e.id == entry.id)
            .and_then(|e| e.raw.as_ref())
            .and_then(|r| r["fs_id"].as_i64())
            .ok_or_else(|| SourceError::msg("未找到该文件"))
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for BaiduBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::baidu()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let dir = dir_id.filter(|d| !d.is_empty()).unwrap_or("/");
        let mut out = Vec::new();
        let mut start = 0i64;
        for _ in 0..MAX_PAGES {
            let q = vec![
                ("dir", dir.to_string()),
                ("order", "name".to_string()),
                ("desc", "0".to_string()),
                ("start", start.to_string()),
                ("limit", PAGE_LIMIT.to_string()),
                ("web", "1".to_string()),
            ];
            let v = if Self::uses_cookie(server) {
                self.web_get(http, server, "/list", &q).await?
            } else {
                let mut q2 = vec![("method", "list".to_string())];
                q2.extend(q);
                self.open_get(http, server, "/xpan/file", &q2).await?
            };
            let empty = vec![];
            let list = v["list"].as_array().unwrap_or(&empty);
            let n = list.len() as i64;
            out.extend(list.iter().map(item_to_entry));
            if n < PAGE_LIMIT {
                break;
            }
            start += n;
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let q = vec![
            ("key", query.to_string()),
            ("dir", "/".to_string()),
            ("recursion", "1".to_string()),
            ("web", "1".to_string()),
            ("num", PAGE_LIMIT.to_string()),
        ];
        let v = if Self::uses_cookie(server) {
            self.web_get(http, server, "/search", &q).await?
        } else {
            let mut q2 = vec![("method", "search".to_string())];
            q2.extend(q);
            self.open_get(http, server, "/xpan/file", &q2).await?
        };
        let empty = vec![];
        let mut out: Vec<SourceEntry> = v["list"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .map(item_to_entry)
            .collect();
        sort_entries(&mut out);
        Ok(out)
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let fs_id = self.fs_id_of(http, server, entry).await?;
        // 直链必须带这套头,否则 ≥20MB 的文件 403。
        let mut headers = HashMap::new();
        headers.insert("User-Agent".to_string(), DLINK_UA.to_string());
        headers.insert("Referer".to_string(), "https://pan.baidu.com/".to_string());

        if Self::uses_cookie(server) {
            // B 路线。无官方文档,失败时给出可操作的指引而不是原始错误码。
            let v = self
                .web_get(
                    http,
                    server,
                    "/download",
                    &[
                        ("type", "dlink".to_string()),
                        ("fidlist", format!("[{fs_id}]")),
                        ("web", "1".to_string()),
                    ],
                )
                .await
                .map_err(|e| {
                    SourceError::msg(format!(
                        "Cookie 方式取播放地址失败（{}）。百度网页版取直链无官方接口且受风控限制，\
                         建议在设置里改用「授权令牌」方式登录百度网盘。",
                        e.message
                    ))
                })?;
            let url = v["dlink"][0]["dlink"].as_str().unwrap_or("");
            if url.is_empty() {
                return Err(SourceError::msg(
                    "百度网页版未返回播放地址，建议改用「授权令牌」方式登录。",
                ));
            }
            if let Some(c) = Self::cookie(server) {
                headers.insert("Cookie".to_string(), c);
            }
            return Ok(ResolvedPlay {
                url: url.to_string(),
                title: entry.name.clone(),
                http_headers: headers,
                user_agent_override: Some(DLINK_UA.to_string()),
                subtitles: vec![],
                qualities: vec![],
                selected_quality_id: None,
            });
        }

        // A 路线:filemetas 带 dlink=1。
        let v = self
            .open_get(
                http,
                server,
                "/xpan/multimedia",
                &[
                    ("method", "filemetas".to_string()),
                    ("fsids", format!("[{fs_id}]")),
                    ("dlink", "1".to_string()),
                ],
            )
            .await?;
        let dlink = v["list"][0]["dlink"].as_str().unwrap_or("");
        if dlink.is_empty() {
            return Err(SourceError::msg("百度网盘未返回播放地址"));
        }
        // dlink 本身不含令牌,必须拼上 —— 少了它拿到的是一个 403 页面而不是视频。
        let token = self.auth().access_token(http, server, false).await?;
        let sep = if dlink.contains('?') { '&' } else { '?' };
        Ok(ResolvedPlay {
            url: format!("{dlink}{sep}access_token={token}"),
            title: entry.name.clone(),
            http_headers: headers,
            user_agent_override: Some(DLINK_UA.to_string()),
            subtitles: vec![],
            qualities: vec![],
            selected_quality_id: None,
        })
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        self.auth().take_rotated(server_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 路线分派靠凭据形态。判错的话会拿 Cookie 去打开放平台(必 401),
    /// 或拿令牌去打网页版(必空列表),两种都不给有用的报错。
    #[test]
    fn route_is_chosen_by_which_credential_exists() {
        let mut s = SourceServer::default();
        assert!(!BaiduBackend::uses_cookie(&s), "无凭据时默认走令牌路线");

        s.token = Some("BDUSS=abc; STOKEN=def".into());
        assert!(BaiduBackend::uses_cookie(&s));

        // 令牌串里不含 BDUSS,不能误判成 Cookie 路线。
        s.token = Some("4.9f0a...refresh-token".into());
        assert!(!BaiduBackend::uses_cookie(&s));

        s.extra.insert("cookie".into(), "BDUSS=xyz".into());
        assert!(BaiduBackend::uses_cookie(&s), "extra.cookie 也应识别");
    }

    /// isdir 有时是数字有时是字符串(网页版/开放平台不一致)。
    /// 只认一种的话,另一条路线下所有目录都会变成"文件",点不进去。
    #[test]
    fn isdir_accepts_both_number_and_string() {
        let n = json!({"isdir":1,"path":"/影视","server_filename":"影视"});
        assert!(item_to_entry(&n).is_dir);
        let s = json!({"isdir":"1","path":"/影视","server_filename":"影视"});
        assert!(item_to_entry(&s).is_dir);
        let f = json!({"isdir":0,"path":"/a.mkv","server_filename":"a.mkv","size":10});
        let e = item_to_entry(&f);
        assert!(!e.is_dir && e.is_video && e.size == Some(10));
    }

    /// id 用全路径(导航要),name 用短名(展示要)。
    /// 缺 server_filename 时从 path 末段兜底,不能显示成空白行。
    #[test]
    fn id_is_full_path_and_name_falls_back_to_last_segment() {
        let full = json!({"isdir":0,"path":"/影视/剧/a.mkv","server_filename":"a.mkv"});
        let e = item_to_entry(&full);
        assert_eq!(e.id, "/影视/剧/a.mkv");
        assert_eq!(e.name, "a.mkv");

        let no_name = json!({"isdir":0,"path":"/影视/剧/b.mkv"});
        assert_eq!(item_to_entry(&no_name).name, "b.mkv");
    }

    /// fs_id 必须随条目带回来 —— 取直链只认 fs_id,不认路径。
    #[test]
    fn fs_id_is_carried_in_raw() {
        let f = json!({"isdir":0,"path":"/a.mkv","server_filename":"a.mkv","fs_id":123456789i64});
        assert_eq!(item_to_entry(&f).raw.unwrap()["fs_id"], 123456789i64);
        let missing = json!({"isdir":0,"path":"/a.mkv","server_filename":"a.mkv"});
        assert!(item_to_entry(&missing).raw.is_none());
    }
}
