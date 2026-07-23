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

use super::contributions::{Contribution, ContributionKind};
use super::convert::{js_to_json, json_to_js};
use super::state::{CtxState, JsOut, JsonVal, PersistentFn};

/// `ctx.errors.unsupported()` 抛出的异常文案前缀。数据源桥按这个前缀把 JS 异常
/// 还原成 `SourceError::unsupported()`(「该源不支持搜索」→ UI 退回本地过滤),
/// 而不是当成一次真失败弹红字。
pub const UNSUPPORTED_MARKER: &str = "__LP_UNSUPPORTED__";

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

/// 给报错用的人话类型名。
fn type_name_of(v: &Json) -> &'static str {
    match v {
        Json::Null => "null",
        Json::Bool(_) => "布尔值",
        Json::Number(_) => "数字",
        Json::String(_) => "字符串",
        Json::Array(_) => "数组",
        Json::Object(_) => "对象",
    }
}

/// 抽出描述对象里的函数存进 handler 表、原位换成 `{__handler__:id}`,然后注册成贡献点。
/// 返回 `(贡献id, 是否新增)`。`ctx.extensions.register` 和 `ctx.sources.register` 共用。
fn register_contribution<'js>(
    ctx: &Ctx<'js>,
    st: &Arc<CtxState>,
    kind: ContributionKind,
    descriptor: Value<'js>,
) -> rquickjs::Result<(String, bool)> {
    let mut newh: Vec<(String, PersistentFn)> = Vec::new();
    let data = js_to_json(&descriptor, &mut |func| {
        let id = st.next_handler_id();
        newh.push((id.clone(), Persistent::save(ctx, func)));
        id
    });
    /* ★ 描述必须是**对象**,而且必须有 id。
       挡的是这一类真实错误:`ctx.extensions.register('panels', 'stats', {…})`
       —— 多写了一个参数(它的签名是 (kind, 描述),而隔壁 ctx.sources.register 是
       (源id, 描述),两个形状不一样,写混很自然)。descriptor 收到的是字符串
       'stats',老代码照单全收:data 存成一个裸字符串、id 编一个 `ext_7`,
       注册**成功**返回。表现是插件已启用、面板出现在 slot 列表里、
       render 调用却永远返回 null —— 一路无声。
       现在当场抛,把三十分钟的排查变成一行报错。 */
    if !data.is_object() {
        return Err(throw(
            ctx,
            format!(
                "{}.register 的描述必须是一个对象;收到的是 {} —— \
                 参数写多了?ctx.extensions.register(类型, 描述) / ctx.sources.register(源id, 描述)",
                kind.id(),
                type_name_of(&data)
            ),
        ));
    }
    {
        let mut h = st.handlers.lock().unwrap();
        for (id, p) in newh {
            h.insert(id, p);
        }
    }
    let Some(cid) = data.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()) else {
        return Err(throw(
            ctx,
            format!("{}.register 的描述必须带一个非空的 id 字段", kind.id()),
        ));
    };
    let registered = st.registry.register(Contribution {
        plugin_id: st.plugin_id.clone(),
        kind,
        id: cid.clone(),
        data,
        from_manifest: false,
    });
    st.host.extensions_changed();
    Ok((cid, registered))
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
    // `render` 是 v2 新增的声明式 UI 入口:插件交一棵 JSON 描述树,宿主用自己的
    // React 组件渲染(桌面/手机/TV 各一套,TV 的遥控器焦点因此白拿)。
    // 其余几个是它的糖 —— showForm/showList 本质就是预置形状的 render。
    let ui = Object::new(ctx.clone())?;
    for m in [
        "render",
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
    // v2 删除 getCredentials:宿主不再持久化明文密码。插件要账密请自己弹表单
    // 存进自己的 storage(每插件隔离)。见 permission::REMOVED。
    emby.set("apiRequest", host_fn(ctx, state, Some("emby.api"), "emby", "apiRequest")?)?;
    c.set("emby", emby)?;

    // ---- ctx.extensions:动态贡献 panels / actions / sandboxViews ----
    // 权限**按贡献点类型各自校验**(见 ContributionKind::required_permission),
    // 不是一个笼统的 "extensions" 通行证 —— 否则拿到 extensions 就能顺手注册
    // 数据源和沙箱视图,而用户在授权弹窗里只看到「扩展界面」。
    let ext = Object::new(ctx.clone())?;
    {
        let st = state.clone();
        ext.set(
            "register",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, kind_str: String, descriptor: Value<'js>| -> rquickjs::Result<Value<'js>> {
                let kind = ContributionKind::from_id(&kind_str)
                    .ok_or_else(|| throw(&ctx, format!("未知贡献点类型: {kind_str}")))?;
                // 只查 kind 自己要的那一条 —— 和 manifest 静态校验**同一把尺子**。
                // 多查一条 "extensions" 会让「manifest 过了、运行时被拒」成为可能。
                st.require(kind.required_permission()).map_err(|e| throw(&ctx, e))?;
                let (id, registered) = register_contribution(&ctx, &st, kind, descriptor)?;
                json_to_js(&ctx, &json!({ "id": id, "registered": registered }))
            })?,
        )?;
    }
    {
        let st = state.clone();
        ext.set(
            "unregister",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, kind_str: String, id: String| -> rquickjs::Result<()> {
                st.require("extensions").map_err(|e| throw(&ctx, e))?;
                let kind = ContributionKind::from_id(&kind_str)
                    .ok_or_else(|| throw(&ctx, format!("未知贡献点类型: {kind_str}")))?;
                st.registry.unregister(&st.plugin_id, kind, &id);
                st.host.extensions_changed();
                Ok(())
            })?,
        )?;
    }
    c.set("extensions", ext)?;

    // ---- ctx.sources:插件即数据源 ----
    // 三个函数就是一个完整数据源。宿主把它接进 MediaSourceBackend,于是浏览页 /
    // 搜索 / 播放 / 外挂字幕 / 多清晰度 / 跨服聚合全部白拿 —— 零新页面零新命令。
    //
    //   ctx.sources.register("mysrc", { listDir, search, resolvePlay })
    let sources = Object::new(ctx.clone())?;
    {
        let st = state.clone();
        sources.set(
            "register",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, src_id: String, handlers: Value<'js>| -> rquickjs::Result<Value<'js>> {
                st.require("sources").map_err(|e| throw(&ctx, e))?;
                if src_id.trim().is_empty() {
                    return Err(throw(&ctx, "数据源 id 不能为空".to_string()));
                }
                // 把 id 拍进描述对象,后面统一走 register_contribution 取 id。
                let obj = handlers
                    .as_object()
                    .ok_or_else(|| throw(&ctx, "第二个参数必须是含 listDir/search/resolvePlay 的对象".to_string()))?
                    .clone();
                obj.set("id", src_id.clone())?;
                let (id, registered) = register_contribution(
                    &ctx,
                    &st,
                    ContributionKind::DataSources,
                    obj.into_value(),
                )?;
                st.host.sources_changed(&st.plugin_id);
                json_to_js(&ctx, &json!({ "id": id, "registered": registered }))
            })?,
        )?;
    }
    {
        let st = state.clone();
        sources.set(
            "unregister",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, src_id: String| -> rquickjs::Result<()> {
                st.require("sources").map_err(|e| throw(&ctx, e))?;
                st.registry
                    .unregister(&st.plugin_id, ContributionKind::DataSources, &src_id);
                st.host.sources_changed(&st.plugin_id);
                st.host.extensions_changed();
                Ok(())
            })?,
        )?;
    }
    c.set("sources", sources)?;

    // ---- ctx.util:纯函数小工具,无需权限 ----
    // isVideoName 直接复用宿主那份扩展名表 —— 插件各自维护一份必然漂移,
    // 而漂移的后果是「某种格式在内置源能播、在插件源里根本不显示」。
    let util = Object::new(ctx.clone())?;
    util.set(
        "isVideoName",
        Function::new(ctx.clone(), |name: Coerced<String>| -> rquickjs::Result<bool> {
            Ok(crate::source::is_video_file_name(&name.0))
        })?,
    )?;
    c.set("util", util)?;

    // ---- ctx.errors:让插件表达「不支持」而不是「失败」 ----
    let errors = Object::new(ctx.clone())?;
    errors.set(
        "unsupported",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, msg: Rest<Coerced<String>>| -> rquickjs::Result<Value<'js>> {
            let extra = msg.0.first().map(|m| m.0.as_str()).unwrap_or("");
            Err(throw(&ctx, format!("{UNSUPPORTED_MARKER}{extra}")))
        })?,
    )?;
    c.set("errors", errors)?;

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
