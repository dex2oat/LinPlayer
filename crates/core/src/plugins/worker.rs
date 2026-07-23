//! 插件执行线程:QuickJS runtime 单线程,所有引擎钉在这条专用线程上,永不跨线程。
//! manager 只持一个 Send 的命令通道句柄;每条命令带 oneshot 回执。
//!
//! 单线程多引擎、命令用 spawn_local 并发:等用户填表/网络的 await 期不阻塞别的插件。
//! ponytail: 纯 JS 死循环会占住本线程直到 30s 看门狗中断(此间其他插件卡顿)。要更强隔离
//!           就每插件一条线程——但那 16 线程 ×tokio 更重,当前用共享线程 + 看门狗兜底。

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use serde_json::Value as Json;
use tokio::sync::{mpsc, oneshot};

use super::engine::PluginEngine;
use super::contributions::ContributionRegistry;
use super::host::PluginHost;
use super::manifest::PluginManifest;
use super::permission::GrantedPermissions;
use super::state::SourceHostGrant;
use super::storage::PluginStorage;

pub struct StartReq {
    pub manifest: PluginManifest,
    pub main_js: String,
    pub granted: GrantedPermissions,
    pub storage: Arc<PluginStorage>,
    pub host: Arc<dyn PluginHost>,
    pub registry: Arc<ContributionRegistry>,
    /// `$sourceServer` 展开表。manager 持同一个 Arc,配置源时直接写,无需重启引擎。
    pub source_hosts: Arc<Mutex<Vec<SourceHostGrant>>>,
}

enum Cmd {
    Start(StartReq, oneshot::Sender<Result<(), String>>),
    Lifecycle(String, String, oneshot::Sender<Result<(), String>>),
    CallDynamic(String, String, Json, oneshot::Sender<Result<Json, String>>),
    CallNamed(String, String, Json, oneshot::Sender<Result<Json, String>>),
    FireEvent(String, Json),
    Dispose(String, oneshot::Sender<()>),
}

#[derive(Clone)]
pub struct PluginWorker {
    tx: mpsc::UnboundedSender<Cmd>,
}

impl PluginWorker {
    pub fn spawn() -> Self {
        let (tx, rx) = mpsc::unbounded_channel::<Cmd>();
        std::thread::Builder::new()
            .name("plugin-worker".into())
            .spawn(move || run(rx))
            .expect("spawn plugin-worker 线程失败");
        PluginWorker { tx }
    }

    async fn ask<T>(&self, make: impl FnOnce(oneshot::Sender<T>) -> Cmd) -> Result<T, String> {
        let (rtx, rrx) = oneshot::channel();
        self.tx.send(make(rtx)).map_err(|_| "插件线程已停止".to_string())?;
        rrx.await.map_err(|_| "插件线程未回复".to_string())
    }

    pub async fn start(&self, req: StartReq) -> Result<(), String> {
        self.ask(|r| Cmd::Start(req, r)).await?
    }

    pub async fn run_lifecycle(&self, plugin_id: &str, name: &str) -> Result<(), String> {
        self.ask(|r| Cmd::Lifecycle(plugin_id.into(), name.into(), r)).await?
    }

    pub async fn call_dynamic(&self, plugin_id: &str, handler_id: &str, args: Json) -> Result<Json, String> {
        self.ask(|r| Cmd::CallDynamic(plugin_id.into(), handler_id.into(), args, r)).await?
    }

    pub async fn call_named(&self, plugin_id: &str, fn_name: &str, args: Json) -> Result<Json, String> {
        self.ask(|r| Cmd::CallNamed(plugin_id.into(), fn_name.into(), args, r)).await?
    }

    pub fn fire_event(&self, event: &str, data: Json) {
        let _ = self.tx.send(Cmd::FireEvent(event.into(), data));
    }

    pub async fn dispose(&self, plugin_id: &str) {
        let _ = self.ask(|r| Cmd::Dispose(plugin_id.into(), r)).await;
    }
}

fn run(mut rx: mpsc::UnboundedReceiver<Cmd>) {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("建插件线程 tokio runtime 失败");
    let local = tokio::task::LocalSet::new();
    local.block_on(&rt, async move {
        let engines: Rc<RefCell<HashMap<String, Rc<PluginEngine>>>> =
            Rc::new(RefCell::new(HashMap::new()));

        while let Some(cmd) = rx.recv().await {
            match cmd {
                Cmd::Start(req, reply) => {
                    let id = req.manifest.id.clone();
                    let r = PluginEngine::start(
                        &req.manifest,
                        &req.main_js,
                        req.granted,
                        req.storage,
                        req.host,
                        req.registry,
                        req.source_hosts,
                    )
                    .await;
                    let out = match r {
                        Ok(engine) => {
                            engines.borrow_mut().insert(id, Rc::new(engine));
                            Ok(())
                        }
                        Err(e) => Err(e),
                    };
                    let _ = reply.send(out);
                }
                Cmd::Lifecycle(id, name, reply) => {
                    let eng = engines.borrow().get(&id).cloned();
                    match eng {
                        Some(e) => {
                            tokio::task::spawn_local(async move {
                                let _ = reply.send(e.run_lifecycle(&name).await);
                            });
                        }
                        None => {
                            let _ = reply.send(Ok(()));
                        }
                    }
                }
                Cmd::CallDynamic(id, handler, args, reply) => {
                    let eng = engines.borrow().get(&id).cloned();
                    match eng {
                        Some(e) => {
                            tokio::task::spawn_local(async move {
                                let _ = reply.send(e.call_handler(&handler, args).await);
                            });
                        }
                        None => {
                            let _ = reply.send(Ok(Json::Null));
                        }
                    }
                }
                Cmd::CallNamed(id, fname, args, reply) => {
                    let eng = engines.borrow().get(&id).cloned();
                    match eng {
                        Some(e) => {
                            tokio::task::spawn_local(async move {
                                let _ = reply.send(e.call_named(&fname, args).await);
                            });
                        }
                        None => {
                            let _ = reply.send(Ok(Json::Null));
                        }
                    }
                }
                Cmd::FireEvent(event, data) => {
                    let all: Vec<Rc<PluginEngine>> =
                        engines.borrow().values().cloned().collect();
                    tokio::task::spawn_local(async move {
                        for e in all {
                            e.fire_event(&event, data.clone()).await;
                        }
                    });
                }
                Cmd::Dispose(id, reply) => {
                    let removed = engines.borrow_mut().remove(&id);
                    // 若还有在途调用持有 Rc,try_unwrap 会失败;直接 drop 也安全(Drop 会清 Persistent)。
                    drop(removed);
                    let _ = reply.send(());
                }
            }
        }
    });
}
