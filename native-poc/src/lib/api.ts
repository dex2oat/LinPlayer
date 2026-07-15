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
  /* 以下字段核层 emby::Item 一直在传,只是这份类型漏了 —— 漏了它们,
     海报评分角标/已看反显/本地排序就会被误判成「服务端不透传」。别再删。 */
  /** 已看(UserData.Played)。setPlayed 的反显靠它。 */
  played: boolean;
  genres: string[];
  year: number | null;
  rating: number | null;
  provider_ids: Record<string, string>;
  presentation_unique_key: string | null;
  path: string | null;
  series_id: string | null;
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

export type ServerLine = {
  id: string;
  name: string;
  url: string;
  remark: string | null;
};

export type SourceKind = "Emby" | "Openlist" | "Quark" | "Anirss" | "Feiniu";

/** 连通状态三态。unknown = 还没探过(按灰显示),与 down「探过确实不通」同色不同义。 */
export type AccountStatus = "ok" | "reauth" | "down" | "unknown";

export type AccountInfo = {
  server: string;
  user_name: string;
  user_id: string;
  /** 是否当前选中。**不是**连通状态 —— 状态看 status。 */
  active: boolean;
  /** 需先调 probeAccounts 刷新,否则恒为 unknown。 */
  status: AccountStatus;
  /** 显示名(用户起的名,空则回落 host)。 */
  name: string;
  remark: string | null;
  icon_url: string | null;
  lines: ServerLine[];
  active_line: number;
  /** 当前生效的上游线路(未经 CF 反代改写)。 */
  line_url: string;
  allow_insecure_tls: boolean;
  source_kind: SourceKind;
  /** 文件浏览型源(非 Emby)——据此决定进媒体库还是进文件浏览。 */
  is_file_browse: boolean;
};

export type LineProbe = {
  index: number;
  url: string;
  /** null = 该线路探测失败。 */
  ms: number | null;
};

export type ServerInfo = { name: string; version: string; id: string };

export type Filters = {
  genres: string[];
  tags: string[];
  years: number[];
  studios: string[];
  official_ratings: string[];
};

export type ItemPage = { items: Item[]; total: number };

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
  /** 稳定 id(增删改的身份键)。留空由核层用 api_url 补。 */
  id: string;
  /** 显示名;空则回落 host。 */
  name: string;
  api_url: string;
  auth_type: string; // none | pathToken | headerToken | queryToken
  token: string;
  enabled: boolean;
  /** 越小越先用。 */
  priority: number;
};

export type DanmakuEpisode = {
  episode_id: string;
  episode_title: string;
  episode_number: string | null;
};

export type DanmakuAnime = {
  anime_id: string;
  anime_title: string;
  type_: string | null;
  type_description: string | null;
  image_url: string | null;
  year: number | null;
  episode_count: number | null;
  episodes: DanmakuEpisode[];
};

/** 一源一组:单源失败只填 error,不拖累别的源。 */
export type DanmakuSourceGroup = {
  source_id: string;
  source_name: string;
  animes: DanmakuAnime[];
  matches: unknown[];
  error: string | null;
};

export type DanmakuMatchCandidate = {
  source_id: string;
  source_name: string;
  anime_id: string;
  anime_title: string;
  episode_id: string;
  episode_title: string;
  /** 越大越可信;与 danmakuMinAutoScore() 比较决定自动挂还是让用户挑。 */
  score: number;
};

export type DanmakuMatchInput = {
  /** 剧集用 seriesName,否则条目名。 */
  title: string;
  episode_no?: number | null;
  file_name?: string;
  file_hash?: string | null;
  file_size?: number | null;
  duration_secs?: number | null;
};

export type DanmakuFilterOptions = {
  blockwords: string[];
  user_blocklist: string[];
  /** 屏蔽类型(1=滚动 4=底 5=顶);空=不过滤。 */
  blocked_modes: number[];
  dedup: boolean;
  dedup_window: number;
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

/** 分页+服务端排序+服务端筛选(要总数/翻页/筛选一律走它,别用 listItems 全量拉)。 */
export const listItemsPage = (
  parentId: string,
  o: {
    startIndex?: number;
    limit?: number;
    sortBy?: string;
    sortOrder?: string;
    genres?: string[];
    tags?: string[];
    years?: number[];
    studios?: string[];
    ratingMin?: number;
    ratingMax?: number;
  } = {},
) =>
  invoke<ItemPage>("list_items_page", {
    parentId,
    startIndex: o.startIndex ?? null,
    limit: o.limit ?? null,
    sortBy: o.sortBy ?? null,
    sortOrder: o.sortOrder ?? null,
    genres: o.genres ?? null,
    tags: o.tags ?? null,
    years: o.years ?? null,
    studios: o.studios ?? null,
    ratingMin: o.ratingMin ?? null,
    ratingMax: o.ratingMax ?? null,
  });

/** 某库的真实筛选分面(类型/标签/年份/工作室/分级)—— 不是从已加载条目里猜。 */
export const getFilters = (parentId: string) =>
  invoke<Filters>("get_filters", { parentId });

/** 服务端搜索(带类型过滤+条数上限)。别再用「拉全库再本地 includes」代替。 */
export const search = (query: string, types?: string[], limit?: number) =>
  invoke<Item[]>("search", { query, types: types ?? null, limit: limit ?? null });

export const listCollections = () => invoke<Item[]>("list_collections");
export const listNextUp = (limit = 20) => invoke<Item[]>("list_next_up", { limit });

/** 标记已看/未看。played=false 亦即「移出继续观看」。 */
export const setPlayed = (itemId: string, played: boolean) =>
  invoke<void>("set_played", { itemId, played });

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
/** 画质档位 `[id, 显示名, 窗口模式是否也生效]`。
 *  ★ 第三个字段别丢:放大类滤镜(FSR EASU / Anime4K CNN)只有画面区大于源才跑,
 *  窗口里播 1080p 点了毫无变化。要在**点之前**就标出来,别让用户点完自己猜。 */
export type ShaderLevel = [id: string, name: string, worksInWindow: boolean];
export const shaderLevels = () => invoke<ShaderLevel[]>("shader_levels");
/** 应用超分档位,返回实际挂上的 shader 数;非 off 却返 0 会直接报错(超分没生效)。 */
/** 挂超分的结果。★ count>0 只说明 mpv 收下了路径,**不代表 shader 会跑** ——
 *  Anime4K 每个 pass 都带「输出 > 源 ×1.2」的门槛,窗口没比源大就整条链空转。
 *  所以必须看 will_run,别只看 count 就报「已生效」(那正是它撒过的谎)。 */
export type ShaderApplied = {
  count: number;
  /** null = 没在播,尺寸未知,核层不下结论 */
  will_run: boolean | null;
  /** will_run=false 时的人话解释(带真实数字),直接显示给用户 */
  note: string | null;
};
export const setShaderLevel = (level: string) => invoke<ShaderApplied>("set_shader_level", { level });

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
/** mediaSourceId = 选版本(草稿 03/04「版本」选择器);省略 = 服务器给的第一个。
    指定了却不存在会报错,不会静默回落 —— 免得以为在看 4K 其实是 1080p。 */
export const play = (itemId: string, resumeSecs: number, mediaSourceId?: string | null) =>
  invoke<number>("play", { itemId, resumeSecs, mediaSourceId: mediaSourceId ?? null });

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

/** 并发探测所有账号连通性,返回带 status 三态的列表(状态点靠它)。 */
export const probeAccounts = () => invoke<AccountInfo[]>("probe_accounts");

/** 编辑账号。**不传的字段 = 不改**;传空串 = 清空该字段。 */
export const updateAccount = (
  serverId: string,
  o: {
    name?: string;
    remark?: string;
    iconUrl?: string;
    allowInsecureTls?: boolean;
    password?: string;
  },
) =>
  invoke<void>("update_account", {
    serverId,
    name: o.name ?? null,
    remark: o.remark ?? null,
    iconUrl: o.iconUrl ?? null,
    allowInsecureTls: o.allowInsecureTls ?? null,
    password: o.password ?? null,
  });

export const reorderAccounts = (from: number, to: number) =>
  invoke<void>("reorder_accounts", { from, to });

/** 图标:下载+缓存后返回 data URI;失败 → 前端回落内置图标。 */
export const accountIcon = (serverId: string) =>
  invoke<string>("account_icon", { serverId });
/** 本地图片存为图标,返回 data URI(同时记住原路径,缓存清了也能重建)。 */
export const setAccountIconFile = (serverId: string, filePath: string) =>
  invoke<string>("set_account_icon_file", { serverId, filePath });
export const clearAccountIcon = (serverId: string) =>
  invoke<void>("clear_account_icon", { serverId });

// ---------- 服务器线路 ----------
/** 并发探测各线路延迟(GET /System/Info/Public,非 ping)。ms=null 即不通。 */
export const probeLines = (serverId: string) =>
  invoke<LineProbe[]>("probe_lines", { serverId });
/** 整表覆写(增删改排序都走它)。 */
export const setLines = (serverId: string, lines: ServerLine[]) =>
  invoke<void>("set_lines", { serverId, lines });
/** 切当前线路;若是活跃服务器会同时刷新会话地址,无需重启。 */
export const setActiveLine = (serverId: string, index: number) =>
  invoke<void>("set_active_line", { serverId, index });

// ---------- 测试连接 / 批量 / 深链 ----------
/** 登录**前**探服务器公开信息(草稿页 06「测试连接」)。不落账号、不动会话。 */
export const testConnection = (server: string) =>
  invoke<ServerInfo>("test_connection", { server });

export type ParsedLine = { name: string; url: string };

/** 一个账号块:一台服务器(可能多线路)+ 该账号的弹幕线路 + 用户名/密码。
    ★ 形状必须与 core/server_batch.rs 的 ParsedServerBlock 一致 —— 块要原样回传给
    batchAddServers,自己瞎编字段(如 urls/remark)会在回传时被 serde 丢掉。 */
export type ParsedServerBlock = {
  username: string | null;
  password: string | null;
  lines: ParsedLine[];
  danmaku_lines: ParsedLine[];
};
export type BatchAddResult = {
  server_id: string | null;
  name: string;
  error: string | null;
};
/** 纯解析,不登录不落盘 —— 拿去展示让用户核对,确认后再 batchAddServers。 */
export const batchParse = (text: string) =>
  invoke<ParsedServerBlock[]>("batch_parse", { text });
export const batchAddServers = (
  blocks: ParsedServerBlock[],
  fallbackUsername?: string | null,
  fallbackPassword?: string | null,
  fallbackName?: string | null,
) =>
  invoke<BatchAddResult[]>("batch_add_servers", {
    blocks,
    fallbackUsername: fallbackUsername ?? null,
    fallbackPassword: fallbackPassword ?? null,
    fallbackName: fallbackName ?? null,
  });

export type DeepLinkAddServer = { name: string | null; block: ParsedServerBlock };
/** ⚠️ 返回非 null **不等于**可以直接加 —— 深链可能来自任意网页/聊天窗。
    必须弹确认框展示地址与用户名,用户点头后才 batchAddServers。 */
export const parseDeepLink = (url: string) =>
  invoke<DeepLinkAddServer | null>("parse_deep_link", { url });
/** ★ 返回的是**原始 URL 字符串**(冷启动命令行里的 linplayer://…),不是解析结果 ——
    还要再喂给 parseDeepLink。且只在冷启动有效:App 已开着时点深链会拉起第二个进程,
    那需要单实例守卫(未接,已知缺口)。 */
export const startupDeepLink = () => invoke<string | null>("startup_deep_link");

// ---------- 夸克扫码 ----------
export type QuarkScan = { device_id: string; qr_data: string; query_token: string };
export const quarkScanStart = () => invoke<QuarkScan>("quark_scan_start");
/** false = 继续轮询;true = 已换到 token 且夸克源已装为活跃源。 */
export const quarkScanPoll = (deviceId: string, queryToken: string) =>
  invoke<boolean>("quark_scan_poll", { deviceId, queryToken });

// ---------- Ani-RSS ----------
/* 核层是 Json 直通(镜像 Ani-RSS 服务端的 map),故这里统一 Json 类型。
   set_config 必须回传 getConfig 的完整 map 改字段后的结果 —— 传半张表会丢字段。 */
export type Json = Record<string, unknown>;

export const anirssListAni = () => invoke<Json[]>("anirss_list_ani");
export const anirssGetConfig = () => invoke<Json>("anirss_get_config");
export const anirssSetConfig = (config: Json) => invoke<void>("anirss_set_config", { config });
export const anirssSearchBgm = (name: string) => invoke<Json>("anirss_search_bgm", { name });
export const anirssGetAniBySubjectId = (id: string) =>
  invoke<Json>("anirss_get_ani_by_subject_id", { id });
export const anirssAddAni = (ani: Json) => invoke<void>("anirss_add_ani", { ani });
export const anirssSetAni = (ani: Json) => invoke<void>("anirss_set_ani", { ani });
export const anirssDeleteAni = (ids: string[], deleteFiles: boolean) =>
  invoke<void>("anirss_delete_ani", { ids, deleteFiles });
export const anirssRefreshAni = (id: string) => invoke<void>("anirss_refresh_ani", { id });
export const anirssRefreshAll = () => invoke<void>("anirss_refresh_all");
/** 当前下载中的种子信息 → 订阅行的「下载中 · 62%」。 */
export const anirssTorrentsInfos = () => invoke<Json>("anirss_torrents_infos");
export const anirssProxyImageUrl = (imgUrl: string) =>
  invoke<string>("anirss_proxy_image_url", { imgUrl });

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
/** 只清记录,不删文件。返回清掉的条数。 */
export const downloadClearCompleted = () => invoke<number>("download_clear_completed");
/** 播放已下载完成的本地文件(下载页 ▶)。传任务 id,不是路径。返回续播位置。 */
export const playLocal = (id: string, resumeSecs = 0) =>
  invoke<number>("play_local", { id, resumeSecs });

// ---------- CF 优选加速 ----------
export type CfTestResult = {
  ip: string;
  latency_ms: number;
  loss_rate: number;
  download_kbps: number | null;
};
export type CfProxyStatus = { server_id: string; local_url: string; pinned_ip: string };
/** 测速,已按优劣排序。validateHost 可剔除「TCP 通但 HTTP 死」的 IP。 */
export const cfSpeedTest = (validateHost?: string | null, testUrl?: string | null) =>
  invoke<CfTestResult[]>("cf_speed_test", {
    validateHost: validateHost ?? null,
    testUrl: testUrl ?? null,
  });
/** 开优选:返回本地反代基址;已开则热换 IP,且立即生效无需重启。 */
export const cfProxyEnable = (serverId: string, ip: string) =>
  invoke<string>("cf_proxy_enable", { serverId, ip });
export const cfProxyDisable = (serverId: string) =>
  invoke<void>("cf_proxy_disable", { serverId });
export const cfProxyStatus = () => invoke<CfProxyStatus[]>("cf_proxy_status");

// ---------- 多线程加载(预取代理) ----------
export type PrefetchSettings = { enabled: boolean; threads: number; cache_bytes: number };
export const getPrefetchSettings = () => invoke<PrefetchSettings>("get_prefetch_settings");
/** threads 必须 2~4、cache_bytes ≥16MB,越界核层直接报错(不静默夹紧)。 */
export const setPrefetchSettings = (settings: PrefetchSettings) =>
  invoke<void>("set_prefetch_settings", { settings });

// ---------- 跨服续播 / 回传 ----------
export const getCrossServerResume = () => invoke<boolean>("get_cross_server_resume");
export const setCrossServerResume = (enabled: boolean) =>
  invoke<void>("set_cross_server_resume", { enabled });

export type WritebackSettings = {
  enabled: boolean;
  /** "all" | "first" | "latest" */
  range: string;
  include_progress: boolean;
};
export const getWritebackSettings = () => invoke<WritebackSettings>("get_writeback_settings");
export const setWritebackSettings = (settings: WritebackSettings) =>
  invoke<void>("set_writeback_settings", { settings });

// ---------- 观看记录 ----------
export type WatchRecord = {
  record_id: string;
  /** `server:user_id` */
  scope_key: string;
  canonical_key: string;
  title: string;
  series_title: string | null;
  season_number: number | null;
  episode_number: number | null;
  [k: string]: unknown;
};
/** currentOnly=true 只列当前服务器+用户的记录;false = 全部(跨服)。 */
export const watchHistoryList = (currentOnly: boolean) =>
  invoke<WatchRecord[]>("watch_history_list", { currentOnly });
/** 删一条:传 record_id(不是 canonical_key)。 */
export const watchHistoryDelete = (recordId: string) =>
  invoke<void>("watch_history_delete", { recordId });
export const watchHistoryClear = () => invoke<void>("watch_history_clear");

// ---------- 字幕翻译 ----------
export type TranslationSettings = Record<string, unknown>;
export const getTranslationSettings = () =>
  invoke<TranslationSettings>("get_translation_settings");
export const setTranslationSettings = (settings: TranslationSettings) =>
  invoke<void>("set_translation_settings", { settings });
/** 各引擎是否已配好 → 设置页的状态点。 */
export const translationEngineStatus = () =>
  invoke<Record<string, boolean>>("translation_engine_status");

export type WhisperModelInfo = {
  key: string;
  display_name: string;
  size_label: string;
  downloaded: boolean;
  downloaded_bytes: number;
};
/** 依赖探测:返回**可执行文件路径**,null = 没找到(不是布尔)。 */
export type WhisperDeps = { whisper: string | null; ffmpeg: string | null };
export const whisperModels = () => invoke<WhisperModelInfo[]>("whisper_models");
export const whisperDownload = (model: string) =>
  invoke<string>("whisper_download", { model });
export const whisperDelete = (model: string) => invoke<void>("whisper_delete", { model });
export const whisperDeps = () => invoke<WhisperDeps>("whisper_deps");
export const whisperDownloadFfmpeg = () => invoke<string>("whisper_download_ffmpeg");

// ---------- 插件 ----------
export type PluginInfo = {
  id: string;
  name: string;
  version: string;
  enabled: boolean;
  [k: string]: unknown;
};
export const pluginList = () => invoke<PluginInfo[]>("plugin_list");
export const pluginEnable = (id: string) => invoke<void>("plugin_enable", { id });
export const pluginDisable = (id: string) => invoke<void>("plugin_disable", { id });
/** 从 **.ipk** 安装(不是 .lpk —— 核层是 install_ipk)。返回的是原始 Json,不保证是 PluginInfo。 */
export const pluginInstall = (path: string) =>
  invoke<Record<string, unknown>>("plugin_install", { path });
export const pluginUninstall = (id: string) => invoke<void>("plugin_uninstall", { id });

// ---------- 代理 ----------
export const getProxy = () => invoke<ProxyConfig>("get_proxy");
export const setProxy = (config: ProxyConfig) => invoke<void>("set_proxy", { config });

// ---------- 弹幕源 ----------
/* ★ 核层收发的都是**列表**(Vec<DanmakuServer>),不是单个对象。
   曾经这里写成单对象:读回来的数组塞进对象类型 → api_url 恒 undefined(输入框永远空),
   写出去少了 sources 参数 → invoke 直接被拒、还被 .catch 吞掉 → 「保存」永远是空操作。
   两头都不报错,所以别再改回单对象。 */
export const getDanmakuConfig = () => invoke<DanmakuServer[]>("get_danmaku_config");
export const setDanmakuConfig = (sources: DanmakuServer[]) =>
  invoke<void>("set_danmaku_config", { sources });

/** 按标题搜番剧,多源并行分组返回(每组自带 error,别丢)。 */
export const danmakuSearch = (keyword: string) =>
  invoke<DanmakuSourceGroup[]>("danmaku_search", { keyword });

export const danmakuLoad = (episodeId: string) =>
  invoke<DanmakuComment[]>("danmaku_load", { episodeId });

/** 智能匹配候选(带评分)。 */
export const danmakuMatch = (input: DanmakuMatchInput) =>
  invoke<DanmakuMatchCandidate[]>("danmaku_match", { input });

/** 自动挂弹幕:返回 null = 没有够可信的匹配,该回落到 danmakuMatch 让用户挑。 */
export const danmakuAutoLoad = (
  input: DanmakuMatchInput,
  options: DanmakuFilterOptions,
  chConvert?: number | null,
  anchorKey?: string | null,
) =>
  invoke<DanmakuComment[] | null>("danmaku_auto_load", {
    input,
    options,
    chConvert: chConvert ?? null,
    anchorKey: anchorKey ?? null,
  });

/** 自动挂载的评分门槛(低于它就别自动挂,交给用户挑)。 */
export const danmakuMinAutoScore = () => invoke<number>("danmaku_min_auto_score");

export const danmakuLoadLocal = (path: string) =>
  invoke<DanmakuComment[]>("danmaku_load_local", { path });

/** 弹幕过滤/去重的默认参数(核层只管过滤,渲染参数是前端的事)。 */
export const defaultDanmakuFilter = (): DanmakuFilterOptions => ({
  blockwords: [],
  user_blocklist: [],
  blocked_modes: [],
  dedup: true,
  dedup_window: 10,
});

export type DanmakuComment = {
  time: number;
  text: string;
  mode: number; // 1=滚动 4=底 5=顶
  color: number;
  source: string;
  cid: string | null;
  user_id: string | null;
  count: number;
};

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
