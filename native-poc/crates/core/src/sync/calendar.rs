// 追剧日历条目(Trakt/Bangumi 归一化)。归组是 UI 逻辑,留前端 TS;核只出数据。
use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct CalendarEntry {
    pub title: String,
    pub subtitle: Option<String>,
    /// 精确放送时刻 ISO8601(Trakt 有);为空时前端用 weekday 归组。
    pub air_date: Option<String>,
    /// 每周放送日 1=周一…7=周日(Bangumi 用)。
    pub weekday: Option<i32>,
    /// 每周固定放送时刻(ISO8601 UTC 的**首播时刻**,周期重复 → 时分即每周更新时间)。
    /// Bangumi 官方 API 不给时刻,靠 bangumi-data 数据集补;取不到就是 None(不编时间)。
    /// 前端拿它换算成本地 HH:MM 显示;air_date 已有精确时刻时(Trakt)不需要它。
    pub broadcast_at: Option<String>,
    pub image_url: Option<String>,
    pub tmdb_id: Option<i64>,
    /// 评分(10 分制,两源同口径)。
    /// ★ 0 分 = **没人评过**,不是「这片 0 分」—— 取不到就 None,前端别画。
    /// 以前 Bangumi 把评分硬塞进 subtitle 当文字("评分 8.2"),那是拿文案位当数据位,已改。
    pub rating: Option<f64>,
    /// 简介。
    /// - Trakt:TMDB 的 overview —— 取海报那次请求**顺手就有**,零额外开销,故直接内联。
    /// - Bangumi:**恒为 None**。2026-07-16 实测 `/calendar` 的 summary 字段整周 111 条
    ///   全是空字符串(字段在、值不给),真简介只在 `/v0/subjects/{id}`。一周 111 部要 111 次
    ///   请求,不能在拉放送表时同步做 → 走 `bangumi_summary` 命令按需拉(前端只对聚焦那条拉)。
    pub summary: Option<String>,
    /// Bangumi subject id。前端拿它按需拉简介(见上)。Trakt 侧为 None。
    pub bangumi_id: Option<i64>,
    pub source: String, // trakt | bangumi
}

/// epoch 天数 → (年,月,日)。Howard Hinnant civil_from_days,免 chrono 依赖。
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m as u32, d as u32)
}

/// (年,月,日) → epoch 天数。Howard Hinnant days_from_civil(civil_from_days 的逆),日期差用。
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468
}

/// 解析日期串(取首个 YYYY-MM-DD)→ epoch 天数。失败 None。
pub fn parse_date_to_days(s: &str) -> Option<i64> {
    let bytes = s.as_bytes();
    // 找 4 位年-月-日 的起点(宽松:任意位置的 \d{4}-\d{1,2}-\d{1,2})。
    let parts: Vec<&str> = s.splitn(2, |c: char| c == 'T' || c == ' ').collect();
    let date_part = parts.first()?;
    let seg: Vec<&str> = date_part.split('-').collect();
    if seg.len() < 3 {
        return None;
    }
    let _ = bytes;
    let y = seg[0].trim().parse::<i64>().ok()?;
    let m = seg[1].trim().parse::<i64>().ok()?;
    let d = seg[2].trim().parse::<i64>().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

/// 从当前时间偏移若干天,格式化成 YYYY-MM-DD(Trakt 日历起点用)。
pub fn date_str_days_ago(offset_days: i64) -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let days = secs / 86400 - offset_days;
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_date_known_epochs() {
        assert_eq!(civil_from_days(0), (1970, 1, 1)); // unix epoch
        assert_eq!(civil_from_days(18262), (2020, 1, 1)); // 2020-01-01
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
    }

    #[test]
    fn days_roundtrip_and_diff() {
        // civil→days→civil 往返一致。
        for &(y, m, d) in &[(1970, 1, 1), (2020, 1, 1), (2024, 2, 29), (1999, 12, 31)] {
            let days = days_from_civil(y, m, d);
            assert_eq!(civil_from_days(days), (y, m as u32, d as u32));
        }
        // 日期差(天)。
        let a = parse_date_to_days("2020-01-01").unwrap();
        let b = parse_date_to_days("2020-01-11T00:00:00").unwrap();
        assert_eq!((a - b).abs(), 10);
        assert!(parse_date_to_days("garbage").is_none());
    }
}
