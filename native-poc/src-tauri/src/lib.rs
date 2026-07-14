mod mpv;

use linplayer_core::config::{Account, AppConfig, Prefs};
use linplayer_core::emby::{self, Item, LoginResult, PlaybackTarget, Session};
use linplayer_core::http;
use linplayer_core::media::{pick_tracks, Track};
use linplayer_core::source::anirss::AniRssBackend;
use linplayer_core::source::feiniu::FeiniuBackend;
use linplayer_core::source::openlist::OpenListBackend;
use linplayer_core::source::quark::QuarkBackend;
use linplayer_core::source::{MediaSourceBackend, SourceEntry, SourceKind, SourceServer};
use mpv::{Player, Status};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{Manager, State, WindowEvent};

struct AppState {
    http: reqwest::Client,
    config: Mutex<AppConfig>,
    session: Mutex<Option<Session>>,
    player: Mutex<Option<Player>>,
    playback: Mutex<Option<PlaybackTarget>>, // 当前播放会话(上报三件套共享)
    // 文件浏览型源:后端注册表(长驻,持 token 缓存)+ 当前活跃源
    source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>>,
    source: Mutex<Option<(SourceKind, SourceServer)>>,
    // 当前正在播放的源条目(entry_id, entry_name),供 302 重签重解析;None=非源播放
    source_play_entry: Mutex<Option<(String, String)>>,
    // 连续 302 重签次数(防死循环:文件本身放不了时不无限重签),每次新播放清零
    resign_count: AtomicU32,
}

fn poclog(msg: &str) {
    use std::io::Write;
    let path = std::env::temp_dir().join("linplayer_poc.log");
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{msg}");
    }
}

/// 把 mpv 视频窗口对齐到 Tauri 窗口客户区。
fn sync_video(window: &tauri::WebviewWindow, parent: isize, state: &AppState) {
    let video = state.player.lock().unwrap().as_ref().map(|p| p.video_hwnd);
    if let Some(v) = video {
        if let (Ok(pos), Ok(size)) = (window.inner_position(), window.inner_size()) {
            mpv::sync_overlay(v, parent, pos.x, pos.y, size.width as i32, size.height as i32);
        }
    }
}

fn hwnd_of(window: &tauri::WebviewWindow) -> Result<isize, String> {
    let handle = window.window_handle().map_err(|e| e.to_string())?;
    match handle.as_raw() {
        RawWindowHandle::Win32(h) => Ok(h.hwnd.get()),
        _ => Err("非 Win32 窗口".into()),
    }
}

fn session_of(state: &State<'_, AppState>) -> Result<Session, String> {
    state
        .session
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "未登录".to_string())
}

// ---------- Emby 命令 ----------
#[tauri::command]
async fn login(
    state: State<'_, AppState>,
    server: String,
    username: String,
    password: String,
) -> Result<LoginResult, String> {
    let device_id = state.config.lock().unwrap().device_id.clone();
    let (session, result) =
        emby::login(&state.http, &server, &username, &password, &device_id).await?;
    // 持久化账号 -> 重启免登
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.upsert(Account {
            server: result.server.clone(),
            token: result.token.clone(),
            user_id: result.user_id.clone(),
            user_name: result.user_name.clone(),
        });
        cfg.save();
    }
    *state.session.lock().unwrap() = Some(session);
    Ok(result)
}

/// 已登录账号(用于启动时跳过登录页直接进库);无则 None。
#[tauri::command]
fn current_session(state: State<'_, AppState>) -> Option<LoginResult> {
    state.config.lock().unwrap().active_account().map(|a| LoginResult {
        server: a.server.clone(),
        token: a.token.clone(),
        user_id: a.user_id.clone(),
        user_name: a.user_name.clone(),
    })
}

#[tauri::command]
async fn views(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::views(&state.http, &s).await
}

#[tauri::command]
async fn list_items(state: State<'_, AppState>, parent_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::items(&state.http, &s, &parent_id).await
}

#[tauri::command]
fn image_url(state: State<'_, AppState>, item_id: String) -> Result<String, String> {
    let s = session_of(&state)?;
    Ok(emby::image_url(&s, &item_id))
}

// ---------- 播放命令 ----------
/// 播放:解析流 -> 从 resume_secs 起播 -> 上报 start;返回起播秒数供前端定位进度条。
#[tauri::command]
async fn play(
    state: State<'_, AppState>,
    item_id: String,
    resume_secs: f64,
) -> Result<f64, String> {
    let s = session_of(&state)?;
    let target = emby::resolve_stream(&state.http, &s, &item_id).await?;
    poclog(&format!(
        "PLAY item={item_id} resume={resume_secs} psid={} url={}",
        target.play_session_id, target.url
    ));
    // 加载(不跨 await 持锁)
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or_else(|| {
            poclog("PLAY 失败: 播放器未就绪(mpv 初始化没成功)");
            "播放器未就绪".to_string()
        })?;
        let _ = p.take_error_eof();
        p.load_at(&target.url, resume_secs)?;
        p.set_pause(false);
    }
    *state.source_play_entry.lock().unwrap() = None; // Emby 播放,非源
    // 上报 start(失败不阻断播放)
    if let Err(e) = emby::report_start(&state.http, &s, &target, resume_secs).await {
        poclog(&format!("report_start ERR: {e}"));
    }
    *state.playback.lock().unwrap() = Some(target);
    poclog("load OK");
    Ok(resume_secs)
}

/// 周期/暂停切换时上报进度(前端每 ~5s 及暂停切换时调)。仅 Emby 播放有会话时上报。
#[tauri::command]
async fn report_progress(state: State<'_, AppState>, pos: f64, paused: bool) -> Result<(), String> {
    let target = state.playback.lock().unwrap().clone();
    let Some(t) = target else { return Ok(()) }; // 网盘源无会话,跳过
    let s = session_of(&state)?;
    let _ = emby::report_progress(&state.http, &s, &t, pos, paused).await;
    Ok(())
}

/// 停止播放:暂停 mpv + 上报 stopped(写回最终进度 -> 续播落地)+ 清会话。
#[tauri::command]
async fn stop_playback(state: State<'_, AppState>, pos: f64) -> Result<(), String> {
    {
        let guard = state.player.lock().unwrap();
        if let Some(p) = guard.as_ref() {
            p.set_pause(true);
        }
    }
    *state.source_play_entry.lock().unwrap() = None; // 退出播放,停止 302 看门狗
    let target = state.playback.lock().unwrap().take();
    if let (Some(t), Ok(s)) = (target, session_of(&state)) {
        if let Err(e) = emby::report_stopped(&state.http, &s, &t, pos).await {
            poclog(&format!("report_stopped ERR: {e}"));
        }
    }
    Ok(())
}

#[tauri::command]
fn set_pause(state: State<'_, AppState>, paused: bool) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.set_pause(paused);
    Ok(())
}

#[tauri::command]
fn seek(state: State<'_, AppState>, pos: f64) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.seek_abs(pos)
}

#[tauri::command]
fn status(state: State<'_, AppState>) -> Result<Status, String> {
    let guard = state.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.status())
}

#[tauri::command]
fn tracks(state: State<'_, AppState>) -> Result<Vec<Track>, String> {
    let guard = state.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.tracks())
}

#[tauri::command]
fn set_track(state: State<'_, AppState>, kind: String, id: String) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.set_track(&kind, &id);
    Ok(())
}

/// 按已存偏好自动选轨(起播后前端调一次)。返回实际选中的 (aid, sid)。
#[tauri::command]
fn apply_prefs(state: State<'_, AppState>) -> Result<(Option<String>, Option<String>), String> {
    let prefs = state.config.lock().unwrap().prefs.clone();
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let tracks = p.tracks();
    let (aid, sid) = pick_tracks(
        &tracks,
        prefs.audio_lang.as_deref(),
        prefs.sub_lang.as_deref(),
        prefs.sub_enabled,
    );
    p.apply_tracks(aid.clone(), sid.clone());
    Ok((aid, sid))
}

#[tauri::command]
fn get_prefs(state: State<'_, AppState>) -> Prefs {
    state.config.lock().unwrap().prefs.clone()
}

/// 记住偏好(用户手动切轨时持久化,下次同语言自动命中)。
#[tauri::command]
fn set_prefs(
    state: State<'_, AppState>,
    audio_lang: Option<String>,
    sub_lang: Option<String>,
    sub_enabled: bool,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs = Prefs { audio_lang, sub_lang, sub_enabled };
    cfg.save();
    Ok(())
}

// ---------- 文件浏览型源命令(网盘/追番)----------
fn source_backend(
    state: &State<'_, AppState>,
    kind: SourceKind,
) -> Result<Arc<dyn MediaSourceBackend>, String> {
    state
        .source_backends
        .get(&kind)
        .cloned()
        .ok_or_else(|| "该源类型暂未接入".to_string())
}

#[tauri::command]
async fn source_login(
    state: State<'_, AppState>,
    kind: SourceKind,
    base_url: String,
    username: String,
    password: String,
    cookie: Option<String>,
) -> Result<(), String> {
    // 夸克 Cookie 模式无 base_url(固定云端 API),用 kind 名做稳定 id。
    let id = if base_url.trim().is_empty() {
        format!("{kind:?}")
    } else {
        base_url.clone()
    };
    let server = SourceServer {
        id,
        base_url,
        username: (!username.is_empty()).then_some(username),
        password: (!password.is_empty()).then_some(password),
        token: cookie.filter(|c| !c.is_empty()),
        extra: HashMap::new(),
    };
    let backend = source_backend(&state, kind)?;
    // 列根目录以验证登录可用
    backend
        .list_dir(&state.http, &server, None)
        .await
        .map_err(|e| e.message)?;
    *state.source.lock().unwrap() = Some((kind, server));
    Ok(())
}

#[tauri::command]
async fn source_list_dir(
    state: State<'_, AppState>,
    dir_id: Option<String>,
) -> Result<Vec<SourceEntry>, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, kind)?;
    backend
        .list_dir(&state.http, &server, dir_id.as_deref())
        .await
        .map_err(|e| e.message)
}

/// 解析源文件为直链并用 mpv 播放(带逐流 headers)。返回起播秒数。
#[tauri::command]
async fn source_play(
    state: State<'_, AppState>,
    entry_id: String,
    entry_name: String,
    resume_secs: f64,
) -> Result<f64, String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, kind)?;
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw: None,
    };
    let resolved = backend
        .resolve_play(&state.http, &server, &entry, None)
        .await
        .map_err(|e| e.message)?;
    poclog(&format!("SOURCE PLAY url={}", resolved.url));
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        let _ = p.take_error_eof(); // 清历史失效标志
        p.load_with_headers(
            &resolved.url,
            resume_secs,
            &resolved.http_headers,
            resolved.user_agent_override.as_deref(),
        )?;
        p.set_pause(false);
    }
    *state.playback.lock().unwrap() = None; // 网盘源不走 Emby 上报
    *state.source_play_entry.lock().unwrap() = Some((entry.id.clone(), entry.name.clone()));
    state.resign_count.store(0, Ordering::Relaxed);
    Ok(resume_secs)
}

/// 302 看门狗:探测直链是否失效(END_FILE=error),失效则重解析并从 pos 续播。返回是否重签了。
/// 前端播放中每轮轮询调用;仅对网盘源播放生效(Emby 直链稳定,不重签)。
#[tauri::command]
async fn source_watchdog(state: State<'_, AppState>, pos: f64) -> Result<bool, String> {
    // 无失效信号 or 非源播放 -> 什么都不做
    let errored = {
        let guard = state.player.lock().unwrap();
        match guard.as_ref() {
            Some(p) => p.take_error_eof(),
            None => return Ok(false),
        }
    };
    let entry = state.source_play_entry.lock().unwrap().clone();
    let (Some((entry_id, entry_name)), true) = (entry, errored) else {
        return Ok(false);
    };
    let Some((kind, server)) = state.source.lock().unwrap().clone() else {
        return Ok(false);
    };
    // 连续重签超上限:文件本身放不了(非过期),放弃以免死循环。
    if state.resign_count.load(Ordering::Relaxed) >= 3 {
        *state.source_play_entry.lock().unwrap() = None;
        poclog("302 重签连续 3 次仍失败,放弃");
        return Ok(false);
    }
    state.resign_count.fetch_add(1, Ordering::Relaxed);
    let backend = source_backend(&state, kind)?;
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw: None,
    };
    // 重解析拿新直链,从原位置续播。
    let resolved = backend
        .resolve_play(&state.http, &server, &entry, None)
        .await
        .map_err(|e| e.message)?;
    poclog(&format!("302 重签 -> {}", resolved.url));
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    p.load_with_headers(
        &resolved.url,
        pos,
        &resolved.http_headers,
        resolved.user_agent_override.as_deref(),
    )?;
    p.set_pause(false);
    Ok(true)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let config = AppConfig::load();
    let http = http::client();

    // 源后端注册表(长驻,持各自 token 缓存)。逐 Phase 增量接入更多源。
    let mut source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>> = HashMap::new();
    source_backends.insert(SourceKind::Openlist, Arc::new(OpenListBackend::new()));
    source_backends.insert(SourceKind::Anirss, Arc::new(AniRssBackend::new()));
    source_backends.insert(SourceKind::Feiniu, Arc::new(FeiniuBackend::new()));
    source_backends.insert(SourceKind::Quark, Arc::new(QuarkBackend::new()));

    // 有活跃账号 -> 用存盘凭据重建会话(重启免登)
    let session = config.active_account().map(|a| Session {
        server: a.server.clone(),
        token: a.token.clone(),
        user_id: a.user_id.clone(),
        device_id: config.device_id.clone(),
    });

    // 清旧诊断日志
    let _ = std::fs::remove_file(std::env::temp_dir().join("linplayer_poc.log"));
    let _ = std::fs::remove_file(mpv::mpv_log_path());

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            http,
            config: Mutex::new(config),
            session: Mutex::new(session),
            player: Mutex::new(None),
            playback: Mutex::new(None),
            source_backends,
            source: Mutex::new(None),
            source_play_entry: Mutex::new(None),
            resign_count: AtomicU32::new(0),
        })
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");
            let parent = match hwnd_of(&window) {
                Ok(p) => {
                    poclog(&format!("hwnd OK parent={p}"));
                    Some(p)
                }
                Err(e) => {
                    poclog(&format!("hwnd ERR: {e}"));
                    None
                }
            };
            match Player::new() {
                Ok(p) => {
                    poclog(&format!("player init OK video_hwnd={}", p.video_hwnd));
                    *app.state::<AppState>().player.lock().unwrap() = Some(p);
                }
                Err(e) => poclog(&format!("player init ERR: {e}")),
            }
            if let Some(parent) = parent {
                sync_video(&window, parent, &app.state::<AppState>());
            }

            // 窗口移动/缩放/激活 -> 重新对齐视频窗口
            let app_handle = app.handle().clone();
            let win2 = window.clone();
            window.on_window_event(move |ev| {
                if matches!(
                    ev,
                    WindowEvent::Resized(_) | WindowEvent::Moved(_) | WindowEvent::Focused(true)
                ) {
                    if let Some(parent) = parent {
                        sync_video(&win2, parent, &app_handle.state::<AppState>());
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            login,
            current_session,
            views,
            list_items,
            image_url,
            play,
            report_progress,
            stop_playback,
            set_pause,
            seek,
            status,
            tracks,
            set_track,
            apply_prefs,
            get_prefs,
            set_prefs,
            source_login,
            source_list_dir,
            source_play,
            source_watchdog
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
