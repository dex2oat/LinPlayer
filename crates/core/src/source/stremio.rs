// Stremio Addon 协议源。https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md
//
// ★ 为什么不用 stremio-core:那是个完整的 Redux 客户端框架(状态机 + UI model),
//   而且**没发到 crates.io**。我们要的只是「按 manifest 拼 URL、GET、反序列化三种 JSON」,
//   自己撸一份反而更小更可控,也不给安卓交叉编译添依赖。
//
// ---------- 怎么塞进「文件浏览型源」这套抽象 ----------
// Stremio 本身是三层元数据(catalog → meta → stream),不是文件树。这里把三层**折成虚拟路径**,
// 于是 list_dir/resolve_play 两个方法就够用 —— 零新增 Tauri 命令、零新增前端页面,
// 桌面端 NetdiskPage 的网格模式(已在渲染 thumb_url)直接白送一面海报墙。
//
//   None                      → 所有 addon 的 catalog 列表        [文件夹]
//   c|{ai}|{type}|{skip}|{id} → 该 catalog 的条目(海报墙)         [文件夹 + poster]
//   m|{type}|{id}             → 剧集的分集列表                     [文件夹 + 缩略图]
//   s|{type}|{videoId}        → 该条目/该集的可选流                [叶子 is_video]
//
// id 放在最后一段:catalog id / IMDB id 里可能带分隔符,splitn 到最后一段兜住,不会被切坏。
//
// ---------- 凭据怎么存 ----------
// SourceServer 是所有源共用的结构,不为 Stremio 加字段(加了就要改 source_login 命令 + 两端注册 + api.ts)。
//   base_url = 主 addon 的 manifest URL(同时当账号 id,所以要挑一个稳定的,比如 Cinemeta)
//   token    = 其余配置,**每行一条**:
//              - `server=http://192.168.1.10:11470` → 自建 Stremio 流媒体服务器(可选,用来播种子流)
//              - 其余任何行                          → 追加的 addon manifest URL

use super::{
    normalize_base_url, MediaSourceBackend, PlayQuality, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer, SourceSubtitle,
};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 单个 addon 请求的超时。一个挂掉的 addon 不该把整个浏览拖死。
const REQ_TIMEOUT: Duration = Duration::from_secs(15);
/// 判定「这一页是满的、后面还有」的下限。
///
/// ★ **分页步长必须从响应里学,不能写死。** SDK 文档举的例子是 `skip=100`,但那只是例子:
///   2026-07-23 实测 Cinemeta 的 `/catalog/series/top` 每页只回 **50** 条,
///   而 skip=50 / skip=100 都能拿到真实的下一页。按 100 判满页 → 永远不给「下一页」,
///   用户只看得到前 50 条,还完全不报错(最难发现的那种残废)。
///   所以规则改成:回了 n 条就按 n 翻页,n 够大才认为后面还有。
///   ponytail: 20 是「小目录已到底」的经验下限。Stremio 协议没有总数字段,谁也算不出真结尾;
///   猜错的代价是「不足 20 条的小目录看不到第二页」,比「所有目录都卡在第一页」轻得多。
const MIN_PAGE: usize = 20;

// ============================================================================
// manifest 结构(只声明我们真正用到的字段;addon 千奇百怪,一律 default 兜住)
// ============================================================================

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Manifest {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub resources: Vec<Resource>,
    #[serde(default)]
    pub types: Vec<String>,
    #[serde(default)]
    pub catalogs: Vec<Catalog>,
    #[serde(default, rename = "idPrefixes")]
    pub id_prefixes: Option<Vec<String>>,
}

/// resources 有两种写法:短格式 `"catalog"`,完整格式 `{name, types, idPrefixes}`。
/// untagged 顺序要紧:先试字符串,不是字符串才当对象。
#[derive(Deserialize, Clone, Debug)]
#[serde(untagged)]
pub enum Resource {
    Name(String),
    Full {
        name: String,
        #[serde(default)]
        types: Vec<String>,
        #[serde(default, rename = "idPrefixes")]
        id_prefixes: Option<Vec<String>>,
    },
}

impl Resource {
    fn name(&self) -> &str {
        match self {
            Resource::Name(n) => n,
            Resource::Full { name, .. } => name,
        }
    }
}

#[derive(Deserialize, Clone, Debug)]
pub struct Catalog {
    #[serde(rename = "type")]
    pub kind: String,
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub extra: Vec<ExtraProp>,
    // 老式 manifest 用这两个字符串数组代替 extra。两种都得认,否则老 addon 的 catalog 全被判成不可浏览。
    #[serde(default, rename = "extraRequired")]
    pub extra_required: Vec<String>,
    #[serde(default, rename = "extraSupported")]
    pub extra_supported: Vec<String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct ExtraProp {
    pub name: String,
    #[serde(default, rename = "isRequired")]
    pub is_required: bool,
}

impl Catalog {
    /// 必填 extra 参数名。非空 = 这个 catalog 不能裸浏览。
    fn required(&self) -> Vec<&str> {
        let mut v: Vec<&str> = self
            .extra
            .iter()
            .filter(|e| e.is_required)
            .map(|e| e.name.as_str())
            .collect();
        v.extend(self.extra_required.iter().map(|s| s.as_str()));
        v
    }

    fn supports(&self, key: &str) -> bool {
        self.extra.iter().any(|e| e.name == key) || self.extra_supported.iter().any(|s| s == key)
    }

    /// 能不带参数直接列出来吗?
    ///
    /// ★ 这一条是必须的,不是防御式编程:Cinemeta 官方 manifest 里的 `lastVideos` /
    ///   `calendarVideos` 两个 catalog 都要求 `lastVideosIds` / `calendarVideosIds`,
    ///   裸请求返回空。不过滤的话根目录会挂两个点进去永远空的文件夹。
    fn browsable(&self) -> bool {
        self.required().is_empty()
    }

    /// 只有 search 是必填 → 这是个「搜索专用」catalog,不进根目录,但要参与 search()。
    fn search_only(&self) -> bool {
        let req = self.required();
        !req.is_empty() && req.iter().all(|k| *k == "search")
    }

    fn searchable(&self) -> bool {
        self.supports("search")
    }

    fn label(&self) -> String {
        self.name.clone().unwrap_or_else(|| self.id.clone())
    }
}

// ============================================================================
// 响应结构
// ============================================================================

#[derive(Deserialize)]
struct CatalogResp {
    #[serde(default)]
    metas: Vec<MetaPreview>,
}

#[derive(Deserialize)]
struct MetaPreview {
    id: String,
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    poster: Option<String>,
}

#[derive(Deserialize)]
struct MetaResp {
    #[serde(default)]
    meta: Option<MetaDetail>,
}

#[derive(Deserialize)]
struct MetaDetail {
    #[serde(default)]
    videos: Vec<Video>,
}

#[derive(Deserialize)]
struct Video {
    id: String,
    #[serde(default)]
    title: Option<String>,
    /// 有 addon 用 name 而不是 title 装集标题。
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    season: Option<i64>,
    #[serde(default)]
    episode: Option<i64>,
    /// 少数 addon 用 number 代替 episode。
    #[serde(default)]
    number: Option<i64>,
    #[serde(default)]
    thumbnail: Option<String>,
}

#[derive(Deserialize)]
struct StreamResp {
    #[serde(default)]
    streams: Vec<serde_json::Value>,
}

/// 解析用的 Stream 视图。原始 JSON 另存(见 raw 透传),这里只挑要用的字段。
#[derive(Deserialize, Default, Clone)]
struct Stream {
    #[serde(default)]
    url: Option<String>,
    #[serde(default, rename = "ytId")]
    yt_id: Option<String>,
    #[serde(default, rename = "infoHash")]
    info_hash: Option<String>,
    #[serde(default, rename = "fileIdx")]
    file_idx: Option<u32>,
    #[serde(default, rename = "externalUrl")]
    external_url: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    subtitles: Vec<SubEntry>,
    #[serde(default, rename = "behaviorHints")]
    hints: Option<StreamHints>,
}

#[derive(Deserialize, Default, Clone)]
struct StreamHints {
    #[serde(default, rename = "proxyHeaders")]
    proxy_headers: Option<ProxyHeaders>,
    #[serde(default)]
    filename: Option<String>,
    #[serde(default, rename = "videoSize")]
    video_size: Option<i64>,
}

#[derive(Deserialize, Default, Clone)]
struct ProxyHeaders {
    #[serde(default)]
    request: HashMap<String, String>,
}

#[derive(Deserialize, Clone)]
struct SubEntry {
    url: String,
    #[serde(default)]
    lang: Option<String>,
}

#[derive(Deserialize)]
struct SubtitlesResp {
    #[serde(default)]
    subtitles: Vec<SubEntry>,
}

/// 叶子节点透传给 resolve_play 的负载。原始 stream JSON 原样带走(无损),
/// 外加取字幕要用的 type/videoId —— 否则 resolve_play 只拿到一个 entry.id 是拼不出 /subtitles 的。
#[derive(Deserialize)]
struct Payload {
    s: serde_json::Value,
    t: String,
    v: String,
}

// ============================================================================
// 虚拟路径编解码
// ============================================================================

#[derive(Debug, PartialEq)]
enum Node {
    Root,
    Catalog {
        addon: usize,
        kind: String,
        skip: u32,
        id: String,
    },
    Meta {
        kind: String,
        id: String,
    },
    Streams {
        kind: String,
        id: String,
    },
}

fn enc_catalog(addon: usize, kind: &str, skip: u32, id: &str) -> String {
    format!("c|{addon}|{kind}|{skip}|{id}")
}

fn parse_node(raw: Option<&str>) -> Result<Node, SourceError> {
    let Some(s) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(Node::Root);
    };
    let bad = || SourceError::msg(format!("无法识别的 Stremio 路径:{s}"));
    match s.split_once('|') {
        Some(("c", rest)) => {
            // 只切 3 刀 → id 独占最后一段,里面带 `|` 也不会被切坏。
            let p: Vec<&str> = rest.splitn(4, '|').collect();
            if p.len() != 4 {
                return Err(bad());
            }
            Ok(Node::Catalog {
                addon: p[0].parse().map_err(|_| bad())?,
                kind: p[1].to_string(),
                skip: p[2].parse().map_err(|_| bad())?,
                id: p[3].to_string(),
            })
        }
        Some((tag @ ("m" | "s"), rest)) => {
            let (kind, id) = rest.split_once('|').ok_or_else(bad)?;
            let (kind, id) = (kind.to_string(), id.to_string());
            Ok(if tag == "m" {
                Node::Meta { kind, id }
            } else {
                Node::Streams { kind, id }
            })
        }
        _ => Err(bad()),
    }
}

// ============================================================================
// URL 拼接
// ============================================================================

/// manifest URL → addon 根(去掉尾部 `/manifest.json`)。
fn addon_base(manifest_url: &str) -> String {
    let u = normalize_base_url(manifest_url);
    u.strip_suffix("/manifest.json")
        .map(str::to_string)
        .unwrap_or(u)
}

/// 资源路径里的 id 编码。
///
/// ★ `:` 必须**原样留着**:分集 id 就长 `tt0108778:1:5`,官方文档示例写的也是
///   `/stream/series/tt0108778:1:5.json`。转成 %3A 有 addon 不解码 → 直接 404,
///   表现是「电视剧点进去一个流都没有,电影却正常」。
///   只转真会破 URL 结构的字符(空格 / `/` / `?` / `#` / `&` / `%`)。
fn enc_id(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b':' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 拼资源 URL。extra 是 Stremio 的路径段参数(**不是** query string):
/// `/catalog/movie/top/skip=100&genre=Action.json`
fn res_url(base: &str, resource: &str, kind: &str, id: &str, extra: &[(&str, String)]) -> String {
    let mut u = format!(
        "{base}/{resource}/{}/{}",
        enc_id(kind),
        enc_id(id)
    );
    if !extra.is_empty() {
        let q = extra
            .iter()
            .map(|(k, v)| format!("{k}={}", urlencoding::encode(v)))
            .collect::<Vec<_>>()
            .join("&");
        u.push('/');
        u.push_str(&q);
    }
    u.push_str(".json");
    u
}

// ============================================================================
// 后端
// ============================================================================

struct Addon {
    base: String,
    manifest: Manifest,
}

impl Addon {
    fn label(&self) -> &str {
        if self.manifest.name.is_empty() {
            &self.manifest.id
        } else {
            &self.manifest.name
        }
    }

    /// 这个 addon 能处理 (resource, type, id) 吗?
    ///
    /// idPrefixes 只约束 meta/stream/subtitles,**不约束 catalog** —— catalog 一旦声明就总是被请求。
    fn handles(&self, resource: &str, kind: &str, id: &str) -> bool {
        let Some(r) = self
            .manifest
            .resources
            .iter()
            .find(|r| r.name() == resource)
        else {
            return false;
        };
        // 资源级 types/idPrefixes 优先,缺省回落到 manifest 顶层。
        let (types, prefixes) = match r {
            Resource::Full {
                types, id_prefixes, ..
            } => (
                if types.is_empty() {
                    &self.manifest.types
                } else {
                    types
                },
                id_prefixes.as_ref().or(self.manifest.id_prefixes.as_ref()),
            ),
            Resource::Name(_) => (&self.manifest.types, self.manifest.id_prefixes.as_ref()),
        };
        if !types.is_empty() && !types.iter().any(|t| t == kind) {
            return false;
        }
        // idPrefixes 缺省(None)= 不限制;显式给空数组也当不限制。
        match prefixes {
            Some(p) if !p.is_empty() => p.iter().any(|pre| id.starts_with(pre)),
            _ => true,
        }
    }
}

/// 一个 Stremio 账号解析出来的配置。
struct Conf {
    manifests: Vec<String>,
    /// 自建 Stremio 流媒体服务器(可选)。没有则种子流不可播。
    stream_server: Option<String>,
}

fn parse_conf(server: &SourceServer) -> Conf {
    let mut manifests = Vec::new();
    let mut stream_server = None;
    let primary = server.base_url.trim();
    if !primary.is_empty() {
        manifests.push(primary.to_string());
    }
    for line in server.token.as_deref().unwrap_or_default().lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match line.split_once('=') {
            // 只认行首关键字,不用 split_once 的通用结果 —— addon URL 里常有 `=`(配置型 addon
            // 把配置编进路径),按 `=` 一刀切会把它们错判成 server。
            Some((k, v)) if k.trim().eq_ignore_ascii_case("server") => {
                stream_server = Some(normalize_base_url(v));
            }
            _ => manifests.push(line.to_string()),
        }
    }
    manifests.dedup();
    Conf {
        manifests,
        stream_server,
    }
}

#[derive(Default)]
pub struct StremioBackend {
    /// key = server.id。manifest 基本不变,每次浏览都重拉是纯浪费。
    cache: Mutex<HashMap<String, Arc<Vec<Addon>>>>,
}

impl StremioBackend {
    pub fn new() -> Self {
        Self::default()
    }

    async fn get_json<T: serde::de::DeserializeOwned>(
        http: &reqwest::Client,
        url: &str,
    ) -> Result<T, SourceError> {
        let resp = http
            .get(url)
            .timeout(REQ_TIMEOUT)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("请求失败:{e}")))?;
        let status = resp.status();
        if !status.is_success() {
            // addon 没有鉴权概念,401/403 通常是配置型 addon 的配置串失效 —— 当作要重配。
            return Err(if status.as_u16() == 401 || status.as_u16() == 403 {
                SourceError::auth(format!("Addon 拒绝访问({status}),请检查 addon 配置串是否过期"))
            } else {
                SourceError::msg(format!("Addon 返回 {status}"))
            });
        }
        let body = resp
            .bytes()
            .await
            .map_err(|e| SourceError::msg(format!("读取响应失败:{e}")))?;
        serde_json::from_slice(&body)
            .map_err(|e| SourceError::msg(format!("Addon 响应不是合法的 Stremio JSON:{e}")))
    }

    /// 取(并缓存)这个账号的全部 addon manifest。
    async fn addons(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Arc<Vec<Addon>>, SourceError> {
        if let Some(hit) = self.cache.lock().unwrap().get(&server.id) {
            return Ok(hit.clone());
        }
        let conf = parse_conf(server);
        if conf.manifests.is_empty() {
            return Err(SourceError::msg("没有配置任何 Stremio addon"));
        }
        let mut addons = Vec::new();
        let mut errs = Vec::new();
        // ponytail: 串行拉。addon 通常 1~5 个,且拉完就进缓存;真慢了再上并发。
        for m in &conf.manifests {
            let base = addon_base(m);
            let url = format!("{base}/manifest.json");
            match Self::get_json::<Manifest>(http, &url).await {
                Ok(manifest) => addons.push(Addon { base, manifest }),
                Err(e) => errs.push(format!("{m}: {}", e.message)),
            }
        }
        if addons.is_empty() {
            return Err(SourceError::msg(format!(
                "所有 addon 都拉不到 manifest —— {}",
                errs.join(";")
            )));
        }
        let arc = Arc::new(addons);
        self.cache
            .lock()
            .unwrap()
            .insert(server.id.clone(), arc.clone());
        Ok(arc)
    }

    /// catalog 的一页。
    async fn list_catalog(
        &self,
        http: &reqwest::Client,
        addons: &[Addon],
        addon: usize,
        kind: &str,
        cat_id: &str,
        skip: u32,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let a = addons
            .get(addon)
            .ok_or_else(|| SourceError::msg("addon 已变更,请返回根目录重进"))?;
        let extra: Vec<(&str, String)> = if skip > 0 {
            vec![("skip", skip.to_string())]
        } else {
            vec![]
        };
        let url = res_url(&a.base, "catalog", kind, cat_id, &extra);
        let resp: CatalogResp = Self::get_json(http, &url).await?;
        let n = resp.metas.len();
        let mut out: Vec<SourceEntry> = resp.metas.into_iter().map(meta_entry).collect();
        // 够满 → 挂一个「下一页」文件夹,步长就是这一页实际拿到的条数。
        // 面包屑天然管回退,不做「上一页」。
        if let Some(next) = next_skip(skip, n) {
            out.push(SourceEntry {
                id: enc_catalog(addon, kind, next, cat_id),
                name: format!("▶ 下一页(第 {} 项起)", next + 1),
                is_dir: true,
                is_video: false,
                size: None,
                thumb_url: None,
                raw: None,
            });
        }
        Ok(out)
    }

    /// 剧集的分集列表。
    async fn list_episodes(
        &self,
        http: &reqwest::Client,
        addons: &[Addon],
        kind: &str,
        id: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let mut last = SourceError::msg("没有 addon 能提供这个条目的信息");
        for a in addons.iter().filter(|a| a.handles("meta", kind, id)) {
            let url = res_url(&a.base, "meta", kind, id, &[]);
            match Self::get_json::<MetaResp>(http, &url).await {
                Ok(r) => {
                    let Some(meta) = r.meta else { continue };
                    if meta.videos.is_empty() {
                        continue;
                    }
                    let mut videos = meta.videos;
                    videos.sort_by_key(|v| (v.season.unwrap_or(0), v.episode.or(v.number).unwrap_or(0)));
                    return Ok(videos
                        .into_iter()
                        .map(|v| episode_entry(kind, v))
                        .collect());
                }
                Err(e) => last = e,
            }
        }
        // 没有分集 = 这其实是部电影(或 addon 只给了 meta 没给 videos)。直接进选流。
        // 不报错 —— 报错会让用户以为源坏了,实际只是层级少一层。
        Err(last)
    }

    /// 该 videoId 在所有 stream addon 上的可选流。
    async fn list_streams(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        addons: &[Addon],
        kind: &str,
        id: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let has_server = parse_conf(server).stream_server.is_some();
        let mut out = Vec::new();
        let mut errs = Vec::new();
        let mut asked = 0;
        for a in addons.iter().filter(|a| a.handles("stream", kind, id)) {
            asked += 1;
            let url = res_url(&a.base, "stream", kind, id, &[]);
            match Self::get_json::<StreamResp>(http, &url).await {
                Ok(r) => {
                    for raw in r.streams {
                        let Ok(s) = serde_json::from_value::<Stream>(raw.clone()) else {
                            continue;
                        };
                        out.push(stream_entry(a.label(), &s, raw, kind, id, has_server));
                    }
                }
                Err(e) => errs.push(format!("{}: {}", a.label(), e.message)),
            }
        }
        if asked == 0 {
            return Err(SourceError::msg(
                "没有安装能提供播放源的 addon(当前 addon 只提供元数据)",
            ));
        }
        if out.is_empty() {
            return Err(SourceError::msg(if errs.is_empty() {
                "所有 addon 都没有返回可用的播放源".to_string()
            } else {
                format!("取播放源失败 —— {}", errs.join(";"))
            }));
        }
        // 能直接播的排前面。置灰的种子流仍然留着,让用户看得见「有源但缺引擎」,不静默吞掉。
        out.sort_by_key(|e| !e.is_video);
        Ok(out)
    }
}

/// 下一页的 skip 值。None = 这一页已经是结尾,不挂「下一页」。
/// 见 [`MIN_PAGE`]:步长按**实测拿到的条数**走,不按协议文档举例的 100。
fn next_skip(skip: u32, got: usize) -> Option<u32> {
    (got >= MIN_PAGE).then(|| skip + got as u32)
}

/// 内容类型的中文名。认不出的原样显示 —— addon 可以自定义类型,不该被吞成「其它」。
fn type_label(kind: &str) -> &str {
    match kind {
        "movie" => "电影",
        "series" => "剧集",
        "tv" => "直播",
        "channel" => "频道",
        "anime" => "动画",
        "other" => "其它",
        k => k,
    }
}

/// catalog 条目 → 目录项。剧集多一层分集,其它类型直接进选流。
fn meta_entry(m: MetaPreview) -> SourceEntry {
    let kind = m.kind.as_deref().unwrap_or("movie");
    let id = if kind == "series" {
        format!("m|{kind}|{}", m.id)
    } else {
        format!("s|{kind}|{}", m.id)
    };
    SourceEntry {
        id,
        name: m.name.unwrap_or_else(|| m.id.clone()),
        is_dir: true,
        is_video: false,
        size: None,
        thumb_url: m.poster,
        raw: None,
    }
}

fn episode_entry(kind: &str, v: Video) -> SourceEntry {
    let ep = v.episode.or(v.number);
    let tag = match (v.season, ep) {
        (Some(s), Some(e)) => format!("S{s:02}E{e:02}"),
        (None, Some(e)) => format!("E{e:02}"),
        _ => String::new(),
    };
    let title = v.title.or(v.name).unwrap_or_default();
    let name = match (tag.is_empty(), title.is_empty()) {
        (false, false) => format!("{tag} · {title}"),
        (false, true) => tag,
        (true, false) => title,
        (true, true) => v.id.clone(),
    };
    SourceEntry {
        id: format!("s|{kind}|{}", v.id),
        name,
        is_dir: true,
        is_video: false,
        size: None,
        thumb_url: v.thumbnail,
        raw: None,
    }
}

fn stream_entry(
    addon: &str,
    s: &Stream,
    raw: serde_json::Value,
    kind: &str,
    vid: &str,
    has_server: bool,
) -> SourceEntry {
    // 种子流要「配了流媒体服务器」**且** addon 给了 fileIdx —— 缺任一条都拼不出可靠的 URL。
    let torrent_ok = s.info_hash.is_some() && s.file_idx.is_some() && has_server;
    let playable = s.url.is_some() || torrent_ok;
    // name/title/description 里全是换行(addon 拿它排多行标签),压成一行,否则列表行高炸掉。
    let flat = |o: &Option<String>| {
        o.as_deref()
            .map(|t| t.split_whitespace().collect::<Vec<_>>().join(" "))
            .filter(|t| !t.is_empty())
    };
    let mut parts: Vec<String> = [&s.name, &s.title, &s.description]
        .iter()
        .filter_map(|o| flat(o))
        .collect();
    parts.dedup();
    if parts.is_empty() {
        parts.push(addon.to_string());
    }
    let mut name = parts.join(" · ");
    if !playable {
        // 说清楚为什么不能点 —— 「灰着但不说话」用户只会当成 bug。
        name = if s.info_hash.is_some() && !has_server {
            format!("⛔ 种子源(需配 Stremio 流媒体服务器) · {name}")
        } else if s.info_hash.is_some() {
            format!("⛔ 种子源未指定文件索引 · {name}")
        } else if s.external_url.is_some() {
            format!("⛔ 外部链接(需浏览器打开) · {name}")
        } else if s.yt_id.is_some() {
            format!("⛔ YouTube 源(暂不支持) · {name}")
        } else {
            format!("⛔ 不支持的流类型 · {name}")
        };
    }
    SourceEntry {
        id: format!("p|{kind}|{vid}"),
        name,
        is_dir: false,
        is_video: playable,
        size: s.hints.as_ref().and_then(|h| h.video_size),
        thumb_url: None,
        raw: Some(serde_json::json!({ "s": raw, "t": kind, "v": vid })),
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for StremioBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::stremio()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let node = parse_node(dir_id)?;
        let addons = self.addons(http, server).await?;
        match node {
            Node::Root => {
                let multi = addons.len() > 1;
                let mut out = Vec::new();
                for (i, a) in addons.iter().enumerate() {
                    for c in a.manifest.catalogs.iter().filter(|c| c.browsable()) {
                        // 必须带类型:Cinemeta 的四个目录叫 Popular/Popular/Featured/Featured,
                        // 光看名字分不出电影还是剧集(实测根目录就是这四行)。
                        let mut name = format!("{} · {}", c.label(), type_label(&c.kind));
                        if multi {
                            name.push_str(" · ");
                            name.push_str(a.label());
                        }
                        out.push(SourceEntry {
                            id: enc_catalog(i, &c.kind, 0, &c.id),
                            name,
                            is_dir: true,
                            is_video: false,
                            size: None,
                            thumb_url: None,
                            raw: None,
                        });
                    }
                }
                if out.is_empty() {
                    return Err(SourceError::msg(
                        "这些 addon 没有可浏览的目录(可能只提供播放源)。请至少加一个元数据 addon,如 Cinemeta。",
                    ));
                }
                Ok(out)
            }
            Node::Catalog {
                addon,
                kind,
                skip,
                id,
            } => {
                self.list_catalog(http, &addons, addon, &kind, &id, skip)
                    .await
            }
            Node::Meta { kind, id } => {
                match self.list_episodes(http, &addons, &kind, &id).await {
                    Ok(v) => Ok(v),
                    // 拿不到分集就当单体影片,退到选流。别让用户卡在一个空文件夹里。
                    Err(_) => self.list_streams(http, server, &addons, &kind, &id).await,
                }
            }
            Node::Streams { kind, id } => {
                self.list_streams(http, server, &addons, &kind, &id).await
            }
        }
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let q = query.trim();
        if q.is_empty() {
            return Ok(vec![]);
        }
        let addons = self.addons(http, server).await?;
        let mut out: Vec<SourceEntry> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        let mut any = false;
        for a in addons.iter() {
            for c in a.manifest.catalogs.iter() {
                // 可浏览的和「搜索专用」的都要问 —— 后者不进根目录,但正是为搜索存在的。
                if !c.searchable() || !(c.browsable() || c.search_only()) {
                    continue;
                }
                any = true;
                let url = res_url(
                    &a.base,
                    "catalog",
                    &c.kind,
                    &c.id,
                    &[("search", q.to_string())],
                );
                let Ok(r) = Self::get_json::<CatalogResp>(http, &url).await else {
                    continue;
                };
                for m in r.metas {
                    let e = meta_entry(m);
                    if seen.contains(&e.id) {
                        continue;
                    }
                    seen.push(e.id.clone());
                    out.push(e);
                }
            }
        }
        if !any {
            return Err(SourceError::unsupported());
        }
        Ok(out)
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let raw = entry
            .raw
            .clone()
            .ok_or_else(|| SourceError::msg("缺少播放源数据,请返回上一级重新选择"))?;
        let p: Payload = serde_json::from_value(raw)
            .map_err(|e| SourceError::msg(format!("播放源数据损坏:{e}")))?;
        let s: Stream = serde_json::from_value(p.s)
            .map_err(|e| SourceError::msg(format!("播放源格式无法解析:{e}")))?;
        let conf = parse_conf(server);

        let url = match (&s.url, &s.info_hash, s.file_idx, &conf.stream_server) {
            (Some(u), _, _, _) => u.clone(),
            (None, Some(h), Some(idx), Some(srv)) => torrent_url(srv, h, idx),
            (None, Some(_), _, None) => {
                return Err(SourceError::msg(
                    "这是种子源。要播放请在 Stremio 源配置里加一行 `server=http://你的地址:11470`,指向自建的 Stremio 流媒体服务器。",
                ))
            }
            (None, Some(_), None, _) => {
                return Err(SourceError::msg(
                    "这条种子源没有指定文件索引(fileIdx),无法定位到具体视频文件。请换一条。",
                ))
            }
            _ => return Err(SourceError::msg("该播放源类型暂不支持(仅支持直链和种子流)")),
        };

        let mut headers = HashMap::new();
        if let Some(ph) = s.hints.as_ref().and_then(|h| h.proxy_headers.as_ref()) {
            headers.extend(ph.request.clone());
        }

        // 字幕:stream 自带的(免费,已在响应里)+ 各 subtitles addon 提供的。
        let mut subtitles: Vec<SourceSubtitle> = s
            .subtitles
            .iter()
            .map(|x| sub_entry(x, &headers))
            .collect();
        if let Ok(addons) = self.addons(http, server).await {
            let mut extra: Vec<(&str, String)> = vec![];
            if let Some(h) = &s.hints {
                if let Some(sz) = h.video_size {
                    extra.push(("videoSize", sz.to_string()));
                }
                if let Some(f) = &h.filename {
                    extra.push(("filename", f.clone()));
                }
            }
            for a in addons.iter().filter(|a| a.handles("subtitles", &p.t, &p.v)) {
                let u = res_url(&a.base, "subtitles", &p.t, &p.v, &extra);
                if let Ok(r) = Self::get_json::<SubtitlesResp>(http, &u).await {
                    subtitles.extend(r.subtitles.iter().map(|x| sub_entry(x, &headers)));
                }
            }
        }

        Ok(ResolvedPlay {
            url,
            title: entry.name.clone(),
            http_headers: headers,
            user_agent_override: None,
            subtitles,
            qualities: Vec::<PlayQuality>::new(),
            selected_quality_id: None,
        })
    }
}

fn sub_entry(x: &SubEntry, headers: &HashMap<String, String>) -> SourceSubtitle {
    SourceSubtitle {
        url: x.url.clone(),
        title: x.lang.clone(),
        language: x.lang.clone(),
        http_headers: headers.clone(),
    }
}

/// infoHash → 自建 Stremio 流媒体服务器(enginefs)上的 HTTP 直链。
///
/// 模板出处:Stremio/enginefs README 的真实示例
/// `vlc http://localhost:10000/2f24d03eab998ca672b8c1ef567a184609236c02/0`
/// —— 即 `{server}/{infoHash}/{fileIndex}`。
///
/// ★ 要求 fileIdx 必须存在(见 stream_entry 的 playable 判定)。enginefs 文档里**只有**带数字索引
///   这一种形式;省略段 / 用 `-1` / 用 `null` 都是我们猜的,猜错的表现是「点了没反应」这种
///   最难查的静默失败。addon 侧不给 fileIdx 是少数情况(Torrentio/Comet 等主流都给),
///   宁可把那几条置灰说明原因,也不发一个来路不明的 URL。
fn torrent_url(server: &str, info_hash: &str, file_idx: u32) -> String {
    format!(
        "{}/{}/{}",
        normalize_base_url(server),
        info_hash.to_lowercase(),
        file_idx
    )
}

// ============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    fn cat(id: &str, extra: Vec<(&str, bool)>) -> Catalog {
        Catalog {
            kind: "movie".into(),
            id: id.into(),
            name: None,
            extra: extra
                .into_iter()
                .map(|(n, r)| ExtraProp {
                    name: n.into(),
                    is_required: r,
                })
                .collect(),
            extra_required: vec![],
            extra_supported: vec![],
        }
    }

    #[test]
    fn path_roundtrip() {
        assert_eq!(parse_node(None).unwrap(), Node::Root);
        assert_eq!(parse_node(Some("")).unwrap(), Node::Root);
        assert_eq!(
            parse_node(Some(&enc_catalog(2, "series", 100, "top"))).unwrap(),
            Node::Catalog {
                addon: 2,
                kind: "series".into(),
                skip: 100,
                id: "top".into()
            }
        );
        // catalog id 里带分隔符也不能被切坏 —— id 独占最后一段就是为了这个。
        assert_eq!(
            parse_node(Some(&enc_catalog(0, "movie", 0, "a|b|c"))).unwrap(),
            Node::Catalog {
                addon: 0,
                kind: "movie".into(),
                skip: 0,
                id: "a|b|c".into()
            }
        );
        // 分集 id 带两个冒号,必须整段留住。
        assert_eq!(
            parse_node(Some("s|series|tt0108778:1:5")).unwrap(),
            Node::Streams {
                kind: "series".into(),
                id: "tt0108778:1:5".into()
            }
        );
        assert!(parse_node(Some("c|xx|movie|0|top")).is_err());
        assert!(parse_node(Some("z|movie|1")).is_err());
    }

    #[test]
    fn id_encoding_keeps_colon() {
        // 这条挂了 = 电视剧点进去一个流都没有。
        assert_eq!(enc_id("tt0108778:1:5"), "tt0108778:1:5");
        assert_eq!(enc_id("a b"), "a%20b");
        assert_eq!(enc_id("x/y?z"), "x%2Fy%3Fz");
    }

    #[test]
    fn resource_url_shapes() {
        let b = "https://v3-cinemeta.strem.io";
        assert_eq!(
            res_url(b, "catalog", "movie", "top", &[]),
            "https://v3-cinemeta.strem.io/catalog/movie/top.json"
        );
        // extra 是**路径段**不是 query string。写成 ?skip=100 所有 addon 都会当成没传。
        assert_eq!(
            res_url(b, "catalog", "movie", "top", &[("skip", "100".into())]),
            "https://v3-cinemeta.strem.io/catalog/movie/top/skip=100.json"
        );
        assert_eq!(
            res_url(b, "stream", "series", "tt0108778:1:5", &[]),
            "https://v3-cinemeta.strem.io/stream/series/tt0108778:1:5.json"
        );
        assert_eq!(
            res_url(b, "catalog", "movie", "top", &[("search", "game of thrones".into())]),
            "https://v3-cinemeta.strem.io/catalog/movie/top/search=game%20of%20thrones.json"
        );
    }

    #[test]
    fn addon_base_strips_manifest() {
        assert_eq!(
            addon_base("https://v3-cinemeta.strem.io/manifest.json"),
            "https://v3-cinemeta.strem.io"
        );
        assert_eq!(addon_base("v3-cinemeta.strem.io/manifest.json"), "https://v3-cinemeta.strem.io");
        assert_eq!(addon_base("https://x.io/abc123/manifest.json"), "https://x.io/abc123");
        assert_eq!(addon_base("https://x.io/abc123/"), "https://x.io/abc123");
    }

    #[test]
    fn catalog_browsability() {
        assert!(cat("top", vec![("genre", false), ("skip", false)]).browsable());
        // Cinemeta 的 lastVideos:必填 ids,裸浏览必空 —— 不能进根目录。
        let last = cat("lastVideos", vec![("lastVideosIds", true)]);
        assert!(!last.browsable());
        assert!(!last.search_only());
        let s = cat("search", vec![("search", true)]);
        assert!(!s.browsable());
        assert!(s.search_only() && s.searchable());
        // 老式 manifest 的 extraRequired 也要认。
        let mut old = cat("x", vec![]);
        old.extra_required = vec!["genre".into()];
        assert!(!old.browsable());
        let mut old2 = cat("y", vec![]);
        old2.extra_supported = vec!["search".into()];
        assert!(old2.browsable() && old2.searchable());
    }

    #[test]
    fn conf_parsing() {
        let mut srv = SourceServer::default();
        srv.base_url = "https://v3-cinemeta.strem.io/manifest.json".into();
        srv.token = Some(
            "# 注释\nhttps://opensubtitles.strem.io/manifest.json\nserver=http://192.168.1.9:11470/\n\nhttps://x.io/eyJhIjoxfQ==/manifest.json"
                .into(),
        );
        let c = parse_conf(&srv);
        assert_eq!(c.stream_server.as_deref(), Some("http://192.168.1.9:11470"));
        assert_eq!(c.manifests.len(), 3);
        // 配置型 addon 的 URL 里带 `=`,不能被当成 `server=`。
        assert!(c.manifests.iter().any(|m| m.contains("eyJhIjoxfQ==")));
    }

    #[test]
    fn addon_routing_by_type_and_prefix() {
        let a = Addon {
            base: "https://x".into(),
            manifest: serde_json::from_str(
                r#"{"id":"a","name":"A","resources":["catalog","meta"],"types":["movie","series"],"idPrefixes":["tt"]}"#,
            )
            .unwrap(),
        };
        assert!(a.handles("meta", "series", "tt123"));
        assert!(!a.handles("meta", "series", "kitsu:9"));
        assert!(!a.handles("stream", "movie", "tt123")); // 没声明 stream
        assert!(!a.handles("meta", "channel", "tt123")); // 类型不匹配

        // 完整对象格式的 resource:资源级 types/idPrefixes 覆盖顶层。
        let b = Addon {
            base: "https://y".into(),
            manifest: serde_json::from_str(
                r#"{"id":"b","name":"B","types":["movie"],
                    "resources":[{"name":"stream","types":["series"],"idPrefixes":["kitsu:"]}]}"#,
            )
            .unwrap(),
        };
        assert!(b.handles("stream", "series", "kitsu:9"));
        assert!(!b.handles("stream", "movie", "tt1"));

        // idPrefixes 缺省 = 不限制。
        let c = Addon {
            base: "https://z".into(),
            manifest: serde_json::from_str(r#"{"id":"c","resources":["stream"],"types":["movie"]}"#)
                .unwrap(),
        };
        assert!(c.handles("stream", "movie", "任意id"));
    }

    #[test]
    fn stream_entry_playability() {
        let direct: Stream =
            serde_json::from_str(r#"{"url":"https://a/b.mkv","name":"1080p","title":"WEB-DL"}"#)
                .unwrap();
        let e = stream_entry("A", &direct, serde_json::json!({}), "movie", "tt1", false);
        assert!(e.is_video && !e.is_dir);
        assert_eq!(e.name, "1080p · WEB-DL");

        let torrent: Stream =
            serde_json::from_str(r#"{"infoHash":"ABC","fileIdx":2,"name":"4K"}"#).unwrap();
        // 没配流媒体服务器 → 置灰且说明原因,不静默吞掉。
        let g = stream_entry("A", &torrent, serde_json::json!({}), "movie", "tt1", false);
        assert!(!g.is_video);
        assert!(g.name.contains("种子源"));
        // 配了 → 可播。
        let ok = stream_entry("A", &torrent, serde_json::json!({}), "movie", "tt1", true);
        assert!(ok.is_video);

        // 有服务器但 addon 没给 fileIdx → 仍不可播:enginefs 只有带数字索引这一种 URL 形式,
        // 省略/猜一个索引就是发一条来路不明的 URL,失败起来是「点了没反应」。
        let no_idx: Stream = serde_json::from_str(r#"{"infoHash":"ABC","name":"4K"}"#).unwrap();
        let n = stream_entry("A", &no_idx, serde_json::json!({}), "movie", "tt1", true);
        assert!(!n.is_video);
        assert!(n.name.contains("未指定文件索引"));

        // 多行 name/title 压成一行,否则列表行高炸掉。
        let multi: Stream =
            serde_json::from_str(r#"{"url":"u","name":"Torrentio\n1080p","title":"a\n b"}"#).unwrap();
        let m = stream_entry("A", &multi, serde_json::json!({}), "movie", "tt1", false);
        assert!(!m.name.contains('\n'));
        assert_eq!(m.name, "Torrentio 1080p · a b");
    }

    #[test]
    fn episode_naming_and_id() {
        let v: Video =
            serde_json::from_str(r#"{"id":"tt1:1:5","season":1,"episode":5,"title":"标题"}"#).unwrap();
        let e = episode_entry("series", v);
        assert_eq!(e.id, "s|series|tt1:1:5");
        assert_eq!(e.name, "S01E05 · 标题");
        assert!(e.is_dir);
        // 用 name 代替 title、用 number 代替 episode 的 addon 也要认。
        let v2: Video = serde_json::from_str(r#"{"id":"x","number":3,"name":"仅名字"}"#).unwrap();
        assert_eq!(episode_entry("series", v2).name, "E03 · 仅名字");
    }

    #[test]
    fn meta_entry_series_gets_extra_level() {
        let s: MetaPreview =
            serde_json::from_str(r#"{"id":"tt1","type":"series","name":"剧","poster":"p"}"#).unwrap();
        assert_eq!(meta_entry(s).id, "m|series|tt1"); // 剧集要先进分集
        let m: MetaPreview = serde_json::from_str(r#"{"id":"tt2","type":"movie","name":"片"}"#).unwrap();
        assert_eq!(meta_entry(m).id, "s|movie|tt2"); // 电影直接进选流
    }

    #[test]
    fn pagination_learns_page_size_from_response() {
        // ★ 这条钉的是 2026-07-23 实测出来的坑:Cinemeta 每页回 **50** 条,
        //   按协议文档举例的 100 判满页 → 永远不给「下一页」,用户只看得到前 50 条还不报错。
        assert_eq!(next_skip(0, 50), Some(50)); // 第一页 50 条 → 从第 50 项接着要
        assert_eq!(next_skip(50, 50), Some(100));
        assert_eq!(next_skip(0, 100), Some(100)); // 每页 100 的 addon 同样成立
        // ★ 不能拿「比第一页少」当结尾:同一次实测里 Cinemeta 第一页 46 条、第二页 51 条,
        //   每页条数根本不固定。所以判据只能是绝对下限,37 条照样接着翻。
        assert_eq!(next_skip(100, 37), Some(137));
        assert_eq!(next_skip(0, 0), None); // 空目录不挂下一页
        assert_eq!(next_skip(0, MIN_PAGE - 1), None); // 低于下限 = 认作到底
    }

    #[test]
    fn root_catalog_names_disambiguate_type() {
        // Cinemeta 的四个目录真名就是 Popular/Popular/Featured/Featured,
        // 不带类型的话根目录是四行看不出区别的字。
        assert_eq!(type_label("movie"), "电影");
        assert_eq!(type_label("series"), "剧集");
        // 认不出的自定义类型原样透出,不吞成「其它」。
        assert_eq!(type_label("podcast"), "podcast");
    }

    #[test]
    fn torrent_url_shape() {
        // 对齐 enginefs README 示例 `http://localhost:10000/{infoHash}/{fileIndex}`。
        assert_eq!(
            torrent_url("http://192.168.1.9:11470/", "ABCdef", 2),
            "http://192.168.1.9:11470/abcdef/2"
        );
        assert_eq!(
            torrent_url("http://127.0.0.1:11470", "abc", 0),
            "http://127.0.0.1:11470/abc/0"
        );
    }

    /// 真网络。跑:cargo test -p linplayer-core stremio_live -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn stremio_live_cinemeta() {
        let be = StremioBackend::new();
        let http = reqwest::Client::builder()
            .user_agent("LinPlayer/test")
            .build()
            .unwrap();
        let srv = SourceServer {
            id: "live".into(),
            base_url: "https://v3-cinemeta.strem.io/manifest.json".into(),
            ..Default::default()
        };
        let root = be.list_dir(&http, &srv, None).await.unwrap();
        println!("根目录 {} 项", root.len());
        assert!(!root.is_empty());
        assert!(root.iter().all(|e| e.is_dir));
        // lastVideos / calendarVideos 必须被挡掉。
        assert!(!root.iter().any(|e| e.id.ends_with("|lastVideos")));

        // 根目录必须能分清电影/剧集 —— Cinemeta 四个目录重名。
        assert!(root.iter().any(|e| e.name.contains("电影")));
        assert!(root.iter().any(|e| e.name.contains("剧集")));

        let first = root.iter().find(|e| e.id.contains("|movie|")).unwrap();
        let page = be.list_dir(&http, &srv, Some(&first.id)).await.unwrap();
        println!("首个目录 {} 项,首项 {}", page.len(), page[0].name);
        assert!(page.iter().any(|e| e.thumb_url.is_some()), "海报没拿到");

        // 分页:Cinemeta 每页 50,必须挂得出「下一页」,且第二页内容和第一页不同。
        let next = page
            .iter()
            .find(|e| e.name.contains("下一页"))
            .expect("满页却没有下一页 —— 用户会永远卡在第一页");
        let page2 = be.list_dir(&http, &srv, Some(&next.id)).await.unwrap();
        println!("第二页 {} 项,首项 {}", page2.len(), page2[0].name);
        assert_ne!(page2[0].id, page[0].id, "第二页和第一页一样,skip 没生效");

        let hits = be.search(&http, &srv, "matrix").await.unwrap();
        println!("搜索命中 {}", hits.len());
        assert!(!hits.is_empty());
    }
}
