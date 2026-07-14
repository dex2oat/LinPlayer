// 最小 libmpv 封装。
// 合成方案:mpv 渲染进一个【独立顶层无边框窗口】,垫在【透明 Tauri 窗口】正下方并保持对齐。
// 顶层↔顶层 DWM 能正常合成(子窗口无法进逐像素透明窗口,故不能用子窗口)。
#![allow(non_camel_case_types)]

use linplayer_core::media::Track;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::Once;

// ---------- libmpv FFI ----------
#[repr(C)]
pub struct mpv_handle {
    _private: [u8; 0],
}

const MPV_FORMAT_DOUBLE: c_int = 5;

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
            set("msg-level", "all=v");
            set("log-file", &mpv_log_path().to_string_lossy());
            let rc = mpv_initialize(ctx);
            if rc < 0 {
                let e = err_str(rc);
                mpv_terminate_destroy(ctx);
                return Err(format!("mpv_initialize 失败: {e}"));
            }
            Ok(Player { ctx, video_hwnd: video })
        }
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

    /// 带续播起点加载:用 mpv 的 `start` 选项(下一次 loadfile 生效),避免 seek 早于解码就绪失败。
    pub fn load_at(&self, url: &str, start_secs: f64) -> Result<(), String> {
        self.set_str(
            "start",
            &if start_secs > 1.0 { start_secs.to_string() } else { "none".to_string() },
        );
        self.cmd(&["loadfile", url])
    }
    pub fn set_pause(&self, paused: bool) {
        self.set_str("pause", if paused { "yes" } else { "no" });
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
}

impl Drop for Player {
    fn drop(&mut self) {
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

