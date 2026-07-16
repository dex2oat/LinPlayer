// 字幕翻译 —— 迁自 Dart lib/core/services/translation/。
//
// 平台无关部分全部收在本文件:
//   1. 文档模型:SRT/VTT/ASS 解析 → SubtitleCue → 重组回 SRT(双语排版)。
//   2. 语言映射:Emby/ISO 各式语言码 → 内部基准码 → 百度/腾讯码 / AI 提示词用人名。
//   3. 五个引擎:OpenAI / Anthropic / 百度通用 / 百度大模型 / 腾讯(TC3 签名)。
//   4. 服务层:按引擎能力分块 → 有界并发 → 失败二分重试 → 回退原文 → 文件缓存。
//   5. 流式翻译:cue 级缓存 + 双语组合(播放器侧的 cue 观测/叠加层由宿主驱动)。
//   6. Whisper:外部 ffmpeg/whisper-cli 进程调用 + 模型下载(桌面;安卓编得过但跑不了)。
//
// 【宿主层契约】本 crate 不碰播放器。宿主需提供:
//   - 流式:观测到字幕 cue 文本 → 调 StreamingTranslator::on_cue → 拿显示文本喂叠加层;
//           并负责隐藏 mpv 原生字幕(sub-visibility=no)、停用时恢复。
//   - 预读:宿主用 mpv `sub-step` 偷看后续 cue 文本 → 调 StreamingTranslator::warm 预热。
//   - 整轨:拿到 translate_subtitle_url 返回的 SRT 路径 → loadLibassSubtitle 加载。
//   - Whisper 流式:宿主提供当前播放位置 → 驱动 WhisperStream::advance 循环 → 每次回调重载 SRT。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// 给子进程加 Windows `CREATE_NO_WINDOW`,不弹黑色 cmd 窗口(用户 2026-07-16:设置里探测
/// ffmpeg/whisper 每次都闪一下 cmd 窗)。stdout/stderr 置 null 不足以压掉控制台窗口,必须这个 flag。
/// 非 Windows 平台是空操作。
#[cfg(windows)]
fn hide_window(cmd: &mut std::process::Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
}
#[cfg(not(windows))]
fn hide_window(_cmd: &mut std::process::Command) {}
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::task::JoinSet;

// ============================================================================
// 1. 文档模型
// ============================================================================

/// 一条字幕对白(归一化后的中间表示)。
///
/// 时间用毫秒整数(而非 Dart 的 Duration):既方便跨 FFI/JSON 传给宿主,也免掉序列化歧义。
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SubtitleCue {
    pub start_ms: u64,
    pub end_ms: u64,
    /// 原文(多行以 `\n` 连接,已去除 ASS 覆盖标签)。
    pub text: String,
    /// 译文,翻译完成后填充。
    #[serde(default)]
    pub translated_text: Option<String>,
}

impl SubtitleCue {
    pub fn new(start_ms: u64, end_ms: u64, text: impl Into<String>) -> Self {
        Self { start_ms, end_ms, text: text.into(), translated_text: None }
    }
}

/// 双语字幕排版方式。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub enum BilingualLayout {
    /// 仅译文。
    TranslatedOnly,
    /// 译文在上,原文在下。
    #[default]
    TranslatedFirst,
    /// 原文在上,译文在下。
    OriginalFirst,
}

impl BilingualLayout {
    /// 存盘键(与 Dart enum name 一致,老配置/前端字符串通用)。
    pub fn storage_key(&self) -> &'static str {
        match self {
            Self::TranslatedOnly => "translatedOnly",
            Self::TranslatedFirst => "translatedFirst",
            Self::OriginalFirst => "originalFirst",
        }
    }
    pub fn from_key(k: &str) -> Self {
        match k {
            "translatedOnly" => Self::TranslatedOnly,
            "originalFirst" => Self::OriginalFirst,
            _ => Self::TranslatedFirst,
        }
    }
}

/// 字幕文档:把各格式解析成 [`SubtitleCue`],并序列化成 SRT。
#[derive(Clone, Debug, Default)]
pub struct SubtitleDocument {
    pub cues: Vec<SubtitleCue>,
}

impl SubtitleDocument {
    pub fn new(cues: Vec<SubtitleCue>) -> Self {
        Self { cues }
    }
    pub fn is_empty(&self) -> bool {
        self.cues.is_empty()
    }

    /// 从文件解析;按扩展名选择解析器,未知扩展名时按内容嗅探。
    pub fn parse_file(path: &str) -> Result<Self, String> {
        let content = std::fs::read_to_string(path).map_err(|e| format!("读取字幕文件失败: {e}"))?;
        let ext = std::path::Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        Ok(Self::parse_str(&content, &ext))
    }

    /// 按扩展名解析;`ext` 传空则按内容嗅探(SRT 兜底)。
    pub fn parse_str(content: &str, ext: &str) -> Self {
        match ext {
            "srt" => Self::new(parse_srt(content)),
            "vtt" | "webvtt" => Self::new(parse_vtt(content)),
            "ass" | "ssa" => Self::new(parse_ass(content)),
            _ => {
                // 内容嗅探兜底。
                let trimmed = content.trim_start();
                if trimmed.starts_with("[Script Info]") || trimmed.contains("[Events]") {
                    Self::new(parse_ass(content))
                } else if trimmed.starts_with("WEBVTT") {
                    Self::new(parse_vtt(content))
                } else {
                    Self::new(parse_srt(content))
                }
            }
        }
    }

    /// 序列化为 SRT。[`BilingualLayout`] 控制是否带原文双语。
    pub fn to_srt(&self, layout: BilingualLayout) -> String {
        let mut out = String::new();
        let mut index = 1;
        for cue in &self.cues {
            let body = compose_body(cue, layout);
            if body.trim().is_empty() {
                continue;
            }
            out.push_str(&format!(
                "{index}\n{} --> {}\n{body}\n\n",
                fmt_srt(cue.start_ms),
                fmt_srt(cue.end_ms)
            ));
            index += 1;
        }
        out
    }
}

fn compose_body(cue: &SubtitleCue, layout: BilingualLayout) -> String {
    let translated = cue.translated_text.as_deref().unwrap_or("").trim();
    let original = cue.text.trim();
    if translated.is_empty() {
        return original.to_string();
    }
    match layout {
        BilingualLayout::TranslatedOnly => translated.to_string(),
        BilingualLayout::TranslatedFirst => format!("{translated}\n{original}"),
        BilingualLayout::OriginalFirst => format!("{original}\n{translated}"),
    }
}

// ---------- SRT / VTT 解析 ----------

/// SRT/VTT 时间轴行。逗号/点号小数分隔符都吃。
fn srt_time_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(
            r"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})",
        )
        .expect("srt time regex")
    })
}

fn caps_ms(c: &regex::Captures, g: usize) -> u64 {
    let n = |i: usize| c.get(i).map_or(0u64, |m| m.as_str().parse().unwrap_or(0));
    // 毫秒位数不足要右补零:`,5` 是 500ms 不是 5ms。
    let raw = c.get(g + 3).map_or("0", |m| m.as_str());
    let ms: u64 = format!("{raw:0<3}")[..3].parse().unwrap_or(0);
    n(g) * 3_600_000 + n(g + 1) * 60_000 + n(g + 2) * 1000 + ms
}

/// 拆成空行分隔的块(先归一化 CRLF)。
fn blocks(content: &str) -> Vec<Vec<String>> {
    let norm = content.replace("\r\n", "\n");
    let mut out = Vec::new();
    let mut cur: Vec<String> = Vec::new();
    for line in norm.split('\n') {
        if line.trim().is_empty() {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(line.to_string());
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn parse_srt(content: &str) -> Vec<SubtitleCue> {
    let mut cues = Vec::new();
    for lines in blocks(content) {
        // 时间轴只可能在块的前两行(第一行常是序号)。
        let Some(i) = (0..lines.len().min(2)).find(|&i| srt_time_re().is_match(&lines[i])) else {
            continue;
        };
        let Some(c) = srt_time_re().captures(&lines[i]) else { continue };
        let text = strip_tags(&lines[i + 1..].join("\n"));
        if text.is_empty() {
            continue;
        }
        cues.push(SubtitleCue::new(caps_ms(&c, 1), caps_ms(&c, 5), text));
    }
    cues
}

fn parse_vtt(content: &str) -> Vec<SubtitleCue> {
    static TAG: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let tag = TAG.get_or_init(|| regex::Regex::new(r"<[^>]+>").expect("vtt tag regex"));
    let mut cues = Vec::new();
    for lines in blocks(content) {
        // VTT 块可能带 cue 标识行,时间轴不限定在前两行。
        let Some(i) = (0..lines.len()).find(|&i| srt_time_re().is_match(&lines[i])) else {
            continue;
        };
        let Some(c) = srt_time_re().captures(&lines[i]) else { continue };
        // 去掉 VTT 内联标签 <c>、<v Name> 等。
        let body = lines[i + 1..].join("\n");
        let text = strip_tags(&tag.replace_all(&body, ""));
        if text.is_empty() {
            continue;
        }
        cues.push(SubtitleCue::new(caps_ms(&c, 1), caps_ms(&c, 5), text));
    }
    cues
}

// ---------- ASS/SSA 解析 ----------

const ASS_DEFAULT_FORMAT: &[&str] = &[
    "Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text",
];

fn parse_ass(content: &str) -> Vec<SubtitleCue> {
    let mut cues = Vec::new();
    let mut in_events = false;
    let mut format: Vec<String> = ASS_DEFAULT_FORMAT.iter().map(|s| s.to_string()).collect();
    for raw in content.replace("\r\n", "\n").split('\n') {
        let line = raw.trim();
        if line.starts_with('[') {
            in_events = line == "[Events]";
            continue;
        }
        if !in_events {
            continue;
        }
        if let Some(rest) = line.strip_prefix("Format:") {
            format = rest.split(',').map(|e| e.trim().to_string()).collect();
            continue;
        }
        let Some(body) = line.strip_prefix("Dialogue:") else { continue };
        let fields = split_ass_fields(body.trim_start(), format.len());
        let idx = |name: &str| format.iter().position(|f| f == name);
        let (Some(si), Some(ei), Some(ti)) = (idx("Start"), idx("End"), idx("Text")) else {
            continue;
        };
        if fields.len() <= ti {
            continue;
        }
        let text = strip_ass(&fields[ti]);
        if text.is_empty() {
            continue;
        }
        cues.push(SubtitleCue::new(
            parse_ass_time(fields[si].trim()),
            parse_ass_time(fields[ei].trim()),
            text,
        ));
    }
    cues
}

/// 按逗号切前 `expected-1` 段,余下整块当最后一个字段——Text 里的逗号不能被切碎。
fn split_ass_fields(input: &str, expected: usize) -> Vec<String> {
    if expected <= 1 {
        return vec![input.to_string()];
    }
    let mut out = Vec::new();
    let mut start = 0;
    for (i, ch) in input.char_indices() {
        if ch != ',' {
            continue;
        }
        if out.len() >= expected - 1 {
            break;
        }
        out.push(input[start..i].to_string());
        start = i + 1;
    }
    out.push(input[start..].to_string());
    out
}

fn strip_ass(text: &str) -> String {
    static OVERRIDE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static NEWLINE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let nl = NEWLINE.get_or_init(|| regex::Regex::new(r"(?i)\\N").expect("ass newline regex"));
    let ov = OVERRIDE.get_or_init(|| regex::Regex::new(r"\{[^}]*\}").expect("ass override regex"));
    let r = nl.replace_all(text, "\n");
    let r = ov.replace_all(&r, ""); // 覆盖标签 {\an8} 等
    strip_tags(&r)
}

/// 逐行 trim 并丢空行。
fn strip_tags(text: &str) -> String {
    text.split('\n')
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// ASS 时间 `H:MM:SS.cc`(百分秒)。
fn parse_ass_time(t: &str) -> u64 {
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() != 3 {
        return 0;
    }
    let h: u64 = parts[0].parse().unwrap_or(0);
    let m: u64 = parts[1].parse().unwrap_or(0);
    let sec: Vec<&str> = parts[2].split('.').collect();
    let s: u64 = sec[0].parse().unwrap_or(0);
    let cs: u64 = if sec.len() > 1 {
        format!("{:0<2}", sec[1])[..2].parse().unwrap_or(0)
    } else {
        0
    };
    h * 3_600_000 + m * 60_000 + s * 1000 + cs * 10
}

fn fmt_srt(ms: u64) -> String {
    let (h, m, s, milli) = (ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000);
    format!("{h:02}:{m:02}:{s:02},{milli:03}")
}

// ============================================================================
// 2. 语言映射
// ============================================================================

pub mod lang {
    /// 自动检测源语言。
    pub const AUTO: &str = "auto";
    /// 通用目标默认中文。
    pub const TARGET_CHINESE: &str = "zh";

    /// 把各式语言码归一为内部基准码(剥离地区后缀、三字母转两字母、繁简区分)。
    ///
    /// 例:`en-GB`→`en`、`zh-TW`→`zh-hant`、`jpn`→`ja`、`fre`→`fr`、`ita`→`it`。
    pub fn norm(code: &str) -> String {
        let c = code.to_lowercase().trim().replace('_', "-");
        if c.is_empty() || c == "auto" || c == "und" {
            return "auto".into();
        }
        // 繁体中文家族。
        if matches!(c.as_str(), "cht" | "zh-tw" | "zh-hant" | "zh-hk" | "zh-mo" | "big5") {
            return "zh-hant".into();
        }
        // 简体/泛中文家族。
        if matches!(c.as_str(), "chs" | "chi" | "zho" | "gb") || c.starts_with("zh") {
            return "zh-hans".into();
        }
        let base = c.split('-').next().unwrap_or(&c);
        let three = [
            ("eng", "en"), ("jpn", "ja"), ("kor", "ko"), ("fre", "fr"), ("fra", "fr"),
            ("ger", "de"), ("deu", "de"), ("rus", "ru"), ("spa", "es"), ("ita", "it"),
            ("por", "pt"), ("tha", "th"), ("vie", "vi"), ("ara", "ar"), ("hin", "hi"),
            ("ind", "id"), ("msa", "ms"), ("may", "ms"), ("tur", "tr"), ("nld", "nl"),
            ("dut", "nl"), ("pol", "pl"),
        ];
        three
            .iter()
            .find(|(k, _)| *k == base)
            .map(|(_, v)| v.to_string())
            .unwrap_or_else(|| base.to_string())
    }

    /// 内部基准码 → 百度码(日语 jp,中文 zh/cht,未知回退 auto)。
    pub fn to_baidu(code: &str) -> &'static str {
        match norm(code).as_str() {
            "zh-hans" => "zh",
            "zh-hant" => "cht",
            "en" => "en",
            "ja" => "jp",
            "ko" => "kor",
            "fr" => "fra",
            "de" => "de",
            "ru" => "ru",
            "es" => "spa",
            "it" => "it",
            "pt" => "pt",
            "th" => "th",
            "vi" => "vie",
            "ar" => "ara",
            "nl" => "nl",
            "pl" => "pl",
            _ => "auto",
        }
    }

    /// 内部基准码 → 腾讯码(日语 ja,中文 zh/zh-TW,未知回退 auto)。
    pub fn to_tencent(code: &str) -> &'static str {
        match norm(code).as_str() {
            "zh-hans" => "zh",
            "zh-hant" => "zh-TW",
            "en" => "en",
            "ja" => "ja",
            "ko" => "ko",
            "fr" => "fr",
            "de" => "de",
            "ru" => "ru",
            "es" => "es",
            "it" => "it",
            "pt" => "pt",
            "th" => "th",
            "vi" => "vi",
            "ar" => "ar",
            "id" => "id",
            "ms" => "ms",
            "tr" => "tr",
            "hi" => "hi",
            _ => "auto",
        }
    }

    /// 内部基准码 → 人类可读语言名(喂给 AI 提示词)。
    pub fn human_name(code: &str) -> String {
        let n = norm(code);
        let name = match n.as_str() {
            "auto" => "the source language",
            "zh-hans" => "Simplified Chinese",
            "zh-hant" => "Traditional Chinese",
            "en" => "English",
            "ja" => "Japanese",
            "ko" => "Korean",
            "fr" => "French",
            "de" => "German",
            "ru" => "Russian",
            "es" => "Spanish",
            "it" => "Italian",
            "pt" => "Portuguese",
            "th" => "Thai",
            "vi" => "Vietnamese",
            "ar" => "Arabic",
            // 未知码原样喂给模型(与 Dart 一致:返回传入的 code 而非归一码)。
            _ => return code.to_string(),
        };
        name.to_string()
    }
}

// ============================================================================
// 3. 引擎种类与配置
// ============================================================================

/// 引擎种类。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub enum TranslationEngineKind {
    #[default]
    Openai,
    Anthropic,
    BaiduGeneral,
    BaiduLlm,
    Tencent,
}

impl TranslationEngineKind {
    pub fn storage_key(&self) -> &'static str {
        match self {
            Self::Openai => "openai",
            Self::Anthropic => "anthropic",
            Self::BaiduGeneral => "baiduGeneral",
            Self::BaiduLlm => "baiduLlm",
            Self::Tencent => "tencent",
        }
    }
    pub fn from_key(k: &str) -> Self {
        match k {
            "anthropic" => Self::Anthropic,
            "baiduGeneral" => Self::BaiduGeneral,
            "baiduLlm" => Self::BaiduLlm,
            "tencent" => Self::Tencent,
            _ => Self::Openai,
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::Openai => "AI · OpenAI 格式",
            Self::Anthropic => "AI · Anthropic 格式",
            Self::BaiduGeneral => "百度通用翻译",
            Self::BaiduLlm => "百度大模型翻译",
            Self::Tencent => "腾讯机器翻译",
        }
    }
    pub fn is_ai(&self) -> bool {
        matches!(self, Self::Openai | Self::Anthropic)
    }
}

/// AI 引擎配置(OpenAI / Anthropic 通用)。
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AiEngineConfig {
    #[serde(default)]
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub model: String,
}

impl AiEngineConfig {
    pub fn is_configured(&self) -> bool {
        !self.api_key.is_empty() && !self.base_url.is_empty()
    }
    pub fn openai_default() -> Self {
        Self {
            base_url: "https://api.openai.com/v1".into(),
            api_key: String::new(),
            model: "gpt-4o-mini".into(),
        }
    }
    pub fn anthropic_default() -> Self {
        Self {
            base_url: "https://api.anthropic.com/v1".into(),
            api_key: String::new(),
            model: "claude-haiku-4-5-20251001".into(),
        }
    }
}

/// 百度翻译配置(通用 / 大模型共用,endpoint 可改)。
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct BaiduEngineConfig {
    #[serde(default)]
    pub endpoint: String,
    #[serde(default)]
    pub app_id: String,
    #[serde(default)]
    pub secret_key: String,
    /// 大模型接口的 Bearer API Key(通用接口不用)。
    #[serde(default)]
    pub api_key: String,
}

impl BaiduEngineConfig {
    pub fn is_configured(&self) -> bool {
        !self.app_id.is_empty() && (!self.secret_key.is_empty() || !self.api_key.is_empty())
    }
    /// 通用翻译接口地址(q/from/to/appid/salt/sign,sign=MD5(appid+q+salt+密钥))。
    pub const GENERAL_ENDPOINT: &'static str = "https://fanyi-api.baidu.com/api/trans/vip/translate";
    /// 大模型文本翻译接口(POST JSON + Bearer API Key,model_type=llm)。
    pub const LLM_ENDPOINT: &'static str = "https://fanyi-api.baidu.com/ait/api/aiTextTranslate";
}

/// 腾讯机器翻译配置。
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TencentEngineConfig {
    #[serde(default)]
    pub secret_id: String,
    #[serde(default)]
    pub secret_key: String,
    #[serde(default = "default_region")]
    pub region: String,
    #[serde(default)]
    pub project_id: i64,
}

fn default_region() -> String {
    "ap-beijing".into()
}

impl Default for TencentEngineConfig {
    fn default() -> Self {
        Self {
            secret_id: String::new(),
            secret_key: String::new(),
            region: default_region(),
            project_id: 0,
        }
    }
}

impl TencentEngineConfig {
    pub fn is_configured(&self) -> bool {
        !self.secret_id.is_empty() && !self.secret_key.is_empty()
    }
    pub const ENDPOINT: &'static str = "tmt.tencentcloudapi.com";
}

// ============================================================================
// 4. 引擎抽象与实现
// ============================================================================

/// 翻译引擎接口。实现须保证返回列表与输入等长、顺序一致。
#[async_trait::async_trait]
pub trait TranslationEngine: Send + Sync {
    fn id(&self) -> &str;
    /// 单批可处理的最大条数(服务层据此分块)。
    fn max_batch_size(&self) -> usize;
    /// 单批文本字符数上限(服务层据此分块,0 表示不限制)。
    fn max_batch_chars(&self) -> usize;
    /// 并发批次上限(API 限流敏感的引擎应取 1)。
    fn max_concurrency(&self) -> usize;
    /// 翻译一批文本。语言码为 ISO 风格(auto/zh/ja/en…),返回与输入等长的译文列表。
    async fn translate(
        &self,
        texts: &[String],
        source_lang: &str,
        target_lang: &str,
    ) -> Result<Vec<String>, String>;
}

/// 翻译失败错误串(带引擎名前缀,便于日志/UI 定位)。
fn err(engine: &str, msg: impl std::fmt::Display) -> String {
    format!("[{engine}] {msg}")
}

// ---------- AI 引擎(OpenAI / Anthropic) ----------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AiProtocol {
    OpenAi,
    Anthropic,
}

/// AI 翻译引擎:把一批字幕作为 JSON 数组交给大模型整体翻译。
///
/// 整批翻译相比逐条能让模型看到上下文,质量更好也更省请求数。
/// 两种协议(OpenAI chat/completions、Anthropic messages)只在请求/回包形状上有别。
pub struct AiEngine {
    pub proto: AiProtocol,
    pub config: AiEngineConfig,
    id: String,
}

impl AiEngine {
    pub fn new(proto: AiProtocol, config: AiEngineConfig) -> Self {
        let id = match proto {
            AiProtocol::OpenAi => "openai",
            AiProtocol::Anthropic => "anthropic",
        };
        Self { proto, config, id: id.into() }
    }

    fn system_prompt(target_name: &str) -> String {
        format!(
            "You are a professional subtitle translator. \
             Translate every item of the input JSON array into {target_name}. \
             Rules: (1) Return ONLY a JSON array of strings, same length and order as the input. \
             (2) Keep line breaks inside an item as \\n. \
             (3) Do not merge or split items, add numbering, notes, or romanization. \
             (4) Keep proper nouns natural. Output must be valid JSON, nothing else."
        )
    }

    /// 发送提示词,返回模型纯文本回复。
    async fn complete(&self, system_prompt: &str, user_content: &str) -> Result<String, String> {
        let base = self.config.base_url.trim_end_matches('/');
        let http = crate::http::client();
        let (url, body, headers): (String, serde_json::Value, Vec<(&str, String)>) = match self.proto
        {
            AiProtocol::OpenAi => (
                format!("{base}/chat/completions"),
                serde_json::json!({
                    "model": self.config.model,
                    "temperature": 0.2,
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": user_content},
                    ],
                }),
                vec![("Authorization", format!("Bearer {}", self.config.api_key))],
            ),
            AiProtocol::Anthropic => (
                format!("{base}/messages"),
                serde_json::json!({
                    "model": self.config.model,
                    "max_tokens": 8192,
                    "temperature": 0.2,
                    "system": system_prompt,
                    "messages": [{"role": "user", "content": user_content}],
                }),
                vec![
                    ("x-api-key", self.config.api_key.clone()),
                    ("anthropic-version", "2023-06-01".into()),
                ],
            ),
        };

        let mut rb = http.post(&url).json(&body);
        for (k, v) in headers {
            rb = rb.header(k, v);
        }
        let resp = rb.send().await.map_err(|e| err(self.id(), format!("请求失败: {e}")))?;
        let status = resp.status();
        let data: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| err(self.id(), format!("响应非 JSON (HTTP {status}): {e}")))?;
        if !status.is_success() {
            return Err(err(self.id(), format!("请求失败: HTTP {status} ({data})")));
        }
        let text = match self.proto {
            AiProtocol::OpenAi => data["choices"][0]["message"]["content"].as_str(),
            AiProtocol::Anthropic => data["content"][0]["text"].as_str(),
        };
        match text {
            Some(t) if !t.is_empty() => Ok(t.to_string()),
            _ => Err(err(self.id(), format!("响应为空: {data}"))),
        }
    }
}

/// 从模型回复里抠出 JSON 数组;长度对不上视为失败(交给服务层二分重试)。
fn parse_json_array(raw: &str, expected: usize) -> Option<Vec<String>> {
    let start = raw.find('[')?;
    let end = raw.rfind(']')?;
    if end <= start {
        return None;
    }
    let decoded: serde_json::Value = serde_json::from_str(&raw[start..=end]).ok()?;
    let arr = decoded.as_array()?;
    if arr.len() != expected {
        return None;
    }
    Some(
        arr.iter()
            .map(|v| match v {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Null => String::new(),
                other => other.to_string(),
            })
            .collect(),
    )
}

#[async_trait::async_trait]
impl TranslationEngine for AiEngine {
    fn id(&self) -> &str {
        &self.id
    }
    // AI 单批可承载较多条目,但要控制 token;按条数+字符数双限制。
    fn max_batch_size(&self) -> usize {
        40
    }
    fn max_batch_chars(&self) -> usize {
        4000
    }
    fn max_concurrency(&self) -> usize {
        3
    }

    async fn translate(
        &self,
        texts: &[String],
        _source_lang: &str,
        target_lang: &str,
    ) -> Result<Vec<String>, String> {
        if texts.is_empty() {
            return Ok(vec![]);
        }
        let target_name = lang::human_name(target_lang);
        let user_content =
            serde_json::to_string(texts).map_err(|e| err(self.id(), format!("编码失败: {e}")))?;
        let raw = self.complete(&Self::system_prompt(&target_name), &user_content).await?;
        parse_json_array(&raw, texts.len())
            .ok_or_else(|| err(self.id(), "AI 返回无法解析为等长 JSON 数组"))
    }
}

// ---------- 百度通用翻译 ----------

/// 百度文本翻译引擎(通用接口)。
///
/// sign = MD5(appid + q + salt + 密钥)。多条字幕用 `\n` 拼成单个 q 一次提交,
/// trans_result 按行回包,从而批量翻译。endpoint 可在设置里覆盖以适配官方调整。
pub struct BaiduEngine {
    pub config: BaiduEngineConfig,
    id: String,
    default_endpoint: String,
}

impl BaiduEngine {
    pub fn new(config: BaiduEngineConfig, engine_id: &str, default_endpoint: &str) -> Self {
        Self { config, id: engine_id.into(), default_endpoint: default_endpoint.into() }
    }
    /// 默认的「百度通用翻译」实例(engine_id=baidu_general)。
    pub fn general(config: BaiduEngineConfig) -> Self {
        Self::new(config, "baidu_general", BaiduEngineConfig::GENERAL_ENDPOINT)
    }
    fn endpoint(&self) -> &str {
        if self.config.endpoint.is_empty() {
            &self.default_endpoint
        } else {
            &self.config.endpoint
        }
    }
}

fn md5_hex(s: &str) -> String {
    use md5::Md5;
    let mut h = Md5::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// 百度 salt:任意随机串即可(参与签名)。条数+长度+内容哈希,足够避免重放碰撞。
fn baidu_salt(count: usize, q: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    q.hash(&mut h);
    format!("{count}{}{}", q.len(), h.finish())
}

/// 把每条内部换行压成空格,避免破坏「一行一条」的回包对齐。
fn flatten_lines(texts: &[String]) -> Vec<String> {
    texts.iter().map(|t| t.replace('\n', " ").trim().to_string()).collect()
}

/// 解析百度回包(通用/大模型同构):error_code → 错误,trans_result[].dst → 译文。
fn parse_baidu_response(
    id: &str,
    data: &serde_json::Value,
    expected: usize,
) -> Result<Vec<String>, String> {
    if !data["error_code"].is_null() {
        return Err(err(id, format!("百度翻译错误 {}: {}", data["error_code"], data["error_msg"])));
    }
    let dst: Vec<String> = data["trans_result"]
        .as_array()
        .map(|l| l.iter().map(|e| e["dst"].as_str().unwrap_or("").to_string()).collect())
        .unwrap_or_default();
    if dst.len() != expected {
        // 行数对不齐(百度偶发合并空行),交给服务层缩小批次重试。
        return Err(err(id, format!("回包行数({})与请求({expected})不一致", dst.len())));
    }
    Ok(dst)
}

#[async_trait::async_trait]
impl TranslationEngine for BaiduEngine {
    fn id(&self) -> &str {
        &self.id
    }
    // 百度免费版 QPS=1,必须串行;单条 q 上限 6000 字节,按行数与字符双限。
    fn max_batch_size(&self) -> usize {
        50
    }
    fn max_batch_chars(&self) -> usize {
        2000
    }
    fn max_concurrency(&self) -> usize {
        1
    }

    async fn translate(
        &self,
        texts: &[String],
        source_lang: &str,
        target_lang: &str,
    ) -> Result<Vec<String>, String> {
        if texts.is_empty() {
            return Ok(vec![]);
        }
        let q = flatten_lines(texts).join("\n");
        let salt = baidu_salt(texts.len(), &q);
        let sign = md5_hex(&format!("{}{q}{salt}{}", self.config.app_id, self.config.secret_key));
        let form = [
            ("q", q.as_str()),
            ("from", lang::to_baidu(source_lang)),
            ("to", lang::to_baidu(target_lang)),
            ("appid", self.config.app_id.as_str()),
            ("salt", salt.as_str()),
            ("sign", sign.as_str()),
        ];
        let resp = crate::http::client()
            .post(self.endpoint())
            .form(&form)
            .send()
            .await
            .map_err(|e| err(self.id(), format!("百度翻译请求失败: {e}")))?;
        let status = resp.status();
        let data: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| err(self.id(), format!("响应非 JSON (HTTP {status}): {e}")))?;
        parse_baidu_response(self.id(), &data, texts.len())
    }
}

// ---------- 百度大模型翻译 ----------

/// 百度大模型文本翻译引擎(POST JSON + Bearer API Key)。
///
/// `/ait/api/aiTextTranslate`:body 为 JSON {appid,q,from,to,model_type};
/// 推荐 Bearer 鉴权,未填 apiKey 时回退 appid+salt+sign。回包结构与通用接口一致。
pub struct BaiduLlmEngine {
    pub config: BaiduEngineConfig,
}

impl BaiduLlmEngine {
    pub fn new(config: BaiduEngineConfig) -> Self {
        Self { config }
    }
    fn endpoint(&self) -> &str {
        if self.config.endpoint.is_empty() {
            BaiduEngineConfig::LLM_ENDPOINT
        } else {
            &self.config.endpoint
        }
    }
}

#[async_trait::async_trait]
impl TranslationEngine for BaiduLlmEngine {
    fn id(&self) -> &str {
        "baidu_llm"
    }
    fn max_batch_size(&self) -> usize {
        40
    }
    fn max_batch_chars(&self) -> usize {
        2000 // 单次 q 上限 6000 字符,留余量。
    }
    fn max_concurrency(&self) -> usize {
        1
    }

    async fn translate(
        &self,
        texts: &[String],
        source_lang: &str,
        target_lang: &str,
    ) -> Result<Vec<String>, String> {
        if texts.is_empty() {
            return Ok(vec![]);
        }
        let q = flatten_lines(texts).join("\n");
        let mut body = serde_json::json!({
            "appid": self.config.app_id,
            "q": q,
            "from": lang::to_baidu(source_lang),
            "to": lang::to_baidu(target_lang),
            "model_type": "llm",
        });

        let mut rb = crate::http::client().post(self.endpoint());
        if !self.config.api_key.is_empty() {
            rb = rb.header("Authorization", format!("Bearer {}", self.config.api_key));
        } else {
            // 回退签名鉴权:appid+q+salt+密钥 的 MD5。
            let salt = baidu_salt(texts.len(), &q);
            let sign =
                md5_hex(&format!("{}{q}{salt}{}", self.config.app_id, self.config.secret_key));
            body["salt"] = salt.into();
            body["sign"] = sign.into();
        }

        let resp = rb
            .json(&body)
            .send()
            .await
            .map_err(|e| err(self.id(), format!("百度大模型翻译请求失败: {e}")))?;
        let status = resp.status();
        let data: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| err(self.id(), format!("响应非 JSON (HTTP {status}): {e}")))?;
        parse_baidu_response(self.id(), &data, texts.len())
    }
}

// ---------- 腾讯机器翻译 ----------

/// 腾讯机器翻译引擎(TextTranslateBatch,TC3-HMAC-SHA256 签名,service=tmt)。
pub struct TencentEngine {
    pub config: TencentEngineConfig,
}

const TENCENT_SERVICE: &str = "tmt";
const TENCENT_VERSION: &str = "2018-03-21";

impl TencentEngine {
    pub fn new(config: TencentEngineConfig) -> Self {
        Self { config }
    }

    /// 发起一次腾讯云 V3 签名请求,返回 Response 对象内容(出错抛错)。
    async fn call(
        &self,
        action: &str,
        payload_map: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let payload = payload_map.to_string();
        let ts = now_secs();
        let date = utc_date(ts);
        let authorization = self.build_authorization(action, &payload, ts, &date);
        let host = TencentEngineConfig::ENDPOINT;

        let resp = crate::http::client()
            .post(format!("https://{host}"))
            .header("Authorization", authorization)
            .header("Content-Type", "application/json; charset=utf-8")
            .header("Host", host)
            .header("X-TC-Action", action)
            .header("X-TC-Timestamp", ts.to_string())
            .header("X-TC-Version", TENCENT_VERSION)
            .header("X-TC-Region", &self.config.region)
            .body(payload)
            .send()
            .await
            .map_err(|e| err(self.id(), format!("腾讯翻译请求失败: {e}")))?;
        let status = resp.status();
        let data: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| err(self.id(), format!("响应非 JSON (HTTP {status}): {e}")))?;
        let response = data.get("Response").ok_or_else(|| {
            err(self.id(), format!("腾讯翻译响应缺少 Response 字段 (HTTP {status})"))
        })?;
        if let Some(error) = response.get("Error") {
            if !error.is_null() {
                return Err(err(
                    self.id(),
                    format!("腾讯翻译错误 {}: {}", error["Code"], error["Message"]),
                ));
            }
        }
        Ok(response.clone())
    }

    /// TC3-HMAC-SHA256 Authorization 头。签名头固定 content-type;host;x-tc-action。
    fn build_authorization(&self, action: &str, payload: &str, ts: u64, date: &str) -> String {
        const ALGORITHM: &str = "TC3-HMAC-SHA256";
        const SIGNED_HEADERS: &str = "content-type;host;x-tc-action";
        let host = TencentEngineConfig::ENDPOINT;
        let canonical_headers = format!(
            "content-type:application/json; charset=utf-8\nhost:{host}\nx-tc-action:{}\n",
            action.to_lowercase()
        );
        let canonical_request = format!(
            "POST\n/\n\n{canonical_headers}\n{SIGNED_HEADERS}\n{}",
            sha256_hex(payload.as_bytes())
        );
        let credential_scope = format!("{date}/{TENCENT_SERVICE}/tc3_request");
        let string_to_sign = format!(
            "{ALGORITHM}\n{ts}\n{credential_scope}\n{}",
            sha256_hex(canonical_request.as_bytes())
        );

        let secret_date = hmac_sha256(format!("TC3{}", self.config.secret_key).as_bytes(), date.as_bytes());
        let secret_service = hmac_sha256(&secret_date, TENCENT_SERVICE.as_bytes());
        let secret_signing = hmac_sha256(&secret_service, b"tc3_request");
        let signature = hex(&hmac_sha256(&secret_signing, string_to_sign.as_bytes()));

        format!(
            "{ALGORITHM} Credential={}/{credential_scope}, SignedHeaders={SIGNED_HEADERS}, Signature={signature}",
            self.config.secret_id
        )
    }
}

#[async_trait::async_trait]
impl TranslationEngine for TencentEngine {
    fn id(&self) -> &str {
        "tencent"
    }
    // 腾讯批量接口单次条数有限制,保守取 50;免费 QPS 较低,串行更稳。
    fn max_batch_size(&self) -> usize {
        50
    }
    fn max_batch_chars(&self) -> usize {
        4000
    }
    fn max_concurrency(&self) -> usize {
        1
    }

    async fn translate(
        &self,
        texts: &[String],
        source_lang: &str,
        target_lang: &str,
    ) -> Result<Vec<String>, String> {
        if texts.is_empty() {
            return Ok(vec![]);
        }
        let source = lang::to_tencent(source_lang);
        let target = lang::to_tencent(target_lang);

        // TextTranslateBatch 不支持源语言 auto;源语言未知时退回支持 auto 的单条接口。
        if source == "auto" {
            let mut out = Vec::with_capacity(texts.len());
            for t in texts {
                let r = self
                    .call(
                        "TextTranslate",
                        serde_json::json!({
                            "SourceText": t, "Source": source, "Target": target,
                            "ProjectId": self.config.project_id,
                        }),
                    )
                    .await?;
                out.push(r["TargetText"].as_str().unwrap_or("").to_string());
            }
            return Ok(out);
        }

        let r = self
            .call(
                "TextTranslateBatch",
                serde_json::json!({
                    "Source": source, "Target": target,
                    "ProjectId": self.config.project_id,
                    "SourceTextList": texts,
                }),
            )
            .await?;
        let out: Vec<String> = r["TargetTextList"]
            .as_array()
            .map(|l| l.iter().map(|e| e.as_str().unwrap_or("").to_string()).collect())
            .unwrap_or_default();
        if out.len() != texts.len() {
            return Err(err(
                self.id(),
                format!("回包条数({})与请求({})不一致", out.len(), texts.len()),
            ));
        }
        Ok(out)
    }
}

// ---------- 签名/时间小工具 ----------

fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// HMAC-SHA256(RFC 2104)。手写以免为几行代码多引一个 hmac crate 依赖。
fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut k = [0u8; BLOCK];
    if key.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; BLOCK];
    let mut opad = [0x5cu8; BLOCK];
    for i in 0..BLOCK {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let inner = Sha256::new().chain_update(ipad).chain_update(msg).finalize();
    Sha256::new().chain_update(opad).chain_update(inner).finalize().into()
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Unix 秒 → UTC `YYYY-MM-DD`(腾讯签名的 credential scope 用)。
/// 民用历换算(Howard Hinnant `civil_from_days`),免引 chrono。
fn utc_date(ts: u64) -> String {
    let z = (ts / 86400) as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

// ---------- 引擎工厂 ----------

/// 按种类与配置构造引擎;未配置返回 None(对齐 Dart activeTranslationEngineProvider)。
pub fn build_engine(
    kind: TranslationEngineKind,
    s: &TranslationSettings,
) -> Option<Arc<dyn TranslationEngine>> {
    use TranslationEngineKind::*;
    // 每个分支:没配全 → None(对齐 Dart:UI 据此禁用「翻译」入口)。
    let e: Arc<dyn TranslationEngine> = match kind {
        Openai if s.openai.is_configured() => {
            Arc::new(AiEngine::new(AiProtocol::OpenAi, s.openai.clone()))
        }
        Anthropic if s.anthropic.is_configured() => {
            Arc::new(AiEngine::new(AiProtocol::Anthropic, s.anthropic.clone()))
        }
        BaiduGeneral if s.baidu_general.is_configured() => {
            Arc::new(BaiduEngine::general(s.baidu_general.clone()))
        }
        BaiduLlm if s.baidu_llm.is_configured() => Arc::new(BaiduLlmEngine::new(s.baidu_llm.clone())),
        Tencent if s.tencent.is_configured() => Arc::new(TencentEngine::new(s.tencent.clone())),
        _ => return None,
    };
    Some(e)
}

/// 按当前设置里选中的引擎构造;未配置返回 None。
pub fn active_engine(s: &TranslationSettings) -> Option<Arc<dyn TranslationEngine>> {
    build_engine(s.engine, s)
}

// ============================================================================
// 5. 设置持久化(独立文件,不塞 config.json)
// ============================================================================

/// 翻译模块设置。对齐 Dart translation_providers 的一堆 prefs 键。
///
/// ⚠️ 内含用户填的 apiKey/secretKey:与 config.json 里的 token 同等姿态(明文落盘),
/// 旧 Dart 走 SecureCredentialStore(OS 加密 KV);新栈的加固与 config.rs 的
/// keyring 待决项一并处理,不在本模块单独造轮子。
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TranslationSettings {
    /// 当前选用的翻译引擎。
    #[serde(default)]
    pub engine: TranslationEngineKind,
    /// 翻译目标语言(默认简体中文)。
    #[serde(default = "default_target")]
    pub target_lang: String,
    /// 双语排版方式。
    #[serde(default)]
    pub layout: BilingualLayout,

    #[serde(default = "AiEngineConfig::openai_default")]
    pub openai: AiEngineConfig,
    #[serde(default = "AiEngineConfig::anthropic_default")]
    pub anthropic: AiEngineConfig,
    #[serde(default)]
    pub baidu_general: BaiduEngineConfig,
    #[serde(default)]
    pub baidu_llm: BaiduEngineConfig,
    #[serde(default)]
    pub tencent: TencentEngineConfig,

    /// 是否启用 Whisper 本地转写(默认关闭,用户手动开启后再下载模型)。
    #[serde(default)]
    pub whisper_enabled: bool,
    /// 选用的 Whisper 模型规格。
    #[serde(default)]
    pub whisper_model: WhisperModel,
    /// 模型下载镜像(留空用官方源)。
    #[serde(default)]
    pub whisper_mirror: String,
    /// whisper-cli 可执行文件路径(用户指定,空=自动定位)。
    #[serde(default)]
    pub whisper_binary: String,
    /// ffmpeg 可执行文件路径(音频抽取用,空=自动定位)。
    #[serde(default)]
    pub ffmpeg_path: String,
}

fn default_target() -> String {
    lang::TARGET_CHINESE.into()
}

impl Default for TranslationSettings {
    fn default() -> Self {
        Self {
            engine: TranslationEngineKind::default(),
            target_lang: default_target(),
            layout: BilingualLayout::default(),
            openai: AiEngineConfig::openai_default(),
            anthropic: AiEngineConfig::anthropic_default(),
            baidu_general: BaiduEngineConfig::default(),
            baidu_llm: BaiduEngineConfig::default(),
            tencent: TencentEngineConfig::default(),
            whisper_enabled: false,
            whisper_model: WhisperModel::default(),
            whisper_mirror: String::new(),
            whisper_binary: String::new(),
            ffmpeg_path: String::new(),
        }
    }
}

fn settings_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LinPlayer")
        .join("translation.json")
}

impl TranslationSettings {
    pub fn load() -> Self {
        std::fs::read_to_string(settings_path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }
    pub fn save(&self) -> Result<(), String> {
        let path = settings_path();
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(path, json).map_err(|e| e.to_string())
    }
}

// ============================================================================
// 6. 服务层:分块 / 并发 / 二分重试 / 缓存
// ============================================================================

/// 翻译进度回调:(已完成条数, 总条数, 阶段描述)。
pub type ProgressFn = Arc<dyn Fn(usize, usize, &str) + Send + Sync>;

/// 按引擎能力把 cue 切成批次(返回下标区间)。
/// 与 Dart 一致:条数超限或累计字符超限即断批;单条超限也自成一批(不丢)。
fn chunk_ranges(cues: &[SubtitleCue], max_size: usize, max_chars: usize) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = 0usize;
    for (i, cue) in cues.iter().enumerate() {
        let len = cue.text.chars().count();
        let cur_len = i - start;
        let over_size = cur_len >= max_size;
        let over_chars = max_chars > 0 && chars + len > max_chars;
        if cur_len > 0 && (over_size || over_chars) {
            out.push((start, i));
            start = i;
            chars = 0;
        }
        chars += len;
    }
    if start < cues.len() {
        out.push((start, cues.len()));
    }
    out
}

/// 一批的翻译结果:(译文, 失败条数, 最后错误)。失败条回退原文。
type ChunkOutcome = (Vec<String>, usize, Option<String>);

/// 翻译一块文本;遇引擎抛错(如回包条数不齐)二分重试,单条仍失败则回退原文,
/// 保证不中断整体流程。递归 async → Box::pin。
fn translate_chunk(
    engine: Arc<dyn TranslationEngine>,
    texts: Vec<String>,
    source: String,
    target: String,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ChunkOutcome> + Send>> {
    Box::pin(async move {
        if texts.is_empty() {
            return (vec![], 0, None);
        }
        match engine.translate(&texts, &source, &target).await {
            Ok(v) => (v, 0, None),
            Err(e) => {
                if texts.len() == 1 {
                    // 单条也失败:回退原文并记账,让上层判断引擎是否整体不可用。
                    return (texts, 1, Some(e));
                }
                let mid = texts.len() / 2;
                let right_texts = texts[mid..].to_vec();
                let left_texts = texts[..mid].to_vec();
                let (mut lv, lf, le) =
                    translate_chunk(engine.clone(), left_texts, source.clone(), target.clone())
                        .await;
                let (rv, rf, re) = translate_chunk(engine, right_texts, source, target).await;
                lv.extend(rv);
                (lv, lf + rf, re.or(le))
            }
        }
    })
}

/// 就地翻译一个已解析的文档(填充每条 cue 的 translated_text)。
///
/// 全部条目都失败(回退原文)通常意味着引擎根本不可用(未开通服务/鉴权错误),
/// 此时直接报错而非静默产出未翻译文件。
pub async fn translate_document(
    doc: &mut SubtitleDocument,
    engine: Arc<dyn TranslationEngine>,
    source_lang: &str,
    target_lang: &str,
    on_progress: Option<ProgressFn>,
) -> Result<(), String> {
    let total = doc.cues.len();
    if total == 0 {
        return Ok(());
    }
    let chunks = chunk_ranges(&doc.cues, engine.max_batch_size(), engine.max_batch_chars());
    let concurrency = engine.max_concurrency().clamp(1, 8);
    let (mut done, mut failed, mut last_error) = (0usize, 0usize, None::<String>);

    // 按引擎并发能力分波跑:每波起 concurrency 个批次,等齐再下一波(对齐 Dart Future.wait 切片)。
    for wave in chunks.chunks(concurrency) {
        let mut set = JoinSet::new();
        for &(s, e) in wave {
            let texts: Vec<String> = doc.cues[s..e].iter().map(|c| c.text.clone()).collect();
            let (eng, src, tgt) =
                (engine.clone(), source_lang.to_string(), target_lang.to_string());
            set.spawn(async move { (s, e, translate_chunk(eng, texts, src, tgt).await) });
        }
        while let Some(joined) = set.join_next().await {
            let (s, e, (translated, f, err)) = joined.map_err(|e| format!("翻译任务崩溃: {e}"))?;
            for (cue, t) in doc.cues[s..e].iter_mut().zip(translated) {
                cue.translated_text = Some(t);
            }
            failed += f;
            if err.is_some() {
                last_error = err;
            }
            done += e - s;
            if let Some(p) = &on_progress {
                p(done, total, "翻译中…");
            }
        }
    }

    if failed >= total {
        if let Some(e) = last_error {
            return Err(format!("翻译引擎不可用,全部 {total} 条均失败: {e}"));
        }
    }
    Ok(())
}

/// 粗判内容是否为字幕文本(SRT/VTT/ASS),避免把 404/HTML 错误页当字幕。
fn looks_like_subtitle(body: &str) -> bool {
    if body.trim().is_empty() {
        return false;
    }
    let head: String = body.chars().take(4000).collect();
    head.contains("-->")
        || head.contains("Dialogue:")
        || head.trim_start().starts_with("WEBVTT")
        || head.contains("[Script Info]")
}

/// 依次尝试候选地址,返回第一个「内容确为字幕」的响应体。
///
/// 不同服务端的内封字幕导出路由不一(有的需 `/Subtitles/{i}/0/Stream.srt` 的
/// StartPositionTicks 段,有的给 deliveryUrl),故逐个尝试并校验内容。
pub async fn fetch_first_subtitle(urls: &[String], auth_token: Option<&str>) -> Result<String, String> {
    let http = crate::http::client();
    let mut last_error: Option<String> = None;
    for url in urls.iter().filter(|u| !u.is_empty()) {
        if !url.starts_with("http") {
            // 本地外挂字幕文件。
            match std::fs::read_to_string(url) {
                Ok(body) if looks_like_subtitle(&body) => return Ok(body),
                Ok(_) => continue,
                Err(e) => {
                    last_error = Some(e.to_string());
                    continue;
                }
            }
        }
        let mut rb = http.get(url).timeout(Duration::from_secs(60));
        if let Some(t) = auth_token {
            rb = rb.header("X-Emby-Token", t).header("X-MediaBrowser-Token", t);
        }
        match rb.send().await {
            Ok(resp) => {
                let ok = resp.status().is_success();
                let body = resp.text().await.unwrap_or_default();
                if ok && looks_like_subtitle(&body) {
                    return Ok(body);
                }
            }
            Err(e) => last_error = Some(e.to_string()),
        }
    }
    Err(format!(
        "所有字幕地址均不可用(共 {} 个候选{})",
        urls.len(),
        last_error.map(|e| format!(",最后错误: {e}")).unwrap_or_default()
    ))
}

fn subtitle_cache_dir() -> PathBuf {
    dirs::cache_dir()
        .or_else(dirs::config_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LinPlayer")
        .join("translated_subtitles")
}

fn cache_key(source: &str, engine_id: &str, from: &str, to: &str, layout: BilingualLayout) -> String {
    md5_hex(&format!("{source}|{engine_id}|{from}|{to}|{}", layout.storage_key()))
}

/// 翻译远程/本地字幕文件,返回生成的 SRT 路径(供宿主 loadLibassSubtitle 加载)。
///
/// 管线:拉取源字幕 → 解析为 cue → 分块并发翻译 → 序列化为 SRT → 写缓存文件。
/// 同一 (源, 引擎, 目标语言, 排版) 命中缓存直接复用,避免重复消耗额度。
#[allow(clippy::too_many_arguments)]
pub async fn translate_subtitle_url(
    urls: &[String],
    engine: Arc<dyn TranslationEngine>,
    source_lang: &str,
    target_lang: &str,
    layout: BilingualLayout,
    auth_token: Option<&str>,
    cache_key_seed: &str,
    on_progress: Option<ProgressFn>,
) -> Result<String, String> {
    let dir = subtitle_cache_dir();
    let seed = if cache_key_seed.is_empty() { urls.join("|") } else { cache_key_seed.to_string() };
    let key = cache_key(&seed, engine.id(), source_lang, target_lang, layout);
    let out = dir.join(format!("trans_{key}.srt"));
    if std::fs::metadata(&out).map(|m| m.len() > 0).unwrap_or(false) {
        if let Some(p) = &on_progress {
            p(1, 1, "已使用缓存");
        }
        return Ok(out.to_string_lossy().into_owned());
    }

    if let Some(p) = &on_progress {
        p(0, 1, "下载字幕…");
    }
    let raw = fetch_first_subtitle(urls, auth_token).await?;
    let mut doc = SubtitleDocument::parse_str(&raw, ""); // 按内容嗅探格式
    if doc.is_empty() {
        return Err(format!(
            "源字幕解析为空(拉取 {} 字节)。该轨可能无法被服务端导出为文本",
            raw.len()
        ));
    }

    translate_document(&mut doc, engine, source_lang, target_lang, on_progress).await?;

    std::fs::create_dir_all(&dir).map_err(|e| format!("建缓存目录失败: {e}"))?;
    std::fs::write(&out, doc.to_srt(layout)).map_err(|e| format!("写翻译字幕失败: {e}"))?;
    Ok(out.to_string_lossy().into_owned())
}

/// 构造内封/外挂字幕的候选下载地址(按命中概率排序)。
///
/// 不同 Emby/Jellyfin 服务端的字幕导出路由不一:有的是 `/Subtitles/{i}/Stream.srt`,
/// 有的需要 `/Subtitles/{i}/0/Stream.srt`(StartPositionTicks 段),还可能直接给
/// deliveryUrl/path。逐个尝试以兼容。
///
/// `base` 为当前线路地址(不带尾斜杠),`token` 为 api_key。
pub fn subtitle_url_candidates(
    base: &str,
    token: Option<&str>,
    item_id: &str,
    media_source_id: &str,
    index: i64,
    delivery_url: Option<&str>,
    path: Option<&str>,
) -> Vec<String> {
    let base = base.trim_end_matches('/');
    let mut out: Vec<String> = Vec::new();
    // 服务端直接给出的地址优先(仅取绝对地址)。
    for u in [delivery_url, path].into_iter().flatten() {
        let u = u.trim();
        if u.starts_with("http") {
            out.push(u.to_string());
        }
    }
    // 各封装格式 × 是否带 StartPositionTicks 段;ticks 变体优先(覆盖面更广)。
    let q = token.map(|t| format!("?api_key={t}")).unwrap_or_default();
    for codec in ["srt", "vtt", "ass"] {
        let stem = format!("{base}/Videos/{item_id}/{media_source_id}/Subtitles/{index}");
        out.push(format!("{stem}/0/Stream.{codec}{q}"));
        out.push(format!("{stem}/Stream.{codec}{q}"));
    }
    // 去重并保持顺序。
    let mut seen = std::collections::HashSet::new();
    out.retain(|u| !u.is_empty() && seen.insert(u.clone()));
    out
}

// ============================================================================
// 7. 流式翻译(cue 级)
// ============================================================================

/// 流式字幕翻译器(用于内封等无法整文件下载的字幕轨)的**核心侧**。
///
/// 【宿主契约】本结构只管「文本进、显示文本出」+ 缓存:
///   - 宿主观测到当前 cue → `on_cue(text)` → 拿返回值喂叠加层;缓存命中即秒回。
///   - 宿主用 mpv `sub-step` 从已缓冲区偷看后续 cue → `warm(&texts)` 预热缓存。
///   - 宿主负责 `sub-visibility=no` 隐藏 mpv 原生字幕、停用时恢复(那是播放器的事)。
///   - 停止时调 `clear()` 释放本集缓存,否则长会话内存只增不减。
pub struct StreamingTranslator {
    pub engine: Arc<dyn TranslationEngine>,
    pub source_lang: String,
    pub target_lang: String,
    /// 双语排版:决定叠加层显示「仅译文 / 译文+原文 / 原文+译文」。
    pub layout: BilingualLayout,
    cache: Mutex<HashMap<String, String>>,
}

impl StreamingTranslator {
    pub fn new(
        engine: Arc<dyn TranslationEngine>,
        source_lang: impl Into<String>,
        target_lang: impl Into<String>,
        layout: BilingualLayout,
    ) -> Self {
        Self {
            engine,
            source_lang: source_lang.into(),
            target_lang: target_lang.into(),
            layout,
            cache: Mutex::new(HashMap::new()),
        }
    }

    /// 缓存键:压平空白,避免同一句因换行/空格差异重复消耗额度。
    fn norm(text: &str) -> String {
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    /// 按排版把原文与译文组合成叠加层文本。
    /// 译文为空(尚未译好)时:双语显示原文占位,仅译文显示空。
    pub fn compose(&self, original: &str, translated: &str) -> String {
        let (o, t) = (original.trim(), translated.trim());
        match self.layout {
            BilingualLayout::TranslatedOnly => t.to_string(),
            BilingualLayout::TranslatedFirst if t.is_empty() => o.to_string(),
            BilingualLayout::OriginalFirst if t.is_empty() => o.to_string(),
            BilingualLayout::TranslatedFirst => format!("{t}\n{o}"),
            BilingualLayout::OriginalFirst => format!("{o}\n{t}"),
        }
    }

    /// 查缓存;命中则返回可直接显示的文本(不发请求)。
    pub fn cached_display(&self, text: &str) -> Option<String> {
        let key = Self::norm(text);
        let hit = self.cache.lock().ok()?.get(&key).cloned()?;
        Some(self.compose(text, &hit))
    }

    /// 翻译并缓存一条 cue,返回该 cue 的显示文本。空文本返回空串。
    pub async fn on_cue(&self, text: &str) -> Result<String, String> {
        let key = Self::norm(text);
        if key.is_empty() {
            return Ok(String::new());
        }
        if let Some(d) = self.cached_display(text) {
            return Ok(d);
        }
        let translated = self.translate_one(&key).await?;
        Ok(self.compose(text, &translated))
    }

    /// 预热若干条(宿主 sub-step 偷看到的后续 cue);已缓存的跳过,错误吞掉不影响播放。
    pub async fn warm(&self, texts: &[String]) -> usize {
        let mut warmed = 0;
        for t in texts {
            let key = Self::norm(t);
            if key.is_empty() || self.cache.lock().map(|c| c.contains_key(&key)).unwrap_or(false) {
                continue;
            }
            if self.translate_one(&key).await.is_ok() {
                warmed += 1;
            }
        }
        warmed
    }

    async fn translate_one(&self, key: &str) -> Result<String, String> {
        let out = self.engine.translate(&[key.to_string()], &self.source_lang, &self.target_lang).await?;
        let translated = out.into_iter().next().unwrap_or_else(|| key.to_string());
        if let Ok(mut c) = self.cache.lock() {
            c.insert(key.to_string(), translated.clone());
        }
        Ok(translated)
    }

    /// 释放本集累积的翻译缓存(停用翻译/换集时调)。
    pub fn clear(&self) {
        if let Ok(mut c) = self.cache.lock() {
            c.clear();
        }
    }
}

// ============================================================================
// 8. Whisper 本地转写(桌面)
// ============================================================================

/// Whisper 本地模型规格(桌面专属)。
///
/// 不预置任何模型,用户在设置里开启功能后按需下载。模型为 whisper.cpp 的 GGML
/// 量化权重,下载源默认 Hugging Face 官方仓库。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "lowercase")]
pub enum WhisperModel {
    Tiny,
    #[default]
    Base,
    Medium,
    Large,
}

impl WhisperModel {
    pub fn storage_key(&self) -> &'static str {
        match self {
            Self::Tiny => "tiny",
            Self::Base => "base",
            Self::Medium => "medium",
            Self::Large => "large",
        }
    }
    pub fn from_key(k: &str) -> Self {
        match k {
            "tiny" => Self::Tiny,
            "medium" => Self::Medium,
            "large" => Self::Large,
            _ => Self::Base,
        }
    }
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Tiny => "Tiny(最快,精度最低)",
            Self::Base => "Base(快速,日常够用)",
            Self::Medium => "Medium(较慢,精度好)",
            Self::Large => "Large(最慢,精度最高)",
        }
    }
    /// 权重文件名(whisper.cpp GGML 格式)。
    pub fn file_name(&self) -> &'static str {
        match self {
            Self::Tiny => "ggml-tiny.bin",
            Self::Base => "ggml-base.bin",
            Self::Medium => "ggml-medium.bin",
            Self::Large => "ggml-large-v3.bin",
        }
    }
    /// 大致体积(用于 UI 提示)。
    pub fn size_label(&self) -> &'static str {
        match self {
            Self::Tiny => "约 75 MB",
            Self::Base => "约 142 MB",
            Self::Medium => "约 1.5 GB",
            Self::Large => "约 2.9 GB",
        }
    }
    /// 默认下载地址(Hugging Face 官方仓库;设置里可改镜像)。
    pub fn download_url(&self, mirror_base: &str) -> String {
        let base = if mirror_base.is_empty() {
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
        } else {
            mirror_base.trim_end_matches('/')
        };
        format!("{base}/{}", self.file_name())
    }
}

pub mod whisper {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::AsyncWriteExt;

    /// 下载进度:(已收字节, 总字节, 0..1)。总字节未知时为 0。
    pub type DownloadProgress = Arc<dyn Fn(u64, u64, f64) + Send + Sync>;

    /// 模型目录(持久,不随缓存清理被删;对齐 Dart ApplicationSupport)。
    pub fn models_dir() -> PathBuf {
        dirs::data_dir()
            .or_else(dirs::config_dir)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("LinPlayer")
            .join("whisper_models")
    }

    pub fn model_file(model: WhisperModel) -> PathBuf {
        models_dir().join(model.file_name())
    }

    /// 已下载(且非半截文件:>1MB)。
    pub fn is_downloaded(model: WhisperModel) -> bool {
        downloaded_size(model) > 1024 * 1024
    }

    /// 已下载模型的体积(字节),未下载返回 0。
    pub fn downloaded_size(model: WhisperModel) -> u64 {
        std::fs::metadata(model_file(model)).map(|m| m.len()).unwrap_or(0)
    }

    pub fn delete_model(model: WhisperModel) -> Result<(), String> {
        let f = model_file(model);
        if f.exists() {
            std::fs::remove_file(f).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    /// 下载模型;`mirror_base` 为空用官方源。`cancel` 置 true 即中止(半截文件清掉)。
    ///
    /// 流式写临时文件,完成后原子改名,避免中断产生半截损坏文件。
    pub async fn download_model(
        model: WhisperModel,
        mirror_base: &str,
        cancel: Option<Arc<AtomicBool>>,
        on_progress: Option<DownloadProgress>,
    ) -> Result<PathBuf, String> {
        let url = model.download_url(mirror_base);
        // 强制 https:自定义镜像可能填 http://,明文下载会被中间人替换为篡改的 GGML 权重
        // 交给原生 whisper 二进制解析(潜在内存破坏)。
        if !url.to_lowercase().starts_with("https://") {
            return Err(format!("模型下载地址必须为 https:{url}"));
        }
        let target = model_file(model);
        let dir = models_dir();
        std::fs::create_dir_all(&dir).map_err(|e| format!("建模型目录失败: {e}"))?;
        let tmp = target.with_extension("part");

        let r = download_to(&url, &tmp, cancel, on_progress).await;
        if let Err(e) = r {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
        if target.exists() {
            let _ = std::fs::remove_file(&target);
        }
        std::fs::rename(&tmp, &target).map_err(|e| format!("改名失败: {e}"))?;
        Ok(target)
    }

    /// 流式下载到文件(带取消与进度)。
    async fn download_to(
        url: &str,
        out: &std::path::Path,
        cancel: Option<Arc<AtomicBool>>,
        on_progress: Option<DownloadProgress>,
    ) -> Result<(), String> {
        let mut resp = crate::http::client()
            .get(url)
            .send()
            .await
            .map_err(|e| format!("下载请求失败: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("下载失败: HTTP {}", resp.status()));
        }
        let total = resp.content_length().unwrap_or(0);
        let mut f = tokio::fs::File::create(out).await.map_err(|e| format!("建文件失败: {e}"))?;
        let mut got = 0u64;
        while let Some(chunk) = resp.chunk().await.map_err(|e| format!("下载中断: {e}"))? {
            if cancel.as_ref().is_some_and(|c| c.load(Ordering::Relaxed)) {
                return Err("下载已取消".into());
            }
            f.write_all(&chunk).await.map_err(|e| format!("写入失败: {e}"))?;
            got += chunk.len() as u64;
            if let Some(p) = &on_progress {
                p(got, total, if total > 0 { got as f64 / total as f64 } else { 0.0 });
            }
        }
        f.flush().await.map_err(|e| e.to_string())?;
        Ok(())
    }

    // ---------- 外部二进制定位 ----------

    fn exe_name(stem: &str) -> String {
        if cfg!(windows) {
            format!("{stem}.exe")
        } else {
            stem.to_string()
        }
    }

    fn bin_dir() -> PathBuf {
        dirs::data_dir()
            .or_else(dirs::config_dir)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("LinPlayer")
            .join("bin")
    }

    fn exe_dir() -> PathBuf {
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from("."))
    }

    /// PATH 探测结果的进程内缓存。见 [`runs_ok`] 上关于「为什么缓存是正确的」的论证。
    static RUNS_OK_MEMO: std::sync::OnceLock<std::sync::Mutex<HashMap<String, bool>>> =
        std::sync::OnceLock::new();

    /// 能跑起来即视为可用(PATH 命中判定)。**结果按 exe 名缓存到进程退出**。
    ///
    /// ## 为什么非缓存不可
    /// `.status()` 是**同步等子进程退出**。whisper-cli + ffmpeg 各最多试 `-version`/`--help`
    /// 两次 = 一次探测最多 4 次进程创建。用户 2026-07-15 报「每次打开设置的字幕翻译每次都会卡」
    /// 就是这个:面板一 mount 就跑一遍,切走再切回重新 mount,又跑一遍。
    ///
    /// ## 为什么缓存是**正确**的,不只是快
    /// 1. `Command` 用的是**本进程启动时继承的 PATH**。用户中途往系统 PATH 里装了 ffmpeg,
    ///    本进程也看不见 —— 那本来就得重启 App。缓存没有丢失任何本可感知的变化。
    /// 2. App 内下载的 ffmpeg 落在 `bin_dir()`,而 resolve_* 里 `cached.is_file()` 排在
    ///    runs_ok **前面**。所以下载完立刻就能命中,根本不经过这里。
    ///
    /// 即:缓存唯一"看不见"的场景,是本进程原本也看不见的场景。
    fn runs_ok(exe: &str) -> bool {
        let memo = RUNS_OK_MEMO.get_or_init(Default::default);
        if let Some(hit) = memo.lock().unwrap().get(exe) {
            return *hit;
        }
        // ★ 探测时不持锁:否则两个引擎同时探,后一个会被前一个的进程创建整个卡住,
        //   等于白缓存。宁可偶尔重复探一次,也不要把锁按在同步 spawn 上面。
        let ok = ["-version", "--help"].into_iter().any(|arg| {
            let mut cmd = std::process::Command::new(exe);
            cmd.arg(arg)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            hide_window(&mut cmd);
            cmd.status().map(|s| s.success()).unwrap_or(false)
        });
        memo.lock().unwrap().insert(exe.to_string(), ok);
        ok
    }

    /// 定位 ffmpeg,找不到返回 None。
    /// 顺序:用户指定 → 已下载缓存 → 随应用打包 → 系统 PATH → 常见安装位置。
    pub fn resolve_ffmpeg(configured: &str) -> Option<String> {
        let name = exe_name("ffmpeg");
        if !configured.is_empty() && std::path::Path::new(configured).is_file() {
            return Some(configured.to_string());
        }
        let cached = bin_dir().join(&name);
        if cached.is_file() {
            return Some(cached.to_string_lossy().into_owned());
        }
        let d = exe_dir();
        for c in [d.join(&name), d.join("ffmpeg").join(&name), d.join("bin").join(&name)] {
            if c.is_file() {
                return Some(c.to_string_lossy().into_owned());
            }
        }
        if runs_ok(&name) {
            return Some(name); // PATH
        }
        common_ffmpeg_locations()
            .into_iter()
            .find(|c| std::path::Path::new(c).is_file())
            .map(|s| s.to_string())
    }

    fn common_ffmpeg_locations() -> Vec<&'static str> {
        if cfg!(windows) {
            vec![r"C:\ffmpeg\bin\ffmpeg.exe", r"C:\Program Files\ffmpeg\bin\ffmpeg.exe"]
        } else if cfg!(target_os = "macos") {
            vec!["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        } else {
            vec!["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/snap/bin/ffmpeg"]
        }
    }

    /// 定位 whisper-cli(用户指定/缓存/内置/PATH/旧名 main|whisper),找不到返回 None。
    pub fn resolve_whisper(configured: &str) -> Option<String> {
        let name = exe_name("whisper-cli");
        if !configured.is_empty() && std::path::Path::new(configured).is_file() {
            return Some(configured.to_string());
        }
        let cached = bin_dir().join(&name);
        if cached.is_file() {
            return Some(cached.to_string_lossy().into_owned());
        }
        let d = exe_dir();
        // 随应用打包:可执行文件同级 / macOS .app 的 Resources。
        for c in [
            d.join(&name),
            d.join("whisper").join(&name),
            d.join("bin").join(&name),
            d.join("..").join("Resources").join("whisper").join(&name),
        ] {
            if c.is_file() {
                return Some(c.to_string_lossy().into_owned());
            }
        }
        if runs_ok(&name) {
            return Some(name); // PATH
        }
        // 兼容旧名 main / whisper。
        for alt in ["main", "whisper"] {
            let c = d.join(exe_name(alt));
            if c.is_file() {
                return Some(c.to_string_lossy().into_owned());
            }
        }
        None
    }

    /// 官方/官网指向的 ffmpeg 静态构建下载地址。
    const FFMPEG_WIN: &str = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
    const FFMPEG_MAC: &str = "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip";

    /// Linux 静态构建(.tar.xz)。johnvansickle 是 ffmpeg 官网 Download 页给 Linux 指的源。
    #[cfg(target_os = "linux")]
    const FFMPEG_LINUX_AMD64: &str =
        "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz";
    #[cfg(target_os = "linux")]
    const FFMPEG_LINUX_ARM64: &str =
        "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz";

    /// 下载并安装 ffmpeg 到应用 bin 目录,返回可执行文件路径。
    pub async fn download_ffmpeg(on_progress: Option<DownloadProgress>) -> Result<String, String> {
        #[cfg(target_os = "linux")]
        {
            return download_ffmpeg_linux(on_progress).await;
        }
        #[cfg(not(target_os = "linux"))]
        {
            download_ffmpeg_zip(on_progress).await
        }
    }

    /// Linux:.tar.xz 交给系统 tar 解 —— 每个发行版都自带,省掉 tar+xz2 两个 crate。
    /// ponytail: 依赖外部 tar;若哪天要支持无 tar 的极简容器,再引 xz2+tar crate。
    #[cfg(target_os = "linux")]
    async fn download_ffmpeg_linux(
        on_progress: Option<DownloadProgress>,
    ) -> Result<String, String> {
        let url = if cfg!(target_arch = "aarch64") {
            FFMPEG_LINUX_ARM64
        } else {
            FFMPEG_LINUX_AMD64
        };
        // 先确认 tar 在:没有的话早点说清楚,别下完 30MB 再失败。
        let mut tar_probe = std::process::Command::new("tar");
        tar_probe.arg("--version");
        hide_window(&mut tar_probe);
        tar_probe
            .output()
            .map_err(|_| "系统没有 tar,无法解包;请用发行版包管理器装 ffmpeg,或在设置里手填路径".to_string())?;

        let dir = bin_dir();
        std::fs::create_dir_all(&dir).map_err(|e| format!("建 bin 目录失败: {e}"))?;
        let tmp = dir.join("ffmpeg_dl.tar.xz");
        download_to(url, &tmp, None, on_progress).await?;

        // 解到临时目录再挑文件:包内路径含版本号(ffmpeg-7.x-amd64-static/ffmpeg),
        // 写死路径会在上游发版时静默失效。
        let ex = dir.join("ffmpeg_extract");
        let _ = std::fs::remove_dir_all(&ex);
        std::fs::create_dir_all(&ex).map_err(|e| format!("建解包目录失败: {e}"))?;
        let mut tar_cmd = std::process::Command::new("tar");
        tar_cmd.arg("-xJf").arg(&tmp).arg("-C").arg(&ex);
        hide_window(&mut tar_cmd);
        let st = tar_cmd.status().map_err(|e| format!("调用 tar 失败: {e}"))?;
        if !st.success() {
            return Err("tar 解包失败(包损坏或缺 xz 支持)".into());
        }

        let found = find_file(&ex, "ffmpeg").ok_or("包内未找到 ffmpeg")?;
        let out = dir.join("ffmpeg");
        std::fs::copy(&found, &out).map_err(|e| format!("写 ffmpeg 失败: {e}"))?;
        let _ = std::fs::remove_dir_all(&ex);
        let _ = std::fs::remove_file(&tmp);
        set_executable(&out);
        Ok(out.to_string_lossy().into_owned())
    }

    /// 在目录树里找指定文件名的第一个匹配。
    #[cfg(target_os = "linux")]
    fn find_file(dir: &std::path::Path, name: &str) -> Option<PathBuf> {
        let rd = std::fs::read_dir(dir).ok()?;
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                if let Some(hit) = find_file(&p, name) {
                    return Some(hit);
                }
            } else if p.file_name().and_then(|s| s.to_str()) == Some(name) {
                return Some(p);
            }
        }
        None
    }

    #[cfg(not(target_os = "linux"))]
    async fn download_ffmpeg_zip(
        on_progress: Option<DownloadProgress>,
    ) -> Result<String, String> {
        let url = if cfg!(windows) { FFMPEG_WIN } else { FFMPEG_MAC };
        let dir = bin_dir();
        std::fs::create_dir_all(&dir).map_err(|e| format!("建 bin 目录失败: {e}"))?;
        let tmp = dir.join("ffmpeg_dl.zip");
        download_to(url, &tmp, None, on_progress).await?;

        let name = exe_name("ffmpeg");
        let out = dir.join(&name);
        let bytes = std::fs::read(&tmp).map_err(|e| format!("读压缩包失败: {e}"))?;
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes))
            .map_err(|e| format!("解压失败: {e}"))?;
        // 静态构建的 zip 里 ffmpeg 埋在 <version>/bin/ 下;按后缀找。
        let idx = (0..zip.len())
            .find(|&i| {
                zip.by_index(i)
                    .map(|f| f.is_file() && f.name().rsplit('/').next() == Some(name.as_str()))
                    .unwrap_or(false)
            })
            .ok_or_else(|| format!("压缩包内未找到 {name}"))?;
        let mut entry = zip.by_index(idx).map_err(|e| e.to_string())?;
        let mut f = std::fs::File::create(&out).map_err(|e| format!("写 ffmpeg 失败: {e}"))?;
        std::io::copy(&mut entry, &mut f).map_err(|e| format!("解出 ffmpeg 失败: {e}"))?;
        drop(f);
        let _ = std::fs::remove_file(&tmp);
        set_executable(&out);
        Ok(out.to_string_lossy().into_owned())
    }

    #[cfg(unix)]
    fn set_executable(p: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755));
    }
    #[cfg(not(unix))]
    fn set_executable(_p: &std::path::Path) {}

    // ---------- 音频抽取 / 转写 ----------

    fn work_dir(sub: &str) -> Result<PathBuf, String> {
        let d = dirs::cache_dir()
            .or_else(dirs::config_dir)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("LinPlayer")
            .join(sub);
        std::fs::create_dir_all(&d).map_err(|e| format!("建工作目录失败: {e}"))?;
        Ok(d)
    }

    fn fmt_ts(ms: u64) -> String {
        let (h, m, s, milli) = (ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000);
        format!("{h:02}:{m:02}:{s:02}.{milli:03}")
    }

    /// ffmpeg 是否可用(用于设置页探测)。
    pub fn ffmpeg_available(ffmpeg: &str) -> bool {
        runs_ok(ffmpeg)
    }

    /// 用 ffmpeg 抽取 `source` 自 `start_ms` 起、时长 `dur_ms` 的音频段为 16kHz 单声道 WAV。
    ///
    /// libmpv 内含 ffmpeg 但未单独暴露可执行文件,故走外部 ffmpeg。支持从 HTTP 流
    /// (带 Emby 鉴权头)直接抽取,无需先下载整片。返回 WAV 路径。
    pub fn extract_segment(
        ffmpeg: &str,
        source: &str,
        start_ms: u64,
        dur_ms: u64,
        auth_token: Option<&str>,
        audio_stream_index: Option<u32>,
    ) -> Result<String, String> {
        let dir = work_dir("whisper_audio")?;
        let out = dir.join(format!("seg_{start_ms}_{dur_ms}.wav"));

        let mut cmd = std::process::Command::new(ffmpeg);
        cmd.args(["-y", "-loglevel", "error"]);
        if let Some(t) = auth_token {
            if source.starts_with("http") {
                cmd.args([
                    "-headers",
                    &format!("X-Emby-Token: {t}\r\nX-MediaBrowser-Token: {t}\r\n"),
                ]);
            }
        }
        cmd.args(["-ss", &fmt_ts(start_ms), "-t", &fmt_ts(dur_ms), "-i", source]);
        if let Some(i) = audio_stream_index {
            cmd.args(["-map", &format!("0:a:{i}")]);
        }
        cmd.args(["-vn", "-ar", "16000", "-ac", "1", "-f", "wav"]);
        cmd.arg(&out);
        hide_window(&mut cmd);

        let r = cmd.output().map_err(|e| format!("ffmpeg 启动失败: {e}"))?;
        if !r.status.success() {
            return Err(format!(
                "ffmpeg 抽取失败({}): {}",
                r.status,
                String::from_utf8_lossy(&r.stderr)
            ));
        }
        if std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0) < 1024 {
            return Err(format!("ffmpeg 输出为空: {}", out.display()));
        }
        Ok(out.to_string_lossy().into_owned())
    }

    /// whisper-cli 是否可用(用于设置页探测)。
    pub fn whisper_available(binary: &str) -> bool {
        runs_ok(binary)
    }

    /// 调用 whisper.cpp 可执行文件把一段 WAV 转写为字幕。
    ///
    /// 不内置二进制:用户在设置里指定 whisper-cli 路径(或放进 PATH)。转写产出 SRT,
    /// 解析后按段起始时间整体平移,回到全片绝对时间轴。转写完清掉中间 WAV/SRT。
    pub fn transcribe(
        binary: &str,
        model_path: &str,
        wav_path: &str,
        offset_ms: u64,
        language: &str,
        threads: u32,
    ) -> Result<SubtitleDocument, String> {
        let dir = work_dir("whisper_out")?;
        let prefix = dir.join(format!("whisper_{offset_ms}"));
        let prefix_s = prefix.to_string_lossy().into_owned();

        let mut whisper_cmd = std::process::Command::new(binary);
        whisper_cmd
            .args(["-m", model_path, "-f", wav_path, "-l", language])
            .args(["-t", &threads.to_string(), "-osrt", "-of", &prefix_s]);
        hide_window(&mut whisper_cmd);
        let r = whisper_cmd.output().map_err(|e| format!("whisper 启动失败: {e}"))?;
        if !r.status.success() {
            return Err(format!(
                "whisper 转写失败({}): {}",
                r.status,
                String::from_utf8_lossy(&r.stderr)
            ));
        }

        let srt = prefix.with_extension("srt");
        let content = std::fs::read_to_string(&srt)
            .map_err(|e| format!("whisper 未产出字幕 {}: {e}", srt.display()))?;
        let doc = SubtitleDocument::parse_str(&content, "srt");
        // 平移到绝对时间轴。
        let cues = doc
            .cues
            .into_iter()
            .map(|c| SubtitleCue {
                start_ms: c.start_ms + offset_ms,
                end_ms: c.end_ms + offset_ms,
                ..c
            })
            .collect();
        let _ = std::fs::remove_file(&srt);
        let _ = std::fs::remove_file(wav_path);
        Ok(SubtitleDocument::new(cues))
    }

    /// Whisper 流式转写状态机(桌面)。
    ///
    /// 边播边转写:以滚动窗口在播放头前方抽音频 → whisper 转写 → 经翻译引擎译成中文 →
    /// 合并进累积文档 → 重写同一个 SRT 文件(路径稳定),让宿主重新加载字幕。
    ///
    /// 【宿主契约】本结构只做「推进一个窗口」;**播放位置由宿主提供**,循环也由宿主驱动:
    /// ```text
    /// while !s.is_done(total_ms) {
    ///     if pos_ms + lookahead < s.next_start_ms { sleep(2s); continue; }  // 别领先太多
    ///     s.advance(...).await?;            // 一个窗口:抽音频→转写→翻译→写盘
    ///     host.reload_subtitle(s.output_path());   // 播放器重载 SRT
    /// }
    /// ```
    /// whisper 为 CPU 密集型,一次只处理一个窗口(本结构天然串行,不要并发调 advance)。
    pub struct WhisperStream {
        cues: Vec<SubtitleCue>,
        next_start_ms: u64,
        output_path: PathBuf,
        /// 每个窗口的时长(默认 30s)。
        pub window_ms: u64,
    }

    impl WhisperStream {
        /// `source` 为播放源地址(参与输出文件名哈希,同片复用同一路径)。
        pub fn new(source: &str) -> Result<Self, String> {
            let dir = work_dir("whisper_live")?;
            let id: String = md5_hex(source).chars().take(12).collect();
            Ok(Self {
                cues: Vec::new(),
                next_start_ms: 0,
                output_path: dir.join(format!("whisper_{id}.srt")),
                window_ms: 30_000,
            })
        }

        pub fn output_path(&self) -> String {
            self.output_path.to_string_lossy().into_owned()
        }
        pub fn next_start_ms(&self) -> u64 {
            self.next_start_ms
        }
        pub fn cue_count(&self) -> usize {
            self.cues.len()
        }
        /// 已覆盖全片。
        pub fn is_done(&self, total_ms: u64) -> bool {
            self.next_start_ms >= total_ms
        }

        /// 推进一个窗口。失败也照样前移窗口(与 Dart 一致:跳过坏窗口,不卡死整条流)。
        #[allow(clippy::too_many_arguments)]
        pub async fn advance(
            &mut self,
            ffmpeg: &str,
            whisper_binary: &str,
            model_path: &str,
            source: &str,
            total_ms: u64,
            engine: Arc<dyn TranslationEngine>,
            source_lang: &str,
            target_lang: &str,
            layout: BilingualLayout,
            auth_token: Option<&str>,
            audio_stream_index: Option<u32>,
        ) -> Result<(), String> {
            let start = self.next_start_ms;
            let dur = self.window_ms.min(total_ms.saturating_sub(start));
            self.next_start_ms += self.window_ms;
            if dur == 0 {
                return Ok(());
            }

            let wav =
                extract_segment(ffmpeg, source, start, dur, auth_token, audio_stream_index)?;
            let mut doc =
                transcribe(whisper_binary, model_path, &wav, start, source_lang, 4)?;
            if doc.is_empty() {
                return Ok(());
            }
            // 译成中文(复用批量管线的分块与容错)。
            translate_document(&mut doc, engine, source_lang, target_lang, None).await?;

            self.cues.extend(doc.cues);
            self.cues.sort_by_key(|c| c.start_ms);
            let srt = SubtitleDocument::new(self.cues.clone()).to_srt(layout);
            std::fs::write(&self.output_path, srt).map_err(|e| format!("写字幕失败: {e}"))
        }
    }
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    const SRT: &str = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\nWorld\r\n\r\n\
                       2\r\n00:01:00,5 --> 00:01:02,000\r\nSecond, line\r\n";

    #[test]
    fn srt_parses_times_text_and_pads_millis() {
        let d = SubtitleDocument::parse_str(SRT, "srt");
        assert_eq!(d.cues.len(), 2);
        assert_eq!(d.cues[0], SubtitleCue::new(1000, 2500, "Hello\nWorld"));
        // `,5` 必须补成 500ms 而不是 5ms —— 补零补错就是全片字幕轴偏移。
        assert_eq!(d.cues[1].start_ms, 60_500);
        assert_eq!(d.cues[1].text, "Second, line");
    }

    #[test]
    fn srt_roundtrip_keeps_timeline_and_text() {
        let d = SubtitleDocument::parse_str(SRT, "srt");
        let out = d.to_srt(BilingualLayout::TranslatedOnly);
        // 无译文 → 回退原文(不该产出空块)。
        let back = SubtitleDocument::parse_str(&out, "srt");
        assert_eq!(back.cues, d.cues, "SRT 往返不该丢时间轴/文本");
        assert!(out.starts_with("1\n00:00:01,000 --> 00:00:02,500\nHello\nWorld\n\n"));
        // 序号必须从 1 连续重排。
        assert!(out.contains("\n2\n00:01:00,500 --> 00:01:02,000\n"));
    }

    #[test]
    fn srt_bilingual_layouts() {
        let mut d = SubtitleDocument::parse_str("1\n00:00:01,000 --> 00:00:02,000\nHello\n", "srt");
        d.cues[0].translated_text = Some("你好".into());
        assert!(d.to_srt(BilingualLayout::TranslatedOnly).contains("\n你好\n"));
        assert!(d.to_srt(BilingualLayout::TranslatedFirst).contains("\n你好\nHello\n"));
        assert!(d.to_srt(BilingualLayout::OriginalFirst).contains("\nHello\n你好\n"));
        // 译文为空 → 回退原文,不产空块。
        d.cues[0].translated_text = Some("   ".into());
        assert!(d.to_srt(BilingualLayout::TranslatedFirst).contains("\nHello\n"));
        assert!(!d.to_srt(BilingualLayout::TranslatedOnly).is_empty());
    }

    #[test]
    fn empty_cue_never_emits_blank_block() {
        // 仅译文 + 空原文空译文:整块必须被丢掉,否则 libass 吃到空块会错位。
        let d = SubtitleDocument::new(vec![
            SubtitleCue::new(0, 1000, ""),
            SubtitleCue::new(1000, 2000, "ok"),
        ]);
        let out = d.to_srt(BilingualLayout::TranslatedOnly);
        assert_eq!(out.matches("-->").count(), 1);
        assert!(out.starts_with("1\n"), "剩下的那条必须重新编号为 1");
    }

    const ASS: &str = r#"[Script Info]
Title: t
[V4+ Styles]
Format: Name, Fontname
Style: Default,Arial
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.55,Default,,0,0,0,,{\an8}Hi, there\Nsecond line
Comment: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,ignored
Dialogue: 0,0:00:05.06,0:00:06.00,Default,,0,0,0,,{\pos(1,2)}
"#;

    #[test]
    fn ass_parses_dialogue_strips_tags_and_keeps_text_commas() {
        let d = SubtitleDocument::parse_str(ASS, "ass");
        assert_eq!(d.cues.len(), 1, "Comment 行与纯标签行都不该成为 cue");
        let c = &d.cues[0];
        assert_eq!(c.start_ms, 1000);
        assert_eq!(c.end_ms, 2550, "百分秒 .55 = 550ms");
        // Text 里的逗号不能被字段切分吃掉;\N 变换行;{} 覆盖标签剥掉。
        assert_eq!(c.text, "Hi, there\nsecond line");
    }

    #[test]
    fn ass_sniffed_without_ext_and_converts_to_srt() {
        let d = SubtitleDocument::parse_str(ASS, "");
        assert_eq!(d.cues.len(), 1, "无扩展名必须靠 [Script Info] 嗅探出 ASS");
        let srt = d.to_srt(BilingualLayout::TranslatedOnly);
        assert!(srt.contains("00:00:01,000 --> 00:00:02,550"), "ASS→SRT 时间轴要对: {srt}");
        assert!(srt.contains("Hi, there\nsecond line"));
    }

    #[test]
    fn vtt_parses_and_strips_inline_tags() {
        let vtt = "WEBVTT\n\ncue-1\n00:00:01.000 --> 00:00:02.000\n<v Bob>Hi</v> <c.x>there</c>\n";
        let d = SubtitleDocument::parse_str(vtt, "");
        assert_eq!(d.cues.len(), 1, "WEBVTT 头必须被嗅探到");
        assert_eq!(d.cues[0], SubtitleCue::new(1000, 2000, "Hi there"));
    }

    #[test]
    fn garbage_parses_to_empty_not_panic() {
        // 404 HTML 页当字幕喂进来:必须空文档 + looks_like_subtitle 挡住。
        let html = "<html><body>Not Found</body></html>";
        assert!(SubtitleDocument::parse_str(html, "").is_empty());
        assert!(!looks_like_subtitle(html));
        assert!(!looks_like_subtitle("   "));
        assert!(looks_like_subtitle("1\n00:00:01,000 --> 00:00:02,000\nx"));
        assert!(looks_like_subtitle("WEBVTT\n\n"));
        assert!(looks_like_subtitle("[Script Info]\n"));
    }

    // ---------- 分批 ----------

    fn cues(lens: &[usize]) -> Vec<SubtitleCue> {
        lens.iter().map(|&n| SubtitleCue::new(0, 1, "a".repeat(n))).collect()
    }

    #[test]
    fn chunk_splits_by_count() {
        let c = cues(&[1; 7]);
        assert_eq!(chunk_ranges(&c, 3, 0), vec![(0, 3), (3, 6), (6, 7)]);
        // max_chars=0 表示不限字符数。
        assert_eq!(chunk_ranges(&cues(&[9999; 2]), 5, 0), vec![(0, 2)]);
    }

    #[test]
    fn chunk_splits_by_chars() {
        // 100+100 = 200 未超;再加 100 就超 250 → 断批。
        assert_eq!(chunk_ranges(&cues(&[100; 5]), 99, 250), vec![(0, 2), (2, 4), (4, 5)]);
    }

    #[test]
    fn chunk_never_drops_oversized_single_cue() {
        // 单条就超字符上限:必须自成一批而不是被丢掉(丢=那句字幕永远没译文)。
        let c = cues(&[10, 9999, 10]);
        let r = chunk_ranges(&c, 50, 100);
        assert_eq!(r, vec![(0, 1), (1, 2), (2, 3)]);
        assert_eq!(r.iter().map(|(s, e)| e - s).sum::<usize>(), c.len(), "分批不许丢条目");
    }

    #[test]
    fn chunk_empty_and_single() {
        assert!(chunk_ranges(&[], 10, 100).is_empty());
        assert_eq!(chunk_ranges(&cues(&[1]), 10, 100), vec![(0, 1)]);
    }

    #[test]
    fn chunk_covers_every_cue_contiguously() {
        // 随机长度也必须无缝覆盖 [0,n):漏一段就是漏译一段。
        let c = cues(&[3, 400, 1, 77, 200, 5, 5, 900, 12]);
        let r = chunk_ranges(&c, 4, 500);
        assert_eq!(r.first().unwrap().0, 0);
        assert_eq!(r.last().unwrap().1, c.len());
        for w in r.windows(2) {
            assert_eq!(w[0].1, w[1].0, "批次之间不许有缝/重叠: {r:?}");
        }
    }

    // ---------- 语言映射 ----------

    #[test]
    fn lang_norm_handles_regions_and_three_letter() {
        assert_eq!(lang::norm("en-GB"), "en");
        assert_eq!(lang::norm("zh-TW"), "zh-hant");
        assert_eq!(lang::norm("cht"), "zh-hant");
        assert_eq!(lang::norm("zh_CN"), "zh-hans");
        assert_eq!(lang::norm("chi"), "zh-hans");
        assert_eq!(lang::norm("jpn"), "ja");
        assert_eq!(lang::norm("fre"), "fr");
        assert_eq!(lang::norm("ita"), "it");
        assert_eq!(lang::norm(""), "auto");
        assert_eq!(lang::norm("und"), "auto");
        assert_eq!(lang::norm("xyz"), "xyz");
    }

    #[test]
    fn lang_maps_to_vendor_codes() {
        // 日语在百度是 jp、腾讯是 ja —— 映错就整轨翻译成别的语言。
        assert_eq!(lang::to_baidu("jpn"), "jp");
        assert_eq!(lang::to_tencent("jpn"), "ja");
        assert_eq!(lang::to_baidu("zh-TW"), "cht");
        assert_eq!(lang::to_tencent("zh-TW"), "zh-TW");
        assert_eq!(lang::to_baidu("zh"), "zh");
        assert_eq!(lang::to_baidu("xyz"), "auto", "未知码必须回退 auto 而不是原样送出");
        assert_eq!(lang::to_tencent("xyz"), "auto");
        assert_eq!(lang::human_name("zh"), "Simplified Chinese");
        assert_eq!(lang::human_name("auto"), "the source language");
        assert_eq!(lang::human_name("xyz"), "xyz");
    }

    // ---------- AI 回包解析 ----------

    #[test]
    fn ai_json_array_extracted_from_chatter() {
        // 模型爱包一层 markdown / 前言,必须能抠出数组。
        let raw = "好的:\n```json\n[\"你好\", \"世界\"]\n```\n";
        assert_eq!(parse_json_array(raw, 2), Some(vec!["你好".into(), "世界".into()]));
        // 长度不齐 → None(上层二分重试),绝不能错位对齐。
        assert_eq!(parse_json_array("[\"a\"]", 2), None);
        assert_eq!(parse_json_array("not json", 1), None);
        assert_eq!(parse_json_array("[", 1), None);
        // null / 非字符串元素不该 panic。
        assert_eq!(parse_json_array("[null, 1]", 2), Some(vec!["".into(), "1".into()]));
    }

    #[test]
    fn baidu_response_parsing() {
        let ok = serde_json::json!({"trans_result":[{"dst":"你好"},{"dst":"世界"}]});
        assert_eq!(parse_baidu_response("b", &ok, 2).unwrap(), vec!["你好", "世界"]);
        // 行数不齐 → Err,交给二分重试。
        assert!(parse_baidu_response("b", &ok, 3).is_err());
        let bad = serde_json::json!({"error_code":"54001","error_msg":"Invalid Sign"});
        let e = parse_baidu_response("b", &bad, 1).unwrap_err();
        assert!(e.contains("54001"), "错误码必须透出来: {e}");
    }

    // ---------- 签名工具 ----------

    #[test]
    fn hmac_sha256_matches_rfc4231() {
        // RFC 4231 Test Case 2:自己手写的 HMAC 必须与标准一致,否则腾讯签名全废。
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            hex(&mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        // 超过 64 字节的 key 必须先哈希(TC3 密钥长时会走到这条路)。
        let long = hmac_sha256(&[0xaa; 131], b"Test Using Larger Than Block-Size Key - Hash Key First");
        assert_eq!(
            hex(&long),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        );
    }

    #[test]
    fn sha256_and_utc_date() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(utc_date(0), "1970-01-01");
        assert_eq!(utc_date(1_700_000_000), "2023-11-14");
        // 闰日:算错就在 2/29 当天签名失败(scope 日期与服务端对不上)。
        assert_eq!(utc_date(1_709_164_800), "2024-02-29");
        assert_eq!(utc_date(1_709_251_199), "2024-02-29");
        assert_eq!(utc_date(1_709_251_200), "2024-03-01");
    }

    #[test]
    fn md5_matches_baidu_sign_shape() {
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        // 百度官方文档示例:appid=2015063000000001 q=apple salt=1435660288 key=12345678
        assert_eq!(md5_hex("2015063000000001apple143566028812345678"), "f89f9594663708c1605f3d736d01d2d4");
    }

    // ---------- 引擎工厂 / 设置 ----------

    #[test]
    fn engine_factory_returns_none_until_configured() {
        let mut s = TranslationSettings::default();
        // 默认只有 baseUrl/model,没 key → 未配置。
        assert!(active_engine(&s).is_none());
        s.openai.api_key = "sk-x".into();
        let e = active_engine(&s).expect("填了 key 就该出引擎");
        assert_eq!(e.id(), "openai");
        assert_eq!(e.max_concurrency(), 3);

        s.engine = TranslationEngineKind::Tencent;
        assert!(active_engine(&s).is_none(), "换引擎后没配就得是 None");
        s.tencent.secret_id = "id".into();
        s.tencent.secret_key = "k".into();
        let t = active_engine(&s).unwrap();
        assert_eq!(t.id(), "tencent");
        assert_eq!(t.max_concurrency(), 1, "腾讯必须串行");

        // 百度:只填 appid 不算配好。
        s.engine = TranslationEngineKind::BaiduGeneral;
        s.baidu_general.app_id = "a".into();
        assert!(active_engine(&s).is_none());
        s.baidu_general.secret_key = "k".into();
        assert_eq!(active_engine(&s).unwrap().id(), "baidu_general");
    }

    #[test]
    fn settings_json_roundtrip_and_defaults() {
        let s = TranslationSettings::default();
        let j = serde_json::to_string(&s).unwrap();
        let back: TranslationSettings = serde_json::from_str(&j).unwrap();
        assert_eq!(back.target_lang, "zh");
        assert_eq!(back.layout, BilingualLayout::TranslatedFirst);
        assert_eq!(back.openai.model, "gpt-4o-mini");
        // 空 JSON 也得读得出默认值(首次运行/老文件)。
        let empty: TranslationSettings = serde_json::from_str("{}").unwrap();
        assert_eq!(empty.engine, TranslationEngineKind::Openai);
        assert_eq!(empty.openai.base_url, "https://api.openai.com/v1");
        assert!(!empty.whisper_enabled);
        assert_eq!(empty.whisper_model, WhisperModel::Base);
    }

    #[test]
    fn enum_keys_match_dart_storage() {
        // 存盘键要与旧 Dart enum name 一致,否则用户设置迁不过来。
        assert_eq!(TranslationEngineKind::BaiduLlm.storage_key(), "baiduLlm");
        assert_eq!(TranslationEngineKind::from_key("baiduGeneral"), TranslationEngineKind::BaiduGeneral);
        assert_eq!(TranslationEngineKind::from_key("nonsense"), TranslationEngineKind::Openai);
        assert!(TranslationEngineKind::Anthropic.is_ai());
        assert!(!TranslationEngineKind::Tencent.is_ai());
        assert_eq!(BilingualLayout::from_key("translatedOnly"), BilingualLayout::TranslatedOnly);
        assert_eq!(BilingualLayout::from_key("x"), BilingualLayout::TranslatedFirst);
        assert_eq!(WhisperModel::from_key("large").file_name(), "ggml-large-v3.bin");
        assert_eq!(WhisperModel::from_key("x"), WhisperModel::Base);
    }

    #[test]
    fn whisper_download_url_uses_mirror() {
        assert_eq!(
            WhisperModel::Base.download_url(""),
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        );
        assert_eq!(
            WhisperModel::Tiny.download_url("https://hf-mirror.com/x/"),
            "https://hf-mirror.com/x/ggml-tiny.bin"
        );
    }

    // ---------- URL 候选 ----------

    #[test]
    fn subtitle_candidates_prefer_delivery_then_ticks_variant() {
        let u = subtitle_url_candidates(
            "https://h/emby/",
            Some("tk"),
            "it",
            "ms",
            2,
            Some("https://cdn/x.srt"),
            Some("/local/not-http.srt"),
        );
        assert_eq!(u[0], "https://cdn/x.srt", "服务端给的绝对地址优先");
        assert!(!u.iter().any(|x| x.contains("/local/")), "非 http 的 path 不该进候选");
        assert_eq!(u[1], "https://h/emby/Videos/it/ms/Subtitles/2/0/Stream.srt?api_key=tk");
        assert_eq!(u[2], "https://h/emby/Videos/it/ms/Subtitles/2/Stream.srt?api_key=tk");
        assert_eq!(u.len(), 7); // delivery + 3 codec × 2 变体
        // 无 token 不该拼出空 api_key。
        let n = subtitle_url_candidates("https://h", None, "it", "ms", 0, None, None);
        assert!(!n[0].contains("api_key"), "{}", n[0]);
        // 去重:delivery 与拼出来的重复时只留一个。
        let dup = subtitle_url_candidates(
            "https://h",
            None,
            "it",
            "ms",
            0,
            Some("https://h/Videos/it/ms/Subtitles/0/0/Stream.srt"),
            None,
        );
        assert_eq!(dup.len(), 6);
    }

    // ---------- 服务层:分块/并发/二分重试(假引擎) ----------

    /// 假引擎:按 `fail_on` 谓词报错,用于验证二分重试与回退原文。
    struct FakeEngine {
        batch: usize,
        chars: usize,
        conc: usize,
        /// 整批命中该条件即失败(模拟「回包条数不齐」)。
        fail_if: fn(&[String]) -> bool,
        calls: Mutex<Vec<usize>>,
    }

    #[async_trait::async_trait]
    impl TranslationEngine for FakeEngine {
        fn id(&self) -> &str {
            "fake"
        }
        fn max_batch_size(&self) -> usize {
            self.batch
        }
        fn max_batch_chars(&self) -> usize {
            self.chars
        }
        fn max_concurrency(&self) -> usize {
            self.conc
        }
        async fn translate(
            &self,
            texts: &[String],
            _s: &str,
            _t: &str,
        ) -> Result<Vec<String>, String> {
            self.calls.lock().unwrap().push(texts.len());
            if (self.fail_if)(texts) {
                return Err("boom".into());
            }
            Ok(texts.iter().map(|t| format!("[{t}]")).collect())
        }
    }

    fn fake(fail_if: fn(&[String]) -> bool) -> Arc<FakeEngine> {
        Arc::new(FakeEngine { batch: 2, chars: 0, conc: 2, fail_if, calls: Mutex::new(vec![]) })
    }

    fn doc_of(n: usize) -> SubtitleDocument {
        SubtitleDocument::new(
            (0..n).map(|i| SubtitleCue::new(i as u64 * 1000, i as u64 * 1000 + 900, format!("t{i}")))
                .collect(),
        )
    }

    #[tokio::test]
    async fn translate_document_fills_every_cue_in_order() {
        let e = fake(|_| false);
        let mut d = doc_of(5);
        let seen = Arc::new(Mutex::new(vec![]));
        let s2 = seen.clone();
        let p: ProgressFn = Arc::new(move |done, total, _| s2.lock().unwrap().push((done, total)));
        translate_document(&mut d, e.clone(), "en", "zh", Some(p)).await.unwrap();
        for (i, c) in d.cues.iter().enumerate() {
            assert_eq!(c.translated_text.as_deref(), Some(format!("[t{i}]").as_str()), "第 {i} 条串位了");
        }
        // batch=2 → 3 批。
        assert_eq!(e.calls.lock().unwrap().len(), 3);
        let s = seen.lock().unwrap();
        assert_eq!(s.len(), 3, "每批回一次进度");
        assert_eq!(s.iter().map(|(d, _)| d).max(), Some(&5), "最终进度必须到满");
        assert!(s.iter().all(|(_, t)| *t == 5));
    }

    #[tokio::test]
    async fn failed_batch_bisects_and_falls_back_to_original() {
        // 只有含 t3 的**多条**批次会失败;二分到单条后 t3 单条也失败 → 回退原文,其余正常。
        let e = fake(|texts| texts.iter().any(|t| t == "t3"));
        let mut d = doc_of(6);
        translate_document(&mut d, e.clone(), "en", "zh", None).await.unwrap();
        assert_eq!(d.cues[2].translated_text.as_deref(), Some("[t2]"));
        assert_eq!(d.cues[3].translated_text.as_deref(), Some("t3"), "单条失败必须回退原文");
        assert_eq!(d.cues[4].translated_text.as_deref(), Some("[t4]"), "同批的邻居不该被连累");
        // (t2,t3) 失败 → 拆成 (t2) 和 (t3) 重试。
        let calls = e.calls.lock().unwrap().clone();
        assert!(calls.contains(&1), "必须发生过二分到单条: {calls:?}");
    }

    #[tokio::test]
    async fn all_failed_reports_engine_unusable() {
        // 引擎整体不可用(未开通/鉴权错)时必须报错,而不是静默产出一份未翻译的字幕。
        let e = fake(|_| true);
        let mut d = doc_of(4);
        let err = translate_document(&mut d, e, "en", "zh", None).await.unwrap_err();
        assert!(err.contains("全部 4 条均失败"), "{err}");
    }

    #[tokio::test]
    async fn empty_document_is_noop() {
        let mut d = SubtitleDocument::default();
        translate_document(&mut d, fake(|_| true), "en", "zh", None).await.unwrap();
        assert!(d.is_empty());
    }

    // ---------- 流式 ----------

    #[tokio::test]
    async fn streaming_caches_by_normalized_text() {
        let e = fake(|_| false);
        let s = StreamingTranslator::new(e.clone(), "ja", "zh", BilingualLayout::TranslatedFirst);
        assert_eq!(s.on_cue("t0").await.unwrap(), "[t0]\nt0");
        // 同句(仅空白差异)必须命中缓存,不再发请求。
        assert_eq!(s.on_cue(" t0 \n").await.unwrap(), "[t0]\nt0");
        assert_eq!(e.calls.lock().unwrap().len(), 1, "空白差异不该重复消耗额度");
        // 空 cue → 空显示,不发请求。
        assert_eq!(s.on_cue("   ").await.unwrap(), "");
        assert_eq!(e.calls.lock().unwrap().len(), 1);
        // 预热:已缓存的跳过。
        assert_eq!(s.warm(&["t0".into(), "t1".into()]).await, 1);
        assert_eq!(s.cached_display("t1").as_deref(), Some("[t1]\nt1"));
        s.clear();
        assert!(s.cached_display("t1").is_none(), "clear 必须真的放掉缓存");
    }

    #[tokio::test]
    async fn streaming_layout_composition() {
        let e = fake(|_| false);
        let only = StreamingTranslator::new(e.clone(), "ja", "zh", BilingualLayout::TranslatedOnly);
        assert_eq!(only.on_cue("t0").await.unwrap(), "[t0]");
        assert_eq!(only.compose("orig", ""), "", "仅译文模式:没译文就留空");
        let first = StreamingTranslator::new(e, "ja", "zh", BilingualLayout::OriginalFirst);
        assert_eq!(first.on_cue("t0").await.unwrap(), "t0\n[t0]");
        assert_eq!(first.compose("orig", ""), "orig", "双语模式:没译文先显示原文占位");
    }
}
