// Bangumi 反查器 —— 迁自 Dart bangumi_matcher.dart。把 Emby 项目反查成 Bangumi subject/episode,
// 纯在线 API(不下载 bangumi-data 离线集):
// 1) /v0/search/subjects 按剧名搜 → 用开播日期(±180天)择优定位本体;
// 2) 多季沿「续集」关系链 /v0/subjects/{id}/subjects 走到目标季;
// 3) /v0/episodes 按集号取真实 ep id。

use serde_json::Value;

use super::calendar::parse_date_to_days;
use super::BANGUMI_API_MIRROR;

const API_BASE: &str = BANGUMI_API_MIRROR;
const MAX_SEQUEL_HOPS: i64 = 10;
const EPISODES_PAGE_LIMIT: i64 = 200;
const DATE_TOLERANCE_DAYS: i64 = 180;

/// 解析结果:subject_id + 该集真实 episode_id(非集号)。
#[derive(Clone, Copy, serde::Serialize)]
pub struct BangumiEpisodeRef {
    pub subject_id: i64,
    pub episode_id: i64,
}

struct SubjectMatch {
    subject_id: i64,
    season_matched: bool,
}

fn client() -> reqwest::Client {
    crate::http::client()
}

/// 解析剧集 → (subject_id, episode_id)。失败 None(静默跳过)。
pub async fn resolve_episode(
    title: &str,
    original_title: Option<&str>,
    air_date: Option<&str>,
    season: i64,
    episode: i64,
) -> Option<BangumiEpisodeRef> {
    let m = search_subject(title, original_title, air_date, season).await?;
    let mut subject_id = m.subject_id;
    if season > 1 && !m.season_matched {
        subject_id = resolve_season_subject_id(m.subject_id, season).await?;
    }
    let episode_id = find_episode_id_by_sort(subject_id, episode).await?;
    Some(BangumiEpisodeRef { subject_id, episode_id })
}

/// 解析电影 → (subject_id, 主章节 episode_id)。
pub async fn resolve_movie(
    title: &str,
    original_title: Option<&str>,
    air_date: Option<&str>,
) -> Option<BangumiEpisodeRef> {
    let m = search_subject(title, original_title, air_date, 1).await?;
    let episode_id = find_episode_id_by_sort(m.subject_id, 1).await?;
    Some(BangumiEpisodeRef { subject_id: m.subject_id, episode_id })
}

// ============ 标题搜索 → subject ============
async fn search_subject(
    title: &str,
    original_title: Option<&str>,
    air_date: Option<&str>,
    season: i64,
) -> Option<SubjectMatch> {
    // 去重保序的候选查询:多季先去季度后缀,再原名,再外文名。
    let mut queries: Vec<String> = Vec::new();
    let mut push = |s: String| {
        let t = s.trim().to_string();
        if !t.is_empty() && !queries.contains(&t) {
            queries.push(t);
        }
    };
    if season > 1 {
        push(strip_season_suffix(title));
    } else {
        push(title.to_string());
    }
    push(title.to_string());
    if let Some(o) = original_title {
        push(o.to_string());
    }

    let air_days = air_date.and_then(parse_date_to_days);
    for q in &queries {
        let results = search_bgm(q).await;
        if results.is_empty() {
            continue;
        }
        // 按开播日期择优。
        let mut best: Option<&Value> = None;
        let mut best_diff = i64::MAX;
        if let Some(ad) = air_days {
            for r in &results {
                if r["id"].as_i64().is_none() {
                    continue;
                }
                if let Some(days) = r["date"].as_str().and_then(parse_date_to_days) {
                    let diff = (days - ad).abs();
                    if diff < best_diff {
                        best_diff = diff;
                        best = Some(r);
                    }
                }
            }
        }
        if let Some(b) = best {
            if best_diff <= DATE_TOLERANCE_DAYS {
                // 日期高度吻合:基本可断定就是这一季本体,不再走续集链。
                return Some(SubjectMatch { subject_id: b["id"].as_i64().unwrap(), season_matched: true });
            }
        }
        // 日期对不上/无日期:退回第一个结果。标题含季度信息则视为季本体。
        let first = &results[0];
        let id = first["id"].as_i64()?;
        let name = format!(
            "{} {}",
            first["name"].as_str().unwrap_or(""),
            first["name_cn"].as_str().unwrap_or("")
        );
        let season_matched = season <= 1 || title_has_season_info(&name, season);
        return Some(SubjectMatch { subject_id: id, season_matched });
    }
    None
}

/// 调 Bangumi 搜索,返回候选(含 id/name/name_cn/date)。v0 POST 优先,回退旧 GET。
async fn search_bgm(keyword: &str) -> Vec<Value> {
    // 新版:POST /v0/search/subjects(type 2 = 动画)。
    let body = serde_json::json!({
        "keyword": keyword,
        "filter": { "type": [2], "nsfw": true }
    });
    if let Ok(resp) = client()
        .post(format!("{API_BASE}/v0/search/subjects?limit=10"))
        .json(&body)
        .send()
        .await
    {
        if resp.status().is_success() {
            if let Ok(j) = resp.json::<Value>().await {
                if let Some(arr) = j["data"].as_array() {
                    if !arr.is_empty() {
                        return arr.clone();
                    }
                }
            }
        }
    }
    // 回退旧版:GET /search/subject/{keyword}?type=2。
    let url = format!("{API_BASE}/search/subject/{}", urlencoding::encode(keyword));
    if let Ok(resp) = client().get(&url).query(&[("type", "2"), ("responseGroup", "small")]).send().await {
        if resp.status().is_success() {
            if let Ok(j) = resp.json::<Value>().await {
                if let Some(arr) = j["list"].as_array() {
                    return arr.clone();
                }
            }
        }
    }
    vec![]
}

/// 已知 subject_id,按集号取真实 ep id(供弹弹play 反查路径复用)。
pub async fn find_episode_id(subject_id: i64, episode: i64) -> Option<i64> {
    find_episode_id_by_sort(subject_id, episode).await
}

// ============ 续集链 / 集数解析 ============
async fn resolve_season_subject_id(root_id: i64, season: i64) -> Option<i64> {
    if season <= 1 {
        return Some(root_id);
    }
    if season - 1 > MAX_SEQUEL_HOPS {
        return None; // 防御异常季号狂刷接口
    }
    let mut current = root_id;
    for _ in 1..season {
        current = next_sequel_subject_id(current).await?;
    }
    Some(current)
}

async fn next_sequel_subject_id(subject_id: i64) -> Option<i64> {
    let resp = client().get(format!("{API_BASE}/v0/subjects/{subject_id}/subjects")).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: Value = resp.json().await.ok()?;
    // 响应可能是数组或 {data:[...]}。
    let list = if j.is_array() { j.as_array() } else { j["data"].as_array() }?;
    for rel in list {
        if rel["relation"].as_str() == Some("续集") {
            // id 可能是数字或字符串。
            return rel["id"].as_i64().or_else(|| rel["id"].as_str().and_then(|s| s.parse().ok()));
        }
    }
    None
}

async fn find_episode_id_by_sort(subject_id: i64, target_sort: i64) -> Option<i64> {
    let mut offset = 0;
    while offset < EPISODES_PAGE_LIMIT * 5 {
        let resp = client()
            .get(format!("{API_BASE}/v0/episodes"))
            .query(&[
                ("subject_id", subject_id.to_string()),
                ("type", "0".to_string()), // 本篇
                ("limit", EPISODES_PAGE_LIMIT.to_string()),
                ("offset", offset.to_string()),
            ])
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let j: Value = resp.json().await.ok()?;
        let data = j["data"].as_array()?;
        if data.is_empty() {
            return None;
        }
        for ep in data {
            let sort = ep["sort"].as_i64();
            let ep_no = ep["ep"].as_i64();
            if sort == Some(target_sort) || ep_no == Some(target_sort) {
                return ep["id"].as_i64().or_else(|| ep["id"].as_str().and_then(|s| s.parse().ok()));
            }
        }
        if (data.len() as i64) < EPISODES_PAGE_LIMIT {
            return None;
        }
        offset += EPISODES_PAGE_LIMIT;
    }
    None
}

// ============ 工具(纯逻辑,可测) ============
/// 标题是否含第 N 季信息(移植自 Bangumi-syncer)。
fn title_has_season_info(title: &str, season: i64) -> bool {
    let cn = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"];
    let mut keywords = vec![
        format!("第{season}季"),
        format!("第{season}期"),
        format!("{season}季"),
        format!("{season}期"),
        format!("Season {season}"),
        format!("S{season}"),
    ];
    if (1..=10).contains(&season) {
        let c = cn[season as usize];
        keywords.extend([format!("第{c}季"), format!("第{c}期"), format!("{c}季"), format!("{c}期")]);
    }
    keywords.iter().any(|k| title.contains(k.as_str()))
}

/// 去掉标题尾部的季度后缀(第N季/期/话/集、Season N、SN、罗马数字 II、尾部数字)。
fn strip_season_suffix(title: &str) -> String {
    use regex::Regex;
    // 逐条剥离(与 Dart 同序)。正则编译一次即可,这里为简明每调编译(匹配频率极低)。
    let pats = [
        r"\s*第?\s*\d+\s*[期季話话集]\s*$",
        r"(?i)\s*Season\s*\d+\s*$",
        r"(?i)\s*S\d+\s*$",
        r"\s+I I*\s*$", // 占位,下面单独处理罗马数字
        r"\s+\d+\s*$",
    ];
    let mut t = title.to_string();
    for (i, p) in pats.iter().enumerate() {
        if i == 3 {
            // 罗马数字 II/III...(至少两个 I)。
            if let Ok(re) = Regex::new(r"\s+II+\s*$") {
                t = re.replace(&t, "").to_string();
            }
            continue;
        }
        if let Ok(re) = Regex::new(p) {
            t = re.replace(&t, "").to_string();
        }
    }
    let trimmed = t.trim();
    if trimmed.is_empty() {
        title.to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn season_info_detection() {
        assert!(title_has_season_info("进击的巨人 第二季", 2));
        assert!(title_has_season_info("Re:Zero Season 2", 2));
        assert!(title_has_season_info("某番 S3", 3));
        assert!(!title_has_season_info("进击的巨人", 2));
    }

    #[test]
    fn strip_season_suffix_cases() {
        // 与 Dart 同:只剥「数字」季度后缀(\d+),中文数字季不动(靠搜索+日期择优)。
        assert_eq!(strip_season_suffix("进击的巨人 第2季"), "进击的巨人");
        assert_eq!(strip_season_suffix("Re:Zero Season 2"), "Re:Zero");
        assert_eq!(strip_season_suffix("某番 II"), "某番");
        assert_eq!(strip_season_suffix("孤独摇滚 12"), "孤独摇滚");
        // 中文数字季不含 \d,保持不变。
        assert_eq!(strip_season_suffix("进击的巨人 第二季"), "进击的巨人 第二季");
    }
}
