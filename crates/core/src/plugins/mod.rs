//! 插件系统(Phase 7):QuickJS(rquickjs)执行 JS 插件,原生把宿主能力绑进 `ctx`。
//!
//! 相对 Flutter/flutter_qjs 版的改进:不再走 `__lp_host(channel,method,argsJson)` 字符串
//! 编组(那是跨 Dart isolate 只能传简单类型逼出来的)。这里把 Rust async 函数**直接**绑成
//! JS 函数返回真 Promise;插件回调用 `Persistent<Function>` 存下日后直接调。整层脚手架消失。
//!
//! 无 Apple 目标 -> 只支持 runtime: js(data/addon 是 iOS App Store 合规专用,已砍)。

mod convert;
mod ctx;
mod engine;
pub mod extensions;
pub mod host;
mod installer;
pub mod manager;
pub mod manifest;
pub mod permission;
mod state;
pub mod storage;
mod worker;

#[cfg(test)]
mod hello_it;

pub use extensions::{ExtensionRegistry, ExtensionType, RegisteredExtension};
pub use host::{NoopHost, PluginHost};
pub use manager::{PluginManager, PluginStatus, MAX_ENABLED};
pub use manifest::PluginManifest;
pub use permission::GrantedPermissions;
