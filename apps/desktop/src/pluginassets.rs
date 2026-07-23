//! `lpplugin://` 自定义协议:喂 iframe 逃生舱和插件图标。
//!
//! 范式照抄同目录的 `imgcache.rs` —— 闭包是**同步**的且跑在 webview UI 线程上,
//! 里面不能 await、绝不能阻塞。
//!
//! URL 形如 `lpplugin://<插件id>/<插件目录内的相对路径>`。
//! 路径穿越防护和 Content-Type 判定在核层 `plugins::assets`(那里可以直接单测,
//! 不必拉起一个 Tauri app)。
//!
//! **为什么逃生舱要走独立协议而不是直接塞进主窗口**:主窗口的 JS 上下文里有
//! `__TAURI_INTERNALS__.invoke`,插件代码进去就等于拿到宿主全部命令,
//! 整套权限模型变成摆设。独立 origin 的 iframe 才有边界,而独立 origin 需要这个协议供文件。

use std::borrow::Cow;

use linplayer_core::plugins::{content_type_for, AssetError};
use tauri::http::{header, Request, Response, StatusCode};
use tauri::{Builder, Manager, Runtime, UriSchemeContext, UriSchemeResponder};

use crate::AppState;

pub const SCHEME: &str = "lpplugin";

pub fn register<R: Runtime>(builder: Builder<R>) -> Builder<R> {
    builder.register_asynchronous_uri_scheme_protocol(
        SCHEME,
        |ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>, responder: UriSchemeResponder| {
            let app = ctx.app_handle().clone();
            let uri = request.uri().clone();
            // Windows 上这是个真 http URL(host = 插件 id);其它平台是 lpplugin://<id>/...。
            // 两边都能从 host + path 拼回来。
            let host = uri.host().unwrap_or_default().to_string();
            let path = uri.path().to_string();

            tauri::async_runtime::spawn(async move {
                let resp = match load(&app, &host, &path) {
                    Ok((bytes, mime)) => Response::builder()
                        .status(StatusCode::OK)
                        .header(header::CONTENT_TYPE, mime)
                        // 逃生舱页面改了要能立刻看到(开发模式插件尤其),不缓存。
                        .header(header::CACHE_CONTROL, "no-store")
                        // 插件资源永远不该被别的页面 fetch 走。
                        .header("X-Content-Type-Options", "nosniff")
                        .body(Cow::Owned(bytes))
                        .unwrap(),
                    Err(e) => {
                        let (code, msg) = match e {
                            AssetError::NotEnabled => (StatusCode::FORBIDDEN, "插件未启用"),
                            AssetError::Forbidden => (StatusCode::FORBIDDEN, "路径不允许"),
                            AssetError::NotFound => (StatusCode::NOT_FOUND, "文件不存在"),
                        };
                        // 失败必须回真实状态码而不是 200+空体 —— 后者会被当成一张坏图或
                        // 一个空白页,前端的 onError 也不触发(「不报错,只是不显示」)。
                        Response::builder()
                            .status(code)
                            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
                            .body(Cow::Owned(msg.as_bytes().to_vec()))
                            .unwrap()
                    }
                };
                responder.respond(resp);
            });
        },
    )
}

fn load<R: Runtime>(
    app: &tauri::AppHandle<R>,
    plugin_id: &str,
    path: &str,
) -> Result<(Vec<u8>, &'static str), AssetError> {
    if plugin_id.is_empty() {
        return Err(AssetError::Forbidden);
    }
    let state = app.state::<AppState>();
    let mgr = state.plugins.get().ok_or(AssetError::NotEnabled)?;
    let file = mgr.asset_path(plugin_id, path)?;
    let mime = content_type_for(&file);
    let bytes = std::fs::read(&file).map_err(|_| AssetError::NotFound)?;
    Ok((bytes, mime))
}
