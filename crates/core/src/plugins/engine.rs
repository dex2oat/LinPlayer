//! 每插件一个 QuickJS 引擎(AsyncRuntime + AsyncContext)。
//!
//! - 内存上限 64MB;崩溃/栈溢出只毁自己。
//! - 空转看门狗:interrupt handler 只在 JS 真跑字节码时触发,等宿主 UI/网络的 await 期不触发,
//!   所以交互式流程(等用户填表)不会误杀,纯 JS 死循环 30s 无宿主交互被中断。
//! - 插件回调用 `Persistent<Function>` 存,日后经 `__lp_call` 统一包成 Promise 再 await。

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rquickjs::{async_with, AsyncContext, AsyncRuntime, Ctx, Function, Promise, Value};
use serde_json::{json, Value as Json};

use super::convert::{js_value_to_json, json_to_js};
use super::ctx::install;
use super::contributions::ContributionRegistry;
use super::host::PluginHost;
use super::manifest::PluginManifest;
use super::permission::GrantedPermissions;
use super::state::{CtxState, SourceHostGrant};
use super::storage::PluginStorage;

const MEMORY_LIMIT: usize = 64 * 1024 * 1024;

/// 统一把插件回调包成 Promise(无论 handler 是同步还是 async)。唯一残留的 JS 胶水,1 行。
const PRELUDE: &str = "globalThis.__lp_call=function(f,a){return Promise.resolve(f.apply(null,a||[]))};";

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 从 rquickjs 错误里尽量取出人类可读的 JS 异常文案。
fn js_err(ctx: &Ctx, e: rquickjs::Error) -> String {
    if e.is_exception() {
        let v = ctx.catch();
        if let Some(ex) = v.as_exception() {
            if let Some(msg) = ex.message() {
                return msg;
            }
        }
        if let Some(s) = v.as_string() {
            if let Ok(s) = s.to_string() {
                return s;
            }
        }
    }
    format!("{e}")
}

pub struct PluginEngine {
    ctx: AsyncContext,
    rt: AsyncRuntime,
    state: Arc<CtxState>,
}

impl PluginEngine {
    pub async fn start(
        manifest: &PluginManifest,
        main_js: &str,
        granted: GrantedPermissions,
        storage: Arc<PluginStorage>,
        host: Arc<dyn PluginHost>,
        registry: Arc<ContributionRegistry>,
        source_hosts: Arc<Mutex<Vec<SourceHostGrant>>>,
    ) -> Result<Self, String> {
        let rt = AsyncRuntime::new().map_err(|e| format!("建 QuickJS 运行时失败: {e}"))?;
        rt.set_memory_limit(MEMORY_LIMIT).await;

        let deadline = Arc::new(AtomicI64::new(0));
        {
            let d = deadline.clone();
            rt.set_interrupt_handler(Some(Box::new(move || {
                let dl = d.load(Ordering::Relaxed);
                dl != 0 && now_ms() > dl
            })))
            .await;
        }

        let ctx = AsyncContext::full(&rt)
            .await
            .map_err(|e| format!("建 QuickJS 上下文失败: {e}"))?;

        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| format!("建 http 客户端失败: {e}"))?;

        let state = Arc::new(CtxState {
            plugin_id: manifest.id.clone(),
            permissions: granted,
            allowed_hosts: manifest.http_allowed_hosts.clone(),
            source_hosts,
            http,
            storage,
            host,
            registry,
            handlers: Mutex::new(std::collections::HashMap::new()),
            events: Mutex::new(std::collections::HashMap::new()),
            lifecycle: Mutex::new(std::collections::HashMap::new()),
            handler_seq: AtomicU64::new(0),
            deadline: deadline.clone(),
        });

        let meta = json!({
            "id": manifest.id, "name": manifest.name, "version": manifest.version,
        });
        state.bump_deadline();

        let st = state.clone();
        let main = main_js.to_string();
        let res: Result<(), String> = async_with!(ctx => |ctx| {
            install(&ctx, &st, &meta).map_err(|e| format!("装配 ctx 失败: {e}"))?;
            ctx.eval::<(), _>(PRELUDE).map_err(|e| js_err(&ctx, e))?;
            ctx.eval::<(), _>(main.into_bytes()).map_err(|e| js_err(&ctx, e))?;
            Ok(())
        })
        .await;
        rt.idle().await;
        res?;

        Ok(Self { ctx, rt, state })
    }

    /// 调一个 JS 函数(经 __lp_call 包成 Promise),args 为参数 JSON 数组。
    async fn apply<'js>(ctx: &Ctx<'js>, f: Function<'js>, args: &Json) -> Result<Json, String> {
        let call: Function = ctx
            .globals()
            .get("__lp_call")
            .map_err(|e| format!("取 __lp_call 失败: {e}"))?;
        let args_js = json_to_js(ctx, args).map_err(|e| format!("参数转换失败: {e}"))?;
        let promise: Promise = call.call((f, args_js)).map_err(|e| js_err(ctx, e))?;
        match promise.into_future::<Value>().await {
            Ok(v) => Ok(js_value_to_json(&v)),
            Err(e) => Err(js_err(ctx, e)),
        }
    }

    /// 触发动态注册的 handler(按 id)。
    pub async fn call_handler(&self, handler_id: &str, args: Json) -> Result<Json, String> {
        let p = self.state.handlers.lock().unwrap().get(handler_id).cloned();
        let Some(p) = p else { return Ok(Json::Null) };
        self.state.bump_deadline();
        let out = async_with!(self.ctx => |ctx| {
            let f = match p.restore(&ctx) {
                Ok(f) => f,
                Err(e) => return Err(format!("恢复 handler 失败: {e}")),
            };
            Self::apply(&ctx, f, &args).await
        })
        .await;
        self.rt.idle().await;
        out
    }

    /// 触发 manifest 声明的具名全局函数 handler。
    pub async fn call_named(&self, fn_name: &str, args: Json) -> Result<Json, String> {
        self.state.bump_deadline();
        let name = fn_name.to_string();
        let out = async_with!(self.ctx => |ctx| {
            let f: Function = match ctx.globals().get(name.as_str()) {
                Ok(f) => f,
                Err(_) => return Ok(Json::Null),
            };
            Self::apply(&ctx, f, &args).await
        })
        .await;
        self.rt.idle().await;
        out
    }

    /// 派发播放事件给所有监听者。
    pub async fn fire_event(&self, event: &str, data: Json) {
        let listeners = {
            let map = self.state.events.lock().unwrap();
            map.get(event).cloned().unwrap_or_default()
        };
        if listeners.is_empty() {
            return;
        }
        self.state.bump_deadline();
        let args = json!([data]);
        let _ = async_with!(self.ctx => |ctx| {
            for p in listeners {
                if let Ok(f) = p.restore(&ctx) {
                    let _ = Self::apply(&ctx, f, &args).await;
                }
            }
        })
        .await;
        self.rt.idle().await;
    }

    /// 跑生命周期回调 onEnable / onDisable(若插件注册了)。
    pub async fn run_lifecycle(&self, name: &str) -> Result<(), String> {
        let p = self.state.lifecycle.lock().unwrap().get(name).cloned();
        let Some(p) = p else { return Ok(()) };
        self.state.bump_deadline();
        let out = async_with!(self.ctx => |ctx| {
            let f = match p.restore(&ctx) {
                Ok(f) => f,
                Err(e) => return Err(format!("恢复 {name} 失败: {e}")),
            };
            Self::apply(&ctx, f, &json!([])).await.map(|_| ())
        })
        .await;
        self.rt.idle().await;
        out
    }

}

impl Drop for PluginEngine {
    /// 关键:rquickjs 若检测到 Persistent 活过 runtime 会直接 abort 进程。所以 drop 时先清空三张
    /// Persistent 表(此刻 rt 字段尚在,可正常反注册),之后 ctx/rt 字段才依序释放。这样即便引擎被
    /// 直接 drop(未显式 dispose)也安全。
    fn drop(&mut self) {
        self.state.handlers.lock().unwrap().clear();
        self.state.events.lock().unwrap().clear();
        self.state.lifecycle.lock().unwrap().clear();
    }
}
