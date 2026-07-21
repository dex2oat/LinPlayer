// 排行榜双源(动漫=弹弹Play,影视=TMDB)—— 迁自 Dart lib/core/api/ranking/。
//
// 两源字段收敛到统一 RankingEntry;分类清单内置。凭据均编译期注入:弹弹官方 AppId/Secret
// (option_env DANDANPLAY_*)、TMDB 密钥(option_env TMDB_API_KEY_ENC,AES-256-CBC 密文)。
// PoC 默认无凭据 → available_categories 为空(honest:有凭据的构建才亮对应榜)。6h 文件缓存。

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
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

#[derive(Serialize, Deserialize, Clone, Debug)]
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
/* ★ 这里的每一条错误都必须**说人话地冒出去**,不许再吞成空数组。
   2026-07-21 用户报「榜单没数据」,而当时 fetch_dandan 有 6 条 `return vec![]`:
   缺凭据、请求失败、非 JSON、success=false、无 bangumiList —— 全部长得一模一样(空榜)。
   排查时根本分不清是「构建没注入密钥」还是「服务端拒签」,只能靠猜。
   现在一律 Err(原因),UI 的 catch 分支会把它显示出来(RankingsPage 早就写好了 setErr)。 */
async fn fetch_dandan(cat: &RankingCategory) -> Result<Vec<RankingEntry>, String> {
    let Some(seg) = cat.dandan_path else {
        return Err(format!("分类 {} 没有弹弹Play 路径", cat.id));
    };
    let Some((app_id, secret)) = dandan_creds() else {
        return Err("此构建未注入弹弹Play 凭据(DANDANPLAY_APP_ID/APP_SECRET)".into());
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
    let v = resp.map_err(|e| format!("请求弹弹Play 失败: {e}"))?;
    let status = v.status();
    let j = v
        .json::<serde_json::Value>()
        .await
        .map_err(|e| format!("弹弹Play 返回不是 JSON(HTTP {status}): {e}"))?;
    if j.get("success").and_then(|s| s.as_bool()) != Some(true) {
        // errorCode/errorMessage 是官方 ResponseBase 的字段,签名错/无权限都在这儿说明原因。
        let code = j.get("errorCode").and_then(|c| c.as_i64()).unwrap_or(-1);
        let msg = j.get("errorMessage").and_then(|m| m.as_str()).unwrap_or("(无错误信息)");
        return Err(format!("弹弹Play 拒绝请求(HTTP {status} / errorCode {code}): {msg}"));
    }
    let Some(list) = j.get("bangumiList").and_then(|l| l.as_array()) else {
        return Err(format!("弹弹Play 响应缺少 bangumiList 字段(HTTP {status})"));
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
    Ok(out)
}

async fn fetch_tmdb(cat: &RankingCategory) -> Result<Vec<RankingEntry>, String> {
    let Some(path) = cat.tmdb_path else {
        return Err(format!("分类 {} 没有 TMDB 路径", cat.id));
    };
    let key = tmdb_key();
    if key.is_empty() {
        return Err("此构建未注入 TMDB 密钥(TMDB_API_KEY)".into());
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
    let v = req.send().await.map_err(|e| format!("请求 TMDB 失败: {e}"))?;
    let status = v.status();
    let j = v
        .json::<serde_json::Value>()
        .await
        .map_err(|e| format!("TMDB 返回不是 JSON(HTTP {status}): {e}"))?;
    let Some(list) = j.get("results").and_then(|l| l.as_array()) else {
        // TMDB 用 status_message 说明密钥无效/超配额。
        let msg = j.get("status_message").and_then(|m| m.as_str()).unwrap_or("响应缺少 results 字段");
        return Err(format!("TMDB 拒绝请求(HTTP {status}): {msg}"));
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
    Ok(out)
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
pub async fn fetch(category_id: &str, force_refresh: bool) -> Result<Vec<RankingEntry>, String> {
    let Some(cat) = category_by_id(category_id) else {
        return Err(format!("未知榜单分类: {category_id}"));
    };
    if !force_refresh {
        if let Some(c) = cache_get(category_id) {
            return Ok(c);
        }
    }
    let list = match cat.source {
        Dandan => fetch_dandan(cat).await,
        Tmdb => fetch_tmdb(cat).await,
    }?;
    if !list.is_empty() {
        cache_put(category_id, &list);
    }
    Ok(list)
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

    /* 回归:榜单失败必须**说出原因**,不许再退化成「空数组 = 没数据」。
       2026-07-21 用户报「弹弹榜单没数据」,而当时 fetch_dandan 把缺凭据 / 请求失败 /
       非 JSON / success=false / 缺字段 全部 `return vec![]` —— 五种成因长得一模一样,
       排查只能靠猜(实际根因之一是安卓 CI 压根没传 DANDANPLAY_*)。
       反向验证:把 fetch_dandan 的 Err 改回 Ok(vec![]),本测试立刻红。 */
    #[tokio::test]
    async fn missing_creds_reports_why_instead_of_empty_list() {
        // 未知分类:必须点名分类 id,而不是静默空榜。
        let e = fetch("no-such-category", true).await.expect_err("未知分类应当报错");
        assert!(e.contains("no-such-category"), "错误信息没点名分类: {e}");

        // 本地/PoC 构建没有编译期凭据 —— 此时必须明说「没注入凭据」,
        // 并且把变量名写进去,让人一眼知道去 CI 里补哪个。
        if !anime_configured() {
            let e = fetch("anime_hot_week", true).await.expect_err("无凭据应当报错");
            assert!(e.contains("DANDANPLAY_APP_ID"), "没指明缺哪个变量: {e}");
        }
        if !video_configured() {
            let e = fetch("movie_popular", true).await.expect_err("无 TMDB 密钥应当报错");
            assert!(e.contains("TMDB_API_KEY"), "没指明缺哪个变量: {e}");
        }
    }

    /* 联网冒烟:拿**真凭据**打一次弹弹Play 排行榜,把服务端的真实回答打出来。
       默认 #[ignore] —— 它要网络 + 编译期凭据,本地/PR 都不该因为弹弹抽风而红。
       CI 里由 build-linux 的「Dandanplay 排行榜连通性」步骤显式 --ignored 跑,
       且不阻断构建:它是**诊断**,不是闸门。

       为什么值得留着:2026-07-21 排查「弹弹榜单没数据」时,凭据有效(弹幕搜索同款
       签名同套凭据能出结果)、TMDB 榜正常、分类也全亮 —— 唯独 trending 一族空。
       当时手上没有凭据可以本地复现,只能靠 CI 里这一步把 errorCode/errorMessage 吐出来。
       以后凭据过期、接口改版、签名口径变了,这一步都会第一时间说清楚是哪种。 */
    #[tokio::test]
    #[ignore = "需要网络 + 编译期注入的弹弹Play 凭据;CI 显式 --ignored 跑"]
    async fn dandan_trending_smoke() {
        assert!(anime_configured(), "这个构建没有弹弹Play 凭据,冒烟测试无从谈起");
        match fetch("anime_hot_week", true).await {
            Ok(v) => {
                println!("弹弹Play 排行榜返回 {} 条", v.len());
                for e in v.iter().take(3) {
                    println!("  #{} {}", e.rank, e.title);
                }
                assert!(!v.is_empty(), "弹弹Play 榜单返回空列表(success=true 但 bangumiList 是空的)");
            }
            Err(e) => panic!("弹弹Play 排行榜失败: {e}"),
        }
    }

    #[test]
    fn no_creds_means_no_categories() {
        // PoC 无编译期凭据 → 两源都不亮(honest)。
        if !anime_configured() && !video_configured() {
            assert!(available_categories().is_empty());
        }
    }
}
