// 同步/周边基座 —— 迁自 Dart lib/core/services/sync/ + afdian_service。
//
// 所有需要 client_secret 的令牌交换/刷新 + 爱发电订单校验都经**已部署的 CF oauth-proxy**
// (291277.xyz/api,secret 只存代理环境变量,客户端不接触)。client_id/app_id 是公开标识符,
// 以 XOR(SHA256 keystream)轻混淆存客户端(抬高 grep/strings 门槛,非绝对安全)。
//
// 本模块落地基座 + 爱发电校验(运行时可跑);Trakt/Bangumi 全生命周期(scrobble/matcher/
// calendar)是最深集成,依赖 OAuth 浏览器授权流 + 播放事件钩子,待前端补齐后接。

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub mod bangumi;
pub mod bangumi_matcher;
pub mod calendar;
pub mod trakt;

// ---------- 代理配置 ----------
pub const SYNC_PROXY_BASE: &str = "https://291277.xyz/api";
pub const SYNC_PROXY_KEY: &str = "m4cfEohhuz4u142d3w";

pub fn use_sync_proxy() -> bool {
    !SYNC_PROXY_BASE.is_empty()
}

/// 代理请求要附带的头(共享密钥)。
pub fn proxy_headers() -> Vec<(&'static str, &'static str)> {
    if SYNC_PROXY_KEY.is_empty() {
        vec![]
    } else {
        vec![("X-LinPlayer-Key", SYNC_PROXY_KEY)]
    }
}

// Bangumi 国内加速反代(官方国内常慢/不通)。
pub const BANGUMI_API_OFFICIAL: &str = "https://api.bgm.tv";
pub const BANGUMI_API_MIRROR: &str = "https://bgmapi.anibt.net";
pub const BANGUMI_OAUTH_OFFICIAL: &str = "https://bgm.tv";
// 图片反代(用户 2026-07-16:anibt 的 API 反代一直过不了 CF,但图片反代没问题)。
// 因此 API 走官方、图片单独改写到 anibt 图片反代 —— 官方图片 lain.bgm.tv 国内常不通。
pub const BANGUMI_IMG_MIRROR: &str = "https://bgmimg.anibt.net";

// ---------- OAuth 凭据轻混淆(XOR SHA256 keystream) ----------
const OBF_PASSPHRASE: &str = "LinPlayer::oauth::keystream::v1";

fn reveal(cipher: &[i32]) -> String {
    let key = Sha256::digest(OBF_PASSPHRASE.as_bytes());
    let out: Vec<u8> = cipher
        .iter()
        .enumerate()
        .map(|(i, &b)| (b as u8) ^ key[i % key.len()])
        .collect();
    String::from_utf8_lossy(&out).to_string()
}

// XOR 密文(非明文,与 Dart obfuscated_secrets 对齐;secret 已迁代理,客户端不持有)。
const TRAKT_ID: &[i32] = &[
    94, 64, 7, 107, 88, 45, 161, 24, 109, 207, 251, 44, 74, 86, 128, 57, 28, 25, 181, 219, 228,
    246, 2, 118, 33, 9, 178, 128, 140, 203, 179, 119, 12, 30, 3, 103, 92, 36, 250, 79, 111, 206,
    250, 40, 27, 0, 140, 56, 26, 76, 182, 143, 229, 240, 82, 115, 44, 95, 184, 208, 142, 157, 230,
    39,
];
const BANGUMI_ID: &[i32] = &[
    8, 31, 88, 107, 89, 35, 247, 29, 50, 150, 245, 40, 76, 85, 220, 59, 28, 72, 179, 139,
];

pub fn trakt_client_id() -> String {
    reveal(TRAKT_ID)
}
pub fn bangumi_app_id() -> String {
    reveal(BANGUMI_ID)
}

// ---------- 已连接账号令牌 ----------
#[derive(Serialize, Deserialize, Clone)]
pub struct SyncAccount {
    pub service: String, // trakt | bangumi
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    /// 过期时刻 epoch ms;None=未知/不过期。
    #[serde(default)]
    pub expires_at: Option<i64>,
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub user_id: Option<String>,
}

impl SyncAccount {
    /// 是否已过期(带 60s 安全余量)。
    pub fn is_expired(&self, now_ms: i64) -> bool {
        match self.expires_at {
            Some(exp) => now_ms > exp - 60_000,
            None => false,
        }
    }
}

// ---------- 爱发电付费校验 ----------
pub const AFDIAN_SPONSOR_URL: &str = "https://afdian.com/a/zzzwannasleep";

#[derive(Serialize, Clone, Default)]
pub struct AfdianVerifyResult {
    pub valid: bool,
    pub plan_title: String,
    pub amount: String,
    pub reason: Option<String>,
}

/// 校验爱发电订单号:订单号发给自建代理(代理持 afdian token 调 query-order),
/// 客户端不接触 token。软锁——只抬高门槛,别指望防破解。
pub async fn afdian_verify(order_no: &str) -> AfdianVerifyResult {
    let trimmed = order_no.trim();
    if trimmed.is_empty() {
        return AfdianVerifyResult { reason: Some("请输入订单号".into()), ..Default::default() };
    }
    if !use_sync_proxy() {
        return AfdianVerifyResult { reason: Some("未配置校验服务".into()), ..Default::default() };
    }
    let mut req = crate::http::client()
        .post(format!("{SYNC_PROXY_BASE}/afdian/verify"))
        .json(&serde_json::json!({ "out_trade_no": trimmed }));
    for (k, v) in proxy_headers() {
        req = req.header(k, v);
    }
    match req.send().await {
        Ok(resp) => {
            let code = resp.status().as_u16();
            match resp.json::<serde_json::Value>().await {
                Ok(j) => AfdianVerifyResult {
                    valid: j.get("valid").and_then(|v| v.as_bool()).unwrap_or(false),
                    plan_title: j.get("planTitle").map(v2s).unwrap_or_default(),
                    amount: j.get("amount").map(v2s).unwrap_or_default(),
                    reason: j.get("reason").map(v2s),
                },
                Err(_) => AfdianVerifyResult {
                    reason: Some(format!("服务返回异常:HTTP {code}")),
                    ..Default::default()
                },
            }
        }
        Err(e) => AfdianVerifyResult { reason: Some(format!("网络错误:{e}")), ..Default::default() },
    }
}

fn v2s(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reveals_plausible_client_ids() {
        // 混淆解出的应为可打印 ASCII(公开标识符),且非空。
        let t = trakt_client_id();
        let b = bangumi_app_id();
        assert!(!t.is_empty() && t.chars().all(|c| c.is_ascii_graphic()), "trakt id: {t:?}");
        assert!(!b.is_empty() && b.chars().all(|c| c.is_ascii_graphic()), "bangumi id: {b:?}");
    }

    #[test]
    fn account_expiry_with_margin() {
        let a = SyncAccount {
            service: "trakt".into(),
            access_token: "x".into(),
            refresh_token: None,
            expires_at: Some(100_000),
            username: None,
            user_id: None,
        };
        assert!(!a.is_expired(0));
        assert!(a.is_expired(100_000)); // 到点前 60s 余量内即视为过期
        let never = SyncAccount { expires_at: None, ..a.clone() };
        assert!(!never.is_expired(i64::MAX));
    }
}
