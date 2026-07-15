// 夸克 TV OAuth(扫码)API 客户端。对齐 Dart quark_tv.dart。
// 与 Cookie 网页 API 是两套鉴权:走 open-api-drive.quark.cn,access_token + 每请求 x-pan-token 签名。
// 令牌兑换/刷新经第三方代理 api.extscreen.com(TV 驱动既定做法)。全逆向接口,需真机+扫码验证。
use super::{is_video_file_name, SourceEntry, SourceError};
use md5::Md5;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

const API: &str = "https://open-api-drive.quark.cn";
const CLIENT_ID: &str = "d3194e61504e493eb6222857bccfed94";
const SIGN_KEY: &str = "kw2dvtd7p4t3pjl2d9ed9yc8yej8kw2d";
const APP_VER: &str = "1.8.2.2";
const CHANNEL: &str = "GENERAL";
const CODE_API: &str = "http://api.extscreen.com/quarkdrive";
const UA: &str = "Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1";

fn now_millis() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
        .to_string()
}

fn md5_hex(s: &str) -> String {
    let mut h = Md5::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn sha256_hex(s: &str) -> String {
    let mut h = Sha256::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// 每安装生成一个稳定 device_id(扫码时用,存进凭据)。
pub fn gen_device_id() -> String {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    md5_hex(&format!("linplayer-quark-{n}"))
}

struct Sign {
    tm: String,
    token: String,
    req_id: String,
}
fn sign(method: &str, pathname: &str, device_id: &str) -> Sign {
    let tm = now_millis();
    let req_id = md5_hex(&format!("{device_id}{tm}"));
    let token = sha256_hex(&format!("{method}&{pathname}&{tm}&{SIGN_KEY}"));
    Sign { tm, token, req_id }
}

fn common_query(device_id: &str, access_token: &str, req_id: &str) -> Vec<(String, String)> {
    [
        ("req_id", req_id),
        ("access_token", access_token),
        ("app_ver", APP_VER),
        ("device_id", device_id),
        ("device_brand", "Xiaomi"),
        ("platform", "tv"),
        ("device_name", "M2004J7AC"),
        ("device_model", "M2004J7AC"),
        ("build_device", "M2004J7AC"),
        ("build_product", "M2004J7AC"),
        ("device_gpu", "Adreno (TM) 550"),
        ("activity_rect", "{}"),
        ("channel", CHANNEL),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

async fn request(
    http: &reqwest::Client,
    pathname: &str,
    method: &str,
    device_id: &str,
    access_token: &str,
    extra_query: &[(&str, &str)],
) -> Result<Value, SourceError> {
    let s = sign(method, pathname, device_id);
    let mut query = common_query(device_id, access_token, &s.req_id);
    query.extend(extra_query.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    let url = format!("{API}{pathname}");
    let req = if method == "POST" {
        http.post(&url)
    } else {
        http.get(&url)
    }
    .query(&query)
    .header("Accept", "application/json, text/plain, */*")
    .header("User-Agent", UA)
    .header("x-pan-tm", &s.tm)
    .header("x-pan-token", &s.token)
    .header("x-pan-client-id", CLIENT_ID);
    let resp = req
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("夸克TV请求失败: {e}")))?;
    let data: Value = resp
        .json()
        .await
        .map_err(|e| SourceError::msg(format!("夸克TV解析失败: {e}")))?;
    let status = data["status"].as_i64();
    let errno = data["errno"].as_i64();
    if status.map(|s| s >= 400).unwrap_or(false) || errno.map(|e| e != 0).unwrap_or(false) {
        let info = data["error_info"].as_str().unwrap_or("").to_string();
        let lower = info.to_lowercase();
        let is_auth = (status == Some(-1) && matches!(errno, Some(10001) | Some(11001)))
            || lower.contains("access token")
            || lower.contains("access_token")
            || lower.contains("token无效")
            || lower.contains("token 无效");
        return Err(SourceError {
            message: if info.is_empty() { "夸克请求失败".into() } else { info },
            is_auth,
        });
    }
    Ok(data)
}

/// 1) 取扫码二维码内容 + query_token。
pub async fn get_login_code(
    http: &reqwest::Client,
    device_id: &str,
) -> Result<(String, String), SourceError> {
    let data = request(
        http,
        "/oauth/authorize",
        "GET",
        device_id,
        "",
        &[
            ("auth_type", "code"),
            ("client_id", CLIENT_ID),
            ("scope", "netdisk"),
            ("qrcode", "1"),
            ("qr_width", "460"),
            ("qr_height", "460"),
        ],
    )
    .await?;
    Ok((
        data["qr_data"].as_str().unwrap_or("").to_string(),
        data["query_token"].as_str().unwrap_or("").to_string(),
    ))
}

/// 2) 轮询:用户扫码确认后返回 code(未确认时接口报错,外层捕获后继续轮询)。
pub async fn get_code(
    http: &reqwest::Client,
    device_id: &str,
    query_token: &str,
) -> Result<String, SourceError> {
    let data = request(
        http,
        "/oauth/code",
        "GET",
        device_id,
        "",
        &[
            ("client_id", CLIENT_ID),
            ("scope", "netdisk"),
            ("query_token", query_token),
        ],
    )
    .await?;
    Ok(data["code"].as_str().unwrap_or("").to_string())
}

/// 3) 用 code 换 token,或用 refresh_token 刷新(经 extscreen 代理)。
/// 返回 (access_token, refresh_token)。
pub async fn exchange_token(
    http: &reqwest::Client,
    device_id: &str,
    code_or_refresh: &str,
    is_refresh: bool,
) -> Result<(String, String), SourceError> {
    let s = sign("POST", "/token", device_id);
    let mut body = json!({
        "req_id": s.req_id, "app_ver": APP_VER, "device_id": device_id,
        "device_brand": "Xiaomi", "platform": "tv", "device_name": "M2004J7AC",
        "device_model": "M2004J7AC", "build_device": "M2004J7AC", "build_product": "M2004J7AC",
        "device_gpu": "Adreno (TM) 550", "activity_rect": "{}", "channel": CHANNEL,
    });
    let key = if is_refresh { "refresh_token" } else { "code" };
    body[key] = json!(code_or_refresh);
    let resp = http
        .post(format!("{CODE_API}/token"))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| SourceError::auth(format!("夸克令牌请求失败: {e}")))?;
    let data: Value = resp
        .json()
        .await
        .map_err(|e| SourceError::auth(format!("夸克令牌解析失败: {e}")))?;
    if data["code"].as_i64() != Some(200) {
        return Err(SourceError::auth(
            data["message"].as_str().unwrap_or("令牌兑换失败").to_string(),
        ));
    }
    let access = data["data"]["access_token"].as_str().unwrap_or("").to_string();
    let refresh = data["data"]["refresh_token"].as_str().unwrap_or("").to_string();
    if refresh.is_empty() {
        return Err(SourceError::auth("未返回 refresh_token"));
    }
    Ok((access, refresh))
}

/// 列目录(TV API)。
pub async fn list_files(
    http: &reqwest::Client,
    device_id: &str,
    access_token: &str,
    parent_fid: &str,
) -> Result<Vec<SourceEntry>, SourceError> {
    let mut entries = Vec::new();
    let mut page = 0;
    while page < 200 {
        let page_s = page.to_string();
        let data = request(
            http,
            "/file",
            "GET",
            device_id,
            access_token,
            &[
                ("method", "list"),
                ("parent_fid", parent_fid),
                ("order_by", "3"),
                ("desc", "1"),
                ("category", ""),
                ("source", ""),
                ("ex_source", ""),
                ("list_all", "0"),
                ("page_size", "100"),
                ("page_index", &page_s),
            ],
        )
        .await?;
        let empty = vec![];
        let files = data["data"]["files"].as_array().unwrap_or(&empty);
        let count = files.len();
        for f in files {
            let is_dir = f["isdir"].as_i64() == Some(1) || f["dir"].as_bool() == Some(true);
            let name = f["filename"].as_str().unwrap_or("").to_string();
            let is_video = !is_dir && (f["category"].as_i64() == Some(1) || is_video_file_name(&name));
            let thumb = f["thumbnail_url"]
                .as_str()
                .filter(|s| s.starts_with("http"))
                .map(|s| s.to_string());
            entries.push(SourceEntry {
                id: f["fid"].as_str().unwrap_or("").to_string(),
                name,
                is_dir,
                is_video,
                size: f["size"].as_i64(),
                thumb_url: thumb,
                raw: None,
            });
        }
        let total = data["data"]["total_count"].as_i64().unwrap_or(count as i64);
        if (page + 1) * 100 >= total as usize || count == 0 {
            break;
        }
        page += 1;
    }
    Ok(entries)
}

/// 取转码播放档位:每档 (resolution, url)。
pub async fn streaming_infos(
    http: &reqwest::Client,
    device_id: &str,
    access_token: &str,
    fid: &str,
) -> Result<Vec<(String, String)>, SourceError> {
    let data = request(
        http,
        "/file",
        "GET",
        device_id,
        access_token,
        &[
            ("method", "streaming"),
            ("group_by", "source"),
            ("fid", fid),
            ("resolution", "low,normal,high,super,2k,4k"),
            ("support", "dolby_vision"),
        ],
    )
    .await?;
    let empty = vec![];
    Ok(data["data"]["video_info"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter_map(|v| {
            let url = v["url"].as_str().unwrap_or("");
            if url.is_empty() {
                None
            } else {
                let res = v["resolution"].as_str().or_else(|| v["name"].as_str()).unwrap_or("");
                Some((res.to_string(), url.to_string()))
            }
        })
        .collect())
}

/// 取原文件直链(转码不可用时回退)。
pub async fn download_link(
    http: &reqwest::Client,
    device_id: &str,
    access_token: &str,
    fid: &str,
) -> Result<String, SourceError> {
    let data = request(
        http,
        "/file",
        "GET",
        device_id,
        access_token,
        &[("method", "download"), ("group_by", "source"), ("fid", fid)],
    )
    .await?;
    let url = data["data"]["download_url"].as_str().unwrap_or("");
    if url.is_empty() {
        return Err(SourceError::msg("未获取到下载地址"));
    }
    Ok(url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sign_shape() {
        // sha256 hex = 64 位;md5 hex = 32 位。
        let s = sign("GET", "/file", "dev123");
        assert_eq!(s.token.len(), 64);
        assert_eq!(s.req_id.len(), 32);
        assert_eq!(gen_device_id().len(), 32);
    }

    /// 打真接口,确认 `qr_data` 到底是**图**还是**URL**。
    ///
    /// 起因:用户报「夸克网盘根本生不出来二维码,报错 The amount of data is too big to be
    /// stored in a QR Code」。我们向 /oauth/authorize 传了 `qr_width=460&qr_height=460`
    /// —— 这两个参数只有在「服务端渲染一张图」时才有意义。若 qr_data 是 base64 图,
    /// 那前端再拿它去 QRCode.toDataURL() 就是**给一张二维码图再编一个二维码**,必然超容量。
    ///
    /// 联网 + 会被限流,故 #[ignore];本地验证:
    ///   cargo test -p linplayer-core quark_qr_data_shape -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "打夸克真接口,需联网"]
    async fn quark_qr_data_shape() {
        let http = reqwest::Client::new();
        let dev = gen_device_id();
        let (qr, tok) = get_login_code(&http, &dev).await.expect("取二维码失败");
        eprintln!("query_token 长度 = {}", tok.len());
        eprintln!("qr_data 长度 = {}", qr.len());
        eprintln!("qr_data 开头 120 字符 = {}", &qr[..qr.len().min(120)]);
        assert!(!qr.is_empty(), "qr_data 为空");
        // 二维码(纠错级 M)的物理上限约 2.3KB。超过就说明它不是待编码的文本。
        eprintln!(
            "→ 判定: {}",
            if qr.starts_with("data:image") || qr.len() > 2300 {
                "qr_data 是**图**,必须 <img src> 直出,不能再编码"
            } else {
                "qr_data 是短文本,可以喂 QRCode.toDataURL"
            }
        );
    }
}
