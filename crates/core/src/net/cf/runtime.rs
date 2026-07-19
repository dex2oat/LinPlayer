// CF 优选反代的「路由改写」运行时(全局)。迁自 Dart cf_proxy_runtime.dart。
//
// 这是整套 CF 优选的**唯一改写点**:某台服务器开启优选反代后,这里登记
// `server_id -> 本地反代基址(http://127.0.0.1:port/<原路径前缀>)`。
// [`crate::config::Account::active_line_url`] 取值时先查这里,命中则返回本地基址,
// 于是 Emby API 请求与 mpv 取流 URL 都自动改走本地反代 → 上游优选 CF IP,与播放器实现无关。
//
// 为什么是全局静态而不是塞进 AppState:改写点必须能被 `Account` 这个纯数据类型看见,
// 而 Account 在平台无关核里,拿不到宿主的 State。Dart 侧同理用的单例。
// 故意做得极薄、零依赖,避免 config → net 的循环引用变重。

use std::collections::HashMap;
use std::sync::RwLock;

static ROUTES: RwLock<Option<HashMap<String, String>>> = RwLock::new(None);

/// 命中则返回本地反代基址,否则 None(走原始线路)。
pub fn local_url_for(server_id: &str) -> Option<String> {
    ROUTES.read().ok()?.as_ref()?.get(server_id).cloned()
}

/// 登记改写:此后该服务器的 `active_line_url()` 返回 `local_url`。
pub fn bind(server_id: impl Into<String>, local_url: impl Into<String>) {
    if let Ok(mut g) = ROUTES.write() {
        g.get_or_insert_with(HashMap::new).insert(server_id.into(), local_url.into());
    }
}

/// 撤销改写,恢复直连原线路。
pub fn unbind(server_id: &str) {
    if let Ok(mut g) = ROUTES.write() {
        if let Some(m) = g.as_mut() {
            m.remove(server_id);
        }
    }
}

pub fn is_active(server_id: &str) -> bool {
    local_url_for(server_id).is_some()
}

/// 当前所有改写(server_id -> 本地基址),供设置页展示。
pub fn all() -> HashMap<String, String> {
    ROUTES.read().ok().and_then(|g| g.clone()).unwrap_or_default()
}

/// 拆除所有改写(退出/禁用插件时)。
pub fn clear() {
    if let Ok(mut g) = ROUTES.write() {
        *g = None;
    }
}

/// 把上游线路 URL 的路径前缀嫁接到本地反代端口上。
/// 对齐 Dart:`Uri(scheme:'http', host:'127.0.0.1', port:proxy.port, path: upstream.path)`。
/// 为什么要保留路径:反向代理只换了传输层落点,Emby 若挂在 `https://h/emby` 这种子路径下,
/// 丢掉 `/emby` 会让之后所有 API 打到 404 —— 且是「连得上但全 404」的静默故障。
pub fn local_base(upstream_url: &str, port: u16) -> String {
    let rest = upstream_url.split_once("://").map(|(_, r)| r).unwrap_or(upstream_url);
    let path = rest.find('/').map(|i| &rest[i..]).unwrap_or("");
    let path = path.trim_end_matches('/');
    format!("http://127.0.0.1:{port}{path}")
}

/// 拆出上游的 (scheme, host, port),供起反代用。默认 https:443 / http:80。
pub fn split_upstream(url: &str) -> (String, String, u16) {
    let (scheme, rest) = url.split_once("://").unwrap_or(("https", url));
    let scheme = if scheme.is_empty() { "https" } else { scheme };
    let authority = rest.split('/').next().unwrap_or(rest);
    // IPv6 字面量形如 [::1]:8096 —— 按最后一个 ':' 且在 ']' 之后切,否则会把地址本身切碎。
    let default_port = if scheme.eq_ignore_ascii_case("http") { 80 } else { 443 };
    let split_at = match authority.rfind(']') {
        Some(b) => authority[b..].find(':').map(|i| b + i),
        None => authority.rfind(':'),
    };
    match split_at {
        Some(i) => {
            let (h, p) = (&authority[..i], &authority[i + 1..]);
            (scheme.to_string(), h.to_string(), p.parse().unwrap_or(default_port))
        }
        None => (scheme.to_string(), authority.to_string(), default_port),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_base_keeps_upstream_path_prefix() {
        // 丢掉子路径 = 连得上但全 404 的静默故障,必须保住。
        assert_eq!(local_base("https://h.com/emby", 5001), "http://127.0.0.1:5001/emby");
        assert_eq!(local_base("https://h.com:443/emby/", 5001), "http://127.0.0.1:5001/emby");
        assert_eq!(local_base("https://h.com", 5001), "http://127.0.0.1:5001");
        assert_eq!(local_base("https://h.com/", 5001), "http://127.0.0.1:5001");
    }

    #[test]
    fn split_upstream_defaults_and_ipv6() {
        assert_eq!(split_upstream("https://h.com/emby"), ("https".into(), "h.com".into(), 443));
        assert_eq!(split_upstream("http://h.com/x"), ("http".into(), "h.com".into(), 80));
        assert_eq!(split_upstream("https://h.com:8096"), ("https".into(), "h.com".into(), 8096));
        // ':' 出现在 IPv6 地址内部,不能当端口分隔符切。
        assert_eq!(split_upstream("https://[::1]:8096/emby"), ("https".into(), "[::1]".into(), 8096));
        assert_eq!(split_upstream("https://[::1]/emby"), ("https".into(), "[::1]".into(), 443));
    }

    #[test]
    fn bind_and_unbind_roundtrip() {
        let id = "cf-runtime-test-server";
        assert!(!is_active(id));
        bind(id, "http://127.0.0.1:9999");
        assert_eq!(local_url_for(id).as_deref(), Some("http://127.0.0.1:9999"));
        assert!(is_active(id));
        unbind(id);
        assert!(!is_active(id));
    }
}
