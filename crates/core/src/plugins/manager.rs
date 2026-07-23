//! 插件管理器(Send+Sync,进 Tauri AppState):扫描/安装/启用/禁用/卸载/触发扩展/派发事件。
//! 引擎执行全部委托给 worker 线程;本层只管元数据、启用态持久化、扩展注册表编排。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value as Json};

use super::assets;
use super::contributions::{handler_ref, Contribution, ContributionKind, ContributionRegistry, HandlerRef};
use super::host::PluginHost;
use super::installer;
use super::manifest::PluginManifest;
use super::permission::GrantedPermissions;
use super::state::SourceHostGrant;
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
    /// 开发模式:直接挂本地目录,不复制文件,改完存盘即重载。
    dev: bool,
    /// 入口文件 mtime,开发模式热重载靠它判变化。
    entry_mtime: Option<u128>,
}

/// 入口文件的修改时间(毫秒)。取不到就 None —— 取不到时一律不判「变了」,
/// 免得每轮都无脑重载。
fn mtime_of(path: &std::path::Path) -> Option<u128> {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_millis())
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
    registry: Arc<ContributionRegistry>,
    host: Arc<dyn PluginHost>,
    worker: PluginWorker,
    state: Mutex<State>,
    /// 每插件一份的 `$sourceServer` 展开表。**引擎持同一个 Arc**,所以用户新配一个源
    /// 之后不必重启插件引擎,写这里就立刻生效。
    source_grants: Mutex<HashMap<String, Arc<Mutex<Vec<SourceHostGrant>>>>>,
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
            registry: Arc::new(ContributionRegistry::new()),
            host,
            worker: PluginWorker::spawn(),
            state: Mutex::new(State { records: HashMap::new(), enabled, approved }),
            source_grants: Mutex::new(HashMap::new()),
        })
    }

    pub fn registry(&self) -> Arc<ContributionRegistry> {
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
                                dev: false,
                                entry_mtime: None,
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
                    "dev": r.dev,
                    "category": r.manifest.category,
                    "apiVersion": r.manifest.api_version,
                    "contributes": contributes_summary(&r.manifest),
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
                dev: false,
                entry_mtime: None,
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

        // 先注册 manifest 静态声明的贡献点(handler 为具名全局函数)。
        for decl in &manifest.contributions {
            let cid = decl
                .data
                .get("id")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("static_{}", decl.kind.id()));
            self.registry.register(Contribution {
                plugin_id: manifest.id.clone(),
                kind: decl.kind,
                id: cid,
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
                source_hosts: self.grants_slot(id),
            })
            .await;

        match start {
            Ok(()) => {
                /* ★ onEnable 抛出的错**必须留下来**。第一版是 `let _ = …`:
                   插件在 onEnable 里踩到权限拒绝/写错一行,注册到一半就中断,
                   而界面上它是「已启用、无错误」—— 面板永远空白、数据源少一半,
                   没有任何线索。现在照旧保持启用(已经注册上的那部分是能用的),
                   但把错误挂到记录上让用户看得见。 */
                match self.worker.run_lifecycle(id, "onEnable").await {
                    Ok(_) => self.set_status(id, PluginStatus::Enabled, None),
                    Err(e) => self.set_status(
                        id,
                        PluginStatus::Error,
                        Some(format!("插件初始化(onEnable)出错,功能可能不完整:{e}")),
                    ),
                }
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
        let kind = ContributionKind::from_id(type_id).ok_or_else(|| format!("未知贡献点类型: {type_id}"))?;
        let ext = self
            .registry
            .find(plugin_id, kind, ext_id)
            .ok_or_else(|| format!("贡献点不存在: {plugin_id}/{type_id}/{ext_id}"))?;
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
        let kind = ContributionKind::from_id(type_id).ok_or_else(|| format!("未知贡献点类型: {type_id}"))?;
        let ext = self
            .registry
            .find(plugin_id, kind, ext_id)
            .ok_or_else(|| format!("贡献点不存在: {plugin_id}/{type_id}/{ext_id}"))?;
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

    /// 取某类贡献的前端渲染 JSON。
    pub fn extensions_by_type(&self, type_id: &str) -> Vec<Json> {
        match ContributionKind::from_id(type_id) {
            Some(k) => self.registry.by_kind(k).iter().map(|e| e.to_json()).collect(),
            None => vec![],
        }
    }

    /// 取挂在某个 slot 的全部 panels(首页/侧栏/播放器叠加层各自只关心自己那一撮)。
    pub fn panels_in_slot(&self, slot: &str) -> Vec<Json> {
        self.registry.panels_in_slot(slot).iter().map(|e| e.to_json()).collect()
    }

    // ---- lpplugin:// 静态资源 ----

    /// 解析 `lpplugin://<插件id>/<rel>` 到磁盘文件。
    ///
    /// **只有已启用的插件可读** —— 装了没启用的插件不该能被一个 iframe 拉起来,
    /// 否则「禁用」这个动作就没有实际约束力。
    pub fn asset_path(&self, plugin_id: &str, rel: &str) -> Result<PathBuf, assets::AssetError> {
        let dir = {
            let st = self.state.lock().unwrap();
            if !st.enabled.contains(plugin_id) {
                return Err(assets::AssetError::NotEnabled);
            }
            st.records
                .get(plugin_id)
                .map(|r| r.dir.clone())
                .ok_or(assets::AssetError::NotEnabled)?
        };
        assets::resolve_asset(&dir, rel)
    }

    // ---- 开发模式 ----

    /// 把一个**本地目录**直接当插件装上(不复制文件)。改完源码存盘即可重载。
    ///
    /// 跟 `install_ipk` 的区别就是不搬文件 —— 这样「自己写插件自己用」的循环
    /// 从「改代码→打包→安装→启用」缩成「改代码→存盘」。
    pub fn install_dev_dir(&self, dir: &str) -> Result<Json, String> {
        let path = std::path::Path::new(dir);
        let p = installer::load_from_dir(path)?;
        let id = p.manifest.id.clone();
        let entry_mtime_src = p.entry_path.clone();
        let summary = json!({
            "id": id, "name": p.manifest.name, "version": p.manifest.version, "dev": true
        });
        {
            let mut st = self.state.lock().unwrap();
            // 同 install_ipk:换了源就强制重新授权,防新清单悄悄提权。
            st.enabled.remove(&id);
            st.approved.remove(&id);
            st.records.insert(
                id.clone(),
                Record {
                    manifest: p.manifest,
                    dir: p.dir,
                    entry_path: p.entry_path,
                    status: PluginStatus::Disabled,
                    error: None,
                    dev: true,
                    entry_mtime: mtime_of(&entry_mtime_src),
                },
            );
        }
        self.persist();
        Ok(summary)
    }

    /// 开发模式插件的入口文件是否变了(mtime)。变了就该重载。
    ///
    /// `ponytail:` 轮询 mtime 而不是上 `notify` crate —— 零新依赖,
    /// 而开发模式插件通常就一两个。真嫌慢再换 notify。
    pub fn dev_plugins_changed(&self) -> Vec<String> {
        let snapshot: Vec<(String, PathBuf, Option<u128>)> = {
            let st = self.state.lock().unwrap();
            st.records
                .values()
                .filter(|r| r.dev)
                .map(|r| (r.manifest.id.clone(), r.entry_path.clone(), r.entry_mtime))
                .collect()
        };
        let mut changed = Vec::new();
        for (id, path, known) in snapshot {
            let now = mtime_of(&path);
            if now.is_some() && now != known {
                let mut st = self.state.lock().unwrap();
                if let Some(r) = st.records.get_mut(&id) {
                    r.entry_mtime = now;
                }
                changed.push(id);
            }
        }
        changed
    }

    /// 重载一个插件(禁用 -> 重扫 manifest -> 重新启用)。开发模式热重载走这里。
    pub async fn reload(self: &Arc<Self>, id: &str) -> Result<(), String> {
        let was_enabled = self.state.lock().unwrap().enabled.contains(id);
        if was_enabled {
            self.disable(id).await;
        }
        // manifest 可能也改了,重新读一遍。
        let dir = self
            .state
            .lock()
            .unwrap()
            .records
            .get(id)
            .map(|r| r.dir.clone())
            .ok_or_else(|| format!("插件不存在: {id}"))?;
        let p = installer::load_from_dir(&dir)?;
        {
            let mut st = self.state.lock().unwrap();
            if let Some(r) = st.records.get_mut(id) {
                r.manifest = p.manifest;
                r.entry_path = p.entry_path;
                r.entry_mtime = mtime_of(&r.entry_path);
                r.error = None;
            }
        }
        if was_enabled {
            self.enable(id).await
        } else {
            Ok(())
        }
    }

    // ---- 数据源桥 ----

    /// 取(或建)某插件的 `$sourceServer` 展开槽。引擎和 manager 共用同一个 Arc。
    fn grants_slot(&self, plugin_id: &str) -> Arc<Mutex<Vec<SourceHostGrant>>> {
        self.source_grants
            .lock()
            .unwrap()
            .entry(plugin_id.to_string())
            .or_default()
            .clone()
    }

    /// 用「用户已为该插件配置的全部源地址」整体替换它的 `$sourceServer` 展开表。
    ///
    /// **整体替换而不是追加** —— 用户删掉一个源之后,那台机器必须立刻不再可达;
    /// 追加语义会让已删除的地址一直留着,是个只增不减的越权口子。
    pub fn set_source_grants(&self, plugin_id: &str, base_urls: &[String]) {
        let grants: Vec<SourceHostGrant> = base_urls
            .iter()
            .filter_map(|u| SourceHostGrant::from_base_url(u))
            .collect();
        *self.grants_slot(plugin_id).lock().unwrap() = grants;
    }

    /// 当前所有已启用插件贡献的数据源:`(插件id, 源id, 展示名)`。
    pub fn data_sources(&self) -> Vec<(String, String, String)> {
        self.registry
            .by_kind(ContributionKind::DataSources)
            .into_iter()
            .map(|c| {
                let name = c
                    .data
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&c.id)
                    .to_string();
                (c.plugin_id, c.id, name)
            })
            .collect()
    }

    /// 调某数据源的一个方法(listDir / search / resolvePlay)。
    ///
    /// 走 `invoke_extension_field`:三个方法就是 dataSources 贡献描述里的三个字段,
    /// 复用既有的 handler 派发,不新开一条通路。
    pub async fn call_source(
        &self,
        plugin_id: &str,
        src_id: &str,
        method: &str,
        args: Json,
    ) -> Result<Json, String> {
        self.invoke_extension_field(
            plugin_id,
            ContributionKind::DataSources.id(),
            src_id,
            method,
            args,
        )
        .await
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

/// 卡片上的能力徽章:「提供 1 个数据源、2 个面板」。市场不下载包就能展示。
fn contributes_summary(m: &PluginManifest) -> Json {
    let count = |k: ContributionKind| m.contributions.iter().filter(|c| c.kind == k).count();
    json!({
        "dataSources": count(ContributionKind::DataSources),
        "panels": count(ContributionKind::Panels),
        "actions": count(ContributionKind::Actions),
        "sandboxViews": count(ContributionKind::SandboxViews),
    })
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
