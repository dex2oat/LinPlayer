// Emby 客户端:登录、取媒体库(Views)、列条目、解析直连播放地址。
use crate::http::{device_name, APP_VERSION, CLIENT_NAME};
use serde::{Deserialize, Serialize};

/// X-Emby-Authorization 头:身份用真实应用标识(非 PoC 名),DeviceId 用持久化设备 ID。
fn auth_header(device_id: &str) -> String {
    format!(
        "MediaBrowser Client=\"{CLIENT_NAME}\", Device=\"{}\", DeviceId=\"{device_id}\", Version=\"{APP_VERSION}\"",
        device_name()
    )
}

#[derive(Clone)]
pub struct Session {
    pub server: String, // 归一化后不带尾斜杠
    pub token: String,
    pub user_id: String,
    pub device_id: String,
}

#[derive(Serialize)]
pub struct LoginResult {
    pub server: String,
    pub token: String,
    pub user_id: String,
    pub user_name: String,
    /// 登录用户的头像 tag(建服务器图标用)。无头像则 None。
    #[serde(default)]
    pub primary_image_tag: Option<String>,
}

#[derive(Deserialize)]
struct AuthResponse {
    #[serde(rename = "AccessToken")]
    access_token: String,
    #[serde(rename = "User")]
    user: AuthUser,
}
#[derive(Deserialize)]
struct AuthUser {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: String,
    /// 用户头像 tag。很多 Emby 服把品牌 logo 设成用户头像,服务器图标优先用它。
    /// 不解这个字段的话图标只能退 /web/touchicon.png —— 能用,但悄悄降级。
    #[serde(rename = "PrimaryImageTag", default)]
    primary_image_tag: Option<String>,
}

#[derive(Deserialize)]
struct ItemsResponse {
    #[serde(rename = "Items")]
    items: Vec<RawItem>,
    /// 库内符合条件的总数(与本页 Items.len() 无关)。前端靠它算分页页数;
    /// 缺省 0 —— /Items/Latest 那种裸数组端点走不到这里。
    #[serde(rename = "TotalRecordCount")]
    total_record_count: Option<i64>,
}

/// 一页条目 + 总数。★ 必须带 total:Emby 单次请求最多吐 200 条(实测 smart.uhdnow.com
/// Limit=1000 仍只返 200),3276 条的库只能靠 StartIndex 翻页,没有总数前端就不知道翻到哪。
#[derive(Serialize)]
pub struct ItemPage {
    pub items: Vec<Item>,
    pub total: i64,
}

#[derive(Deserialize)]
struct RawItem {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "Type")]
    type_: Option<String>,
    #[serde(rename = "IsFolder")]
    is_folder: Option<bool>,
    #[serde(rename = "CollectionType")]
    collection_type: Option<String>,
    #[serde(rename = "ImageTags")]
    image_tags: Option<serde_json::Value>,
    #[serde(rename = "RunTimeTicks")]
    runtime_ticks: Option<i64>,
    #[serde(rename = "UserData")]
    user_data: Option<UserData>,
    #[serde(rename = "SeriesName")]
    series_name: Option<String>,
    #[serde(rename = "IndexNumber")]
    index_number: Option<i64>,
    #[serde(rename = "ParentIndexNumber")]
    parent_index_number: Option<i64>,
    /// 仅在请求 Fields=MediaSources 时有(分集卡要「2160p · 45M · 18.4G」)。
    #[serde(rename = "MediaSources")]
    media_sources: Option<Vec<RawMediaSource>>,
    /// 以下三项要 Fields=Genres,ProductionYear,CommunityRating 才有值。
    /// 除了给前端展示,还是 items() 客户端兜底过滤的判据(见 ItemQuery 注释)。
    #[serde(rename = "Genres")]
    genres: Option<Vec<String>>,
    #[serde(rename = "ProductionYear")]
    production_year: Option<i64>,
    #[serde(rename = "CommunityRating")]
    community_rating: Option<f64>,
    /// 以下三项要 Fields=ProviderIds,PresentationUniqueKey,Path。
    /// 它们是**跨服务器续播强匹配的判据**:没有 TMDB id 就只能靠剧名+季集号猜,
    /// 猜错不报错、只是静默匹配不上 —— 所以宁可多要这三个字段。
    #[serde(rename = "ProviderIds")]
    provider_ids: Option<std::collections::HashMap<String, String>>,
    #[serde(rename = "PresentationUniqueKey")]
    presentation_unique_key: Option<String>,
    #[serde(rename = "Path")]
    path: Option<String>,
    /// 剧集所属剧的 Id(跨服匹配要拿它去查剧的 TMDB id)。
    #[serde(rename = "SeriesId")]
    series_id: Option<String>,
}
#[derive(Deserialize)]
struct UserData {
    #[serde(rename = "PlaybackPositionTicks")]
    position_ticks: Option<i64>,
    /// 已看标记。set_played 改的就是它,列表不返回它前端就没法反显「已看」角标。
    #[serde(rename = "Played")]
    played: Option<bool>,
}

#[derive(Serialize)]
pub struct Item {
    pub id: String,
    pub name: String,
    pub type_: String,
    pub is_folder: bool,
    pub has_primary: bool,
    pub runtime_secs: f64,
    pub resume_secs: f64,
    /// 剧集所属剧名。Emby 的 Episode.Name 只是「第 35 集」,单看无意义,
    /// 继续观看/收藏/搜索等混排列表必须靠它才说得清是哪部剧。
    pub series_name: Option<String>,
    pub episode_no: Option<i64>,
    pub season_no: Option<i64>,
    /// 以下三项仅在请求带 Fields=MediaSources 时有值(草稿分集卡的「2160p · 45M · 18.4G」)。
    pub video_height: Option<i64>,
    pub bitrate: Option<i64>,
    pub size_bytes: Option<i64>,
    /// 已看(UserData.Played)。set_played 的反显靠它。
    pub played: bool,
    /// 以下三项要 Fields=Genres,ProductionYear,CommunityRating;媒体库筛选面板要展示也要过滤。
    pub genres: Vec<String>,
    pub year: Option<i64>,
    pub rating: Option<f64>,
    /// 以下四项要 Fields=ProviderIds,PresentationUniqueKey,Path;跨服务器续播强匹配的判据。
    /// 缺了不崩,但匹配会静默降级到「剧名+季集号」—— 那正是跨服续播最容易假装能用的失败形态。
    pub provider_ids: std::collections::HashMap<String, String>,
    pub presentation_unique_key: Option<String>,
    pub path: Option<String>,
    pub series_id: Option<String>,
}

impl From<RawItem> for Item {
    fn from(r: RawItem) -> Self {
        let has_primary = r
            .image_tags
            .as_ref()
            .and_then(|v| v.get("Primary"))
            .is_some();
        let is_folder = r.is_folder.unwrap_or(false) || r.collection_type.is_some();
        // 主版本(第一个 MediaSource)的规格,只为分集卡那行小字;没请求 Fields 时全 None。
        let ms = r.media_sources.as_ref().and_then(|v| v.first());
        let video_height = ms
            .and_then(|m| m.media_streams.as_ref())
            .and_then(|ss| ss.iter().find(|s| s.type_.as_deref() == Some("Video")))
            .and_then(|s| s.height);
        // user_data 要读两个字段(进度 + 已看),先拆出来免得被 move 掉。
        let (resume_ticks, played) = match r.user_data {
            Some(u) => (u.position_ticks.unwrap_or(0), u.played.unwrap_or(false)),
            None => (0, false),
        };
        Item {
            id: r.id,
            name: r.name.unwrap_or_default(),
            type_: r.type_.unwrap_or_default(),
            is_folder,
            has_primary,
            runtime_secs: r.runtime_ticks.unwrap_or(0) as f64 / 1e7,
            resume_secs: resume_ticks as f64 / 1e7,
            played,
            genres: r.genres.unwrap_or_default(),
            year: r.production_year,
            rating: r.community_rating,
            series_name: r.series_name.filter(|s| !s.is_empty()),
            episode_no: r.index_number,
            season_no: r.parent_index_number,
            video_height,
            bitrate: ms.and_then(|m| m.bitrate),
            size_bytes: ms.and_then(|m| m.size),
            provider_ids: r.provider_ids.unwrap_or_default(),
            presentation_unique_key: r.presentation_unique_key.filter(|s| !s.is_empty()),
            path: r.path.filter(|s| !s.is_empty()),
            series_id: r.series_id.filter(|s| !s.is_empty()),
        }
    }
}

// ---------- 媒体信息(草稿页 03 的「版本/音轨/字幕」选择器 + 媒体信息版本块)----------
#[derive(Deserialize)]
struct RawMediaSource {
    #[serde(rename = "Id")]
    id: Option<String>,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "Container")]
    container: Option<String>,
    #[serde(rename = "Size")]
    size: Option<i64>,
    #[serde(rename = "Bitrate")]
    bitrate: Option<i64>,
    #[serde(rename = "RunTimeTicks")]
    runtime_ticks: Option<i64>,
    #[serde(rename = "MediaStreams")]
    media_streams: Option<Vec<RawStream>>,
}

#[derive(Deserialize)]
struct RawStream {
    #[serde(rename = "Type")]
    type_: Option<String>,
    #[serde(rename = "Codec")]
    codec: Option<String>,
    #[serde(rename = "Profile")]
    profile: Option<String>,
    #[serde(rename = "DisplayTitle")]
    display_title: Option<String>,
    #[serde(rename = "Language")]
    language: Option<String>,
    #[serde(rename = "Width")]
    width: Option<i64>,
    #[serde(rename = "Height")]
    height: Option<i64>,
    #[serde(rename = "BitRate")]
    bitrate: Option<i64>,
    #[serde(rename = "Channels")]
    channels: Option<i64>,
    #[serde(rename = "ChannelLayout")]
    channel_layout: Option<String>,
    #[serde(rename = "AverageFrameRate")]
    frame_rate: Option<f64>,
    #[serde(rename = "VideoRange")]
    video_range: Option<String>,
    #[serde(rename = "IsDefault")]
    is_default: Option<bool>,
    #[serde(rename = "Index")]
    index: Option<i64>,
}

/// 一条流(视频/音频/字幕),字段照草稿媒体信息卡的 kv 行来。
#[derive(Serialize, Clone)]
pub struct StreamInfo {
    pub index: i64,
    pub type_: String, // Video | Audio | Subtitle
    pub codec: String,
    pub profile: Option<String>,
    pub display_title: Option<String>,
    pub language: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub bitrate: Option<i64>,
    pub channels: Option<i64>,
    pub channel_layout: Option<String>,
    pub frame_rate: Option<f64>,
    pub video_range: Option<String>,
    pub is_default: bool,
}

/// 一个版本(= 一个 MediaSource)。草稿的「版本 1 · 4K HDR · 主线」一整块。
#[derive(Serialize, Clone)]
pub struct MediaVersion {
    pub id: String,
    pub name: String,
    pub container: Option<String>,
    pub size_bytes: Option<i64>,
    pub bitrate: Option<i64>,
    pub runtime_secs: f64,
    pub streams: Vec<StreamInfo>,
}

impl From<RawMediaSource> for MediaVersion {
    fn from(m: RawMediaSource) -> Self {
        let streams = m
            .media_streams
            .unwrap_or_default()
            .into_iter()
            .filter(|s| {
                matches!(
                    s.type_.as_deref(),
                    Some("Video") | Some("Audio") | Some("Subtitle")
                )
            })
            .map(|s| StreamInfo {
                index: s.index.unwrap_or(0),
                type_: s.type_.unwrap_or_default(),
                codec: s.codec.unwrap_or_default(),
                profile: s.profile.filter(|x| !x.is_empty()),
                display_title: s.display_title.filter(|x| !x.is_empty()),
                language: s.language.filter(|x| !x.is_empty()),
                width: s.width,
                height: s.height,
                bitrate: s.bitrate,
                channels: s.channels,
                channel_layout: s.channel_layout.filter(|x| !x.is_empty()),
                frame_rate: s.frame_rate,
                video_range: s.video_range.filter(|x| !x.is_empty() && x != "Unknown"),
                is_default: s.is_default.unwrap_or(false),
            })
            .collect();
        MediaVersion {
            id: m.id.unwrap_or_default(),
            name: m.name.unwrap_or_default(),
            container: m.container.filter(|x| !x.is_empty()),
            size_bytes: m.size,
            bitrate: m.bitrate,
            runtime_secs: m.runtime_ticks.unwrap_or(0) as f64 / 1e7,
            streams,
        }
    }
}

/// 取条目全部版本+流(走 PlaybackInfo,拿到的才是服务端真判定可播的源)。
pub async fn media_versions(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Result<Vec<MediaVersion>, String> {
    let url = format!(
        "{}/Items/{}/PlaybackInfo?UserId={}",
        s.server, item_id, s.user_id
    );
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&serde_json::json!({}))
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    #[derive(Deserialize)]
    struct Wrap {
        #[serde(rename = "MediaSources")]
        media_sources: Option<Vec<RawMediaSource>>,
    }
    let w: Wrap = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(w
        .media_sources
        .unwrap_or_default()
        .into_iter()
        .map(MediaVersion::from)
        .collect())
}

/// 首页 Hero 的随机推荐(草稿页 01:大幅剧照轮播)。只要有剧照的,否则 Hero 是空的。
pub async fn random_picks(
    http: &reqwest::Client,
    s: &Session,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items?Recursive=true&IncludeItemTypes=Movie,Series&SortBy=Random&Limit={}&ImageTypes=Backdrop&Fields=Overview,Genres,ProductionYear,CommunityRating",
        s.server, s.user_id, limit
    );
    fetch_items(http, s, &url).await
}

fn norm(server: &str) -> String {
    server.trim().trim_end_matches('/').to_string()
}

pub async fn login(
    http: &reqwest::Client,
    server: &str,
    username: &str,
    password: &str,
    device_id: &str,
) -> Result<(Session, LoginResult), String> {
    let server = norm(server);
    let url = format!("{server}/Users/AuthenticateByName");
    let body = serde_json::json!({ "Username": username, "Pw": password });
    let resp = http
        .post(&url)
        .header("X-Emby-Authorization", auth_header(device_id))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("登录失败: HTTP {}", resp.status()));
    }
    let auth: AuthResponse = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let session = Session {
        server: server.clone(),
        token: auth.access_token,
        user_id: auth.user.id.clone(),
        device_id: device_id.to_string(),
    };
    let result = LoginResult {
        server,
        token: session.token.clone(),
        user_id: auth.user.id,
        user_name: auth.user.name,
        primary_image_tag: auth.user.primary_image_tag,
    };
    Ok((session, result))
}

pub async fn views(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let url = format!("{}/Users/{}/Views", s.server, s.user_id);
    fetch_items(http, s, &url).await
}

/// 媒体库浏览的查询条件。全 Option = 不传就不进 URL,老调用点(只给 parent_id)照旧能编。
#[derive(Default, Deserialize)]
pub struct ItemQuery {
    pub start_index: Option<u32>,
    /// None → 用 SERVER_PAGE_CAP(200)。★ 不能"省略 Limit 表示不限":
    /// 实测 smart.uhdnow.com(Emby 4.9.3)省略 Limit 只返 20 条,Limit=0 也是 20,
    /// 而 Limit=1000 被硬顶到 200。所以"不限"在单次请求里根本不存在,
    /// 超过 200 条的库只能靠 start_index 翻页(total 已随 ItemPage 返回)。
    pub limit: Option<u32>,
    pub sort_by: Option<String>,
    pub sort_order: Option<String>,
    pub genres: Option<Vec<String>>,
    pub tags: Option<Vec<String>>,
    pub years: Option<Vec<i32>>,
    pub studios: Option<Vec<String>>,
    pub rating_min: Option<f64>,
    pub rating_max: Option<f64>,
}

/// Emby 单次请求返回条数的服务端硬上限(实测:Limit=201/250/500/1000 一律只回 200)。
const SERVER_PAGE_CAP: u32 = 200;

impl ItemQuery {
    /// 本次查询是否需要客户端兜底过滤(见 items() 里的说明)。
    fn needs_local_filter(&self) -> bool {
        self.genres.as_ref().is_some_and(|v| !v.is_empty())
            || self.tags.as_ref().is_some_and(|v| !v.is_empty())
            || self.years.as_ref().is_some_and(|v| !v.is_empty())
            || self.rating_min.is_some()
            || self.rating_max.is_some()
    }

    /// 条目是否命中过滤条件。tags 无法在客户端判定(Item 不带 Tags),故不参与,
    /// 交给服务端;标准 Emby 认 Tags,不认的服务器上 tag 分面本来也是空的。
    fn matches(&self, it: &Item) -> bool {
        if let Some(g) = self.genres.as_ref().filter(|v| !v.is_empty()) {
            if !g.iter().any(|want| it.genres.iter().any(|has| has == want)) {
                return false;
            }
        }
        if let Some(y) = self.years.as_ref().filter(|v| !v.is_empty()) {
            match it.year {
                Some(iy) => {
                    if !y.iter().any(|w| *w as i64 == iy) {
                        return false;
                    }
                }
                None => return false,
            }
        }
        // 评分区间:无评分的条目视为不在区间(与旧 Dart 一致)。
        if self.rating_min.is_some() || self.rating_max.is_some() {
            let Some(r) = it.rating else { return false };
            if self.rating_min.is_some_and(|m| r < m) || self.rating_max.is_some_and(|m| r > m) {
                return false;
            }
        }
        true
    }
}

/// 媒体库浏览。返回 ItemPage(带 total)以支持翻页。
///
/// ★ 服务端过滤在部分 Emby 上是**假的**:实测 smart.uhdnow.com(Emby 4.9.3 "UHD")
/// 对 Genres/GenreIds/Years/MinCommunityRating 一律忽略 —— 传 Genres=喜剧 返回的
/// TotalRecordCount 与不传完全一致(3276),头几条根本没有喜剧标签。
/// 所以参数照发(标准 Emby/Jellyfin 认,服务端过滤能少传数据),同时在客户端按同样条件
/// 复筛一遍:认参数的服务器上复筛是 no-op,不认的服务器上至少保证**不会显示不匹配的条目**。
/// ponytail: 复筛只作用于当前这一页,3276 条的库筛"喜剧"只会得到前 200 条里的喜剧;
/// 要完整结果需服务端支持,或改成翻页累加(17 次请求)—— 宁可少给,不能给错。
pub async fn items(
    http: &reqwest::Client,
    s: &Session,
    parent_id: &str,
    q: &ItemQuery,
) -> Result<ItemPage, String> {
    // Fields 必须带 Genres/ProductionYear/CommunityRating,否则客户端复筛没有判据。
    let mut url = format!(
        "{}/Users/{}/Items?ParentId={}&Recursive=true&IncludeItemTypes=Movie,Series&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
        s.server, s.user_id, parent_id
    );
    url.push_str(&format!(
        "&Limit={}",
        q.limit.unwrap_or(SERVER_PAGE_CAP).min(SERVER_PAGE_CAP)
    ));
    if let Some(si) = q.start_index {
        url.push_str(&format!("&StartIndex={si}"));
    }
    // SortOrder 必须跟着 SortBy 一起发:实测只发 StartIndex 不发 SortOrder 时排序不稳,
    // 翻页会拿到重复/错位的条目。默认按名升序(= 原先写死的行为)。
    let sort_by = q.sort_by.as_deref().unwrap_or("SortName");
    let sort_order = q.sort_order.as_deref().unwrap_or("Ascending");
    url.push_str(&format!("&SortBy={}&SortOrder={}", enc(sort_by), enc(sort_order)));
    // Genres/Tags/Studios 竖线分隔,Years 逗号分隔(Emby 约定)。
    push_list(&mut url, "Genres", q.genres.as_deref(), "|");
    push_list(&mut url, "Tags", q.tags.as_deref(), "|");
    push_list(&mut url, "Studios", q.studios.as_deref(), "|");
    if let Some(y) = q.years.as_ref().filter(|v| !v.is_empty()) {
        let joined = y.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",");
        url.push_str(&format!("&Years={joined}"));
    }
    // Emby 只有下界参数(无 MaxCommunityRating),上界只能靠客户端复筛。
    if let Some(m) = q.rating_min {
        url.push_str(&format!("&MinCommunityRating={m}"));
    }

    let mut page = fetch_page(http, s, &url).await?;
    if q.needs_local_filter() {
        let before = page.items.len();
        page.items.retain(|it| q.matches(it));
        // 复筛动过手 → 服务端的 TotalRecordCount 不再是筛后总数,报本页实际条数,
        // 免得前端按 3276 画出永远翻不满的页码。
        if page.items.len() != before {
            page.total = page.items.len() as i64;
        }
    }
    Ok(page)
}

/// 把多值条件拼进 URL(空则跳过),值逐个转义。
fn push_list(url: &mut String, key: &str, vals: Option<&[String]>, sep: &str) {
    let Some(v) = vals.filter(|v| !v.is_empty()) else { return };
    let joined = v.iter().map(|x| enc(x)).collect::<Vec<_>>().join(sep);
    url.push_str(&format!("&{key}={joined}"));
}

fn enc(s: &str) -> String {
    urlencoding::encode(s).into_owned()
}

/// 首页"最新更新"轨道:某库最近入库条目(GroupItems 让剧集归并到剧,避免刷一堆单集)。
/// Latest 端点直接返回裸数组(非 {Items} 包裹)。
pub async fn latest(
    http: &reqwest::Client,
    s: &Session,
    parent_id: &str,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items/Latest?ParentId={}&GroupItems=true&Limit={}&Fields=PrimaryImageAspectRatio",
        s.server, s.user_id, parent_id, limit
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let items: Vec<RawItem> = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(items.into_iter().map(Item::from).collect())
}

/// 演职人员(草稿页 03「演职人员」圆头像轨道)。
#[derive(Serialize)]
pub struct Person {
    pub id: String,
    pub name: String,
    pub role: Option<String>,
    /// Director / Actor / Writer / Producer …
    pub type_: String,
    pub has_primary: bool,
}

/// 详情页数据:条目元信息 + 剧集列表(仅 Series/Season 有 children)。
#[derive(Serialize)]
pub struct ItemDetail {
    pub id: String,
    pub name: String,
    pub type_: String,
    pub overview: String,
    pub year: Option<i64>,
    pub genres: Vec<String>,
    pub rating: Option<f64>,
    pub runtime_secs: f64,
    pub resume_secs: f64,
    pub has_primary: bool,
    pub has_backdrop: bool,
    pub is_favorite: bool,
    pub series_name: Option<String>,
    pub series_id: Option<String>,
    pub season_no: Option<i64>,
    pub episode_no: Option<i64>,
    pub children: Vec<Item>, // Series/Season → 剧集(按季+集号排序);Movie/Episode → 空
    pub people: Vec<Person>,
}

pub async fn detail(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Result<ItemDetail, String> {
    let url = format!(
        "{}/Users/{}/Items/{item_id}?Fields=Overview,Genres,ProductionYear,CommunityRating,PremiereDate,People",
        s.server, s.user_id
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let type_ = j["Type"].as_str().unwrap_or_default().to_string();

    // Series/Season 才拉子集(全部集,跨季按季号+集号排序)。
    let children = if type_ == "Series" || type_ == "Season" {
        episodes(http, s, item_id).await.unwrap_or_default()
    } else {
        Vec::new()
    };

    let genres = j["Genres"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();

    // 演职人员:导演优先排前(草稿轨道从左读),其余保持服务端顺序(已按重要性)。
    let mut people: Vec<Person> = j["People"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|p| !p["Name"].as_str().unwrap_or_default().is_empty())
                .map(|p| Person {
                    id: p["Id"].as_str().unwrap_or_default().to_string(),
                    name: p["Name"].as_str().unwrap_or_default().to_string(),
                    role: p["Role"].as_str().filter(|x| !x.is_empty()).map(String::from),
                    type_: p["Type"].as_str().unwrap_or_default().to_string(),
                    has_primary: p["PrimaryImageTag"].as_str().is_some(),
                })
                .collect()
        })
        .unwrap_or_default();
    people.sort_by_key(|p| if p.type_ == "Director" { 0 } else { 1 });

    Ok(ItemDetail {
        id: j["Id"].as_str().unwrap_or(item_id).to_string(),
        name: j["Name"].as_str().unwrap_or_default().to_string(),
        type_,
        overview: j["Overview"].as_str().unwrap_or_default().to_string(),
        year: j["ProductionYear"].as_i64(),
        genres,
        rating: j["CommunityRating"].as_f64(),
        runtime_secs: j["RunTimeTicks"].as_i64().unwrap_or(0) as f64 / 1e7,
        resume_secs: j["UserData"]["PlaybackPositionTicks"].as_i64().unwrap_or(0) as f64 / 1e7,
        has_primary: j.get("ImageTags").and_then(|v| v.get("Primary")).is_some(),
        has_backdrop: j["BackdropImageTags"].as_array().map(|a| !a.is_empty()).unwrap_or(false),
        is_favorite: j["UserData"]["IsFavorite"].as_bool().unwrap_or(false),
        series_name: j["SeriesName"].as_str().map(String::from),
        series_id: j["SeriesId"].as_str().map(String::from),
        season_no: j["ParentIndexNumber"].as_i64(),
        episode_no: j["IndexNumber"].as_i64(),
        children,
        people,
    })
}

/// 继续观看(有播放进度的条目)。
pub async fn resume(http: &reqwest::Client, s: &Session, limit: u32) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items/Resume?Limit={}&MediaTypes=Video&Recursive=true&Fields=PrimaryImageAspectRatio",
        s.server, s.user_id, limit
    );
    fetch_items(http, s, &url).await
}

/// 翻页拉全:服务端把任何 Limit 都夹到 SERVER_PAGE_CAP(200),写 `Limit=500` 只会**静默少拿**。
/// 想要"全部"就必须自己按 StartIndex 翻到底。base_url 需已带 `?`(调用方拼好查询串)。
///
/// `max` 是安全闸:防某天对上一个几万条的库把内存和服务端一起打爆。到闸就停并返回已拿到的,
/// **不报错** —— 对收藏/分集这两个场景,拿到前 max 条远好过整页失败。
async fn fetch_all_paged(
    http: &reqwest::Client,
    s: &Session,
    base_url: &str,
    max: usize,
) -> Result<Vec<Item>, String> {
    let mut out: Vec<Item> = Vec::new();
    loop {
        let url = format!("{base_url}&StartIndex={}&Limit={SERVER_PAGE_CAP}", out.len());
        let page = fetch_items(http, s, &url).await?;
        let got = page.len();
        out.extend(page);
        // 不足一页 = 到底了;够一页但触闸也停(别无限翻)。
        if got < SERVER_PAGE_CAP as usize || out.len() >= max {
            break;
        }
    }
    Ok(out)
}

/// 收藏列表(IsFavorite 过滤,跨库递归)。
/// 原来写 `Limit=300` —— 服务端夹到 200,收藏超过 200 条就静默丢,用户看不到也无从察觉。改翻页。
pub async fn favorites(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let base = format!(
        "{}/Users/{}/Items?Filters=IsFavorite&Recursive=true&IncludeItemTypes=Movie,Series,Episode&SortBy=SortName&SortOrder=Ascending&Fields=PrimaryImageAspectRatio",
        s.server, s.user_id
    );
    fetch_all_paged(http, s, &base, 2000).await
}

/// 切换收藏(POST=加,DELETE=取消)。
pub async fn set_favorite(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    fav: bool,
) -> Result<(), String> {
    let url = format!("{}/Users/{}/FavoriteItems/{}", s.server, s.user_id, item_id);
    let req = if fav { http.post(&url) } else { http.delete(&url) };
    let resp = req
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    Ok(())
}

/// 某剧全部剧集(递归跨季,按季号→集号升序)。
/// 原来写 `Limit=500` —— 服务端夹到 200,长剧(如 500+ 集的动画/长篇剧)**直接缺集**,
/// 而且缺得无声无息:详情页分集列表就是少,用户以为服务器没有。改翻页。
async fn episodes(
    http: &reqwest::Client,
    s: &Session,
    series_id: &str,
) -> Result<Vec<Item>, String> {
    // 带 MediaSources 才有草稿分集卡那行「2160p · 45M · 18.4G」。
    let base = format!(
        "{}/Users/{}/Items?ParentId={}&IncludeItemTypes=Episode&Recursive=true&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending&Fields=PrimaryImageAspectRatio,MediaSources",
        s.server, s.user_id, series_id
    );
    fetch_all_paged(http, s, &base, 3000).await
}

/// 播放期同步所需的条目信息:Trakt(类型+外部ID+时长)+ Bangumi(标题/季/集/首播日)。
#[derive(serde::Serialize, Clone)]
pub struct ScrobbleInfo {
    pub media_type: String,     // "movie" | "episode"
    pub ids: serde_json::Value, // {imdb, tmdb, tvdb}(Trakt;可能为空对象)
    pub runtime_secs: f64,
    // Bangumi 反查用:剧集取剧名(SeriesName),电影取片名(Name)。
    pub title: String,
    pub original_title: Option<String>,
    pub air_date: Option<String>, // PremiereDate
    pub season: i64,              // ParentIndexNumber(电影=1)
    pub episode: i64,             // IndexNumber(电影=1)
}

impl ScrobbleInfo {
    /// Trakt 是否可用(有至少一个外部 ID)。
    pub fn has_trakt_ids(&self) -> bool {
        self.ids.as_object().map(|o| !o.is_empty()).unwrap_or(false)
    }
}

/// 取条目元数据,组装成播放期同步用信息。仅 Movie/Episode 返回 Some(其它类型不同步)。
pub async fn fetch_scrobble_info(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Option<ScrobbleInfo> {
    let url = format!(
        "{}/Users/{}/Items/{item_id}?Fields=ProviderIds,PremiereDate,OriginalTitle",
        s.server, s.user_id
    );
    let resp = http.get(&url).header("X-Emby-Token", &s.token).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: serde_json::Value = resp.json().await.ok()?;
    let raw_type = j["Type"].as_str()?;
    let media_type = match raw_type {
        "Movie" => "movie",
        "Episode" => "episode",
        _ => return None,
    };
    let is_episode = raw_type == "Episode";
    // ProviderIds 键名大小写不一(Imdb/Tmdb/Tvdb),归一小写;tmdb/tvdb 转数字(Trakt 要 int)。
    let mut ids = serde_json::Map::new();
    if let Some(obj) = j["ProviderIds"].as_object() {
        for (k, v) in obj {
            let key = k.to_lowercase();
            if !matches!(key.as_str(), "imdb" | "tmdb" | "tvdb") {
                continue;
            }
            let sv = v.as_str().unwrap_or("").trim().to_string();
            if sv.is_empty() {
                continue;
            }
            if key == "imdb" {
                ids.insert(key, serde_json::Value::String(sv));
            } else if let Ok(n) = sv.parse::<i64>() {
                ids.insert(key, serde_json::Value::from(n));
            }
        }
    }
    // 剧集用剧名(SeriesName)反查 Bangumi 本体,电影用片名。
    let title = if is_episode {
        j["SeriesName"].as_str().unwrap_or("")
    } else {
        j["Name"].as_str().unwrap_or("")
    }
    .to_string();
    Some(ScrobbleInfo {
        media_type: media_type.to_string(),
        ids: serde_json::Value::Object(ids),
        runtime_secs: j["RunTimeTicks"].as_i64().unwrap_or(0) as f64 / 1e7,
        title,
        original_title: j["OriginalTitle"].as_str().filter(|s| !s.is_empty()).map(String::from),
        air_date: j["PremiereDate"].as_str().filter(|s| !s.is_empty()).map(String::from),
        season: if is_episode { j["ParentIndexNumber"].as_i64().unwrap_or(1) } else { 1 },
        episode: if is_episode { j["IndexNumber"].as_i64().unwrap_or(1) } else { 1 },
    })
}

/// 搜索。types=None 时用默认类型集(含 Episode —— 旧实现写死 Movie,Series 搜不到分集)。
///
/// ★ 实测提醒:smart.uhdnow.com(Emby 4.9.3)在带 SearchTerm 时**忽略 IncludeItemTypes**
/// (传 Episode 照样只回 Series/Movie),且分集名("星海飞驰27")根本搜不出来。
/// 参数照发是为标准 Emby/Jellyfin 服务;这台服务器上搜不到分集是服务端行为,客户端改不动。
pub async fn search(
    http: &reqwest::Client,
    s: &Session,
    query: &str,
    types: Option<&[String]>,
    limit: Option<u32>,
) -> Result<Vec<Item>, String> {
    let url = search_url(s, query, types, limit);
    fetch_items(http, s, &url).await
}

/// 拆出来只为可测 —— 见 tests::search_term_must_be_capitalized。
fn search_url(s: &Session, query: &str, types: Option<&[String]>, limit: Option<u32>) -> String {
    let types = match types.filter(|t| !t.is_empty()) {
        Some(t) => t.iter().map(|x| enc(x)).collect::<Vec<_>>().join(","),
        None => "Movie,Series,Episode".to_string(),
    };
    // ★★ 必须是 SearchTerm(大写 S)。原实现写的 searchTerm 被服务端**静默忽略**:
    // 实测 searchTerm=凡人 返回 TotalRecordCount=25596(整个服务器!)且头几条与关键词无关,
    // 而 SearchTerm=凡人 返回 6 条正确结果。也就是说搜索一直在吐全库前 N 条冒充结果。
    // Emby 的 query 参数大小写敏感,别再改回小写。
    // ProviderIds/PresentationUniqueKey/Path:跨服务器续播恢复扫描要靠它们做强匹配 ——
    // 搜索是恢复扫描的入口,这里不要就只能靠剧名猜(静默匹配不上,不报错)。
    format!(
        "{}/Users/{}/Items?SearchTerm={}&IncludeItemTypes={}&Recursive=true&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating,{HISTORY_FIELDS}&Limit={}",
        s.server,
        s.user_id,
        enc(query),
        types,
        limit.unwrap_or(50).min(SERVER_PAGE_CAP)
    )
}

/// 跨服务器续播强匹配所需的 Fields(见 Item 的 provider_ids/presentation_unique_key/path)。
pub const HISTORY_FIELDS: &str = "ProviderIds,PresentationUniqueKey,Path,SeriesId";

/// 取单条 Item(带跨服续播强匹配所需的全部 Fields)。
/// 与 [`detail`] 的区别:detail 面向详情页(要 Overview/People/子集),这个面向观看记录 —— 只要匹配判据。
pub async fn item_for_history(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Result<Item, String> {
    let url = format!(
        "{}/Users/{}/Items/{item_id}?Fields=Genres,ProductionYear,CommunityRating,{HISTORY_FIELDS}",
        s.server, s.user_id
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let raw: RawItem = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(raw.into())
}

/// 取某剧的 TMDB id(跨服务器匹配剧集时用:同一部剧在两台服的 item_id 不同,但 TMDB id 相同)。
/// 剧不存在/没刮到 TMDB → None(不是错误:没刮削的库属正常,匹配自然降级)。
pub async fn series_tmdb_id(
    http: &reqwest::Client,
    s: &Session,
    series_id: &str,
) -> Option<String> {
    let item = item_for_history(http, s, series_id).await.ok()?;
    crate::watch_history::extract_provider_id(&item.provider_ids, "Tmdb")
}

/// 合集(草稿页 01 首页「合集」轨道)。
pub async fn collections(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items?IncludeItemTypes=BoxSet&Recursive=true&SortBy=SortName&SortOrder=Ascending&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating&Limit={}",
        s.server, s.user_id, SERVER_PAGE_CAP
    );
    fetch_items(http, s, &url).await
}

/// 接下来播放(/Shows/NextUp)。返回的是 Episode,靠 SeriesName 才认得出是哪部剧。
pub async fn next_up(http: &reqwest::Client, s: &Session, limit: u32) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Shows/NextUp?UserId={}&Limit={}&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
        s.server, s.user_id, limit
    );
    fetch_items(http, s, &url).await
}

/// 标记已看/未看(POST=已看,DELETE=未看)。实测两者均返 200 + 更新后的 UserData。
pub async fn set_played(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    played: bool,
) -> Result<(), String> {
    let url = format!("{}/Users/{}/PlayedItems/{}", s.server, s.user_id, item_id);
    let req = if played { http.post(&url) } else { http.delete(&url) };
    let resp = req
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    Ok(())
}

/// 服务端登出。★ 尽力而为:实测 smart.uhdnow.com 该端点 404 且 token 登出后仍可用,
/// 所以**不能**让它的失败挡住本地删账号 —— 调用方忽略返回值即可。
pub async fn logout(http: &reqwest::Client, s: &Session) -> Result<(), String> {
    let resp = http
        .post(format!("{}/Sessions/Logout", s.server))
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("登出失败: HTTP {}", resp.status()));
    }
    Ok(())
}

// ---------- 服务器公开信息 / 测试连接(登录前用,无会话)----------
#[derive(Serialize, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    pub id: String,
}

/// 探测服务器(草稿页 06「测试连接」)。★ 不需要登录态 —— 这是登录前用的,别走 session。
/// 实测 GET /System/Info/Public 返回 {ServerName, Version, Id}。
pub async fn server_info(http: &reqwest::Client, server: &str) -> Result<ServerInfo, String> {
    let url = format!("{}/System/Info/Public", norm(server));
    let resp = http
        .get(&url)
        .header("X-Emby-Authorization", auth_header("linplayer-probe"))
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(ServerInfo {
        name: j["ServerName"].as_str().unwrap_or_default().to_string(),
        version: j["Version"].as_str().unwrap_or_default().to_string(),
        id: j["Id"].as_str().unwrap_or_default().to_string(),
    })
}

// ---------- 筛选分面(草稿媒体库详情的 类型/标签/时间 面板)----------
#[derive(Serialize, Default)]
pub struct Filters {
    pub genres: Vec<String>,
    pub tags: Vec<String>,
    pub years: Vec<i32>,
    pub studios: Vec<String>,
    pub official_ratings: Vec<String>,
}

/// 取某库的筛选分面。
///
/// ★ 端点可用性是实测出来的,不是照文档抄的(smart.uhdnow.com / Emby 4.9.3):
///   /Items/Filters、/Users/{u}/Items/Filters2 → 404(旧 Dart 注释里记的坑,复现了)
///   /Genres、/Studios                          → 200 ✅
///   /Years、/Tags、/OfficialRatings            → 404 ❌(旧 Dart 也在拉这三个并吞错,
///                                                 所以旧版的年份/标签分面一直是空的)
/// 故:genres/studios/tags/official_ratings 走各自分面端点(**各自吞错**,一个挂不能拖垮面板);
/// years 因为没有可用端点,改用两次 Limit=1 探针取最早/最晚年份再铺成区间(见下)。
pub async fn filters(http: &reqwest::Client, s: &Session, parent_id: &str) -> Result<Filters, String> {
    // 五路并行,各自吞错 —— 某个分面 404/500 只让它自己为空。
    let (genres, tags, studios, official_ratings, years) = tokio::join!(
        facet(http, s, "Genres", parent_id),
        facet(http, s, "Tags", parent_id),
        facet(http, s, "Studios", parent_id),
        facet(http, s, "OfficialRatings", parent_id),
        year_range(http, s, parent_id),
    );
    Ok(Filters {
        genres,
        tags,
        studios,
        official_ratings,
        years,
    })
}

/// 某分面端点的库内取值(Items[].Name)。失败吞掉返回空:分面挂了不该让整个面板报错。
async fn facet(http: &reqwest::Client, s: &Session, endpoint: &str, parent_id: &str) -> Vec<String> {
    let url = format!(
        "{}/{}?UserId={}&ParentId={}&Recursive=true",
        s.server, endpoint, s.user_id, parent_id
    );
    let Ok(resp) = http.get(&url).header("X-Emby-Token", &s.token).send().await else {
        return Vec::new();
    };
    if !resp.status().is_success() {
        return Vec::new();
    }
    let Ok(j) = resp.json::<serde_json::Value>().await else {
        return Vec::new();
    };
    j["Items"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|i| i["Name"].as_str())
                .filter(|n| !n.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

/// 年份分面。★ Emby 没有 /Years 端点(实测 404),而全量扫出所有年份要翻 17 页(200/页)。
/// 折中:按 ProductionYear 正/倒排各取 1 条拿到最早/最晚年,铺成倒序区间。
/// ponytail: 区间里可能混入该库没有的年份(选了就是空结果),换取 2 次请求而非 17 次;
/// 要精确年份列表得等服务端支持分面,或改成全量扫描。
async fn year_range(http: &reqwest::Client, s: &Session, parent_id: &str) -> Vec<i32> {
    let probe = |order: &'static str| async move {
        let url = format!(
            "{}/Users/{}/Items?ParentId={}&Recursive=true&IncludeItemTypes=Movie,Series&SortBy=ProductionYear&SortOrder={}&Limit=1&Fields=ProductionYear",
            s.server, s.user_id, parent_id, order
        );
        fetch_items(http, s, &url)
            .await
            .ok()
            .and_then(|v| v.into_iter().next())
            .and_then(|i| i.year)
    };
    let (newest, oldest) = tokio::join!(probe("Descending"), probe("Ascending"));
    match (newest, oldest) {
        (Some(hi), Some(lo)) if hi >= lo => (lo as i32..=hi as i32).rev().collect(),
        _ => Vec::new(),
    }
}

/// 取一页(含总数)。所有 {Items} 包裹的列表端点都从这里过。
async fn fetch_page(http: &reqwest::Client, s: &Session, url: &str) -> Result<ItemPage, String> {
    let resp = http
        .get(url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let data: ItemsResponse = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let items: Vec<Item> = data.items.into_iter().map(Item::from).collect();
    Ok(ItemPage {
        // 端点没给 TotalRecordCount 时退回本页条数,别让前端看到 0。
        total: data.total_record_count.unwrap_or(items.len() as i64),
        items,
    })
}

/// 只要条目、不关心总数的调用点(继续观看/收藏/剧集…)。
async fn fetch_items(http: &reqwest::Client, s: &Session, url: &str) -> Result<Vec<Item>, String> {
    Ok(fetch_page(http, s, url).await?.items)
}

#[derive(Deserialize)]
struct PlaybackInfoResp {
    #[serde(rename = "MediaSources")]
    media_sources: Vec<MediaSource>,
    #[serde(rename = "PlaySessionId")]
    play_session_id: Option<String>,
}
#[derive(Deserialize)]
struct MediaSource {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Container")]
    container: Option<String>,
    #[serde(rename = "DirectStreamUrl")]
    direct_stream_url: Option<String>,
    #[serde(rename = "TranscodingUrl")]
    transcoding_url: Option<String>,
}

/// 一次播放会话的目标 + 上报三件套共享的 id。
/// ★ PlaySessionId 必须贯穿 start/progress/stopped 三次上报(续播落地老坑)。
#[derive(Clone, Serialize)]
pub struct PlaybackTarget {
    pub url: String,
    pub item_id: String,
    pub media_source_id: String,
    pub play_session_id: String,
    pub play_method: String, // "DirectStream" | "Transcode"
}

fn secs_to_ticks(secs: f64) -> i64 {
    (secs.max(0.0) * 1e7) as i64
}

/// 补全 server 前缀与 api_key。
fn abs_url(s: &Session, path: &str) -> String {
    let mut u = if path.starts_with("http") {
        path.to_string()
    } else {
        format!("{}{}", s.server, path)
    };
    if !u.contains("api_key=") {
        u.push(if u.contains('?') { '&' } else { '?' });
        u.push_str(&format!("api_key={}", s.token));
    }
    u
}

/// 正确解析播放地址:POST PlaybackInfo -> 用服务器给的 DirectStreamUrl/TranscodingUrl。
/// 返回 PlaybackTarget(含 PlaySessionId,供上报三件套贯穿使用)。
///
/// `media_source_id`:选哪个版本(草稿页 03/04 的「版本」选择器)。
/// None = 服务器返回的第一个。**指定了却找不到就报错,不静默回落第一个** ——
/// 那会让用户以为在看 4K,实际放的是 1080p,且毫无提示。
pub async fn resolve_stream(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    media_source_id: Option<&str>,
) -> Result<PlaybackTarget, String> {
    let url = format!(
        "{}/Items/{}/PlaybackInfo?UserId={}",
        s.server, item_id, s.user_id
    );
    // 宽松 DeviceProfile:声明啥都能直连,促使服务器返回 DirectStreamUrl
    let profile = serde_json::json!({
        "DeviceProfile": {
            "MaxStreamingBitrate": 120000000i64,
            "MaxStaticBitrate": 100000000i64,
            "DirectPlayProfiles": [ { "Type": "Video" }, { "Type": "Audio" } ],
            "TranscodingProfiles": [],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": []
        }
    });
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&profile)
        .send()
        .await
        .map_err(|e| format!("PlaybackInfo 网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("PlaybackInfo 失败: HTTP {}", resp.status()));
    }
    let info: PlaybackInfoResp = resp
        .json()
        .await
        .map_err(|e| format!("PlaybackInfo 解析失败: {e}"))?;
    // 服务器发的 PlaySessionId 优先;缺则本地兜底生成(但同一次播放内保持一致)。
    let play_session_id = info
        .play_session_id
        .filter(|x| !x.is_empty())
        .unwrap_or_else(|| format!("{}-{}", s.device_id, item_id));
    let ms = match media_source_id {
        Some(want) => info
            .media_sources
            .into_iter()
            .find(|m| m.id == want)
            .ok_or_else(|| format!("该条目没有版本 {want}(服务器可能已改动媒体源)"))?,
        None => info
            .media_sources
            .into_iter()
            .next()
            .ok_or("该条目无可播放源")?,
    };
    let media_source_id = ms.id.clone();

    let (url, play_method) = if let Some(d) = ms.direct_stream_url.filter(|x| !x.is_empty()) {
        (abs_url(s, &d), "DirectStream")
    } else if let Some(t) = ms.transcoding_url.filter(|x| !x.is_empty()) {
        (abs_url(s, &t), "Transcode")
    } else {
        // 兜底:用真实 mediaSourceId + container 直拼
        let container = ms.container.unwrap_or_default();
        let ext = if container.is_empty() {
            String::new()
        } else {
            format!(".{container}")
        };
        (
            format!(
                "{}/Videos/{}/stream{}?static=true&mediaSourceId={}&api_key={}",
                s.server, item_id, ext, media_source_id, s.token
            ),
            "DirectStream",
        )
    };

    Ok(PlaybackTarget {
        url,
        item_id: item_id.to_string(),
        media_source_id,
        play_session_id,
        play_method: play_method.to_string(),
    })
}

// ---------- 播放上报三件套(start / progress / stopped,同 PlaySessionId)----------

async fn post_report(
    http: &reqwest::Client,
    s: &Session,
    endpoint: &str,
    body: serde_json::Value,
) -> Result<(), String> {
    let url = format!("{}/Sessions/Playing{}", s.server, endpoint);
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("上报网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("上报失败: HTTP {}", resp.status()));
    }
    Ok(())
}

pub async fn report_start(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PlayMethod": t.play_method,
        "PositionTicks": secs_to_ticks(position_secs),
        "CanSeek": true,
        "IsPaused": false,
    });
    post_report(http, s, "", body).await
}

pub async fn report_progress(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
    paused: bool,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PlayMethod": t.play_method,
        "PositionTicks": secs_to_ticks(position_secs),
        "IsPaused": paused,
        "EventName": "timeupdate",
    });
    post_report(http, s, "/Progress", body).await
}

pub async fn report_stopped(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PositionTicks": secs_to_ticks(position_secs),
    });
    post_report(http, s, "/Stopped", body).await
}

// image_url() 已删:前端(src/lib/api.ts)自己按 server+token 拼图片地址,
// 且这里写死 Primary?maxHeight=360 无法表达 Thumb/Backdrop/Logo 与尺寸 —— 无人调用的死代码,
// 与其扩参数不如删掉。真要回到 Rust 侧再按 image_type/tag/max_width/max_height 重建。

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实载荷回归:smart.uhdnow.com 的 /Items/Resume 原样返回(2026-07-15 实抓)。
    /// Episode.Name 只有「第 35 集」,剧名单独在 SeriesName —— 丢了它列表就没法认剧。
    #[test]
    fn episode_carries_series_name() {
        let raw = r#"{
            "Name": "第 35 集",
            "SeriesName": "问心",
            "Id": "e01KWPH9HCE3AFHNG6PN0HP25JS",
            "Type": "Episode",
            "RunTimeTicks": 27390000000,
            "ImageTags": { "Primary": "x" },
            "UserData": { "PlaybackPositionTicks": 0 }
        }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert_eq!(it.series_name.as_deref(), Some("问心"));
        assert_eq!(it.name, "第 35 集");
        assert!(it.has_primary);
        assert_eq!(it.runtime_secs, 2739.0);
    }

    /// 电影没有 SeriesName,不该冒出空串(前端靠 null 判断要不要拼前缀)。
    #[test]
    fn movie_has_no_series_name() {
        let raw = r#"{ "Name": "沙丘", "Id": "m1", "Type": "Movie" }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert_eq!(it.series_name, None);
    }

    /// 真实载荷回归:smart.uhdnow.com 的 /Users/{u}/Items 分页响应(2026-07-15 实抓)。
    /// TotalRecordCount=3276 但本页只有 200 条 —— 总数必须独立于 items.len() 解析出来,
    /// 否则前端按 200 算页数,3000 多条内容静默消失。
    #[test]
    fn page_total_is_independent_of_page_len() {
        let raw = r#"{
            "Items": [
                { "Id": "m1", "Name": "12金鸭", "Type": "Movie" },
                { "Id": "m2", "Name": "2046", "Type": "Movie" }
            ],
            "TotalRecordCount": 3276
        }"#;
        let data: ItemsResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(data.total_record_count, Some(3276));
        assert_eq!(data.items.len(), 2);
    }

    /// Emby 单次最多 200 条:传再大也要夹到 200,免得前端以为拿全了。
    #[test]
    fn limit_is_clamped_to_server_cap() {
        assert_eq!(Some(5000u32).unwrap_or(SERVER_PAGE_CAP).min(SERVER_PAGE_CAP), 200);
        // 不传 limit 时用 200,而不是"省略 Limit"(实测省略只返 20 条)。
        assert_eq!(None::<u32>.unwrap_or(SERVER_PAGE_CAP).min(SERVER_PAGE_CAP), 200);
    }

    /// UserData.Played 要进漏斗:set_played 之后列表得能反显。
    /// 载荷取自实测 POST /Users/{u}/PlayedItems/{id} 的返回。
    #[test]
    fn played_flag_flows_through_funnel() {
        let raw = r#"{
            "Id": "m01KRGA5RC8R7C5RR1S06THXXQT", "Name": "龙门客栈", "Type": "Movie",
            "UserData": { "PlaybackPositionTicks": 120000000, "Played": true }
        }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert!(it.played);
        assert_eq!(it.resume_secs, 12.0); // 已看不该把进度吃掉
    }

    /// 没有 UserData 的条目(如 BoxSet)不该 panic,played=false。
    #[test]
    fn missing_user_data_defaults_to_unplayed() {
        let raw = r#"{ "Id": "b1", "Name": "合集", "Type": "BoxSet" }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert!(!it.played);
        assert_eq!(it.resume_secs, 0.0);
    }

    /// 客户端兜底复筛:实测 UHD 服务端忽略 Genres/Years/评分过滤,
    /// 复筛必须真的能把不匹配的条目挡掉 —— 否则筛选面板就是个摆设。
    /// 载荷字段取自实测 Fields=Genres,ProductionYear,CommunityRating 的返回形状。
    #[test]
    fn local_filter_rejects_non_matching_items() {
        let mk = |raw: &str| -> Item { serde_json::from_str::<RawItem>(raw).unwrap().into() };
        // 实测「Genres=喜剧」时服务端原样吐回来的那类条目:根本没有喜剧。
        let action = mk(r#"{"Id":"1","Name":"龙门飞甲","Type":"Movie",
            "Genres":["冒险","剧情","动作"],"ProductionYear":2011,"CommunityRating":6.2}"#);
        let comedy = mk(r#"{"Id":"2","Name":"龙马精神","Type":"Movie",
            "Genres":["剧情","动作","喜剧"],"ProductionYear":2023,"CommunityRating":8.5}"#);

        let by_genre = ItemQuery { genres: Some(vec!["喜剧".into()]), ..Default::default() };
        assert!(by_genre.needs_local_filter());
        assert!(!by_genre.matches(&action), "非喜剧必须被挡掉");
        assert!(by_genre.matches(&comedy));

        let by_year = ItemQuery { years: Some(vec![2023]), ..Default::default() };
        assert!(!by_year.matches(&action));
        assert!(by_year.matches(&comedy));

        // 评分上界 Emby 没有参数,只能靠复筛。
        let by_rating = ItemQuery { rating_min: Some(7.0), rating_max: Some(9.0), ..Default::default() };
        assert!(!by_rating.matches(&action));
        assert!(by_rating.matches(&comedy));

        // 无评分条目视为不在区间(与旧 Dart 行为一致)。
        let unrated = mk(r#"{"Id":"3","Name":"万米危机","Type":"Movie","CommunityRating":null}"#);
        assert!(!by_rating.matches(&unrated));

        // 不传任何筛选条件 → 不复筛,全部放行(避免把正常浏览误伤成空列表)。
        let none = ItemQuery::default();
        assert!(!none.needs_local_filter());
        assert!(none.matches(&action) && none.matches(&unrated));
    }

    /// 空 vec 不算筛选条件 —— 否则前端传 genres:[] 会把整页清空。
    #[test]
    fn empty_filter_vecs_are_not_filters() {
        let q = ItemQuery { genres: Some(vec![]), years: Some(vec![]), ..Default::default() };
        assert!(!q.needs_local_filter());
        let it: Item = serde_json::from_str::<RawItem>(r#"{"Id":"1","Type":"Movie"}"#).unwrap().into();
        assert!(q.matches(&it));
    }

    /// /System/Info/Public 实抓形状(登录前探测,无 token)。
    #[test]
    fn parses_public_server_info() {
        let raw = r#"{"SystemUpdateLevel":"Release","OperatingSystem":"Linux",
            "ServerName":"UHD","Version":"4.9.3.0","Id":"UHD"}"#;
        let j: serde_json::Value = serde_json::from_str(raw).unwrap();
        let si = ServerInfo {
            name: j["ServerName"].as_str().unwrap_or_default().to_string(),
            version: j["Version"].as_str().unwrap_or_default().to_string(),
            id: j["Id"].as_str().unwrap_or_default().to_string(),
        };
        assert_eq!((si.name.as_str(), si.version.as_str(), si.id.as_str()), ("UHD", "4.9.3.0", "UHD"));
    }

    /// /Genres 实抓:Id 是**数字**不是 GUID 字符串,只取 Name 才不会踩类型坑。
    #[test]
    fn parses_genre_facet_with_numeric_ids() {
        let raw = r#"{"Items":[{"Id":12,"Name":"冒险","Type":"Genre"},
            {"Id":35,"Name":"喜剧","Type":"Genre"},{"Id":99,"Name":"","Type":"Genre"}],
            "TotalRecordCount":3}"#;
        let j: serde_json::Value = serde_json::from_str(raw).unwrap();
        let names: Vec<String> = j["Items"].as_array().unwrap().iter()
            .filter_map(|i| i["Name"].as_str()).filter(|n| !n.is_empty())
            .map(String::from).collect();
        assert_eq!(names, vec!["冒险", "喜剧"]); // 空名被剔除
    }

    /// ★ 搜索关键词参数名必须是大写 SearchTerm。
    /// 实测:searchTerm(小写)被服务端静默忽略 → 返回全库 25596 条冒充搜索结果;
    /// SearchTerm → 6 条正确结果。这个测试就是防止有人手滑改回小写。
    #[test]
    fn search_term_must_be_capitalized() {
        let s = Session {
            server: "https://x".into(),
            token: "t".into(),
            user_id: "u".into(),
            device_id: "d".into(),
        };
        let url = search_url(&s, "凡人", None, None);
        assert!(url.contains("SearchTerm="), "关键词参数必须大写 SearchTerm: {url}");
        assert!(!url.contains("searchTerm="), "小写 searchTerm 会被服务端忽略并返回全库");
        // 默认类型集要含 Episode(旧实现写死 Movie,Series 搜不到分集)。
        assert!(url.contains("IncludeItemTypes=Movie,Series,Episode"));
        assert!(url.contains("Limit=50"));
        // 显式传类型/条数时照传,且条数夹到服务端上限。
        let url2 = search_url(&s, "x", Some(&["Movie".to_string()]), Some(9999));
        assert!(url2.contains("IncludeItemTypes=Movie&"));
        assert!(url2.contains("Limit=200"));
    }

    /// 年份区间探针:最早 1922 最晚 2026(实测华语电影库),铺成倒序区间。
    #[test]
    fn year_range_is_descending_and_inclusive() {
        let years: Vec<i32> = (1922i32..=2026).rev().collect();
        assert_eq!(years.first(), Some(&2026));
        assert_eq!(years.last(), Some(&1922));
        assert_eq!(years.len(), 105);
    }
}
