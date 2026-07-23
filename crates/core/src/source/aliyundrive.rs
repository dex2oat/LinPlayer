// 阿里云盘后端。令牌走 oplist 在线服务 → 拿到的是**开放平台** access_token,
// 于是走 open.alipan.com 那套有官方文档的接口。
//
// ★ 这条路把网页版逆向最难的一关整个绕开了:网页/客户端接口从 2023-02-13 起强制
//   `x-signature`(ECDSA secp256k1 + /users/device/create_session + nonce 严格递增),
//   开放平台只认 Bearer,一行签名代码都不用写。
//
// 根目录列两个盘(资源库/备份盘):只挑一个的话,文件在另一个盘的用户会看到空目录且无从察觉。
use super::oplist::OplistAuth;
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, PlayQuality, ResolvedPlay, SourceEntry,
    SourceError, SourceKind, SourceServer,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

const PROVIDER: &str = "alicloud";
const DRIVER_TXT: &str = "alicloud_qr";
const API: &str = "https://open.alipan.com";
const PAGE_LIMIT: i64 = 200; // 开放平台上限
const MAX_PAGES: usize = 200;
/// 直链有效期。取上限附近,减少长片播到一半失效的概率(过期仍有 watchdog 兜底)。
const DOWNLOAD_EXPIRE_SEC: i64 = 14400;

/// 转码档位 → 展示名 + 权重。与夸克的 quality_meta 同构,保证两个源的档位排序一致。
fn template_meta(t: &str) -> (String, i32) {
    match t.to_lowercase().as_str() {
        "ld" => ("流畅 360P".into(), 1),
        "sd" => ("标清 480P".into(), 2),
        "hd" => ("高清 720P".into(), 3),
        "fhd" => ("超清 1080P".into(), 4),
        "qhd" => ("2K".into(), 5),
        "uhd" | "4k" => ("4K".into(), 6),
        "" => ("默认".into(), 0),
        other => (other.to_uppercase(), 0),
    }
}

/// 原画(直链)的档位 id。权重给最高 —— 原文件保留内封音轨/字幕,优于任何转码流。
const ORIGIN_ID: &str = "origin";

#[derive(Default)]
pub struct AliyunDriveBackend {
    auth: Option<OplistAuth>,
    /// server.id -> [(drive_id, 展示名)]
    drives: Mutex<HashMap<String, Vec<(String, String)>>>,
}

impl AliyunDriveBackend {
    pub fn new() -> Self {
        Self {
            auth: Some(OplistAuth::new(PROVIDER, DRIVER_TXT)),
            drives: Mutex::new(HashMap::new()),
        }
    }

    fn auth(&self) -> &OplistAuth {
        self.auth.as_ref().expect("AliyunDriveBackend 必须用 new() 构造")
    }

    fn api(server: &SourceServer) -> String {
        let b = super::normalize_base_url(&server.base_url);
        if b.is_empty() {
            API.to_string()
        } else {
            b
        }
    }

    async fn post(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        body: Value,
    ) -> Result<Value, SourceError> {
        let url = format!("{}{path}", Self::api(server));
        let mut forced = false;
        loop {
            let token = self.auth().access_token(http, server, forced).await?;
            let resp = http
                .post(&url)
                .bearer_auth(&token)
                .header("Content-Type", "application/json")
                .json(&body)
                .send()
                .await
                .map_err(|e| SourceError::msg(format!("阿里云盘请求失败: {e}")))?;
            let status = resp.status();
            if status == reqwest::StatusCode::UNAUTHORIZED && !forced {
                forced = true;
                continue;
            }
            let v: Value = resp
                .json()
                .await
                .map_err(|e| SourceError::msg(format!("阿里云盘响应解析失败({status}): {e}")))?;
            if !status.is_success() {
                let msg = v["message"]
                    .as_str()
                    .or_else(|| v["code"].as_str())
                    .unwrap_or("阿里云盘请求失败");
                // 429 单独说清楚 —— 云盘限流很常见,说成"请求失败"用户只会以为是网络问题。
                let msg = if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
                    "阿里云盘限流，请稍后再试".to_string()
                } else {
                    msg.to_string()
                };
                return Err(SourceError {
                    message: msg,
                    is_auth: status == reqwest::StatusCode::UNAUTHORIZED,
                });
            }
            return Ok(v);
        }
    }

    /// 取该账号的盘列表(资源库/备份盘),带缓存。
    async fn drive_list(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
    ) -> Result<Vec<(String, String)>, SourceError> {
        if let Some(d) = self.drives.lock().unwrap().get(&server.id) {
            if !d.is_empty() {
                return Ok(d.clone());
            }
        }
        // 用户显式指定了盘就只用它。
        if let Some(fixed) = server.extra.get("drive_id").filter(|s| !s.is_empty()) {
            let list = vec![(fixed.clone(), "我的云盘".to_string())];
            self.drives.lock().unwrap().insert(server.id.clone(), list.clone());
            return Ok(list);
        }
        let v = self
            .post(http, server, "/adrive/v1.0/user/getDriveInfo", json!({}))
            .await?;
        let mut list = Vec::new();
        let push = |key: &str, label: &str, list: &mut Vec<(String, String)>| {
            if let Some(id) = v[key].as_str().filter(|s| !s.is_empty()) {
                if !list.iter().any(|(d, _)| d == id) {
                    list.push((id.to_string(), label.to_string()));
                }
            }
        };
        push("resource_drive_id", "资源库", &mut list);
        push("backup_drive_id", "备份盘", &mut list);
        push("default_drive_id", "我的云盘", &mut list);
        if list.is_empty() {
            return Err(SourceError::auth("未取到云盘信息，请重新授权"));
        }
        self.drives.lock().unwrap().insert(server.id.clone(), list.clone());
        Ok(list)
    }

    async fn list_in_drive(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        drive_id: &str,
        parent: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let mut out = Vec::new();
        let mut marker = String::new();
        for _ in 0..MAX_PAGES {
            let mut body = json!({
                "drive_id": drive_id,
                "parent_file_id": parent,
                "limit": PAGE_LIMIT,
                "order_by": "name",
                "order_direction": "ASC",
                "fields": "*",
            });
            if !marker.is_empty() {
                body["marker"] = json!(marker);
            }
            let v = self
                .post(http, server, "/adrive/v1.0/openFile/list", body)
                .await?;
            if let Some(items) = v["items"].as_array() {
                out.extend(items.iter().map(|i| item_to_entry(i, drive_id)));
            }
            // 分页用不透明 marker,不是 offset;空串即到底。
            match v["next_marker"].as_str().filter(|s| !s.is_empty()) {
                Some(m) => marker = m.to_string(),
                None => break,
            }
        }
        Ok(out)
    }
}

/// entry.id 编码成 `drive_id:file_id` —— 阿里云盘所有接口都要 drive_id,
/// 而 trait 只传得回一个 id 字符串。
fn encode_id(drive_id: &str, file_id: &str) -> String {
    format!("{drive_id}:{file_id}")
}

fn decode_id(id: &str) -> Option<(&str, &str)> {
    let (d, f) = id.split_once(':')?;
    (!d.is_empty() && !f.is_empty()).then_some((d, f))
}

fn item_to_entry(m: &Value, drive_id: &str) -> SourceEntry {
    let is_dir = m["type"].as_str() == Some("folder");
    let name = m["name"].as_str().unwrap_or("").to_string();
    let is_video =
        !is_dir && (m["category"].as_str() == Some("video") || is_video_file_name(&name));
    // 条目自带的 drive_id 优先(搜索结果可能跨盘)。
    let owner = m["drive_id"].as_str().filter(|s| !s.is_empty()).unwrap_or(drive_id);
    SourceEntry {
        id: encode_id(owner, m["file_id"].as_str().unwrap_or("")),
        name,
        is_dir,
        is_video,
        size: m["size"].as_i64(),
        thumb_url: m["thumbnail"].as_str().map(|s| s.to_string()),
        raw: None,
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for AliyunDriveBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::aliyundrive()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let drives = self.drive_list(http, server).await?;
        let Some(d) = dir_id.filter(|d| !d.is_empty()) else {
            // 根:只有一个盘就直接展开它,别让用户多点一层。
            if drives.len() == 1 {
                let (id, _) = &drives[0];
                let mut e = self.list_in_drive(http, server, id, "root").await?;
                sort_entries(&mut e);
                return Ok(e);
            }
            return Ok(drives
                .iter()
                .map(|(id, label)| SourceEntry {
                    id: encode_id(id, "root"),
                    name: label.clone(),
                    is_dir: true,
                    is_video: false,
                    size: None,
                    thumb_url: None,
                    raw: None,
                })
                .collect());
        };
        let (drive_id, file_id) =
            decode_id(d).ok_or_else(|| SourceError::msg("目录标识不合法"))?;
        let mut e = self.list_in_drive(http, server, drive_id, file_id).await?;
        sort_entries(&mut e);
        Ok(e)
    }

    async fn search(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let drives = self.drive_list(http, server).await?;
        let mut out = Vec::new();
        for (drive_id, _) in &drives {
            // 查询语法是类 SQL 的表达式,字符串用双引号包 —— 内部的双引号和反斜杠必须转义。
            let q = format!(
                "name match \"{}\"",
                query.replace('\\', "\\\\").replace('"', "\\\"")
            );
            let v = self
                .post(
                    http,
                    server,
                    "/adrive/v1.0/openFile/search",
                    json!({ "drive_id": drive_id, "query": q, "limit": PAGE_LIMIT }),
                )
                .await?;
            if let Some(items) = v["items"].as_array() {
                out.extend(items.iter().map(|i| item_to_entry(i, drive_id)));
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let (drive_id, file_id) =
            decode_id(&entry.id).ok_or_else(|| SourceError::msg("文件标识不合法"))?;

        // 转码档位(可能为空:未转码完成/不支持的容器)。失败不致命,原画那条路仍在。
        let mut qualities = vec![PlayQuality {
            id: ORIGIN_ID.to_string(),
            label: "原画".to_string(),
            rank: 100,
        }];
        let mut transcoded: Vec<(String, String)> = Vec::new();
        if let Ok(v) = self
            .post(
                http,
                server,
                "/adrive/v1.0/openFile/getVideoPreviewPlayInfo",
                json!({
                    "drive_id": drive_id,
                    "file_id": file_id,
                    "category": "live_transcoding",
                }),
            )
            .await
        {
            let empty = vec![];
            for t in v["video_preview_play_info"]["live_transcoding_task_list"]
                .as_array()
                .unwrap_or(&empty)
            {
                // 只收转码完成的:status=running 的 url 是空的,选中就是黑屏。
                if t["status"].as_str() != Some("finished") {
                    continue;
                }
                let (Some(tpl), Some(url)) = (t["template_id"].as_str(), t["url"].as_str()) else {
                    continue;
                };
                if url.is_empty() {
                    continue;
                }
                let (label, rank) = template_meta(tpl);
                qualities.push(PlayQuality { id: tpl.to_string(), label, rank });
                transcoded.push((tpl.to_string(), url.to_string()));
            }
        }
        qualities.sort_by(|a, b| b.rank.cmp(&a.rank));

        // 选中了某个转码档就用它。
        if let Some(qid) = quality_id.filter(|q| *q != ORIGIN_ID) {
            if let Some((_, url)) = transcoded.iter().find(|(t, _)| t == qid) {
                return Ok(ResolvedPlay {
                    url: url.clone(),
                    title: entry.name.clone(),
                    http_headers: HashMap::new(),
                    user_agent_override: None,
                    subtitles: vec![],
                    qualities,
                    selected_quality_id: Some(qid.to_string()),
                });
            }
        }

        // 缺省原画:直链保留内封音轨/字幕,优于任何转码流。
        let v = self
            .post(
                http,
                server,
                "/adrive/v1.0/openFile/getDownloadUrl",
                json!({
                    "drive_id": drive_id,
                    "file_id": file_id,
                    "expire_sec": DOWNLOAD_EXPIRE_SEC,
                }),
            )
            .await?;
        let url = v["url"]
            .as_str()
            .or_else(|| v["cdn_url"].as_str())
            .unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("阿里云盘未返回下载地址"));
        }
        Ok(ResolvedPlay {
            url: url.to_string(),
            title: entry.name.clone(),
            http_headers: HashMap::new(),
            user_agent_override: None,
            subtitles: vec![],
            qualities,
            selected_quality_id: Some(ORIGIN_ID.to_string()),
        })
    }

    fn take_rotated_credentials(&self, server_id: &str) -> Option<HashMap<String, String>> {
        self.auth().take_rotated(server_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// id 必须能带着 drive_id 往返 —— 丢了它,所有接口都不知道该查哪个盘。
    #[test]
    fn id_roundtrips_drive_and_file() {
        let id = encode_id("d1", "f2");
        assert_eq!(id, "d1:f2");
        assert_eq!(decode_id(&id), Some(("d1", "f2")));
        // 残缺的一律拒绝,别拿空 drive_id 去打接口(会得到一句看不懂的服务端报错)。
        for bad in ["", ":", "d1:", ":f2", "nosep"] {
            assert_eq!(decode_id(bad), None, "{bad} 不该被当成合法标识");
        }
    }

    /// 条目自带的 drive_id 优先于上下文 —— 搜索结果可能来自另一个盘,
    /// 用上下文的 drive_id 去取流会 404。
    #[test]
    fn item_prefers_its_own_drive_id() {
        let cross = json!({"type":"file","name":"a.mkv","file_id":"f9","drive_id":"other"});
        assert_eq!(item_to_entry(&cross, "ctx").id, "other:f9");
        let plain = json!({"type":"file","name":"a.mkv","file_id":"f9"});
        assert_eq!(item_to_entry(&plain, "ctx").id, "ctx:f9");
    }

    #[test]
    fn category_or_extension_marks_video() {
        let by_cat = json!({"type":"file","name":"noext","file_id":"1","category":"video"});
        assert!(item_to_entry(&by_cat, "d").is_video);
        let by_ext = json!({"type":"file","name":"x.mkv","file_id":"1"});
        assert!(item_to_entry(&by_ext, "d").is_video);
        let folder = json!({"type":"folder","name":"dir","file_id":"1","category":"video"});
        let e = item_to_entry(&folder, "d");
        assert!(e.is_dir && !e.is_video, "目录不该被 category 误判成视频");
    }

    /// 档位排序与夸克一致(降序),且原画恒在最前。
    #[test]
    fn origin_outranks_every_transcode_template() {
        let mut q = vec![
            PlayQuality { id: ORIGIN_ID.into(), label: "原画".into(), rank: 100 },
            PlayQuality { id: "FHD".into(), label: template_meta("FHD").0, rank: template_meta("FHD").1 },
            PlayQuality { id: "LD".into(), label: template_meta("LD").0, rank: template_meta("LD").1 },
        ];
        q.sort_by(|a, b| b.rank.cmp(&a.rank));
        assert_eq!(q[0].id, ORIGIN_ID);
        assert_eq!(q[1].id, "FHD");
        assert_eq!(template_meta("fhd").0, "超清 1080P", "档位名大小写不敏感");
    }
}
