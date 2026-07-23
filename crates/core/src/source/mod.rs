// 文件浏览型数据源后端抽象(网盘/聚合/追番),对齐 Dart 的 media_source_backend.dart。
// 三件事:列目录 / 搜索(可降级)/ 把文件解析成可播 URL(含逐流 headers)。
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub mod aliyundrive;
pub mod anirss;
pub mod baidu;
pub mod dropbox;
pub mod feiniu;
pub mod googledrive;
pub mod onedrive;
pub mod openlist;
pub mod oplist;
pub mod pan115;
pub mod pan115_crypto;
pub mod plugin_source;
pub mod quark;
pub mod quark_tv;
pub mod stremio;

/// 源类型标识。**开放键**:内置源是固定小写字面量,插件贡献的源是 `plugin:<插件id>/<源id>`。
///
/// 2026-07-23 从封闭 enum 改成开放键 —— 封闭 enum 意味着加一个源必须改 Rust 重新编译,
/// 插件永远塞不进 `HashMap<SourceKind, Arc<dyn MediaSourceBackend>>` 那张分派表。
///
/// `#[serde(transparent)]` 让线上表示仍是**裸小写字符串**,与改造前逐字节相同:
/// 老配置照常读回,而且不再会因为遇到未知变体而让整份 config 反序列化失败。
/// (装过插件源的用户禁用/卸载该插件后,账号不该跟着一起掉 —— 见
/// `unknown_kind_deserializes_instead_of_failing`。)
///
/// `transparent` 对单字段 newtype 其实是**冗余**的(serde 默认就透传,实测去掉它
/// `kind_wire_format_is_bare_lowercase_string` 不会红)。留着是当编译期的钉子:
/// 谁哪天往这个 struct 里加第二个字段,`transparent` 会直接编译报错,
/// 而不是悄悄把线上表示从裸字符串变成对象、让所有老配置读不回来。
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Hash, Debug)]
#[serde(transparent)]
pub struct SourceKind(String);

impl SourceKind {
    pub const EMBY: &'static str = "emby";
    pub const OPENLIST: &'static str = "openlist";
    pub const QUARK: &'static str = "quark";
    pub const ANIRSS: &'static str = "anirss";
    pub const FEINIU: &'static str = "feiniu";
    pub const STREMIO: &'static str = "stremio";
    pub const ONEDRIVE: &'static str = "onedrive";
    pub const GOOGLEDRIVE: &'static str = "googledrive";
    pub const DROPBOX: &'static str = "dropbox";
    pub const ALIYUNDRIVE: &'static str = "aliyundrive";
    pub const BAIDU: &'static str = "baidu";
    pub const PAN115: &'static str = "pan115";

    /// 插件源键前缀。插件贡献的源统一形如 `plugin:com.example.foo/mysrc`。
    const PLUGIN_PREFIX: &'static str = "plugin:";

    /// 全部内置源。**顺序即枚举顺序**,给需要穷举的地方(跨语言契约测试)用。
    pub const BUILTIN: &'static [&'static str] = &[
        Self::EMBY, Self::OPENLIST, Self::QUARK,
        Self::ANIRSS, Self::FEINIU, Self::STREMIO,
        Self::ONEDRIVE, Self::GOOGLEDRIVE, Self::DROPBOX,
        Self::ALIYUNDRIVE, Self::BAIDU, Self::PAN115,
    ];

    pub fn is_builtin(&self) -> bool {
        Self::BUILTIN.contains(&self.0.as_str())
    }

    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn emby() -> Self {
        Self::new(Self::EMBY)
    }
    pub fn openlist() -> Self {
        Self::new(Self::OPENLIST)
    }
    pub fn quark() -> Self {
        Self::new(Self::QUARK)
    }
    pub fn anirss() -> Self {
        Self::new(Self::ANIRSS)
    }
    pub fn feiniu() -> Self {
        Self::new(Self::FEINIU)
    }
    pub fn stremio() -> Self {
        Self::new(Self::STREMIO)
    }
    pub fn onedrive() -> Self {
        Self::new(Self::ONEDRIVE)
    }
    pub fn googledrive() -> Self {
        Self::new(Self::GOOGLEDRIVE)
    }
    pub fn dropbox() -> Self {
        Self::new(Self::DROPBOX)
    }
    pub fn aliyundrive() -> Self {
        Self::new(Self::ALIYUNDRIVE)
    }
    pub fn baidu() -> Self {
        Self::new(Self::BAIDU)
    }
    pub fn pan115() -> Self {
        Self::new(Self::PAN115)
    }

    /// Emby 是唯一的非「文件浏览型」源,全仓多处靠它分叉。
    pub fn is_emby(&self) -> bool {
        self.0 == Self::EMBY
    }

    /// 插件贡献的源。一个插件可贡献多个源,故带 src_id。
    pub fn plugin(plugin_id: &str, src_id: &str) -> Self {
        Self(format!("{}{plugin_id}/{src_id}", Self::PLUGIN_PREFIX))
    }

    /// 是插件源就拆出 `(插件id, 源id)`。**残缺键一律返回 None** ——
    /// 拆出空 id 会让上层去问一个不存在的插件,错误信息还会指向错的地方。
    pub fn as_plugin(&self) -> Option<(&str, &str)> {
        let (plugin_id, src_id) = self.0.strip_prefix(Self::PLUGIN_PREFIX)?.split_once('/')?;
        (!plugin_id.is_empty() && !src_id.is_empty()).then_some((plugin_id, src_id))
    }

    pub fn is_plugin(&self) -> bool {
        self.as_plugin().is_some()
    }

    /// **兼容用,别在新代码里当展示名。**
    ///
    /// 2026-07-23 之前 `SourceKind` 是封闭 enum,`apps/*/src/lib.rs` 用
    /// `format!("{kind:?}")`(派生 Debug = 首字母大写的变体名)当作
    /// **无 base_url 的源(夸克 Cookie 模式)的账号 id 和用户名**,这些字符串
    /// 已经躺在用户配置文件里了。
    ///
    /// 改成 newtype 后 Debug 变成 `SourceKind("quark")` —— 直接沿用会让老账号
    /// 在 `upsert` 时匹配不上、变成重复项,旧账号成孤儿。这个方法逐字复刻老输出。
    pub fn legacy_debug_label(&self) -> String {
        let mut chars = self.0.chars();
        match chars.next() {
            Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
            None => String::new(),
        }
    }
}

impl Default for SourceKind {
    fn default() -> Self {
        Self::emby()
    }
}

impl std::fmt::Display for SourceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// 浏览返回的一行:文件夹或文件。
#[derive(Serialize, Clone)]
pub struct SourceEntry {
    /// 继续浏览/取流的标识:OpenList=完整路径,夸克=fid,Ani-rss=filename。
    pub id: String,
    pub name: String,
    pub is_dir: bool,
    pub is_video: bool,
    pub size: Option<i64>,
    pub thumb_url: Option<String>,
    /// 源原始数据,供 resolve_play 复用(避免二次请求)。
    pub raw: Option<serde_json::Value>,
}

/// 一档可选清晰度(转码源如夸克提供多档)。
#[derive(Serialize, Clone)]
pub struct PlayQuality {
    pub id: String,
    pub label: String,
    pub rank: i32,
}

/// 外挂字幕轨。
#[derive(Serialize, Clone)]
pub struct SourceSubtitle {
    pub url: String,
    pub title: Option<String>,
    pub language: Option<String>,
    pub http_headers: HashMap<String, String>,
}

/// 交给播放器的最小可播单元:URL + 逐流 headers。
#[derive(Serialize, Clone)]
pub struct ResolvedPlay {
    pub url: String,
    pub title: String,
    pub http_headers: HashMap<String, String>,
    pub user_agent_override: Option<String>,
    pub subtitles: Vec<SourceSubtitle>,
    pub qualities: Vec<PlayQuality>,
    pub selected_quality_id: Option<String>,
}

impl ResolvedPlay {
    pub fn simple(url: String, title: String, http_headers: HashMap<String, String>) -> Self {
        Self {
            url,
            title,
            http_headers,
            user_agent_override: None,
            subtitles: vec![],
            qualities: vec![],
            selected_quality_id: None,
        }
    }
}

/// 源后端统一错误。is_auth=鉴权失效(UI 可引导重登)。
#[derive(Debug, Clone, Serialize)]
pub struct SourceError {
    pub message: String,
    pub is_auth: bool,
}
impl SourceError {
    pub fn msg(m: impl Into<String>) -> Self {
        Self { message: m.into(), is_auth: false }
    }
    pub fn auth(m: impl Into<String>) -> Self {
        Self { message: m.into(), is_auth: true }
    }
    pub fn unsupported() -> Self {
        Self::msg("该源不支持搜索")
    }
}
impl std::fmt::Display for SourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

/// 一个浏览型源服务器的连接凭据。对齐 Dart ServerConfig 的相关字段。
/// serde:源服务器要随 AppConfig 落盘(重启免登 + 多源并存),故必须可序列化。
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct SourceServer {
    pub id: String,
    pub base_url: String, // activeLineUrl,后端内部 normalize
    pub username: Option<String>,
    pub password: Option<String>,
    pub token: Option<String>,             // 账密型主令牌
    pub extra: HashMap<String, String>,    // 夸克等多凭据(cookie/refresh_token…)
}

/// 文件浏览型源后端的最小抽象(三端复用,纯逻辑)。
#[async_trait::async_trait]
pub trait MediaSourceBackend: Send + Sync {
    fn kind(&self) -> SourceKind;

    /// 列目录。dir_id=None 表示根目录。
    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError>;

    /// 源内搜索。无源端搜索能力的实现返回 unsupported,UI 退回本地过滤。
    async fn search(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
        _query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        Err(SourceError::unsupported())
    }

    /// 把文件解析成可播单元(含取流所需 headers)。短效直链过期后播放层回调重解析。
    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError>;

    /// 播放进度上报。有服务端观看记录的源(飞牛等)覆写它,纯网盘默认空实现。
    ///
    /// 调用方在播放中按既有节奏(5s 一拍)调用,并在停止时以 finished 再调一次。
    /// 失败一律吞掉不打断播放 —— 进度没记上是小事,把正在看的片子打断是大事。
    async fn report_progress(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
        _entry: &SourceEntry,
        _position_secs: f64,
        _duration_secs: f64,
        _finished: bool,
    ) -> Result<(), SourceError> {
        Ok(())
    }

    /// **凭据轮换回写通道。** 返回 Some 表示该源的存盘凭据变了,调用方必须落盘。
    ///
    /// 存在的理由:trait 只拿得到 `&SourceServer`(只读),而 oplist 系与阿里云盘的
    /// refresh_token 是**一次性的** —— 刷新一次旧值当场作废。不回写的话内存里能用,
    /// 一重启就拿着死 token 去刷,表现为「用得好好的,重开就要重新授权」,且不报错。
    ///
    /// 调用方在每次 list_dir/search/resolve_play 之后取一次;返回的 map 并入
    /// `SourceServer.extra` 后存盘。默认实现返回 None(凭据不轮换的源无需关心)。
    fn take_rotated_credentials(&self, _server_id: &str) -> Option<HashMap<String, String>> {
        None
    }
}

// ---------- 各后端共用工具 ----------

/// 规整 baseUrl:去尾斜杠、补协议(缺省 https)。
pub fn normalize_base_url(raw: &str) -> String {
    let mut url = raw.trim().to_string();
    if url.is_empty() {
        return url;
    }
    if !url.starts_with("http://") && !url.starts_with("https://") {
        url = format!("https://{url}");
    }
    while url.ends_with('/') {
        url.pop();
    }
    url
}

/// 视频扩展名判定(各后端列目录时标记 is_video)。
pub fn is_video_file_name(name: &str) -> bool {
    match name.rsplit_once('.') {
        Some((_, ext)) => VIDEO_EXTENSIONS.contains(&ext.to_lowercase().as_str()),
        None => false,
    }
}

const VIDEO_EXTENSIONS: &[&str] = &[
    "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "ts", "m2ts", "mts",
    "rmvb", "rm", "vob", "3gp", "f4v", "ogv", "m3u8", "iso", "divx", "asf", "mxf",
];

/// 文件夹在前、各自按名排序。
pub fn sort_entries(entries: &mut [SourceEntry]) {
    entries.sort_by(|a, b| {
        if a.is_dir != b.is_dir {
            return if a.is_dir {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            };
        }
        a.name.to_lowercase().cmp(&b.name.to_lowercase())
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalize_and_video_detection() {
        assert_eq!(normalize_base_url(" http://x:5244/ "), "http://x:5244");
        assert_eq!(normalize_base_url("alist.example.com//"), "https://alist.example.com");
        assert!(is_video_file_name("片子.MKV"));
        assert!(is_video_file_name("a.mp4"));
        assert!(!is_video_file_name("cover.jpg"));
        assert!(!is_video_file_name("无扩展名"));
    }

    /// SourceKind 的线上表示就是**配置文件里的字面量**和**前端 api.ts 的联合类型**。
    /// 字面量写歪一个字母,老配置就读不回来(掉账号),前端的 KIND_LABEL 也对不上。
    ///
    /// 2026-07-23 从封闭 enum 改成开放键(newtype String)后,这条钉的是
    /// **线上表示逐字节不变** —— 改造前后序列化结果必须完全一致。
    #[test]
    fn kind_wire_format_is_bare_lowercase_string() {
        let all = [
            (SourceKind::emby(), "emby"),
            (SourceKind::openlist(), "openlist"),
            (SourceKind::quark(), "quark"),
            (SourceKind::anirss(), "anirss"),
            (SourceKind::feiniu(), "feiniu"),
            (SourceKind::stremio(), "stremio"),
            (SourceKind::onedrive(), "onedrive"),
            (SourceKind::googledrive(), "googledrive"),
            (SourceKind::dropbox(), "dropbox"),
            (SourceKind::aliyundrive(), "aliyundrive"),
            (SourceKind::baidu(), "baidu"),
            (SourceKind::pan115(), "pan115"),
        ];
        // 这张表必须与 BUILTIN 一一对应 —— 新增源只加常量不补这里,
        // 下面的逐条断言就完全跑不到它,等于没有守卫。
        assert_eq!(
            all.len(),
            SourceKind::BUILTIN.len(),
            "新增了内置源却没补进本测试表,线上表示无人把关"
        );
        for (k, wire) in all {
            assert_eq!(
                serde_json::to_string(&k).unwrap(),
                format!("\"{wire}\""),
                "{wire} 序列化后不是裸小写字符串 —— 老版本读不回新配置"
            );
            let back: SourceKind = serde_json::from_str(&format!("\"{wire}\"")).unwrap();
            assert_eq!(back, k, "{wire} 反序列化不回原值 —— 老配置会掉账号");
        }
        assert!(
            SourceKind::default().is_emby(),
            "默认必须是 emby —— 没有 source_kind 字段的老账号全靠它兜底"
        );
    }

    /// 插件源键的往返和边界。内置源被误判成插件源的话,请求会被路由去问一个
    /// 根本不存在的插件;残缺键拆出空 id 则会让错误信息指向错的地方。
    #[test]
    fn plugin_kind_roundtrips_and_never_collides_with_builtin() {
        let k = SourceKind::plugin("com.example.foo", "mysrc");
        assert_eq!(k.as_str(), "plugin:com.example.foo/mysrc");
        assert_eq!(
            serde_json::to_string(&k).unwrap(),
            "\"plugin:com.example.foo/mysrc\""
        );
        assert_eq!(k.as_plugin(), Some(("com.example.foo", "mysrc")));
        assert!(k.is_plugin() && !k.is_emby());

        // 直接遍历 BUILTIN:任何新增内置源都自动纳入,不会漏。
        for name in SourceKind::BUILTIN {
            let builtin = SourceKind::new(*name);
            assert!(builtin.is_builtin(), "{builtin} 不认自己是内置源");
            assert!(!builtin.is_plugin(), "内置源 {builtin} 被误判成插件源");
            assert_eq!(builtin.as_plugin(), None);
        }
        // 键重复会让后注册的后端悄悄顶掉前一个。
        let mut seen = std::collections::HashSet::new();
        for name in SourceKind::BUILTIN {
            assert!(seen.insert(*name), "内置源键重复: {name}");
        }

        // 残缺键:少 src_id / 少 plugin_id / 没有分隔符,一律不许拆出来
        for broken in ["plugin:com.x.y/", "plugin:/srcid", "plugin:nosep", "plugin:"] {
            assert_eq!(
                SourceKind::new(broken).as_plugin(),
                None,
                "残缺插件键 {broken} 不该拆出 id"
            );
        }
    }

    /// `legacy_debug_label()` 必须逐字等于老封闭 enum 的派生 Debug 输出 ——
    /// 它是**已经落在用户配置里的账号 id**(夸克 Cookie 模式 base_url 为空,拿它当稳定 id)。
    /// 差一个字母,老账号 upsert 时就匹配不上、变重复项,旧账号成孤儿。
    #[test]
    fn legacy_debug_label_reproduces_old_enum_debug_exactly() {
        let expected = [
            (SourceKind::emby(), "Emby"),
            (SourceKind::openlist(), "Openlist"),
            (SourceKind::quark(), "Quark"),
            (SourceKind::anirss(), "Anirss"),
            (SourceKind::feiniu(), "Feiniu"),
            (SourceKind::stremio(), "Stremio"),
            // 下面 6 个没有"老 enum"可兼容,但它们同样靠这个标签当**账号 id**
            // (base_url 为空的源),所以一旦发版就同样不能再改。
            (SourceKind::onedrive(), "Onedrive"),
            (SourceKind::googledrive(), "Googledrive"),
            (SourceKind::dropbox(), "Dropbox"),
            (SourceKind::aliyundrive(), "Aliyundrive"),
            (SourceKind::baidu(), "Baidu"),
            (SourceKind::pan115(), "Pan115"),
        ];
        assert_eq!(expected.len(), SourceKind::BUILTIN.len(), "新增源未补进本表");
        for (k, old_debug) in expected {
            assert_eq!(
                k.legacy_debug_label(),
                old_debug,
                "{k} 的兼容标签跟老 enum 的 Debug 对不上 —— 老账号会掉"
            );
        }
    }

    /// 开放键的核心收益:装过插件源的配置,在插件被禁用/卸载后仍能读回**整个账号**,
    /// 而不是让整份 config 反序列化失败、把所有服务器一起带走。
    /// 老的封闭 enum 遇到未知字面量会直接报错,这正是要摆脱的东西。
    #[test]
    fn unknown_kind_deserializes_instead_of_failing() {
        let k: SourceKind = serde_json::from_str("\"plugin:com.gone/x\"")
            .expect("未知源类型必须能读回,否则插件一卸载用户就掉光服务器");
        assert_eq!(k.as_str(), "plugin:com.gone/x");
        assert!(!k.is_emby());
    }
}
