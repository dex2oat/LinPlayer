// 最小 libmpv 封装。
// 合成方案:mpv 渲染进一个【独立顶层无边框窗口】,垫在【透明 Tauri 窗口】正下方并保持对齐。
// 顶层↔顶层 DWM 能正常合成(子窗口无法进逐像素透明窗口,故不能用子窗口)。
#![allow(non_camel_case_types)]

use linplayer_core::media::Track;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Once};
use std::thread::JoinHandle;

// ---------- libmpv FFI ----------
#[repr(C)]
pub struct mpv_handle {
    _private: [u8; 0],
}

const MPV_FORMAT_DOUBLE: c_int = 5;

// 事件循环:检测直链失效(网盘短链过期)以触发 302 重签。
const MPV_EVENT_END_FILE: c_int = 7;
const MPV_END_FILE_REASON_ERROR: c_int = 4;

#[repr(C)]
struct mpv_event {
    event_id: c_int,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}
#[repr(C)]
struct mpv_event_end_file {
    reason: c_int,
    error: c_int,
}

#[link(name = "mpv")]
extern "C" {
    fn mpv_create() -> *mut mpv_handle;
    fn mpv_initialize(ctx: *mut mpv_handle) -> c_int;
    fn mpv_terminate_destroy(ctx: *mut mpv_handle);
    fn mpv_set_option_string(ctx: *mut mpv_handle, name: *const c_char, data: *const c_char) -> c_int;
    fn mpv_set_property_string(ctx: *mut mpv_handle, name: *const c_char, data: *const c_char) -> c_int;
    fn mpv_get_property(ctx: *mut mpv_handle, name: *const c_char, format: c_int, data: *mut c_void) -> c_int;
    fn mpv_get_property_string(ctx: *mut mpv_handle, name: *const c_char) -> *mut c_char;
    fn mpv_free(data: *mut c_void);
    fn mpv_command(ctx: *mut mpv_handle, args: *const *const c_char) -> c_int;
    fn mpv_error_string(error: c_int) -> *const c_char;
    fn mpv_wait_event(ctx: *mut mpv_handle, timeout: f64) -> *mut mpv_event;
}

fn err_str(code: c_int) -> String {
    unsafe {
        let p = mpv_error_string(code);
        if p.is_null() { format!("code {code}") } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
    }
}

pub fn mpv_log_path() -> std::path::PathBuf {
    std::env::temp_dir().join("linplayer_mpv.log")
}

use crate::poclog;

/// 编译好的 shader 缓存目录。放 app data 而不是 %TEMP% —— 它就是要跨次启动活着才有意义,
/// 被临时目录清理掉就等于没缓存。和 config.rs 同一个 LinPlayer 根,不另起门户。
fn shader_cache_dir() -> std::path::PathBuf {
    dirs::cache_dir()
        .or_else(dirs::config_dir)
        .unwrap_or_else(std::env::temp_dir)
        .join("LinPlayer")
        .join("shader-cache")
}

// ---------- Win32 顶层视频窗口 ----------
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Gdi::HBRUSH;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, RegisterClassW, SetWindowPos, SWP_NOACTIVATE, SWP_SHOWWINDOW,
    WNDCLASSW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP, WS_VISIBLE,
};
use windows_sys::Win32::Foundation::{LPARAM, LRESULT, WPARAM};

static REGISTER: Once = Once::new();
const CLASS_NAME: &[u16] = &[b'l' as u16, b'p' as u16, b'v' as u16, b'i' as u16, b'd' as u16, 0];

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    DefWindowProcW(hwnd, msg, wp, lp)
}

fn ensure_class() {
    REGISTER.call_once(|| unsafe {
        let hinst = GetModuleHandleW(std::ptr::null());
        let wc = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(wndproc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinst,
            hIcon: std::ptr::null_mut(),
            hCursor: std::ptr::null_mut(),
            hbrBackground: std::ptr::null_mut() as HBRUSH,
            lpszMenuName: std::ptr::null(),
            lpszClassName: CLASS_NAME.as_ptr(),
        };
        RegisterClassW(&wc);
    });
}

/// 建一个独立顶层无边框窗口(不进任务栏/不抢焦点),给 mpv 当渲染面。
fn create_overlay() -> isize {
    ensure_class();
    unsafe {
        let hinst = GetModuleHandleW(std::ptr::null());
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            std::ptr::null(),
            WS_POPUP | WS_VISIBLE,
            100, 100, 800, 600,
            std::ptr::null_mut(), // 顶层,无父窗口
            std::ptr::null_mut(),
            hinst,
            std::ptr::null(),
        );
        hwnd as isize
    }
}

/// 把视频窗口对齐到 Tauri 窗口客户区(屏幕坐标 x,y,w,h),并置于 Tauri 窗口正下方。
pub fn sync_overlay(video: isize, tauri: isize, x: i32, y: i32, w: i32, h: i32) {
    unsafe {
        // hWndInsertAfter = tauri => video 排在 tauri 之下(紧贴其后)
        SetWindowPos(video as HWND, tauri as HWND, x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}

// ---------- 播放器 ----------
pub struct Player {
    ctx: *mut mpv_handle,
    pub video_hwnd: isize,
    error_eof: Arc<AtomicBool>, // 直链失效标志(END_FILE=error),供 302 重签探测
    running: Arc<AtomicBool>,
    event_thread: Option<JoinHandle<()>>,
}
unsafe impl Send for Player {}

impl Player {
    pub fn new() -> Result<Self, String> {
        let video = create_overlay();
        unsafe {
            let ctx = mpv_create();
            if ctx.is_null() {
                return Err("mpv_create 失败".into());
            }
            let set = |name: &str, val: &str| {
                let n = CString::new(name).unwrap();
                let v = CString::new(val).unwrap();
                mpv_set_option_string(ctx, n.as_ptr(), v.as_ptr());
            };
            set("wid", &video.to_string());
            set("vo", "gpu-next");
            set("gpu-context", "d3d11");
            set("hwdec", "auto-safe");
            set("keep-open", "yes");
            set("force-window", "yes");
            set("osc", "no");
            set("terminal", "no");
            set("input-default-bindings", "no");
            set("input-vo-keyboard", "no");

            /* shader 缓存。libmpv 没有配置目录(日志里 `cache path: '' -> '-'`),
               不显式给路径就**没有任何缓存** —— 每次起播都要把整条 Anime4K 链
               (最重的档 6 个 pass、VL 模型 143K)重新 glsl→SPIR-V(shaderc)
               →HLSL(spirv-cross)→D3D 编译一遍,首帧就得干等这一整轮。
               这条同时打「起播慢」和「一开超分就卡」。 */
            let cache = shader_cache_dir();
            let _ = std::fs::create_dir_all(&cache);
            set("gpu-shader-cache", "yes");
            set("gpu-shader-cache-dir", &cache.to_string_lossy());

            /* ★ mpv 日志默认**关闭** —— 别无条件打开。
               `log-file` 一旦给了路径,mpv 就把日志目标钉在 MSGL_DEBUG,`msg-level=all=v`
               管不住它(证据:日志里全是 [d] 行),而且会连带把 ffmpeg 的 av_log_set_level
               一起拉到 debug → 解码器逐 packet 打日志并**同步写盘**。
               实测:一个文件都没加载、光 mpv 初始化就写了 247 行 / 24KB。
               需要排查时(见 [[prefetch-proxy-deadlock]] 的查法)设环境变量再跑:
                   set LP_MPV_LOG=1 && LinPlayer.exe
               日志仍落 %TEMP%\linplayer_mpv.log。 */
            if std::env::var_os("LP_MPV_LOG").is_some() {
                set("msg-level", "all=v");
                set("log-file", &mpv_log_path().to_string_lossy());
            }
            let rc = mpv_initialize(ctx);
            if rc < 0 {
                let e = err_str(rc);
                mpv_terminate_destroy(ctx);
                return Err(format!("mpv_initialize 失败: {e}"));
            }

            /* ★ 回读校验 shader 缓存真设上了。上面那个 set() **吞掉 mpv 的返回码** ——
               选项名写错/该版 mpv 不认,是**静默无效**,不报错,只是缓存永远不生效,
               而「起播慢」这种症状根本看不出是它。本项目吃过太多次「不报错,只是静默不干活」
               的亏,这类优化必须回读确认(同 set_shader_level 回读 glsl-shaders 的理由)。 */
            let got = {
                let n = CString::new("gpu-shader-cache-dir").unwrap();
                let p = mpv_get_property_string(ctx, n.as_ptr());
                if p.is_null() {
                    String::new()
                } else {
                    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
                    mpv_free(p as *mut c_void);
                    s
                }
            };
            if got != cache.to_string_lossy() {
                poclog(&format!(
                    "警告: gpu-shader-cache-dir 没设上(回读={got:?} 期望={:?}) —— \
                     shader 每次起播都要重编译,起播会变慢",
                    cache.to_string_lossy()
                ));
            }

            // 事件循环线程:排空 mpv 事件,捕获 END_FILE=error(直链失效)。
            let error_eof = Arc::new(AtomicBool::new(false));
            let running = Arc::new(AtomicBool::new(true));
            let ctx_addr = ctx as usize;
            let (e2, r2) = (error_eof.clone(), running.clone());
            let event_thread = std::thread::spawn(move || {
                let ctx = ctx_addr as *mut mpv_handle;
                while r2.load(Ordering::Relaxed) {
                    let ev = mpv_wait_event(ctx, 0.5);
                    if ev.is_null() {
                        continue;
                    }
                    if (*ev).event_id == MPV_EVENT_END_FILE {
                        let ef = (*ev).data as *const mpv_event_end_file;
                        if !ef.is_null() && (*ef).reason == MPV_END_FILE_REASON_ERROR {
                            e2.store(true, Ordering::Relaxed);
                        }
                    }
                }
            });

            Ok(Player {
                ctx,
                video_hwnd: video,
                error_eof,
                running,
                event_thread: Some(event_thread),
            })
        }
    }

    /// 取并清「直链失效」标志(网盘短链过期 → 触发 302 重签)。
    pub fn take_error_eof(&self) -> bool {
        self.error_eof.swap(false, Ordering::Relaxed)
    }

    fn cmd(&self, args: &[&str]) -> Result<(), String> {
        let cstrs: Vec<CString> = args.iter().map(|a| CString::new(*a).unwrap()).collect();
        let mut ptrs: Vec<*const c_char> = cstrs.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let r = unsafe { mpv_command(self.ctx, ptrs.as_ptr()) };
        if r < 0 { Err(format!("mpv 命令失败: {}", err_str(r))) } else { Ok(()) }
    }

    fn set_str(&self, name: &str, val: &str) {
        let n = CString::new(name).unwrap();
        let v = CString::new(val).unwrap();
        unsafe { mpv_set_property_string(self.ctx, n.as_ptr(), v.as_ptr()); }
    }

    fn get_str(&self, name: &str) -> Option<String> {
        let n = CString::new(name).unwrap();
        unsafe {
            let p = mpv_get_property_string(self.ctx, n.as_ptr());
            if p.is_null() { return None; }
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            mpv_free(p as *mut c_void);
            Some(s)
        }
    }

    fn get_f64(&self, name: &str) -> f64 {
        let n = CString::new(name).unwrap();
        let mut out: f64 = 0.0;
        unsafe {
            mpv_get_property(self.ctx, n.as_ptr(), MPV_FORMAT_DOUBLE, &mut out as *mut f64 as *mut c_void);
        }
        out
    }

    /// 设置/清除 mpv HTTP 代理(media 走代理时用;空串=直连)。SOCKS 不被 mpv 支持,只传 http://。
    pub fn set_http_proxy(&self, proxy: Option<&str>) {
        self.set_str("http-proxy", proxy.unwrap_or(""));
    }

    /// 带续播起点加载:用 mpv 的 `start` 选项(下一次 loadfile 生效),避免 seek 早于解码就绪失败。
    pub fn load_at(&self, url: &str, start_secs: f64) -> Result<(), String> {
        self.set_str(
            "start",
            &if start_secs > 1.0 { start_secs.to_string() } else { "none".to_string() },
        );
        self.cmd(&["loadfile", url])
    }
    /// 带逐流 HTTP headers / UA 加载(网盘直链取流用:Authorization/Cookie/Referer)。
    // ponytail: http-header-fields 用逗号分隔 "Key: Value";含逗号的值会串味,当前源(OpenList Authorization)不涉及,够用。
    pub fn load_with_headers(
        &self,
        url: &str,
        start_secs: f64,
        headers: &HashMap<String, String>,
        user_agent: Option<&str>,
    ) -> Result<(), String> {
        let joined = headers
            .iter()
            .map(|(k, v)| format!("{k}: {v}"))
            .collect::<Vec<_>>()
            .join(",");
        self.set_str("http-header-fields", &joined);
        if let Some(ua) = user_agent {
            self.set_str("user-agent", ua);
        }
        self.load_at(url, start_secs)
    }
    pub fn set_pause(&self, paused: bool) {
        self.set_str("pause", if paused { "yes" } else { "no" });
    }
    /// 挂一条外挂字幕(URL 自鉴权的源用;当前文件加载后调用)。
    pub fn add_subtitle(&self, url: &str, title: &str) {
        // sub-add <url> [<flags> [<title>]];flags=auto 不自动切,让用户/偏好选。
        let _ = self.cmd(&["sub-add", url, "auto", title]);
    }
    pub fn seek_abs(&self, secs: f64) -> Result<(), String> {
        self.cmd(&["seek", &secs.to_string(), "absolute"])
    }
    pub fn status(&self) -> Status {
        Status {
            time: self.get_f64("time-pos"),
            duration: self.get_f64("duration"),
            paused: self.get_str("pause").as_deref() == Some("yes"),
            buffered: self.get_f64("demuxer-cache-time"),
        }
    }
    pub fn tracks(&self) -> Vec<Track> {
        let count = self.get_str("track-list/count").and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
        let mut v = Vec::new();
        for i in 0..count {
            let kind = self.get_str(&format!("track-list/{i}/type")).unwrap_or_default();
            if kind != "audio" && kind != "sub" { continue; }
            v.push(Track {
                kind,
                id: self.get_str(&format!("track-list/{i}/id")).unwrap_or_default(),
                title: self.get_str(&format!("track-list/{i}/title")).unwrap_or_default(),
                lang: self.get_str(&format!("track-list/{i}/lang")).unwrap_or_default(),
                selected: self.get_str(&format!("track-list/{i}/selected")).as_deref() == Some("yes"),
            });
        }
        v
    }
    pub fn set_track(&self, kind: &str, id: &str) {
        let prop = if kind == "audio" { "aid" } else { "sid" };
        self.set_str(prop, id);
    }
    /// 按偏好一次性应用音轨/字幕(None=不动)。
    pub fn apply_tracks(&self, aid: Option<String>, sid: Option<String>) {
        if let Some(a) = aid {
            self.set_str("aid", &a);
        }
        if let Some(s) = sid {
            self.set_str("sid", &s);
        }
    }

    // ================= 播放器能力面 =================
    // 对齐旧 Flutter 三端契约 lib/core/services/video_player_service.dart。
    // 之前只搬了 load/pause/seek/track 这几样,草稿要的倍速/音量/截图/画面比例/延迟/
    // 字幕样式/超分全没搬 → UI 上就是一排"点了没反应"的死按钮。这里补齐。

    /// 通用属性读/写 + 命令。插件桥和一次性调参靠它(Flutter 的 mpvGetProperty/
    /// mpvSetProperty/mpvCommand 同源);有专用方法的优先用专用方法。
    pub fn get_property(&self, name: &str) -> Option<String> {
        self.get_str(name)
    }
    pub fn set_property(&self, name: &str, value: &str) {
        self.set_str(name, value);
    }
    pub fn command(&self, args: &[String]) -> Result<(), String> {
        let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        self.cmd(&refs)
    }

    /// 倍速。mpv 的 speed 同时变调,配 audio-pitch-correction(默认开)保音高。
    pub fn set_speed(&self, speed: f64) {
        self.set_str("speed", &speed.clamp(0.1, 6.0).to_string());
    }
    pub fn speed(&self) -> f64 {
        let v = self.get_f64("speed");
        if v <= 0.0 { 1.0 } else { v }
    }

    /// 音量 0..=130(mpv 上限 130 是软增益)。
    pub fn set_volume(&self, vol: f64) {
        self.set_str("volume", &vol.clamp(0.0, 130.0).to_string());
    }
    pub fn volume(&self) -> f64 {
        self.get_f64("volume")
    }
    pub fn set_mute(&self, mute: bool) {
        self.set_str("mute", if mute { "yes" } else { "no" });
    }
    pub fn muted(&self) -> bool {
        self.get_str("mute").as_deref() == Some("yes")
    }

    /// 截图到文件。用 screenshot-to-file 而非 screenshot-raw:后者要走 mpv_node
    /// 取原始像素再自己编码,而我们只需要落一个 png 给用户。
    /// each-frame=no;"video" = 不带 OSD/字幕的原始画面。
    pub fn screenshot_to(&self, path: &str) -> Result<(), String> {
        self.cmd(&["screenshot-to-file", path, "video"])
    }

    /// 音画同步:音频延迟(秒,可负)。
    pub fn set_audio_delay(&self, secs: f64) {
        self.set_str("audio-delay", &secs.to_string());
    }
    pub fn audio_delay(&self) -> f64 {
        self.get_f64("audio-delay")
    }
    /// 字幕延迟(秒,可负)。
    pub fn set_sub_delay(&self, secs: f64) {
        self.set_str("sub-delay", &secs.to_string());
    }
    pub fn sub_delay(&self) -> f64 {
        self.get_f64("sub-delay")
    }

    /// 画面比例。"" / "-1" = 还原源比例(mpv 用 video-aspect-override=-1 复位)。
    pub fn set_aspect_ratio(&self, ratio: &str) {
        let v = if ratio.is_empty() || ratio == "auto" { "-1" } else { ratio };
        self.set_str("video-aspect-override", v);
    }

    /// 硬解档位。零拷贝(d3d11va)在 Win 上是默认最佳;软解排查问题用 "no"。
    /// 见 [[desktop-double-audio-orphan-player]]:Win 默认 d3d11va 零拷贝。
    pub fn set_hwdec(&self, mode: &str) {
        self.set_str("hwdec", mode);
    }
    pub fn hwdec(&self) -> String {
        self.get_str("hwdec-current")
            .or_else(|| self.get_str("hwdec"))
            .unwrap_or_default()
    }

    // ---- 字幕样式(对齐 Flutter setSubtitleFont/Size/Position/Background/BlendMode)----
    pub fn set_sub_font(&self, font: &str) {
        // 「默认」是 UI 占位,不该塞给 libass(见 [[android-mpv-subtitle-fonts]] 同款守卫)。
        if font.is_empty() || font == "默认" {
            return;
        }
        self.set_str("sub-font", font);
    }
    /// 字幕缩放倍率。**这才是「字幕大小」该拧的那颗旋钮**。
    ///
    /// 2026-07-16 用 ctypes 直接问 libmpv(v0.41.0-744)实测:
    ///   - `sub-ass-override` 默认 = `scale` —— 这个模式下 ASS 字幕**只认 `sub-scale`,
    ///     完全忽略 `sub-font-size`**。而内封字幕(尤其番剧)绝大多数是 ASS。
    ///   - `secondary-sub-ass-override` 默认 = `strip` —— ASS 标记被剥成纯文本,
    ///     于是它**反过来只认 `sub-font-size`**。
    /// 合起来正是用户 2026-07-16 报的那个怪象:「只能调次字幕的字体大小,主字幕的调不动」——
    /// 同一个 sub-font-size,对主(ASS 保样式)无效、对次(被 strip 成纯文本)有效。
    /// `sub-scale` 对 ASS 与纯文本都生效,所以大小统一走它。别再拿 sub-font-size 当大小旋钮。
    pub fn set_sub_scale(&self, scale: f64) {
        self.set_str("sub-scale", &format!("{:.2}", scale.clamp(0.2, 4.0)));
    }
    /// 次字幕的 ASS 处理模式。mpv 默认 `strip`(剥成纯文本)= 用户说的「次字幕不渲染样式」。
    /// `scale` 则与主字幕同规矩:保留 ASS 自带样式。取值必须是 mpv 认的枚举,别乱传。
    pub fn set_secondary_sub_ass_override(&self, mode: &str) {
        if !matches!(mode, "no" | "scale" | "force" | "strip") {
            return; // 传错值 mpv 只会静默拒绝,这里先挡掉,免得以为设上了
        }
        self.set_str("secondary-sub-ass-override", mode);
    }
    /// 字幕竖直位置 0(顶)..100(底)。mpv 只收整数(见 [[macos-no-video-hwdec]])。
    pub fn set_sub_position(&self, pos: f64) {
        self.set_str("sub-pos", &(pos.clamp(0.0, 100.0).round() as i64).to_string());
    }
    pub fn set_sub_background(&self, enabled: bool) {
        // 半透明黑底 vs 全透明;ASS 自带样式的字幕不受此影响。
        self.set_str("sub-back-color", if enabled { "#80000000" } else { "#00000000" });
    }
    pub fn set_sub_blend_mode(&self, mode: &str) {
        self.set_str("blend-subtitles", mode);
    }

    // ---- 次字幕/双字幕(对齐 Flutter loadSecondarySubtitle/selectSecondary…)----
    pub fn set_secondary_sub(&self, id: &str) {
        self.set_str("secondary-sid", if id.is_empty() { "no" } else { id });
    }
    pub fn add_secondary_sub(&self, url: &str, title: &str) -> Result<(), String> {
        // sub-add 挂上后再指给 secondary-sid;取新挂那条(sub 列表末尾)。
        self.cmd(&["sub-add", url, "auto", title])?;
        if let Some(id) = self.last_sub_id() {
            self.set_secondary_sub(&id);
        }
        Ok(())
    }
    pub fn set_secondary_sub_delay(&self, secs: f64) {
        self.set_str("secondary-sub-delay", &secs.to_string());
    }
    pub fn set_secondary_sub_position(&self, pos: f64) {
        self.set_str("secondary-sub-pos", &(pos.clamp(0.0, 100.0).round() as i64).to_string());
    }
    /// 最后一条字幕轨的 id(sub-add 之后取新挂的那条)。
    fn last_sub_id(&self) -> Option<String> {
        self.tracks()
            .into_iter()
            .filter(|t| t.kind == "sub")
            .next_back()
            .map(|t| t.id)
    }

    /// 超分(Anime4K):按档位挂 glsl-shaders。空列表 = 关。
    /// 传绝对路径列表;mpv 的 glsl-shaders 用 ; 分隔,路径里的 ; 和 " 需转义。
    pub fn set_shaders(&self, paths: &[String]) {
        if paths.is_empty() {
            self.set_str("glsl-shaders", "");
            return;
        }
        let joined = paths.join(";");
        self.set_str("glsl-shaders", &joined);
    }
    /// shader 参数(mpv glsl-shader-opts)。hooke007 那套 shader 全靠参数调强度,
    /// 不设 = 一直吃默认值(CAS STR=0.5 只开一半)。返回是否设上了 —— 参数名写错
    /// mpv 会拒掉整个选项,而且**不会有任何提示**,必须回读。
    pub fn set_shader_opts(&self, opts: &str) -> bool {
        self.set_str("glsl-shader-opts", opts);
        self.get_str("glsl-shader-opts").as_deref() == Some(opts)
    }

    /// 源画面尺寸(dwidth/dheight 是**显示**尺寸,已算进非方像素/裁剪,正是 shader 里的 MAIN)。
    /// 没在播 → None。
    pub fn video_size(&self) -> Option<(f64, f64)> {
        let w = self.get_str("dwidth")?.parse().ok()?;
        let h = self.get_str("dheight")?.parse().ok()?;
        Some((w, h))
    }
    /// mpv 输出区尺寸(= shader 里的 OUTPUT)。窗口大小,不是屏幕大小。
    pub fn output_size(&self) -> Option<(f64, f64)> {
        let w = self.get_str("osd-width")?.parse().ok()?;
        let h = self.get_str("osd-height")?.parse().ok()?;
        Some((w, h))
    }

    /// 实际挂上的 shader 数(用于校验超分是否真生效 —— 见 [[superres-and-toast]]:
    /// 旧 Flutter 桌面端软件纹理根本不跑 glsl-shader,回读才知道)。
    /// ⚠️ 它只说明 mpv **收下了**路径,**不代表 shader 会跑** —— 见 will_run()。
    pub fn shader_count(&self) -> usize {
        self.get_str("glsl-shaders")
            .map(|s| s.split(';').filter(|x| !x.trim().is_empty()).count())
            .unwrap_or(0)
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        // 先停事件线程并 join,避免它在 ctx 销毁后仍访问(悬垂)。
        self.running.store(false, Ordering::Relaxed);
        if let Some(h) = self.event_thread.take() {
            let _ = h.join();
        }
        unsafe { mpv_terminate_destroy(self.ctx); }
    }
}

#[derive(serde::Serialize)]
pub struct Status {
    pub time: f64,
    pub duration: f64,
    pub paused: bool,
    pub buffered: f64,
}

