// 115 网盘后端(Cookie / 网页 API)。
//
// 列目录/搜索是普通 JSON 接口,唯独**取直链要过私有编解码**:
//   POST proapi.115.com/app/chrome/downurl,form 里 data= 是密文,响应 data 也是密文。
// 编解码见 pan115_crypto(m115),只用到大数模幂 + 两次 XOR,不涉及上传那套 ECDH/P-224。
//
// ★ 直链**绑定请求时用的 User-Agent**:换个 UA 去取流直接 403。
//   所以取直链和喂给播放器必须是同一个 UA,靠 user_agent_override 传下去。
//
// ★ 115 风控严(社区共识约 3 QPS、多端互踢)。这里不做并发扫目录,分页也走串行。
use super::pan115_crypto as m115;
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use serde_json::Value;
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

const WEB_API: &str = "https://webapi.115.com";
const PRO_API: &str = "https://proapi.115.com";
/// 取直链时用的 UA,必须与播放时一致。
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 115Browser/24.0.0";
/// 115 单页上限(取 1150 会被拒,官方前端用 115/1150 两档,这里取稳的)。
const PAGE_LIMIT: i64 = 115;
const MAX_PAGES: usize = 200;

#[derive(Default)]
pub struct Pan115Backend;

impl Pan115Backend {
    pub fn new() -> Self {
        Self
    }

    fn cookie(server: &SourceServer) -> Result<String, SourceError> {
        server
            .extra
            .get("cookie")
            .cloned()
            .or_else(|| server.token.clone())
            .filter(|c| c.contains("UID") || c.contains("SEID"))
            .ok_or_else(|| SourceError::auth("115 未登录，请重新添加 Cookie"))
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
            .header("User-Agent", UA)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("115 请求失败: {e}")))?;
        let status = resp.status();
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("115 响应解析失败({status}): {e}")))?;
        // 115 的成功标志是 state=true;鉴权失效时 errno 常见 99 / errcode 911。
        if v["state"].as_bool() == Some(true) {
            return Ok(v);
        }
        let errno = v["errno"].as_i64().or_else(|| v["errNo"].as_i64()).unwrap_or(0);
        let is_auth = matches!(errno, 99 | 911) || v["errcode"].as_i64() == Some(911);
        Err(SourceError {
            message: v["error"]
                .as_str()
                .or_else(|| v["error_msg"].as_str())
                .unwrap_or(if is_auth { "115 登录已失效，请重新登录" } else { "115 请求失败" })
                .to_string(),
            is_auth,
        })
    }
}

fn item_to_entry(m: &Value) -> SourceEntry {
    // 目录没有 fid,自身 id 在 cid;文件有 fid,cid 是父目录。
    let fid = m["fid"].as_str().map(|s| s.to_string());
    let is_dir = fid.is_none();
    let name = m["n"].as_str().unwrap_or("").to_string();
    let id = match &fid {
        Some(f) => f.clone(),
        None => m["cid"].as_str().unwrap_or("").to_string(),
    };
    // 视频判定:iv=1 是 115 自己标的视频,再用扩展名兜底。
    let is_video = !is_dir && (m["iv"].as_i64() == Some(1) || is_video_file_name(&name));
    SourceEntry {
        id,
        name,
        is_dir,
        is_video,
        // s 有时是数字有时是字符串。
        size: m["s"].as_i64().or_else(|| m["s"].as_str().and_then(|x| x.parse().ok())),
        thumb_url: m["u"].as_str().filter(|s| s.starts_with("http")).map(|s| s.to_string()),
        // pick_code 是取直链的唯一钥匙,文件 id 换不来直链。
        raw: m["pc"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(|pc| serde_json::json!({ "pick_code": pc })),
    }
}

impl Pan115Backend {
    async fn pick_code_of(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
    ) -> Result<String, SourceError> {
        if let Some(pc) = entry.raw.as_ref().and_then(|r| r["pick_code"].as_str()) {
            if !pc.is_empty() {
                return Ok(pc.to_string());
            }
        }
        // watchdog 重签时 raw 是空的,按文件 id 反查一次。
        let v = self
            .web_get(
                http,
                server,
                "/files/file",
                &[("file_id", entry.id.clone())],
            )
            .await?;
        v["data"][0]["pick_code"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .ok_or_else(|| SourceError::msg("未取到该文件的提取码"))
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for Pan115Backend {
    fn kind(&self) -> SourceKind {
        SourceKind::pan115()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let cid = dir_id.filter(|d| !d.is_empty()).unwrap_or("0");
        let mut out = Vec::new();
        let mut offset = 0i64;
        for _ in 0..MAX_PAGES {
            let v = self
                .web_get(
                    http,
                    server,
                    "/files",
                    &[
                        ("aid", "1".into()),
                        ("cid", cid.to_string()),
                        ("o", "file_name".into()),
                        ("asc", "1".into()),
                        ("offset", offset.to_string()),
                        ("limit", PAGE_LIMIT.to_string()),
                        ("show_dir", "1".into()),
                        ("natsort", "1".into()),
                        ("format", "json".into()),
                    ],
                )
                .await?;
            let empty = vec![];
            let list = v["data"].as_array().unwrap_or(&empty);
            let n = list.len() as i64;
            out.extend(list.iter().map(item_to_entry));
            if n < PAGE_LIMIT {
                break;
            }
            offset += n;
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
        let v = self
            .web_get(
                http,
                server,
                "/files/search",
                &[
                    ("aid", "1".into()),
                    ("cid", "0".into()),
                    ("search_value", query.to_string()),
                    ("offset", "0".into()),
                    ("limit", PAGE_LIMIT.to_string()),
                    ("format", "json".into()),
                ],
            )
            .await?;
        let empty = vec![];
        let mut out: Vec<SourceEntry> = v["data"]
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
        let cookie = Self::cookie(server)?;
        let pick_code = self.pick_code_of(http, server, entry).await?;

        let key = m115::generate_key();
        let payload = serde_json::json!({ "pickcode": pick_code }).to_string();
        let data = m115::encode(payload.as_bytes(), &key);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        let resp = http
            .post(format!("{PRO_API}/app/chrome/downurl"))
            .query(&[("t", ts.to_string())])
            .header("Cookie", &cookie)
            .header("User-Agent", UA)
            .form(&[("data", data)])
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("115 取直链失败: {e}")))?;
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("115 直链响应异常: {e}")))?;
        if v["state"].as_bool() != Some(true) {
            let msg = v["msg"].as_str().unwrap_or("115 取直链被拒绝");
            // 115 对频繁取链会限流,说清楚比抛原始 msg 有用。
            return Err(SourceError::msg(format!("{msg}（115 取链受频率限制，请稍后重试）")));
        }
        let cipher = v["data"].as_str().unwrap_or("");
        let plain = m115::decode(cipher, &key).map_err(SourceError::msg)?;
        let decoded: Value = serde_json::from_slice(&plain)
            .map_err(|e| SourceError::msg(format!("115 直链解码后不是合法 JSON: {e}")))?;

        // 结构是 { "<file_id>": { file_name, file_size, url: { url } } },键名是文件 id,
        // 事先不知道,故取第一个值。
        let url = decoded
            .as_object()
            .and_then(|o| o.values().next())
            .and_then(|f| f["url"]["url"].as_str())
            .unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("115 未返回可播地址（该文件可能仍在转码或已被和谐）"));
        }

        // 直链绑 UA + Cookie,两者必须与取链时逐字一致。
        let mut headers = HashMap::new();
        headers.insert("User-Agent".to_string(), UA.to_string());
        headers.insert("Cookie".to_string(), cookie);
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 目录靠"没有 fid"识别,自身 id 取 cid。
    /// 判反的话:目录会变成不可播的文件,或文件被当目录点进去得到空列表 —— 都不报错。
    #[test]
    fn directories_have_no_fid_and_use_cid_as_id() {
        let dir = json!({"cid":"2024","n":"电影","pid":"0"});
        let e = item_to_entry(&dir);
        assert!(e.is_dir && e.id == "2024" && !e.is_video);

        let file = json!({"fid":"f88","cid":"2024","n":"a.mkv","s":123,"pc":"abcpick","iv":1});
        let e = item_to_entry(&file);
        assert!(!e.is_dir && e.is_video);
        assert_eq!(e.id, "f88", "文件的 id 是 fid 不是 cid(cid 是父目录)");
        assert_eq!(e.size, Some(123));
    }

    /// pick_code 是取直链的唯一钥匙 —— 文件 id 换不来直链。
    /// 丢了它,播放时要么多打一次接口,要么直接失败。
    #[test]
    fn pick_code_is_carried_in_raw() {
        let f = json!({"fid":"f1","n":"a.mkv","pc":"pk123"});
        assert_eq!(item_to_entry(&f).raw.unwrap()["pick_code"], "pk123");
        let no_pc = json!({"fid":"f1","n":"a.mkv"});
        assert!(item_to_entry(&no_pc).raw.is_none());
        let blank = json!({"fid":"f1","n":"a.mkv","pc":""});
        assert!(item_to_entry(&blank).raw.is_none(), "空提取码等于没有");
    }

    /// size 两种类型都出现过;只认数字会让一半文件显示 0 字节。
    #[test]
    fn size_accepts_number_and_string() {
        assert_eq!(item_to_entry(&json!({"fid":"1","n":"a","s":42})).size, Some(42));
        assert_eq!(item_to_entry(&json!({"fid":"1","n":"a","s":"42"})).size, Some(42));
        assert_eq!(item_to_entry(&json!({"fid":"1","n":"a"})).size, None);
    }

    /// Cookie 必须含 115 的会话字段才算数 —— 随便一个字符串会让请求发出去再被拒,
    /// 用户看到的是"请求失败"而不是"没登录"。
    #[test]
    fn cookie_requires_session_fields() {
        let mut s = SourceServer::default();
        assert!(Pan115Backend::cookie(&s).is_err());

        s.token = Some("some-random-token".into());
        assert!(Pan115Backend::cookie(&s).is_err(), "不含 UID/SEID 不该当作已登录");

        s.token = Some("UID=1_2_3; CID=x; SEID=y".into());
        assert!(Pan115Backend::cookie(&s).is_ok());

        s.token = None;
        s.extra.insert("cookie".into(), "SEID=abc".into());
        assert!(Pan115Backend::cookie(&s).is_ok());
    }
}
