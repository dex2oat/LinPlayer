// 文件浏览型数据源后端抽象(网盘/聚合/追番),对齐 Dart 的 media_source_backend.dart。
// 三件事:列目录 / 搜索(可降级)/ 把文件解析成可播 URL(含逐流 headers)。
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub mod anirss;
pub mod feiniu;
pub mod openlist;
pub mod quark;
pub mod quark_tv;
pub mod stremio;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    #[default]
    Emby,
    Openlist,
    Quark,
    Anirss,
    Feiniu,
    Stremio,
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
    /// 变体名大小写写歪一个字母,老配置就读不回来(掉账号),前端的 KIND_LABEL 也对不上。
    /// 这条钉的是「加变体时顺手把两端对齐」。
    #[test]
    fn kind_wire_format_is_lowercase() {
        let all = [
            (SourceKind::Emby, "emby"),
            (SourceKind::Openlist, "openlist"),
            (SourceKind::Quark, "quark"),
            (SourceKind::Anirss, "anirss"),
            (SourceKind::Feiniu, "feiniu"),
            (SourceKind::Stremio, "stremio"),
        ];
        for (k, wire) in all {
            assert_eq!(serde_json::to_string(&k).unwrap(), format!("\"{wire}\""));
            let back: SourceKind = serde_json::from_str(&format!("\"{wire}\"")).unwrap();
            assert_eq!(back, k, "{wire} 反序列化不回原变体 —— 老配置会掉账号");
        }
    }
}
