// 阿里云盘后端。**网页版 API 路线** —— 2026-07-24 从 oplist 开放平台路线整体迁过来
// (oplist 在线中继实测已死,见 [[netdisk-sources-via-oplist]] 作废说明)。
//
// 拿不到开放平台 token(那要开发者 App),只能走网页版 api.aliyundrive.com,代价是必须复刻
// 2023-02-13 起强制的 `x-signature`:
//   secp256k1 ECDSA(SHA256 预哈希)对 "{AppId}:{DeviceId}:{UserId}:{Nonce}" 签名,
//   输出 hex(r‖s)+"01";公钥(未压缩 04‖x‖y)先经 create_session 注册到 device_id 上。
//   算法逐字节抄自 tickstep/aliyunpan-api(Go)+ 其 secp256k1 库,曲线/预哈希/字节序都核过。
//
// 登录:passport.aliyundrive.com 扫码 → bizExt 里抠 refresh_token(见 qr_start/qr_poll)。
// 根目录列两个盘(资源库/备份盘):只挑一个的话,文件在另一个盘的用户会看到空目录且无从察觉。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, PlayQuality, QrPoll, QrStart,
    ResolvedPlay, SourceEntry, SourceError, SourceKind, SourceServer,
};
use k256::ecdsa::{signature::Signer, Signature, SigningKey};
use rand::RngCore;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

const AUTH_URL: &str = "https://auth.aliyundrive.com";
const API_URL: &str = "https://api.aliyundrive.com";
const USER_URL: &str = "https://user.aliyundrive.com";
const PASSPORT: &str = "https://passport.aliyundrive.com";
/// token 刷新的 api_id、签名用的 AppId:tickstep 源码里的网页端常量,非开发者凭据。
const API_ID: &str = "pJZInNHN2dZWk8qg";
const APP_ID: &str = "25dzX3vbYqktVxyX";
const DOWNLOAD_REFERER: &str = "https://www.aliyundrive.com/";
const PAGE_LIMIT: i64 = 100;
const MAX_PAGES: usize = 400;
/// 直链有效期。取上限附近,减少长片播到一半失效的概率(过期仍有 watchdog 兜底)。
const DOWNLOAD_EXPIRE_SEC: i64 = 14400;

const ORIGIN_ID: &str = "origin";

/// 转码档位 → 展示名 + 权重。与夸克的 quality_meta 同构,保证两个源的档位排序一致。
fn template_meta(t: &str) -> (String, i32) {
    match t.to_lowercase().as_str() {
        "ld" => ("流畅 360P".into(), 1),
        "sd" => ("标清 480P".into(), 2),
        "hd" => ("高清 720P".into(), 3),
        "fhd" => ("超清 1080P".into(), 4),
        "qhd" => ("2K".into(), 5),
        "uhd" | "4k" => ("4K".into(), 6),
        "" => ("默认".into(), 0),
        other => (other.to_uppercase(), 0),
    }
}

/// 一次会话签名到手后的可复用状态。x-signature 是 per-session 的(nonce 固定 0,
/// CalcNextSignature 在源码里注释掉了),换会话才重签。
#[derive(Clone)]
struct Session {
    access_token: String,
    device_id: String,
    signature: String,
}

#[derive(Default)]
pub struct AliyunDriveBackend {
    /// server.id -> 会话
    session: Mutex<HashMap<String, Session>>,
    /// server.id -> [(drive_id, 展示名)]
    drives: Mutex<HashMap<String, Vec<(String, String)>>>,
    /// server.id -> 待落盘凭据(轮换后的 refresh_token / 首次生成的 device_id)
    rotated: Mutex<HashMap<String, HashMap<String, String>>>,
}

impl AliyunDriveBackend {
    pub fn new() -> Self {
        Self::default()
    }

    fn current_refresh(server: &SourceServer) -> String {
        server
            .extra
            .get("refresh_token")
            .cloned()
            .or_else(|| server.token.clone())
            .unwrap_or_default()
    }

    fn record_rotated(&self, server_id: &str, key: &str, val: &str) {
        self.rotated
            .lock()
            .unwrap()
            .entry(server_id.to_string())
            .or_default()
            .insert(key.to_string(), val.to_string());
    }

    /// 建立会话:刷 token → 生成密钥 → create_session 注册公钥 → 得到 x-signature。
    async fn build_session(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Session, SourceError> {
        let refresh = Self::current_refresh(server);
        if refresh.is_empty() {
            return Err(SourceError::auth("尚未登录，请扫码登录阿里云盘"));
        }
        // 1. 刷 token。
        let tok: Value = http
            .post(format!("{AUTH_URL}/v2/account/token"))
            .json(&json!({
                "refresh_token": refresh,
                "api_id": API_ID,
                "grant_type": "refresh_token",
            }))
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("阿里云盘刷新令牌失败: {e}")))?
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("阿里云盘令牌响应解析失败: {e}")))?;
        let access = tok["access_token"].as_str().unwrap_or("").to_string();
        let user_id = tok["user_id"].as_str().unwrap_or("").to_string();
        if access.is_empty() {
            let msg = tok["message"].as_str().unwrap_or("登录已失效，请重新扫码登录");
            return Err(SourceError::auth(msg.to_string()));
        }
        // refresh_token 会轮换,旧值当场作废 —— 变了就记下待落盘。
        if let Some(new_refresh) = tok["refresh_token"].as_str() {
            if !new_refresh.is_empty() && new_refresh != refresh {
                self.record_rotated(&server.id, "refresh_token", new_refresh);
            }
        }

        // 2. device_id:持久化,没有就生成一次并记下待落盘。
        let device_id = match server.extra.get("device_id").filter(|s| !s.is_empty()) {
            Some(d) => d.clone(),
            None => {
                let d = gen_device_id();
                self.record_rotated(&server.id, "device_id", &d);
                d
            }
        };

        // 3. 生成 secp256k1 密钥 + 签名。
        let key = gen_signing_key();
        let pub_hex = public_key_hex(&key);
        let signature = make_signature(&key, &device_id, &user_id, 0);

        // 4. create_session 注册公钥(签名/设备绑定)。失败要抛 —— 不注册后续全 401。
        let resp: Value = http
            .post(format!("{API_URL}/users/v1/users/device/create_session"))
            .bearer_auth(&access)
            .header("x-device-id", &device_id)
            .header("x-signature", &signature)
            .json(&json!({
                "deviceName": "LinPlayer",
                "modelName": "Windows",
                "pubKey": pub_hex,
            }))
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("阿里云盘会话建立失败: {e}")))?
            .json()
            .await
            .unwrap_or(Value::Null);
        // success=false 时给出人话;但有的返回体没有 success 字段,只要没报错就放行。
        if resp["success"].as_bool() == Some(false) {
            let msg = resp["message"].as_str().unwrap_or("会话建立失败，请重新登录");
            return Err(SourceError::auth(msg.to_string()));
        }

        let sess = Session { access_token: access, device_id, signature };
        self.session.lock().unwrap().insert(server.id.clone(), sess.clone());
        Ok(sess)
    }

    async fn session(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        force: bool,
    ) -> Result<Session, SourceError> {
        if !force {
            if let Some(s) = self.session.lock().unwrap().get(&server.id) {
                return Ok(s.clone());
            }
        }
        self.build_session(http, server).await
    }

    async fn post(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        base: &str,
        path: &str,
        body: Value,
    ) -> Result<Value, SourceError> {
        let url = format!("{base}{path}");
        let mut forced = false;
        loop {
            let sess = self.session(http, server, forced).await?;
            let resp = http
                .post(&url)
                .bearer_auth(&sess.access_token)
                .header("x-device-id", &sess.device_id)
                .header("x-signature", &sess.signature)
                .header("Content-Type", "application/json")
                .json(&body)
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("阿里云盘请求失败: {e}")))?;
            let status = resp.status();
            // 401(token 过期)或设备签名失效都重建一次会话。
            if (status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::BAD_REQUEST)
                && !forced
            {
                let v: Value = resp.json().await.unwrap_or(Value::Null);
                let code = v["code"].as_str().unwrap_or("");
                if status == reqwest::StatusCode::UNAUTHORIZED
                    || code.contains("Device")
                    || code.contains("Signature")
                    || code.contains("Token")
                {
                    self.session.lock().unwrap().remove(&server.id);
                    forced = true;
                    continue;
                }
                // 其它 400 原样报出去。
                let msg = v["message"].as_str().unwrap_or("阿里云盘请求失败");
                return Err(SourceError::msg(msg.to_string()));
            }
            let v: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("阿里云盘响应解析失败({status}): {e}")))?;
            if !status.is_success() {
                let msg = v["message"].as_str().or_else(|| v["code"].as_str());
                let msg = if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
                    "阿里云盘限流，请稍后再试".to_string()
                } else {
                    msg.unwrap_or("阿里云盘请求失败").to_string()
                };
                return Err(SourceError {
                    message: msg,
                    is_auth: status == reqwest::StatusCode::UNAUTHORIZED,
                });
            }
            return Ok(v);
        }
    }

    /// 取该账号的盘列表(资源库/备份盘),带缓存。
    async fn drive_list(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Vec<(String, String)>, SourceError> {
        if let Some(d) = self.drives.lock().unwrap().get(&server.id) {
            if !d.is_empty() {
                return Ok(d.clone());
            }
        }
        if let Some(fixed) = server.extra.get("drive_id").filter(|s| !s.is_empty()) {
            let list = vec![(fixed.clone(), "我的云盘".to_string())];
            self.drives.lock().unwrap().insert(server.id.clone(), list.clone());
            return Ok(list);
        }
        let v = self.post(http, server, USER_URL, "/v2/user/get", json!({})).await?;
        let mut list = Vec::new();
        let push = |key: &str, label: &str, list: &mut Vec<(String, String)>| {
            if let Some(id) = v[key].as_str().filter(|s| !s.is_empty()) {
                if !list.iter().any(|(d, _)| d == id) {
                    list.push((id.to_string(), label.to_string()));
                }
            }
        };
        push("resource_drive_id", "资源库", &mut list);
        push("backup_drive_id", "备份盘", &mut list);
        push("default_drive_id", "我的云盘", &mut list);
        if list.is_empty() {
            return Err(SourceError::auth("未取到云盘信息，请重新登录"));
        }
        self.drives.lock().unwrap().insert(server.id.clone(), list.clone());
        Ok(list)
    }

    async fn list_in_drive(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        drive_id: &str,
        parent: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let mut out = Vec::new();
        let mut marker = String::new();
        for _ in 0..MAX_PAGES {
            let mut body = json!({
                "drive_id": drive_id,
                "parent_file_id": parent,
                "limit": PAGE_LIMIT,
                "all": false,
                "url_expire_sec": 1600,
                "fields": "*",
                "order_by": "name",
                "order_direction": "ASC",
            });
            if !marker.is_empty() {
                body["marker"] = json!(marker);
            }
            let v = self
                .post(http, server, API_URL, "/adrive/v3/file/list", body)
                .await?;
            if let Some(items) = v["items"].as_array() {
                out.extend(items.iter().map(|i| item_to_entry(i, drive_id)));
            }
            match v["next_marker"].as_str().filter(|s| !s.is_empty()) {
                Some(m) => marker = m.to_string(),
                None => break,
            }
        }
        Ok(out)
    }
}

/// entry.id 编码成 `drive_id:file_id` —— 阿里云盘所有接口都要 drive_id,
/// 而 trait 只传得回一个 id 字符串。
fn encode_id(drive_id: &str, file_id: &str) -> String {
    format!("{drive_id}:{file_id}")
}

fn decode_id(id: &str) -> Option<(&str, &str)> {
    let (d, f) = id.split_once(':')?;
    (!d.is_empty() && !f.is_empty()).then_some((d, f))
}

fn item_to_entry(m: &Value, drive_id: &str) -> SourceEntry {
    let is_dir = m["type"].as_str() == Some("folder");
    let name = m["name"].as_str().unwrap_or("").to_string();
    let is_video =
        !is_dir && (m["category"].as_str() == Some("video") || is_video_file_name(&name));
    let owner = m["drive_id"].as_str().filter(|s| !s.is_empty()).unwrap_or(drive_id);
    SourceEntry {
        id: encode_id(owner, m["file_id"].as_str().unwrap_or("")),
        name,
        is_dir,
        is_video,
        size: m["size"].as_i64(),
        thumb_url: m["thumbnail"].as_str().map(|s| s.to_string()),
        raw: None,
    }
}

// ---------- secp256k1 x-signature ----------

fn gen_signing_key() -> SigningKey {
    let mut b = [0u8; 32];
    loop {
        rand::rng().fill_bytes(&mut b);
        // 私钥必须落在 [1, n) 区间,超界或全零极罕见,重摇即可。
        if let Ok(k) = SigningKey::from_slice(&b) {
            return k;
        }
    }
}

/// 未压缩公钥 hex:04‖x‖y = 130 个 hex 字符。create_session 的 pubKey 就是它。
fn public_key_hex(key: &SigningKey) -> String {
    let vk = key.verifying_key();
    hex::encode(vk.to_encoded_point(false).as_bytes())
}

/// 签名:SHA256("{AppId}:{DeviceId}:{UserId}:{Nonce}") 后 ECDSA,输出 hex(r‖s)+"01"。
fn make_signature(key: &SigningKey, device_id: &str, user_id: &str, nonce: i32) -> String {
    let data = format!("{APP_ID}:{device_id}:{user_id}:{nonce}");
    // SigningKey 默认摘要就是 SHA256,sign() 内部先哈希再签,与 Go 侧一致。
    let sig: Signature = key.sign(data.as_bytes());
    format!("{}01", hex::encode(sig.to_bytes()))
}

fn gen_device_id() -> String {
    const CS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut r = rand::rng();
    (0..24)
        .map(|_| CS[(r.next_u32() as usize) % CS.len()] as char)
        .collect()
}

#[async_trait::async_trait]
impl MediaSourceBackend for AliyunDriveBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::aliyundrive()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let drives = self.drive_list(http, server).await?;
        let Some(d) = dir_id.filter(|d| !d.is_empty()) else {
            if drives.len() == 1 {
                let (id, _) = &drives[0];
                let mut e = self.list_in_drive(http, server, id, "root").await?;
                sort_entries(&mut e);
                return Ok(e);
            }
            return Ok(drives
                .iter()
                .map(|(id, label)| SourceEntry {
                    id: encode_id(id, "root"),
                    name: label.clone(),
                    is_dir: true,
                    is_video: false,
                    size: None,
                    thumb_url: None,
                    raw: None,
                })
                .collect());
        };
        let (drive_id, file_id) = decode_id(d).ok_or_else(|| SourceError::msg("目录标识不合法"))?;
        let mut e = self.list_in_drive(http, server, drive_id, file_id).await?;
        sort_entries(&mut e);
        Ok(e)
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let drives = self.drive_list(http, server).await?;
        let mut out = Vec::new();
        for (drive_id, _) in &drives {
            let q = format!(
                "name match \"{}\"",
                query.replace('\\', "\\\\").replace('"', "\\\"")
            );
            let v = self
                .post(
                    http,
                    server,
                    API_URL,
                    "/adrive/v3/file/search",
                    json!({ "drive_id": drive_id, "query": q, "limit": PAGE_LIMIT }),
                )
                .await?;
            if let Some(items) = v["items"].as_array() {
                out.extend(items.iter().map(|i| item_to_entry(i, drive_id)));
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
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let (drive_id, file_id) =
            decode_id(&entry.id).ok_or_else(|| SourceError::msg("文件标识不合法"))?;

        // 直链要带 Referer 才能取到字节。
        let mut dl_headers = HashMap::new();
        dl_headers.insert("Referer".to_string(), DOWNLOAD_REFERER.to_string());

        let mut qualities = vec![PlayQuality {
            id: ORIGIN_ID.to_string(),
            label: "原画".to_string(),
            rank: 100,
        }];
        let mut transcoded: Vec<(String, String)> = Vec::new();
        if let Ok(v) = self
            .post(
                http,
                server,
                API_URL,
                "/adrive/v2/file/get_video_preview_play_info",
                json!({
                    "drive_id": drive_id,
                    "file_id": file_id,
                    "category": "live_transcoding",
                    "template_id": "",
                }),
            )
            .await
        {
            let empty = vec![];
            for t in v["video_preview_play_info"]["live_transcoding_task_list"]
                .as_array()
                .unwrap_or(&empty)
            {
                if t["status"].as_str() != Some("finished") {
                    continue;
                }
                let (Some(tpl), Some(url)) = (t["template_id"].as_str(), t["url"].as_str()) else {
                    continue;
                };
                if url.is_empty() {
                    continue;
                }
                let (label, rank) = template_meta(tpl);
                qualities.push(PlayQuality { id: tpl.to_string(), label, rank });
                transcoded.push((tpl.to_string(), url.to_string()));
            }
        }
        qualities.sort_by(|a, b| b.rank.cmp(&a.rank));

        if let Some(qid) = quality_id.filter(|q| *q != ORIGIN_ID) {
            if let Some((_, url)) = transcoded.iter().find(|(t, _)| t == qid) {
                return Ok(ResolvedPlay {
                    url: url.clone(),
                    title: entry.name.clone(),
                    http_headers: dl_headers,
                    user_agent_override: None,
                    subtitles: vec![],
                    qualities,
                    selected_quality_id: Some(qid.to_string()),
                });
            }
        }

        let v = self
            .post(
                http,
                server,
                API_URL,
                "/v2/file/get_download_url",
                json!({
                    "drive_id": drive_id,
                    "file_id": file_id,
                    "expire_sec": DOWNLOAD_EXPIRE_SEC,
                }),
            )
            .await?;
        let url = v["url"].as_str().or_else(|| v["cdn_url"].as_str()).unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("阿里云盘未返回下载地址"));
        }
        Ok(ResolvedPlay {
            url: url.to_string(),
            title: entry.name.clone(),
            http_headers: dl_headers,
            user_agent_override: None,
            subtitles: vec![],
            qualities,
            selected_quality_id: Some(ORIGIN_ID.to_string()),
        })
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        self.rotated.lock().unwrap().remove(server_id)
    }
}

// ---------- 扫码登录:passport 出码 → 轮询 → bizExt 抠 refresh_token ----------

/// 开始扫码:generate.do 拿 codeContent(要渲成二维码)+ t/ck(轮询用)。
pub async fn qr_start(http: &reqwest::Client) -> Result<QrStart, SourceError> {
    let v: Value = http
        .get(format!("{PASSPORT}/newlogin/qrcode/generate.do"))
        .query(&[
            ("appName", "aliyun_drive"),
            ("fromSite", "52"),
            ("appEntrance", "web"),
            ("_bx-v", "2.2.3"),
        ])
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("阿里云盘取二维码失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("阿里云盘二维码响应解析失败: {e}")))?;
    let data = &v["content"]["data"];
    let code_content = data["codeContent"].as_str().unwrap_or("");
    let t = data["t"].to_string(); // 数字,原样转字符串
    let ck = data["ck"].as_str().unwrap_or("");
    if code_content.is_empty() || ck.is_empty() {
        return Err(SourceError::msg("阿里云盘未返回二维码"));
    }
    let image = super::qr_svg_data_uri(code_content)?;
    let ctx = json!({ "t": t, "ck": ck }).to_string();
    Ok(QrStart { image, ctx })
}

/// 轮询一次。ctx = {t, ck}。
pub async fn qr_poll(http: &reqwest::Client, ctx: &str) -> Result<QrPoll, SourceError> {
    let c: Value = serde_json::from_str(ctx)
        .map_err(|_| SourceError::msg("扫码上下文损坏，请重新获取二维码"))?;
    let t = c["t"].as_str().unwrap_or("");
    let ck = c["ck"].as_str().unwrap_or("");
    let v: Value = http
        .post(format!("{PASSPORT}/newlogin/qrcode/query.do"))
        .query(&[("appName", "aliyun_drive"), ("fromSite", "52")])
        .form(&[("t", t), ("ck", ck), ("appName", "aliyun_drive")])
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("阿里云盘扫码轮询失败: {e}")))?
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("阿里云盘扫码轮询解析失败: {e}")))?;
    let data = &v["content"]["data"];
    match data["qrCodeStatus"].as_str().unwrap_or("") {
        "CONFIRMED" => {
            let biz = data["bizExt"].as_str().unwrap_or("");
            match extract_refresh_token(biz) {
                Some(rt) => Ok(QrPoll::Confirmed {
                    credentials: HashMap::from([("refresh_token".to_string(), rt)]),
                }),
                None => Err(SourceError::msg("阿里云盘登录成功但未取到令牌，请重试")),
            }
        }
        "EXPIRED" | "CANCELED" => Ok(QrPoll::Expired),
        _ => Ok(QrPoll::Pending), // NEW / SCANED
    }
}

/// bizExt = base64(可能 gzip 的 JSON,昵称字段可能是 GB18030)。refreshToken 本身是 ASCII,
/// 直接在 lossy 文本上正则抠,绕开整段 charset 解码。
fn extract_refresh_token(biz_ext_b64: &str) -> Option<String> {
    use base64::Engine;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(biz_ext_b64)
        .ok()?;
    // gzip 魔数 1f 8b:解压;否则当明文。
    let bytes = if raw.starts_with(&[0x1f, 0x8b]) {
        use std::io::Read;
        let mut d = flate2::read::GzDecoder::new(&raw[..]);
        let mut out = Vec::new();
        d.read_to_end(&mut out).ok()?;
        out
    } else {
        raw
    };
    let s = String::from_utf8_lossy(&bytes);
    let re = regex::Regex::new(r#""refreshToken"\s*:\s*"([^"]+)""#).ok()?;
    re.captures(&s)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .filter(|t| !t.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_roundtrips_drive_and_file() {
        let id = encode_id("d1", "f2");
        assert_eq!(id, "d1:f2");
        assert_eq!(decode_id(&id), Some(("d1", "f2")));
        for bad in ["", ":", "d1:", ":f2", "nosep"] {
            assert_eq!(decode_id(bad), None, "{bad} 不该被当成合法标识");
        }
    }

    #[test]
    fn item_prefers_its_own_drive_id() {
        let cross = json!({"type":"file","name":"a.mkv","file_id":"f9","drive_id":"other"});
        assert_eq!(item_to_entry(&cross, "ctx").id, "other:f9");
        let plain = json!({"type":"file","name":"a.mkv","file_id":"f9"});
        assert_eq!(item_to_entry(&plain, "ctx").id, "ctx:f9");
    }

    #[test]
    fn category_or_extension_marks_video() {
        let by_cat = json!({"type":"file","name":"noext","file_id":"1","category":"video"});
        assert!(item_to_entry(&by_cat, "d").is_video);
        let by_ext = json!({"type":"file","name":"x.mkv","file_id":"1"});
        assert!(item_to_entry(&by_ext, "d").is_video);
        let folder = json!({"type":"folder","name":"dir","file_id":"1","category":"video"});
        let e = item_to_entry(&folder, "d");
        assert!(e.is_dir && !e.is_video, "目录不该被 category 误判成视频");
    }

    #[test]
    fn origin_outranks_every_transcode_template() {
        let mut q = vec![
            PlayQuality { id: ORIGIN_ID.into(), label: "原画".into(), rank: 100 },
            PlayQuality { id: "FHD".into(), label: template_meta("FHD").0, rank: template_meta("FHD").1 },
            PlayQuality { id: "LD".into(), label: template_meta("LD").0, rank: template_meta("LD").1 },
        ];
        q.sort_by(|a, b| b.rank.cmp(&a.rank));
        assert_eq!(q[0].id, ORIGIN_ID);
        assert_eq!(q[1].id, "FHD");
        assert_eq!(template_meta("fhd").0, "超清 1080P", "档位名大小写不敏感");
    }

    /// 公钥必须是未压缩 04‖x‖y = 130 hex;签名必须是 128 hex + "01" = 130 字符。
    /// 长度/前缀错了,create_session 直接拒,后续全 401。
    #[test]
    fn signature_and_pubkey_have_exact_shape() {
        let key = gen_signing_key();
        let pk = public_key_hex(&key);
        assert_eq!(pk.len(), 130, "未压缩公钥应为 130 hex");
        assert!(pk.starts_with("04"), "未压缩公钥必须 04 前缀");

        let sig = make_signature(&key, "DEV123", "USER456", 0);
        assert_eq!(sig.len(), 130, "签名应为 128 hex + 01");
        assert!(sig.ends_with("01"), "签名必须以 01 收尾");
        assert!(sig[..128].chars().all(|c| c.is_ascii_hexdigit()));
    }

    /// device_id 24 位字母数字,持久化的形状不能变。
    #[test]
    fn device_id_is_24_alnum() {
        let d = gen_device_id();
        assert_eq!(d.len(), 24);
        assert!(d.chars().all(|c| c.is_ascii_alphanumeric()));
    }

    /// bizExt 明文与 gzip 两种形态都要能抠出 refreshToken(GB18030 昵称不能挡道)。
    #[test]
    fn extract_refresh_token_handles_plain_and_gzip() {
        use base64::Engine;
        use std::io::Write;
        let json_txt = r#"{"pds_login_result":{"nickName":"张三","refreshToken":"rt-abc-123"}}"#;
        // 明文 base64
        let plain_b64 = base64::engine::general_purpose::STANDARD.encode(json_txt.as_bytes());
        assert_eq!(extract_refresh_token(&plain_b64).as_deref(), Some("rt-abc-123"));
        // gzip base64
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(json_txt.as_bytes()).unwrap();
        let gz = enc.finish().unwrap();
        let gz_b64 = base64::engine::general_purpose::STANDARD.encode(&gz);
        assert_eq!(extract_refresh_token(&gz_b64).as_deref(), Some("rt-abc-123"));
        // 无 token 返回 None
        let empty_b64 = base64::engine::general_purpose::STANDARD.encode(b"{}");
        assert_eq!(extract_refresh_token(&empty_b64), None);
    }
}
