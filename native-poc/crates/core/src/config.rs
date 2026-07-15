// 应用配置 + 服务器账号持久化。
// Phase 1:落地"重启免登"——把登录后的 token/user 存盘,下次启动直接进库。
// ponytail: token 目前明文存 config.json(与 PoC 同等安全姿态);是否升级 OS 钥匙串(keyring)见交付说明的待决项。
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 一条备用线路(同一服务器的不同入口:直连/CDN/内网)。对齐 Dart ServerLine。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct ServerLine {
    pub id: String,
    pub name: String,
    pub url: String,
    #[serde(default)]
    pub remark: Option<String>,
}

/// 一个已登录的服务器账号。**统一承载 Emby 与浏览型源**(靠 source_kind 区分),
/// 对齐 Dart 的 ServerConfig —— 旧栈只有一张服务器表,新栈也只能有一张。
///
/// 身份键仍是 `server`(归一化后不带尾斜杠):前端既有的 server_id 参数就是它,别换。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Account {
    pub server: String, // 归一化后不带尾斜杠
    pub token: String,
    pub user_id: String,
    pub user_name: String,

    /// 显示名;空则由 [`Account::display_name`] 回落到 host。
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub remark: Option<String>,
    #[serde(default)]
    pub icon_url: Option<String>,
    /// 登录密码(可选)。用于需重新登录的场景 + 插件 emby.credentials 权限。
    #[serde(default)]
    pub password: Option<String>,
    /// 备用线路;空表示只用 `server` 本身。
    #[serde(default)]
    pub lines: Vec<ServerLine>,
    #[serde(default)]
    pub active_line: usize,
    /// 是否信任该服务器的自签名/无效 TLS 证书(不安全)。默认 false=严格校验。
    /// 仅对本服务器主机放行,不影响更新下载/WebDAV/其它主机。
    #[serde(default)]
    pub allow_insecure_tls: bool,
    /// 源类型:emby(默认)/ openlist / quark / anirss / feiniu。
    #[serde(default = "default_source_kind")]
    pub source_kind: crate::source::SourceKind,
    /// 浏览型源的连接凭据;source_kind==Emby 时为 None。
    #[serde(default)]
    pub source: Option<crate::source::SourceServer>,
}

fn default_source_kind() -> crate::source::SourceKind {
    crate::source::SourceKind::Emby
}

impl Account {
    /// 当前生效的线路地址(原始上游,**不经** CF 优选反代改写)。
    /// 对齐 Dart 的 directLineUrl:越界下标钳回合法区间,而不是 panic。
    pub fn direct_line_url(&self) -> &str {
        if self.lines.is_empty() {
            return &self.server;
        }
        let i = self.active_line.min(self.lines.len() - 1);
        &self.lines[i].url
    }

    /// 当前生效的线路地址。**会被 CF 优选反代改写**:该服务器开了优选反代时返回本地反代基址
    /// (`http://127.0.0.1:port/...`),让 API 请求与 mpv 取流都改走优选 CF IP。
    /// 需要原始上游地址(起反代自身的上游、编辑线路、展示给用户看)时用 [`Account::direct_line_url`]。
    ///
    /// 这是 CF 优选的**唯一 choke point** —— 取基址一律走这里,新增取流路径别绕开它,
    /// 否则会出现「API 走优选、取流仍走原线」这种一半生效的静默故障。
    pub fn active_line_url(&self) -> String {
        crate::net::cf::runtime::local_url_for(&self.server)
            .unwrap_or_else(|| self.direct_line_url().to_string())
    }

    /// 显示名:优先用户起的名,否则回落 host,再否则整个 URL。
    pub fn display_name(&self) -> String {
        if !self.name.trim().is_empty() {
            return self.name.clone();
        }
        self.server
            .split("://")
            .nth(1)
            .and_then(|s| s.split('/').next())
            .filter(|h| !h.is_empty())
            .unwrap_or(&self.server)
            .to_string()
    }

    pub fn is_file_browse(&self) -> bool {
        self.source_kind != crate::source::SourceKind::Emby
    }
}

/// 播放偏好(语言选轨)。
#[derive(Serialize, Deserialize, Clone)]
pub struct Prefs {
    pub audio_lang: Option<String>,
    pub sub_lang: Option<String>,
    pub sub_enabled: bool,
    /// 跨服务器续播:在别的服务器看过同一部片时,用本地记录里的最大进度起播。
    /// 默认关 —— 它会让「这台服上没看过的片」也从中间起播,得用户明确要才开。
    #[serde(default)]
    pub cross_server_resume: bool,
    /// 跨服回传主开关:看完/进度写回**其它**服务器。
    /// 默认关 —— 它会往别人的服务器写数据,必须用户主动开(对齐 Dart 默认值)。
    #[serde(default)]
    pub cross_server_writeback: bool,
    /// 回传范围:"all" 所有看过的服 / "first" 仅初次 / "latest" 仅最近。
    /// 存 wire 字符串而非枚举:Prefs 在 config 里,枚举在 watch_history 里,
    /// 这么存免得 config 反过来依赖 watch_history。取用时 WritebackRange::from_wire。
    #[serde(default = "default_writeback_range")]
    pub cross_server_writeback_range: String,
    /// 回传时是否连播放进度一起同步(关掉则只同步「已看完」标记)。默认开。
    #[serde(default = "default_true")]
    pub cross_server_writeback_progress: bool,
    /* 多线程加载(本地预取代理)开关。**默认关**。
       2026-07-15 真机实测:开着会让 Emby 直传流放不出来(有流量、黑屏、无声、永远缓冲),
       关掉立刻正常 —— 同一个包、只翻这一个开关的 A/B 对照。
       已修掉其中一个死锁(见 net/prefetch.rs 的 bump_gen),但那只是一环,整体仍不可靠:
       每次 seek 的 reset() 会 ready.clear() 把已下好的缓存全丢,而 mpv 探测 MKV 时
       (尤其带大字体附件、cues 在文件末尾的片子)会来回大跳,等于反复重下。
       它是**优化**不是功能:不确定能加速之前,绝不能默认开着换来「放不了」。
       修好并有端到端验证之前别改回 default_true。 */
    #[serde(default)]
    pub prefetch_enabled: bool,
    /// 预取并发线程数。引擎内部 clamp(2,4),这里存原值。
    #[serde(default = "default_prefetch_threads")]
    pub prefetch_threads: usize,
    /// 读前缓冲上限(字节)。默认 1GB。
    #[serde(default = "default_prefetch_cache")]
    pub prefetch_cache_bytes: u64,
}
fn default_prefetch_threads() -> usize {
    3
}
fn default_prefetch_cache() -> u64 {
    1024 * 1024 * 1024
}
fn default_writeback_range() -> String {
    "all".to_string()
}
impl Default for Prefs {
    fn default() -> Self {
        Self {
            audio_lang: None,
            sub_lang: None,
            sub_enabled: true,
            cross_server_resume: false,
            cross_server_writeback: false,
            cross_server_writeback_range: default_writeback_range(),
            cross_server_writeback_progress: true,
            prefetch_enabled: false, // 见字段上的说明:开着会放不了,修好前默认关
            prefetch_threads: default_prefetch_threads(),
            prefetch_cache_bytes: default_prefetch_cache(),
        }
    }
}

/// 自建弹幕服务器(兼容弹弹Play /api/v2 接口)。可配多个:并行分源、用户挑。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct DanmakuServer {
    /// 稳定 id(前端增删改的身份键)。旧配置迁移过来的固定为 "custom"。
    #[serde(default)]
    pub id: String,
    /// 显示名;空则前端回落 host。
    #[serde(default)]
    pub name: String,
    pub api_url: String,
    pub auth_type: String, // none | pathToken | headerToken | queryToken
    pub token: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 越小越先用(并行拉取后按它排序挑主源)。
    #[serde(default)]
    pub priority: i32,
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
    /// 旧配置的单个自建弹幕源。**只读不写**:load() 时迁进 danmaku_sources 后就不再落盘。
    /// 留着纯粹是为了老用户升级不丢源 —— 别在新代码里用它。
    #[serde(default, rename = "danmaku", skip_serializing)]
    legacy_danmaku: Option<DanmakuServer>,
    /// 自建弹幕源(可多个)。官方弹弹Play 不在这里:它靠编译期凭据,不由用户配。
    #[serde(default)]
    pub danmaku_sources: Vec<DanmakuServer>,
    #[serde(default)]
    pub proxy: ProxyConfig,
    /// 已连接的 Trakt 账号(令牌);None=未连接。ponytail: 与其它 token 同为明文,加固待 keyring。
    #[serde(default)]
    pub sync_trakt: Option<crate::sync::SyncAccount>,
    /// 已连接的 Bangumi 账号(令牌);None=未连接。
    #[serde(default)]
    pub sync_bangumi: Option<crate::sync::SyncAccount>,
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
        let mut dirty = false;
        if cfg.device_id.is_empty() {
            cfg.device_id = gen_device_id();
            dirty = true;
        }
        // 迁移:旧配置的单个自建弹幕源 -> 多源表。只在多源表还空时做,别把用户后来配的覆盖了。
        if let Some(old) = cfg.legacy_danmaku.take() {
            if cfg.danmaku_sources.is_empty() && !old.api_url.trim().is_empty() {
                cfg.danmaku_sources.push(DanmakuServer {
                    id: "custom".into(),
                    name: "自建源".into(),
                    enabled: true,
                    ..old
                });
            }
            dirty = true; // legacy 字段 skip_serializing,存一次就从盘上消失了
        }
        if dirty {
            cfg.save();
        }
        // 必须无条件同步:save() 只在 dirty 时走,干净加载时白名单会是空的 ——
        // 表现为"重启后自签名服务器全连不上,重新勾一次又好了"。
        cfg.sync_insecure_hosts();
        cfg
    }

    /// 启用的自建弹幕源,按 priority 升序。宿主据此组多源请求。
    pub fn enabled_danmaku_sources(&self) -> Vec<DanmakuServer> {
        let mut v: Vec<_> = self.danmaku_sources.iter().filter(|s| s.enabled).cloned().collect();
        v.sort_by_key(|s| s.priority);
        v
    }

    pub fn save(&self) {
        let path = config_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, json);
        }
        self.sync_insecure_hosts();
    }

    /// 把「允许自签名」的账号 host 同步进 HTTP 层白名单。
    /// 挂在 load/save 上是故意的:每条改账号的路径最后都会 save,搭在这儿就不会漏
    /// —— 漏了的后果是用户勾了"允许自签名"却连不上、或取消了勾选却还在放行,两头都不响。
    fn sync_insecure_hosts(&self) {
        let hosts = self
            .accounts
            .iter()
            .filter(|a| a.allow_insecure_tls)
            // 一个账号可能配多条线路,每条都可能是不同 host,得全放进去。
            .flat_map(|a| {
                std::iter::once(a.server.clone())
                    .chain(a.lines.iter().map(|l| l.url.clone()))
            })
            .collect::<Vec<_>>();
        crate::http::set_insecure_hosts(hosts);
    }

    pub fn active_account(&self) -> Option<&Account> {
        self.active.and_then(|i| self.accounts.get(i))
    }

    /// 按 server 去重写入(同服重登刷新 token),并设为活跃账号。
    /// 重登**保留用户侧编辑**(名称/备注/图标/线路/TLS 开关)——那些不该被一次登录冲掉。
    pub fn upsert(&mut self, acc: Account) {
        match self.accounts.iter().position(|a| a.server == acc.server) {
            Some(i) => {
                let old = &self.accounts[i];
                let merged = Account {
                    name: if acc.name.is_empty() { old.name.clone() } else { acc.name },
                    remark: acc.remark.or_else(|| old.remark.clone()),
                    icon_url: acc.icon_url.or_else(|| old.icon_url.clone()),
                    lines: if acc.lines.is_empty() { old.lines.clone() } else { acc.lines },
                    active_line: old.active_line,
                    allow_insecure_tls: old.allow_insecure_tls,
                    ..acc
                };
                self.accounts[i] = merged;
                self.active = Some(i);
            }
            None => {
                self.accounts.push(acc);
                self.active = Some(self.accounts.len() - 1);
            }
        }
    }

    pub fn find(&self, server_id: &str) -> Option<&Account> {
        self.accounts.iter().find(|a| a.server == server_id)
    }

    pub fn find_mut(&mut self, server_id: &str) -> Option<&mut Account> {
        self.accounts.iter_mut().find(|a| a.server == server_id)
    }

    /// 拖拽排序。移动后修正 active 下标,让活跃账号跟着走而不是指向别人。
    pub fn reorder(&mut self, from: usize, to: usize) -> Result<(), String> {
        let n = self.accounts.len();
        if from >= n || to >= n {
            return Err("排序下标越界".into());
        }
        let active_server = self.active_account().map(|a| a.server.clone());
        let acc = self.accounts.remove(from);
        self.accounts.insert(to, acc);
        if let Some(sv) = active_server {
            self.active = self.accounts.iter().position(|a| a.server == sv);
        }
        Ok(())
    }

    /// 删除账号;活跃账号被删则回落到第一个(空表则清空活跃)。
    pub fn remove(&mut self, server_id: &str) -> bool {
        let Some(i) = self.accounts.iter().position(|a| a.server == server_id) else {
            return false;
        };
        let was_active = self.active == Some(i);
        let active_server = self.active_account().map(|a| a.server.clone());
        self.accounts.remove(i);
        self.active = if self.accounts.is_empty() {
            None
        } else if was_active {
            Some(0)
        } else {
            // 删的是别人:靠 server 重新定位,别让下标漂移串台。
            active_server.and_then(|sv| self.accounts.iter().position(|a| a.server == sv)).or(Some(0))
        };
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acc(server: &str) -> Account {
        Account { server: server.into(), ..Default::default() }
    }

    #[test]
    fn direct_line_url_falls_back_and_clamps() {
        let mut a = acc("https://h:8096");
        // 无线路 → 用 server 本身。
        assert_eq!(a.direct_line_url(), "https://h:8096");
        a.lines = vec![
            ServerLine { id: "1".into(), name: "直连".into(), url: "https://direct".into(), remark: None },
            ServerLine { id: "2".into(), name: "CDN".into(), url: "https://cdn".into(), remark: None },
        ];
        a.active_line = 1;
        assert_eq!(a.direct_line_url(), "https://cdn");
        // 下标越界(线路被删过)→ 钳回最后一条,不 panic。
        a.active_line = 99;
        assert_eq!(a.direct_line_url(), "https://cdn");
    }

    /// CF 优选的 choke point 必须真的穿透到 Account 这一层 —— 否则改写表登记了、
    /// 取基址的人却拿不到,就是"开了优选没反应"。这条测的就是那根线通不通。
    #[test]
    fn active_line_url_is_rewritten_by_cf_runtime() {
        // 全局改写表被所有测试共享,用唯一 id 免得和别的用例串台。
        let mut a = acc("https://cf-choke-point-test.example.com");
        a.lines = vec![ServerLine {
            id: "1".into(),
            name: "CDN".into(),
            url: "https://cdn.example.com".into(),
            remark: None,
        }];
        // 未开优选 → 与 direct 一致。
        assert_eq!(a.active_line_url(), "https://cdn.example.com");

        crate::net::cf::runtime::bind(&a.server, "http://127.0.0.1:5001");
        assert_eq!(a.active_line_url(), "http://127.0.0.1:5001", "开了优选却没改写 = choke point 断了");
        // direct 必须**不受**改写影响:反代自己要拿它当上游,被改写就自环了。
        assert_eq!(a.direct_line_url(), "https://cdn.example.com");

        crate::net::cf::runtime::unbind(&a.server);
        assert_eq!(a.active_line_url(), "https://cdn.example.com", "关了优选没恢复直连");
    }

    #[test]
    fn display_name_prefers_custom_then_host() {
        let mut a = acc("https://smart.example.com/emby");
        assert_eq!(a.display_name(), "smart.example.com");
        a.name = "我的服".into();
        assert_eq!(a.display_name(), "我的服");
        // 全空白的名字不算名字。
        a.name = "   ".into();
        assert_eq!(a.display_name(), "smart.example.com");
    }

    #[test]
    fn upsert_refreshes_token_but_keeps_user_edits() {
        let mut cfg = AppConfig::default();
        cfg.upsert(Account {
            server: "https://h".into(),
            token: "old".into(),
            name: "我的服".into(),
            remark: Some("备注".into()),
            allow_insecure_tls: true,
            active_line: 1,
            lines: vec![ServerLine { id: "1".into(), name: "l".into(), url: "https://l".into(), remark: None }],
            ..Default::default()
        });
        // 重登:只带 token,不带用户编辑过的字段。
        cfg.upsert(Account { server: "https://h".into(), token: "new".into(), ..Default::default() });
        assert_eq!(cfg.accounts.len(), 1, "同服重登不该变成两条");
        let a = &cfg.accounts[0];
        assert_eq!(a.token, "new", "token 必须刷新");
        assert_eq!(a.name, "我的服", "登录不该冲掉用户起的名");
        assert_eq!(a.remark.as_deref(), Some("备注"));
        assert!(a.allow_insecure_tls, "登录不该重置 TLS 开关");
        assert_eq!(a.active_line, 1, "登录不该重置选中线路");
        assert_eq!(a.lines.len(), 1, "登录不该清空线路");
    }

    #[test]
    fn reorder_keeps_active_pointing_at_same_account() {
        let mut cfg = AppConfig::default();
        for s in ["https://a", "https://b", "https://c"] {
            cfg.upsert(acc(s));
        }
        cfg.active = Some(0); // 活跃 = a
        cfg.reorder(2, 0).unwrap(); // c 拖到最前 → [c, a, b]
        assert_eq!(cfg.accounts[0].server, "https://c");
        assert_eq!(
            cfg.active_account().unwrap().server,
            "https://a",
            "拖别人不该把活跃账号串到别的服"
        );
        assert!(cfg.reorder(0, 9).is_err(), "越界必须报错而不是 panic");
    }

    #[test]
    fn remove_relocates_active() {
        let mut cfg = AppConfig::default();
        for s in ["https://a", "https://b", "https://c"] {
            cfg.upsert(acc(s));
        }
        cfg.active = Some(2); // 活跃 = c
        assert!(cfg.remove("https://a"));
        assert_eq!(cfg.active_account().unwrap().server, "https://c", "删别人不该改活跃账号");
        // 删活跃的 → 回落第一个。
        assert!(cfg.remove("https://c"));
        assert_eq!(cfg.active_account().unwrap().server, "https://b");
        assert!(cfg.remove("https://b"));
        assert!(cfg.active.is_none(), "删空后不该留下悬空下标");
        assert!(!cfg.remove("https://nope"));
    }

    #[test]
    fn old_config_json_still_loads() {
        // 回归:老配置文件没有新字段,必须靠 serde(default) 读得进来,否则用户升级即丢账号。
        let old = r#"{"device_id":"d","accounts":[{"server":"https://h","token":"t","user_id":"u","user_name":"n"}],"active":0}"#;
        let cfg: AppConfig = serde_json::from_str(old).expect("老配置必须能读");
        assert_eq!(cfg.accounts.len(), 1);
        let a = &cfg.accounts[0];
        assert_eq!(a.token, "t");
        assert!(matches!(a.source_kind, crate::source::SourceKind::Emby), "老账号必须默认当 Emby");
        assert!(a.source.is_none());
        assert!(a.lines.is_empty());
    }

    #[test]
    fn legacy_single_danmaku_migrates_to_sources() {
        // 老配置只有一个 danmaku 对象 → 必须迁进多源表,否则用户升级即丢弹幕源。
        let old = r#"{"device_id":"d","accounts":[],"danmaku":{"api_url":"https://dm","auth_type":"pathToken","token":"tk"}}"#;
        let mut cfg: AppConfig = serde_json::from_str(old).unwrap();
        assert!(cfg.danmaku_sources.is_empty(), "迁移前多源表是空的");
        // load() 里的迁移段(这里手动跑,load 会读真实用户目录不适合单测)。
        if let Some(o) = cfg.legacy_danmaku.take() {
            if cfg.danmaku_sources.is_empty() && !o.api_url.trim().is_empty() {
                cfg.danmaku_sources.push(DanmakuServer { id: "custom".into(), enabled: true, ..o });
            }
        }
        assert_eq!(cfg.danmaku_sources.len(), 1);
        assert_eq!(cfg.danmaku_sources[0].api_url, "https://dm");
        assert_eq!(cfg.danmaku_sources[0].token, "tk");
        assert!(cfg.danmaku_sources[0].enabled, "迁移来的源必须默认启用,不然弹幕悄悄没了");
        // 迁移后不该再把 legacy 字段写回盘。
        let json = serde_json::to_string(&cfg).unwrap();
        assert!(!json.contains("\"danmaku\":"), "legacy 字段必须 skip_serializing");
        assert!(json.contains("danmaku_sources"));
    }

    #[test]
    fn enabled_danmaku_sources_filters_and_sorts() {
        let mut cfg = AppConfig::default();
        cfg.danmaku_sources = vec![
            DanmakuServer { id: "b".into(), priority: 2, enabled: true, ..Default::default() },
            DanmakuServer { id: "off".into(), priority: 0, enabled: false, ..Default::default() },
            DanmakuServer { id: "a".into(), priority: 1, enabled: true, ..Default::default() },
        ];
        let ids: Vec<_> = cfg.enabled_danmaku_sources().into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["a", "b"], "停用的要滤掉,其余按 priority 升序");
    }

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
