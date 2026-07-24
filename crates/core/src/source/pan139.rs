// 移动云盘 / 中国移动云盘(yun.139.com)后端。个人云(hcy 新接口)。
//
// 139 全网**没有逆向出的扫码接口**,一律账密登录。OpenList 的做法也是让用户把浏览器里
// 登录 yun.139.com 后的 Authorization(Basic ...)整段拷出来粘贴,我们照搬:
//   凭据 = 用户粘贴的 Authorization 头(extra.authorization)。
//
// 每个请求都要 **mcloud-sign** 签名(算法逐字节抄自 OpenList drivers/139/util.go 的 calSign):
//   1. body 过 encodeURIComponent(JS 口径,不是通用 urlencode);
//   2. 拆成字符**排序**再拼回,base64;
//   3. sign = UPPER( MD5( MD5(base64) + MD5(ts + ":" + randStr) ) );
//   header:mcloud-sign: {ts},{randStr},{sign}。
//
// ponytail:authTokenRefresh.do 走 XML,暂不实现。Authorization 过期就报鉴权失败让用户重贴,
//   等真机确认刷新链路收益再补(139 是最重且优先级最低的一家)。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use md5::{Digest, Md5};
use rand::RngCore;
use serde_json::{json, Value};
use std::collections::HashMap;

const HCY_HOST: &str = "https://personal-kd-njs.yun.139.com";
const PAGE_SIZE: i64 = 100;
const MAX_PAGES: usize = 400;
/// hcy 个人云根目录。UNVERIFIED:OpenList 用 dir.GetID(),根对象 ID 未在取到的源码片段里,
/// 按社区约定用 "root";填错可在表单 extra.root_id 覆盖。
const DEFAULT_ROOT: &str = "root";

#[derive(Default)]
pub struct Pan139Backend;

impl Pan139Backend {
    pub fn new() -> Self {
        Self
    }

    fn authorization(server: &SourceServer) -> Result<String, SourceError> {
        let raw = server
            .extra
            .get("authorization")
            .cloned()
            .or_else(|| server.token.clone())
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| SourceError::auth("尚未登录，请粘贴移动云盘 Authorization"))?;
        let raw = raw.trim();
        // 用户可能只贴了 base64 主体,也可能带 "Basic " 前缀,统一补上。
        if raw.to_ascii_lowercase().starts_with("basic ") {
            Ok(raw.to_string())
        } else {
            Ok(format!("Basic {raw}"))
        }
    }

    async fn post(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        body: Value,
    ) -> Result<Value, SourceError> {
        let auth = Self::authorization(server)?;
        let body_str = serde_json::to_string(&body).unwrap_or_default();
        let ts = now_ms().to_string();
        let rand_str = gen_rand_str();
        let sign = cal_sign(&body_str, &ts, &rand_str);

        let resp = http
            .post(format!("{HCY_HOST}{path}"))
            .header("Accept", "application/json, text/plain, */*")
            .header("Content-Type", "application/json;charset=UTF-8")
            .header("Authorization", &auth)
            .header("CMS-DEVICE", "default")
            .header("mcloud-channel", "1000101")
            .header("mcloud-client", "10701")
            .header("mcloud-version", "7.14.0")
            .header("mcloud-sign", format!("{ts},{rand_str},{sign}"))
            .header("x-SvcType", "1")
            .header("x-DeviceInfo", "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||")
            .header("x-huawei-channelSrc", "10000034")
            .header("x-inner-ntwk", "2")
            .header("x-m4c-caller", "PC")
            .header("x-m4c-src", "10002")
            .body(body_str)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("移动云盘请求失败: {e}")))?;
        let status = resp.status();
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("移动云盘响应解析失败({status}): {e}")))?;
        // 139 用 success + code 表状态;鉴权失效常见 code 含 "auth"/"token" 或 HTTP 401。
        let success = v["success"].as_bool().unwrap_or(false)
            || v["code"].as_str() == Some("0")
            || v["code"].as_i64() == Some(0);
        if !success {
            let msg = v["message"].as_str().unwrap_or("请求失败");
            let is_auth = status == reqwest::StatusCode::UNAUTHORIZED
                || {
                    let code = v["code"].as_str().unwrap_or("").to_ascii_lowercase();
                    code.contains("auth") || code.contains("token") || code.contains("login")
                };
            return Err(SourceError {
                message: format!(
                    "移动云盘错误: {msg}{}",
                    if is_auth { "（Authorization 可能已过期，请重新粘贴）" } else { "" }
                ),
                is_auth,
            });
        }
        Ok(v)
    }
}

fn item_to_entry(m: &Value) -> SourceEntry {
    let is_dir = m["type"].as_str() == Some("folder");
    let name = m["name"].as_str().unwrap_or("").to_string();
    let is_video = !is_dir && is_video_file_name(&name);
    SourceEntry {
        id: m["fileId"].as_str().unwrap_or("").to_string(),
        is_video,
        name,
        is_dir,
        size: m["size"].as_i64(),
        thumb_url: m["thumbnailUrl"]
            .as_str()
            .or_else(|| m["bigThumbnailUrl"].as_str())
            .map(|s| s.to_string()),
        raw: None,
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for Pan139Backend {
    fn kind(&self) -> SourceKind {
        SourceKind::pan139()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let root = server
            .extra
            .get("root_id")
            .filter(|s| !s.is_empty())
            .map(|s| s.as_str())
            .unwrap_or(DEFAULT_ROOT);
        let parent = dir_id.filter(|d| !d.is_empty()).unwrap_or(root);
        let mut out = Vec::new();
        let mut cursor = String::new();
        for _ in 0..MAX_PAGES {
            let body = json!({
                "imageThumbnailStyleList": ["Small", "Large"],
                "orderBy": "updated_at",
                "orderDirection": "DESC",
                "pageInfo": { "pageCursor": cursor, "pageSize": PAGE_SIZE },
                "parentFileId": parent,
            });
            let v = self.post(http, server, "/hcy/file/list", body).await?;
            let data = &v["data"];
            let empty = vec![];
            let items = data["items"].as_array().unwrap_or(&empty);
            out.extend(items.iter().map(item_to_entry));
            match data["nextPageCursor"].as_str().filter(|s| !s.is_empty()) {
                Some(c) => cursor = c.to_string(),
                None => break,
            }
        }
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
        let v = self
            .post(
                http,
                server,
                "/hcy/file/getDownloadUrl",
                json!({ "fileId": entry.id }),
            )
            .await?;
        let url = v["data"]["cdnUrl"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or_else(|| v["data"]["url"].as_str())
            .unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("移动云盘未返回下载地址"));
        }
        Ok(ResolvedPlay::simple(url.to_string(), entry.name.clone(), HashMap::new()))
    }
}

// ---------- mcloud-sign ----------

fn md5_hex(data: &[u8]) -> String {
    let mut h = Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

/// JS encodeURIComponent 的忠实复刻:只放行 A-Za-z0-9 与 -_.!~*'() ,其余按 UTF-8 字节
/// 百分号大写十六进制编码。**不能用通用 urlencode**(那会把 !~*'() 也编码,签名就对不上服务端)。
fn encode_uri_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '!' | '~' | '*' | '\'' | '(' | ')') {
            out.push(c);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

/// calSign:encodeURIComponent → 字符排序 → base64 → 双层 MD5 → 大写。
fn cal_sign(body: &str, ts: &str, rand_str: &str) -> String {
    use base64::Engine;
    let enc = encode_uri_component(body);
    // encodeURIComponent 输出纯 ASCII,按 char 排序 == 按字节排序,与 Go 的 sort.Strings 一致。
    let mut chars: Vec<char> = enc.chars().collect();
    chars.sort_unstable();
    let sorted: String = chars.into_iter().collect();
    let b64 = base64::engine::general_purpose::STANDARD.encode(sorted.as_bytes());
    let part1 = md5_hex(b64.as_bytes());
    let part2 = md5_hex(format!("{ts}:{rand_str}").as_bytes());
    md5_hex(format!("{part1}{part2}").as_bytes()).to_uppercase()
}

fn gen_rand_str() -> String {
    let mut b = [0u8; 8];
    rand::rng().fill_bytes(&mut b);
    hex::encode(b)
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// encodeURIComponent 已知答案:对齐浏览器 JS。写歪一个保留字符,全表签名报废。
    #[test]
    fn encode_uri_component_matches_js() {
        assert_eq!(encode_uri_component("a b/c=中"), "a%20b%2Fc%3D%E4%B8%AD");
        // JS 不编码这几个:-_.!~*'()
        assert_eq!(encode_uri_component("-_.!~*'()"), "-_.!~*'()");
        // JSON 常见字符
        assert_eq!(encode_uri_component("{\"k\":\"v\"}"), "%7B%22k%22%3A%22v%22%7D");
    }

    /// calSign 排序不变性 + 形状。ts/randStr 相同则输出恒定;输出 32 位大写十六进制。
    #[test]
    fn cal_sign_is_deterministic_uppercase_md5() {
        let s1 = cal_sign(r#"{"a":1,"b":2}"#, "1700000000000", "abcd1234");
        let s2 = cal_sign(r#"{"a":1,"b":2}"#, "1700000000000", "abcd1234");
        assert_eq!(s1, s2);
        assert_eq!(s1.len(), 32, "MD5 = 16 字节 = 32 hex");
        assert!(s1.chars().all(|c| c.is_ascii_hexdigit() && !c.is_lowercase()));
        // ts 变则签名变(ts 进了第二层 MD5)。
        assert_ne!(s1, cal_sign(r#"{"a":1,"b":2}"#, "1700000000001", "abcd1234"));
    }

    /// Authorization 归一化:裸 base64 补 "Basic ",已带前缀的原样。无凭据报鉴权。
    #[test]
    fn authorization_normalizes_prefix() {
        let mut s = SourceServer::default();
        assert!(Pan139Backend::authorization(&s).is_err());
        s.extra.insert("authorization".into(), "YWJjOjEyMw==".into());
        assert_eq!(Pan139Backend::authorization(&s).unwrap(), "Basic YWJjOjEyMw==");
        s.extra.insert("authorization".into(), "Basic ZZZ".into());
        assert_eq!(Pan139Backend::authorization(&s).unwrap(), "Basic ZZZ");
    }

    #[test]
    fn item_type_folder_vs_file() {
        let d = json!({"type":"folder","name":"影视","fileId":"c1"});
        assert!(item_to_entry(&d).is_dir);
        let f = json!({"type":"file","name":"a.mkv","fileId":"f1","size":9});
        let e = item_to_entry(&f);
        assert!(!e.is_dir && e.is_video && e.id == "f1" && e.size == Some(9));
    }
}
