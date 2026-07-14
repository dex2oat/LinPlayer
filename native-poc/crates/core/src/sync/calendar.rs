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
    pub image_url: Option<String>,
    pub tmdb_id: Option<i64>,
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
}
