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
