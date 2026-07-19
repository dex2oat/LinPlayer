// 排行榜双源(动漫=弹弹Play,影视=TMDB)—— 迁自 Dart lib/core/api/ranking/。
//
// 两源字段收敛到统一 RankingEntry;分类清单内置。凭据均编译期注入:弹弹官方 AppId/Secret
// (option_env DANDANPLAY_*)、TMDB 密钥(option_env TMDB_API_KEY_ENC,AES-256-CBC 密文)。
// PoC 默认无凭据 → available_categories 为空(honest:有凭据的构建才亮对应榜)。6h 文件缓存。

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RankingSource {
    Dandan,
    Tmdb,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RankingGroup {
    Anime,
    Movie,
    Tv,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct RankingEntry {
    pub source: RankingSource,
    pub id: String,
    pub title: String,
    pub rank: i32,
    pub image_url: Option<String>,
    pub rating: Option<f64>,
    pub subtitle: Option<String>,
    pub is_favorited: bool,
    pub media_type: Option<String>, // tmdb: movie | tv
}

#[derive(Serialize, Clone)]
pub struct RankingCategory {
    pub id: &'static str,
    pub group: RankingGroup,
    pub source: RankingSource,
    pub label: &'static str,
    pub dandan_path: Option<&'static str>,
    pub tmdb_path: Option<&'static str>,
}

const fn cat(
    id: &'static str,
    group: RankingGroup,
    source: RankingSource,
    label: &'static str,
    dandan_path: Option<&'static str>,
    tmdb_path: Option<&'static str>,
) -> RankingCategory {
    RankingCategory { id, group, source, label, dandan_path, tmdb_path }
}

use RankingGroup::*;
use RankingSource::*;

/// 内置榜单清单。动漫走弹弹Play,电影/剧集走 TMDB。
pub const CATEGORIES: &[RankingCategory] = &[
    cat("anime_hot_week", Anime, Dandan, "本周热门", Some("all/hot/week"), None),
    cat("anime_hot_month", Anime, Dandan, "本月热门", Some("all/hot/month"), None),
    cat("anime_rising_week", Anime, Dandan, "本周飙升", Some("all/rising/week"), None),
    cat("anime_new_current", Anime, Dandan, "当季新番", Some("new-anime/hot/current-season"), None),
    cat("anime_new_previous", Anime, Dandan, "上季新番", Some("new-anime/hot/previous-season"), None),
    cat("movie_trending_week", Movie, Tmdb, "本周趋势", None, Some("/trending/movie/week")),
    cat("movie_popular", Movie, Tmdb, "流行", None, Some("/movie/popular")),
    cat("movie_top_rated", Movie, Tmdb, "高分", None, Some("/movie/top_rated")),
    cat("movie_now_playing", Movie, Tmdb, "正在上映", None, Some("/movie/now_playing")),
    cat("tv_trending_week", Tv, Tmdb, "本周趋势", None, Some("/trending/tv/week")),
    cat("tv_popular", Tv, Tmdb, "流行", None, Some("/tv/popular")),
    cat("tv_top_rated", Tv, Tmdb, "高分", None, Some("/tv/top_rated")),
    cat("tv_on_the_air", Tv, Tmdb, "正在播出", None, Some("/tv/on_the_air")),
];

// ---------- 凭据(编译期加密注入,见 crate::secrets / build.rs) ----------
use crate::secrets::{dandan_creds, tmdb_configured, tmdb_key};

pub fn anime_configured() -> bool {
    dandan_creds().is_some()
}
pub fn video_configured() -> bool {
    tmdb_configured()
}

/// 当前构建可用的分类(动漫需弹弹凭据,影视需 TMDB 密钥)。
pub fn available_categories() -> Vec<RankingCategory> {
    CATEGORIES
        .iter()
        .filter(|c| match c.source {
            Dandan => anime_configured(),
            Tmdb => video_configured(),
        })
        .cloned()
        .collect()
}

fn category_by_id(id: &str) -> Option<&'static RankingCategory> {
    CATEGORIES.iter().find(|c| c.id == id)
}

// ---------- 拉取 ----------
async fn fetch_dandan(cat: &RankingCategory) -> Vec<RankingEntry> {
    let (Some(seg), Some((app_id, secret))) = (cat.dandan_path, dandan_creds()) else {
        return vec![];
    };
    let path = format!("/api/v2/trending/{seg}");
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let sig = crate::danmaku::signature(&app_id, &path, ts, &secret);
    let url = format!("https://api.dandanplay.net{path}");
    let resp = crate::http::client()
        .get(&url)
        .query(&[("filterAdultContent", "true"), ("limit", "50")])
        .header("X-AppId", app_id)
        .header("X-Timestamp", ts.to_string())
        .header("X-Signature", sig)
        .header("Accept", "application/json")
        .send()
        .await;
    let Ok(v) = resp else { return vec![] };
    let Ok(j) = v.json::<serde_json::Value>().await else {
        return vec![];
    };
    if j.get("success").and_then(|s| s.as_bool()) != Some(true) {
        return vec![];
    }
    let Some(list) = j.get("bangumiList").and_then(|l| l.as_array()) else {
        return vec![];
    };
    let mut out = Vec::new();
    let mut rank = 0;
    for m in list {
        let title = m.get("animeTitle").and_then(|t| t.as_str()).unwrap_or("").trim();
        if title.is_empty() {
            continue;
        }
        rank += 1;
        out.push(RankingEntry {
            source: Dandan,
            id: m.get("animeId").map(val_to_str).unwrap_or_default(),
            title: title.to_string(),
            rank,
            image_url: m.get("imageUrl").and_then(|i| i.as_str()).map(str::trim).filter(|s| !s.is_empty()).map(String::from),
            rating: m.get("rating").and_then(|r| r.as_f64()),
            subtitle: m.get("typeDescription").and_then(|s| s.as_str()).map(|s| s.trim().to_string()),
            is_favorited: m.get("isFavorited").and_then(|b| b.as_bool()).unwrap_or(false),
            media_type: None,
        });
    }
    out
}

async fn fetch_tmdb(cat: &RankingCategory) -> Vec<RankingEntry> {
    let Some(path) = cat.tmdb_path else { return vec![] };
    let key = tmdb_key();
    if key.is_empty() {
        return vec![];
    }
    let use_bearer = key.contains('.'); // v4 JWT 含点;v3 为 32 位十六进制
    let media_type = if path.contains("/tv") { "tv" } else { "movie" };
    let url = format!("https://api.themoviedb.org/3{path}");
    let mut req = crate::http::client()
        .get(&url)
        .header("Accept", "application/json")
        .query(&[("language", "zh-CN"), ("page", "1")]);
    if use_bearer {
        req = req.header("Authorization", format!("Bearer {key}"));
    } else {
        req = req.query(&[("api_key", key.as_str())]);
    }
    let Ok(v) = req.send().await else { return vec![] };
    let Ok(j) = v.json::<serde_json::Value>().await else { return vec![] };
    let Some(list) = j.get("results").and_then(|l| l.as_array()) else {
        return vec![];
    };
    const IMG: &str = "https://image.tmdb.org/t/p/w342";
    let mut out = Vec::new();
    let mut rank = 0;
    for m in list {
        let title = m
            .get("title")
            .or_else(|| m.get("name"))
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .trim();
        if title.is_empty() {
            continue;
        }
        rank += 1;
        let poster = m.get("poster_path").and_then(|p| p.as_str()).map(str::trim).filter(|s| !s.is_empty());
        let date = m
            .get("release_date")
            .or_else(|| m.get("first_air_date"))
            .and_then(|d| d.as_str())
            .unwrap_or("");
        let year = if date.len() >= 4 { Some(date[..4].to_string()) } else { None };
        out.push(RankingEntry {
            source: Tmdb,
            id: m.get("id").map(val_to_str).unwrap_or_default(),
            title: title.to_string(),
            rank,
            image_url: poster.map(|p| format!("{IMG}{p}")),
            rating: m.get("vote_average").and_then(|r| r.as_f64()),
            subtitle: year,
            is_favorited: false,
            media_type: Some(media_type.to_string()),
        });
    }
    out
}

fn val_to_str(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

// ---------- 6h 文件缓存 + 聚合 ----------
fn cache_dir() -> PathBuf {
    crate::paths::cache_dir("ranking")
}

#[derive(Serialize, Deserialize)]
struct Cached {
    at: u64,
    entries: Vec<RankingEntry>,
}

const CACHE_TTL_SECS: u64 = 6 * 3600;

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn cache_get(id: &str) -> Option<Vec<RankingEntry>> {
    let path = cache_dir().join(format!("{id}.json"));
    let raw = std::fs::read_to_string(path).ok()?;
    let c: Cached = serde_json::from_str(&raw).ok()?;
    if now_secs().saturating_sub(c.at) <= CACHE_TTL_SECS {
        Some(c.entries)
    } else {
        None
    }
}

fn cache_put(id: &str, entries: &[RankingEntry]) {
    let dir = cache_dir();
    let _ = std::fs::create_dir_all(&dir);
    let c = Cached { at: now_secs(), entries: entries.to_vec() };
    if let Ok(json) = serde_json::to_string(&c) {
        let _ = std::fs::write(dir.join(format!("{id}.json")), json);
    }
}

/// 拉取某分类榜单。默认命中 6h 缓存;force_refresh 绕过。
pub async fn fetch(category_id: &str, force_refresh: bool) -> Vec<RankingEntry> {
    let Some(cat) = category_by_id(category_id) else {
        return vec![];
    };
    if !force_refresh {
        if let Some(c) = cache_get(category_id) {
            return c;
        }
    }
    let list = match cat.source {
        Dandan => fetch_dandan(cat).await,
        Tmdb => fetch_tmdb(cat).await,
    };
    if !list.is_empty() {
        cache_put(category_id, &list);
    }
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_well_formed() {
        // 每条分类恰有对应源的路径。
        for c in CATEGORIES {
            match c.source {
                Dandan => assert!(c.dandan_path.is_some() && c.tmdb_path.is_none(), "{}", c.id),
                Tmdb => assert!(c.tmdb_path.is_some() && c.dandan_path.is_none(), "{}", c.id),
            }
        }
        // id 唯一。
        let mut ids: Vec<_> = CATEGORIES.iter().map(|c| c.id).collect();
        ids.sort_unstable();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n, "分类 id 有重复");
    }

    #[test]
    fn no_creds_means_no_categories() {
        // PoC 无编译期凭据 → 两源都不亮(honest)。
        if !anime_configured() && !video_configured() {
            assert!(available_categories().is_empty());
        }
    }
}
