//! `lpimg` 自定义 URI scheme:`<img src>` 的字节由 Rust 给,走磁盘缓存,不过 IPC。
//!
//! ## 解决什么
//! 用户 2026-07-15:「你根本没做持久化缓存 媒体库封面 条目的图片封面……每次都要重新加载,
//! 服务器压力很大」。此前前端是把 `{server}/Items/{id}/Images/Primary?api_key={token}`
//! 直接塞进 `<img src>`,由 webview 去拉 —— 关掉程序缓存就没了,**而且 api_key 进 DOM**。
//!
//! 现在前端只给 `lpimg://…/i/{itemId}/Primary?h=480`,**URL 里没有 token**;
//! 上游地址由这里从会话里现拼,字节先查 [`linplayer_core::image_cache`](2GB/30 天)。
//!
//! ## 为什么不吐 base64 data URI(icon_cache 那种做法)
//! 服务器图标一次就一个,封面一屏几十张、翻一次库几百张。base64 有 33% 膨胀,
//! 还要过 IPC 序列化成 JSON 字符串再在 JS 里解 —— 那是给主线程加活。
//! icon_cache 的注释里也写了「真到要缓存大图的那天再开 asset 协议」,就是今天。
//!
//! ## 前端 URL 因平台而异(别写死)
//! Windows/Android 是 `http://lpimg.localhost/…`,Linux/macOS 是 `lpimg://localhost/…`
//! (来自 tauri 注入的 core.js)。前端用 `convertFileSrc("", "lpimg")` 取这个前缀。
//!
//! 事实核对于 tauri 2.11.5 / wry 0.55.1 / http 1.4.2。

use crate::AppState;
use linplayer_core::image_cache;
use std::borrow::Cow;
use tauri::http::{header, Request, Response, StatusCode};
use tauri::{Builder, Manager, Runtime, UriSchemeContext, UriSchemeResponder};

pub const SCHEME: &str = "lpimg";

/// 挂到 builder 链上。
pub fn register<R: Runtime>(builder: Builder<R>) -> Builder<R> {
    builder.register_asynchronous_uri_scheme_protocol(
        SCHEME,
        |ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>, responder: UriSchemeResponder| {
            /* ★ 这个闭包是**同步**的 `Fn(..) -> ()`,而且跑在 webview 的 UI 线程上 ——
               里面不能 await,也绝不能阻塞(阻塞 = 整个界面卡住,正是我们要修的那类毛病)。
               把要用的东西取出来,活儿交给 tauri 的全局 tokio 运行时,responder 移进去,
               wry 会负责把响应 marshal 回 UI 线程。 */
            let app = ctx.app_handle().clone();
            let path = request.uri().path().to_string();
            let query = request.uri().query().unwrap_or_default().to_string();

            tauri::async_runtime::spawn(async move {
                let resp = match load(&app, &path, &query).await {
                    Ok(bytes) => {
                        let mime = sniff(&bytes);
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(header::CONTENT_TYPE, mime)
                            /* 头会被原样透传给 WebView2 / WebKitGTK。Windows 上这是个真
                               `http://` URL,浏览器自己那层内存缓存会认;Linux 的
                               `lpimg://` 非 http scheme 大概率不认 —— **没验证过,别指望它**。
                               承重的是磁盘缓存,这个头只是白捡的。 */
                            .header(header::CACHE_CONTROL, "public, max-age=604800")
                            .body(Cow::Owned(bytes))
                            .unwrap()
                    }
                    /* 失败必须回 404 而不是 200+空体:空体会被当成一张坏图,
                       前端的 onError 也不触发 —— 又一个「不报错,只是不显示」。 */
                    Err(e) => Response::builder()
                        .status(StatusCode::NOT_FOUND)
                        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
                        .body(Cow::Owned(e.into_bytes()))
                        .unwrap(),
                };
                responder.respond(resp);
            });
        },
    )
}

/// `/i/{itemId}/{kind}` → (itemId, kind)。kind 只认白名单。
///
/// ★ path 是**从 webview 来的、可被页面内容影响的字符串**,当它不可信:
///   itemId 会被拼进上游 URL,kind 会被拼进路径。这里卡死形状,
///   不让 `../` 之类的东西流到 URL 拼接里去。
fn parse(path: &str) -> Option<(String, &'static str)> {
    let mut it = path.trim_start_matches('/').split('/');
    if it.next()? != "i" {
        return None;
    }
    let id = it.next()?;
    let kind = match it.next()? {
        "Primary" => "Primary",
        "Backdrop" => "Backdrop",
        "Logo" => "Logo",
        _ => return None,
    };
    if it.next().is_some() {
        return None; // 多余的段 = 不是我们的格式
    }
    // Emby 的 id 是十六进制/GUID 形状。放行 [0-9a-zA-Z-] 足够,也堵死了 ../ 和 ? &
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return None;
    }
    Some((id.to_string(), kind))
}

/// 查缓存 → 回源 → 落缓存。
async fn load<R: Runtime>(
    app: &tauri::AppHandle<R>,
    path: &str,
    query: &str,
) -> Result<Vec<u8>, String> {
    let (id, kind) = parse(path).ok_or("路径格式不对")?;
    let state = app.state::<AppState>();

    // ★ 锁不跨 await。
    let (acct_key, base, token) = {
        let cfg = state.config.lock().unwrap();
        let a = cfg.active_account().ok_or("没有活跃账号")?;
        (a.server.clone(), a.active_line_url(), a.token.clone())
    };

    /* 缓存键用**账号主键**(a.server)而不是当前线路地址:同一张图换条线路拉还是同一张图,
       用线路地址当键的话,用户一切线路整盘缓存就全部落空。
       更不能用完整上游 URL —— 那里面有 api_key,重登一次 token 变了,缓存全废。 */
    let key = format!("{acct_key}|{id}|{kind}|{query}");

    /* ★ 必须 spawn_blocking:image_cache 是同步 fs::read。
       直接在 async fn 里读盘 = 阻塞 tokio worker,一屏几十张图并发时把整个运行时按住 ——
       **和刚修的 whisper_deps 一模一样的病,我在同一个 commit 里又犯了一遍**。
       内存命中不碰盘,但这里预先不知道会不会命中,所以一律当阻塞的处理。 */
    let k = key.clone();
    if let Some(b) = tokio::task::spawn_blocking(move || image_cache::get_2l(&k))
        .await
        .map_err(|e| format!("读缓存任务崩了: {e}"))?
    {
        return Ok(b);
    }

    // Backdrop 要带序号;Primary/Logo 不带。
    let seg = if kind == "Backdrop" { "Backdrop/0".to_string() } else { kind.to_string() };
    let mut url = format!("{}/Items/{id}/Images/{seg}?quality=90", base.trim_end_matches('/'));
    // query 是前端给的尺寸(maxHeight=480 之类)。只放行已知键,别把任意 query 拼给上游。
    for kv in query.split('&').filter(|s| !s.is_empty()) {
        let Some((k, v)) = kv.split_once('=') else { continue };
        if !v.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        match k {
            "h" => url.push_str(&format!("&maxHeight={v}")),
            "w" => url.push_str(&format!("&maxWidth={v}")),
            _ => {}
        }
    }

    /* reqwest 默认就跟 301(Policy::default = 最多 10 跳),这里依赖这个行为:
       实测(2026-07-15)UHD 那台服务器的 /Items/{id}/Images/Backdrop/0 会 **301 跳到
       静态文件** /img/i/fanart/{id}.jpg。不跟跳只会拿到 79 字节的 HTML,
       然后被 sniff 判成 octet-stream —— 表现为「图不显示但也不报错」。
       别给这个 client 关掉 redirect。 */
    let resp = state
        .http
        .get(&url)
        .header("X-Emby-Token", &token)
        .send()
        .await
        .map_err(|e| format!("取图失败: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("上游 HTTP {}", resp.status()));
    }
    let bytes = resp.bytes().await.map_err(|e| format!("读图失败: {e}"))?.to_vec();

    // 写盘是同步 IO,挪出 async worker;顺带把 bytes 还回来免得多克隆一份。
    let bytes = tokio::task::spawn_blocking(move || {
        image_cache::put_2l(&key, &bytes);
        bytes
    })
    .await
    .map_err(|e| format!("写缓存任务崩了: {e}"))?;
    Ok(bytes)
}

/// 按魔数嗅 MIME。**不能信上游的 Content-Type**:反代经常把它抹成
/// application/octet-stream,那样浏览器不认,图就是不显示且不报错(icon_cache 同款教训)。
fn sniff(b: &[u8]) -> &'static str {
    match b {
        [0xFF, 0xD8, 0xFF, ..] => "image/jpeg",
        [0x89, b'P', b'N', b'G', ..] => "image/png",
        [b'G', b'I', b'F', b'8', ..] => "image/gif",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniff_reads_magic_bytes() {
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), "image/jpeg");
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\n"), "image/png");
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), "image/webp");
        assert_eq!(sniff(b"nope"), "application/octet-stream");
    }

    #[test]
    fn parses_good_paths() {
        assert_eq!(parse("/i/abc123/Primary"), Some(("abc123".into(), "Primary")));
        assert_eq!(parse("/i/abc123/Backdrop"), Some(("abc123".into(), "Backdrop")));
        assert_eq!(parse("/i/a-b-c/Logo"), Some(("a-b-c".into(), "Logo")));
    }

    /// ★ path 来自 webview,当它不可信:itemId 会被拼进上游 URL。
    /// 放行 `..` / `?` / `&` 就等于把上游请求的构造权交出去。
    #[test]
    fn rejects_hostile_or_malformed_paths() {
        for bad in [
            "/i/../../etc/passwd/Primary", // 路径穿越
            "/i/abc/Primary/extra",        // 多余的段
            "/i/abc/Restore",              // 不在白名单的 kind
            "/i//Primary",                 // 空 id
            "/x/abc/Primary",              // 前缀不对
            "/i/abc",                      // 缺 kind
            "/i/ab?c/Primary",             // id 里带 query 分隔符
            "/i/ab&c=1/Primary",           // id 里带参数拼接
        ] {
            assert_eq!(parse(bad), None, "这个路径必须被拒:{bad}");
        }
    }
}
