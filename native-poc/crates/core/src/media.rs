// 媒体轨道类型 + 语言偏好选轨(桌面/安卓共用)。
use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct Track {
    pub kind: String, // "audio" | "sub"
    pub id: String,
    pub title: String,
    pub lang: String,
    pub selected: bool,
}

/// 按语言偏好挑音轨/字幕轨。
/// 返回 (aid, sid):`Some(id)` = 切到该轨;`Some("no")` = 关字幕;`None` = 保持不变。
pub fn pick_tracks(
    tracks: &[Track],
    audio_lang: Option<&str>,
    sub_lang: Option<&str>,
    sub_enabled: bool,
) -> (Option<String>, Option<String>) {
    let aid = audio_lang.and_then(|want| match_lang(tracks, "audio", want));
    let sid = if !sub_enabled {
        Some("no".to_string())
    } else {
        sub_lang.and_then(|want| match_lang(tracks, "sub", want))
    };
    (aid, sid)
}

// ponytail: 朴素的 lang/title 包含匹配;需要"正则版本偏好"(track_preference)时再升级。
fn match_lang(tracks: &[Track], kind: &str, want: &str) -> Option<String> {
    let want = want.trim().to_lowercase();
    if want.is_empty() {
        return None;
    }
    tracks
        .iter()
        .filter(|t| t.kind == kind)
        .find(|t| {
            t.lang.to_lowercase().contains(&want) || t.title.to_lowercase().contains(&want)
        })
        .map(|t| t.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn t(kind: &str, id: &str, lang: &str, title: &str) -> Track {
        Track { kind: kind.into(), id: id.into(), title: title.into(), lang: lang.into(), selected: false }
    }
    #[test]
    fn picks_by_lang_and_respects_sub_toggle() {
        let tracks = vec![
            t("audio", "1", "jpn", "日本語"),
            t("audio", "2", "eng", "English"),
            t("sub", "3", "chi", "简体中文"),
        ];
        // 偏好中文字幕 + 英语音轨
        let (aid, sid) = pick_tracks(&tracks, Some("eng"), Some("chi"), true);
        assert_eq!(aid.as_deref(), Some("2"));
        assert_eq!(sid.as_deref(), Some("3"));
        // 关字幕
        let (_, sid_off) = pick_tracks(&tracks, None, Some("chi"), false);
        assert_eq!(sid_off.as_deref(), Some("no"));
        // 无匹配 -> 保持不变
        let (aid_none, _) = pick_tracks(&tracks, Some("kor"), None, true);
        assert_eq!(aid_none, None);
    }
}
