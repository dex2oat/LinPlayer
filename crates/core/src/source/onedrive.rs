// OneDrive 后端(Microsoft Graph)。令牌走 oplist 在线服务,接口全是官方有文档的 Graph v1.0。
//
// 播放最省事的一个源:列目录时用 $select 顺带把 `@microsoft.graph.downloadUrl` 取回来,
// 那是**预签名 URL** —— 不需要 Authorization 头、支持 Range(能 seek)、约 1 小时有效,
// 直接扔给 mpv 即可。过期由既有的 source_watchdog 重解析兜底。
use super::oplist::OplistAuth;
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use serde_json::Value;
use std::collections::HashMap;

const PROVIDER: &str = "onedrive";
const DRIVER_TXT: &str = "onedrive_pr";

/// 国际版。世纪互联(21Vianet)用 `https://microsoftgraph.chinacloudapi.cn/v1.0`,
/// 用户可在表单里填 base_url 覆盖。
const GRAPH: &str = "https://graph.microsoft.com/v1.0";

/// 一次取满上限,少翻几页。$top 上限 999。
const SELECT: &str = "id,name,size,file,folder,video,@microsoft.graph.downloadUrl";
const PAGE: &str = "$top=999";
/// 翻页保险丝:单目录 999x200 ≈ 20 万项,够任何真实网盘目录了。
const MAX_PAGES: usize = 200;

#[derive(Default)]
pub struct OneDriveBackend {
    auth: Option<OplistAuth>,
}

impl OneDriveBackend {
    pub fn new() -> Self {
        Self { auth: Some(OplistAuth::new(PROVIDER, DRIVER_TXT)) }
    }

    fn auth(&self) -> &OplistAuth {
        self.auth.as_ref().expect("OneDriveBackend 必须用 new() 构造")
    }

    fn graph(server: &SourceServer) -> String {
        let b = super::normalize_base_url(&server.base_url);
        if b.is_empty() {
            GRAPH.to_string()
        } else {
            b
        }
    }

    /// 带 Bearer 的 GET。401 时刷新令牌重试一次 —— access_token 只有 1 小时,
    /// 长时间挂着的 App 第一个请求几乎必然撞过期。
    async fn get(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        url: &str,
    ) -> Result<Value, SourceError> {
        let mut forced = false;
        loop {
            let token = self.auth().access_token(http, server, forced).await?;
            let resp = http
                .get(url)
                .bearer_auth(&token)
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("OneDrive 请求失败: {e}")))?;
            if resp.status() == reqwest::StatusCode::UNAUTHORIZED && !forced {
                forced = true;
                continue;
            }
            let status = resp.status();
            let v: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("OneDrive 响应解析失败({status}): {e}")))?;
            if let Some(err) = v["error"].as_object() {
                let msg = err
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("OneDrive 请求失败");
                let is_auth = status == reqwest::StatusCode::UNAUTHORIZED;
                return Err(SourceError { message: msg.to_string(), is_auth });
            }
            return Ok(v);
        }
    }

    /// 顺着 @odata.nextLink 收完所有页。
    async fn collect(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        first: String,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let mut out = Vec::new();
        let mut next = Some(first);
        let mut pages = 0;
        while let Some(url) = next {
            if pages >= MAX_PAGES {
                break;
            }
            pages += 1;
            let v = self.get(http, server, &url).await?;
            if let Some(items) = v["value"].as_array() {
                out.extend(items.iter().map(item_to_entry));
            }
            next = v["@odata.nextLink"].as_str().map(|s| s.to_string());
        }
        sort_entries(&mut out);
        Ok(out)
    }
}

fn item_to_entry(m: &Value) -> SourceEntry {
    let is_dir = m["folder"].is_object();
    let name = m["name"].as_str().unwrap_or("").to_string();
    // video facet 存在即为视频;它不总是有(未转码完成的文件没有),故用扩展名兜底。
    let is_video = !is_dir && (m["video"].is_object() || is_video_file_name(&name));
    let thumb = m["thumbnails"][0]["medium"]["url"]
        .as_str()
        .or_else(|| m["thumbnails"][0]["small"]["url"].as_str())
        .map(|s| s.to_string());
    SourceEntry {
        id: m["id"].as_str().unwrap_or("").to_string(),
        name,
        is_dir,
        is_video,
        size: m["size"].as_i64(),
        thumb_url: thumb,
        // 直链随列表一起取回,播放时若还没过期可以直接用,省一次往返。
        raw: m["@microsoft.graph.downloadUrl"]
            .as_str()
            .map(|u| serde_json::json!({ "download_url": u })),
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for OneDriveBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::onedrive()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let graph = Self::graph(server);
        let scope = match dir_id.filter(|d| !d.is_empty()) {
            Some(id) => format!("items/{id}"),
            None => "root".to_string(),
        };
        let url =
            format!("{graph}/me/drive/{scope}/children?{PAGE}&$select={SELECT}&$expand=thumbnails");
        self.collect(http, server, url).await
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let graph = Self::graph(server);
        // search(q='...') 里的单引号要翻倍转义,否则查询语法直接崩。
        let q = urlencoding::encode(&query.replace('\'', "''")).into_owned();
        let url = format!("{graph}/me/drive/root/search(q='{q}')?{PAGE}&$select={SELECT}");
        self.collect(http, server, url).await
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        // 列表里带回来的直链先用;它约 1 小时有效,浏览完立刻点播的常见路径不必再打一次接口。
        // 过期了 mpv 会报错,source_watchdog 重解析时 raw 为空自然走下面的现取。
        if let Some(u) = entry.raw.as_ref().and_then(|r| r["download_url"].as_str()) {
            if !u.is_empty() {
                return Ok(ResolvedPlay::simple(
                    u.to_string(),
                    entry.name.clone(),
                    HashMap::new(),
                ));
            }
        }
        let graph = Self::graph(server);
        let url = format!(
            "{graph}/me/drive/items/{}?$select=id,name,@microsoft.graph.downloadUrl",
            entry.id
        );
        let v = self.get(http, server, &url).await?;
        let dl = v["@microsoft.graph.downloadUrl"].as_str().unwrap_or("");
        if dl.is_empty() {
            return Err(SourceError::msg("OneDrive 未返回下载地址"));
        }
        // 预签名 URL:不带任何 header,带了反而可能被 CDN 拒。
        Ok(ResolvedPlay::simple(
            dl.to_string(),
            entry.name.clone(),
            HashMap::new(),
        ))
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        self.auth().take_rotated(server_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 目录/文件/视频的判定全靠 facet:folder 对象在就是目录,video 对象在就是视频。
    /// 判错的后果是目录点不进去或视频不给播,且不报错。
    #[test]
    fn item_facets_decide_dir_and_video() {
        let dir = serde_json::json!({"id":"1","name":"电影","folder":{"childCount":3}});
        let e = item_to_entry(&dir);
        assert!(e.is_dir && !e.is_video);

        let vid = serde_json::json!({
            "id":"2","name":"a.mkv","size":123,
            "file":{"mimeType":"video/x-matroska"},
            "video":{"duration":1000},
            "@microsoft.graph.downloadUrl":"https://dl.example/x"
        });
        let e = item_to_entry(&vid);
        assert!(!e.is_dir && e.is_video);
        assert_eq!(e.size, Some(123));
        assert_eq!(e.raw.unwrap()["download_url"], "https://dl.example/x");

        // 没有 video facet 时靠扩展名兜底 —— OneDrive 对未处理完的文件不给 facet。
        let no_facet = serde_json::json!({"id":"3","name":"b.mp4","file":{}});
        assert!(item_to_entry(&no_facet).is_video);

        let doc = serde_json::json!({"id":"4","name":"说明.txt","file":{}});
        assert!(!item_to_entry(&doc).is_video);
    }

    /// 缩略图取 medium,缺了退 small。取不到就是 None(UI 显示占位),不能整条崩。
    #[test]
    fn thumbnail_prefers_medium_then_small_then_none() {
        let m = serde_json::json!({"id":"1","name":"a.mp4","file":{},
            "thumbnails":[{"medium":{"url":"M"},"small":{"url":"S"}}]});
        assert_eq!(item_to_entry(&m).thumb_url.as_deref(), Some("M"));

        let s = serde_json::json!({"id":"1","name":"a.mp4","file":{},
            "thumbnails":[{"small":{"url":"S"}}]});
        assert_eq!(item_to_entry(&s).thumb_url.as_deref(), Some("S"));

        let none = serde_json::json!({"id":"1","name":"a.mp4","file":{}});
        assert_eq!(item_to_entry(&none).thumb_url, None);
    }

    /// 世纪互联端点必须能靠 base_url 覆盖 —— 写死国际版的话国内 OneDrive 一个请求都发不出去。
    #[test]
    fn graph_endpoint_is_overridable_for_21vianet() {
        let mut s = SourceServer::default();
        assert_eq!(OneDriveBackend::graph(&s), GRAPH);
        s.base_url = "https://microsoftgraph.chinacloudapi.cn/v1.0/".into();
        assert_eq!(
            OneDriveBackend::graph(&s),
            "https://microsoftgraph.chinacloudapi.cn/v1.0"
        );
    }
}
