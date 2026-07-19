//! 扩展点(港自 Dart plugin_extension_point.dart + plugin_extension_registry.dart)。
//!
//! 插件把自定义功能「挂载」到预定义位置:静态(manifest.extends)或动态
//! (`ctx.extensions.register`)。宿主收集后在对应位置渲染;handler 由引擎回调触发。
//!
//! ponytail: 平台过滤(TV 不支持 playerOverlays/contextMenus)未做——PoC 仅桌面。
//! 加 TV 端时在 register 处按平台忽略即可。

use std::sync::Mutex;

use serde_json::{json, Value};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ExtensionType {
    SidebarItems,
    MediaSources,
    Actions,
    EventListeners,
    SettingsPages,
    HomeStats,
    PlayerOverlays,
    ContextMenus,
}

impl ExtensionType {
    pub fn id(&self) -> &'static str {
        match self {
            ExtensionType::SidebarItems => "sidebarItems",
            ExtensionType::MediaSources => "mediaSources",
            ExtensionType::Actions => "actions",
            ExtensionType::EventListeners => "eventListeners",
            ExtensionType::SettingsPages => "settingsPages",
            ExtensionType::HomeStats => "homeStats",
            ExtensionType::PlayerOverlays => "playerOverlays",
            ExtensionType::ContextMenus => "contextMenus",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "sidebarItems" => ExtensionType::SidebarItems,
            "mediaSources" => ExtensionType::MediaSources,
            "actions" => ExtensionType::Actions,
            "eventListeners" => ExtensionType::EventListeners,
            "settingsPages" => ExtensionType::SettingsPages,
            "homeStats" => ExtensionType::HomeStats,
            "playerOverlays" => ExtensionType::PlayerOverlays,
            "contextMenus" => ExtensionType::ContextMenus,
            _ => return None,
        })
    }
}

/// 一条已注册扩展。`data` 里的 handler 已被引擎替换成 `{"__handler__": id}` 标记
/// (真正的 JS 函数在引擎的 handler 表里,以 Persistent 存)。
#[derive(Clone, Debug)]
pub struct RegisteredExtension {
    pub plugin_id: String,
    pub type_: ExtensionType,
    pub id: String,
    pub data: Value,
    pub from_manifest: bool,
}

impl RegisteredExtension {
    /// 供前端渲染的精简 JSON。
    pub fn to_json(&self) -> Value {
        json!({
            "pluginId": self.plugin_id,
            "type": self.type_.id(),
            "id": self.id,
            "data": self.data,
            "fromManifest": self.from_manifest,
        })
    }
}

/// 全局扩展注册表(所有插件共享一份)。
#[derive(Default)]
pub struct ExtensionRegistry {
    items: Mutex<Vec<RegisteredExtension>>,
}

impl ExtensionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注册/覆盖(同 plugin+type+id 视为同一条)。返回是否为新增。
    pub fn register(&self, ext: RegisteredExtension) -> bool {
        let mut items = self.items.lock().unwrap();
        if let Some(slot) = items
            .iter_mut()
            .find(|e| e.plugin_id == ext.plugin_id && e.type_ == ext.type_ && e.id == ext.id)
        {
            *slot = ext;
            false
        } else {
            items.push(ext);
            true
        }
    }

    pub fn unregister(&self, plugin_id: &str, type_: ExtensionType, id: &str) {
        let mut items = self.items.lock().unwrap();
        items.retain(|e| !(e.plugin_id == plugin_id && e.type_ == type_ && e.id == id));
    }

    pub fn remove_all_for_plugin(&self, plugin_id: &str) {
        let mut items = self.items.lock().unwrap();
        items.retain(|e| e.plugin_id != plugin_id);
    }

    /// 取某类型全部扩展(供前端渲染 homeStats/sidebarItems 等)。
    pub fn by_type(&self, type_: ExtensionType) -> Vec<RegisteredExtension> {
        self.items
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.type_ == type_)
            .cloned()
            .collect()
    }

    /// 查一条(供 manager 触发 handler)。
    pub fn find(&self, plugin_id: &str, type_: ExtensionType, id: &str) -> Option<RegisteredExtension> {
        self.items
            .lock()
            .unwrap()
            .iter()
            .find(|e| e.plugin_id == plugin_id && e.type_ == type_ && e.id == id)
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
