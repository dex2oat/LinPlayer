// 百度网盘后端。**Cookie(BDUSS)单路线** —— 2026-07-24 砍掉原先的 oplist 令牌路线
// (那个在线中继实测已不可用,见 [[netdisk-sources-via-oplist]] 的作废说明)。
//
// 登录两种姿势,产物都是 BDUSS Cookie:
//   1. 扫码(推荐):passport.baidu.com 出码 → 轮询 → 换 BDUSS(见 qr_start/qr_poll)。
//   2. 手动粘贴:用户从浏览器 DevTools 拷 `BDUSS=...; STOKEN=...` 填进表单。
//
// 取流走网页版 /api/*,直链走 /api/download?type=dlink。
// ★ 直链必须伪装 UA:≥20MB 的文件用别的 UA 会 403/被限速到不可用。
//   这是全项目 UA 口径的第四条(前三条见 http.rs:Emby / 预取 / 默认)。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, QrPoll, QrStart, ResolvedPlay,
    SourceEntry, SourceError, SourceKind, SourceServer,
};
use rand::RngCore;
use serde_json::Value;
use std::collections::HashMap;

const WEB_API: &str = "https://pan.baidu.com/api";
const REFERER: &str = "https://pan.baidu.com/disk/home";
/// 取直链专用 UA。换成浏览器 UA,≥20MB 的文件直接 403 —— 表现为"小文件能播大文件不能"。
const DLINK_UA: &str = "pan.baidu.com";
const BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
const PAGE_LIMIT: i64 = 1000;
const MAX_PAGES: usize = 200;

const PASSPORT: &str = "https://passport.baidu.com";

#[derive(Default)]
pub struct BaiduBackend;

impl BaiduBackend {
    pub fn new() -> Self {
        Self
    }

    /// 取 BDUSS Cookie。cookie 优先 extra.cookie,回落 token 字段;必须含 BDUSS。
    fn cookie(server: &SourceServer) -> Result<String, SourceError> {
        server
            .extra
            .get("cookie")
            .cloned()
            .or_else(|| server.token.clone())
            .filter(|c| c.contains("BDUSS"))
            .ok_or_else(|| SourceError::auth("百度网盘未登录，请扫码或填写含 BDUSS 的 Cookie"))
    }

    async fn web_get(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Value, SourceError> {
        let cookie = Self::cookie(server)?;
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
        // errno 是百度自己的错误码,HTTP 一律 200。-6/111/-9 = 鉴权/Cookie 失效。
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
            let v = self.web_get(http, server, "/list", &q).await?;
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
        let v = self.web_get(http, server, "/search", &q).await?;
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

        // 网页版取直链无官方文档,失败时给出可操作的指引而不是原始错误码。
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
                if e.is_auth {
                    e
                } else {
                    SourceError::msg(format!(
                        "百度取播放地址失败（{}）。网页版取直链受风控限制，Cookie 过期请重新扫码登录。",
                        e.message
                    ))
                }
            })?;
        let url = v["dlink"][0]["dlink"].as_str().unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("百度未返回播放地址，Cookie 可能已过期，请重新扫码登录。"));
        }
        headers.insert("Cookie".to_string(), Self::cookie(server)?);
        Ok(ResolvedPlay {
            url: url.to_string(),
            title: entry.name.clone(),
            http_headers: headers,
            user_agent_override: Some(DLINK_UA.to_string()),
            subtitles: vec![],
            qualities: vec![],
            selected_quality_id: None,
        })
    }
}

// ---------- 扫码登录:passport.baidu.com 出码 → 轮询 → 换 BDUSS ----------
//
// ★ UNVERIFIED:百度扫码是 JSONP 老接口,gid/tt/回调那套没有官方文档,只能靠社区
//   脚本(BaiduPCS-Py / iScript)复刻。真机跑不通时,手动粘贴 BDUSS Cookie 那条路仍在,
//   不至于把用户堵死。

/// 生成一个 baidu gid(形如 32 位大写十六进制 + 短横,凑够它认的格式)。
fn gen_gid() -> String {
    let mut b = [0u8; 16];
    rand::rng().fill_bytes(&mut b);
    let h = hex::encode_upper(b);
    // 8-4-4-4-12 的 UUID 版式,百度接受。
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

/// 开始扫码:拿二维码图 + sign(轮询用的 channel_id)。
pub async fn qr_start(http: &reqwest::Client) -> Result<QrStart, SourceError> {
    let gid = gen_gid();
    let v: Value = http
        .get(format!("{PASSPORT}/v2/api/getqrcode"))
        .query(&[
            ("apiver", "v3"),
            ("tpl", "netdisk"),
            ("lp", "pc"),
            ("qrloginfrom", "pc"),
            ("gid", &gid),
        ])
        .header("Referer", "https://pan.baidu.com/")
        .header("User-Agent", BROWSER_UA)
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("百度取二维码失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("百度二维码响应解析失败: {e}")))?;
    let sign = v["sign"].as_str().unwrap_or("");
    let imgurl = v["imgurl"].as_str().unwrap_or("");
    if sign.is_empty() || imgurl.is_empty() {
        return Err(SourceError::msg("百度未返回二维码"));
    }
    // imgurl 是无协议的相对地址(pss.bdstatic.com/...),补上 https。
    let image = if imgurl.starts_with("http") {
        imgurl.to_string()
    } else {
        format!("https://{imgurl}")
    };
    let ctx = serde_json::json!({ "sign": sign, "gid": gid }).to_string();
    Ok(QrStart { image, ctx })
}

/// 轮询一次。ctx 是 qr_start 回传的 {sign,gid}。
pub async fn qr_poll(http: &reqwest::Client, ctx: &str) -> Result<QrPoll, SourceError> {
    let c: Value = serde_json::from_str(ctx)
        .map_err(|_| SourceError::msg("扫码上下文损坏，请重新获取二维码"))?;
    let sign = c["sign"].as_str().unwrap_or("");
    let gid = c["gid"].as_str().unwrap_or("");

    // 1. unicast 探状态。channel_v 是个 JSON 字符串:{status, v, ...}。
    let uni: Value = http
        .get(format!("{PASSPORT}/channel/unicast"))
        .query(&[
            ("apiver", "v3"),
            ("tpl", "netdisk"),
            ("gid", gid),
            ("channel_id", sign),
            ("_sdkFrom", "1"),
        ])
        .header("Referer", "https://pan.baidu.com/")
        .header("User-Agent", BROWSER_UA)
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("百度扫码轮询失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("百度扫码轮询解析失败: {e}")))?;
    let channel_v = uni["channel_v"].as_str().unwrap_or("");
    if channel_v.is_empty() {
        return Ok(QrPoll::Pending); // 还没扫
    }
    let cv: Value = serde_json::from_str(channel_v).unwrap_or(Value::Null);
    match cv["status"].as_i64() {
        Some(0) => {} // 已确认,继续换 BDUSS
        Some(1) => return Ok(QrPoll::Pending), // 扫了未确认
        _ => return Ok(QrPoll::Pending),
    }
    let bduss_code = cv["v"].as_str().unwrap_or("");
    if bduss_code.is_empty() {
        return Ok(QrPoll::Pending);
    }

    // 2. 用 code 换 Set-Cookie。要读原始响应头,不能让 reqwest 吞掉。
    let resp = http
        .get(format!("{PASSPORT}/v3/login/main/qrbdusslogin"))
        .query(&[
            ("bduss", bduss_code),
            ("u", "https://pan.baidu.com/disk/home"),
            ("loginVersion", "v4"),
            ("qrcode", "1"),
            ("tpl", "netdisk"),
            ("apiver", "v3"),
        ])
        .header("Referer", "https://pan.baidu.com/")
        .header("User-Agent", BROWSER_UA)
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("百度换取登录态失败: {e}")))?;
    // 收集所有 Set-Cookie,拼成 name=value; 串。只保留取流真正要的几个。
    let mut jar: Vec<String> = Vec::new();
    for hv in resp.headers().get_all(reqwest::header::SET_COOKIE) {
        if let Ok(s) = hv.to_str() {
            if let Some(pair) = s.split(';').next() {
                let name = pair.split('=').next().unwrap_or("");
                if matches!(name, "BDUSS" | "STOKEN" | "PTOKEN" | "PANWEB" | "BDUSS_BFESS") {
                    jar.push(pair.trim().to_string());
                }
            }
        }
    }
    let cookie = jar.join("; ");
    if !cookie.contains("BDUSS") {
        // 没拿到 BDUSS,多半是 code 还没生效或已过期。
        return Ok(QrPoll::Pending);
    }
    Ok(QrPoll::Confirmed {
        credentials: HashMap::from([("cookie".to_string(), cookie)]),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 无 BDUSS 一律拒绝 —— 空 Cookie 打网页版只会拿到一句看不懂的 errno。
    #[test]
    fn cookie_requires_bduss() {
        let mut s = SourceServer::default();
        assert!(BaiduBackend::cookie(&s).is_err(), "没凭据必须报未登录");

        s.token = Some("4.9f0a...refresh-token".into());
        assert!(BaiduBackend::cookie(&s).is_err(), "不含 BDUSS 的串不算登录");

        s.token = Some("BDUSS=abc; STOKEN=def".into());
        assert!(BaiduBackend::cookie(&s).is_ok());

        s.token = None;
        s.extra.insert("cookie".into(), "BDUSS=xyz".into());
        assert!(BaiduBackend::cookie(&s).is_ok(), "extra.cookie 也应识别");
    }

    /// isdir 有时是数字有时是字符串。只认一种的话,另一条路线下所有目录都会变成"文件",点不进去。
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

    /// id 用全路径(导航要),name 用短名(展示要)。缺 server_filename 时从 path 末段兜底。
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

    /// gid 版式必须是 8-4-4-4-12 的大写十六进制,百度只认这个形状。
    #[test]
    fn gid_has_uuid_shape() {
        let g = gen_gid();
        let parts: Vec<&str> = g.split('-').collect();
        assert_eq!(parts.iter().map(|p| p.len()).collect::<Vec<_>>(), vec![8, 4, 4, 4, 12]);
        assert!(g.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
        assert!(g.chars().filter(|c| c.is_alphabetic()).all(|c| c.is_uppercase()));
    }
}
