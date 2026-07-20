//! LinPlayer Android TV 宿主壳。
//!
//! ## 它和 apps/desktop 是什么关系
//! 仍然**不依赖** apps/desktop —— 那个包绑死 tauri 桌面特性,交叉编译到
//! aarch64-linux-android 第一步就死。两端共用的是 crate:
//!   * `crates/core` —— 平台无关的数据源/网络/配置;
//!   * `crates/mpv`  —— libmpv 封装 + 各平台渲染面(2026-07-20 从桌面壳提出来的)。
//!
//! 本文件里的命令是从 `apps/desktop/src/lib.rs` **逐字照抄签名和返回类型**的。
//! 前端 `ui/shared/api.ts` 的 TS 类型和这些结构体逐字段对应,改一个名字前端就静默拿到
//! undefined —— 不报错,只是数据不见了。加字段/改名请两端一起改。
//!
//! ## 播放链路(安卓)
//! `libmpv.so` 由 Java 层 `System.loadLibrary("mpv")` 加载,渲染面是垫在透明 WebView
//! 底下的 SurfaceView。两条都不能省,理由分别写在 MainActivity.kt 和 crates/mpv 的
//! `mod overlay` 里。
//!
//! ⚠️ **本轮接入未经真机验证** —— 手上没有安卓设备,CI 只能证明它编得过、
//! libmpv.so 确实进了 APK。首次真机跑挂了先看 `adb logcat -s mpv`。

mod imgcache;

use linplayer_core::config::{Account, AppConfig, Prefs};
use linplayer_core::emby::{self, Item, LoginResult, Session};
use linplayer_core::http;
use linplayer_core::media::Track;
use linplayer_core::source::anirss::AniRssBackend;
use linplayer_core::source::feiniu::FeiniuBackend;
use linplayer_core::source::openlist::OpenListBackend;
use linplayer_core::source::quark::QuarkBackend;
use linplayer_core::source::{MediaSourceBackend, SourceEntry, SourceKind, SourceServer};
use linplayer_core::sync::{bangumi, trakt};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tauri::{Manager, State};

struct AppState {
    http: reqwest::Client,
    config: Mutex<AppConfig>,
    session: Mutex<Option<Session>>,
    // 文件浏览型源:后端注册表(长驻,持 token 缓存)+ 当前活跃源
    source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>>,
    source: Mutex<Option<(SourceKind, SourceServer)>>,
    // 多线程下载管理器(长驻,持久化索引)。
    download: linplayer_core::download::DownloadManager,
    // server_id -> 连通状态三态。probe_accounts 刷新,list_accounts 读;不落盘(重启即重探)。
    account_status: Mutex<HashMap<String, AccountStatus>>,
    // check_update 查到的待装版本。存核层是为了不让前端把资产清单原样传回来。
    pending_update: Mutex<Option<linplayer_core::update::UpdateInfo>>,
}

fn session_of(state: &State<'_, AppState>) -> Result<Session, String> {
    state
        .session
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "未登录".to_string())
}

/* ============================================================
   播放器 —— 原生 libmpv(与桌面同一份 crates/mpv)
   ============================================================ */

use linplayer_mpv::{Player, Status};

/// 播放器实例 + 当前 Emby 播放会话。
///
/// ★ 为什么懒创建而不是启动时就建:安卓的 Surface 由系统在 surfaceCreated 回调里给,
///   App 启动那一刻它还不存在。启动时建 Player 必然拿到 wid=0 直接失败。
struct PlayerState {
    player: Mutex<Option<Player>>,
    /// 当前播放会话(Emby 上报三件套共享)。网盘/本地源没有,故 Option。
    playback: Mutex<Option<linplayer_core::emby::PlaybackTarget>>,
}

impl Default for PlayerState {
    fn default() -> Self {
        Self { player: Mutex::new(None), playback: Mutex::new(None) }
    }
}

/// 取播放器;没有就现建一个。
///
/// ★ 建失败的最常见原因是 Surface 还没就绪(用户在页面还没铺好时就按了播放),
///   这时**不缓存失败结果** —— 下次再调会重试,而不是一路错到重启 App。
fn ensure_player(ps: &PlayerState) -> Result<std::sync::MutexGuard<'_, Option<Player>>, String> {
    let mut g = ps.player.lock().unwrap();
    if g.is_none() {
        *g = Some(Player::new()?);
    }
    Ok(g)
}

#[tauri::command]
async fn play(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    item_id: String,
    resume_secs: f64,
    media_source_id: Option<String>,
) -> Result<f64, String> {
    let s = session_of(&state)?;
    let target =
        emby::resolve_stream(&state.http, &s, &item_id, media_source_id.as_deref()).await?;

    let g = ensure_player(&ps)?;
    let p = g.as_ref().unwrap();
    let _ = p.take_error_eof(); // 清历史失效标志
    p.load_at(&target.url, resume_secs)?;
    p.set_pause(false);
    *ps.playback.lock().unwrap() = Some(target);
    Ok(resume_secs)
}

/* ponytail: 本地下载文件与网盘/聚合源的起播先不接。
   两者都要先把「下载索引 / 源解析」这两条链路在安卓上跑通,而现在连 Emby 直连
   都还没上过真机 —— 先证明画面和声音出得来,再铺开源类型。
   保持明确报错而不是假装成功:假装成功的表现是黑屏等一个永远不来的 status。 */
#[tauri::command]
fn play_local(_id: String, _resume_secs: f64) -> Result<f64, String> {
    Err("安卓端暂不支持播放本地下载文件".to_string())
}

#[tauri::command]
fn source_play(
    _entry_id: String,
    _entry_name: String,
    _resume_secs: f64,
    _raw: Option<serde_json::Value>,
) -> Result<f64, String> {
    Err("安卓端暂不支持播放网盘/聚合源".to_string())
}

#[tauri::command]
fn seek(ps: State<'_, PlayerState>, pos: f64) -> Result<(), String> {
    let g = ps.player.lock().unwrap();
    g.as_ref().ok_or("播放器未就绪")?.seek_abs(pos)
}

#[tauri::command]
fn set_pause(ps: State<'_, PlayerState>, paused: bool) -> Result<(), String> {
    let g = ps.player.lock().unwrap();
    g.as_ref().ok_or("播放器未就绪")?.set_pause(paused);
    Ok(())
}

#[tauri::command]
fn set_track(ps: State<'_, PlayerState>, kind: String, id: String) -> Result<(), String> {
    let g = ps.player.lock().unwrap();
    g.as_ref().ok_or("播放器未就绪")?.set_track(&kind, &id);
    Ok(())
}

#[tauri::command]
fn status(ps: State<'_, PlayerState>) -> Result<Status, String> {
    let g = ps.player.lock().unwrap();
    Ok(g.as_ref().ok_or("播放器未就绪")?.status())
}

#[tauri::command]
fn tracks(ps: State<'_, PlayerState>) -> Result<Vec<Track>, String> {
    let g = ps.player.lock().unwrap();
    Ok(g.as_ref().ok_or("播放器未就绪")?.tracks())
}

#[tauri::command]
async fn stop_playback(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    pos: f64,
) -> Result<(), String> {
    // 先上报再拆播放器:反过来的话 pos 已经取不到了。
    let target = ps.playback.lock().unwrap().take();
    if let Some(t) = target {
        if let Ok(s) = session_of(&state) {
            let _ = emby::report_stopped(&state.http, &s, &t, pos).await;
        }
    }
    /* ★ 必须真的 drop 掉 Player。安卓上留着它 = 一直占着 Surface 和 MediaCodec 实例,
       下次起播要么黑屏要么直接拿不到解码器(硬件解码器数量是有限的)。 */
    ps.player.lock().unwrap().take();
    Ok(())
}

#[tauri::command]
async fn report_progress(
    state: State<'_, AppState>,
    ps: State<'_, PlayerState>,
    pos: f64,
    paused: bool,
) -> Result<(), String> {
    let target = ps.playback.lock().unwrap().clone();
    let Some(t) = target else { return Ok(()) }; // 无会话(网盘源)跳过
    let s = session_of(&state)?;
    let _ = emby::report_progress(&state.http, &s, &t, pos, paused).await;
    Ok(())
}

/* ============================================================
   Emby 浏览 / 账号
   ============================================================ */

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
    {
        let mut cfg = state.config.lock().unwrap();
        // 只在**首次添加**时设图标:upsert 对已存在账号是 `acc.icon_url.or(old)`,
        // 传 Some 会盖掉用户自定义的图标 —— 重登不能把人家换过的图标冲回头像。
        let is_new = cfg.find(&result.server).is_none();
        let icon_url = if is_new {
            result
                .primary_image_tag
                .as_deref()
                .filter(|t| !t.is_empty())
                .map(|tag| {
                    linplayer_core::server_batch::build_icon_url(
                        &result.server,
                        Some(&result.user_id),
                        Some(tag),
                    )
                })
        } else {
            None
        };
        cfg.upsert(Account {
            server: result.server.clone(),
            token: result.token.clone(),
            user_id: result.user_id.clone(),
            user_name: result.user_name.clone(),
            icon_url,
            password: (!password.is_empty()).then_some(password),
            ..Default::default()
        });
        cfg.save();
    }
    *state.session.lock().unwrap() = Some(session);
    *state.source.lock().unwrap() = None; // 登 Emby → 上一个源作废
    Ok(result)
}

/// 已登录的 Emby 账号(启动时跳过登录页直接进库);无则 None。
/// 活跃的是浏览型源时返回 None —— 它没有 Emby token,吐个空 token 的会话会被前端拿去打 401。
#[tauri::command]
fn current_session(state: State<'_, AppState>) -> Option<LoginResult> {
    state
        .config
        .lock()
        .unwrap()
        .active_account()
        .filter(|a| !a.is_file_browse())
        .map(|a| LoginResult {
            // 必须是**当前生效线路**:前端拿它直接拼封面地址,用账号主键会让切线路后
            // API 走新线、封面还打老线 —— 表现为"封面全白但不报错"。
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            user_name: a.user_name.clone(),
            primary_image_tag: None,
        })
}

#[derive(serde::Serialize)]
struct ServerGroup {
    server_id: String,
    server_name: String,
    items: Vec<Item>,
}

/// 跨所有已登录 Emby 服务器并行搜索,按服分组(单台失败隔离)。
#[tauri::command]
async fn aggregate_search(
    state: State<'_, AppState>,
    query: String,
) -> Result<Vec<ServerGroup>, String> {
    let (accounts, device_id) = {
        let cfg = state.config.lock().unwrap();
        (cfg.accounts.clone(), cfg.device_id.clone())
    };
    if query.trim().is_empty() || accounts.is_empty() {
        return Ok(vec![]);
    }
    let mut handles = Vec::new();
    for a in accounts {
        let http = state.http.clone();
        let device_id = device_id.clone();
        let query = query.clone();
        handles.push(tauri::async_runtime::spawn(async move {
            let s = Session {
                // 必须走生效线路:用账号主键会让聚合搜索永远打主线路,而用户切到备用线
                // 正是因为主线不通 —— 那台服务器会静默变成空结果从搜索里消失。
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            };
            // 跨服只出剧/电影,不出「集」(emby::search 传 None 默认会带 Episode)。
            let types = ["Movie".to_string(), "Series".to_string()];
            let items = emby::search(&http, &s, &query, Some(&types), None)
                .await
                .unwrap_or_default();
            ServerGroup {
                server_name: a.display_name(),
                server_id: a.server,
                items,
            }
        }));
    }
    let mut groups = Vec::new();
    for h in handles {
        if let Ok(g) = h.await {
            if !g.items.is_empty() {
                groups.push(g);
            }
        }
    }
    Ok(groups)
}

/// 切换活跃服务器。Emby 装 session,浏览型源装 source —— 一张表两种形态,
/// 切换必须两边都对齐,否则会留着上一个服的会话在那儿(切服失败还打错服务器)。
#[tauri::command]
fn set_active_server(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    let (account, device_id) = {
        let mut cfg = state.config.lock().unwrap();
        let idx = cfg
            .accounts
            .iter()
            .position(|a| a.server == server_id)
            .ok_or("找不到该服务器账号")?;
        cfg.active = Some(idx);
        let a = cfg.accounts[idx].clone();
        cfg.save();
        (a, cfg.device_id.clone())
    };
    if account.is_file_browse() {
        let server = account.source.clone().ok_or("该源缺少登录凭据,请重新登录")?;
        *state.source.lock().unwrap() = Some((account.source_kind, server));
        *state.session.lock().unwrap() = None;
    } else {
        *state.session.lock().unwrap() = Some(Session {
            server: account.active_line_url(),
            token: account.token,
            user_id: account.user_id,
            device_id,
        });
        *state.source.lock().unwrap() = None;
    }
    Ok(())
}

#[tauri::command]
async fn views(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::views(&state.http, &s).await
}

/// 媒体库浏览(翻页 + 排序 + 筛选)。
/// 参数全 Option:Tauri 对缺省字段反序列化成 None,前端只传 parentId 也能调。
#[tauri::command]
async fn list_items_page(
    state: State<'_, AppState>,
    parent_id: String,
    start_index: Option<u32>,
    limit: Option<u32>,
    sort_by: Option<String>,
    sort_order: Option<String>,
    genres: Option<Vec<String>>,
    tags: Option<Vec<String>>,
    years: Option<Vec<i32>>,
    studios: Option<Vec<String>>,
    rating_min: Option<f64>,
    rating_max: Option<f64>,
) -> Result<emby::ItemPage, String> {
    let s = session_of(&state)?;
    let q = emby::ItemQuery {
        start_index,
        limit,
        sort_by,
        sort_order,
        genres,
        tags,
        years,
        studios,
        rating_min,
        rating_max,
    };
    emby::items(&state.http, &s, &parent_id, &q).await
}

/// 媒体库筛选分面(类型/标签/时间/工作室/分级)。
#[tauri::command]
async fn get_filters(state: State<'_, AppState>, parent_id: String) -> Result<emby::Filters, String> {
    let s = session_of(&state)?;
    emby::filters(&state.http, &s, &parent_id).await
}

/// 标记已看/未看。
#[tauri::command]
async fn set_played(state: State<'_, AppState>, item_id: String, played: bool) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_played(&state.http, &s, &item_id, played).await
}

/// 接下来播放。
#[tauri::command]
async fn list_next_up(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::next_up(&state.http, &s, limit).await
}

/// 搜索(可指定类型/条数;默认含 Episode)。
#[tauri::command]
async fn search(
    state: State<'_, AppState>,
    query: String,
    types: Option<Vec<String>>,
    limit: Option<u32>,
) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::search(&state.http, &s, &query, types.as_deref(), limit).await
}

/// 相似推荐。空结果不是错误 —— 有些条目就是没有相似项,前端整段不渲染。
#[tauri::command]
async fn similar_items(state: State<'_, AppState>, item_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::similar(&state.http, &s, &item_id, 12).await
}

/// 首页某库"最新更新"轨道。
#[tauri::command]
async fn list_latest(
    state: State<'_, AppState>,
    parent_id: String,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::latest(&state.http, &s, &parent_id, limit).await
}

/// 继续观看。
#[tauri::command]
async fn list_resume(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::resume(&state.http, &s, limit).await
}

/// 首页 Hero 随机推荐。
#[tauri::command]
async fn list_random(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::random_picks(&state.http, &s, limit).await
}

/// 详情页:元信息 + 剧集列表。
#[tauri::command]
async fn item_detail(
    state: State<'_, AppState>,
    item_id: String,
) -> Result<emby::ItemDetail, String> {
    let s = session_of(&state)?;
    emby::detail(&state.http, &s, &item_id).await
}

/// 条目的全部版本+流(详情页「版本/音轨/字幕」选择器 + 媒体信息块)。
#[tauri::command]
async fn item_media(
    state: State<'_, AppState>,
    item_id: String,
) -> Result<Vec<emby::MediaVersion>, String> {
    let s = session_of(&state)?;
    emby::media_versions(&state.http, &s, &item_id).await
}

/// 收藏列表。
#[tauri::command]
async fn list_favorites(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::favorites(&state.http, &s).await
}

/// 切换收藏。
#[tauri::command]
async fn set_favorite(state: State<'_, AppState>, item_id: String, fav: bool) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_favorite(&state.http, &s, &item_id, fav).await
}

/* ============================================================
   服务器页 —— 账号表 / 线路
   ============================================================ */

/// 服务器连通状态。三态:绿=正常 / 黄=需重登 / 灰=未连。
/// `Unknown` 是「还没探过」,与"探过了确实不通"同色不同义 —— 别在 Rust 侧合并成一个,
/// 合并了就没法区分"没测"和"测了挂了"。
#[derive(serde::Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum AccountStatus {
    Ok,
    Reauth,
    Down,
    Unknown,
}

/// 服务器页:服务器列表(Emby + 浏览型源,统一一张表)。
#[derive(serde::Serialize)]
struct AccountInfo {
    server: String,
    user_name: String,
    user_id: String,
    /// 是否当前选中的服务器。**不是**连通状态 —— 状态看 `status`。
    active: bool,
    status: AccountStatus,
    name: String,
    remark: Option<String>,
    icon_url: Option<String>,
    lines: Vec<linplayer_core::config::ServerLine>,
    active_line: usize,
    /// 当前生效的上游线路地址(未经 CF 反代改写)。
    line_url: String,
    allow_insecure_tls: bool,
    source_kind: SourceKind,
    /// 是否文件浏览型源(非 Emby)——前端据此决定进媒体库还是进文件浏览。
    is_file_browse: bool,
}

fn account_info_with(
    a: &linplayer_core::Account,
    active: bool,
    status: AccountStatus,
) -> AccountInfo {
    AccountInfo {
        server: a.server.clone(),
        user_name: a.user_name.clone(),
        user_id: a.user_id.clone(),
        active,
        status,
        name: a.display_name(),
        remark: a.remark.clone(),
        icon_url: a.icon_url.clone(),
        lines: a.lines.clone(),
        active_line: a.active_line,
        line_url: a.direct_line_url().to_string(),
        allow_insecure_tls: a.allow_insecure_tls,
        source_kind: a.source_kind,
        is_file_browse: a.is_file_browse(),
    }
}

#[tauri::command]
fn list_accounts(state: State<'_, AppState>) -> Vec<AccountInfo> {
    let cfg = state.config.lock().unwrap();
    let active = cfg.active;
    let statuses = state.account_status.lock().unwrap();
    cfg.accounts
        .iter()
        .enumerate()
        .map(|(i, a)| {
            let st = statuses.get(&a.server).copied().unwrap_or(AccountStatus::Unknown);
            account_info_with(a, Some(i) == active, st)
        })
        .collect()
}

/// 单台探测。**必须走 active_line_url()** —— 用户切了备用线路正是因为主线不通,
/// 拿主线去探会把一台好服务器判成灰,而用户看到的又是"我明明能用"。
async fn probe_account(http: &reqwest::Client, a: &linplayer_core::Account) -> AccountStatus {
    let base = a.active_line_url();
    let base = base.trim_end_matches('/');
    if a.is_file_browse() {
        // 浏览型源没有统一的鉴权探测端点,只判连通,所以只会给出绿/灰两态。
        return match http.get(base).send().await {
            Ok(_) => AccountStatus::Ok,
            Err(_) => AccountStatus::Down,
        };
    }
    // 用 /System/Info(需鉴权)而不是 /System/Info/Public:后者 token 失效也回 200,
    // 那样"需重登"永远探不出来,黄灯就成了摆设。
    let url = format!("{base}/System/Info?api_key={}", a.token);
    match http.get(&url).send().await {
        Ok(r) if r.status().is_success() => AccountStatus::Ok,
        Ok(r) if matches!(r.status().as_u16(), 401 | 403) => AccountStatus::Reauth,
        Ok(_) => AccountStatus::Down,
        Err(_) => AccountStatus::Down,
    }
}

/// 探测所有服务器的连通状态,刷新缓存并返回新的列表。
/// 并发探测:一台慢的不该拖住整页(串行 N 台 × 超时 = 页面空一分钟)。
#[tauri::command]
async fn probe_accounts(state: State<'_, AppState>) -> Result<Vec<AccountInfo>, String> {
    let accounts = state.config.lock().unwrap().accounts.clone();
    let mut handles = Vec::new();
    for a in accounts {
        let http = state.http.clone();
        handles.push(tauri::async_runtime::spawn(async move {
            let status = probe_account(&http, &a).await;
            (a.server.clone(), status)
        }));
    }
    for h in handles {
        if let Ok((server, status)) = h.await {
            state.account_status.lock().unwrap().insert(server, status);
        }
    }
    Ok(list_accounts(state))
}

#[derive(serde::Serialize)]
struct LineProbe {
    index: usize,
    url: String,
    ms: Option<u64>,
}

/// 线路 URL 表。空 lines 回落成「server 本身算一条线」—— 前端渲染行数必须与此一致。
fn line_urls(state: &State<'_, AppState>, server_id: &str) -> Result<Vec<String>, String> {
    let cfg = state.config.lock().unwrap();
    let a = cfg.find(server_id).ok_or("找不到该服务器")?;
    Ok(if a.lines.is_empty() {
        vec![a.server.clone()]
    } else {
        a.lines.iter().map(|l| l.url.clone()).collect()
    })
}

/// 单条线路测速。通 = Some(毫秒),不通/超时 = None。
async fn probe_one(http: &reqwest::Client, url: &str) -> Option<u64> {
    let probe = format!("{}/System/Info/Public", url.trim_end_matches('/'));
    let t0 = std::time::Instant::now();
    let ok = tokio::time::timeout(std::time::Duration::from_secs(6), http.get(&probe).send())
        .await
        .ok()
        .and_then(|r| r.ok())
        .map(|r| r.status().is_success())
        .unwrap_or(false);
    ok.then(|| t0.elapsed().as_millis() as u64)
}

/// 只探**一条**线路:先出线路表、再逐条填延迟。
/// 整表并发探的做法要等最慢那条,一条死线就把整个面板扣住,用户连切到能用的线路都做不到。
#[tauri::command]
async fn probe_line(
    state: State<'_, AppState>,
    server_id: String,
    index: usize,
) -> Result<LineProbe, String> {
    let urls = line_urls(&state, &server_id)?;
    let url = urls.get(index).ok_or("线路下标越界")?.clone();
    let ms = probe_one(&state.http, &url).await;
    Ok(LineProbe { index, url, ms })
}

/// 删除某账号;若删的是活跃账号,回落到第一个(无账号则清空会话)。
/// 删本地前尽力通知服务端登出,失败不影响本地删除(实测有的服 /Sessions/Logout 直接 404)。
#[tauri::command]
async fn remove_account(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    {
        let sess = {
            let cfg = state.config.lock().unwrap();
            cfg.accounts
                .iter()
                .find(|a| a.server == server_id)
                .map(|a| Session {
                    server: a.active_line_url(),
                    token: a.token.clone(),
                    user_id: a.user_id.clone(),
                    device_id: cfg.device_id.clone(),
                })
        };
        if let Some(s) = sess {
            let _ = emby::logout(&state.http, &s).await;
        }
    }
    let new_session = {
        let mut cfg = state.config.lock().unwrap();
        if !cfg.remove(&server_id) {
            return Err("找不到该账号".into());
        }
        cfg.save();
        let device_id = cfg.device_id.clone();
        // 回落后的活跃账号若是浏览型源,它没有 Emby 会话 —— 别硬造一个假的。
        cfg.active_account()
            .filter(|a| !a.is_file_browse())
            .map(|a| Session {
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            })
    };
    *state.session.lock().unwrap() = new_session;
    Ok(())
}

/// 服务器列表拖拽排序。
#[tauri::command]
fn reorder_accounts(state: State<'_, AppState>, from: usize, to: usize) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.reorder(from, to)?;
    cfg.save();
    Ok(())
}

/// 覆写某服务器的备用线路表。
#[tauri::command]
fn set_lines(
    state: State<'_, AppState>,
    server_id: String,
    lines: Vec<linplayer_core::config::ServerLine>,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    // 线路变少时把选中项钳回合法区间,别留悬空下标。
    if !lines.is_empty() && a.active_line >= lines.len() {
        a.active_line = lines.len() - 1;
    }
    a.lines = lines;
    cfg.save();
    Ok(())
}

/// 切换生效线路;若切的是当前活跃服务器,同步刷新会话让后续请求立刻走新线路。
#[tauri::command]
fn set_active_line(
    state: State<'_, AppState>,
    server_id: String,
    index: usize,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    if !a.lines.is_empty() && index >= a.lines.len() {
        return Err("线路下标越界".into());
    }
    a.active_line = index;
    cfg.save();
    let is_active = cfg.active_account().map(|x| x.server == server_id).unwrap_or(false);
    if is_active {
        if let Some(s) = state.session.lock().unwrap().as_mut() {
            s.server = cfg.find(&server_id).unwrap().active_line_url();
        }
    }
    Ok(())
}

/// 「同步线路」的结果。`supported=false` 时 UI 该说「这台服务器没提供线路表」,不是报错。
#[derive(serde::Serialize)]
struct SyncedLines {
    supported: bool,
    added: usize,
    total: usize,
}

/// 同步线路:从服主部署的 emby_ext_domains 拉取备用域名,并入本地线路表。
///
/// **只增不删,按 url 去重**:用户手填的线路(内网地址)服主表里不可能有,整表覆写等于
/// 把用户配置删了 —— 而他多半是在「当前线路连不上」时点的同步,那一刻删掉他仅有的能用
/// 线路是灾难。active_line 是**下标**不是 id,插行会让它指到别的线路上,所以合并后要按
/// 原 url 找回下标(core::merge_lines 负责,那边有测试钉)。
#[tauri::command]
async fn sync_lines(state: State<'_, AppState>, server_id: String) -> Result<SyncedLines, String> {
    // ★ 锁不能跨 await(见 [[prefetch-proxy-deadlock]]):先取完数据立刻放锁。
    let sess = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        if a.is_file_browse() {
            return Err("网盘/聚合源没有线路表".into());
        }
        Session {
            server: a.direct_line_url().to_string(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            device_id: cfg.device_id.clone(),
        }
    };
    let remote = emby::ext_domains(&state.http, &sess).await?;
    if remote.is_empty() {
        let total = {
            let cfg = state.config.lock().unwrap();
            cfg.find(&server_id).map(|a| a.lines.len()).unwrap_or(0)
        };
        return Ok(SyncedLines { supported: false, added: 0, total });
    }

    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    let added = linplayer_core::config::merge_lines(a, &remote);
    let total = a.lines.len();
    cfg.save();
    Ok(SyncedLines { supported: true, added, total })
}

/// 取服务器图标(data URI)。首次调用会下载并缓存,之后直接读缓存。
/// 取不到返回 Err —— 由前端回退内置图标,别在这儿吞成空串让 UI 显示碎图。
#[tauri::command]
async fn account_icon(state: State<'_, AppState>, server_id: String) -> Result<String, String> {
    let url = {
        let cfg = state.config.lock().unwrap();
        cfg.find(&server_id).and_then(|a| a.icon_url.clone())
    };
    // 服务器图标是用户填的任意外链,不是 Emby → 默认 UA。
    linplayer_core::icon_cache::get(&http::client(), &server_id, url.as_deref()).await
}

/* ============================================================
   文件浏览型源
   ============================================================ */

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

/* ============================================================
   设置 / 数据目录 / 更新
   ============================================================ */

/// 数据根 + 各子目录的真实绝对路径,直接给设置页显示。存在的意义就是**别让用户猜**。
#[derive(serde::Serialize)]
struct DataPaths {
    root: String,
    config: String,
    data: String,
    cache: String,
    temp: String,
    webview: String,
    logs: String,
    downloads: String,
    kind: linplayer_core::paths::RootKind,
    exe_dir: String,
}

#[tauri::command]
fn data_paths() -> DataPaths {
    use linplayer_core::paths as p;
    let s = |x: std::path::PathBuf| x.to_string_lossy().into_owned();
    DataPaths {
        root: s(p::root()),
        config: s(p::config_file()),
        data: s(p::data_root()),
        cache: s(p::cache_root()),
        temp: s(p::temp_dir()),
        webview: s(p::webview_dir()),
        logs: s(p::logs_dir()),
        downloads: s(p::downloads_dir()),
        kind: p::root_kind(),
        // 安卓上 current_exe() 指向 /system/bin/app_process(zygote),对用户毫无意义,
        // 但也不该编造 —— 如实给,UI 那栏本来就是"包在哪儿"的诊断信息。
        exe_dir: std::env::current_exe()
            .ok()
            .and_then(|e| e.parent().map(|d| s(d.to_path_buf())))
            .unwrap_or_default(),
    }
}

/// 缓存占用字节数。**同步递归遍历目录**,缓存大时会卡几百毫秒 —— 丢去阻塞线程池,别堵住 UI。
#[tauri::command]
async fn cache_size() -> Result<u64, String> {
    tauri::async_runtime::spawn_blocking(linplayer_core::paths::cache_size)
        .await
        .map_err(|e| format!("统计缓存失败: {e}"))
}

/// 清空缓存。只动 cache/,config/data/downloads 一根汗毛都不碰。
#[tauri::command]
async fn clear_cache() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(|| {
        linplayer_core::paths::clear_cache()?;
        // 内存层必须一起清:只删磁盘的话内存里那份还在继续供图,
        // 用户看着占用变 0、封面却还是旧的 —— 那不叫清理,叫骗人。
        linplayer_core::image_cache::mem_clear();
        Ok(())
    })
    .await
    .map_err(|e| format!("清理缓存失败: {e}"))?
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
    // 只改选轨三项。别整体覆盖 —— 那会把 cross_server_resume 悄悄重置成默认值
    // (用户改个字幕语言,跨服续播就被关了)。
    cfg.prefs = Prefs { audio_lang, sub_lang, sub_enabled, ..cfg.prefs.clone() };
    cfg.save();
    Ok(())
}

/// 播放器默认行为(设置页「播放器」区)。
#[derive(serde::Serialize, serde::Deserialize)]
struct PlaybackPrefs {
    /// "auto-safe"(硬解) | "no"(软解)
    hwdec: String,
    default_speed: f64,
    skip_intro: bool,
    skip_outro: bool,
    preview_thumbs: bool,
    dolby_auto_sw: bool,
    external_player: String,
}

#[tauri::command]
fn get_playback_prefs(state: State<'_, AppState>) -> PlaybackPrefs {
    let p = &state.config.lock().unwrap().prefs;
    PlaybackPrefs {
        hwdec: p.hwdec.clone(),
        default_speed: p.default_speed,
        skip_intro: p.skip_intro,
        skip_outro: p.skip_outro,
        preview_thumbs: p.preview_thumbs,
        dolby_auto_sw: p.dolby_auto_sw,
        external_player: p.external_player.clone(),
    }
}

#[tauri::command]
fn set_playback_prefs(state: State<'_, AppState>, settings: PlaybackPrefs) -> Result<(), String> {
    // 拒而不是夹:静默夹紧 = 用户以为设上了。
    if !matches!(settings.hwdec.as_str(), "auto-safe" | "no") {
        return Err(format!("未知的解码方式: {}", settings.hwdec));
    }
    if !(linplayer_core::config::SPEED_MIN..=linplayer_core::config::SPEED_MAX)
        .contains(&settings.default_speed)
    {
        return Err(format!(
            "默认倍速只支持 {:.2}~{:.2}×",
            linplayer_core::config::SPEED_MIN,
            linplayer_core::config::SPEED_MAX
        ));
    }
    /* ★ 桌面版在这里校验「外部播放器路径必须是个存在的文件」。安卓**不校验**:
       那边根本没有「给出一个 exe 路径」这回事(要拉起别的播放器得走 Intent),
       沿用 is_file() 只会把用户填的任何东西一律判错。字段照存不动,留着两端结构一致。 */
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.hwdec = settings.hwdec;
    cfg.prefs.default_speed = settings.default_speed;
    cfg.prefs.skip_intro = settings.skip_intro;
    cfg.prefs.skip_outro = settings.skip_outro;
    cfg.prefs.preview_thumbs = settings.preview_thumbs;
    cfg.prefs.dolby_auto_sw = settings.dolby_auto_sw;
    cfg.prefs.external_player = settings.external_player.trim().to_string();
    cfg.save();
    Ok(())
}

/// 跨服务器续播开关(设置页)。
#[tauri::command]
fn get_cross_server_resume(state: State<'_, AppState>) -> bool {
    state.config.lock().unwrap().prefs.cross_server_resume
}

#[tauri::command]
fn set_cross_server_resume(state: State<'_, AppState>, enabled: bool) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.cross_server_resume = enabled;
    cfg.save();
    Ok(())
}

#[derive(serde::Serialize)]
struct UpdateSettings {
    channel: linplayer_core::update::UpdateChannel,
    auto_check: bool,
    /// 当前版本(tauri.conf.json 的 version,由 build.rs 注入)。**比较用它**。
    current_version: String,
    /// 能不能就地自更新。安卓上恒为 false —— APK 的替换必须走系统安装器,
    /// 应用自己覆盖不了自己的 apk。UI 据此只提示「去下载」,不给「一键更新」。
    can_self_update: bool,
}

#[tauri::command]
fn get_update_settings(state: State<'_, AppState>) -> UpdateSettings {
    let cfg = state.config.lock().unwrap();
    UpdateSettings {
        channel: cfg.prefs.update_channel,
        auto_check: cfg.prefs.update_auto_check,
        current_version: env!("LP_VERSION").to_string(),
        can_self_update: false,
    }
}

#[tauri::command]
fn set_update_settings(
    state: State<'_, AppState>,
    channel: linplayer_core::update::UpdateChannel,
    auto_check: bool,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    // 逐字段改,别整体覆盖 Prefs —— 见 set_prefs 上的说明。
    cfg.prefs.update_channel = channel;
    cfg.prefs.update_auto_check = auto_check;
    cfg.save();
    Ok(())
}

/// 查更新。`Ok(None)` = 确实已是最新;`Err` = 没查成(断网/限流)。
/// 两者必须分开:把「查不动」显示成「已是最新」是在骗用户。
#[tauri::command]
async fn check_update(
    state: State<'_, AppState>,
) -> Result<Option<linplayer_core::update::UpdateInfo>, String> {
    let channel = state.config.lock().unwrap().prefs.update_channel;
    let found = linplayer_core::update::check(channel, env!("LP_VERSION")).await?;
    *state.pending_update.lock().unwrap() = found.clone();
    Ok(found)
}

/* ============================================================
   下载
   ============================================================ */

/// 入队下载:走 Emby /Items/{id}/Download(服务端按下载权限放行),返回任务 id。
#[tauri::command]
fn download_enqueue(
    state: State<'_, AppState>,
    item_id: String,
    type_: String,
    title: String,
    container: String,
    poster_url: Option<String>,
) -> Result<String, String> {
    let s = session_of(&state)?;
    let url = format!(
        "{}/Items/{}/Download?api_key={}",
        s.server.trim_end_matches('/'),
        item_id,
        s.token
    );
    let c = if container.trim().is_empty() { "mkv".into() } else { container };
    let item =
        linplayer_core::download::DownloadItem::new(item_id, type_, title, c, url, poster_url);
    Ok(state.download.enqueue(item))
}

#[tauri::command]
fn download_list(state: State<'_, AppState>) -> Vec<linplayer_core::download::DownloadItem> {
    state.download.list()
}

#[tauri::command]
fn download_pause(state: State<'_, AppState>, id: String) {
    state.download.pause(&id);
}

#[tauri::command]
fn download_remove(state: State<'_, AppState>, id: String) {
    state.download.remove(&id);
}

#[tauri::command]
fn download_resume(state: State<'_, AppState>, id: String) {
    state.download.resume(&id);
}

#[tauri::command]
fn download_set_threads(state: State<'_, AppState>, threads: usize) {
    state.download.set_threads(threads);
}

/// 批量清除已完成的下载记录。返回清掉的条数。
/// 只清记录,不删已下好的文件 —— 用户点「清除已完成」是想收拾列表,不是想丢文件。
#[tauri::command]
fn download_clear_completed(state: State<'_, AppState>) -> usize {
    let done: Vec<String> = state
        .download
        .list()
        .into_iter()
        .filter(|i| i.status == linplayer_core::download::DownloadStatus::Completed)
        .map(|i| i.id)
        .collect();
    let mut n = 0;
    for id in done {
        // forget 而非 remove:remove 会 delete_files 把已下好的片子删掉,与本命令的契约相反。
        if state.download.forget(&id) {
            n += 1;
        }
    }
    n
}

/* ============================================================
   排行榜 / 追剧日历
   ============================================================ */

/// 当前构建可用的榜单分类(动漫需弹弹凭据、影视需 TMDB 密钥,均编译期注入)。
#[tauri::command]
fn ranking_categories() -> Vec<linplayer_core::ranking::RankingCategory> {
    linplayer_core::ranking::available_categories()
}

/// 拉取某分类榜单(默认命中 6h 缓存)。
#[tauri::command]
async fn ranking_fetch(
    category_id: String,
    force_refresh: Option<bool>,
) -> Result<Vec<linplayer_core::ranking::RankingEntry>, String> {
    Ok(linplayer_core::ranking::fetch(&category_id, force_refresh.unwrap_or(false)).await)
}

/// 当前已连接的 Trakt 账号(None=未连接)。
#[tauri::command]
fn trakt_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_trakt.clone()
}

/// 追剧日历(only_mine=只看我追的)。未连接返回空。
#[tauri::command]
async fn trakt_calendar(
    state: State<'_, AppState>,
    only_mine: Option<bool>,
) -> Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String> {
    let acc = state.config.lock().unwrap().sync_trakt.clone();
    let Some(acc) = acc else { return Ok(vec![]) };
    Ok(trakt::fetch_shows_calendar(&acc, 3, 21, only_mine.unwrap_or(true)).await)
}

#[tauri::command]
fn bangumi_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_bangumi.clone()
}

#[tauri::command]
async fn bangumi_calendar(
    state: State<'_, AppState>,
    only_mine: Option<bool>,
) -> Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String> {
    let only_mine = only_mine.unwrap_or(true);
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    // 未登录时:个性化「我追的」拉不了(空);通用放送表 /calendar 是公开端点,用匿名账号照拉。
    match acc {
        Some(a) => Ok(bangumi::fetch_anime_calendar(&a, only_mine).await),
        None if !only_mine => {
            let anon = linplayer_core::sync::SyncAccount {
                service: "bangumi".into(),
                access_token: String::new(),
                refresh_token: None,
                expires_at: None,
                username: None,
                user_id: None,
            };
            Ok(bangumi::fetch_anime_calendar(&anon, false).await)
        }
        None => Ok(vec![]),
    }
}

/* ============================================================
   入口
   ============================================================ */

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = imgcache::register(tauri::Builder::default());
    builder
        .setup(|app| {
            /* ★ 这里的顺序是有讲究的,别挪。
               安卓没有 XDG/AppData,更没有「exe 同级 userdata/」—— `paths::root()` 的默认
               解析在安卓上会落到一个进程无权写的地方。所以必须由宿主显式喂沙盒目录,
               而 `set_root` **只在 root() 被第一次调用之前有效**(设晚了直接 Err,免得
               一半模块用旧根一半用新根)。
               `AppConfig::load()` 会读 config 路径 = 会触发 root() —— 所以 set_root 必须
               排在它前面,而拿到沙盒目录又必须有 AppHandle,于是整块搬进 setup。
               (桌面壳能在 run() 顶部就把状态建好,是因为它的根不依赖 AppHandle。) */
            #[cfg(target_os = "android")]
            {
                let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
                std::fs::create_dir_all(&dir)?;
                // 已被用过就说明有人抢跑了,如实报错而不是继续跑一个数据分裂的 App。
                linplayer_core::paths::set_root(dir).map_err(std::io::Error::other)?;
            }

            let config = AppConfig::load();
            // 先把代理写进全局,再建各 HTTP 客户端,使其启动即带代理。
            http::set_proxy(config.proxy.proxy_url());
            let http = http::emby_client();

            // 源后端注册表(长驻,持各自 token 缓存)。
            let mut source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>> =
                HashMap::new();
            source_backends.insert(SourceKind::Openlist, Arc::new(OpenListBackend::new()));
            source_backends.insert(SourceKind::Anirss, Arc::new(AniRssBackend::new()));
            source_backends.insert(SourceKind::Feiniu, Arc::new(FeiniuBackend::new()));
            source_backends.insert(SourceKind::Quark, Arc::new(QuarkBackend::new()));

            // 有活跃账号 -> 用存盘凭据重建会话/源(重启免登)。Emby 与浏览型源互斥。
            let active = config.active_account();
            let session = active.filter(|a| !a.is_file_browse()).map(|a| Session {
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id: config.device_id.clone(),
            });
            let source = active
                .filter(|a| a.is_file_browse())
                .and_then(|a| a.source.clone().map(|s| (a.source_kind, s)));

            let download = tauri::async_runtime::block_on(
                linplayer_core::download::DownloadManager::new(
                    linplayer_core::paths::downloads_dir(),
                ),
            );

            app.manage(AppState {
                http,
                config: Mutex::new(config),
                session: Mutex::new(session),
                source_backends,
                source: Mutex::new(source),
                download,
                account_status: Mutex::new(HashMap::new()),
                pending_update: Mutex::new(None),
            });
            /* 播放器状态单独一份 State:它的生命周期和 Surface 绑,不跟 AppState 一起建。 */
            app.manage(PlayerState::default());
            /* mpv 提成共享 crate 后自带的日志出口是空的,把安卓这边的接进去,
               否则它那些「静默失效」告警(如 shader 缓存没设上)全被丢掉。 */
            linplayer_mpv::set_logger(|m| log::info!("[mpv] {m}"));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // --- Emby 浏览 ---
            login,
            current_session,
            aggregate_search,
            set_active_server,
            views,
            list_items_page,
            get_filters,
            set_played,
            list_next_up,
            search,
            similar_items,
            list_latest,
            list_resume,
            list_random,
            item_detail,
            item_media,
            list_favorites,
            set_favorite,
            // --- 服务器 / 线路 ---
            list_accounts,
            probe_accounts,
            probe_line,
            remove_account,
            reorder_accounts,
            set_lines,
            set_active_line,
            sync_lines,
            account_icon,
            // --- 源 ---
            source_list_dir,
            // --- 设置 / 数据 / 更新 ---
            data_paths,
            cache_size,
            clear_cache,
            get_prefs,
            set_prefs,
            get_playback_prefs,
            set_playback_prefs,
            get_cross_server_resume,
            set_cross_server_resume,
            get_update_settings,
            set_update_settings,
            check_update,
            // --- 下载 ---
            download_enqueue,
            download_list,
            download_pause,
            download_remove,
            download_resume,
            download_set_threads,
            download_clear_completed,
            // --- 排行 / 日历 ---
            ranking_categories,
            ranking_fetch,
            trakt_account,
            trakt_calendar,
            bangumi_account,
            bangumi_calendar,
            // --- 播放器(桩:缺 libmpv .so,调用即报错,详见文件头)---
            play,
            play_local,
            source_play,
            seek,
            set_pause,
            set_track,
            status,
            tracks,
            stop_playback,
            report_progress,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    /// TV 前端 `ui/tv` 会调的命令,一个都不能漏注册 —— 漏了**不会编译报错**,
    /// 只在用户走到那个页面时抛 "command not found"。这条把 ui/tv(含它 import 的
    /// ui/shared/api.ts)里出现的 invoke 名和本文件的注册表对一遍。
    ///
    /// 反向验证:把 generate_handler! 里任意一行注释掉,此测试立刻红(已实测)。
    #[test]
    fn every_tv_invoke_names_a_registered_command() {
        let me = include_str!("lib.rs");
        let handlers = me
            .split_once("generate_handler![")
            .expect("找不到 generate_handler!")
            .1
            .split_once("])")
            .expect("generate_handler! 没有收尾")
            .0;
        let registered: Vec<&str> = handlers
            .lines()
            .map(|l| l.trim().trim_end_matches(','))
            .filter(|s| !s.is_empty() && !s.starts_with("//"))
            .collect();

        // api.ts 是 TV 页面唯一的命令出口(ui/tv 不直接 invoke)。
        let api_ts = include_str!("../../../ui/shared/api.ts");
        let mut names: Vec<&str> = Vec::new();
        for (i, _) in api_ts.match_indices("invoke") {
            let rest = &api_ts[i + "invoke".len()..];
            let Some(lp) = rest.find('(') else { continue };
            if rest[..lp].contains(';') || rest[..lp].contains('\n') {
                continue; // 不是调用(import / 注释里的 invoke 字样)
            }
            let after = rest[lp + 1..].trim_start();
            let Some(q) = after.strip_prefix('"') else { continue };
            let Some(end) = q.find('"') else { continue };
            names.push(&q[..end]);
        }
        assert!(names.len() > 50, "只抠出 {} 个 invoke,解析多半坏了", names.len());

        // api.ts 是三端共用的,里面有大量 PC 专属命令(mpv 系、whisper 系、插件系)。
        // TV 壳按需注册,所以这里只校验**清单内**的那批,而不是全表。
        // 清单来自 ui/tv 的真实 import 反推(见 apps/android/README.md)。
        let tv_cmds = include_str!("../tv-commands.txt");
        for cmd in tv_cmds.lines().map(str::trim).filter(|l| !l.is_empty()) {
            assert!(
                registered.contains(&cmd),
                "TV 命令清单里的 `{cmd}` 没在 generate_handler! 注册 —— \
                 用户走到那个页面就报 command not found"
            );
            assert!(
                names.contains(&cmd),
                "`{cmd}` 在 TV 清单里,但 ui/shared/api.ts 里没有对应的 invoke —— \
                 清单和前端漂移了,先查是不是前端改了命令名"
            );
        }
    }
}

/* ============================================================
   JNI:Java 层的 SurfaceView ←→ mpv 的渲染面
   ============================================================ */

/* 由 MainActivity 的 SurfaceHolder.Callback 调用。见那边的注释。

   ★ 必须 NewGlobalRef。传进来的 jobject 是**局部引用**,这次 native 调用一返回就失效;
     而 mpv 是在之后某个时刻(Player::new → mpv_initialize)才拿它去
     ANativeWindow_fromSurface。用局部引用的表现不是「不工作」,是**在一个和这里
     毫无关系的地方崩溃**,极难反查。

   ★ 旧的全局引用要显式 DeleteGlobalRef,否则每次转屏/回前台都漏一个 Surface。 */
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_xyz_linplayer_tv_MainActivity_nativeSetSurface(
    env: jni::JNIEnv,
    _this: jni::objects::JObject, // 实例方法 → 第二个参数是 this,不是 jclass
    surface: jni::objects::JObject,
) {
    /* 全局引用存这里。**用 GlobalRef 而不是裸 jobject**:它的 Drop 会自己
       DeleteGlobalRef,换面/退出时不会漏 Surface。手工管裸指针的版本写过一版,
       jni 0.21 根本没有 delete_global_ref 这个方法(交叉编译时才报出来 ——
       宿主 cargo check 编不到 cfg(android) 这段代码,查这类错只能真交叉编)。 */
    static CUR: std::sync::Mutex<Option<jni::objects::GlobalRef>> = std::sync::Mutex::new(None);

    let g = if surface.is_null() {
        None
    } else {
        match env.new_global_ref(&surface) {
            Ok(g) => Some(g),
            Err(e) => {
                log::error!("[mpv] NewGlobalRef 失败,视频将没有渲染面: {e}");
                None
            }
        }
    };

    /* ★ 顺手把 JavaVM 登记给 libmpv —— 这个 libmpv 没有导出 JNI_OnLoad,
       不登记就是「一切成功但黑屏」。理由和实测见 crates/mpv 的 set_android_java_vm。
       挂在这里是因为这是**唯一**天然带 JNIEnv 又必定早于起播的入口。
       重复调无害(ffmpeg 侧是幂等的设值)。 */
    match env.get_java_vm() {
        Ok(vm) => linplayer_mpv::set_android_java_vm(vm.get_java_vm_pointer() as *mut _),
        Err(e) => log::error!("[mpv] 取 JavaVM 失败,硬解/渲染会起不来: {e}"),
    }

    let ptr = g.as_ref().map(|g| g.as_raw() as isize).unwrap_or(0);
    // 先把新的存住再交给 mpv;旧的在这一行被 drop → 自动 DeleteGlobalRef。
    *CUR.lock().unwrap() = g;
    linplayer_mpv::set_android_surface(ptr);
}
