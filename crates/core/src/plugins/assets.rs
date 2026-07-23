//! `lpplugin://` 静态资源解析:iframe 逃生舱和插件图标从这里读文件。
//!
//! 宿主注册一个自定义 URI scheme(桌面侧照抄 `apps/desktop/src/imgcache.rs` 已在用的
//! `register_asynchronous_uri_scheme_protocol`),把 `lpplugin://<插件id>/<相对路径>`
//! 交给这里解析成磁盘路径。
//!
//! **为什么逃生舱不能直接把 React 组件塞进主窗口**:主窗口的 JS 上下文里有
//! `__TAURI_INTERNALS__.invoke` —— 插件代码进去就等于拿到宿主全部命令,
//! rquickjs 那套权限模型直接变成摆设。所以逃生舱必须是独立 origin 的 iframe,
//! 而独立 origin 就需要这个协议来喂文件。
//! (顺带澄清:挡住它的**不是** Tauri CSP —— `tauri.conf.json` 里 `"csp": null`,
//! 压根没注入 CSP。理由是 invoke 可达性,不是 CSP。)

use std::path::{Component, Path, PathBuf};

/// 解析失败的原因。分开是因为宿主要按类型回不同 HTTP 状态码。
#[derive(Debug, PartialEq)]
pub enum AssetError {
    /// 插件不存在或未启用。
    NotEnabled,
    /// 路径越界 / 非法。
    Forbidden,
    /// 文件不存在。
    NotFound,
}

/// 把 `lpplugin://` 的请求路径解析成插件目录内的真实文件路径。
///
/// `rel` 是 URL 里插件 id 之后的部分。三道防线:
///  1. 逐段检查:`..` / 根组件 / 盘符前缀一律拒(在字符串层就挡掉);
///  2. 规范化后必须仍以插件目录为前缀(挡符号链接和大小写差异之外的意外);
///  3. 必须是文件、且真实存在。
///
/// 只做纯路径逻辑,不碰 IO 之外的东西 —— 这样穿越防护可以直接单测,
/// 而不必拉起一个 Tauri app。
pub fn resolve_asset(plugin_dir: &Path, rel: &str) -> Result<PathBuf, AssetError> {
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() {
        return Err(AssetError::Forbidden);
    }
    // URL 里可能带 query/fragment,先切掉。
    let rel = rel.split(['?', '#']).next().unwrap_or("");
    // 百分号解码后再检查 —— 否则 `%2e%2e%2f` 能绕过下面的逐段检查。
    let decoded = percent_decode(rel);

    let candidate = Path::new(&decoded);
    for comp in candidate.components() {
        match comp {
            Component::Normal(_) => {}
            // ParentDir(..) / RootDir(/) / Prefix(C:) / CurDir(.) 全部拒绝
            _ => return Err(AssetError::Forbidden),
        }
    }

    let joined = plugin_dir.join(candidate);

    // 规范化。文件不存在时 canonicalize 会失败,那就是 NotFound。
    let real = joined.canonicalize().map_err(|_| AssetError::NotFound)?;
    let root = plugin_dir.canonicalize().map_err(|_| AssetError::NotEnabled)?;
    if !real.starts_with(&root) {
        return Err(AssetError::Forbidden);
    }
    if !real.is_file() {
        return Err(AssetError::NotFound);
    }
    Ok(real)
}

/// 最小百分号解码。只为把 `%2e%2e` 这类编码还原出来交给上面的逐段检查 ——
/// 不追求完整 URL 语义。非法转义原样保留(保留比吞掉安全:留着会被判非法,吞掉可能拼出合法路径)。
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(b) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 按扩展名给个 Content-Type。逃生舱要用的就这几类;认不出一律 octet-stream
/// (**不猜** —— 猜错成 text/html 会把任意文件变成可执行页面)。
pub fn content_type_for(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "txt" | "md" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sandbox(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("lp_asset_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let plugin = base.join("plugins").join("com.x.y");
        std::fs::create_dir_all(plugin.join("ui")).unwrap();
        std::fs::write(plugin.join("ui").join("index.html"), "<p>hi</p>").unwrap();
        std::fs::write(plugin.join("icon.svg"), "<svg/>").unwrap();
        // 插件目录**外**的秘密文件 —— 穿越测试的靶子
        std::fs::write(base.join("secret.txt"), "TOP SECRET").unwrap();
        plugin
    }

    #[test]
    fn resolves_files_inside_the_plugin_dir() {
        let dir = sandbox("ok");
        assert!(resolve_asset(&dir, "ui/index.html").is_ok());
        assert!(resolve_asset(&dir, "/ui/index.html").is_ok(), "前导斜杠要容忍");
        assert!(resolve_asset(&dir, "icon.svg").is_ok());
        assert!(resolve_asset(&dir, "ui/index.html?v=2").is_ok(), "query 要被切掉");
        assert!(resolve_asset(&dir, "ui/index.html#top").is_ok(), "fragment 要被切掉");
    }

    /// 穿越必须挡死,而且**必须由第一层(逐段检查)挡下、判定为 Forbidden**。
    ///
    /// 断言写成 `Forbidden` 而不是 `Forbidden | NotFound` 是有意的:
    /// 实测发现放宽成两者皆可时,「去掉百分号解码」这个真 bug 测不出来 ——
    /// 未解码的 `..%2f..%2f` 会变成一个不存在的文件名、落到 NotFound,测试照样绿。
    /// 那叫绿错了原因。
    #[test]
    fn traversal_shapes_are_rejected_by_the_component_check() {
        let dir = sandbox("trav");
        // 这些在所有平台上都是明确的穿越/绝对路径
        let always = [
            "../secret.txt",
            "ui/../../secret.txt",
            "./../secret.txt",
            "ui/..%2f..%2fsecret.txt", // 百分号编码
            "%2e%2e/secret.txt",       // 编码的 ..
            "%2E%2E%2Fsecret.txt",     // 大写十六进制
        ];
        for a in always {
            assert_eq!(
                resolve_asset(&dir, a),
                Err(AssetError::Forbidden),
                "{a:?} 必须在逐段检查这一层就被判 Forbidden"
            );
        }

        // `/etc/passwd` **不是**穿越:URL 里的前导斜杠是路径分隔符,不是绝对路径标记,
        // 所以它表示「插件目录下的 etc/passwd」。正确答案是 NotFound。
        // (写成 Forbidden 会让人以为这里挡住了什么,其实什么也没挡。)
        assert_eq!(resolve_asset(&dir, "/etc/passwd"), Err(AssetError::NotFound));
        // 但多个前导斜杠之后接 `..` 仍然是穿越,不能被 trim 掩护过去
        assert_eq!(resolve_asset(&dir, "//../secret.txt"), Err(AssetError::Forbidden));

        // 反斜杠和盘符只有在 Windows 上才是路径语义;Linux 上 `..\x` 就是个普通文件名。
        // 不能一刀切断言,否则测试在另一个平台上是错的(本项目要跑 Win 和 Linux)。
        #[cfg(windows)]
        for a in ["..\\secret.txt", "C:\\Windows\\win.ini", "ui\\..\\..\\secret.txt"] {
            assert_eq!(resolve_asset(&dir, a), Err(AssetError::Forbidden), "{a:?}");
        }
    }

    /// 第二层(canonicalize 后仍须以插件目录为前缀)防的是**符号链接** ——
    /// 插件目录里一个指向外面的软链,路径上全是 Normal 组件,第一层放行,
    /// 只有解析真实路径后比对前缀才能挡住。
    ///
    /// 只在 Unix 跑:Windows 建符号链接要管理员或开发者模式,CI 上不可靠。
    /// Linux CI 会跑到这条,所以这一层不是没人测的死代码。
    #[cfg(unix)]
    #[test]
    fn symlink_escaping_the_plugin_dir_is_blocked_by_the_prefix_check() {
        let dir = sandbox("symlink");
        let outside = dir.parent().unwrap().parent().unwrap().join("secret.txt");
        assert!(outside.exists(), "测试脚手架没建对");
        std::os::unix::fs::symlink(&outside, dir.join("leak.txt")).unwrap();

        // 路径上没有一个 `..`,第一层完全放行;必须靠前缀校验挡下。
        assert_eq!(
            resolve_asset(&dir, "leak.txt"),
            Err(AssetError::Forbidden),
            "指向目录外的软链必须被前缀校验挡住"
        );
    }

    /// 兜底断言:任何情况下解析结果都不许落在插件目录之外。
    #[test]
    fn nothing_ever_resolves_outside_the_plugin_dir() {
        let dir = sandbox("outside");
        let root = dir.canonicalize().unwrap();
        for a in [
            "../secret.txt",
            "ui/../../secret.txt",
            "ui/index.html",
            "icon.svg",
            "%2e%2e/secret.txt",
        ] {
            if let Ok(p) = resolve_asset(&dir, a) {
                assert!(p.starts_with(&root), "{a:?} 解析到了插件目录之外: {p:?}");
                assert!(!p.ends_with("secret.txt"), "{a:?} 读到了插件目录外的文件");
            }
        }
    }

    #[test]
    fn empty_and_directory_paths_are_rejected() {
        let dir = sandbox("empty");
        assert_eq!(resolve_asset(&dir, ""), Err(AssetError::Forbidden));
        assert_eq!(resolve_asset(&dir, "/"), Err(AssetError::Forbidden));
        assert_eq!(resolve_asset(&dir, "ui"), Err(AssetError::NotFound), "目录不是资源");
        assert_eq!(resolve_asset(&dir, "nope.html"), Err(AssetError::NotFound));
    }

    /// 认不出的扩展名必须是 octet-stream。猜成 text/html 会把插件目录里
    /// 任意一个文件变成能执行脚本的页面。
    #[test]
    fn unknown_extensions_never_become_html() {
        assert_eq!(content_type_for(Path::new("a.html")), "text/html; charset=utf-8");
        assert_eq!(content_type_for(Path::new("a.js")), "text/javascript; charset=utf-8");
        assert_eq!(content_type_for(Path::new("a.svg")), "image/svg+xml");
        for weird in ["a.exe", "a.bin", "a", "a.html.bak", "a.HTM_"] {
            assert_eq!(
                content_type_for(Path::new(weird)),
                "application/octet-stream",
                "{weird} 不该被猜成别的类型"
            );
        }
        // 大小写不敏感
        assert_eq!(content_type_for(Path::new("A.HTML")), "text/html; charset=utf-8");
    }

    #[test]
    fn percent_decode_keeps_invalid_escapes_verbatim() {
        assert_eq!(percent_decode("a%2fb"), "a/b");
        assert_eq!(percent_decode("a%2Fb"), "a/b");
        // 非法转义保留原样 —— 吞掉的话 "%2" + "e." 可能被拼成 ".."
        assert_eq!(percent_decode("a%zzb"), "a%zzb");
        assert_eq!(percent_decode("a%2"), "a%2");
        assert_eq!(percent_decode("plain"), "plain");
    }
}
