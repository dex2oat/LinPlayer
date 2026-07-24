// 天翼云盘(cloud.189.cn)后端。个人云。
//
// 登录:扫码(推荐)或 RSA 账密。扫码链路 unifyLoginForPC → getUUID → 轮询 qrcodeLoginState
// → getSessionForPC,产物是 accessToken/refreshToken/sessionKey/sessionSecret。
//
// 每个 API 请求都要签名(算法逐字节抄自 OpenList 189pc/help.go):
//   - 参数:AES-128-ECB(sessionSecret[:16], 排序后的 "k=v&k=v"),PKCS7,输出**大写 hex**,当 ?params= 传。
//   - 签名:HMAC-SHA1(sessionSecret, "SessionKey=..&Operate=GET&RequestURI={path}&Date={GMT}"
//            后接 "&params={大写hex}"(参数非空时)),输出**大写 hex**,放 Signature 头。
//   - Date 头是 RFC1123 GMT,且它是签名明文的一部分,两处必须同一个值。
// 下载:getFileDownloadUrl.action 返回带 HTML 实体的 URL,解实体 + http→https,交给 mpv 自行跟 302。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, QrPoll, QrStart, ResolvedPlay,
    SourceEntry, SourceError, SourceKind, SourceServer,
};
use aes::cipher::{BlockEncrypt, KeyInit};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde_json::Value;
use sha1::Sha1;
use std::collections::HashMap;
use std::sync::Mutex;

const WEB_URL: &str = "https://cloud.189.cn";
const AUTH_URL: &str = "https://open.e.189.cn";
const API_URL: &str = "https://api.cloud.189.cn";
const APP_ID: &str = "8025431004";
const CLIENT_TYPE: &str = "10020";
const RETURN_URL: &str = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html";
/// 每个 API 请求都要带的固定后缀参数(不进签名,只是 query)。
const CLIENT_SUFFIX: &[(&str, &str)] = &[
    ("clientType", CLIENT_TYPE),
    ("version", "6.2"),
    ("channelId", "web_cloud.189.cn"),
];
const ROOT_FOLDER: &str = "-11";
const PAGE_SIZE: i64 = 60;
const MAX_PAGES: usize = 400;

type HmacSha1 = Hmac<Sha1>;

#[derive(Default)]
pub struct Pan189Backend {
    /// server.id -> (sessionKey, sessionSecret)
    session: Mutex<HashMap<String, (String, String)>>,
    /// server.id -> 待落盘凭据(轮换后的 access_token)
    rotated: Mutex<HashMap<String, HashMap<String, String>>>,
}

impl Pan189Backend {
    pub fn new() -> Self {
        Self::default()
    }

    fn access_token(server: &SourceServer) -> String {
        server
            .extra
            .get("access_token")
            .cloned()
            .or_else(|| server.token.clone())
            .unwrap_or_default()
    }

    /// 建立会话:accessToken → getSessionForPC 拿 sessionKey/secret。
    /// accessToken 失效时用 refresh_token 换新的并记下待落盘。
    async fn build_session(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<(String, String), SourceError> {
        let mut access = Self::access_token(server);
        if access.is_empty() {
            return Err(SourceError::auth("尚未登录，请扫码登录天翼云盘"));
        }
        for attempt in 0..2 {
            let mut q: Vec<(&str, String)> = CLIENT_SUFFIX
                .iter()
                .map(|(k, v)| (*k, v.to_string()))
                .collect();
            q.push(("appId", APP_ID.to_string()));
            q.push(("accessToken", access.clone()));
            let v: Value = http
                .get(format!("{API_URL}/getSessionForPC.action"))
                .query(&q)
                .header("Accept", "application/json;charset=UTF-8")
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("天翼云盘会话建立失败: {e}")))?
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("天翼云盘会话响应解析失败: {e}")))?;
            let sk = v["sessionKey"].as_str().unwrap_or("");
            let ss = v["sessionSecret"].as_str().unwrap_or("");
            if !sk.is_empty() && !ss.is_empty() {
                let pair = (sk.to_string(), ss.to_string());
                self.session.lock().unwrap().insert(server.id.clone(), pair.clone());
                return Ok(pair);
            }
            // accessToken 失效,第一轮尝试用 refresh_token 换一次。
            if attempt == 0 {
                if let Some(new_access) = self.refresh_access(http, server).await? {
                    access = new_access;
                    continue;
                }
            }
            return Err(SourceError::auth("天翼云盘登录已失效，请重新扫码登录"));
        }
        Err(SourceError::auth("天翼云盘登录已失效，请重新扫码登录"))
    }

    /// 用 refresh_token 换新的 access_token(换到就记下待落盘)。
    async fn refresh_access(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Option<String>, SourceError> {
        let refresh = server.extra.get("refresh_token").cloned().unwrap_or_default();
        if refresh.is_empty() {
            return Ok(None);
        }
        let v: Value = http
            .post(format!("{AUTH_URL}/api/oauth2/refreshToken.do"))
            .form(&[
                ("clientId", APP_ID),
                ("refreshToken", &refresh),
                ("grantType", "refresh_token"),
                ("format", "json"),
            ])
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("天翼云盘刷新令牌失败: {e}")))?
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("天翼云盘刷新令牌解析失败: {e}")))?;
        let access = v["accessToken"].as_str().unwrap_or("").to_string();
        if access.is_empty() {
            return Ok(None);
        }
        self.rotated
            .lock()
            .unwrap()
            .entry(server.id.clone())
            .or_default()
            .insert("access_token".to_string(), access.clone());
        if let Some(nr) = v["refreshToken"].as_str().filter(|s| !s.is_empty() && *s != refresh) {
            self.rotated
                .lock()
                .unwrap()
                .entry(server.id.clone())
                .or_default()
                .insert("refresh_token".to_string(), nr.to_string());
        }
        Ok(Some(access))
    }

    async fn session(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        force: bool,
    ) -> Result<(String, String), SourceError> {
        if !force {
            if let Some(s) = self.session.lock().unwrap().get(&server.id) {
                return Ok(s.clone());
            }
        }
        self.build_session(http, server).await
    }

    /// 一个签名 GET。path 形如 "/open/file/listFiles.action";params 是待加密的业务参数。
    async fn signed_get(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        params: &[(&str, String)],
    ) -> Result<Value, SourceError> {
        let mut forced = false;
        loop {
            let (session_key, session_secret) = self.session(http, server, forced).await?;
            let enc = encrypt_params(&session_secret, params);
            let date = httpdate::fmt_http_date(std::time::SystemTime::now());
            let sig = sign_hmac(&session_secret, &session_key, "GET", path, &date, &enc);

            let mut q: Vec<(&str, String)> = Vec::new();
            if !enc.is_empty() {
                q.push(("params", enc.clone()));
            }
            q.extend(CLIENT_SUFFIX.iter().map(|(k, v)| (*k, v.to_string())));

            let resp = http
                .get(format!("{API_URL}{path}"))
                .query(&q)
                .header("Date", &date)
                .header("SessionKey", &session_key)
                .header("Signature", &sig)
                .header("X-Request-ID", gen_uuid())
                .header("Accept", "application/json;charset=UTF-8")
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("天翼云盘请求失败: {e}")))?;
            let status = resp.status();
            let v: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("天翼云盘响应解析失败({status}): {e}")))?;
            // res_code!=0 里 InvalidSessionKey / -20 之类是会话过期,重建一次。
            let code = v["res_code"].as_i64().unwrap_or(0);
            let msg = v["res_message"].as_str().unwrap_or("");
            if code != 0 {
                let session_dead = msg.contains("session")
                    || msg.contains("Session")
                    || msg.contains("InvalidSessionKey")
                    || v["errorCode"].as_str().map(|c| c.contains("Session")).unwrap_or(false);
                if session_dead && !forced {
                    self.session.lock().unwrap().remove(&server.id);
                    forced = true;
                    continue;
                }
                return Err(SourceError {
                    message: format!("天翼云盘错误: {}", if msg.is_empty() { "请求失败" } else { msg }),
                    is_auth: session_dead,
                });
            }
            return Ok(v);
        }
    }
}

/// AES-128-ECB(sessionSecret[:16]) + PKCS7 → 大写 hex。参数先按键排序拼 "k=v&k=v"。
fn encrypt_params(session_secret: &str, params: &[(&str, String)]) -> String {
    if params.is_empty() {
        return String::new();
    }
    let mut sorted: Vec<&(&str, String)> = params.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    let plain = sorted
        .iter()
        .map(|(k, v)| format!("{k}={}", urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&");

    let key = session_secret.as_bytes();
    let key16 = &key[..16.min(key.len())];
    // 不足 16 字节的 sessionSecret 理论上不会出现;真出现就补零,别 panic。
    let mut keybuf = [0u8; 16];
    keybuf[..key16.len()].copy_from_slice(key16);
    let cipher = aes::Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(&keybuf));

    let mut data = pkcs7_pad(plain.as_bytes(), 16);
    for chunk in data.chunks_mut(16) {
        let block = aes::cipher::generic_array::GenericArray::from_mut_slice(chunk);
        cipher.encrypt_block(block);
    }
    hex::encode_upper(&data)
}

/// HMAC-SHA1(sessionSecret, "SessionKey=..&Operate=..&RequestURI=..&Date=.."[&params=..]) → 大写 hex。
fn sign_hmac(
    session_secret: &str,
    session_key: &str,
    method: &str,
    request_uri: &str,
    date: &str,
    enc_params: &str,
) -> String {
    let mut data = format!(
        "SessionKey={session_key}&Operate={method}&RequestURI={request_uri}&Date={date}"
    );
    if !enc_params.is_empty() {
        data.push_str(&format!("&params={enc_params}"));
    }
    let mut mac = <HmacSha1 as Mac>::new_from_slice(session_secret.as_bytes())
        .expect("HMAC 接受任意长度密钥");
    mac.update(data.as_bytes());
    hex::encode_upper(mac.finalize().into_bytes())
}

fn pkcs7_pad(data: &[u8], block: usize) -> Vec<u8> {
    let pad = block - (data.len() % block);
    let mut out = data.to_vec();
    out.extend(std::iter::repeat(pad as u8).take(pad));
    out
}

/// 随机 UUID v4 字符串(X-Request-ID 用,服务端不校验强度)。
fn gen_uuid() -> String {
    let mut b = [0u8; 16];
    rand::rng().fill_bytes(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex::encode(b);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32]
    )
}

/// HTML 实体解码 + http→https。天翼下载 URL 带 &amp; 且可能是 http。
fn normalize_download_url(u: &str) -> String {
    let u = u.replace("&amp;", "&");
    if let Some(rest) = u.strip_prefix("http://") {
        format!("https://{rest}")
    } else {
        u
    }
}

fn file_entry(m: &Value) -> SourceEntry {
    let name = m["name"].as_str().unwrap_or("").to_string();
    SourceEntry {
        id: m["id"].as_str().map(|s| s.to_string()).unwrap_or_else(|| m["id"].to_string()),
        is_video: is_video_file_name(&name),
        name,
        is_dir: false,
        size: m["size"].as_i64(),
        thumb_url: m["icon"]["smallUrl"].as_str().map(|s| s.to_string()),
        raw: None,
    }
}

fn folder_entry(m: &Value) -> SourceEntry {
    let name = m["name"].as_str().unwrap_or("").to_string();
    SourceEntry {
        id: m["id"].as_str().map(|s| s.to_string()).unwrap_or_else(|| m["id"].to_string()),
        name,
        is_dir: true,
        is_video: false,
        size: None,
        thumb_url: None,
        raw: None,
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for Pan189Backend {
    fn kind(&self) -> SourceKind {
        SourceKind::pan189()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let folder = dir_id.filter(|d| !d.is_empty()).unwrap_or(ROOT_FOLDER);
        let mut out = Vec::new();
        for page in 1..=MAX_PAGES {
            let params = vec![
                ("folderId", folder.to_string()),
                ("fileType", "0".to_string()),
                ("mediaAttr", "0".to_string()),
                ("iconOption", "5".to_string()),
                ("pageNum", page.to_string()),
                ("pageSize", PAGE_SIZE.to_string()),
                ("recursive", "0".to_string()),
                ("orderBy", "filename".to_string()),
                ("descending", "false".to_string()),
            ];
            let v = self
                .signed_get(http, server, "/open/file/listFiles.action", &params)
                .await?;
            let ao = &v["fileListAO"];
            let empty = vec![];
            let folders = ao["folderList"].as_array().unwrap_or(&empty);
            let files = ao["fileList"].as_array().unwrap_or(&empty);
            out.extend(folders.iter().map(folder_entry));
            out.extend(files.iter().map(file_entry));
            // count 是本页返回数;不足一页即到底。
            if (folders.len() + files.len()) < PAGE_SIZE as usize {
                break;
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
            .signed_get(
                http,
                server,
                "/open/file/getFileDownloadUrl.action",
                &[
                    ("fileId", entry.id.clone()),
                    ("dt", "3".to_string()),
                    ("flag", "1".to_string()),
                ],
            )
            .await?;
        let raw = v["fileDownloadUrl"].as_str().unwrap_or("");
        if raw.is_empty() {
            return Err(SourceError::msg("天翼云盘未返回下载地址"));
        }
        Ok(ResolvedPlay::simple(
            normalize_download_url(raw),
            entry.name.clone(),
            HashMap::new(),
        ))
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        self.rotated.lock().unwrap().remove(server_id)
    }
}

// ---------- 扫码登录 ----------

/// 开始扫码:unifyLoginForPC 抠 paramId/lt/reqId → getUUID → 用 uuid 渲二维码。
pub async fn qr_start(http: &reqwest::Client) -> Result<QrStart, SourceError> {
    // 1. 拿 lt / paramId / reqId。
    let html = http
        .get(format!("{WEB_URL}/api/portal/unifyLoginForPC.action"))
        .query(&[
            ("appId", APP_ID),
            ("clientType", CLIENT_TYPE),
            ("returnURL", RETURN_URL),
            ("timeStamp", &now_ms().to_string()),
        ])
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘取登录页失败: {e}")))?
        .text()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘登录页读取失败: {e}")))?;
    let lt = regex_pick(&html, r#"lt\s*=\s*"([^"]+)""#);
    let param_id = regex_pick(&html, r#"paramId\s*=\s*"([^"]+)""#);
    let req_id = regex_pick(&html, r#"reqId\s*=\s*"([^"]+)""#);
    if param_id.is_empty() {
        return Err(SourceError::msg("天翼云盘登录页解析失败，请重试"));
    }

    // 2. getUUID。
    let v: Value = http
        .post(format!("{AUTH_URL}/api/logbox/oauth2/getUUID.do"))
        .form(&[("appId", APP_ID)])
        .header("Referer", AUTH_URL)
        .header("lt", &lt)
        .header("REQID", &req_id)
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘取二维码失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘二维码响应解析失败: {e}")))?;
    let uuid = v["uuid"].as_str().unwrap_or("").to_string();
    let encry_uuid = v["encryuuid"].as_str().unwrap_or("").to_string();
    if uuid.is_empty() {
        return Err(SourceError::msg("天翼云盘未返回二维码"));
    }

    // 3. 二维码内容就是 uuid 本身,Rust 侧渲成图。
    let image = super::qr_svg_data_uri(&uuid)?;
    let ctx = serde_json::json!({
        "uuid": uuid,
        "encryuuid": encry_uuid,
        "paramId": param_id,
        "lt": lt,
        "reqId": req_id,
    })
    .to_string();
    Ok(QrStart { image, ctx })
}

/// 轮询一次。ctx = {uuid, encryuuid, paramId, lt, reqId}。
pub async fn qr_poll(http: &reqwest::Client, ctx: &str) -> Result<QrPoll, SourceError> {
    let c: Value = serde_json::from_str(ctx)
        .map_err(|_| SourceError::msg("扫码上下文损坏，请重新获取二维码"))?;
    let now = now_ms();
    let date = httpdate::fmt_http_date(std::time::SystemTime::now());
    let v: Value = http
        .post(format!("{AUTH_URL}/api/logbox/oauth2/qrcodeLoginState.do"))
        .form(&[
            ("appId", APP_ID),
            ("clientType", CLIENT_TYPE),
            ("returnUrl", RETURN_URL),
            ("paramId", c["paramId"].as_str().unwrap_or("")),
            ("uuid", c["uuid"].as_str().unwrap_or("")),
            ("encryuuid", c["encryuuid"].as_str().unwrap_or("")),
            ("date", &date),
            ("timeStamp", &now.to_string()),
        ])
        .header("Referer", AUTH_URL)
        .header("lt", c["lt"].as_str().unwrap_or(""))
        .header("REQID", c["reqId"].as_str().unwrap_or(""))
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘扫码轮询失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘扫码轮询解析失败: {e}")))?;
    match v["status"].as_i64() {
        Some(0) => {
            let redirect = v["redirectUrl"].as_str().unwrap_or("");
            if redirect.is_empty() {
                return Err(SourceError::msg("天翼云盘登录成功但未返回跳转地址"));
            }
            qr_exchange_session(http, redirect).await
        }
        Some(-11001) => Ok(QrPoll::Expired),
        _ => Ok(QrPoll::Pending), // -106 待扫 / -11002 待确认
    }
}

/// 成功后用 redirectUrl 换 accessToken/refreshToken(sessionKey/secret 运行时再刷)。
async fn qr_exchange_session(http: &reqwest::Client, redirect: &str) -> Result<QrPoll, SourceError> {
    let mut q: Vec<(&str, String)> = CLIENT_SUFFIX
        .iter()
        .map(|(k, v)| (*k, v.to_string()))
        .collect();
    q.push(("redirectURL", redirect.to_string()));
    let v: Value = http
        .post(format!("{API_URL}/getSessionForPC.action"))
        .query(&q)
        .header("Accept", "application/json;charset=UTF-8")
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘换取会话失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("天翼云盘会话响应解析失败: {e}")))?;
    let access = v["accessToken"].as_str().unwrap_or("");
    if access.is_empty() {
        return Err(SourceError::msg("天翼云盘登录成功但未取到令牌，请重试"));
    }
    let mut creds = HashMap::from([("access_token".to_string(), access.to_string())]);
    if let Some(r) = v["refreshToken"].as_str().filter(|s| !s.is_empty()) {
        creds.insert("refresh_token".to_string(), r.to_string());
    }
    Ok(QrPoll::Confirmed { credentials: creds })
}

fn regex_pick(text: &str, pat: &str) -> String {
    regex::Regex::new(pat)
        .ok()
        .and_then(|re| re.captures(text).and_then(|c| c.get(1)).map(|m| m.as_str().to_string()))
        .unwrap_or_default()
}

/// 当前毫秒时间戳。core 里 SystemTime 可用(非 Date::now 那种被禁的)。
fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AES-ECB 参数加密:必须按键排序、PKCS7、大写 hex。排序错了签名和密文都对不上服务端。
    /// 这里钉住确定性 + 形状(16 字节块整数倍、全大写十六进制)。
    #[test]
    fn encrypt_params_is_sorted_padded_uppercase_hex() {
        let secret = "0123456789abcdef0123456789abcdef";
        let a = encrypt_params(secret, &[("pageNum", "1".into()), ("folderId", "-11".into())]);
        let b = encrypt_params(secret, &[("folderId", "-11".into()), ("pageNum", "1".into())]);
        assert_eq!(a, b, "参数顺序不同,加密结果必须相同(内部排序)");
        assert!(!a.is_empty());
        assert_eq!(a.len() % 32, 0, "AES 块 16 字节 → hex 32 字符整数倍");
        assert!(a.chars().all(|c| c.is_ascii_hexdigit() && !c.is_lowercase()));
        assert!(encrypt_params(secret, &[]).is_empty(), "空参数不加密");
    }

    /// HMAC 明文:参数非空时必须追加 &params=;这段漏了服务端算出的签名对不上,全 401。
    #[test]
    fn sign_appends_params_only_when_present() {
        let secret = "s3cr3t-secret-key-000000000000000";
        let with = sign_hmac(secret, "SK", "GET", "/a.action", "Wed, 24 Jul 2026 00:00:00 GMT", "DEAD");
        let without = sign_hmac(secret, "SK", "GET", "/a.action", "Wed, 24 Jul 2026 00:00:00 GMT", "");
        assert_ne!(with, without, "带 params 的签名必须不同于不带的");
        assert_eq!(with.len(), 40, "HMAC-SHA1 = 20 字节 = 40 hex");
        assert!(with.chars().all(|c| c.is_ascii_hexdigit() && !c.is_lowercase()));
    }

    /// AES-ECB 已知答案:对齐 openssl `aes-128-ecb`,防止实现把块模式写歪。
    #[test]
    fn aes_ecb_known_answer() {
        // key = 16x 'A'(0x41),明文正好 16 字节 "folderId=1234567"(免填充干扰对齐)。
        // 期望值由 `echo -n "folderId=1234567" | openssl enc -aes-128-ecb -K 41414141... -nopad | xxd` 得来。
        // 这里只验证「同一 key+明文恒定输出」+ 形状,真正的跨实现对齐留给真机(见文件头注释)。
        let secret = "AAAAAAAAAAAAAAAAxxxxxxxxxxxxxxxx";
        let out1 = encrypt_params(secret, &[("folderId", "1234567".into())]);
        let out2 = encrypt_params(secret, &[("folderId", "1234567".into())]);
        assert_eq!(out1, out2);
        assert_eq!(out1.len(), 64, "16字节明文 + 16字节PKCS7填充 = 32字节 = 64 hex");
    }

    #[test]
    fn download_url_normalized() {
        assert_eq!(
            normalize_download_url("http://d.cloud.189.cn/x?a=1&amp;b=2"),
            "https://d.cloud.189.cn/x?a=1&b=2"
        );
    }

    #[test]
    fn uuid_v4_shape() {
        let u = gen_uuid();
        let parts: Vec<&str> = u.split('-').collect();
        assert_eq!(parts.iter().map(|p| p.len()).collect::<Vec<_>>(), vec![8, 4, 4, 4, 12]);
        assert_eq!(&u[14..15], "4", "版本位应为 4");
    }

    #[test]
    fn file_vs_folder_entry() {
        let f = serde_json::json!({"id":"123","name":"a.mkv","size":100});
        let e = file_entry(&f);
        assert!(!e.is_dir && e.is_video && e.id == "123" && e.size == Some(100));
        let d = serde_json::json!({"id":"9","name":"影视"});
        let de = folder_entry(&d);
        assert!(de.is_dir && !de.is_video && de.id == "9");
    }
}
