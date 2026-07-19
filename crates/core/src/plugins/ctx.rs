//! 把宿主能力原生绑进插件的全局 `ctx`。
//!
//! 相对 Dart 版:不再有 `__lp_host` 单一字符串通道 + 227 行引导脚本。每个能力就是一个原生
//! 绑定;host 路由类(player/ui/emby/cfproxy)全部收敛到一个 `host_fn` helper(同构:查权限
//! -> 转发参数给宿主)。http/storage/sleep 在 core 内自持;log/extensions/生命周期是同步绑定。

use std::sync::Arc;
use std::time::Duration;

use rquickjs::prelude::{Async, Rest};
use rquickjs::{Coerced, Ctx, Exception, Function, Object, Persistent, Value};
use serde_json::{json, Value as Json};

use super::convert::{js_to_json, json_to_js};
use super::extensions::{ExtensionType, RegisteredExtension};
use super::state::{CtxState, JsOut, JsonVal, PersistentFn};

fn throw<'js>(ctx: &Ctx<'js>, msg: String) -> rquickjs::Error {
    Exception::throw_message(ctx, &msg)
}

/// host 路由绑定:查权限 -> 把原始参数(JSON)转发给宿主。player/ui/emby/cfproxy 共用。
fn host_fn<'js>(
    ctx: &Ctx<'js>,
    state: &Arc<CtxState>,
    perm: Option<&'static str>,
    channel: &'static str,
    method: &'static str,
) -> rquickjs::Result<Function<'js>> {
    let st = state.clone();
    Function::new(
        ctx.clone(),
        Async(move |args: Rest<JsonVal>| {
            let st = st.clone();
            async move {
                if let Some(p) = perm {
                    if let Err(e) = st.require(p) {
                        return JsOut(Err(e));
                    }
                }
                let jargs: Vec<Json> = args.0.into_iter().map(|j| j.0).collect();
                JsOut(st.host_call(channel, method, jargs).await)
            }
        }),
    )
}

fn http_fn<'js>(ctx: &Ctx<'js>, state: &Arc<CtxState>, method: &'static str) -> rquickjs::Result<Function<'js>> {
    let st = state.clone();
    Function::new(
        ctx.clone(),
        Async(move |args: Rest<JsonVal>| {
            let st = st.clone();
            async move {
                let jargs: Vec<Json> = args.0.into_iter().map(|j| j.0).collect();
                JsOut(st.http_request(method, jargs).await)
            }
        }),
    )
}

fn log_fn<'js>(ctx: &Ctx<'js>, state: &Arc<CtxState>, level: &'static str) -> rquickjs::Result<Function<'js>> {
    let st = state.clone();
    Function::new(ctx.clone(), move |msg: Coerced<String>| -> rquickjs::Result<()> {
        st.host.log(&st.plugin_id, level, &msg.0);
        Ok(())
    })
}

fn lifecycle_fn<'js>(ctx: &Ctx<'js>, state: &Arc<CtxState>, name: &'static str) -> rquickjs::Result<Function<'js>> {
    let st = state.clone();
    Function::new(ctx.clone(), move |ctx: Ctx<'js>, f: Function<'js>| -> rquickjs::Result<()> {
        let p = Persistent::save(&ctx, f);
        st.lifecycle.lock().unwrap().insert(name.to_string(), p);
        Ok(())
    })
}

pub fn install<'js>(ctx: &Ctx<'js>, state: &Arc<CtxState>, meta: &Json) -> rquickjs::Result<()> {
    let c = Object::new(ctx.clone())?;

    // ---- ctx.log(始终可用)----
    let log = Object::new(ctx.clone())?;
    log.set("info", log_fn(ctx, state, "info")?)?;
    log.set("warn", log_fn(ctx, state, "warn")?)?;
    log.set("error", log_fn(ctx, state, "error")?)?;
    c.set("log", log)?;

    // ---- ctx.http(仅 HTTPS + 白名单)----
    let http = Object::new(ctx.clone())?;
    http.set("get", http_fn(ctx, state, "get")?)?;
    http.set("post", http_fn(ctx, state, "post")?)?;
    http.set("delete", http_fn(ctx, state, "delete")?)?;
    c.set("http", http)?;

    // ---- ctx.storage ----
    let storage = Object::new(ctx.clone())?;
    {
        let st = state.clone();
        storage.set(
            "get",
            Function::new(ctx.clone(), Async(move |key: String| {
                let st = st.clone();
                async move {
                    if let Err(e) = st.require("storage") { return JsOut(Err(e)); }
                    JsOut(Ok(st.storage.get(&key).await))
                }
            }))?,
        )?;
    }
    {
        let st = state.clone();
        storage.set(
            "set",
            Function::new(ctx.clone(), Async(move |key: String, val: JsonVal| {
                let st = st.clone();
                async move {
                    if let Err(e) = st.require("storage") { return JsOut(Err(e)); }
                    JsOut(st.storage.set(&key, val.0).await.map(|_| Json::Null))
                }
            }))?,
        )?;
    }
    {
        let st = state.clone();
        storage.set(
            "delete",
            Function::new(ctx.clone(), Async(move |key: String| {
                let st = st.clone();
                async move {
                    if let Err(e) = st.require("storage") { return JsOut(Err(e)); }
                    JsOut(st.storage.delete(&key).await.map(|_| Json::Null))
                }
            }))?,
        )?;
    }
    {
        let st = state.clone();
        storage.set(
            "keys",
            Function::new(ctx.clone(), Async(move |_: Rest<JsonVal>| {
                let st = st.clone();
                async move {
                    if let Err(e) = st.require("storage") { return JsOut(Err(e)); }
                    JsOut(Ok(json!(st.storage.keys().await)))
                }
            }))?,
        )?;
    }
    {
        let st = state.clone();
        storage.set(
            "clear",
            Function::new(ctx.clone(), Async(move |_: Rest<JsonVal>| {
                let st = st.clone();
                async move {
                    if let Err(e) = st.require("storage") { return JsOut(Err(e)); }
                    JsOut(st.storage.clear().await.map(|_| Json::Null))
                }
            }))?,
        )?;
    }
    c.set("storage", storage)?;

    // ---- ctx.player ----
    let player = Object::new(ctx.clone())?;
    player.set("getCurrentMedia", host_fn(ctx, state, Some("player.read"), "player", "getCurrentMedia")?)?;
    player.set("getCacheLimitBytes", host_fn(ctx, state, Some("player.read"), "player", "getCacheLimitBytes")?)?;
    player.set("play", host_fn(ctx, state, Some("player.control"), "player", "play")?)?;
    player.set("pause", host_fn(ctx, state, Some("player.control"), "player", "pause")?)?;
    player.set("seek", host_fn(ctx, state, Some("player.control"), "player", "seek")?)?;
    {
        // on(event, fn):需 player.read;存 Persistent 供宿主派发事件时回调。
        let st = state.clone();
        player.set(
            "on",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, event: String, f: Function<'js>| -> rquickjs::Result<()> {
                st.require("player.read").map_err(|e| throw(&ctx, e))?;
                let p = Persistent::save(&ctx, f);
                st.events.lock().unwrap().entry(event).or_default().push(p);
                Ok(())
            })?,
        )?;
    }
    {
        // off(event):ponytail: 按事件整体清空(不做函数身份匹配)。Persistent 难比对身份,
        //            且插件极少用 off。要精确移除时改存 (id, fn) 并按 id 摘除。
        let st = state.clone();
        player.set(
            "off",
            Function::new(ctx.clone(), move |event: String| -> rquickjs::Result<()> {
                st.events.lock().unwrap().remove(&event);
                Ok(())
            })?,
        )?;
    }
    c.set("player", player)?;

    // ---- ctx.ui(全部需 ui)----
    let ui = Object::new(ctx.clone())?;
    for m in [
        "showToast", "showDialog", "showForm", "showList", "openPage",
        "showProgress", "updateProgress", "closeProgress",
    ] {
        ui.set(m, host_fn(ctx, state, Some("ui"), "ui", m)?)?;
    }
    c.set("ui", ui)?;

    // ---- ctx.emby ----
    let emby = Object::new(ctx.clone())?;
    emby.set("getServerUrl", host_fn(ctx, state, Some("emby.read"), "emby", "getServerUrl")?)?;
    emby.set("getServerInfo", host_fn(ctx, state, Some("emby.read"), "emby", "getServerInfo")?)?;
    emby.set("getCurrentUser", host_fn(ctx, state, Some("emby.read"), "emby", "getCurrentUser")?)?;
    emby.set("getCredentials", host_fn(ctx, state, Some("emby.credentials"), "emby", "getCredentials")?)?;
    emby.set("apiRequest", host_fn(ctx, state, Some("emby.api"), "emby", "apiRequest")?)?;
    c.set("emby", emby)?;

    // ---- ctx.extensions ----
    let ext = Object::new(ctx.clone())?;
    {
        let st = state.clone();
        ext.set(
            "register",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, type_str: String, descriptor: Value<'js>| -> rquickjs::Result<Value<'js>> {
                st.require("extensions").map_err(|e| throw(&ctx, e))?;
                let etype = ExtensionType::from_id(&type_str)
                    .ok_or_else(|| throw(&ctx, format!("未知扩展点类型: {type_str}")))?;
                // 抽出描述里的函数存进 handler 表,原位换成 {__handler__:id}。
                let mut newh: Vec<(String, PersistentFn)> = Vec::new();
                let data = js_to_json(&descriptor, &mut |func| {
                    let id = st.next_handler_id();
                    newh.push((id.clone(), Persistent::save(&ctx, func)));
                    id
                });
                {
                    let mut h = st.handlers.lock().unwrap();
                    for (id, p) in newh {
                        h.insert(id, p);
                    }
                }
                let ext_id = data
                    .get("id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("ext_{}", st.next_handler_id()));
                let registered = st.registry.register(RegisteredExtension {
                    plugin_id: st.plugin_id.clone(),
                    type_: etype,
                    id: ext_id.clone(),
                    data,
                    from_manifest: false,
                });
                st.host.extensions_changed();
                json_to_js(&ctx, &json!({ "id": ext_id, "registered": registered }))
            })?,
        )?;
    }
    {
        let st = state.clone();
        ext.set(
            "unregister",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, type_str: String, id: String| -> rquickjs::Result<()> {
                st.require("extensions").map_err(|e| throw(&ctx, e))?;
                let etype = ExtensionType::from_id(&type_str)
                    .ok_or_else(|| throw(&ctx, format!("未知扩展点类型: {type_str}")))?;
                st.registry.unregister(&st.plugin_id, etype, &id);
                st.host.extensions_changed();
                Ok(())
            })?,
        )?;
    }
    c.set("extensions", ext)?;

    // ---- ctx.cfproxy(全部需 cfproxy)----
    let cf = Object::new(ctx.clone())?;
    for m in [
        "listServers", "getStatus", "openPanel", "speedTest", "disable",
        "setSchedule", "restore", "teardown",
    ] {
        cf.set(m, host_fn(ctx, state, Some("cfproxy"), "cfproxy", m)?)?;
    }
    c.set("cfproxy", cf)?;

    // ---- ctx.sleep(无需权限,封顶 10s)----
    c.set(
        "sleep",
        Function::new(ctx.clone(), Async(move |ms: Coerced<f64>| async move {
            let clamped = ms.0.clamp(0.0, 10_000.0) as u64;
            tokio::time::sleep(Duration::from_millis(clamped)).await;
            JsOut(Ok(Json::Null))
        }))?,
    )?;

    // ---- ctx.plugin / 生命周期 ----
    c.set("plugin", json_to_js(ctx, meta)?)?;
    c.set("onEnable", lifecycle_fn(ctx, state, "onEnable")?)?;
    c.set("onDisable", lifecycle_fn(ctx, state, "onDisable")?)?;

    ctx.globals().set("ctx", c)?;
    Ok(())
}
