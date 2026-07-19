//! 平台能力缝:core 保持零桌面依赖,凡是要碰「活的 App 状态」的能力(ui 渲染 / mpv 播放器
//! 控制 / 当前 Emby 服务器 / cfproxy 控制器)都经这个 trait 交给 src-tauri 实现。
//!
//! core 内自持的能力(log/http/storage/sleep/extensions 注册)不走这里。权限检查也在 core
//! 完成,host 只管把已授权的调用落到平台。

use async_trait::async_trait;
use serde_json::Value;

#[async_trait]
pub trait PluginHost: Send + Sync {
    /// 平台能力调用。channel ∈ {ui, player, emby, cfproxy},method/args 见各 ctx.* 定义。
    /// 权限已在 core 检查过;返回 JSON 值或错误文案。
    async fn call(
        &self,
        plugin_id: &str,
        channel: &str,
        method: &str,
        args: Vec<Value>,
    ) -> Result<Value, String>;

    /// 写日志(始终允许,无需权限)。
    fn log(&self, plugin_id: &str, level: &str, msg: &str) {
        let _ = (plugin_id, level, msg);
    }

    /// 扩展注册表发生变化 -> 通知前端重新拉取渲染。
    fn extensions_changed(&self) {}
}

/// 测试/无宿主环境用:所有平台能力返回 Null。
pub struct NoopHost;

#[async_trait]
impl PluginHost for NoopHost {
    async fn call(&self, _: &str, _: &str, _: &str, _: Vec<Value>) -> Result<Value, String> {
        Ok(Value::Null)
    }
}
