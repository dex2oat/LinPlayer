// 本地弹幕文件解析:用户导入的 .xml / .json / .ass 转 DanmakuComment。
// 逐字对齐 Dart lib/core/utils/danmaku_local_parser.dart。
//
// 红线:整个文件解析不出东西必须 Err —— 返回空 Vec 会让用户看到「加载成功但一条弹幕没有」
// 且无从排查。单条畸形跳过是对的,整体失败装成功不是。

use super::{unescape_xml, DanmakuComment};
use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;

const SOURCE: &str = "本地导入";
const WHITE: i32 = 16777215;

/// 支持的扩展名(不含点)。对齐 Dart supportedExtensions。
pub const SUPPORTED_EXTENSIONS: [&str; 4] = ["xml", "json", "ass", "ssa"];

/// 文件内容嗅探出的格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalFormat {
    Xml,
    Json,
    Ass,
}

/// 按内容嗅探格式(不信扩展名:用户改名/下载器乱给后缀是常态)。
/// 注意 ASS 以 `[Script Info]` 开头,首字符也是 `[` —— 必须先于 JSON 判定,否则
/// 每个 ASS 都会被当 JSON 喂给 serde 然后报「JSON 解析失败」。
pub fn sniff(content: &str) -> Option<LocalFormat> {
    let t = content.trim_start();
    if t.is_empty() {
        return None;
    }
    if t.starts_with("[Script Info]") || t.contains("[Events]") || t.contains("Dialogue:") {
        return Some(LocalFormat::Ass);
    }
    match t.as_bytes()[0] {
        b'<' => Some(LocalFormat::Xml),
        b'{' | b'[' => Some(LocalFormat::Json),
        _ => None,
    }
}

/// 解析本地弹幕文件。`file_name` 只在内容嗅探失败时作后备提示。
pub fn parse(file_name: &str, content: &str) -> Result<Vec<DanmakuComment>, String> {
    if content.trim().is_empty() {
        return Err("弹幕文件为空".into());
    }
    let fmt = sniff(content).or_else(|| match ext(file_name).as_str() {
        "xml" => Some(LocalFormat::Xml),
        "json" => Some(LocalFormat::Json),
        "ass" | "ssa" => Some(LocalFormat::Ass),
        _ => None,
    });
    match fmt {
        Some(LocalFormat::Xml) => parse_xml(content),
        Some(LocalFormat::Json) => parse_json(content),
        Some(LocalFormat::Ass) => parse_ass(content),
        None => Err("无法识别的弹幕文件格式(仅支持 xml/json/ass)".into()),
    }
}

fn ext(file_name: &str) -> String {
    file_name
        .rsplit_once('.')
        .map(|(_, e)| e.to_lowercase())
        .unwrap_or_default()
}

/// 各家 mode 归一到弹弹Play 标准:1=滚动 4=底部 5=顶部。对齐 Dart _normalizeMode。
fn normalize_mode(mode: i32) -> i32 {
    match mode {
        4 => 4,
        5 => 5,
        _ => 1, // 含逆向(6)等,渲染层按滚动处理
    }
}

/// `&#39;` 单引号数字实体先解(mod.rs 的 unescape_xml 只认 `&apos;`),再走已有的五件套。
/// 顺序安全:`&amp;#39;` 里不含子串 `&#39;`,不会被这一步误伤。
fn unescape(s: &str) -> String {
    unescape_xml(&s.replace("&#39;", "'"))
}

// ============ XML(B站 / 弹弹Play 导出)============
// <d p="time,mode,fontsize,color,timestamp,pool,userhash,rowid">text</d>
// ponytail: 手写扫描而非上 quick-xml —— 就这一种扁平结构,加个 XML 依赖不值。
// 真要吃任意 XML(CDATA / 命名空间 / 属性值里的 `>`)再换。

/// 下一个 `<d` 开标签的字节偏移。要求 `<d` 后紧跟空白或 `>`,否则 `<data>` 会被误当弹幕。
fn next_d_open(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let mut i = 0;
    while let Some(rel) = s[i..].find("<d") {
        let at = i + rel;
        match b.get(at + 2) {
            Some(c) if c.is_ascii_whitespace() || *c == b'>' => return Some(at),
            None => return None,
            _ => i = at + 2,
        }
    }
    None
}

/// 取 `p="..."` / `p='...'` 属性值。要求 `p` 前是空白,否则 `xp="..."` 会被当成 p。
fn attr_p(attrs: &str) -> Option<&str> {
    for q in ['"', '\''] {
        let pat = format!("p={q}");
        let mut from = 0;
        while let Some(rel) = attrs[from..].find(&pat) {
            let i = from + rel;
            let ok = i == 0 || attrs.as_bytes()[i - 1].is_ascii_whitespace();
            let start = i + pat.len();
            if ok {
                return attrs[start..].find(q).map(|e| &attrs[start..start + e]);
            }
            from = start;
        }
    }
    None
}

pub fn parse_xml(content: &str) -> Result<Vec<DanmakuComment>, String> {
    if !content.trim_start().starts_with('<') {
        return Err("XML 解析失败: 内容不是以 '<' 开头".into());
    }
    let mut out = Vec::new();
    let mut cur = content;
    while let Some(at) = next_d_open(cur) {
        let after = &cur[at..];
        let Some(gt) = after.find('>') else { break }; // 开标签未闭合 → 文件截断,停扫
        let attrs = &after[2..gt];
        let rest = &after[gt + 1..];
        if attrs.trim_end().ends_with('/') {
            cur = rest; // 自闭合 <d p="..."/> 没有文本,跳过(否则会吞到下一个 </d>)
            continue;
        }
        let Some(end) = rest.find("</d>") else { break };
        let body = &rest[..end];
        cur = &rest[end + 4..];

        let text = unescape(body).trim().to_string();
        if text.is_empty() {
            continue;
        }
        let p: Vec<&str> = attr_p(attrs).unwrap_or("").split(',').collect();
        // 时间取不到就跳过:Dart 会退化成 0 秒,那等于把弹幕全堆在片头 —— 宁可少一条。
        let Some(time) = p.first().and_then(|s| s.trim().parse::<f64>().ok()) else {
            continue;
        };
        out.push(DanmakuComment {
            time,
            text,
            // 字号在 index2,颜色在 index3 —— 与弹弹Play JSON 的 p 下标不同,别抄串。
            mode: normalize_mode(p.get(1).and_then(|s| s.trim().parse().ok()).unwrap_or(1)),
            color: p.get(3).and_then(|s| s.trim().parse().ok()).unwrap_or(WHITE),
            source: SOURCE.into(),
            cid: None,
            user_id: p.get(6).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
            count: 1,
        });
    }
    if out.is_empty() {
        return Err("XML 中未找到弹幕(<d> 节点为空)".into());
    }
    Ok(out)
}

// ============ JSON(弹弹Play 评论导出)============
// {"comments":[{"p":"time,mode,color,uid","m":"text"}]} / 裸数组 / {"data":[...]}

pub fn parse_json(content: &str) -> Result<Vec<DanmakuComment>, String> {
    let data: Value = serde_json::from_str(content).map_err(|e| format!("JSON 解析失败: {e}"))?;
    let comments = match &data {
        Value::Array(a) => a,
        v => ["comments", "data", "danmuku"]
            .iter()
            .find_map(|k| v.get(k).and_then(Value::as_array))
            .ok_or("JSON 中未找到弹幕列表(comments/data)")?,
    };
    let mut out = Vec::new();
    for c in comments {
        let text = c["m"]
            .as_str()
            .or_else(|| c["text"].as_str())
            .unwrap_or("")
            .to_string();
        if text.is_empty() {
            continue;
        }
        let p: Vec<&str> = c["p"].as_str().unwrap_or("").split(',').collect();
        let Some(time) = p.first().and_then(|s| s.trim().parse::<f64>().ok()) else {
            continue;
        };
        out.push(DanmakuComment {
            time,
            text,
            // 弹弹Play p 只有 4 段且无字号:color 在 index2(XML 是 index3)。
            mode: normalize_mode(p.get(1).and_then(|s| s.trim().parse().ok()).unwrap_or(1)),
            color: p.get(2).and_then(|s| s.trim().parse().ok()).unwrap_or(WHITE),
            source: SOURCE.into(),
            cid: c["cid"]
                .as_str()
                .map(String::from)
                .or_else(|| c["cid"].as_i64().map(|n| n.to_string())),
            user_id: p.get(3).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
            count: 1,
        });
    }
    if out.is_empty() {
        return Err("JSON 中没有可用弹幕".into());
    }
    Ok(out)
}

// ============ ASS / SSA(字幕版弹幕,尽力解析)============
// Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text

fn ass_color_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\\c&H([0-9A-Fa-f]{6,8})&").expect("ass color regex"))
}

fn ass_override_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\{[^}]*\}").expect("ass override regex"))
}

/// `H:MM:SS.cc` → 秒。畸形返回 None(不是 0 —— 那会把弹幕静默堆到片头)。
fn parse_ass_time(s: &str) -> Option<f64> {
    let (h, rest) = s.split_once(':')?;
    let (m, sec) = rest.split_once(':')?;
    let (whole, frac) = match sec.split_once(['.', ':']) {
        Some((w, f)) => (w, f),
        None => (sec, ""),
    };
    let secs = h.trim().parse::<f64>().ok()? * 3600.0
        + m.trim().parse::<f64>().ok()? * 60.0
        + whole.trim().parse::<f64>().ok()?;
    let frac = if frac.is_empty() {
        0.0
    } else {
        format!("0.{frac}").parse::<f64>().ok()?
    };
    Some(secs + frac)
}

pub fn parse_ass(content: &str) -> Result<Vec<DanmakuComment>, String> {
    let mut out = Vec::new();
    for raw in content.replace("\r\n", "\n").split('\n') {
        let Some(body) = raw.trim().strip_prefix("Dialogue:") else { continue };
        // splitn(10) 正是 translation.rs::split_ass_fields 的行为:前 9 段按逗号切,
        // 第 10 段(Text)整块留下 —— 台词里的逗号不能被切碎。stdlib 够用,不抄那个私有函数。
        let parts: Vec<&str> = body.trim_start().splitn(10, ',').collect();
        if parts.len() < 10 {
            continue;
        }
        let Some(time) = parse_ass_time(parts[1].trim()) else { continue };
        let raw_text = parts[9];

        // 位置:\an8(或老式 \a6/\a7)=顶,\an1/2/3=底,其余滚动。
        let mode = if ["\\an8", "\\a6", "\\a7"].iter().any(|t| raw_text.contains(t)) {
            5
        } else if ["\\an1", "\\an2", "\\an3"].iter().any(|t| raw_text.contains(t)) {
            4
        } else {
            1
        };
        // 颜色:首个 \c&Hbbggrr&(ASS 存的是 BGR,要翻成 RGB)。
        let color = ass_color_re()
            .captures(raw_text)
            .and_then(|c| {
                let hex = c.get(1)?.as_str();
                let bgr = &hex[hex.len() - 6..]; // 8 位形式是 AABBGGRR,丢掉 alpha
                let n = |i: usize| i32::from_str_radix(&bgr[i..i + 2], 16).ok();
                Some((n(4)? << 16) | (n(2)? << 8) | n(0)?)
            })
            .unwrap_or(WHITE);

        let text = ass_override_re()
            .replace_all(&raw_text.replace("\\N", " "), "")
            .trim()
            .to_string();
        if text.is_empty() {
            continue;
        }
        out.push(DanmakuComment {
            time,
            text,
            mode,
            color,
            source: SOURCE.into(),
            cid: None,
            user_id: None,
            count: 1,
        });
    }
    if out.is_empty() {
        return Err("ASS 中未解析到弹幕(Dialogue 行为空)".into());
    }
    out.sort_by(|a, b| a.time.partial_cmp(&b.time).unwrap_or(std::cmp::Ordering::Equal));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---------- XML ----------

    const XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<i>
  <chatserver>chat.bilibili.com</chatserver>
  <maxlimit>8000</maxlimit>
  <d p="12.34500,1,25,16777215,1690000000,0,a1b2c3d4,123456789">前方高能</d>
  <d p="60.100,5,25,16711680,1690000001,0,ffff0000,123456790">顶部红字</d>
  <d p="90.000,4,25,255,1690000002,0,deadbeef,123456791">底部蓝字</d>
</i>"#;

    #[test]
    fn xml_real_sample() {
        let out = parse_xml(XML).unwrap();
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].time, 12.345);
        assert_eq!(out[0].text, "前方高能");
        assert_eq!(out[0].mode, 1);
        // 颜色在 index3(index2=25 是字号)。抄成 index2 就是那种「不崩、颜色全错」的静默 bug。
        assert_eq!(out[0].color, 16777215);
        assert_eq!(out[0].source, "本地导入");
        assert_eq!(out[0].user_id.as_deref(), Some("a1b2c3d4"));
        assert_eq!(out[0].count, 1);
        assert_eq!((out[1].mode, out[1].color), (5, 16711680));
        assert_eq!((out[2].mode, out[2].color), (4, 255));
    }

    #[test]
    fn xml_escapes_are_decoded() {
        let xml = r#"<i><d p="1,1,25,16777215">a &amp; b &lt;tag&gt; &quot;q&quot; &#39;s&#39;</d>
<d p="2,1,25,16777215">&amp;lt; 不该被二次解码</d></i>"#;
        let out = parse_xml(xml).unwrap();
        assert_eq!(out[0].text, r#"a & b <tag> "q" 's'"#);
        assert_eq!(out[1].text, "&lt; 不该被二次解码");
    }

    #[test]
    fn xml_malformed_entries_skipped_not_defaulted() {
        let xml = r#"<i>
  <data>不是弹幕节点</data>
  <d p="10.5,1,25,16777215">好的</d>
  <d p="abc,1,25,16777215">时间非数字 → 跳过(不能默认成 0 秒堆片头)</d>
  <d p="">p 全空 → 跳过</d>
  <d p="20">字段不足:只有时间 → 保留,mode/color 用默认</d>
  <d p="30,x,y,z">mode/color 非数字 → 保留,退默认</d>
  <d p="40,1,25,16777215">   </d>
  <d p="50,1,25,16777215"/>
  <d p="60,1,25,16777215">自闭合之后还能继续扫</d>
</i>"#;
        let out = parse_xml(xml).unwrap();
        let times: Vec<f64> = out.iter().map(|c| c.time).collect();
        assert_eq!(times, vec![10.5, 20.0, 30.0, 60.0], "非数字时间/空文本/自闭合该跳过");
        assert_eq!(out[0].text, "好的", "<data> 不该被当成 <d>");
        assert_eq!((out[1].mode, out[1].color), (1, WHITE), "字段不足退默认");
        assert_eq!((out[2].mode, out[2].color), (1, WHITE), "非数字退默认");
    }

    #[test]
    fn xml_without_any_d_node_is_err() {
        // 红线:解析不出弹幕必须 Err,不能返回空 Vec 让用户看到「加载成功但一条都没有」。
        assert!(parse_xml("<i><chatserver>x</chatserver></i>").is_err());
        assert!(parse_xml("not xml at all").is_err());
    }

    // ---------- JSON ----------

    const JSON: &str = r#"{"count":3,"comments":[
      {"cid":1001,"p":"12.34,1,16777215,user_a","m":"弹弹play 导出"},
      {"cid":1002,"p":"56.78,5,16711680,user_b","m":"顶部红字"},
      {"cid":1003,"p":"90.00,4,255,user_c","m":"底部蓝字"}
    ]}"#;

    #[test]
    fn json_real_sample_color_index_differs_from_xml() {
        let out = parse_json(JSON).unwrap();
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].time, 12.34);
        assert_eq!(out[0].text, "弹弹play 导出");
        // p 只有 4 段:color 在 index2。若按 XML 的 index3 取会拿到 "user_a" → 全退白色。
        assert_eq!(out[0].color, 16777215);
        assert_eq!(out[0].user_id.as_deref(), Some("user_a"));
        assert_eq!(out[0].cid.as_deref(), Some("1001"));
        assert_eq!((out[1].mode, out[1].color), (5, 16711680));
        assert_eq!((out[2].mode, out[2].color), (4, 255));
    }

    #[test]
    fn json_bare_array_and_data_key() {
        let bare = r#"[{"p":"1,1,255,u","m":"裸数组"}]"#;
        assert_eq!(parse_json(bare).unwrap()[0].text, "裸数组");
        let wrapped = r#"{"data":[{"p":"2,1,255,u","m":"data 键"}]}"#;
        assert_eq!(parse_json(wrapped).unwrap()[0].text, "data 键");
    }

    #[test]
    fn json_malformed_entries_and_file_level_errors() {
        let messy = r#"{"comments":[
          {"p":"5,1,255,u","m":"好的"},
          {"p":"nope,1,255,u","m":"时间非数字 → 跳过"},
          {"p":"6","m":"字段不足 → 默认 mode/color"},
          {"p":"7,x,y,u","m":"非数字 → 默认"},
          {"p":"8,1,255,u","m":""},
          {"p":"9,1,255,u"}
        ]}"#;
        let out = parse_json(messy).unwrap();
        assert_eq!(out.iter().map(|c| c.time).collect::<Vec<_>>(), vec![5.0, 6.0, 7.0]);
        assert_eq!((out[1].mode, out[1].color), (1, WHITE));
        assert_eq!((out[2].mode, out[2].color), (1, WHITE));
        // 文件级失败一律 Err。
        assert!(parse_json("{ not json").is_err());
        assert!(parse_json(r#"{"foo":1}"#).is_err(), "没有 comments/data 该 Err");
        assert!(parse_json(r#"{"comments":[]}"#).is_err(), "空列表该 Err 而非空 Vec");
        assert!(parse_json(r#"{"comments":[{"p":"bad","m":"x"}]}"#).is_err(), "全跳过=没弹幕→Err");
    }

    // ---------- ASS ----------

    const ASS: &str = r#"[Script Info]
Title: Danmaku
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,25

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:12.34,0:00:20.00,Default,,0,0,0,,{\move(1920,50,0,50)}滚动弹幕,带逗号
Dialogue: 0,0:01:00.50,0:01:05.00,Default,,0,0,0,,{\an8\c&H0000FF&}顶部红字
Dialogue: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,{\an2\c&HFF0000&}底部蓝字
Dialogue: 0,0:00:30.00,0:00:35.00,Default,,0,0,0,,{\an8}第一行\N第二行
"#;

    #[test]
    fn ass_real_sample() {
        let out = parse_ass(ASS).unwrap();
        assert_eq!(out.len(), 4);
        // 按时间排序:5 / 12.34 / 30 / 60.5
        assert_eq!(out.iter().map(|c| c.time).collect::<Vec<_>>(), vec![5.0, 12.34, 30.0, 60.5]);
        // 底部蓝字:\an2 → mode 4;\c&HFF0000& 是 BGR → RGB 0x0000FF = 255。
        assert_eq!((out[0].mode, out[0].color), (4, 255));
        assert_eq!(out[0].text, "底部蓝字");
        // 特效标签剥掉,Text 里的逗号保住(splitn(10) 的功劳)。
        assert_eq!(out[1].text, "滚动弹幕,带逗号");
        assert_eq!((out[1].mode, out[1].color), (1, WHITE), "无 \\an/\\c → 滚动 + 白");
        // \N → 空格。
        assert_eq!(out[2].text, "第一行 第二行");
        assert_eq!(out[2].mode, 5);
        // \an8 + \c&H0000FF&(BGR) → 顶部 + RGB 0xFF0000。
        assert_eq!((out[3].mode, out[3].color), (5, 16711680));
        assert_eq!(out[3].text, "顶部红字");
        assert_eq!(out[3].source, "本地导入");
    }

    #[test]
    fn ass_override_tags_fully_stripped() {
        let ass = "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,D,,0,0,0,,{\\pos(1,2)\\fad(200,200)\\c&H00FF00&\\fs30}干净文本{\\r}\n";
        let out = parse_ass(ass).unwrap();
        assert_eq!(out[0].text, "干净文本");
        assert_eq!(out[0].color, 65280, "\\c&H00FF00& BGR → RGB 0x00FF00");
    }

    #[test]
    fn ass_alpha_color_and_malformed_lines() {
        let ass = r#"[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,D,,0,0,0,,{\c&H8000FF00&}八位带 alpha
Dialogue: 0,bad-time,0:00:02.00,D,,0,0,0,,时间畸形 → 跳过
Dialogue: 0,0:00:03.00,0:00:04.00,D,,0,0
Dialogue: 0,0:00:05.00,0:00:06.00,D,,0,0,0,,{\pos(1,2)}
Comment: 0,0:00:07.00,0:00:08.00,D,,0,0,0,,注释行不算弹幕
"#;
        let out = parse_ass(ass).unwrap();
        assert_eq!(out.len(), 1, "只有第一行是有效弹幕");
        assert_eq!(out[0].color, 65280, "AABBGGRR 该丢掉 alpha 只取 BBGGRR");
        assert_eq!(out[0].text, "八位带 alpha");
    }

    #[test]
    fn ass_time_forms() {
        assert_eq!(parse_ass_time("0:00:12.34"), Some(12.34));
        assert_eq!(parse_ass_time("1:02:03.50"), Some(3723.5));
        assert_eq!(parse_ass_time("0:00:05"), Some(5.0));
        assert_eq!(parse_ass_time("0:00:05.5"), Some(5.5)); // .5 是 500ms 不是 5ms
        assert_eq!(parse_ass_time("bad"), None);
        assert_eq!(parse_ass_time("0:00"), None);
        assert_eq!(parse_ass_time("x:00:01.00"), None);
    }

    #[test]
    fn ass_no_dialogue_is_err() {
        assert!(parse_ass("[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start\n").is_err());
    }

    // ---------- 分派 / 嗅探 ----------

    #[test]
    fn sniff_by_content_not_extension() {
        // ASS 首字符也是 '[' —— 必须先于 JSON 判,否则每个 ASS 都报「JSON 解析失败」。
        assert_eq!(sniff(ASS), Some(LocalFormat::Ass));
        assert_eq!(sniff(XML), Some(LocalFormat::Xml));
        assert_eq!(sniff(JSON), Some(LocalFormat::Json));
        assert_eq!(sniff(r#"[{"p":"1,1,255,u","m":"x"}]"#), Some(LocalFormat::Json));
        assert_eq!(sniff("   \n\t"), None);
        assert_eq!(sniff("随便一段文本"), None);
        // 扩展名骗人也照样认对内容。
        assert_eq!(parse("danmaku.json", XML).unwrap().len(), 3);
        assert_eq!(parse("danmaku.xml", JSON).unwrap().len(), 3);
        assert_eq!(parse("danmaku.txt", ASS).unwrap().len(), 4);
        // 无后缀 + 认得出内容也行。
        assert_eq!(parse("danmaku", XML).unwrap().len(), 3);
    }

    #[test]
    fn parse_empty_and_unknown_are_err() {
        assert!(parse("a.xml", "").is_err(), "空文件必须 Err");
        assert!(parse("a.xml", "   \n\r\n  ").is_err(), "全空白必须 Err");
        assert!(parse("a.bin", "随便一段既不是 xml 也不是 json 的东西").is_err());
        // 嗅探不出但扩展名说是 xml → 交给 parse_xml,由它给出具体错误(仍是 Err)。
        let e = parse("a.xml", "纯文本").unwrap_err();
        assert!(e.contains("XML"), "错误信息该点名格式, got {e}");
        assert!(SUPPORTED_EXTENSIONS.contains(&"ssa"));
    }
}
