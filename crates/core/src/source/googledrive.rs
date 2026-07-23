// Google Drive 后端(Drive API v3)。令牌走 oplist 在线服务。
//
// 与 OneDrive/Dropbox 的关键差别:**Drive 不给预签名直链**。
// 能播的组合是 `files/{id}?alt=media` + `Authorization: Bearer`,靠 ResolvedPlay.http_headers
// 传给 mpv 的 http-header-fields。这条路支持 Range,能 seek。
//
// 另外两条看似更简单的路都不能用于流播:
//   - `webContentLink`(drive.google.com/uc?export=download):不支持 Range,大文件还会跳病毒扫描确认页
//   - 无鉴权的 usercontent 直链:同上,且随时可能变
//
// v3 最大的坑是 **fields 不显式写就返回不全** —— 不写的话 size/thumbnailLink/videoMediaMetadata
// 统统没有,表现为"文件列出来了但全是 0 字节、没封面",且不报错。
use super::oplist::OplistAuth;
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use serde_json::Value;
use std::collections::HashMap;

const PROVIDER: &str = "googledrive";
const DRIVER_TXT: &str = "googleui_go";
const API: &str = "https://www.googleapis.com/drive/v3";
const FOLDER_MIME: &str = "application/vnd.google-apps.folder";

/// ★ 必须逐字段列全。漏一个就是"那个字段永远是 None",没有任何报错。
const FIELDS: &str = "nextPageToken,files(id,name,mimeType,size,thumbnailLink,videoMediaMetadata(durationMillis,width,height))";
const PAGE_SIZE: &str = "1000";
const MAX_PAGES: usize = 200;

#[derive(Default)]
pub struct GoogleDriveBackend {
    auth: Option<OplistAuth>,
}

impl GoogleDriveBackend {
    pub fn new() -> Self {
        Self { auth: Some(OplistAuth::new(PROVIDER, DRIVER_TXT)) }
    }

    fn auth(&self) -> &OplistAuth {
        self.auth.as_ref().expect("GoogleDriveBackend 必须用 new() 构造")
    }

    async fn list_query(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        q: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let mut out = Vec::new();
        let mut page_token = String::new();
        for _ in 0..MAX_PAGES {
            let mut forced = false;
            let v = loop {
                let token = self.auth().access_token(http, server, forced).await?;
                let mut req = http
                    .get(format!("{API}/files"))
                    .bearer_auth(&token)
                    .query(&[
                        ("q", q),
                        ("pageSize", PAGE_SIZE),
                        ("fields", FIELDS),
                        ("orderBy", "folder,name"),
                        // 共享云端硬盘(团队盘)里的文件不加这两个参数会整个看不见。
                        ("supportsAllDrives", "true"),
                        ("includeItemsFromAllDrives", "true"),
                    ]);
                if !page_token.is_empty() {
                    req = req.query(&[("pageToken", page_token.as_str())]);
                }
                let resp = req
                    .send()
                    .await
                    .map_err(|e| SourceError::msg(format!("Google Drive 请求失败: {e}")))?;
                if resp.status() == reqwest::StatusCode::UNAUTHORIZED && !forced {
                    forced = true;
                    continue;
                }
                let status = resp.status();
                let v: Value = resp.json().await.map_err(|e| {
                    SourceError::msg(format!("Google Drive 响应解析失败({status}): {e}"))
                })?;
                if let Some(err) = v["error"].as_object() {
                    let msg = err
                        .get("message")
                        .and_then(|m| m.as_str())
                        .unwrap_or("Google Drive 请求失败");
                    return Err(SourceError {
                        message: msg.to_string(),
                        is_auth: status == reqwest::StatusCode::UNAUTHORIZED,
                    });
                }
                break v;
            };
            if let Some(files) = v["files"].as_array() {
                out.extend(files.iter().map(item_to_entry));
            }
            match v["nextPageToken"].as_str().filter(|s| !s.is_empty()) {
                Some(t) => page_token = t.to_string(),
                None => break,
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }
}

/// Drive 查询里的字符串用单引号包起,故内部的 `'` 和 `\` 必须反斜杠转义。
/// 不转义的话,文件名里带撇号(常见于英文片名 Don't...)会让整条查询语法错误。
fn escape_query(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\'', "\\'")
}

fn item_to_entry(m: &Value) -> SourceEntry {
    let mime = m["mimeType"].as_str().unwrap_or("");
    let is_dir = mime == FOLDER_MIME;
    let name = m["name"].as_str().unwrap_or("").to_string();
    let is_video = !is_dir
        && (mime.starts_with("video/")
            || m["videoMediaMetadata"].is_object()
            || is_video_file_name(&name));
    SourceEntry {
        id: m["id"].as_str().unwrap_or("").to_string(),
        name,
        is_dir,
        is_video,
        // size 在 v3 里是**字符串**,不是数字 —— 直接 as_i64() 永远拿到 None。
        size: m["size"].as_str().and_then(|s| s.parse::<i64>().ok()),
        thumb_url: m["thumbnailLink"].as_str().map(|s| s.to_string()),
        raw: None,
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for GoogleDriveBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::googledrive()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let parent = dir_id.filter(|d| !d.is_empty()).unwrap_or("root");
        let q = format!("'{}' in parents and trashed=false", escape_query(parent));
        self.list_query(http, server, &q).await
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let q = format!("name contains '{}' and trashed=false", escape_query(query));
        self.list_query(http, server, &q).await
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        // 这里不发请求:URL 是可推导的,真正的鉴权在 header 上。
        // 只需确保手里的 access_token 是新鲜的(过期了 mpv 会 401,watchdog 会重来)。
        let token = self.auth().access_token(http, server, false).await?;
        // acknowledgeAbuse:Google 对判定为"可能滥用"的文件要求显式确认,否则 403。
        let url = format!(
            "{API}/files/{}?alt=media&acknowledgeAbuse=true&supportsAllDrives=true",
            entry.id
        );
        let mut headers = HashMap::new();
        headers.insert("Authorization".to_string(), format!("Bearer {token}"));
        Ok(ResolvedPlay::simple(url, entry.name.clone(), headers))
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        self.auth().take_rotated(server_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// v3 的 size 是字符串。当成数字读会让每个文件都显示 0 字节,而且不报错。
    #[test]
    fn size_is_parsed_from_string_not_number() {
        let f = serde_json::json!({"id":"1","name":"a.mkv","mimeType":"video/x-matroska","size":"1073741824"});
        assert_eq!(item_to_entry(&f).size, Some(1_073_741_824));
        // 缺失时是 None 而不是 0 —— UI 用它区分"未知大小"和"空文件"。
        let no_size = serde_json::json!({"id":"1","name":"a.mkv","mimeType":"video/x-matroska"});
        assert_eq!(item_to_entry(&no_size).size, None);
    }

    #[test]
    fn folder_mime_marks_directory() {
        let d = serde_json::json!({"id":"1","name":"片库","mimeType":FOLDER_MIME});
        let e = item_to_entry(&d);
        assert!(e.is_dir && !e.is_video);

        let v = serde_json::json!({"id":"2","name":"x.mkv","mimeType":"video/x-matroska"});
        assert!(item_to_entry(&v).is_video);
        // mime 不带 video/ 但有视频元数据时也算(Drive 对某些容器给 application/octet-stream)
        let meta = serde_json::json!({"id":"3","name":"y.bin","mimeType":"application/octet-stream",
            "videoMediaMetadata":{"durationMillis":"1000"}});
        assert!(item_to_entry(&meta).is_video);
    }

    /// 文件名/目录名里的单引号必须转义,否则整条 q 语法错误、目录直接打不开。
    /// 英文片名里的撇号极其常见(Don't Look Up),这不是边角 case。
    #[test]
    fn query_escaping_handles_apostrophes_and_backslashes() {
        assert_eq!(escape_query("Don't"), "Don\\'t");
        assert_eq!(escape_query("a\\b"), "a\\\\b");
        // 反斜杠必须先转,否则会把刚插入的转义反斜杠又转一遍。
        assert_eq!(escape_query("a\\'b"), "a\\\\\\'b");
    }
}
