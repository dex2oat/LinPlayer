// Dropbox 后端(API v2)。令牌走 oplist 在线服务。
//
// 取流用 `get_temporary_link` 拿 4 小时签名 URL:免鉴权、支持 Range,直接喂 mpv。
// (另一条 `/2/files/download` 是 **POST + Dropbox-API-Arg 头**,mpv 只会发 GET,用不了。)
//
// ponytail: 已知风险 —— 社区报告临时链在带 Range 时可能回错的 `Content-Type: application/grpc`,
// 字节和状态码都对、播放器却拒播。这条只有挂真机才证得了,先不预造兜底(唯一的兜底是本地反代
// 改写响应头,成本远高于问题本身)。真撞上了再接,查法:curl -H 'Range: bytes=0-1' -D- 看响应头。
use super::oplist::OplistAuth;
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use serde_json::{json, Value};
use std::collections::HashMap;

const PROVIDER: &str = "dropbox";
const DRIVER_TXT: &str = "dropboxs_go";
const API: &str = "https://api.dropboxapi.com/2";
const PAGE_LIMIT: i64 = 2000;
const MAX_PAGES: usize = 200;

#[derive(Default)]
pub struct DropboxBackend {
    auth: Option<OplistAuth>,
}

impl DropboxBackend {
    pub fn new() -> Self {
        Self { auth: Some(OplistAuth::new(PROVIDER, DRIVER_TXT)) }
    }

    fn auth(&self) -> &OplistAuth {
        self.auth.as_ref().expect("DropboxBackend 必须用 new() 构造")
    }

    async fn post(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        body: Value,
    ) -> Result<Value, SourceError> {
        let mut forced = false;
        loop {
            let token = self.auth().access_token(http, server, forced).await?;
            let resp = http
                .post(format!("{API}{path}"))
                .bearer_auth(&token)
                .header("Content-Type", "application/json")
                .json(&body)
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("Dropbox 请求失败: {e}")))?;
            let status = resp.status();
            if status == reqwest::StatusCode::UNAUTHORIZED && !forced {
                forced = true;
                continue;
            }
            let text = resp
                .text()
                .await
                .map_err(|e| SourceError::msg(format!("Dropbox 读取响应失败: {e}")))?;
            if !status.is_success() {
                // Dropbox 的错误体是 {error_summary, error:{...}},summary 已是可读串。
                let summary = serde_json::from_str::<Value>(&text)
                    .ok()
                    .and_then(|v| v["error_summary"].as_str().map(|s| s.to_string()))
                    .unwrap_or_else(|| text.chars().take(200).collect());
                return Err(SourceError {
                    message: format!("Dropbox 请求失败({status}): {summary}"),
                    is_auth: status == reqwest::StatusCode::UNAUTHORIZED,
                });
            }
            return serde_json::from_str(&text)
                .map_err(|e| SourceError::msg(format!("Dropbox 响应解析失败: {e}")));
        }
    }
}

fn entry_from_metadata(m: &Value) -> Option<SourceEntry> {
    let tag = m[".tag"].as_str().unwrap_or("");
    if tag == "deleted" {
        return None;
    }
    let is_dir = tag == "folder";
    let name = m["name"].as_str().unwrap_or("").to_string();
    // id 必须是路径:后续 list_folder / get_temporary_link 全按路径寻址。
    // path_lower 是 Dropbox 保证稳定的那个(path_display 只用于展示)。
    let id = m["path_lower"]
        .as_str()
        .or_else(|| m["path_display"].as_str())
        .unwrap_or("")
        .to_string();
    Some(SourceEntry {
        id,
        name: name.clone(),
        is_dir,
        is_video: !is_dir && is_video_file_name(&name),
        size: m["size"].as_i64(),
        thumb_url: None, // 缩略图要单独 POST 拿二进制,列表里不逐个打(会撞限流)
        raw: None,
    })
}

/// search_v2 的条目比 list_folder 多包一层。两种嵌套都试,省得因为 API 版本差异整个搜索空白。
fn entry_from_search_match(m: &Value) -> Option<SourceEntry> {
    let inner = &m["metadata"]["metadata"];
    if inner.is_object() {
        return entry_from_metadata(inner);
    }
    let flat = &m["metadata"];
    flat.is_object().then(|| entry_from_metadata(flat)).flatten()
}

#[async_trait::async_trait]
impl MediaSourceBackend for DropboxBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::dropbox()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        // ★ 根目录是**空字符串**,不是 "/"。填 "/" 会直接报 malformed_path。
        let path = dir_id.filter(|d| !d.is_empty() && *d != "/").unwrap_or("");
        let mut v = self
            .post(
                http,
                server,
                "/files/list_folder",
                json!({ "path": path, "recursive": false, "limit": PAGE_LIMIT }),
            )
            .await?;
        let mut out = Vec::new();
        for _ in 0..MAX_PAGES {
            if let Some(items) = v["entries"].as_array() {
                out.extend(items.iter().filter_map(entry_from_metadata));
            }
            if v["has_more"].as_bool() != Some(true) {
                break;
            }
            let cursor = v["cursor"].as_str().unwrap_or("").to_string();
            if cursor.is_empty() {
                break;
            }
            v = self
                .post(http, server, "/files/list_folder/continue", json!({ "cursor": cursor }))
                .await?;
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let v = self
            .post(
                http,
                server,
                "/files/search_v2",
                json!({
                    "query": query,
                    "options": { "max_results": 1000, "file_status": "active" }
                }),
            )
            .await?;
        let empty = vec![];
        let mut out: Vec<SourceEntry> = v["matches"]
            .as_array()
            .unwrap_or(&empty)
            .iter()
            .filter_map(entry_from_search_match)
            .collect();
        sort_entries(&mut out);
        Ok(out)
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let v = self
            .post(http, server, "/files/get_temporary_link", json!({ "path": entry.id }))
            .await?;
        let link = v["link"].as_str().unwrap_or("");
        if link.is_empty() {
            return Err(SourceError::msg("Dropbox 未返回播放地址"));
        }
        // 签名 URL,不需要也不应该带 Authorization。
        Ok(ResolvedPlay::simple(
            link.to_string(),
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

    /// `.tag` 决定条目类型;deleted 必须被丢掉,否则用户会看到一堆点不开的幽灵条目。
    #[test]
    fn tag_decides_kind_and_deleted_entries_are_dropped() {
        let folder = json!({".tag":"folder","name":"影视","path_lower":"/影视"});
        let e = entry_from_metadata(&folder).unwrap();
        assert!(e.is_dir && e.id == "/影视");

        let file = json!({".tag":"file","name":"a.mkv","path_lower":"/影视/a.mkv","size":42});
        let e = entry_from_metadata(&file).unwrap();
        assert!(!e.is_dir && e.is_video && e.size == Some(42));

        assert!(entry_from_metadata(&json!({".tag":"deleted","name":"x"})).is_none());
    }

    /// id 必须落在 path 上 —— Dropbox 全套接口按路径寻址,
    /// 误用 `id:xxx` 字段会让点进目录和取播放链全部 404。
    #[test]
    fn entry_id_is_the_path_not_the_file_id() {
        let file = json!({".tag":"file","name":"a.mkv","id":"id:abc123",
            "path_lower":"/movies/a.mkv","path_display":"/Movies/A.mkv"});
        assert_eq!(entry_from_metadata(&file).unwrap().id, "/movies/a.mkv");
        // path_lower 缺失时退 path_display,别退成空串(空串=回根目录)。
        let no_lower = json!({".tag":"file","name":"a.mkv","path_display":"/Movies/A.mkv"});
        assert_eq!(entry_from_metadata(&no_lower).unwrap().id, "/Movies/A.mkv");
    }

    /// 搜索结果的嵌套层级两个版本不一致,两种都要认。
    /// 只认一种的话,另一种版本下搜索永远返回空列表且不报错。
    #[test]
    fn search_match_accepts_both_nesting_depths() {
        let deep = json!({"metadata":{"metadata":
            {".tag":"file","name":"a.mkv","path_lower":"/a.mkv"}}});
        assert_eq!(entry_from_search_match(&deep).unwrap().name, "a.mkv");

        let flat = json!({"metadata":{".tag":"file","name":"b.mkv","path_lower":"/b.mkv"}});
        assert_eq!(entry_from_search_match(&flat).unwrap().name, "b.mkv");

        assert!(entry_from_search_match(&json!({})).is_none());
    }
}
