import { invoke } from "@tauri-apps/api/core";

/* ============================================================
   Tauri 命令类型化封装 —— 前端调 Rust 核的唯一入口。
   所有页面走这里，不散落裸 invoke，改一处全端生效。
   Rust snake_case 参数 → JS camelCase(Tauri 自动转)。
   ============================================================ */

export type LoginResult = {
  server: string;
  token: string;
  user_id: string;
  user_name: string;
};

export type Item = {
  id: string;
  name: string;
  type_: string;
  is_folder: boolean;
  has_primary: boolean;
  runtime_secs: number;
  resume_secs: number;
  /** 剧集所属剧名(Episode.Name 只是「第 35 集」,混排列表靠它认剧)。 */
  series_name: string | null;
  episode_no: number | null;
  season_no: number | null;
  /** 以下三项仅分集列表(带 Fields=MediaSources)有值,用于卡片那行「2160p · 45M · 18.4G」。 */
  video_height: number | null;
  bitrate: number | null;
  size_bytes: number | null;
};

export type Person = {
  id: string;
  name: string;
  role: string | null;
  /** Director / Actor / Writer / Producer … */
  type_: string;
  has_primary: boolean;
};

export type StreamInfo = {
  index: number;
  type_: "Video" | "Audio" | "Subtitle";
  codec: string;
  profile: string | null;
  display_title: string | null;
  language: string | null;
  width: number | null;
  height: number | null;
  bitrate: number | null;
  channels: number | null;
  channel_layout: string | null;
  frame_rate: number | null;
  video_range: string | null;
  is_default: boolean;
};

export type MediaVersion = {
  id: string;
  name: string;
  container: string | null;
  size_bytes: number | null;
  bitrate: number | null;
  runtime_secs: number;
  streams: StreamInfo[];
};

/** 列表卡片标题:剧集补上剧名,否则「第 35 集」单看不知是哪部。 */
export function itemLabel(it: Item): string {
  return it.type_ === "Episode" && it.series_name
    ? `${it.series_name} · ${it.name}`
    : it.name;
}

export type ItemDetail = {
  id: string;
  name: string;
  type_: string;
  overview: string;
  year: number | null;
  genres: string[];
  rating: number | null;
  runtime_secs: number;
  resume_secs: number;
  has_primary: boolean;
  has_backdrop: boolean;
  is_favorite: boolean;
  series_name: string | null;
  series_id: string | null;
  season_no: number | null;
  episode_no: number | null;
  children: Item[];
  people: Person[];
};

export type Status = {
  time: number;
  duration: number;
  paused: boolean;
  buffered: number;
};

export type Track = {
  kind: string;
  id: string;
  title: string;
  lang: string;
  selected: boolean;
};

export type Prefs = {
  audio_lang: string | null;
  sub_lang: string | null;
  sub_enabled: boolean;
};

export type SourceEntry = {
  id: string;
  name: string;
  is_dir: boolean;
  is_video: boolean;
  size: number | null;
  thumb_url: string | null;
  raw?: unknown;
};

export type ServerGroup = {
  server_id: string;
  server_name: string;
  items: Item[];
};

export type AccountInfo = {
  server: string;
  user_name: string;
  user_id: string;
  active: boolean;
};

export type DownloadStatus =
  | "Queued"
  | "Downloading"
  | "Paused"
  | "Completed"
  | "Failed"
  | "Canceled";

export type DownloadItem = {
  id: string;
  item_id: string;
  type: string;
  title: string;
  series_id: string | null;
  series_name: string | null;
  season_number: number | null;
  episode_number: number | null;
  poster_url: string | null;
  container: string;
  file_path: string;
  total_bytes: number;
  received_bytes: number;
  progress: number; // 0..1
  status: DownloadStatus;
  error: string | null;
  added_at: number;
};

export type RankingCategory = {
  id: string;
  group: "anime" | "movie" | "tv";
  source: "dandan" | "tmdb";
  label: string;
};

export type RankingEntry = {
  source: "dandan" | "tmdb";
  id: string;
  title: string;
  rank: number;
  image_url: string | null;
  rating: number | null;
  subtitle: string | null;
  is_favorited: boolean;
  media_type: string | null;
};

export type ProxyConfig = {
  type: string; // none | http | https | socks5 | socks4
  host: string;
  port: number;
  username: string;
  password: string;
  proxy_media: boolean;
};

export type DanmakuServer = {
  api_url: string;
  auth_type: string; // none | pathToken | headerToken | queryToken
  token: string;
};

export type SyncAccount = {
  service: string;
  access_token: string;
  refresh_token: string | null;
  expires_at: number | null;
  username: string | null;
};

export type TraktDeviceCode = {
  device_code: string;
  user_code: string;
  verification_url: string;
  expires_in: number;
  interval: number;
};

export type TraktPollResult = {
  account: SyncAccount | null;
  status: string; // pending | authorized | ...
};

// ---------- Emby ----------
export const currentSession = () =>
  invoke<LoginResult | null>("current_session");

export const login = (server: string, username: string, password: string) =>
  invoke<LoginResult>("login", { server, username, password });

export const views = () => invoke<Item[]>("views");

export const listItems = (parentId: string) =>
  invoke<Item[]>("list_items", { parentId });

export const listLatest = (parentId: string, limit = 20) =>
  invoke<Item[]>("list_latest", { parentId, limit });

export const listResume = (limit = 20) =>
  invoke<Item[]>("list_resume", { limit });

export const itemDetail = (itemId: string) =>
  invoke<ItemDetail>("item_detail", { itemId });

// ---------- 播放器能力(对齐旧 Flutter video_player_service 契约) ----------
export type PlayerOpts = {
  speed: number;
  volume: number;
  muted: boolean;
  audio_delay: number;
  sub_delay: number;
  hwdec: string;
  shader_count: number;
};

/** OSD 一次拉齐当前可调项(别逐个 get)。 */
export const playerOpts = () => invoke<PlayerOpts>("player_opts");

export const setSpeed = (speed: number) => invoke<void>("set_speed", { speed });
export const setVolume = (volume: number) => invoke<void>("set_volume", { volume });
export const setMute = (mute: boolean) => invoke<void>("set_mute", { mute });
export const setAudioDelay = (secs: number) => invoke<void>("set_audio_delay", { secs });
export const setSubDelay = (secs: number) => invoke<void>("set_sub_delay", { secs });
/** "" / "auto" = 还原源比例;否则如 "16:9" / "4:3" / "2.35"。 */
export const setAspectRatio = (ratio: string) => invoke<void>("set_aspect_ratio", { ratio });
/** "auto-safe" / "d3d11va" / "no"(软解) 等。 */
export const setHwdec = (mode: string) => invoke<void>("set_hwdec", { mode });

/** 字幕样式,不传的项不动。 */
export const setSubStyle = (o: {
  font?: string;
  size?: number;
  position?: number;
  background?: boolean;
  blendMode?: string;
}) => invoke<void>("set_sub_style", o);

/** 次字幕(双字幕);id 为空 = 关。 */
export const setSecondarySub = (id: string) => invoke<void>("set_secondary_sub", { id });
export const setSecondarySubOpts = (o: { delay?: number; position?: number }) =>
  invoke<void>("set_secondary_sub_opts", o);

/** 加载外挂字幕(本地路径或 URL)。 */
export const addSubtitle = (url: string, title?: string, secondary?: boolean) =>
  invoke<void>("add_subtitle", { url, title, secondary });

/** 截图,返回落盘路径(dir 省略 → 图片/LinPlayer)。 */
export const screenshot = (dir?: string) => invoke<string>("screenshot", { dir });

/** 超分档位清单 [id, 显示名][]。 */
export const shaderLevels = () => invoke<[string, string][]>("shader_levels");
/** 应用超分档位,返回实际挂上的 shader 数;非 off 却返 0 会直接报错(超分没生效)。 */
export const setShaderLevel = (level: string) => invoke<number>("set_shader_level", { level });

/** mpv 属性直通(有专用命令的优先用专用命令)。 */
export const mpvGet = (name: string) => invoke<string | null>("mpv_get", { name });
export const mpvSet = (name: string, value: string) => invoke<void>("mpv_set", { name, value });
export const mpvCommand = (args: string[]) => invoke<void>("mpv_command", { args });

/** 首页 Hero 随机推荐(只返回有剧照的)。 */
export const listRandom = (limit = 5) =>
  invoke<Item[]>("list_random", { limit });

/** 条目的全部版本+流(详情页 版本/音轨/字幕 选择器 + 媒体信息块)。 */
export const itemMedia = (itemId: string) =>
  invoke<MediaVersion[]>("item_media", { itemId });

/** 人物头像。 */
export function personUrl(session: LoginResult, personId: string, maxHeight = 160): string {
  return `${session.server}/Items/${personId}/Images/Primary?maxHeight=${maxHeight}&quality=90&api_key=${session.token}`;
}

/** 字节数 → 「18.4 GB」。 */
export function fmtSize(bytes: number | null): string {
  if (!bytes || bytes <= 0) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}

/** 码率 bps → 「45.0M」/「256k」(草稿媒体信息卡的写法)。 */
export function fmtBitrate(bps: number | null): string {
  if (!bps || bps <= 0) return "";
  if (bps >= 1e6) return `${(bps / 1e6).toFixed(1)}M`;
  return `${Math.round(bps / 1e3)}k`;
}

/** 高度 → 「2160p」。 */
export function fmtRes(height: number | null): string {
  return height && height > 0 ? `${height}p` : "";
}

export const aggregateSearch = (query: string) =>
  invoke<ServerGroup[]>("aggregate_search", { query });

export const setActiveServer = (serverId: string) =>
  invoke<void>("set_active_server", { serverId });

// ---------- 播放 ----------
export const play = (itemId: string, resumeSecs: number) =>
  invoke<number>("play", { itemId, resumeSecs });

export const reportProgress = (pos: number, paused: boolean) =>
  invoke<void>("report_progress", { pos, paused }).catch(() => {});

export const stopPlayback = (pos: number) =>
  invoke<void>("stop_playback", { pos }).catch(() => {});

export const setPause = (paused: boolean) =>
  invoke<void>("set_pause", { paused });

export const seek = (pos: number) => invoke<void>("seek", { pos });

export const status = () => invoke<Status>("status");

export const tracks = () => invoke<Track[]>("tracks");

export const setTrack = (kind: string, id: string) =>
  invoke<void>("set_track", { kind, id });

export const applyPrefs = () =>
  invoke<[string | null, string | null]>("apply_prefs");

export const getPrefs = () => invoke<Prefs>("get_prefs");

export const setPrefs = (p: Prefs) =>
  invoke<void>("set_prefs", {
    audioLang: p.audio_lang,
    subLang: p.sub_lang,
    subEnabled: p.sub_enabled,
  });

// ---------- 网盘源 ----------
export const sourceLogin = (
  kind: string,
  baseUrl: string,
  username: string,
  password: string,
  cookie: string | null,
) => invoke<void>("source_login", { kind, baseUrl, username, password, cookie });

export const sourceListDir = (dirId: string | null) =>
  invoke<SourceEntry[]>("source_list_dir", { dirId });

export const sourcePlay = (entry: SourceEntry, resumeSecs: number) =>
  invoke<number>("source_play", {
    entryId: entry.id,
    entryName: entry.name,
    resumeSecs,
    raw: entry.raw ?? null,
  });

export const sourceWatchdog = (pos: number) =>
  invoke<boolean>("source_watchdog", { pos }).catch(() => false);

// ---------- 收藏 ----------
export const listFavorites = () => invoke<Item[]>("list_favorites");
export const setFavorite = (itemId: string, fav: boolean) =>
  invoke<void>("set_favorite", { itemId, fav });

// ---------- 多账号/服务器 ----------
export const listAccounts = () => invoke<AccountInfo[]>("list_accounts");
export const removeAccount = (serverId: string) =>
  invoke<void>("remove_account", { serverId });

// ---------- 排行榜 ----------
export const rankingCategories = () =>
  invoke<RankingCategory[]>("ranking_categories");
export const rankingFetch = (categoryId: string, forceRefresh = false) =>
  invoke<RankingEntry[]>("ranking_fetch", { categoryId, forceRefresh });

// ---------- 下载 ----------
export const downloadList = () => invoke<DownloadItem[]>("download_list");
export const downloadEnqueue = (
  itemId: string,
  type: string,
  title: string,
  container: string,
  posterUrl: string | null,
) => invoke<string>("download_enqueue", { itemId, type, title, container, posterUrl });
export const downloadPause = (id: string) => invoke<void>("download_pause", { id });
export const downloadResume = (id: string) => invoke<void>("download_resume", { id });
export const downloadRemove = (id: string) => invoke<void>("download_remove", { id });
export const downloadSetThreads = (threads: number) =>
  invoke<void>("download_set_threads", { threads });

// ---------- 代理 ----------
export const getProxy = () => invoke<ProxyConfig>("get_proxy");
export const setProxy = (config: ProxyConfig) => invoke<void>("set_proxy", { config });

// ---------- 弹幕源 ----------
export const getDanmakuConfig = () => invoke<DanmakuServer>("get_danmaku_config");
export const setDanmakuConfig = (apiUrl: string, authType: string, token: string) =>
  invoke<void>("set_danmaku_config", { apiUrl, authType, token });

// ---------- Trakt / Bangumi 同步 ----------
export const traktAccount = () => invoke<SyncAccount | null>("trakt_account");
export const traktDeviceCode = () => invoke<TraktDeviceCode>("trakt_device_code");
export const traktPoll = (deviceCode: string) =>
  invoke<TraktPollResult>("trakt_poll", { deviceCode });
export const traktLogout = () => invoke<void>("trakt_logout");
export const bangumiAccount = () => invoke<SyncAccount | null>("bangumi_account");
export const bangumiAuthorizeUrl = () => invoke<string>("bangumi_authorize_url", {});
export const bangumiExchange = (code: string) =>
  invoke<SyncAccount>("bangumi_exchange", { code });
export const bangumiLogout = () => invoke<void>("bangumi_logout");

// ---------- 追剧日历(付费解锁) ----------
export type CalendarEntry = {
  title: string;
  subtitle: string | null;
  /** 精确放送时刻 ISO8601(Trakt 有);为空时用 weekday 归组。 */
  air_date: string | null;
  /** 每周放送日 1=周一…7=周日(Bangumi 用)。 */
  weekday: number | null;
  image_url: string | null;
  tmdb_id: number | null;
  source: "trakt" | "bangumi";
};

export type AfdianVerifyResult = {
  valid: boolean;
  plan_title: string;
  amount: string;
  reason: string | null;
};

export const traktCalendar = (onlyMine: boolean) =>
  invoke<CalendarEntry[]>("trakt_calendar", { onlyMine });
export const bangumiCalendar = (onlyMine: boolean) =>
  invoke<CalendarEntry[]>("bangumi_calendar", { onlyMine });
export const afdianVerify = (orderNo: string) =>
  invoke<AfdianVerifyResult>("afdian_verify", { orderNo });

// ---------- 配置迁移(扫码搬服务器) ----------
export const configExportQr = () => invoke<string>("config_export_qr");
export const configImportQr = (payload: string) =>
  invoke<number>("config_import_qr", { payload });

// ---------- 图片 URL(直接从会话拼，免每图一次 invoke) ----------
export function posterUrl(
  session: LoginResult,
  itemId: string,
  maxHeight = 480,
): string {
  return `${session.server}/Items/${itemId}/Images/Primary?maxHeight=${maxHeight}&quality=90&api_key=${session.token}`;
}

/** 横向缩略图(剧集封面/媒体库封面用 Primary，按宽度取，不裁剪比例)。 */
export function thumbUrl(
  session: LoginResult,
  itemId: string,
  maxWidth = 640,
): string {
  return `${session.server}/Items/${itemId}/Images/Primary?maxWidth=${maxWidth}&quality=90&api_key=${session.token}`;
}

export function backdropUrl(
  session: LoginResult,
  itemId: string,
  maxWidth = 1600,
): string {
  return `${session.server}/Items/${itemId}/Images/Backdrop/0?maxWidth=${maxWidth}&quality=90&api_key=${session.token}`;
}

/** 格式化时长(秒 → h:mm:ss / m:ss)。 */
export function fmtTime(t: number): string {
  if (!isFinite(t) || t < 0) t = 0;
  const s = Math.floor(t % 60).toString().padStart(2, "0");
  const m = Math.floor((t / 60) % 60).toString().padStart(2, "0");
  const h = Math.floor(t / 3600);
  return h > 0 ? `${h}:${m}:${s}` : `${m}:${s}`;
}
