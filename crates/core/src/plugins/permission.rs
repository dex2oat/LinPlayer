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
    PluginPermission { id: "emby.credentials", title: "读取登录账号密码", dangerous: true,
        description: "读取你添加服务器时填写的用户名与密码(用于代你登录配套网站)。" },
    PluginPermission { id: "extensions", title: "扩展界面", dangerous: false,
        description: "向应用注册侧边栏入口、操作按钮、设置页等扩展点。" },
    PluginPermission { id: "cfproxy", title: "CF 优选反代", dangerous: true,
        description: "对你添加的服务器做 Cloudflare 优选 IP 测速,并启用本地反代改写其网络线路。" },
    PluginPermission { id: "log", title: "写日志", dangerous: false,
        description: "输出调试日志(始终允许)。" },
];

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
        assert!(is_known("emby.credentials"));
        assert!(!is_known("filesystem"));
    }
}
