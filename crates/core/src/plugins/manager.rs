//! 插件管理器(Send+Sync,进 Tauri AppState):扫描/安装/启用/禁用/卸载/触发扩展/派发事件。
//! 引擎执行全部委托给 worker 线程;本层只管元数据、启用态持久化、扩展注册表编排。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value as Json};

use super::extensions::{handler_ref, ExtensionRegistry, ExtensionType, HandlerRef, RegisteredExtension};
use super::host::PluginHost;
use super::installer;
use super::manifest::PluginManifest;
use super::permission::GrantedPermissions;
use super::storage::PluginStorage;
use super::worker::{PluginWorker, StartReq};

/// 同时启用插件数上限(每引擎 ~64MB,限数即限内存)。
pub const MAX_ENABLED: usize = 16;

#[derive(Clone, Copy, PartialEq)]
pub enum PluginStatus {
    Disabled,
    Enabled,
    Error,
}

impl PluginStatus {
    fn as_str(&self) -> &'static str {
        match self {
            PluginStatus::Disabled => "disabled",
            PluginStatus::Enabled => "enabled",
            PluginStatus::Error => "error",
        }
    }
}

struct Record {
    manifest: PluginManifest,
    dir: PathBuf,
    entry_path: PathBuf,
    status: PluginStatus,
    error: Option<String>,
}

struct State {
    records: HashMap<String, Record>,
    enabled: HashSet<String>,
    approved: HashMap<String, HashSet<String>>,
}

pub struct PluginManager {
    plugins_root: PathBuf,
    data_root: PathBuf,
    state_file: PathBuf,
    registry: Arc<ExtensionRegistry>,
    host: Arc<dyn PluginHost>,
    worker: PluginWorker,
    state: Mutex<State>,
}

impl PluginManager {
    /// base_dir 下建 plugins/ 与 plugin_data/。host = 平台能力实现。
    pub fn new(base_dir: PathBuf, host: Arc<dyn PluginHost>) -> Arc<Self> {
        let plugins_root = base_dir.join("plugins");
        let data_root = base_dir.join("plugin_data");
        let _ = std::fs::create_dir_all(&plugins_root);
        let _ = std::fs::create_dir_all(&data_root);
        let (enabled, approved) = load_state(&base_dir.join("plugins_state.json"));
        Arc::new(Self {
            plugins_root,
            data_root,
            state_file: base_dir.join("plugins_state.json"),
            registry: Arc::new(ExtensionRegistry::new()),
            host,
            worker: PluginWorker::spawn(),
            state: Mutex::new(State { records: HashMap::new(), enabled, approved }),
        })
    }

    pub fn registry(&self) -> Arc<ExtensionRegistry> {
        self.registry.clone()
    }

    /// 扫描插件目录,并激活「已启用且权限未提权」的插件。
    pub async fn init(self: &Arc<Self>) {
        self.scan();
        let to_enable: Vec<String> = {
            let st = self.state.lock().unwrap();
            st.records
                .keys()
                .filter(|id| st.enabled.contains(*id) && perms_approved(&st, id))
                .cloned()
                .collect()
        };
        let mut activated = 0;
        for id in to_enable {
            if activated >= MAX_ENABLED {
                break;
            }
            if self.activate(&id).await.is_ok() {
                activated += 1;
            }
        }
    }

    fn scan(&self) {
        let mut records = HashMap::new();
        if let Ok(entries) = std::fs::read_dir(&self.plugins_root) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }
                match installer::load_from_dir(&path) {
                    Ok(p) => {
                        records.insert(
                            p.manifest.id.clone(),
                            Record {
                                manifest: p.manifest,
                                dir: p.dir,
                                entry_path: p.entry_path,
                                status: PluginStatus::Disabled,
                                error: None,
                            },
                        );
                    }
                    Err(e) => {
                        eprintln!("[plugins] 跳过无效目录 {}: {e}", path.display());
                    }
                }
            }
        }
        self.state.lock().unwrap().records = records;
    }

    pub fn list(&self) -> Vec<Json> {
        let st = self.state.lock().unwrap();
        st.records
            .values()
            .map(|r| {
                json!({
                    "id": r.manifest.id,
                    "name": r.manifest.name,
                    "version": r.manifest.version,
                    "author": r.manifest.author,
                    "description": r.manifest.description,
                    "permissions": r.manifest.permissions,
                    "httpAllowedHosts": r.manifest.http_allowed_hosts,
                    "icon": r.manifest.icon,
                    "homepage": r.manifest.homepage,
                    "status": r.status.as_str(),
                    "enabled": st.enabled.contains(&r.manifest.id),
                    "error": r.error,
                })
            })
            .collect()
    }

    /// 安装 .ipk(安装后默认禁用,待授权启用)。
    pub fn install_ipk(&self, ipk_path: &str) -> Result<Json, String> {
        let p = installer::install_ipk_file(std::path::Path::new(ipk_path), &self.plugins_root)?;
        let id = p.manifest.id.clone();
        let summary = json!({ "id": id, "name": p.manifest.name, "version": p.manifest.version });
        let mut st = self.state.lock().unwrap();
        // 重装:清旧启用态与已同意权限,强制重新授权(防新清单悄悄提权)。
        st.enabled.remove(&id);
        st.approved.remove(&id);
        st.records.insert(
            id,
            Record {
                manifest: p.manifest,
                dir: p.dir,
                entry_path: p.entry_path,
                status: PluginStatus::Disabled,
                error: None,
            },
        );
        drop(st);
        self.persist();
        Ok(summary)
    }

    /// 启用(调用方须已过授权弹窗)。记录用户同意的权限集,启动引擎并跑 onEnable。
    pub async fn enable(self: &Arc<Self>, id: &str) -> Result<(), String> {
        {
            let mut st = self.state.lock().unwrap();
            let rec = st.records.get(id).ok_or_else(|| format!("插件不存在: {id}"))?;
            let already = st.enabled.contains(id);
            if !already && st.enabled.len() >= MAX_ENABLED {
                return Err(format!("已达同时启用上限({MAX_ENABLED} 个),请先禁用其它插件"));
            }
            let perms: HashSet<String> = rec.manifest.permissions.iter().cloned().collect();
            st.enabled.insert(id.to_string());
            st.approved.insert(id.to_string(), perms);
        }
        self.persist();
        self.activate(id).await
    }

    async fn activate(self: &Arc<Self>, id: &str) -> Result<(), String> {
        let (manifest, entry_path) = {
            let st = self.state.lock().unwrap();
            let rec = st.records.get(id).ok_or_else(|| format!("插件不存在: {id}"))?;
            (rec.manifest.clone(), rec.entry_path.clone())
        };
        let main_js = std::fs::read_to_string(&entry_path)
            .map_err(|e| format!("读入口失败: {e}"))?;
        let granted = GrantedPermissions::new(manifest.permissions.clone());
        let storage = Arc::new(PluginStorage::new(
            manifest.id.clone(),
            self.data_root.join(&manifest.id),
        ));

        // 先注册 manifest 静态声明的扩展点(handler 为具名全局函数)。
        for decl in &manifest.extensions {
            let ext_id = decl
                .data
                .get("id")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("static_{}", decl.type_.id()));
            self.registry.register(RegisteredExtension {
                plugin_id: manifest.id.clone(),
                type_: decl.type_,
                id: ext_id,
                data: decl.data.clone(),
                from_manifest: true,
            });
        }

        let start = self
            .worker
            .start(StartReq {
                manifest: manifest.clone(),
                main_js,
                granted,
                storage,
                host: self.host.clone(),
                registry: self.registry.clone(),
            })
            .await;

        match start {
            Ok(()) => {
                let _ = self.worker.run_lifecycle(id, "onEnable").await;
                self.set_status(id, PluginStatus::Enabled, None);
                self.host.extensions_changed();
                Ok(())
            }
            Err(e) => {
                self.registry.remove_all_for_plugin(id);
                self.set_status(id, PluginStatus::Error, Some(e.clone()));
                Err(e)
            }
        }
    }

    pub async fn disable(&self, id: &str) {
        self.worker.run_lifecycle(id, "onDisable").await.ok();
        self.worker.dispose(id).await;
        self.registry.remove_all_for_plugin(id);
        {
            let mut st = self.state.lock().unwrap();
            st.enabled.remove(id);
            if let Some(r) = st.records.get_mut(id) {
                r.status = PluginStatus::Disabled;
                r.error = None;
            }
        }
        self.persist();
        self.host.extensions_changed();
    }

    pub async fn uninstall(&self, id: &str) {
        self.disable(id).await;
        let dir = {
            let mut st = self.state.lock().unwrap();
            st.approved.remove(id);
            st.records.remove(id).map(|r| r.dir)
        };
        if let Some(dir) = dir {
            let _ = installer::uninstall(&dir);
        }
        self.persist();
    }

    /// 触发某扩展的 handler(actions/settingsPages 等的入口按钮)。
    pub async fn trigger_extension(
        &self,
        plugin_id: &str,
        type_id: &str,
        ext_id: &str,
        args: Json,
    ) -> Result<Json, String> {
        let etype = ExtensionType::from_id(type_id).ok_or_else(|| format!("未知扩展点类型: {type_id}"))?;
        let ext = self
            .registry
            .find(plugin_id, etype, ext_id)
            .ok_or_else(|| format!("扩展不存在: {plugin_id}/{type_id}/{ext_id}"))?;
        self.invoke_handler_value(plugin_id, ext.data.get("handler"), args).await
    }

    /// 触发扩展 data 里某具名字段的 handler(如设置页的 load/submit)。
    pub async fn invoke_extension_field(
        &self,
        plugin_id: &str,
        type_id: &str,
        ext_id: &str,
        field: &str,
        args: Json,
    ) -> Result<Json, String> {
        let etype = ExtensionType::from_id(type_id).ok_or_else(|| format!("未知扩展点类型: {type_id}"))?;
        let ext = self
            .registry
            .find(plugin_id, etype, ext_id)
            .ok_or_else(|| format!("扩展不存在: {plugin_id}/{type_id}/{ext_id}"))?;
        self.invoke_handler_value(plugin_id, ext.data.get(field), args).await
    }

    async fn invoke_handler_value(
        &self,
        plugin_id: &str,
        handler: Option<&Json>,
        args: Json,
    ) -> Result<Json, String> {
        match handler_ref(handler) {
            HandlerRef::Dynamic(id) => self.worker.call_dynamic(plugin_id, &id, args).await,
            HandlerRef::Named(name) => self.worker.call_named(plugin_id, &name, args).await,
            HandlerRef::None => Ok(Json::Null),
        }
    }

    /// 派发播放事件给所有插件的监听者。
    pub fn fire_player_event(&self, event: &str, data: Json) {
        self.worker.fire_event(event, data);
    }

    /// 取某类型全部扩展的前端渲染 JSON。
    pub fn extensions_by_type(&self, type_id: &str) -> Vec<Json> {
        match ExtensionType::from_id(type_id) {
            Some(t) => self.registry.by_type(t).iter().map(|e| e.to_json()).collect(),
            None => vec![],
        }
    }

    // ---- 内部 ----

    fn set_status(&self, id: &str, status: PluginStatus, error: Option<String>) {
        let mut st = self.state.lock().unwrap();
        if let Some(r) = st.records.get_mut(id) {
            r.status = status;
            r.error = error;
        }
    }

    fn persist(&self) {
        let st = self.state.lock().unwrap();
        let approved: serde_json::Map<String, Json> = st
            .approved
            .iter()
            .map(|(k, v)| (k.clone(), json!(v.iter().collect::<Vec<_>>())))
            .collect();
        let payload = json!({
            "enabled": st.enabled.iter().collect::<Vec<_>>(),
            "approved": approved,
        });
        let _ = std::fs::write(&self.state_file, payload.to_string());
    }
}

fn perms_approved(st: &State, id: &str) -> bool {
    let Some(rec) = st.records.get(id) else { return false };
    let Some(approved) = st.approved.get(id) else { return false };
    rec.manifest.permissions.iter().all(|p| approved.contains(p))
}

fn load_state(file: &std::path::Path) -> (HashSet<String>, HashMap<String, HashSet<String>>) {
    let mut enabled = HashSet::new();
    let mut approved = HashMap::new();
    if let Ok(raw) = std::fs::read_to_string(file) {
        if let Ok(v) = serde_json::from_str::<Json>(&raw) {
            if let Some(arr) = v.get("enabled").and_then(|x| x.as_array()) {
                for e in arr {
                    if let Some(s) = e.as_str() {
                        enabled.insert(s.to_string());
                    }
                }
            }
            if let Some(obj) = v.get("approved").and_then(|x| x.as_object()) {
                for (k, val) in obj {
                    if let Some(arr) = val.as_array() {
                        approved.insert(
                            k.clone(),
                            arr.iter().filter_map(|e| e.as_str().map(|s| s.to_string())).collect(),
                        );
                    }
                }
            }
        }
    }
    (enabled, approved)
}
