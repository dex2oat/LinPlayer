//! 贡献点(contributions)—— 插件把能力「挂载」到宿主的预定义位置。
//!
//! v2 相对 v1 的收敛:v1 有 8 个平级扩展点(sidebarItems/homeStats/settingsPages/
//! playerOverlays/actions/contextMenus/mediaSources/eventListeners),**位置和类型混在一起**,
//! 每加一个新位置就要加一个新类型,还要在 Rust/manifest/前端三处同步。
//!
//! v2 收敛成 **4 类 × slot**(抄 VS Code contribution points):
//!   - `dataSources`  —— 贡献一个完整数据源(浏览/搜索/播放),接进 `MediaSourceBackend`
//!   - `panels`       —— 贡献一块 UI,挂在 `slot` 指定的位置
//!   - `actions`      —— 贡献一个操作项,出现在 `context` 指定的上下文
//!   - `sandboxViews` —— 贡献一个 iframe 逃生舱视图
//!
//! 以后加新位置只加 slot 常量,不加类型。`eventListeners` 被删除 —— 它本来就该是运行时的
//! `ctx.player.on()`,声明成扩展点是概念错位。

use std::sync::Mutex;

use serde_json::{json, Value};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ContributionKind {
    DataSources,
    Panels,
    Actions,
    SandboxViews,
}

impl ContributionKind {
    pub fn id(&self) -> &'static str {
        match self {
            ContributionKind::DataSources => "dataSources",
            ContributionKind::Panels => "panels",
            ContributionKind::Actions => "actions",
            ContributionKind::SandboxViews => "sandboxViews",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "dataSources" => ContributionKind::DataSources,
            "panels" => ContributionKind::Panels,
            "actions" => ContributionKind::Actions,
            "sandboxViews" => ContributionKind::SandboxViews,
            _ => return None,
        })
    }

    /// 贡献这一类需要的权限。**没有这个权限,连 manifest 里静态声明都不许**
    /// —— 否则用户在授权弹窗里看不到、却被悄悄挂上了东西。
    ///
    /// panels/actions 要的是 `extensions`(权限表原话:「向应用注册侧边栏入口、
    /// 操作按钮、设置页等界面模块」)而**不是** `ui`(那条管的是 `ctx.ui.*`,
    /// 弹提示/对话框)。第一版写成 `ui`,而 `ctx.extensions.register` 那边
    /// 同时要 `extensions` 和这里返回的权限 —— 两边规则对不上:
    /// 一个照 manifest 只声明了 `ui` 的插件能通过静态校验,却在运行时注册面板时被拒,
    /// 而拒的异常发生在 onEnable 里、当时被 `let _ =` 吞掉,表现为
    /// **插件显示已启用、面板却永远是空的**。
    pub fn required_permission(&self) -> &'static str {
        match self {
            ContributionKind::DataSources => "sources",
            ContributionKind::Panels | ContributionKind::Actions => "extensions",
            ContributionKind::SandboxViews => "sandbox",
        }
    }
}

/// `panels` 的挂载位置。加新位置只往这里加一条,不动类型系统。
pub const PANEL_SLOTS: &[&str] = &[
    "home.stats",     // 首页统计区
    "sidebar",        // 侧栏入口
    "settings",       // 插件自己的设置页
    "player.overlay", // 播放器叠加层
    "page",           // 独立整页
];

/// `actions` 的出现上下文。
pub const ACTION_CONTEXTS: &[&str] = &["global", "item", "player"];

/// 一条已注册贡献。`data` 里的 handler 已被引擎替换成 `{"__handler__": id}` 标记
/// (真正的 JS 函数在引擎的 handler 表里,以 Persistent 存)。
#[derive(Clone, Debug)]
pub struct Contribution {
    pub plugin_id: String,
    pub kind: ContributionKind,
    pub id: String,
    pub data: Value,
    pub from_manifest: bool,
}

impl Contribution {
    /// 供前端渲染的精简 JSON。
    pub fn to_json(&self) -> Value {
        json!({
            "pluginId": self.plugin_id,
            "kind": self.kind.id(),
            "id": self.id,
            "data": self.data,
            "fromManifest": self.from_manifest,
        })
    }

    /// panels 的挂载位置(非 panels 或未声明则为 None)。
    pub fn slot(&self) -> Option<&str> {
        self.data.get("slot").and_then(|v| v.as_str())
    }
}

/// 全局贡献点注册表(所有插件共享一份)。
#[derive(Default)]
pub struct ContributionRegistry {
    items: Mutex<Vec<Contribution>>,
}

impl ContributionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注册/覆盖(同 plugin+kind+id 视为同一条)。返回是否为新增。
    ///
    /// ★ **运行时注册撞上 manifest 静态声明时要合并,不能整条顶掉。**
    /// manifest 里写的是**描述性**字段(数据源的 name / auth 表单、面板的 title / slot),
    /// 运行时 `ctx.sources.register('demo', {…})` 交的是**行为**字段(三个回调),
    /// 两边天然只各写一半。第一版直接 `*slot = c`,于是插件一注册回调,
    /// manifest 里的 name 和 auth 就没了 ——
    /// 「添加服务器」页拿到一个**没有任何输入框**的插件源,名字还退化成源 id。
    /// 2026-07-23 真机端到端跑出来的,单测和编译都看不见。
    pub fn register(&self, c: Contribution) -> bool {
        let mut items = self.items.lock().unwrap();
        if let Some(slot) = items
            .iter_mut()
            .find(|e| e.plugin_id == c.plugin_id && e.kind == c.kind && e.id == c.id)
        {
            let mut merged = c;
            if slot.from_manifest && !merged.from_manifest {
                if let (Some(old), Some(new)) = (slot.data.as_object(), merged.data.as_object_mut())
                {
                    // 新的赢同名键,老的填空缺。
                    for (k, v) in old {
                        new.entry(k.clone()).or_insert_with(|| v.clone());
                    }
                }
            }
            *slot = merged;
            false
        } else {
            items.push(c);
            true
        }
    }

    pub fn unregister(&self, plugin_id: &str, kind: ContributionKind, id: &str) {
        let mut items = self.items.lock().unwrap();
        items.retain(|e| !(e.plugin_id == plugin_id && e.kind == kind && e.id == id));
    }

    pub fn remove_all_for_plugin(&self, plugin_id: &str) {
        let mut items = self.items.lock().unwrap();
        items.retain(|e| e.plugin_id != plugin_id);
    }

    pub fn by_kind(&self, kind: ContributionKind) -> Vec<Contribution> {
        self.items
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind == kind)
            .cloned()
            .collect()
    }

    /// 取挂在某个 slot 的全部 panels(首页/侧栏/播放器叠加层各自只关心自己那一撮)。
    pub fn panels_in_slot(&self, slot: &str) -> Vec<Contribution> {
        self.items
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind == ContributionKind::Panels && e.slot() == Some(slot))
            .cloned()
            .collect()
    }

    pub fn find(&self, plugin_id: &str, kind: ContributionKind, id: &str) -> Option<Contribution> {
        self.items
            .lock()
            .unwrap()
            .iter()
            .find(|e| e.plugin_id == plugin_id && e.kind == kind && e.id == id)
            .cloned()
    }

    pub fn all_json(&self) -> Vec<Value> {
        self.items.lock().unwrap().iter().map(|e| e.to_json()).collect()
    }
}

/// 从 handler 描述值里取出「怎么调这个 handler」:
///  - `{"__handler__": id}` -> 动态注册的函数,按 id 调引擎 handler 表;
///  - `"name"` 字符串 -> manifest 声明的全局具名函数。
pub enum HandlerRef {
    Dynamic(String),
    Named(String),
    None,
}

pub fn handler_ref(value: Option<&Value>) -> HandlerRef {
    match value {
        Some(Value::Object(m)) => match m.get("__handler__").and_then(|v| v.as_str()) {
            Some(id) => HandlerRef::Dynamic(id.to_string()),
            None => HandlerRef::None,
        },
        Some(Value::String(s)) if !s.is_empty() => HandlerRef::Named(s.clone()),
        _ => HandlerRef::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 贡献点 id 是**写在用户 manifest 里的字面量**,也是前端查询用的键。
    /// 改一个字母,所有已发布插件的那一类贡献静默消失(不报错,只是不出现)。
    #[test]
    fn kind_ids_are_stable_wire_strings() {
        for (k, id) in [
            (ContributionKind::DataSources, "dataSources"),
            (ContributionKind::Panels, "panels"),
            (ContributionKind::Actions, "actions"),
            (ContributionKind::SandboxViews, "sandboxViews"),
        ] {
            assert_eq!(k.id(), id);
            assert_eq!(ContributionKind::from_id(id), Some(k));
        }
        // v1 的 8 个老扩展点名一律不再认 —— 认了会让 v1 插件半死不活地跑起来
        for old in [
            "sidebarItems",
            "mediaSources",
            "eventListeners",
            "settingsPages",
            "homeStats",
            "playerOverlays",
            "contextMenus",
        ] {
            assert_eq!(ContributionKind::from_id(old), None, "v1 扩展点名 {old} 不该还被认");
        }
    }

    /// 每类贡献都必须绑一个权限。漏绑 = 用户在授权弹窗里看不见、却被挂上了东西。
    #[test]
    fn every_kind_requires_a_declared_permission() {
        for k in [
            ContributionKind::DataSources,
            ContributionKind::Panels,
            ContributionKind::Actions,
            ContributionKind::SandboxViews,
        ] {
            let p = k.required_permission();
            assert!(!p.is_empty(), "{k:?} 没绑权限");
            assert!(
                crate::plugins::permission::is_known(p),
                "{k:?} 绑的权限 {p} 不在权限表里 —— manifest 校验会永远拒绝这类贡献"
            );
        }
    }

    #[test]
    fn panels_are_filtered_by_slot() {
        let reg = ContributionRegistry::new();
        for (id, slot) in [("a", "home.stats"), ("b", "sidebar"), ("c", "home.stats")] {
            reg.register(Contribution {
                plugin_id: "com.x.y".into(),
                kind: ContributionKind::Panels,
                id: id.into(),
                data: json!({ "id": id, "slot": slot }),
                from_manifest: true,
            });
        }
        // 没有 slot 的 panel 不该混进任何一个位置
        reg.register(Contribution {
            plugin_id: "com.x.y".into(),
            kind: ContributionKind::Panels,
            id: "noslot".into(),
            data: json!({ "id": "noslot" }),
            from_manifest: true,
        });
        let home: Vec<String> = reg.panels_in_slot("home.stats").iter().map(|c| c.id.clone()).collect();
        assert_eq!(home, vec!["a", "c"]);
        assert_eq!(reg.panels_in_slot("sidebar").len(), 1);
        assert_eq!(reg.panels_in_slot("player.overlay").len(), 0);
    }

    /// **manifest 的描述字段不能被运行时注册顶掉。**
    /// manifest 写 name/auth(描述),插件运行时写三个回调(行为),两边各写一半;
    /// 整条替换的话「添加服务器」页会拿到一个没有输入框、名字还是 id 的插件源。
    #[test]
    fn runtime_registration_merges_onto_the_manifest_declaration() {
        let reg = ContributionRegistry::new();
        // manifest:名字 + 登录表单
        reg.register(Contribution {
            plugin_id: "com.x.y".into(),
            kind: ContributionKind::DataSources,
            id: "demo".into(),
            data: json!({ "id": "demo", "name": "演示源",
                          "auth": { "fields": [ { "id": "base_url" } ] } }),
            from_manifest: true,
        });
        // 运行时:三个回调,只带 id
        let added = reg.register(Contribution {
            plugin_id: "com.x.y".into(),
            kind: ContributionKind::DataSources,
            id: "demo".into(),
            // name 两边都有:用来钉**合并方向**(运行时赢),不然方向写反了测试照样绿。
            data: json!({ "id": "demo", "name": "插件运行时改的名字",
                          "listDir": "h1", "search": "h2", "resolvePlay": "h3" }),
            from_manifest: false,
        });
        assert!(!added, "同 id 合并成一条,不是新增");

        let c = reg.find("com.x.y", ContributionKind::DataSources, "demo").unwrap();
        assert!(c.data["auth"]["fields"].is_array(), "manifest 的 auth 表单必须留着");
        assert_eq!(c.data["listDir"], "h1", "运行时回调必须挂上");
        assert_eq!(c.data["name"], "插件运行时改的名字", "同名键运行时赢,不是 manifest 赢");
        assert!(!c.from_manifest, "合并后这条以运行时为准");

        // manifest 独有的字段在只有 manifest 声明时当然也要在
        reg.register(Contribution {
            plugin_id: "com.x.y".into(),
            kind: ContributionKind::Panels,
            id: "p".into(),
            data: json!({ "id": "p", "title": "标题", "slot": "home.stats" }),
            from_manifest: true,
        });
        reg.register(Contribution {
            plugin_id: "com.x.y".into(),
            kind: ContributionKind::Panels,
            id: "p".into(),
            data: json!({ "id": "p", "render": { "__handler__": "h9" } }),
            from_manifest: false,
        });
        let p = reg.find("com.x.y", ContributionKind::Panels, "p").unwrap();
        assert_eq!(p.slot(), Some("home.stats"), "slot 丢了面板就不会出现在任何位置");
        assert_eq!(p.data["title"], "标题");
        assert_eq!(reg.panels_in_slot("home.stats").len(), 1);
    }

    /// panels/actions 要的是 `extensions` 不是 `ui`。这两条曾经对不上,
    /// 后果是 manifest 校验放行、运行时注册被拒,而拒的异常在 onEnable 里被吞掉,
    /// 表现成「插件已启用但面板永远空白」。
    #[test]
    fn panels_and_actions_require_extensions_not_ui() {
        assert_eq!(ContributionKind::Panels.required_permission(), "extensions");
        assert_eq!(ContributionKind::Actions.required_permission(), "extensions");
        assert_eq!(ContributionKind::DataSources.required_permission(), "sources");
        assert_eq!(ContributionKind::SandboxViews.required_permission(), "sandbox");
        // 每一条都必须是权限表里真实存在的 id
        for k in [
            ContributionKind::DataSources,
            ContributionKind::Panels,
            ContributionKind::Actions,
            ContributionKind::SandboxViews,
        ] {
            assert!(
                crate::plugins::permission::is_known(k.required_permission()),
                "{:?} 要的权限 {:?} 不在权限表里",
                k,
                k.required_permission()
            );
        }
    }

    #[test]
    fn register_overwrites_same_key_and_unregister_is_scoped() {
        let reg = ContributionRegistry::new();
        let mk = |pid: &str, id: &str, v: i32| Contribution {
            plugin_id: pid.into(),
            kind: ContributionKind::Actions,
            id: id.into(),
            data: json!({ "v": v }),
            from_manifest: false,
        };
        assert!(reg.register(mk("p1", "a", 1)), "首次注册应报新增");
        assert!(!reg.register(mk("p1", "a", 2)), "同键再注册应报覆盖");
        assert_eq!(reg.by_kind(ContributionKind::Actions).len(), 1);
        assert_eq!(reg.by_kind(ContributionKind::Actions)[0].data["v"], 2);

        reg.register(mk("p2", "a", 9));
        reg.unregister("p1", ContributionKind::Actions, "a");
        let left = reg.by_kind(ContributionKind::Actions);
        assert_eq!(left.len(), 1, "只该摘掉 p1 的,别把同 id 的 p2 一起带走");
        assert_eq!(left[0].plugin_id, "p2");
    }
}
