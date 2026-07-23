//! 插件权限模型(港自 Dart plugin_permission.dart)。
//!
//! 声明制:插件在 manifest.permissions 里声明所需能力,用户启用前必须同意。运行时每次
//! `ctx.*` 调用做权限检查,未授权 -> Err -> JS 异常。`log` 隐式授予、无需声明。

/// 单个权限定义。
pub struct PluginPermission {
    pub id: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    /// 涉及网络/隐私的「危险」权限,UI 上需强调。
    pub dangerous: bool,
}

/// 全部内置可申请权限。顺序即 UI 展示顺序。
pub const ALL: &[PluginPermission] = &[
    PluginPermission { id: "player.read", title: "读取播放状态", dangerous: false,
        description: "获取当前播放的媒体信息、播放进度,并监听播放事件(如播放结束)。" },
    PluginPermission { id: "player.control", title: "控制播放器", dangerous: true,
        description: "可以播放、暂停、跳转当前视频。" },
    PluginPermission { id: "http", title: "网络访问", dangerous: true,
        description: "通过 HTTPS 访问外部网络(受域名白名单限制)。" },
    PluginPermission { id: "storage", title: "本地存储", dangerous: false,
        description: "在本地保存插件自己的数据(每个插件独立,上限 5MB)。" },
    PluginPermission { id: "ui", title: "界面交互", dangerous: false,
        description: "弹出提示、对话框,或打开插件页面。" },
    PluginPermission { id: "emby.read", title: "读取 Emby 信息", dangerous: false,
        description: "读取当前登录用户和服务器地址。" },
    PluginPermission { id: "emby.api", title: "调用 Emby 接口", dangerous: true,
        description: "以当前登录身份向 Emby 服务器发起任意 API 请求。" },
    PluginPermission { id: "sources", title: "提供数据源", dangerous: true,
        description: "向应用注册可浏览、搜索、播放的媒体源,出现在你的服务器列表里。" },
    PluginPermission { id: "extensions", title: "扩展界面", dangerous: false,
        description: "向应用注册侧边栏入口、操作按钮、设置页等界面模块。" },
    PluginPermission { id: "sandbox", title: "自定义界面", dangerous: true,
        description: "在隔离沙箱里渲染插件自带的网页界面(拿不到应用本身的任何接口)。" },
    PluginPermission { id: "log", title: "写日志", dangerous: false,
        description: "输出调试日志(始终允许)。" },
];

/// v1 有、v2 已删除的权限。**单独列出来是为了给用户一句人话**,
/// 而不是让老插件撞上「未知权限: cfproxy」这种像是 App 出了 bug 的报错。
///
/// - `emby.credentials`:宿主不再持久化明文密码,插件要账密请自己弹表单存自己的 storage。
/// - `cfproxy`:CF 优选反代本来就是宿主的活,包成插件是绕圈;改做宿主内置设置项。
pub const REMOVED: &[(&str, &str)] = &[
    ("emby.credentials", "宿主不再保存登录密码;请改为在插件自己的设置页里让用户填写"),
    ("cfproxy", "CF 优选反代已改为应用内置功能,不再经由插件"),
];

/// 这个权限是不是 v2 里被删掉的。是的话返回给用户看的原因。
pub fn removed_reason(id: &str) -> Option<&'static str> {
    REMOVED.iter().find(|(k, _)| *k == id).map(|(_, why)| *why)
}

/// 始终授予、无需声明的权限。
pub const IMPLICITLY_GRANTED: &[&str] = &["log"];

pub fn is_known(id: &str) -> bool {
    ALL.iter().any(|p| p.id == id)
}

pub fn by_id(id: &str) -> Option<&'static PluginPermission> {
    ALL.iter().find(|p| p.id == id)
}

/// 一组已授予权限。
#[derive(Clone, Debug)]
pub struct GrantedPermissions {
    ids: std::collections::HashSet<String>,
}

impl GrantedPermissions {
    pub fn new(ids: impl IntoIterator<Item = String>) -> Self {
        let mut set: std::collections::HashSet<String> = ids.into_iter().collect();
        for g in IMPLICITLY_GRANTED {
            set.insert((*g).to_string());
        }
        Self { ids: set }
    }

    pub fn has(&self, id: &str) -> bool {
        self.ids.contains(id)
    }
}

/// 权限被拒 -> 变成插件内 JS 异常的错误文案。
pub fn permission_error(plugin_id: &str, permission_id: &str) -> String {
    format!("插件 {plugin_id} 缺少权限「{permission_id}」")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_is_implicitly_granted() {
        let g = GrantedPermissions::new(vec!["ui".to_string()]);
        assert!(g.has("ui"));
        assert!(g.has("log")); // 隐式
        assert!(!g.has("http"));
    }

    #[test]
    fn known_permissions() {
        assert!(is_known("sources"));
        assert!(is_known("sandbox"));
        assert!(!is_known("filesystem"));
    }

    /// v2 删掉的权限必须**同时**满足:不再是已知权限(manifest 校验会拒),
    /// 且能给出一句人话原因(拒的时候别让用户以为是 App 坏了)。
    /// 只删一半 —— 比如从 ALL 里删了却忘了进 REMOVED —— 老插件会撞上
    /// 「未知权限: cfproxy」,看起来像 bug 而不是设计。
    #[test]
    fn removed_permissions_are_rejected_with_a_human_reason() {
        for (id, _) in REMOVED {
            assert!(!is_known(id), "{id} 已宣布删除,却还在 ALL 里 —— 会被继续放行");
            let why = removed_reason(id).unwrap_or("");
            assert!(!why.is_empty(), "{id} 被删了却没给原因");
        }
        assert_eq!(removed_reason("http"), None, "在用的权限不该被当成已删除");
        assert!(removed_reason("emby.credentials").is_some());
        assert!(removed_reason("cfproxy").is_some());
    }
}
