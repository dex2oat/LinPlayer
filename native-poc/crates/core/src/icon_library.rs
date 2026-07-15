//! 网络图标库:拉取用户给的聚合源 → 解析成 (名字, 链接) → **落盘缓存 + TTL**,不每次拉。
//!
//! 用户 2026-07-15:「我提供四个聚合图标链接 你解析出来名字和链接 然后下载到本地持久化缓存
//! 不要每次都拉取」。四个源统一格式 `{name, description, icons:[{name, url, category?}]}`,
//! 共约 1468 个图标。
//!
//! ## 缓存策略(照 ranking.rs)
//! 拉全四源 → 合并 → 落 `config_dir/LinPlayer/icon_library.json` + 时间戳,TTL 内直接读盘。
//! **拉取失败时回退到旧缓存(哪怕过期)** —— 网断了也别让图标库空着,旧的总比没有强。
//! 用户在弹窗里点「刷新」传 force 绕过 TTL。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

/// 用户 2026-07-15 提供的四个聚合图标源。改动请连带更新缓存(换源后旧缓存仍会先显示直到刷新)。
pub const SOURCES: &[&str] = &[
    "https://zizhu.291277.xyz/icons-all.json",
    "https://gist.github.com/zzzwannasleep/fe6e84f43fcd64672ec71302f48a01ea/raw/4629cb6a10abf954c2ccb2f1b20b9149ba6f1bd9/icons.json",
    "https://gist.github.com/zzzwannasleep/a52322ad8cf1dcf7462dd4a33816e0f4/raw/ab4b2e1a8390c0f1d4f5171e9f2b24fba832a32e/icons.json",
    "https://gist.github.com/zzzwannasleep/1da6e9d12cd9285980c6aba05855dede/raw/bc278c72ac514eba4f9fab48a54975feeeb7d386/icons.json",
];

const CACHE_TTL_SECS: u64 = 24 * 3600; // 图标库不常变,一天拉一次够了

/// 库里的一个图标条目。前端拿它渲染网格 + 点选后当 icon_url。
#[derive(Serialize, Deserialize, Clone)]
pub struct IconEntry {
    pub name: String,
    pub url: String,
    /// 来自哪个源(源的 `name` 字段,如「Emby自助图标库」),UI 可分组;空则未知。
    pub source: String,
}

/// 源 JSON 的结构。`category` 只有第一个源有,可选;这里用不到,不解析进 IconEntry。
#[derive(Deserialize)]
struct SourceDoc {
    #[serde(default)]
    name: String,
    #[serde(default)]
    icons: Vec<RawIcon>,
}

#[derive(Deserialize)]
struct RawIcon {
    #[serde(default)]
    name: String,
    #[serde(default)]
    url: String,
}

#[derive(Serialize, Deserialize)]
struct Cached {
    at: u64,
    entries: Vec<IconEntry>,
}

fn cache_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LinPlayer")
        .join("icon_library.json")
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// 读缓存。`allow_stale=true` 时无视 TTL(拉取失败兜底用)。
fn cache_get(allow_stale: bool) -> Option<Vec<IconEntry>> {
    let raw = std::fs::read_to_string(cache_path()).ok()?;
    let c: Cached = serde_json::from_str(&raw).ok()?;
    if allow_stale || now_secs().saturating_sub(c.at) <= CACHE_TTL_SECS {
        Some(c.entries)
    } else {
        None
    }
}

fn cache_put(entries: &[IconEntry]) {
    let path = cache_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let c = Cached { at: now_secs(), entries: entries.to_vec() };
    if let Ok(json) = serde_json::to_string(&c) {
        let _ = std::fs::write(path, json);
    }
}

/// 解析一个源的 JSON body → 条目。坏 JSON / 空 url 静默跳过,不因一个源坏了整库空。
fn parse_source(body: &str) -> Vec<IconEntry> {
    let Ok(doc) = serde_json::from_str::<SourceDoc>(body) else {
        return vec![];
    };
    let src = doc.name;
    doc.icons
        .into_iter()
        .filter(|i| !i.url.trim().is_empty() && i.url.starts_with("http"))
        .map(|i| IconEntry {
            name: if i.name.trim().is_empty() { i.url.clone() } else { i.name },
            url: i.url,
            source: src.clone(),
        })
        .collect()
}

/// 拉全四源并合并(按 url 去重 —— 不同源可能收录同一张图)。
async fn fetch_all(http: &reqwest::Client) -> Vec<IconEntry> {
    let mut out: Vec<IconEntry> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for url in SOURCES {
        // 单源失败不影响其它源。
        let Ok(resp) = http.get(*url).send().await else { continue };
        if !resp.status().is_success() {
            continue;
        }
        let Ok(body) = resp.text().await else { continue };
        for e in parse_source(&body) {
            if seen.insert(e.url.clone()) {
                out.push(e);
            }
        }
    }
    out
}

/// 图标库。默认命中 24h 缓存;`force` 绕过并重新拉全四源。
///
/// 返回空的唯一情况:从没拉成功过 + 本次也全失败。此时前端应提示「拉取失败」而不是「无图标」。
pub async fn library(http: &reqwest::Client, force: bool) -> Vec<IconEntry> {
    if !force {
        if let Some(c) = cache_get(false) {
            return c;
        }
    }
    let fresh = fetch_all(http).await;
    if !fresh.is_empty() {
        cache_put(&fresh);
        return fresh;
    }
    // 全拉失败 → 回退旧缓存(哪怕过期),网断了也别空着。
    cache_get(true).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 四个真实源的样本结构:{name, icons:[{name,url,category?}]}。解析要拿到 name+url。
    #[test]
    fn parses_real_source_shape() {
        let body = r#"{
            "name": "Emby自助图标库",
            "description": "",
            "icons": [
                {"name": "cattrv", "url": "https://x.com/a.png", "category": "default"},
                {"name": "冰块", "url": "https://x.com/b.png"}
            ]
        }"#;
        let e = parse_source(body);
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].name, "cattrv");
        assert_eq!(e[0].url, "https://x.com/a.png");
        assert_eq!(e[0].source, "Emby自助图标库", "source 要带上,UI 分组用");
        assert_eq!(e[1].name, "冰块");
    }

    /// 空 url / 非 http 的条目必须丢掉 —— 否则前端拿去当 <img src> 是坏图,当 icon_url 更糟。
    #[test]
    fn drops_empty_or_non_http_urls() {
        let body = r#"{"name":"s","icons":[
            {"name":"a","url":""},
            {"name":"b","url":"ftp://x/y.png"},
            {"name":"c","url":"https://ok.com/c.png"}
        ]}"#;
        let e = parse_source(body);
        assert_eq!(e.len(), 1, "只有 https 那条该留下");
        assert_eq!(e[0].name, "c");
    }

    /// 名字缺失时回落成 url —— 不能给前端一个空名字的格子(搜不到、看不出是什么)。
    #[test]
    fn missing_name_falls_back_to_url() {
        let body = r#"{"name":"s","icons":[{"name":"","url":"https://x.com/z.png"}]}"#;
        let e = parse_source(body);
        assert_eq!(e[0].name, "https://x.com/z.png");
    }

    /// 坏 JSON 不 panic、不抛 —— 一个源挂了返回空,别拖垮整库(fetch_all 靠这个隔离)。
    #[test]
    fn broken_json_yields_empty_not_panic() {
        assert!(parse_source("not json at all").is_empty());
        assert!(parse_source("").is_empty());
        assert!(parse_source(r#"{"name":"s"}"#).is_empty()); // 没有 icons 键
    }

    /// SOURCES 必须是四个 http(s) 链接(用户给的),别写错。
    #[test]
    fn sources_are_four_http_urls() {
        assert_eq!(SOURCES.len(), 4);
        for s in SOURCES {
            assert!(s.starts_with("https://"), "源必须是 https: {s}");
        }
    }
}
