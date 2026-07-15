mod mpv;
mod plugins_host;
mod shaders;

use linplayer_core::config::{Account, AppConfig, DanmakuServer, Prefs};
use linplayer_core::plugins::PluginManager;
use linplayer_core::danmaku::{self, DanmakuAuthType, DanmakuComment, DanmakuSourceConfig};
use linplayer_core::emby::{self, Item, LoginResult, PlaybackTarget, Session};
use linplayer_core::http;
use linplayer_core::media::{pick_tracks, Track};
use linplayer_core::net::cf;
use linplayer_core::source::anirss::AniRssBackend;
use linplayer_core::source::feiniu::FeiniuBackend;
use linplayer_core::source::openlist::OpenListBackend;
use linplayer_core::source::quark::QuarkBackend;
use linplayer_core::source::quark_tv;
use linplayer_core::source::{MediaSourceBackend, SourceEntry, SourceKind, SourceServer};
use mpv::{Player, Status};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tauri::{Manager, State, WindowEvent};
use tokio::sync::oneshot;

struct AppState {
    http: reqwest::Client,
    config: Mutex<AppConfig>,
    session: Mutex<Option<Session>>,
    player: Mutex<Option<Player>>,
    playback: Mutex<Option<PlaybackTarget>>, // 当前播放会话(上报三件套共享)
    // 文件浏览型源:后端注册表(长驻,持 token 缓存)+ 当前活跃源
    source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>>,
    source: Mutex<Option<(SourceKind, SourceServer)>>,
    // Ani-RSS 管理接口(listAni/config/…)不在 MediaSourceBackend trait 上,trait object 取不到,
    // 故另存具体类型。**与 source_backends[Anirss] 是同一个 Arc**(建时 clone 后 unsize 成 dyn),
    // 两边共享同一份 token_cache —— 浏览重登拿到的 token 管理接口直接复用,不会分裂成两套。
    anirss: Arc<AniRssBackend>,
    // 当前正在播放的源条目(entry_id, entry_name),供 302 重签重解析;None=非源播放
    source_play_entry: Mutex<Option<(String, String)>>,
    // 连续 302 重签次数(防死循环:文件本身放不了时不无限重签),每次新播放清零
    resign_count: AtomicU32,
    // 多线程加载:本地预取代理句柄(仅 Emby 直传流);Drop 即停服。None=直连。
    prefetch: Mutex<Option<linplayer_core::net::prefetch::ProxyHandle>>,
    // CF 优选:server_id -> 本地钉 IP 反代句柄;移除即 Drop 停服。
    // 与 cf::runtime 的路由改写表一一对应(那边是纯改写,这边持句柄),开关必须两边同步。
    cf_proxy: Mutex<HashMap<String, linplayer_core::net::cf::CfProxyHandle>>,
    // 多线程下载管理器(长驻,持久化索引)。
    download: linplayer_core::download::DownloadManager,
    // 当前 Emby 播放的 Trakt scrobble 上下文(play 时抓取,stop 时用于收尾上报)。
    scrobble_ctx: Mutex<Option<emby::ScrobbleInfo>>,
    // 本地观看记录(跨服务器续播)。长驻,自持存盘。
    watch_history: linplayer_core::watch_history::WatchHistory,
    // 剧 -> TMDB id 缓存(跨服匹配剧集要它;每部剧只查一次)。对齐 Dart _seriesTmdbCache。
    series_tmdb: Mutex<HashMap<String, Option<String>>>,
    // server_id -> 连通状态三态。probe_accounts 刷新,list_accounts 读;不落盘(重启即重探)。
    account_status: Mutex<HashMap<String, AccountStatus>>,
    // 自动挂弹幕的连号锚点:seriesId|seasonId -> (集号, 弹弹Play episodeId)。
    // 只在内存(重启重新匹配一次即可,不值得落盘)。
    danmaku_anchors: Mutex<HashMap<String, (i64, i64)>>,
    // 实时预读翻译:轮询任务的停止信号。None=没开。
    live_translate: Mutex<Option<LiveTranslate>>,
    // 跨服回传去重集(对齐 Dart _done:一次播放会话内不重复回传同一目标)。play 时清空。
    wh_done: Mutex<std::collections::HashSet<String>>,
    // 当前播放条目的观看记录上下文(play 时装,progress/stop 时用)。
    wh_ctx: Mutex<Option<(String, linplayer_core::watch_history::Candidate, Option<String>)>>,
    // 插件管理器(setup 期建,持 AppHandle 的 host)。
    plugins: OnceLock<Arc<PluginManager>>,
    // 插件 ctx.ui 请求的待回表:id -> oneshot,前端 plugin_ui_respond 回填。
    ui_pending: Mutex<HashMap<u64, oneshot::Sender<serde_json::Value>>>,
    ui_seq: AtomicU64,
}

fn plugins_mgr(state: &AppState) -> Result<Arc<PluginManager>, String> {
    state.plugins.get().cloned().ok_or_else(|| "插件系统未就绪".to_string())
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
    // 持久化账号 -> 重启免登。upsert 会保住用户编辑过的名称/备注/线路,不会被重登冲掉。
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.upsert(Account {
            server: result.server.clone(),
            token: result.token.clone(),
            user_id: result.user_id.clone(),
            user_name: result.user_name.clone(),
            // 存密码供重新登录 + 插件 emby.credentials 权限(对齐旧 Dart ServerConfig.password)。
            password: (!password.is_empty()).then_some(password),
            ..Default::default()
        });
        cfg.save();
    }
    *state.session.lock().unwrap() = Some(session);
    *state.source.lock().unwrap() = None; // 登 Emby → 上一个源作废
    Ok(result)
}

/// 已登录的 Emby 账号(用于启动时跳过登录页直接进库);无则 None。
/// 活跃的是浏览型源时返回 None —— 它没有 Emby token,吐个空 token 的会话会让前端拿去打 401。
/// 前端判断"要不要进登录页"应看 `list_accounts` 是否为空,不是只看这个。
#[tauri::command]
fn current_session(state: State<'_, AppState>) -> Option<LoginResult> {
    state
        .config
        .lock()
        .unwrap()
        .active_account()
        .filter(|a| !a.is_file_browse())
        .map(|a| LoginResult {
            // 前端 api.ts 拿这个 server 直接拼封面/背景图地址,所以必须是**当前生效线路**
            // (经 CF 优选改写),不能是账号主键 a.server ——
            // 否则用户切到备用线路后 API 走新线、封面还打老线,表现为"封面全白但不报错"。
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            user_name: a.user_name.clone(),
            // 头像 tag 只在登录那一刻有意义(用来建服务器图标,已存进 Account.icon_url);
            // 恢复会话时没有也不需要重新取。
            primary_image_tag: None,
        })
}

/// 启动时的活跃源(浏览型)——前端据此决定落文件浏览页而不是媒体库。
#[tauri::command]
fn current_source(state: State<'_, AppState>) -> Option<AccountInfo> {
    let cfg = state.config.lock().unwrap();
    cfg.active_account().filter(|a| a.is_file_browse()).map(|a| account_info(a, true))
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
                // 必须走生效线路:用 a.server(账号主键)会让聚合搜索永远打主线路,
                // 用户切到备用线是因为主线路不通 —— 那台服务器会 unwrap_or_default() 成空结果
                // 从搜索里静默消失,查都没处查。
                server: a.active_line_url(),
                token: a.token.clone(),
                user_id: a.user_id.clone(),
                device_id,
            };
            // 不再二次 filter 掉非 Movie/Series:那会把 search 默认带上的 Episode 又筛没,
            // 白瞎。类型收敛交给 search 的 IncludeItemTypes(默认 Movie,Series,Episode)。
            let items = emby::search(&http, &s, &query, None, None)
                .await
                .unwrap_or_default();
            ServerGroup {
                server_name: if a.user_name.is_empty() {
                    a.server.clone()
                } else {
                    format!("{} @ {}", a.user_name, a.server)
                },
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

/// 切换活跃服务器(聚合搜索点播其它服条目前调用;也用于服务器页切换)。
/// Emby 装 session,浏览型源装 source —— 一张表两种形态,切换必须两边都对齐,
/// 否则会留着上一个服的会话在那儿(切服失败还打错服务器)。
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

#[tauri::command]
async fn list_items(state: State<'_, AppState>, parent_id: String) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    // 保持返回 Vec<Item>:现有前端 invoke<Item[]>("list_items", { parentId }) 直接 .map,
    // 改成 ItemPage 会在运行时炸(tsc 是泛型断言,拦不住)。要总数/翻页/筛选走 list_items_page。
    Ok(emby::items(&state.http, &s, &parent_id, &emby::ItemQuery::default())
        .await?
        .items)
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

/// 测试连接 / 取服务器公开信息(草稿页 06「测试连接」)。★ 登录前调用,故不走 session_of。
#[tauri::command]
async fn test_connection(state: State<'_, AppState>, server: String) -> Result<emby::ServerInfo, String> {
    emby::server_info(&state.http, &server).await
}

/// 合集(BoxSet)。
#[tauri::command]
async fn list_collections(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::collections(&state.http, &s).await
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

/// 首页 Hero 随机推荐。
#[tauri::command]
async fn list_random(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::random_picks(&state.http, &s, limit).await
}

/// 继续观看。
#[tauri::command]
async fn list_resume(state: State<'_, AppState>, limit: u32) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::resume(&state.http, &s, limit).await
}

/// 收藏列表。
#[tauri::command]
async fn list_favorites(state: State<'_, AppState>) -> Result<Vec<Item>, String> {
    let s = session_of(&state)?;
    emby::favorites(&state.http, &s).await
}

/// 切换收藏。
#[tauri::command]
async fn set_favorite(
    state: State<'_, AppState>,
    item_id: String,
    fav: bool,
) -> Result<(), String> {
    let s = session_of(&state)?;
    emby::set_favorite(&state.http, &s, &item_id, fav).await
}

/// 服务器连通状态。草稿 06 的状态点三态:绿=正常 / 黄=需重登 / 灰=未连。
/// `Unknown` 是「还没探过」,前端按灰显示 —— 与"探过了确实不通"同色不同义,
/// 别在 Rust 侧合并成一个:合并了就没法区分"没测"和"测了挂了"。
#[derive(serde::Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum AccountStatus {
    /// 绿:能连且 token 有效。
    Ok,
    /// 黄:服务器活着,但 token 被吊销/过期 —— 用户重登一次就好。
    Reauth,
    /// 灰:压根连不上(域名挂了/线路不通/超时)。
    Down,
    /// 灰:尚未探测。
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
    /// 连通状态三态(需先调 probe_accounts 刷新,否则恒为 unknown)。
    status: AccountStatus,
    /// 显示名(用户起的名,空则回落 host)。
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

fn account_info(a: &linplayer_core::Account, active: bool) -> AccountInfo {
    account_info_with(a, active, AccountStatus::Unknown)
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

/// 探测所有服务器的连通状态,刷新缓存并返回新的列表。前端进服务器页时调一次。
/// 并发探测:一台慢的不该拖住整页(串行 N 台 × 8s 超时 = 页面空一分钟)。
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

/// 单台探测。**必须走 active_line_url()** —— 用户切了备用线路正是因为主线不通,
/// 拿主线去探会把一台好服务器判成灰,而用户看到的又是"我明明能用"。
async fn probe_account(http: &reqwest::Client, a: &linplayer_core::Account) -> AccountStatus {
    let base = a.active_line_url();
    let base = base.trim_end_matches('/');
    if a.is_file_browse() {
        // 浏览型源没有统一的鉴权探测端点(各家 API 差太多),只判连通:
        // 能要到任何 HTTP 响应就算活着。判不了"需重登",所以只会给出绿/灰两态。
        return match http.get(base).send().await {
            Ok(_) => AccountStatus::Ok,
            Err(_) => AccountStatus::Down,
        };
    }
    // Emby:/System/Info 需要鉴权 —— 正好一次分出三态。
    // 用 /System/Info/Public 是不行的:它不校验 token,token 失效也回 200,
    // 那样"需重登"永远探不出来,黄灯就成了摆设。
    let url = format!("{base}/System/Info?api_key={}", a.token);
    match http.get(&url).send().await {
        Ok(r) if r.status().is_success() => AccountStatus::Ok,
        Ok(r) if matches!(r.status().as_u16(), 401 | 403) => AccountStatus::Reauth,
        // 其它状态码(5xx / 404 / 网关错误)说明连上了但这服务器不正常,归为不可用。
        Ok(_) => AccountStatus::Down,
        Err(_) => AccountStatus::Down,
    }
}

/// 编辑服务器:名称/备注/图标/TLS 放行/密码。None=不改该字段。
#[tauri::command]
fn update_account(
    state: State<'_, AppState>,
    server_id: String,
    name: Option<String>,
    remark: Option<String>,
    icon_url: Option<String>,
    allow_insecure_tls: Option<bool>,
    password: Option<String>,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    if let Some(v) = name {
        a.name = v;
    }
    // 备注/图标传空串 = 清空,传 None = 不动。
    if let Some(v) = remark {
        a.remark = (!v.trim().is_empty()).then_some(v);
    }
    if let Some(v) = icon_url {
        a.icon_url = (!v.trim().is_empty()).then_some(v);
    }
    if let Some(v) = allow_insecure_tls {
        a.allow_insecure_tls = v;
    }
    if let Some(v) = password {
        a.password = (!v.is_empty()).then_some(v);
    }
    cfg.save();
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
fn set_active_line(state: State<'_, AppState>, server_id: String, index: usize) -> Result<(), String> {
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

/// 注册 `linplayer://` 协议(Windows)。
///
/// 用「写 .reg 文件 + reg import」而非 `reg add`:后者对空值(`URL Protocol`)和带空格的
/// 路径引号处理不可靠,会把命令存成没引号、一运行就失败。这是 Dart 侧踩过的坑,照搬。
///
/// 每次启动都跑一遍:本项目是绿色压缩包分发,用户挪个文件夹 exe 路径就变了,
/// 注册表里还钉着老路径的话,深链点了会启动失败或启动到旧副本 —— 而且不报错。
#[cfg(windows)]
fn register_deep_link_scheme() {
    let Ok(exe) = std::env::current_exe() else { return };
    let exe = exe.to_string_lossy().replace('\\', "\\\\").replace('"', "\\\"");
    let content = format!(
        "Windows Registry Editor Version 5.00\r\n\
         \r\n\
         [HKEY_CURRENT_USER\\Software\\Classes\\linplayer]\r\n\
         @=\"URL:LinPlayer Protocol\"\r\n\
         \"URL Protocol\"=\"\"\r\n\
         \r\n\
         [HKEY_CURRENT_USER\\Software\\Classes\\linplayer\\shell\\open\\command]\r\n\
         @=\"\\\"{exe}\\\" \\\"%1\\\"\"\r\n"
    );
    let f = std::env::temp_dir().join("linplayer_scheme.reg");
    // .reg 必须是无 BOM 的 UTF-8,reg import 才认。
    if std::fs::write(&f, content.as_bytes()).is_ok() {
        let _ = std::process::Command::new("reg").arg("import").arg(&f).status();
        let _ = std::fs::remove_file(&f);
    }
}

#[cfg(not(windows))]
fn register_deep_link_scheme() {}

/// 启动参数里的 `linplayer://...`(系统通过协议拉起我们时会作为 argv 传进来)。
/// 前端进主界面后调一次;有值就走确认流程。
///
/// ⚠️ 只在**冷启动**时有效。App 已经开着时再点深链,系统会拉起第二个进程 ——
/// 那需要单实例守卫(tauri-plugin-single-instance),没接,已知缺口。
#[tauri::command]
fn startup_deep_link() -> Option<String> {
    std::env::args().skip(1).find(|a| a.starts_with("linplayer://"))
}

// ---------- 服务器图标:下载 / 缓存 / 本地上传 ----------

/// 取服务器图标(data URI)。首次调用会下载并缓存,之后直接读缓存。
/// 取不到返回 Err —— 由前端回退内置图标,别在这儿吞成空串让 UI 显示碎图。
#[tauri::command]
async fn account_icon(state: State<'_, AppState>, server_id: String) -> Result<String, String> {
    let url = {
        let cfg = state.config.lock().unwrap();
        cfg.find(&server_id).and_then(|a| a.icon_url.clone())
    };
    linplayer_core::icon_cache::get(&state.http, &server_id, url.as_deref()).await
}

/// 用户从本地挑一张图当服务器图标。返回 data URI 供前端立刻显示。
#[tauri::command]
fn set_account_icon_file(
    state: State<'_, AppState>,
    server_id: String,
    file_path: String,
) -> Result<String, String> {
    let uri = linplayer_core::icon_cache::set_from_file(&server_id, &file_path)?;
    // icon_url 记成本地路径:重装/清缓存后还能从原文件重建,不用让用户再挑一次。
    let mut cfg = state.config.lock().unwrap();
    let a = cfg.find_mut(&server_id).ok_or("找不到该服务器")?;
    a.icon_url = Some(file_path);
    cfg.save();
    Ok(uri)
}

/// 清掉图标缓存,下次 account_icon 会重新下载(服务器换了 logo 时用)。
#[tauri::command]
fn clear_account_icon(server_id: String) {
    linplayer_core::icon_cache::clear(&server_id);
}

// ---------- 批量解析添加服务器 + linplayer:// 深链(草稿页 06)----------

/// 解析分享文本 → 结构化账号块。**纯解析,不登录、不落盘** ——
/// 前端拿去展示让用户核对/补用户名,确认后再调 batch_add_servers。
#[tauri::command]
fn batch_parse(text: String) -> Vec<linplayer_core::server_batch::ParsedServerBlock> {
    linplayer_core::server_batch::parse_share_text(&text)
}

/// 解析 `linplayer://add-server?...` 深链。
///
/// ⚠️ 返回 Some **不等于**可以直接加号 —— 深链可能来自任何网页/聊天窗口。
/// 前端必须弹确认框展示服务器地址和用户名,由用户点头后才调 batch_add_servers。
#[tauri::command]
fn parse_deep_link(url: String) -> Option<linplayer_core::server_batch::DeepLinkAddServer> {
    linplayer_core::server_batch::parse_deep_link(&url)
}

#[derive(serde::Serialize)]
struct BatchAddResult {
    /// 加成功的服务器主键(= 生效线路 URL);失败为 None。
    server_id: Option<String>,
    /// 展示名。
    name: String,
    /// 失败原因;成功为 None。
    error: Option<String>,
}

/// 批量添加:逐块逐线路试登录,第一条通的线路即设为生效线路,其余线路留着备用。
///
/// 为什么要逐线路试:分享文本里的「主线路」经常是最不通的那条(被墙/限速),
/// 直接钉死第 0 条会让用户加完就连不上,还得自己去线路列表里一条条点。
///
/// 参数:
/// - `fallback_username` / `fallback_password`:用户在 UI 里补的,套用到所有 username 为空的块。
/// - `fallback_name`:深链带来的服务器名(`?name=`);取不到 SystemInfo.serverName 时用。
#[tauri::command]
async fn batch_add_servers(
    state: State<'_, AppState>,
    blocks: Vec<linplayer_core::server_batch::ParsedServerBlock>,
    fallback_username: Option<String>,
    fallback_password: Option<String>,
    fallback_name: Option<String>,
) -> Result<Vec<BatchAddResult>, String> {
    use linplayer_core::server_batch as sb;
    let device_id = state.config.lock().unwrap().device_id.clone();
    let mut out = Vec::new();

    for block in &blocks {
        let lines = sb::server_lines(block);
        if lines.is_empty() {
            continue;
        }
        // 空串要当「缺用户名」处理,不能 unwrap_or_default 后闷头登 ——
        // 深链里 ?user= 显式给空串正是这种情况。
        let username = block
            .username
            .clone()
            .or_else(|| fallback_username.clone())
            .filter(|s| !s.trim().is_empty());
        let password = block
            .password
            .clone()
            .or_else(|| fallback_password.clone())
            .unwrap_or_default();
        let display = lines[0].name.clone();
        let Some(username) = username else {
            out.push(BatchAddResult {
                server_id: None,
                name: display,
                error: Some("缺用户名".into()),
            });
            continue;
        };

        let mut added = None;
        let mut last_err = String::new();
        for (i, line) in lines.iter().enumerate() {
            match emby::login(&state.http, &line.url, &username, &password, &device_id).await {
                Ok((session, result)) => {
                    let name = emby::server_info(&state.http, &line.url)
                        .await
                        .map(|si| si.name)
                        .ok()
                        .filter(|n| !n.trim().is_empty())
                        .or_else(|| fallback_name.clone())
                        .unwrap_or_default();
                    let icon = sb::build_icon_url(
                        &line.url,
                        Some(&result.user_id),
                        result.primary_image_tag.as_deref(),
                    );
                    {
                        let mut cfg = state.config.lock().unwrap();
                        cfg.upsert(Account {
                            server: result.server.clone(),
                            token: result.token.clone(),
                            user_id: result.user_id.clone(),
                            user_name: result.user_name.clone(),
                            name,
                            icon_url: Some(icon),
                            password: (!password.is_empty()).then(|| password.clone()),
                            lines: lines.clone(),
                            active_line: i, // 试通的那条即生效线路
                            ..Default::default()
                        });
                        // 块里带的弹幕线路并进全局弹幕源(接着现有源的 priority 往后排)。
                        let base = cfg.danmaku_sources.len() as i32;
                        for src in sb::danmaku_sources_of(block, base) {
                            if !cfg.danmaku_sources.iter().any(|x| x.id == src.id) {
                                cfg.danmaku_sources.push(src);
                            }
                        }
                        cfg.save();
                    }
                    *state.session.lock().unwrap() = Some(session);
                    *state.source.lock().unwrap() = None;
                    added = Some(result.server);
                    break;
                }
                Err(e) => last_err = e,
            }
        }
        match added {
            Some(id) => out.push(BatchAddResult {
                server_id: Some(id),
                name: display,
                error: None,
            }),
            None => out.push(BatchAddResult {
                server_id: None,
                name: display,
                // 所有线路都没通才算失败,报最后一条的错。
                error: Some(if last_err.is_empty() {
                    "所有线路均无法连接".into()
                } else {
                    last_err
                }),
            }),
        }
    }
    Ok(out)
}

/// 线路测速:并发 HEAD 各线路的 /System/Info/Public,返回毫秒;不通为 None。
#[derive(serde::Serialize)]
struct LineProbe {
    index: usize,
    url: String,
    ms: Option<u64>,
}

#[tauri::command]
async fn probe_lines(state: State<'_, AppState>, server_id: String) -> Result<Vec<LineProbe>, String> {
    let urls: Vec<String> = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        if a.lines.is_empty() {
            vec![a.server.clone()]
        } else {
            a.lines.iter().map(|l| l.url.clone()).collect()
        }
    };
    // 并发探测:线路多时别串行等超时(6s × N 会把用户等睡着)。
    let tasks: Vec<_> = urls
        .into_iter()
        .enumerate()
        .map(|(index, url)| {
            let http = state.http.clone();
            tokio::spawn(async move {
                let probe = format!("{}/System/Info/Public", url.trim_end_matches('/'));
                let t0 = std::time::Instant::now();
                let ok = tokio::time::timeout(
                    std::time::Duration::from_secs(6),
                    http.get(&probe).send(),
                )
                .await
                .ok()
                .and_then(|r| r.ok())
                .map(|r| r.status().is_success())
                .unwrap_or(false);
                LineProbe { index, url, ms: ok.then(|| t0.elapsed().as_millis() as u64) }
            })
        })
        .collect();
    let mut out = Vec::with_capacity(tasks.len());
    for t in tasks {
        out.push(t.await.map_err(|e| format!("线路测速任务失败:{e}"))?);
    }
    Ok(out)
}

/// 删除某账号;若删的是活跃账号,回落到第一个(无账号则清空会话)。
/// 删本地前尽力通知服务端登出(吊销 token),失败不影响本地删除。
#[tauri::command]
async fn remove_account(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    // ★ 先尽力登出:服务端不可达/端点不存在也必须能删账号。
    // 实测 smart.uhdnow.com 的 /Sessions/Logout 直接 404,所以这里只能忽略结果 ——
    // 认这个端点的服务器上 token 会被吊销,不认的照旧本地删。
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

// image_url 命令已删:前端 src/lib/api.ts 自己拼图片地址,grep 全仓无人 invoke("image_url"),
// 且原实现写死 Primary?maxHeight=360 表达不了 Thumb/Backdrop/Logo —— 死代码,不留。

// ---------- 播放命令 ----------
/// 播放:解析流 -> 从 resume_secs 起播 -> 上报 start;返回起播秒数供前端定位进度条。
#[tauri::command]
async fn play(
    state: State<'_, AppState>,
    item_id: String,
    resume_secs: f64,
) -> Result<f64, String> {
    let s = session_of(&state)?;

    // 观看记录:装上下文,并据此决定真正的起播点。
    // 前端传进来的 resume_secs 只是 Emby 本服的进度;跨服续播开启时,
    // 本地记录里别的服务器上更靠后的进度会覆盖它(取最大)。
    let ctx = build_wh_ctx(&state, &s, &item_id).await;
    let resume_secs = match &ctx {
        Some((scope, cand, series_tmdb)) => {
            let cross = state.config.lock().unwrap().prefs.cross_server_resume;
            state
                .watch_history
                .resolve_resume_position_ticks(
                    scope,
                    cand,
                    series_tmdb.as_deref(),
                    Some((resume_secs * wh::TICKS_PER_SEC as f64) as i64),
                    cand.played,
                    cross,
                )
                .map(|t| t as f64 / wh::TICKS_PER_SEC as f64)
                .unwrap_or(resume_secs)
        }
        // 取不到匹配判据(网络抖/权限)不该拦住播放,按前端给的进度走。
        None => resume_secs,
    };
    *state.wh_ctx.lock().unwrap() = ctx;
    // 回传去重集按「一次播放」计生命周期(对齐 Dart _done):不清的话,看完第二集时
    // 第一集的去重键还在,同一台服务器会被判成"已回传过"而跳过 —— 静默漏传。
    state.wh_done.lock().unwrap().clear();

    let target = emby::resolve_stream(&state.http, &s, &item_id).await?;
    poclog(&format!(
        "PLAY item={item_id} resume={resume_secs} psid={} url={} method={}",
        target.play_session_id, target.url, target.play_method
    ));

    // 多线程加载:仅直传流走本地预取代理(转码 URL 是分段流,跳过直连)。
    // 起服失败/非直传/用户关掉 → 回退直连;旧句柄被替换即 Drop 停服。
    let (pf_on, pf_threads, pf_cache) = {
        let p = &state.config.lock().unwrap().prefs;
        (p.prefetch_enabled, p.prefetch_threads, p.prefetch_cache_bytes)
    };
    let play_url = if pf_on && target.play_method == "DirectStream" {
        let resign: linplayer_core::net::prefetch::ResignFn = {
            let http = state.http.clone();
            let sess = s.clone();
            let iid = item_id.clone();
            Arc::new(move || {
                let (http, sess, iid) = (http.clone(), sess.clone(), iid.clone());
                Box::pin(async move {
                    emby::resolve_stream(&http, &sess, &iid).await.ok().map(|t| t.url)
                })
            })
        };
        // 线程数与读前缓冲上限来自设置页(prefetch::start 内部会把线程数 clamp 到 2~4)。
        match linplayer_core::net::prefetch::start(target.url.clone(), pf_threads, pf_cache, Some(resign)).await {
            Some(h) => {
                let u = h.url.clone();
                *state.prefetch.lock().unwrap() = Some(h);
                poclog(&format!("prefetch 代理起服 {u}"));
                u
            }
            None => {
                *state.prefetch.lock().unwrap() = None;
                target.url.clone()
            }
        }
    } else {
        *state.prefetch.lock().unwrap() = None; // 转码/非直传:停旧代理走直连
        target.url.clone()
    };

    // 加载(不跨 await 持锁)
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or_else(|| {
            poclog("PLAY 失败: 播放器未就绪(mpv 初始化没成功)");
            "播放器未就绪".to_string()
        })?;
        let _ = p.take_error_eof();
        // media 代理:仅 HTTP 系列 + 开启 proxyMedia 时给 mpv 挂 http-proxy(SOCKS mpv 不支持)。
        let mpv_proxy = state.config.lock().unwrap().proxy.mpv_http_proxy();
        p.set_http_proxy(mpv_proxy.as_deref());
        p.load_at(&play_url, resume_secs)?;
        p.set_pause(false);
    }
    *state.source_play_entry.lock().unwrap() = None; // Emby 播放,非源
    // 上报 start(失败不阻断播放)
    if let Err(e) = emby::report_start(&state.http, &s, &target, resume_secs).await {
        poclog(&format!("report_start ERR: {e}"));
    }
    *state.playback.lock().unwrap() = Some(target);

    // 播放期同步:Trakt/Bangumi 任一连接就抓元数据,存上下文供 stop 收尾。
    *state.scrobble_ctx.lock().unwrap() = None;
    let (trakt_acc, bangumi_on) = {
        let cfg = state.config.lock().unwrap();
        (cfg.sync_trakt.clone(), cfg.sync_bangumi.is_some())
    };
    if trakt_acc.is_some() || bangumi_on {
        if let Some(info) = emby::fetch_scrobble_info(&state.http, &s, &item_id).await {
            *state.scrobble_ctx.lock().unwrap() = Some(info.clone());
            // Trakt 有外部 ID 才上报 start(后台,不阻塞起播)。
            if let Some(acc) = trakt_acc {
                if info.has_trakt_ids() {
                    let progress = if info.runtime_secs > 0.0 {
                        (resume_secs / info.runtime_secs * 100.0).clamp(0.0, 100.0)
                    } else {
                        0.0
                    };
                    tauri::async_runtime::spawn(async move {
                        trakt::scrobble(&acc, &info.media_type, info.ids, progress, "start").await;
                    });
                }
            }
        }
    }
    // 派发 onPlay 给插件(eventListeners)。
    if let Some(mgr) = state.plugins.get() {
        let media = state
            .scrobble_ctx
            .lock()
            .unwrap()
            .as_ref()
            .map(|i| serde_json::json!({ "name": i.title, "type": i.media_type }))
            .unwrap_or(serde_json::Value::Null);
        mgr.fire_player_event("onPlay", media);
    }
    poclog("load OK");
    Ok(resume_secs)
}

// ---------- 本地观看记录 / 跨服务器续播 ----------
use linplayer_core::watch_history as wh;

fn scope_of(s: &Session) -> String {
    wh::scope_key(&s.server, &s.user_id)
}

/// 取某剧的 TMDB id,按 seriesId 缓存(含「查过但没有」的负缓存,别对没刮削的剧反复打服务器)。
/// 对齐 Dart 的 _seriesTmdbCache。
async fn series_tmdb_cached(state: &State<'_, AppState>, s: &Session, series_id: &str) -> Option<String> {
    if let Some(hit) = state.series_tmdb.lock().unwrap().get(series_id) {
        return hit.clone();
    }
    let got = emby::series_tmdb_id(&state.http, s, series_id).await;
    state.series_tmdb.lock().unwrap().insert(series_id.to_string(), got.clone());
    got
}

/// 装配播放条目的观看记录上下文:取带匹配判据的 Item -> Candidate(+剧的 TMDB id)。
/// 失败不该阻断播放 —— 观看记录是增值功能,不是播放的前置。
async fn build_wh_ctx(
    state: &State<'_, AppState>,
    s: &Session,
    item_id: &str,
) -> Option<(String, wh::Candidate, Option<String>)> {
    let item = emby::item_for_history(&state.http, s, item_id).await.ok()?;
    let cand = wh::Candidate::from(&item);
    let series_tmdb = match cand.series_id.as_deref() {
        Some(sid) => series_tmdb_cached(state, s, sid).await,
        None => None,
    };
    Some((scope_of(s), cand, series_tmdb))
}

/// 周期/暂停切换时上报进度(前端每 ~5s 及暂停切换时调)。仅 Emby 播放有会话时上报。
/// 顺带落本地观看记录(core 内部按 10s 节流,不会每次都写盘)。
#[tauri::command]
async fn report_progress(state: State<'_, AppState>, pos: f64, paused: bool) -> Result<(), String> {
    let target = state.playback.lock().unwrap().clone();
    let Some(t) = target else { return Ok(()) }; // 网盘源无会话,跳过
    let s = session_of(&state)?;
    let _ = emby::report_progress(&state.http, &s, &t, pos, paused).await;
    capture_history(&state, pos, false);
    Ok(())
}

/// 把当前进度记进本地观看记录。force=true 用于停止播放(必须落地,不受节流)。
fn capture_history(state: &State<'_, AppState>, pos: f64, force: bool) {
    let ctx = state.wh_ctx.lock().unwrap().clone();
    let Some((scope, cand, series_tmdb)) = ctx else { return };
    state.watch_history.capture_playback(
        &scope,
        &cand,
        series_tmdb.as_deref(),
        (pos * wh::TICKS_PER_SEC as f64) as i64,
        wh::WriteSource::InternalPlayer,
        90, // 看过阈值:与 Emby 默认一致
        false,
        force,
    );
}

/// 观看记录列表。scope=None 取全部(跨服务器);否则只取当前服务器。
#[tauri::command]
fn watch_history_list(state: State<'_, AppState>, current_only: bool) -> Vec<wh::Record> {
    if current_only {
        match session_of(&state) {
            Ok(s) => state.watch_history.load_scope(&scope_of(&s)),
            Err(_) => Vec::new(),
        }
    } else {
        state.watch_history.load_all()
    }
}

#[tauri::command]
fn watch_history_clear(state: State<'_, AppState>) {
    state.watch_history.clear_all();
}

#[tauri::command]
fn watch_history_delete(state: State<'_, AppState>, record_id: String) {
    state.watch_history.delete_record(&record_id);
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

/// 跨服回传设置(主开关 / 范围 / 是否带进度)。
#[derive(serde::Serialize, serde::Deserialize)]
struct WritebackSettings {
    enabled: bool,
    /// "all" | "first" | "latest"
    range: String,
    include_progress: bool,
}

#[tauri::command]
fn get_writeback_settings(state: State<'_, AppState>) -> WritebackSettings {
    let p = &state.config.lock().unwrap().prefs;
    WritebackSettings {
        enabled: p.cross_server_writeback,
        range: p.cross_server_writeback_range.clone(),
        include_progress: p.cross_server_writeback_progress,
    }
}

#[tauri::command]
fn set_writeback_settings(
    state: State<'_, AppState>,
    settings: WritebackSettings,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.cross_server_writeback = settings.enabled;
    // from_wire 对无法识别的值静默回落 "all" —— 那会让用户以为选了"仅初次"其实在写所有服。
    // 宁可在这里拒掉。
    if !matches!(settings.range.as_str(), "all" | "first" | "latest") {
        return Err(format!("未知的回传范围: {}", settings.range));
    }
    cfg.prefs.cross_server_writeback_range = settings.range;
    cfg.prefs.cross_server_writeback_progress = settings.include_progress;
    cfg.save();
    Ok(())
}

/// 所有已登录 Emby 账号的会话(跨服回传/恢复扫描要挨个打)。浏览型源没有 Emby 会话,跳过。
fn all_emby_sessions(state: &AppState) -> Vec<Session> {
    let cfg = state.config.lock().unwrap();
    let device_id = cfg.device_id.clone();
    cfg.accounts
        .iter()
        .filter(|a| !a.is_file_browse() && !a.token.is_empty())
        .map(|a| Session {
            server: a.active_line_url(),
            token: a.token.clone(),
            user_id: a.user_id.clone(),
            device_id: device_id.clone(),
        })
        .collect()
}

/// 恢复扫描:拿本地观看记录去当前服务器找对应条目,strong 匹配的自动回写进度,
/// possible 匹配的放进 prompt_candidates 交给用户确认。
///
/// ⚠️ 这会**往当前服务器写**播放进度,不是只读扫描。前端别在进页面时自动跑,
/// 要给用户一个明确的「扫描并恢复」按钮。
#[tauri::command]
async fn watch_history_scan_restore(
    state: State<'_, AppState>,
) -> Result<linplayer_core::watch_history_sync::RestoreReport, String> {
    let s = session_of(&state)?;
    let scope = scope_of(&s);
    linplayer_core::watch_history_sync::scan_restore(&state.http, &s, &state.watch_history, &scope)
        .await
}

/// 用户确认某个 possible 候选后,把它写进当前服务器。
#[tauri::command]
async fn watch_history_restore_candidate(
    state: State<'_, AppState>,
    candidate: wh::RestoreCandidate,
) -> Result<bool, String> {
    let s = session_of(&state)?;
    linplayer_core::watch_history_sync::restore_candidate(
        &state.http,
        &s,
        &state.watch_history,
        &candidate,
    )
    .await
}

/// 停播时把这次的进度/已看状态回传到**其它**看过同一内容的服务器。
/// 判定逻辑全在 core 的 writeback_targets/writeback_plan(已测),这里只做 HTTP 编排。
///
/// 默认不跑:主开关默认关,因为它会往用户的其它服务器写数据。
async fn writeback_on_stop(
    state: &State<'_, AppState>,
    scope: &str,
    cand: &wh::Candidate,
    pos: f64,
) -> Result<(), String> {
    let (enabled, range, include_progress) = {
        let p = &state.config.lock().unwrap().prefs;
        (
            p.cross_server_writeback,
            wh::WritebackRange::from_wire(&p.cross_server_writeback_range),
            p.cross_server_writeback_progress,
        )
    };
    if !enabled {
        return Ok(());
    }
    let s = session_of(state)?;
    let sessions = all_emby_sessions(state);
    let ticks = (pos * wh::TICKS_PER_SEC as f64) as i64;
    // 「已看完」判定必须与 capture_history 落本地记录时用的是同一个阈值(90%),
    // 否则会出现"本地记成看完了、回传给别的服务器却说没看完"这种自相矛盾。
    let played = cand
        .run_time_ticks
        .filter(|r| *r > 0)
        .map(|r| (ticks as f64 / r as f64) * 100.0 >= 90.0)
        .unwrap_or(false);

    let mut done = state.wh_done.lock().unwrap().clone();
    let report = linplayer_core::watch_history_sync::run_writeback(
        &state.http,
        &s,
        &sessions,
        &state.watch_history,
        scope,
        cand,
        ticks,
        played,
        range,
        include_progress,
        &mut done,
    )
    .await?;
    *state.wh_done.lock().unwrap() = done;
    if !report.errors.is_empty() {
        poclog(&format!("[跨服回传] 部分失败: {:?}", report.errors));
    }
    poclog(&format!(
        "[跨服回传] 目标 {} 台,写成功 {},跳过 {}",
        report.targets,
        report.written,
        report.skipped.len()
    ));
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
    *state.prefetch.lock().unwrap() = None; // 停预取代理(Drop 关服)

    // 观看记录:最终进度必须落地(force 绕开 10s 节流),否则看一半退出这段就丢了。
    capture_history(&state, pos, true);
    // 跨服回传要用 ctx 里的 Candidate,得在清空前取走。
    let wh_ctx = state.wh_ctx.lock().unwrap().take();
    if let Some((scope, cand, _)) = wh_ctx {
        if let Err(e) = writeback_on_stop(&state, &scope, &cand, pos).await {
            poclog(&format!("[跨服回传] 失败: {e}"));
        }
    }

    // 播放期同步收尾:按最终进度上报。
    let ctx = state.scrobble_ctx.lock().unwrap().take();
    let (trakt_acc, bangumi_acc) = {
        let cfg = state.config.lock().unwrap();
        (cfg.sync_trakt.clone(), cfg.sync_bangumi.clone())
    };
    if let Some(info) = ctx {
        let progress = if info.runtime_secs > 0.0 {
            (pos / info.runtime_secs * 100.0).clamp(0.0, 100.0)
        } else {
            0.0
        };
        // Trakt:stop 上报(Trakt 在 ≥80% 时自动标记看过并写历史)。
        if let Some(acc) = trakt_acc {
            if info.has_trakt_ids() {
                trakt::scrobble(&acc, &info.media_type, info.ids.clone(), progress, "stop").await;
            }
        }
        // Bangumi:看过阈值(≥80%)才反查标记(反查耗多次 API,不到阈值不触发)。
        if let Some(acc) = bangumi_acc {
            if progress >= 80.0 && !info.title.is_empty() {
                mark_bangumi_watched(&acc, &info).await;
            }
        }
    }

    let target = state.playback.lock().unwrap().take();
    if let (Some(t), Ok(s)) = (target, session_of(&state)) {
        if let Err(e) = emby::report_stopped(&state.http, &s, &t, pos).await {
            poclog(&format!("report_stopped ERR: {e}"));
        }
    }
    // 派发 onPlayEnd 给插件(eventListeners,如 telegram-notify)。
    if let Some(mgr) = state.plugins.get() {
        mgr.fire_player_event("onPlayEnd", serde_json::json!({ "position": pos }));
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

// ================= 播放器能力命令 =================
// 对齐旧 Flutter 三端契约 lib/core/services/video_player_service.dart。
// 迁移文档只列到「播放器」模块粒度,没列能力清单 → 上一轮把倍速/音量/截图/画面比例/
// 延迟/字幕样式/超分全漏了,UI 上就是一排死按钮。这里按旧契约补齐。

/// 播放器可调项快照(前端 OSD 一次拉齐,不用逐个 get)。
#[derive(serde::Serialize)]
struct PlayerOpts {
    speed: f64,
    volume: f64,
    muted: bool,
    audio_delay: f64,
    sub_delay: f64,
    hwdec: String,
    shader_count: usize,
}

/// 取播放器当前可调项。
#[tauri::command]
fn player_opts(state: State<'_, AppState>) -> Result<PlayerOpts, String> {
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    Ok(PlayerOpts {
        speed: p.speed(),
        volume: p.volume(),
        muted: p.muted(),
        audio_delay: p.audio_delay(),
        sub_delay: p.sub_delay(),
        hwdec: p.hwdec(),
        shader_count: p.shader_count(),
    })
}

macro_rules! with_player {
    ($state:expr, $p:ident => $body:expr) => {{
        let guard = $state.player.lock().unwrap();
        let $p = guard.as_ref().ok_or("播放器未就绪")?;
        $body;
        Ok(())
    }};
}

#[tauri::command]
fn set_speed(state: State<'_, AppState>, speed: f64) -> Result<(), String> {
    with_player!(state, p => p.set_speed(speed))
}

#[tauri::command]
fn set_volume(state: State<'_, AppState>, volume: f64) -> Result<(), String> {
    with_player!(state, p => p.set_volume(volume))
}

#[tauri::command]
fn set_mute(state: State<'_, AppState>, mute: bool) -> Result<(), String> {
    with_player!(state, p => p.set_mute(mute))
}

#[tauri::command]
fn set_audio_delay(state: State<'_, AppState>, secs: f64) -> Result<(), String> {
    with_player!(state, p => p.set_audio_delay(secs))
}

#[tauri::command]
fn set_sub_delay(state: State<'_, AppState>, secs: f64) -> Result<(), String> {
    with_player!(state, p => p.set_sub_delay(secs))
}

#[tauri::command]
fn set_aspect_ratio(state: State<'_, AppState>, ratio: String) -> Result<(), String> {
    with_player!(state, p => p.set_aspect_ratio(&ratio))
}

#[tauri::command]
fn set_hwdec(state: State<'_, AppState>, mode: String) -> Result<(), String> {
    with_player!(state, p => p.set_hwdec(&mode))
}

/// 字幕样式(字体/字号/位置/背景/混合)。None 的项不动。
#[tauri::command]
fn set_sub_style(
    state: State<'_, AppState>,
    font: Option<String>,
    size: Option<f64>,
    position: Option<f64>,
    background: Option<bool>,
    blend_mode: Option<String>,
) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    if let Some(f) = font {
        p.set_sub_font(&f);
    }
    if let Some(s) = size {
        p.set_sub_size(s);
    }
    if let Some(pos) = position {
        p.set_sub_position(pos);
    }
    if let Some(b) = background {
        p.set_sub_background(b);
    }
    if let Some(m) = blend_mode {
        p.set_sub_blend_mode(&m);
    }
    Ok(())
}

/// 次字幕(双字幕)。id 为空 = 关。
#[tauri::command]
fn set_secondary_sub(state: State<'_, AppState>, id: String) -> Result<(), String> {
    with_player!(state, p => p.set_secondary_sub(&id))
}

#[tauri::command]
fn set_secondary_sub_opts(
    state: State<'_, AppState>,
    delay: Option<f64>,
    position: Option<f64>,
) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    if let Some(d) = delay {
        p.set_secondary_sub_delay(d);
    }
    if let Some(pos) = position {
        p.set_secondary_sub_position(pos);
    }
    Ok(())
}

/// 加载外挂字幕(本地路径或 URL)。secondary=true 挂成次字幕。
#[tauri::command]
fn add_subtitle(
    state: State<'_, AppState>,
    url: String,
    title: Option<String>,
    secondary: Option<bool>,
) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let t = title.unwrap_or_else(|| "外挂字幕".into());
    if secondary.unwrap_or(false) {
        p.add_secondary_sub(&url, &t)
    } else {
        p.add_subtitle(&url, &t);
        Ok(())
    }
}

// ---------- 字幕翻译 ----------
use linplayer_core::translation as tr;

#[tauri::command]
fn get_translation_settings() -> tr::TranslationSettings {
    tr::TranslationSettings::load()
}

#[tauri::command]
fn set_translation_settings(settings: tr::TranslationSettings) -> Result<(), String> {
    settings.save()
}

/// 各引擎是否已配好(设置页的状态点)。key=引擎 storage_key。
// ---------- 实时预读翻译:挂在播放器上 ----------
//
// 「字幕 cue 观测」听着像要新建一套观测机制,其实 mpv 的 `sub-text` / `sub-start` /
// `sub-end` 就是普通属性,get_property 直接读得到 —— 播放器侧没有任何前置缺口。
// 内嵌字幕也不用隐藏:我们不改字幕轨,只是把 mpv 当前显示的这句原样取出来译好,
// 通过事件推给前端叠加层渲染,mpv 那句由前端决定盖不盖。

/// 停掉实时翻译轮询的信号。Drop/置 false 即停。
struct LiveTranslate {
    stop: Arc<std::sync::atomic::AtomicBool>,
}

/// 开启实时预读翻译。轮询 mpv 的 sub-text,每换一句就译一句,译完 emit 给前端叠加层。
///
/// source_lang=None 表示让引擎自动判断源语言。
#[tauri::command]
fn translate_live_start(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    source_lang: Option<String>,
) -> Result<(), String> {
    let settings = tr::TranslationSettings::load();
    let engine = tr::active_engine(&settings)
        .ok_or("当前翻译引擎还没配好(缺 API Key 或地址),先去设置里填")?;
    let translator = Arc::new(tr::StreamingTranslator::new(
        engine,
        source_lang.unwrap_or_default(),
        settings.target_lang.clone(),
        settings.layout,
    ));

    // 先停旧的:不停的话切换引擎/语言会留下两个轮询,两句译文交替闪。
    translate_live_stop(state.clone());
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    *state.live_translate.lock().unwrap() = Some(LiveTranslate { stop: stop.clone() });

    tauri::async_runtime::spawn(async move {
        use tauri::Emitter;
        let mut last = String::new();
        loop {
            if stop.load(Ordering::SeqCst) {
                break;
            }
            // 每轮重新拿 state:播放器可能中途被换掉(换片),持着旧引用会译到上一部的字幕。
            let cur = {
                let st: State<'_, AppState> = app.state();
                let guard = st.player.lock().unwrap();
                guard.as_ref().and_then(|p| p.get_property("sub-text"))
            }
            .unwrap_or_default();

            if cur != last {
                last = cur.clone();
                if cur.trim().is_empty() {
                    // 空 cue = 这句结束了,清掉叠加层,否则上一句会一直挂着。
                    let _ = app.emit("subtitle-translated", String::new());
                } else if let Some(hit) = translator.cached_display(&cur) {
                    // 命中缓存就直接推,不必等一个网络往返(重复台词/回看很常见)。
                    let _ = app.emit("subtitle-translated", hit);
                } else {
                    match translator.on_cue(&cur).await {
                        Ok(text) => {
                            let _ = app.emit("subtitle-translated", text);
                        }
                        // 单句失败不该停掉整个轮询(限流/抖动),但要让前端知道这句没译出来,
                        // 不能静默显示原文让用户以为翻译在工作。
                        Err(e) => {
                            let _ = app.emit("subtitle-translate-error", e);
                        }
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
    });
    Ok(())
}

#[tauri::command]
fn translate_live_stop(state: State<'_, AppState>) {
    if let Some(lt) = state.live_translate.lock().unwrap().take() {
        lt.stop.store(true, Ordering::SeqCst);
    }
}

#[tauri::command]
fn translation_engine_status() -> HashMap<String, bool> {
    let s = tr::TranslationSettings::load();
    use tr::TranslationEngineKind::*;
    [Openai, Anthropic, BaiduGeneral, BaiduLlm, Tencent]
        .into_iter()
        .map(|k| (k.storage_key().to_string(), tr::build_engine(k, &s).is_some()))
        .collect()
}

/// 整轨翻译:取当前播放条目的某条字幕流 → 翻译 → 落 SRT → 挂给 mpv。
/// 返回落盘的 SRT 路径。secondary=true 挂成次字幕(原文在下,译文在上)。
#[tauri::command]
async fn translate_subtitle(
    state: State<'_, AppState>,
    item_id: String,
    media_source_id: String,
    index: i64,
    delivery_url: Option<String>,
    source_lang: Option<String>,
    secondary: Option<bool>,
) -> Result<String, String> {
    let settings = tr::TranslationSettings::load();
    let engine = tr::active_engine(&settings)
        .ok_or("当前翻译引擎还没配好(缺 API Key 或地址),先去设置里填")?;
    let s = session_of(&state)?;
    // 走当前生效线路 —— 用户切了线路,字幕也得跟着走。
    let candidates = tr::subtitle_url_candidates(
        &s.server,
        Some(&s.token),
        &item_id,
        &media_source_id,
        index,
        delivery_url.as_deref(),
        None,
    );
    let seed = format!("{}:{item_id}:{media_source_id}:{index}", s.server);
    let path = tr::translate_subtitle_url(
        &candidates,
        engine,
        source_lang.as_deref().unwrap_or(tr::lang::AUTO),
        &settings.target_lang,
        settings.layout,
        Some(&s.token),
        &seed,
        None,
    )
    .await?;
    // 翻完直接挂上 —— 只返回路径不挂载,那就是「摆了个按钮不接线」。
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        if secondary.unwrap_or(false) {
            p.add_secondary_sub(&path, "翻译字幕")?;
        } else {
            p.add_subtitle(&path, "翻译字幕");
        }
    }
    Ok(path)
}

// ---------- Whisper 离线转录 ----------
#[derive(serde::Serialize)]
struct WhisperModelInfo {
    key: String,
    display_name: String,
    size_label: String,
    downloaded: bool,
    downloaded_bytes: u64,
}

const WHISPER_MODELS: [tr::WhisperModel; 4] = {
    use tr::WhisperModel::*;
    [Tiny, Base, Medium, Large]
};

/// key → 模型。`from_key` 对无效值静默回落默认档,故先白名单校验。
fn whisper_model_of(key: &str) -> Result<tr::WhisperModel, String> {
    WHISPER_MODELS
        .into_iter()
        .find(|m| m.storage_key() == key)
        .ok_or_else(|| format!("未知的 Whisper 模型:{key}"))
}

#[tauri::command]
fn whisper_models() -> Vec<WhisperModelInfo> {
    WHISPER_MODELS
        .into_iter()
        .map(|m| WhisperModelInfo {
            key: m.storage_key().to_string(),
            display_name: m.display_name().to_string(),
            size_label: m.size_label().to_string(),
            downloaded: tr::whisper::is_downloaded(m),
            downloaded_bytes: tr::whisper::downloaded_size(m),
        })
        .collect()
}

/// 模型下载(1-3GB)。不报进度用户会以为卡死。
/// 注意 `WhisperModel::from_key` 无效值会**静默回落默认档**(core 的既有语义),
/// 所以这里先对着 storage_key 白名单校验 —— 别让前端传错字就悄悄下了另一个模型。
#[tauri::command]
async fn whisper_download(app: tauri::AppHandle, model: String) -> Result<String, String> {
    use tauri::Emitter;
    let m = whisper_model_of(&model)?;
    let mirror = tr::TranslationSettings::load().whisper_mirror;
    let progress: tr::whisper::DownloadProgress = {
        let app = app.clone();
        Arc::new(move |done: u64, total: u64, pct: f64| {
            let _ = app.emit("whisper-download", (done, total, pct));
        })
    };
    tr::whisper::download_model(m, &mirror, None, Some(progress))
        .await
        .map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn whisper_delete(model: String) -> Result<(), String> {
    tr::whisper::delete_model(whisper_model_of(&model)?)
}

/// Whisper/ffmpeg 可执行文件是否就位(设置页据此决定能不能开转录)。
#[derive(serde::Serialize)]
struct WhisperDeps {
    whisper: Option<String>,
    ffmpeg: Option<String>,
}

#[tauri::command]
fn whisper_deps() -> WhisperDeps {
    let s = tr::TranslationSettings::load();
    WhisperDeps {
        whisper: tr::whisper::resolve_whisper(&s.whisper_binary),
        ffmpeg: tr::whisper::resolve_ffmpeg(&s.ffmpeg_path),
    }
}

/// 自动下载 ffmpeg(Win/macOS)。Linux 是 .tar.xz,core 解不了 —— 会返回明确错误让用户装包管理器。
#[tauri::command]
async fn whisper_download_ffmpeg(app: tauri::AppHandle) -> Result<String, String> {
    use tauri::Emitter;
    let progress: tr::whisper::DownloadProgress = Arc::new(move |done: u64, total: u64, pct: f64| {
        let _ = app.emit("ffmpeg-download", (done, total, pct));
    });
    tr::whisper::download_ffmpeg(Some(progress)).await
}

/// 截图到图片文件,返回落盘路径。dir 为空则落到 图片/LinPlayer。
#[tauri::command]
fn screenshot(state: State<'_, AppState>, dir: Option<String>) -> Result<String, String> {
    let base = dir
        .filter(|d| !d.trim().is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            dirs::picture_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("."))
                .join("LinPlayer")
        });
    std::fs::create_dir_all(&base).map_err(|e| format!("建截图目录失败: {e}"))?;
    // 文件名用播放位置,避免同一片子连拍互相覆盖(不引 chrono,时间戳够用)。
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    let at = p.status().time.max(0.0) as i64;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let path = base.join(format!("shot-{stamp}-{at}s.png"));
    let s = path.to_string_lossy().into_owned();
    p.screenshot_to(&s)?;
    Ok(s)
}

/// 超分档位清单(id, 显示名)。
#[tauri::command]
fn shader_levels() -> Vec<(&'static str, &'static str)> {
    shaders::levels()
}

/// 应用超分档位。返回实际挂上的 shader 数 —— 0 而档位非 off 就是没生效
/// (见 [[superres-and-toast]]:旧 Flutter 桌面软件纹理根本不跑 glsl,必须回读校验)。
#[tauri::command]
fn set_shader_level(state: State<'_, AppState>, level: String) -> Result<usize, String> {
    let dir = dirs::config_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("LinPlayer")
        .join("shaders");
    let paths = shaders::shader_paths(&dir, &level)?;
    let guard = state.player.lock().unwrap();
    let p = guard.as_ref().ok_or("播放器未就绪")?;
    p.set_shaders(&paths);
    let got = p.shader_count();
    if !paths.is_empty() && got == 0 {
        return Err("超分未生效(mpv 未接受 shader)".into());
    }
    Ok(got)
}

/// mpv 属性直读/直写 + 命令直通。插件桥和一次性调参用(对齐 Flutter 的
/// mpvGetProperty/mpvSetProperty/mpvCommand);有专用命令的优先用专用命令。
#[tauri::command]
fn mpv_get(state: State<'_, AppState>, name: String) -> Result<Option<String>, String> {
    let guard = state.player.lock().unwrap();
    Ok(guard.as_ref().ok_or("播放器未就绪")?.get_property(&name))
}

#[tauri::command]
fn mpv_set(state: State<'_, AppState>, name: String, value: String) -> Result<(), String> {
    with_player!(state, p => p.set_property(&name, &value))
}

#[tauri::command]
fn mpv_command(state: State<'_, AppState>, args: Vec<String>) -> Result<(), String> {
    let guard = state.player.lock().unwrap();
    guard.as_ref().ok_or("播放器未就绪")?.command(&args)
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
    // 只改选轨三项。别整体覆盖 —— 那会把 cross_server_resume 悄悄重置成默认值
    // (用户改个字幕语言,跨服续播就被关了)。
    cfg.prefs = Prefs { audio_lang, sub_lang, sub_enabled, ..cfg.prefs.clone() };
    cfg.save();
    Ok(())
}

// ---------- 弹幕 ----------
fn danmaku_cfg(s: &DanmakuServer) -> DanmakuSourceConfig {
    let auth_type = match s.auth_type.as_str() {
        "pathToken" => DanmakuAuthType::PathToken,
        "headerToken" => DanmakuAuthType::HeaderToken,
        "queryToken" => DanmakuAuthType::QueryToken,
        _ => DanmakuAuthType::None,
    };
    // id/name 必须逐源取,不能写死 —— 多源下写死会让所有源撞成同一身份,分组结果串台。
    DanmakuSourceConfig {
        id: if s.id.trim().is_empty() { s.api_url.clone() } else { s.id.clone() },
        name: if s.name.trim().is_empty() { "自建源".into() } else { s.name.clone() },
        api_url: s.api_url.clone(),
        official: false,
        auth_type: Some(auth_type),
        token: (!s.token.is_empty()).then(|| s.token.clone()),
        app_id: None,
        app_secret: None,
    }
}

/// 弹弹Play 官方源配置(编译期加密注入凭据齐才有);无凭据返回 None。
/// 官方弹弹Play 源的 id。★ 是 "official",不是 Dart 那边的 "dandanplay" ——
/// 自动挂弹幕的 episodeId 连号快路径要按它认源,写错了不报错,只是快路径永远不命中。
const DANDAN_OFFICIAL_SOURCE_ID: &str = "official";

fn official_danmaku_cfg() -> Option<DanmakuSourceConfig> {
    let (app_id, app_secret) = linplayer_core::secrets::dandan_creds()?;
    Some(DanmakuSourceConfig {
        id: DANDAN_OFFICIAL_SOURCE_ID.into(),
        name: "弹弹Play".into(),
        api_url: String::new(), // official=true 走固定 OFFICIAL_BASE
        official: true,
        auth_type: Some(DanmakuAuthType::None),
        token: None,
        app_id: Some(app_id),
        app_secret: Some(app_secret),
    })
}

/// 组装参与本次请求的弹幕源:启用的自建源(按 priority)+ 官方弹弹Play(有编译期凭据才有)。
/// 对齐 Dart 的 `sourcesFor(allowOfficial:)` —— 启用/排序/官方过滤都在宿主这层决定。
fn danmaku_sources(state: &State<'_, AppState>, allow_official: bool) -> Vec<DanmakuSourceConfig> {
    let mut out: Vec<DanmakuSourceConfig> = state
        .config
        .lock()
        .unwrap()
        .enabled_danmaku_sources()
        .iter()
        .filter(|s| !s.api_url.trim().is_empty())
        .map(danmaku_cfg)
        .collect();
    if allow_official {
        out.extend(official_danmaku_cfg());
    }
    out
}

fn require_danmaku_sources(state: &State<'_, AppState>) -> Result<Vec<DanmakuSourceConfig>, String> {
    let v = danmaku_sources(state, true);
    if v.is_empty() {
        return Err("未配置弹幕服务器(且无官方弹弹Play凭据)".into());
    }
    Ok(v)
}

/// 自建弹幕源列表(设置页增删改查)。
#[tauri::command]
fn get_danmaku_config(state: State<'_, AppState>) -> Vec<DanmakuServer> {
    state.config.lock().unwrap().danmaku_sources.clone()
}

/// 覆写自建弹幕源表。id 为空的自动补一个(用 api_url 做稳定身份)。
#[tauri::command]
fn set_danmaku_config(
    state: State<'_, AppState>,
    sources: Vec<DanmakuServer>,
) -> Result<(), String> {
    let mut cfg = state.config.lock().unwrap();
    cfg.danmaku_sources = sources
        .into_iter()
        .map(|mut s| {
            if s.id.trim().is_empty() {
                s.id = s.api_url.trim().trim_end_matches('/').to_string();
            }
            s
        })
        .collect();
    cfg.save();
    Ok(())
}

/// 按标题搜弹幕番剧(带剧集列表供挑集)。多源并行,分组返回供用户挑源。
#[tauri::command]
async fn danmaku_search(
    state: State<'_, AppState>,
    keyword: String,
) -> Result<Vec<danmaku::DanmakuSourceGroup>, String> {
    let sources = require_danmaku_sources(&state)?;
    Ok(danmaku::search_all_grouped(&state.http, &sources, &keyword).await)
}

/// 智能匹配:按标题/集号/文件名多源并行匹配,返回候选(带评分)供自动或手动挑。
#[tauri::command]
async fn danmaku_match(
    state: State<'_, AppState>,
    input: danmaku::MatchInput,
) -> Result<Vec<danmaku::DanmakuMatchCandidate>, String> {
    let sources = require_danmaku_sources(&state)?;
    Ok(danmaku::match_all(&state.http, &sources, &input).await)
}

/// 自动匹配的分数门槛(前端据此决定「自动挂上」还是「让用户挑」)。
#[tauri::command]
fn danmaku_min_auto_score() -> f64 {
    danmaku::MIN_AUTO_SCORE
}

/// 取某集弹幕评论(走缓存)。preferred_source 指定用哪个源;不指定则按 priority 依次试。
#[tauri::command]
async fn danmaku_load(
    state: State<'_, AppState>,
    episode_id: String,
    source_id: Option<String>,
    ch_convert: Option<i32>,
) -> Result<Vec<DanmakuComment>, String> {
    let sources = require_danmaku_sources(&state)?;
    Ok(danmaku::get_comments_from_all(
        &state.http,
        &sources,
        &episode_id,
        source_id.as_deref(),
        ch_convert.unwrap_or(0),
    )
    .await)
}

/// 播放开始时自动匹配并挂弹幕。对齐 Dart DanmakuAutoLoader。
///
/// 返回 None = 没自动挂(没匹配上 / 分数不够 / 取到空弹幕)。这不是错误:
/// 给非动漫内容硬塞错配弹幕比不挂更糟,用户仍可手动搜索。
///
/// 快路径:弹弹Play 同一作品的 episodeId 是连号的(第 N 集 +1 = 第 N+1 集)。
/// 追番看下一集时直接 +1 取,省一次 match 往返。猜错(跨季/特殊编号)会取到空弹幕,
/// 自动退回全量匹配 —— 所以「取到非空」就是这条快路径的兜底校验,别去掉。
///
/// `anchor_key`:剧集锚点键(seriesId|seasonId);网盘/无剧集上下文传 None 即关掉快路径。
#[tauri::command]
async fn danmaku_auto_load(
    state: State<'_, AppState>,
    input: danmaku::MatchInput,
    options: danmaku::FilterOptions,
    ch_convert: Option<i32>,
    anchor_key: Option<String>,
) -> Result<Option<Vec<DanmakuComment>>, String> {
    let sources = require_danmaku_sources(&state)?;
    let ch = ch_convert.unwrap_or(0);
    let finish = |raw: Vec<DanmakuComment>| danmaku::apply_filter_and_dedup(raw, &options);

    // 快路径:紧邻下一集。
    if let (Some(key), Some(ep)) = (anchor_key.as_ref(), input.episode_no) {
        let guess = {
            let anchors = state.danmaku_anchors.lock().unwrap();
            anchors.get(key).and_then(|(a_ep, a_id)| (ep == a_ep + 1).then_some(a_id + 1))
        };
        if let Some(gid) = guess {
            let raw = danmaku::get_comments_from_all(
                &state.http,
                &sources,
                &gid.to_string(),
                Some(DANDAN_OFFICIAL_SOURCE_ID),
                ch,
            )
            .await;
            if !raw.is_empty() {
                state
                    .danmaku_anchors
                    .lock()
                    .unwrap()
                    .insert(key.clone(), (ep, gid));
                return Ok(Some(finish(raw)));
            }
        }
    }

    let candidates = danmaku::match_all(&state.http, &sources, &input).await;
    let Some(best) = candidates.into_iter().next().filter(|c| c.score >= danmaku::MIN_AUTO_SCORE)
    else {
        return Ok(None);
    };
    let raw = danmaku::get_comments_from_all(
        &state.http,
        &sources,
        &best.episode_id,
        Some(&best.source_id),
        ch,
    )
    .await;
    if raw.is_empty() {
        return Ok(None);
    }
    // 只有官方源 + episodeId 是纯数字时才记锚点 —— 自建源的 id 未必连号,
    // 拿去 +1 会取到隔壁作品的弹幕(不报错,只是全篇对不上)。
    if best.source_id == DANDAN_OFFICIAL_SOURCE_ID {
        if let (Some(key), Some(ep), Ok(id)) =
            (anchor_key, input.episode_no, best.episode_id.parse::<i64>())
        {
            state.danmaku_anchors.lock().unwrap().insert(key, (ep, id));
        }
    }
    Ok(Some(finish(raw)))
}

/// 过滤 + 去重(屏蔽词/屏蔽用户/合并重复)。渲染参数不在这层 —— 那是前端的事。
#[tauri::command]
fn danmaku_filter(
    comments: Vec<DanmakuComment>,
    options: danmaku::FilterOptions,
) -> Vec<DanmakuComment> {
    danmaku::apply_filter_and_dedup(comments, &options)
}

/// 导入弹弹Play 导出的屏蔽词 XML。
#[tauri::command]
fn danmaku_import_blocklist(xml: String) -> danmaku::DanmakuFilterImportResult {
    danmaku::import_dandanplay_blocklist_xml(&xml)
}

#[tauri::command]
fn danmaku_cache_clear() -> usize {
    danmaku::cache_clear()
}

#[tauri::command]
fn danmaku_cache_size() -> u64 {
    danmaku::cache_disk_size_bytes()
}

/// 加载本地弹幕文件(xml / json / ass / ssa)。格式按**内容**嗅探,不只信扩展名 ——
/// 用户从别处存下来的弹幕改过名是常事。
///
/// 整文件解析失败返回 Err:绝不能返回空 Vec 假装成功,那会让用户看到
/// 「加载成功但一条弹幕都没有」然后无从排查。单条畸形则跳过。
#[tauri::command]
fn danmaku_load_local(path: String) -> Result<Vec<DanmakuComment>, String> {
    let p = std::path::Path::new(&path);
    let content = std::fs::read(p).map_err(|e| format!("读不到弹幕文件: {e}"))?;
    // 弹幕文件常见 GBK/UTF-16 编码,但 from_utf8_lossy 至少不会整个失败;
    // 真乱码时下面的解析会因为找不到 <d>/cues 而报错,不会静默返回空。
    let text = String::from_utf8_lossy(&content);
    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
    linplayer_core::danmaku::local::parse(name, &text)
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
    // 落盘:源和 Emby 共用同一张账号表 —— 重启免登 + 多源并存全靠这一步。
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.upsert(Account {
            server: server.id.clone(),
            user_name: server.username.clone().unwrap_or_else(|| format!("{kind:?}")),
            source_kind: kind,
            source: Some(server.clone()),
            ..Default::default()
        });
        cfg.save();
    }
    *state.source.lock().unwrap() = Some((kind, server));
    *state.session.lock().unwrap() = None; // 切到源 → 上一个 Emby 会话作废
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
    raw: Option<serde_json::Value>,
) -> Result<f64, String> {
    *state.scrobble_ctx.lock().unwrap() = None; // 源播放非 Emby,清 Trakt scrobble 上下文
    *state.wh_ctx.lock().unwrap() = None; // 同理清观看记录上下文,别把网盘进度记到上一部 Emby 片上
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    let backend = source_backend(&state, kind)?;
    let entry = SourceEntry {
        id: entry_id,
        name: entry_name,
        is_dir: false,
        is_video: true,
        size: None,
        thumb_url: None,
        raw, // 透传源原始数据(ani-rss 外挂字幕等靠它)
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
        // 挂外挂字幕(URL 自鉴权的源,如 ani-rss ?s=token)
        for sub in &resolved.subtitles {
            p.add_subtitle(&sub.url, sub.title.as_deref().unwrap_or("字幕"));
        }
    }
    *state.playback.lock().unwrap() = None; // 网盘源不走 Emby 上报
    *state.source_play_entry.lock().unwrap() = Some((entry.id.clone(), entry.name.clone()));
    state.resign_count.store(0, Ordering::Relaxed);
    Ok(resume_secs)
}

// ---------- 夸克 TV 扫码登录 ----------
#[derive(serde::Serialize)]
struct QuarkScan {
    device_id: String,
    qr_data: String,
    query_token: String,
}

/// 起扫码:生成 device_id,拿二维码内容 + query_token。
#[tauri::command]
async fn quark_scan_start(state: State<'_, AppState>) -> Result<QuarkScan, String> {
    let device_id = quark_tv::gen_device_id();
    let (qr_data, query_token) = quark_tv::get_login_code(&state.http, &device_id)
        .await
        .map_err(|e| e.message)?;
    Ok(QuarkScan { device_id, qr_data, query_token })
}

/// 轮询扫码结果:用户确认后拿 code→换 refresh_token→建立夸克 TV 源为活跃源。
/// 返回 true=登录成功;false=尚未确认(继续轮询)。
#[tauri::command]
async fn quark_scan_poll(
    state: State<'_, AppState>,
    device_id: String,
    query_token: String,
) -> Result<bool, String> {
    let code = match quark_tv::get_code(&state.http, &device_id, &query_token).await {
        Ok(c) if !c.is_empty() => c,
        _ => return Ok(false), // 未确认/接口报错 -> 继续轮询
    };
    let (_access, refresh) = quark_tv::exchange_token(&state.http, &device_id, &code, false)
        .await
        .map_err(|e| e.message)?;
    let mut extra = HashMap::new();
    extra.insert("device_id".to_string(), device_id);
    extra.insert("refresh_token".to_string(), refresh);
    let server = SourceServer {
        id: "quark-tv".to_string(),
        base_url: String::new(),
        username: None,
        password: None,
        token: None,
        extra,
    };
    *state.source.lock().unwrap() = Some((SourceKind::Quark, server));
    Ok(true)
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

// ---------- Ani-RSS 管理命令 ----------
// 对齐 core `AniRssBackend` 的管理接口全集(Dart AniRssApi 的移植)。
//
// 为什么 Ani/Config 参数一律 serde_json::Value:core 注释已写明 —— Ani 55 字段、Config ~123
// 字段且随服务端版本增删,addAni/setAni/setConfig 都要把**整个对象**原样回传;在宿主层收窄成
// struct 会把未覆盖字段静默丢掉(用户的服务端设置直接被抹)。故 Value 进 Value 出,字段取舍
// 留给 UI(与 Dart 同构)。
type Json = serde_json::Value;

/// 取(ani-rss 后端 + 当前服务器)。当前活跃源不是 ani-rss 时直接报错 —— 管理接口只对 ani-rss 有意义。
fn anirss_ctx(state: &State<'_, AppState>) -> Result<(Arc<AniRssBackend>, SourceServer), String> {
    let (kind, server) = state.source.lock().unwrap().clone().ok_or("未登录源")?;
    if kind != SourceKind::Anirss {
        return Err("当前源不是 Ani-RSS".to_string());
    }
    Ok((state.anirss.clone(), server))
}

// ---- 浏览 / 详情 ----

#[tauri::command]
async fn anirss_list_ani(state: State<'_, AppState>) -> Result<Vec<Json>, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.list_ani(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_play_list(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.play_list(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_themoviedb_group(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_themoviedb_group(&state.http, &s, ani).await.map_err(|e| e.message)
}

// ---- 下载进度 ----

#[tauri::command]
async fn anirss_torrents_infos(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.torrents_infos(&state.http, &s).await.map_err(|e| e.message)
}

// ---- 订阅管理 ----

#[tauri::command]
async fn anirss_search_bgm(state: State<'_, AppState>, name: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.search_bgm(&state.http, &s, &name).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_ani_by_subject_id(state: State<'_, AppState>, id: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_ani_by_subject_id(&state.http, &s, &id).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_add_ani(state: State<'_, AppState>, ani: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.add_ani(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_set_ani(state: State<'_, AppState>, ani: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.set_ani(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_delete_ani(
    state: State<'_, AppState>,
    ids: Vec<String>,
    delete_files: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.delete_ani(&state.http, &s, &ids, delete_files).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_refresh_ani(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.refresh_ani(&state.http, &s, &id).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_refresh_all(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.refresh_all(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_update_total_episode_number(
    state: State<'_, AppState>,
    ids: Vec<String>,
    force: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.update_total_episode_number(&state.http, &s, &ids, force).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_batch_enable(
    state: State<'_, AppState>,
    ids: Vec<String>,
    value: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.batch_enable(&state.http, &s, &ids, value).await.map_err(|e| e.message)
}

// ---- 设置 / 关于 ----

#[tauri::command]
async fn anirss_get_config(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_config(&state.http, &s).await.map_err(|e| e.message)
}

/// 回写设置。前端**必须**回传 anirss_get_config 拿到的完整 map 改字段后的结果,否则丢字段。
#[tauri::command]
async fn anirss_set_config(state: State<'_, AppState>, config: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.set_config(&state.http, &s, config).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_about(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.about(&state.http, &s).await.map_err(|e| e.message)
}

// ---- 订阅预览 / 标题解析 / 刮削 / 下载位置 ----

#[tauri::command]
async fn anirss_preview_ani(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.preview_ani(&state.http, &s, ani).await.map_err(|e| e.message)
}

/// 从 previewAni 的返回里提取条目列表(服务端装 List 的 key 不定,core 按形状找)。纯解析,不发请求。
#[tauri::command]
fn anirss_preview_items(preview: Json) -> Vec<Json> {
    linplayer_core::source::anirss::preview_items(&preview)
}

#[tauri::command]
async fn anirss_download_path(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.download_path(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_bgm_title(state: State<'_, AppState>, ani: Json) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_bgm_title(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_themoviedb_name(state: State<'_, AppState>, ani: Json) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_themoviedb_name(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_refresh_cover(state: State<'_, AppState>, ani: Json) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.refresh_cover(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_scrape(state: State<'_, AppState>, ani: Json, force: bool) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.scrape(&state.http, &s, ani, force).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_batch_scrape(
    state: State<'_, AppState>,
    ids: Vec<String>,
    force: bool,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.batch_scrape(&state.http, &s, &ids, force).await.map_err(|e| e.message)
}

// ---- BGM 评分 / 账号 ----

#[tauri::command]
async fn anirss_rate(state: State<'_, AppState>, ani: Json) -> Result<i64, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.rate(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_set_rate(state: State<'_, AppState>, ani: Json) -> Result<i64, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.set_rate(&state.http, &s, ani).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_me_bgm(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.me_bgm(&state.http, &s).await.map_err(|e| e.message)
}

// ---- 多搜索源(添加订阅):Mikan / AniBT / AnimeGarden ----

#[tauri::command]
async fn anirss_mikan(
    state: State<'_, AppState>,
    text: String,
    season: Option<Json>,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.mikan(&state.http, &s, &text, season).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_mikan_group(state: State<'_, AppState>, url: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.mikan_group(&state.http, &s, &url).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_ani_bt(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.ani_bt(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_ani_bt_group(state: State<'_, AppState>, bgm_id: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.ani_bt_group(&state.http, &s, &bgm_id).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_anime_garden_list(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.anime_garden_list(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_anime_garden_group(state: State<'_, AppState>, bgm_id: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.anime_garden_group(&state.http, &s, &bgm_id).await.map_err(|e| e.message)
}

/// 由 RSS 生成订阅 Ani(之后 anirss_add_ani 添加)。kind = mikan/ani-bt/anime-garden/other。
#[tauri::command]
async fn anirss_rss_to_ani(
    state: State<'_, AppState>,
    url: String,
    kind: String,
    bgm_url: Option<String>,
    subgroup: String,
    enable: bool,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.rss_to_ani(&state.http, &s, &url, &kind, bgm_url.as_deref(), &subgroup, enable)
        .await
        .map_err(|e| e.message)
}

// ---- 播放:字幕 ----

/// 取某文件的字幕。filename = PlayItem.filename 的 base64 原文(**勿再编码**)。
#[tauri::command]
async fn anirss_get_subtitles(state: State<'_, AppState>, filename: String) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_subtitles(&state.http, &s, &filename).await.map_err(|e| e.message)
}

// ---- 诊断 / 日志 / 维护 ----

#[tauri::command]
async fn anirss_logs(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.logs(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_download_logs(state: State<'_, AppState>) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.download_logs(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_clear_logs(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.clear_logs(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_clear_cache(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.clear_cache(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_ping(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.ping(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_download_login_test(state: State<'_, AppState>, config: Json) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.download_login_test(&state.http, &s, config).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_test_proxy(
    state: State<'_, AppState>,
    url: String,
    config: Json,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.test_proxy(&state.http, &s, &url, config).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_test_ip_whitelist(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.test_ip_whitelist(&state.http, &s).await.map_err(|e| e.message)
}

/// 触发服务端自更新(升级 ani-rss 本体)。
#[tauri::command]
async fn anirss_server_update(state: State<'_, AppState>) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.server_update(&state.http, &s).await.map_err(|e| e.message)
}

/// 停止/重启服务(status 由服务端定义,0 通常为停止)。
#[tauri::command]
async fn anirss_stop(state: State<'_, AppState>, status: i64) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.stop(&state.http, &s, status).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_new_notification(state: State<'_, AppState>) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.new_notification(&state.http, &s).await.map_err(|e| e.message)
}

#[tauri::command]
async fn anirss_get_emby_views(
    state: State<'_, AppState>,
    notification_config: Json,
) -> Result<Json, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.get_emby_views(&state.http, &s, notification_config).await.map_err(|e| e.message)
}

/// 导出设置的下载 URL(带令牌;交给浏览器/系统打开)。
#[tauri::command]
async fn anirss_export_config_url(state: State<'_, AppState>) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.export_config_url(&state.http, &s).await.map_err(|e| e.message)
}

/// 导入设置(bytes = 配置文件字节;前端用 File.arrayBuffer() 传数字数组)。
#[tauri::command]
async fn anirss_import_config(
    state: State<'_, AppState>,
    bytes: Vec<u8>,
    filename: String,
) -> Result<(), String> {
    let (b, s) = anirss_ctx(&state)?;
    b.import_config(&state.http, &s, &bytes, &filename).await.map_err(|e| e.message)
}

/// 经服务端代理取图的 URL(TMDB 相对路径等)。
#[tauri::command]
async fn anirss_proxy_image_url(state: State<'_, AppState>, img_url: String) -> Result<String, String> {
    let (b, s) = anirss_ctx(&state)?;
    b.proxy_image_url(&state.http, &s, &img_url).await.map_err(|e| e.message)
}

/// 清 token 缓存(重新登录前调;下次请求会用账密重登)。
#[tauri::command]
fn anirss_clear_token(state: State<'_, AppState>, server_id: String) {
    state.anirss.clear_token(&server_id);
}

// ---------- CF 优选反代命令 ----------
/// 跑 CF 优选测速,返回排好序的候选 IP(最优在前)。validate_host 传 Emby 域名可剔除
/// 「TCP 通但 HTTP 死」的边缘;传 None/空则跳过 HTTP 校验。
#[tauri::command]
async fn cf_speed_test(
    validate_host: Option<String>,
    test_url: Option<String>,
) -> Result<Vec<linplayer_core::net::cf::CfTestResult>, String> {
    let mut o = linplayer_core::net::cf::CfSpeedTestOptions::default();
    if let Some(h) = validate_host {
        o.validate_host = h;
    }
    if let Some(u) = test_url.filter(|s| !s.is_empty()) {
        o.test_url = u;
    }
    Ok(linplayer_core::net::cf::speed_test(o).await)
}

/// 活跃会话的基址跟随当前生效线路(含 CF 改写)重新对齐。
/// 开关反代后必须调:否则改写只对**之后**新建的会话生效,当前这条还打老地址 ——
/// 表现为"开了优选没反应,重启才生效"。
fn refresh_session_base(state: &AppState, server_id: &str) {
    let cfg = state.config.lock().unwrap();
    let is_active = cfg.active_account().map(|a| a.server == server_id).unwrap_or(false);
    if !is_active {
        return;
    }
    if let Some(url) = cfg.find(server_id).map(|a| a.active_line_url()) {
        if let Some(s) = state.session.lock().unwrap().as_mut() {
            s.server = url;
        }
    }
}

/// 为某台服务器开启 CF 优选反代,并**登记路由改写** —— 之后该服的 `active_line_url()`
/// 返回本地反代基址,Emby API / 封面图 / mpv 取流全部自动改走优选 IP。
/// 已开则热切换 IP(端口与本地基址不变,对进行中的会话无感)。
#[tauri::command]
async fn cf_proxy_enable(
    state: State<'_, AppState>,
    server_id: String,
    ip: String,
) -> Result<String, String> {
    // 已开 → 只热切 IP。注意别在持锁期间 await。
    let existing = {
        let m = state.cf_proxy.lock().unwrap();
        m.get(&server_id).map(|h| h.port)
    };
    if existing.is_some() {
        let handle = state.cf_proxy.lock().unwrap().remove(&server_id);
        if let Some(h) = handle {
            h.update_ip(ip).await;
            let url = cf::runtime::local_url_for(&server_id).unwrap_or_default();
            state.cf_proxy.lock().unwrap().insert(server_id, h);
            return Ok(url);
        }
    }

    let (upstream, allow_insecure) = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.find(&server_id).ok_or("找不到该服务器")?;
        // 上游必须用 direct_line_url:用 active_line_url 会在反代已开时把反代自己当上游,
        // 打成 127.0.0.1 → 127.0.0.1 的自环。
        (a.direct_line_url().to_string(), a.allow_insecure_tls)
    };
    let (scheme, host, port) = cf::runtime::split_upstream(&upstream);
    let handle = linplayer_core::net::cf::start_proxy(scheme, host, port, ip, allow_insecure)
        .await
        .ok_or("CF 反代起服失败(IP 非法?)")?;
    let local = cf::runtime::local_base(&upstream, handle.port);
    cf::runtime::bind(&server_id, &local);
    state.cf_proxy.lock().unwrap().insert(server_id.clone(), handle);
    refresh_session_base(&state, &server_id);
    Ok(local)
}

/// 关闭某服的反代,撤销路由改写,恢复直连原线路。
#[tauri::command]
fn cf_proxy_disable(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    cf::runtime::unbind(&server_id);
    state.cf_proxy.lock().unwrap().remove(&server_id); // Drop 停服
    refresh_session_base(&state, &server_id);
    Ok(())
}

#[derive(serde::Serialize)]
struct CfProxyStatus {
    server_id: String,
    local_url: String,
    pinned_ip: String,
}

/// 当前所有生效的反代改写(设置页展示"哪台服在走优选、钉的哪个 IP")。
#[tauri::command]
async fn cf_proxy_status(state: State<'_, AppState>) -> Result<Vec<CfProxyStatus>, String> {
    let ports: Vec<(String, String)> = cf::runtime::all().into_iter().collect();
    let mut out = Vec::new();
    for (server_id, local_url) in ports {
        // pinned_ip 要 await,不能在持锁时取;先把句柄摘出来问完再放回。
        let handle = state.cf_proxy.lock().unwrap().remove(&server_id);
        let pinned_ip = match handle {
            Some(h) => {
                let ip = h.pinned_ip().await;
                state.cf_proxy.lock().unwrap().insert(server_id.clone(), h);
                ip
            }
            None => String::new(),
        };
        out.push(CfProxyStatus { server_id, local_url, pinned_ip });
    }
    Ok(out)
}

// ---------- 多线程下载命令 ----------
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
fn download_list(
    state: State<'_, AppState>,
) -> Vec<linplayer_core::download::DownloadItem> {
    state.download.list()
}

#[tauri::command]
fn download_pause(state: State<'_, AppState>, id: String) {
    state.download.pause(&id);
}

#[tauri::command]
fn download_resume(state: State<'_, AppState>, id: String) {
    state.download.resume(&id);
}

#[tauri::command]
fn download_remove(state: State<'_, AppState>, id: String) {
    state.download.remove(&id);
}

/// 批量清除已完成的下载记录(下载页「清除已完成」)。返回清掉的条数。
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
    let n = done.len();
    for id in done {
        state.download.remove(&id);
    }
    n
}

/// 多线程加载(预取代理)设置。threads 引擎内部 clamp 到 2~4。
#[derive(serde::Serialize, serde::Deserialize)]
struct PrefetchSettings {
    enabled: bool,
    threads: usize,
    cache_bytes: u64,
}

#[tauri::command]
fn get_prefetch_settings(state: State<'_, AppState>) -> PrefetchSettings {
    let p = &state.config.lock().unwrap().prefs;
    PrefetchSettings {
        enabled: p.prefetch_enabled,
        threads: p.prefetch_threads,
        cache_bytes: p.prefetch_cache_bytes,
    }
}

#[tauri::command]
fn set_prefetch_settings(
    state: State<'_, AppState>,
    settings: PrefetchSettings,
) -> Result<(), String> {
    // 引擎会 clamp(2,4),但在这儿拒掉才有反馈 —— 悄悄 clamp 会让用户以为设了 8 线程生效了。
    if !(2..=4).contains(&settings.threads) {
        return Err("预取线程数只支持 2~4".into());
    }
    if settings.cache_bytes < 16 * 1024 * 1024 {
        return Err("读前缓冲上限不能低于 16MB".into());
    }
    let mut cfg = state.config.lock().unwrap();
    cfg.prefs.prefetch_enabled = settings.enabled;
    cfg.prefs.prefetch_threads = settings.threads;
    cfg.prefs.prefetch_cache_bytes = settings.cache_bytes;
    cfg.save();
    Ok(())
}

#[tauri::command]
fn download_set_threads(state: State<'_, AppState>, threads: usize) {
    state.download.set_threads(threads);
}

/// 播放已下载完成的本地文件(下载页 ▶)。离线可用:不碰网络、不走 Emby 上报。
/// 返回起播秒数供前端定位进度条。
#[tauri::command]
fn play_local(state: State<'_, AppState>, id: String, resume_secs: f64) -> Result<f64, String> {
    let path = state.download.completed_path(&id).ok_or("该任务尚未下载完成")?;
    // 索引说完成了不代表文件还在(用户可能手动删了/挪走了)——放给 mpv 之前先确认。
    if !std::path::Path::new(&path).is_file() {
        return Err(format!("文件已不存在:{path}"));
    }
    poclog(&format!("PLAY LOCAL id={id} path={path}"));
    {
        let guard = state.player.lock().unwrap();
        let p = guard.as_ref().ok_or("播放器未就绪")?;
        let _ = p.take_error_eof();
        p.load_at(&path, resume_secs)?;
        p.set_pause(false);
    }
    *state.playback.lock().unwrap() = None; // 本地文件不走 Emby 上报
    *state.source_play_entry.lock().unwrap() = None; // 非源播放,停 302 看门狗
    *state.scrobble_ctx.lock().unwrap() = None;
    *state.wh_ctx.lock().unwrap() = None; // 本地文件无 Emby 条目,清观看记录上下文
    state.resign_count.store(0, Ordering::Relaxed);
    Ok(resume_secs)
}

// ---------- Trakt 同步命令 ----------
use linplayer_core::sync::trakt;

/// 设备码登录第一步:申请设备码(展示 verification_url + user_code 给用户浏览器授权)。
#[tauri::command]
async fn trakt_device_code() -> Result<trakt::TraktDeviceCode, String> {
    trakt::request_device_code().await
}

/// 轮询一次;授权成功则持久化账号。前端按 interval 反复调,直到非 pending/slowDown。
#[tauri::command]
async fn trakt_poll(
    state: State<'_, AppState>,
    device_code: String,
) -> Result<trakt::TraktPollResult, String> {
    let r = trakt::poll_once(&device_code).await;
    if let Some(acc) = &r.account {
        let mut cfg = state.config.lock().unwrap();
        cfg.sync_trakt = Some(acc.clone());
        cfg.save();
    }
    Ok(r)
}

/// 当前已连接的 Trakt 账号(None=未连接)。
#[tauri::command]
fn trakt_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_trakt.clone()
}

#[tauri::command]
fn trakt_logout(state: State<'_, AppState>) {
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_trakt = None;
    cfg.save();
}

/// Scrobble 一次(start/pause/stop);ids 如 {"imdb":"tt..","tmdb":123}。未连接返回 false。
#[tauri::command]
async fn trakt_scrobble(
    state: State<'_, AppState>,
    type_: String,
    ids: serde_json::Value,
    progress: f64,
    action: String,
) -> Result<bool, String> {
    let acc = state.config.lock().unwrap().sync_trakt.clone();
    let Some(acc) = acc else { return Ok(false) };
    Ok(trakt::scrobble(&acc, &type_, ids, progress, &action).await)
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

// ---------- Bangumi 同步命令 ----------
use linplayer_core::sync::bangumi;
use linplayer_core::sync::bangumi_matcher;

/// 播放看完(≥80%)自动标 Bangumi:反查 subject/episode → 收藏为「在看」→ 单集标「看过」。
/// 反查失败(非番剧/搜不到)静默跳过。更新单集前必须先收藏,否则未收藏的番更新会失败。
async fn mark_bangumi_watched(acc: &linplayer_core::sync::SyncAccount, info: &emby::ScrobbleInfo) {
    let matched = if info.media_type == "movie" {
        bangumi_matcher::resolve_movie(&info.title, info.original_title.as_deref(), info.air_date.as_deref()).await
    } else {
        bangumi_matcher::resolve_episode(
            &info.title,
            info.original_title.as_deref(),
            info.air_date.as_deref(),
            info.season,
            info.episode,
        )
        .await
    };
    let Some(r) = matched else { return };
    // 先确保条目已收藏(3=在看),再标单集看过(2)。
    bangumi::set_collection_type(acc, r.subject_id, 3).await;
    bangumi::update_episode_status(acc, r.subject_id, r.episode_id, 2).await;
}

/// 构造 Bangumi 授权页 URL(前端用浏览器打开,用户授权后粘贴 code 回来)。
#[tauri::command]
fn bangumi_authorize_url(redirect_uri: Option<String>) -> String {
    let uri = redirect_uri.unwrap_or_else(|| bangumi::DEFAULT_REDIRECT_URI.to_string());
    bangumi::build_authorize_url(&uri)
}

/// 用粘贴回来的授权码换令牌并持久化。
#[tauri::command]
async fn bangumi_exchange(
    state: State<'_, AppState>,
    code: String,
    redirect_uri: Option<String>,
) -> Result<linplayer_core::sync::SyncAccount, String> {
    let uri = redirect_uri.unwrap_or_else(|| bangumi::DEFAULT_REDIRECT_URI.to_string());
    let acc = bangumi::exchange_code(&code, &uri).await?;
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.sync_bangumi = Some(acc.clone());
        cfg.save();
    }
    Ok(acc)
}

#[tauri::command]
fn bangumi_account(state: State<'_, AppState>) -> Option<linplayer_core::sync::SyncAccount> {
    state.config.lock().unwrap().sync_bangumi.clone()
}

#[tauri::command]
fn bangumi_logout(state: State<'_, AppState>) {
    let mut cfg = state.config.lock().unwrap();
    cfg.sync_bangumi = None;
    cfg.save();
}

/// 设置条目收藏(type:1想看2看过3在看4搁置5抛弃)。更新单集前须先收藏。
#[tauri::command]
async fn bangumi_set_collection(
    state: State<'_, AppState>,
    subject_id: i64,
    type_: i32,
) -> Result<bool, String> {
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    let Some(acc) = acc else { return Ok(false) };
    Ok(bangumi::set_collection_type(&acc, subject_id, type_).await)
}

/// 更新单集观看状态(type:2看过)。
#[tauri::command]
async fn bangumi_update_episode(
    state: State<'_, AppState>,
    subject_id: i64,
    episode_id: i64,
    type_: Option<i32>,
) -> Result<bool, String> {
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    let Some(acc) = acc else { return Ok(false) };
    Ok(bangumi::update_episode_status(&acc, subject_id, episode_id, type_.unwrap_or(2)).await)
}

#[tauri::command]
async fn bangumi_calendar(
    state: State<'_, AppState>,
    only_mine: Option<bool>,
) -> Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String> {
    let acc = state.config.lock().unwrap().sync_bangumi.clone();
    let Some(acc) = acc else { return Ok(vec![]) };
    Ok(bangumi::fetch_anime_calendar(&acc, only_mine.unwrap_or(true)).await)
}

// ---------- 配置迁移(扫码搬服务器)命令 ----------
/// 导出当前所有账号为二维码载荷字符串(LPSYNC1:...);前端渲染成二维码,他机扫码导入。
/// 全程离线,载荷内账号凭据 AES 加密 + gzip。
#[tauri::command]
fn config_export_qr(state: State<'_, AppState>) -> String {
    let accounts = state.config.lock().unwrap().accounts.clone();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    linplayer_core::config_transfer::encode(&accounts, now)
}

/// 导入扫到的载荷:解码 → 按 server 合并进现有账号 → 落盘。返回导入的账号数。
#[tauri::command]
fn config_import_qr(state: State<'_, AppState>, payload: String) -> Result<usize, String> {
    let incoming = linplayer_core::config_transfer::decode(&payload)?;
    let count = incoming.len();
    let mut cfg = state.config.lock().unwrap();
    let merged = linplayer_core::config_transfer::merge(&cfg.accounts, incoming);
    cfg.accounts = merged;
    if cfg.active.is_none() && !cfg.accounts.is_empty() {
        cfg.active = Some(0);
    }
    cfg.save();
    Ok(count)
}

// ---------- 付费(爱发电)命令 ----------
/// 校验爱发电订单号(经已部署的 CF 代理,客户端不接触 afdian token)。软锁。
#[tauri::command]
async fn afdian_verify(
    order_no: String,
) -> Result<linplayer_core::sync::AfdianVerifyResult, String> {
    Ok(linplayer_core::sync::afdian_verify(&order_no).await)
}

// ---------- 排行榜命令 ----------
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

// ---------- 自定义代理命令 ----------
#[tauri::command]
fn get_proxy(state: State<'_, AppState>) -> linplayer_core::ProxyConfig {
    state.config.lock().unwrap().proxy.clone()
}

/// 保存代理配置并即时生效(新建的 HTTP 客户端全部带上;主 Emby 客户端下次重启完全生效)。
/// ponytail: state.http 是启动期单例,live 切换只覆盖新建客户端;彻底 live-rebuild 留待需要时。
#[tauri::command]
fn set_proxy(state: State<'_, AppState>, config: linplayer_core::ProxyConfig) -> Result<(), String> {
    http::set_proxy(config.proxy_url());
    {
        let mut cfg = state.config.lock().unwrap();
        cfg.proxy = config;
        cfg.save();
    }
    Ok(())
}

// ---------- 插件命令 ----------
#[tauri::command]
fn plugin_list(state: State<'_, AppState>) -> Result<Vec<serde_json::Value>, String> {
    Ok(plugins_mgr(&state)?.list())
}

#[tauri::command]
fn plugin_install(state: State<'_, AppState>, path: String) -> Result<serde_json::Value, String> {
    plugins_mgr(&state)?.install_ipk(&path)
}

#[tauri::command]
async fn plugin_enable(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.enable(&id).await
}

#[tauri::command]
async fn plugin_disable(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.disable(&id).await;
    Ok(())
}

#[tauri::command]
async fn plugin_uninstall(state: State<'_, AppState>, id: String) -> Result<(), String> {
    plugins_mgr(&state)?.uninstall(&id).await;
    Ok(())
}

/// 触发某扩展的 handler(actions/settingsPages 的入口按钮等)。
#[tauri::command]
async fn plugin_trigger(
    state: State<'_, AppState>,
    plugin_id: String,
    type_id: String,
    ext_id: String,
    args: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let args = args.unwrap_or_else(|| serde_json::json!([]));
    plugins_mgr(&state)?.trigger_extension(&plugin_id, &type_id, &ext_id, args).await
}

/// 触发扩展 data 里某具名字段的 handler(设置页的 load/submit)。
#[tauri::command]
async fn plugin_invoke_field(
    state: State<'_, AppState>,
    plugin_id: String,
    type_id: String,
    ext_id: String,
    field: String,
    args: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let args = args.unwrap_or_else(|| serde_json::json!([]));
    plugins_mgr(&state)?
        .invoke_extension_field(&plugin_id, &type_id, &ext_id, &field, args)
        .await
}

/// 取某类型全部扩展(前端渲染 homeStats/sidebarItems 等)。
#[tauri::command]
fn plugin_extensions(state: State<'_, AppState>, type_id: String) -> Result<Vec<serde_json::Value>, String> {
    Ok(plugins_mgr(&state)?.extensions_by_type(&type_id))
}

/// 前端回填一次 ctx.ui 请求(showForm 的返回值等)。value=null 视为取消。
#[tauri::command]
fn plugin_ui_respond(state: State<'_, AppState>, id: u64, value: Option<serde_json::Value>) {
    plugins_host::ui_respond(&state, id, value.unwrap_or(serde_json::Value::Null));
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 每次启动重注册 linplayer:// —— 绿色包用户挪了文件夹,老路径就是死的。
    register_deep_link_scheme();
    let config = AppConfig::load();
    // 先把代理写进全局,再建各 HTTP 客户端(含 Emby 主客户端/下载),使其启动即带代理。
    http::set_proxy(config.proxy.proxy_url());
    let http = http::client();

    // 源后端注册表(长驻,持各自 token 缓存)。逐 Phase 增量接入更多源。
    let mut source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>> = HashMap::new();
    source_backends.insert(SourceKind::Openlist, Arc::new(OpenListBackend::new()));
    // ani-rss 建一次、两处引用同一实例:注册表里当 dyn 走浏览/播放,AppState.anirss 里当具体类型
    // 走管理接口。clone 只加引用计数(不复制 token_cache),故两条路共用同一份登录令牌。
    let anirss = Arc::new(AniRssBackend::new());
    source_backends.insert(SourceKind::Anirss, anirss.clone());
    source_backends.insert(SourceKind::Feiniu, Arc::new(FeiniuBackend::new()));
    source_backends.insert(SourceKind::Quark, Arc::new(QuarkBackend::new()));

    // 有活跃账号 -> 用存盘凭据重建会话/源(重启免登)。
    // 活跃的是 Emby 就装 session,是浏览型源就装 source —— 两者互斥,别同时留着。
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

    // 下载目录:桌面便携场景放 exe 同级 downloads/。
    let download_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("downloads")))
        .unwrap_or_else(|| std::env::temp_dir().join("linplayer-downloads"));
    let download = tauri::async_runtime::block_on(
        linplayer_core::download::DownloadManager::new(download_dir),
    );

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
            anirss,
            source: Mutex::new(source),
            watch_history: linplayer_core::watch_history::WatchHistory::default(),
            series_tmdb: Mutex::new(HashMap::new()),
            wh_ctx: Mutex::new(None),
            source_play_entry: Mutex::new(None),
            resign_count: AtomicU32::new(0),
            prefetch: Mutex::new(None),
            cf_proxy: Mutex::new(HashMap::new()),
            account_status: Mutex::new(HashMap::new()),
            live_translate: Mutex::new(None),
            danmaku_anchors: Mutex::new(HashMap::new()),
            wh_done: Mutex::new(std::collections::HashSet::new()),
            download,
            scrobble_ctx: Mutex::new(None),
            plugins: OnceLock::new(),
            ui_pending: Mutex::new(HashMap::new()),
            ui_seq: AtomicU64::new(0),
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

            // 插件系统:host 持 AppHandle 落平台能力;基目录用应用配置目录。
            let base = app
                .path()
                .app_config_dir()
                .unwrap_or_else(|_| std::env::temp_dir().join("LinPlayer"))
                .join("plugins_root");
            let host = plugins_host::make_host(app.handle().clone());
            let mgr = PluginManager::new(base, host);
            let _ = app.state::<AppState>().plugins.set(mgr.clone());
            tauri::async_runtime::spawn(async move { mgr.init().await });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            login,
            current_session,
            aggregate_search,
            set_active_server,
            views,
            list_items,
            list_items_page,
            get_filters,
            set_played,
            test_connection,
            list_collections,
            list_next_up,
            search,
            list_latest,
            list_resume,
            list_random,
            item_detail,
            item_media,
            list_favorites,
            set_favorite,
            list_accounts,
            remove_account,
            update_account,
            reorder_accounts,
            set_lines,
            set_active_line,
            probe_accounts,
            startup_deep_link,
            account_icon,
            set_account_icon_file,
            clear_account_icon,
            batch_parse,
            parse_deep_link,
            batch_add_servers,
            probe_lines,
            current_source,
            play,
            report_progress,
            stop_playback,
            set_pause,
            seek,
            status,
            tracks,
            set_track,
            player_opts,
            set_speed,
            set_volume,
            set_mute,
            set_audio_delay,
            set_sub_delay,
            set_aspect_ratio,
            set_hwdec,
            set_sub_style,
            set_secondary_sub,
            set_secondary_sub_opts,
            add_subtitle,
            screenshot,
            shader_levels,
            set_shader_level,
            mpv_get,
            mpv_set,
            mpv_command,
            apply_prefs,
            get_prefs,
            set_prefs,
            source_login,
            source_list_dir,
            source_play,
            source_watchdog,
            quark_scan_start,
            quark_scan_poll,
            anirss_list_ani,
            anirss_play_list,
            anirss_get_themoviedb_group,
            anirss_torrents_infos,
            anirss_search_bgm,
            anirss_get_ani_by_subject_id,
            anirss_add_ani,
            anirss_set_ani,
            anirss_delete_ani,
            anirss_refresh_ani,
            anirss_refresh_all,
            anirss_update_total_episode_number,
            anirss_batch_enable,
            anirss_get_config,
            anirss_set_config,
            anirss_about,
            anirss_preview_ani,
            anirss_preview_items,
            anirss_download_path,
            anirss_get_bgm_title,
            anirss_get_themoviedb_name,
            anirss_refresh_cover,
            anirss_scrape,
            anirss_batch_scrape,
            anirss_rate,
            anirss_set_rate,
            anirss_me_bgm,
            anirss_mikan,
            anirss_mikan_group,
            anirss_ani_bt,
            anirss_ani_bt_group,
            anirss_anime_garden_list,
            anirss_anime_garden_group,
            anirss_rss_to_ani,
            anirss_get_subtitles,
            anirss_logs,
            anirss_download_logs,
            anirss_clear_logs,
            anirss_clear_cache,
            anirss_ping,
            anirss_download_login_test,
            anirss_test_proxy,
            anirss_test_ip_whitelist,
            anirss_server_update,
            anirss_stop,
            anirss_new_notification,
            anirss_get_emby_views,
            anirss_export_config_url,
            anirss_import_config,
            anirss_proxy_image_url,
            anirss_clear_token,
            get_danmaku_config,
            set_danmaku_config,
            danmaku_search,
            danmaku_load,
            danmaku_match,
            danmaku_min_auto_score,
            danmaku_filter,
            danmaku_import_blocklist,
            danmaku_cache_clear,
            danmaku_cache_size,
            danmaku_load_local,
            danmaku_auto_load,
            cf_speed_test,
            cf_proxy_enable,
            cf_proxy_disable,
            cf_proxy_status,
            download_enqueue,
            download_list,
            download_pause,
            download_resume,
            download_remove,
            download_set_threads,
            download_clear_completed,
            get_prefetch_settings,
            set_prefetch_settings,
            play_local,
            watch_history_list,
            watch_history_scan_restore,
            watch_history_restore_candidate,
            get_writeback_settings,
            set_writeback_settings,
            watch_history_clear,
            watch_history_delete,
            get_cross_server_resume,
            set_cross_server_resume,
            get_translation_settings,
            set_translation_settings,
            translation_engine_status,
            translate_live_start,
            translate_live_stop,
            translate_subtitle,
            whisper_models,
            whisper_download,
            whisper_delete,
            whisper_deps,
            whisper_download_ffmpeg,
            get_proxy,
            set_proxy,
            ranking_categories,
            ranking_fetch,
            afdian_verify,
            trakt_device_code,
            trakt_poll,
            trakt_account,
            trakt_logout,
            trakt_scrobble,
            trakt_calendar,
            bangumi_authorize_url,
            bangumi_exchange,
            bangumi_account,
            bangumi_logout,
            bangumi_set_collection,
            bangumi_update_episode,
            bangumi_calendar,
            config_export_qr,
            config_import_qr,
            plugin_list,
            plugin_install,
            plugin_enable,
            plugin_disable,
            plugin_uninstall,
            plugin_trigger,
            plugin_invoke_field,
            plugin_ui_respond,
            plugin_extensions,
            plugin_ui_respond
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
