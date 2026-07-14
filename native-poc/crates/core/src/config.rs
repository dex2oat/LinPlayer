// 应用配置 + 服务器账号持久化。
// Phase 1:落地"重启免登"——把登录后的 token/user 存盘,下次启动直接进库。
// ponytail: token 目前明文存 config.json(与 PoC 同等安全姿态);是否升级 OS 钥匙串(keyring)见交付说明的待决项。
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 一个已登录的服务器账号。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Account {
    pub server: String, // 归一化后不带尾斜杠
    pub token: String,
    pub user_id: String,
    pub user_name: String,
}

/// 播放偏好(语言选轨)。
#[derive(Serialize, Deserialize, Clone)]
pub struct Prefs {
    pub audio_lang: Option<String>,
    pub sub_lang: Option<String>,
    pub sub_enabled: bool,
}
impl Default for Prefs {
    fn default() -> Self {
        Self { audio_lang: None, sub_lang: None, sub_enabled: true }
    }
}

/// 自建弹幕服务器(兼容弹弹Play /api/v2 接口)。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct DanmakuServer {
    pub api_url: String,
    pub auth_type: String, // none | pathToken | headerToken | queryToken
    pub token: String,
}

/// 用户自定义代理(三端通用)。type 为 none 时不启用。
/// HTTP/HTTPS 走 CONNECT 隧道;SOCKS5 依赖 reqwest "socks" 特性。
/// ⚠️ libmpv 仅支持 HTTP 代理(http-proxy),SOCKS 只对 API/图片/字幕/下载生效。
#[derive(Serialize, Deserialize, Clone, PartialEq)]
pub struct ProxyConfig {
    #[serde(rename = "type")]
    pub type_: String, // none | http | https | socks5 | socks4
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    /// 是否让媒体流(mpv 播放)也走代理(仅 HTTP 系列有效)。
    #[serde(default = "default_true")]
    pub proxy_media: bool,
}
fn default_true() -> bool {
    true
}
impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            type_: "none".into(),
            host: String::new(),
            port: 0,
            username: String::new(),
            password: String::new(),
            proxy_media: true,
        }
    }
}
impl ProxyConfig {
    pub fn is_enabled(&self) -> bool {
        self.type_ != "none" && !self.host.trim().is_empty() && self.port > 0
    }
    fn is_http(&self) -> bool {
        self.type_ == "http" || self.type_ == "https"
    }
    /// reqwest/mpv 用的代理 URL(如 socks5://user:pass@host:port);未启用返回 None。
    pub fn proxy_url(&self) -> Option<String> {
        if !self.is_enabled() {
            return None;
        }
        let scheme = match self.type_.as_str() {
            "http" | "https" => "http",
            "socks5" => "socks5",
            "socks4" => "socks4a",
            _ => return None,
        };
        let auth = if self.username.is_empty() {
            String::new()
        } else {
            format!(
                "{}:{}@",
                urlencoding::encode(&self.username),
                urlencoding::encode(&self.password)
            )
        };
        Some(format!("{scheme}://{auth}{}:{}", self.host, self.port))
    }
    /// mpv http-proxy 值(仅 HTTP 系列 + 开启 proxy_media)。
    pub fn mpv_http_proxy(&self) -> Option<String> {
        if self.is_enabled() && self.is_http() && self.proxy_media {
            self.proxy_url()
        } else {
            None
        }
    }
}

#[derive(Serialize, Deserialize, Default)]
pub struct AppConfig {
    /// 每安装稳定不变的设备 ID(Emby DeviceId 用,影响会话/上报归属)。
    pub device_id: String,
    pub accounts: Vec<Account>,
    /// 当前活跃账号在 accounts 中的下标。
    pub active: Option<usize>,
    /// 播放偏好;serde(default) 兼容旧配置文件。
    #[serde(default)]
    pub prefs: Prefs,
    #[serde(default)]
    pub danmaku: DanmakuServer,
    #[serde(default)]
    pub proxy: ProxyConfig,
    /// 已连接的 Trakt 账号(令牌);None=未连接。ponytail: 与其它 token 同为明文,加固待 keyring。
    #[serde(default)]
    pub sync_trakt: Option<crate::sync::SyncAccount>,
}

fn config_path() -> PathBuf {
    let dir = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LinPlayer");
    dir.join("config.json")
}

fn gen_device_id() -> String {
    // 首次运行生成一个稳定 ID:安装时的纳秒时间戳足够唯一,之后持久化不变。
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("linplayer-{n:x}")
}

impl AppConfig {
    /// 读盘;不存在则建默认。保证 device_id 非空(新生成则立即落盘)。
    pub fn load() -> Self {
        let mut cfg: AppConfig = std::fs::read_to_string(config_path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        if cfg.device_id.is_empty() {
            cfg.device_id = gen_device_id();
            cfg.save();
        }
        cfg
    }

    pub fn save(&self) {
        let path = config_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, json);
        }
    }

    pub fn active_account(&self) -> Option<&Account> {
        self.active.and_then(|i| self.accounts.get(i))
    }

    /// 按 server 去重写入(同服重登刷新 token),并设为活跃账号。
    pub fn upsert(&mut self, acc: Account) {
        match self.accounts.iter().position(|a| a.server == acc.server) {
            Some(i) => {
                self.accounts[i] = acc;
                self.active = Some(i);
            }
            None => {
                self.accounts.push(acc);
                self.active = Some(self.accounts.len() - 1);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_url_builds_scheme_and_auth() {
        let mut p = ProxyConfig { type_: "socks5".into(), host: "h".into(), port: 1080, ..Default::default() };
        assert_eq!(p.proxy_url().as_deref(), Some("socks5://h:1080"));
        p.username = "u".into();
        p.password = "p@ss".into();
        assert_eq!(p.proxy_url().as_deref(), Some("socks5://u:p%40ss@h:1080"));
        // socks 不给 mpv;http 系列才给。
        assert!(p.mpv_http_proxy().is_none());
        let h = ProxyConfig { type_: "http".into(), host: "h".into(), port: 8080, proxy_media: true, ..Default::default() };
        assert_eq!(h.mpv_http_proxy().as_deref(), Some("http://h:8080"));
        // 关闭 proxy_media → 不给 mpv。
        let h2 = ProxyConfig { proxy_media: false, ..h.clone() };
        assert!(h2.mpv_http_proxy().is_none());
        // 未启用 → None。
        assert!(ProxyConfig::default().proxy_url().is_none());
    }
}
