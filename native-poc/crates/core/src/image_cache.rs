//! 图片磁盘缓存(封面/剧照/头像)。**2GB / 30 天**,超限按最久未用淘汰。
//!
//! ## 为什么必须有
//! 此前前端是 `<img src="{server}/Items/{id}/Images/Primary?...&api_key={token}">` 直出,
//! 让 webview 自己去拉 —— 于是:
//! - 每次进页面、每次翻回来,几十上百张封面全部重新回源。用户 2026-07-15:
//!   「你根本没做持久化缓存……每次都要重新加载,服务器压力很大」。
//! - webview 那点内存 HTTP 缓存关掉程序就没了,而且 Emby 的图片响应常带
//!   `Cache-Control` 不友好的头,反代一挡就更不缓存。
//! - **api_key 明文进 DOM**,还会落进 webview 的网络日志和 Emby 的 access log。
//!
//! 现在走自定义 scheme(见 src-tauri 的 lpimg 协议):前端只给条目 id,
//! URL 里不再有 token,字节由这里从磁盘或上游取。
//!
//! ## 缓存键 ≠ URL
//! **别拿上游 URL 当键** —— 它带 `api_key`,重登一次 token 就变,整盘缓存瞬间全部失效
//! (而且旧文件永远不会被命中,只能等 TTL 到期,白占 2GB)。
//! 键用「服务器 + 条目 + 图种 + 尺寸」这种**稳定身份**,由调用方给。

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// 总容量上限。用户 2026-07-15 选定 2GB(旧 Flutter 栈是 6GB,他选了更省盘的一档)。
pub const MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// 过期时间。超过就当没有,重新回源。
pub const TTL: Duration = Duration::from_secs(30 * 24 * 3600);
/// 单张上限。防「图片地址被填成一部电影的直链」把内存吃穿(icon_cache 同款考虑)。
const MAX_ONE: u64 = 32 * 1024 * 1024;
/// 攒够这么多新字节才做一次淘汰扫描。
/// 每次写入都扫 = 每存一张封面就 readdir 几万个文件,比不缓存还慢。
const SWEEP_EVERY: u64 = 64 * 1024 * 1024;

static ADDED_SINCE_SWEEP: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn cache_dir() -> PathBuf {
    let d = dirs::cache_dir()
        .or_else(dirs::config_dir)
        .unwrap_or_else(std::env::temp_dir)
        .join("LinPlayer")
        .join("images");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// 缓存键 → 文件名。键里有 `/` `:` 等字符,Windows 上直接当文件名建不出来;
/// 而且键可能很长(URL 拼的),超过文件名上限也会失败。故一律哈希成定长十六进制。
fn file_of(key: &str) -> PathBuf {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(key.as_bytes());
    let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
    cache_dir().join(hex)
}

fn age_of(p: &Path) -> Option<Duration> {
    let m = std::fs::metadata(p).ok()?.modified().ok()?;
    SystemTime::now().duration_since(m).ok()
}

/// 读缓存。未命中/已过期 → None。
///
/// 命中且「有点旧」时会把 mtime 顶到现在(touch)—— 淘汰是按 mtime 排的,
/// 不 touch 的话就退化成「按存入时间先进先出」,常看的封面照样被淘汰,等于白缓存。
/// 只在超过 1 天才 touch:每次命中都写一次 mtime,纯属拿磁盘 IO 换空气。
pub fn get(key: &str) -> Option<Vec<u8>> {
    let p = file_of(key);
    let age = age_of(&p)?;
    if age > TTL {
        let _ = std::fs::remove_file(&p); // 过期就顺手删掉,别等淘汰扫描
        return None;
    }
    let b = std::fs::read(&p).ok()?;
    if b.is_empty() {
        let _ = std::fs::remove_file(&p); // 空文件 = 上次写到一半崩了
        return None;
    }
    if age > Duration::from_secs(24 * 3600) {
        if let Ok(f) = std::fs::File::options().write(true).open(&p) {
            let _ = f.set_modified(SystemTime::now());
        }
    }
    Some(b)
}

/// 写缓存。失败(磁盘满/无权限)**不算错误** —— 缓存是优化,它挂了图片照样该显示出来。
pub fn put(key: &str, bytes: &[u8]) {
    if bytes.is_empty() || bytes.len() as u64 > MAX_ONE {
        return;
    }
    let p = file_of(key);
    /* 先写临时文件再 rename:直接写目标文件的话,写到一半进程被杀,
       留下的半张图会被后续 get() 当成有效缓存读出来 —— 表现为「封面永远是坏的,
       删缓存才好」。rename 在同一分区上是原子的。 */
    let tmp = p.with_extension("tmp");
    let ok = std::fs::File::create(&tmp)
        .and_then(|mut f| f.write_all(bytes).map(|_| f))
        .and_then(|f| f.sync_all())
        .is_ok();
    if !ok || std::fs::rename(&tmp, &p).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    let n = ADDED_SINCE_SWEEP.fetch_add(bytes.len() as u64, std::sync::atomic::Ordering::Relaxed);
    if n + bytes.len() as u64 >= SWEEP_EVERY {
        ADDED_SINCE_SWEEP.store(0, std::sync::atomic::Ordering::Relaxed);
        sweep();
    }
}

/// 淘汰:先删过期的,再在超出 [`MAX_BYTES`] 时按 mtime 从旧到新删到 90% 以下。
///
/// 删到 90% 而不是刚好卡在 100%:卡着上限会导致「每存一张就得再扫一次删一张」,
/// 扫描成本被摊到每一次写入上。留 10% 余量让下一次扫描离得远一点。
pub fn sweep() {
    let Ok(rd) = std::fs::read_dir(cache_dir()) else { return };
    let now = SystemTime::now();
    let mut files: Vec<(SystemTime, u64, PathBuf)> = vec![];
    let mut total = 0u64;
    for e in rd.flatten() {
        let p = e.path();
        let Ok(m) = e.metadata() else { continue };
        if !m.is_file() {
            continue;
        }
        let mt = m.modified().unwrap_or(now);
        // 过期的直接删,不参与容量计算
        if now.duration_since(mt).map(|a| a > TTL).unwrap_or(false) {
            let _ = std::fs::remove_file(&p);
            continue;
        }
        total += m.len();
        files.push((mt, m.len(), p));
    }
    if total <= MAX_BYTES {
        return;
    }
    files.sort_by_key(|(mt, _, _)| *mt); // 最久未用的排前面
    let target = MAX_BYTES / 10 * 9;
    for (_, len, p) in files {
        if total <= target {
            break;
        }
        if std::fs::remove_file(&p).is_ok() {
            total = total.saturating_sub(len);
        }
    }
}

/// 当前占用字节数(设置页「已用 xx MB」+「清除缓存」用)。
pub fn size_bytes() -> u64 {
    std::fs::read_dir(cache_dir())
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| e.metadata().ok())
                .filter(|m| m.is_file())
                .map(|m| m.len())
                .sum()
        })
        .unwrap_or(0)
}

/// 清空。
pub fn clear() {
    if let Ok(rd) = std::fs::read_dir(cache_dir()) {
        for e in rd.flatten() {
            let _ = std::fs::remove_file(e.path());
        }
    }
    ADDED_SINCE_SWEEP.store(0, std::sync::atomic::Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试共用**同一个真实缓存目录**,且缓存本就是要跨进程留存的 —— 所以每条测试
    /// 必须先把自己那个 key 清干净再跑,不能假设「上次跑完是干净的」。
    ///
    /// 这条 helper 是被真事教育出来的:验证 oversized_is_not_cached 时我注掉了上限判断,
    /// 那一跑真把 33MB 写进了缓存目录;还原代码后文件还在盘上,于是这条测试**一直红**。
    /// 换个人看到就是「莫名其妙的偶发失败」。
    fn k(name: &str) -> String {
        let key = format!("__test__/{name}/{:?}", std::thread::current().id());
        let _ = std::fs::remove_file(file_of(&key));
        key
    }

    #[test]
    fn put_then_get_roundtrips() {
        let key = k("roundtrip");
        put(&key, b"hello-bytes");
        assert_eq!(get(&key).as_deref(), Some(&b"hello-bytes"[..]));
        let _ = std::fs::remove_file(file_of(&key));
    }

    #[test]
    fn miss_returns_none_not_empty() {
        assert!(get(&k("never-written")).is_none());
    }

    /// 空文件 = 上次写到一半崩了。必须当未命中,不能返回 Some(vec![]) ——
    /// 那样前端拿到 0 字节的「图片」,是一张永远坏掉的封面,而且删缓存前修不好。
    #[test]
    fn empty_file_is_treated_as_miss_and_removed() {
        let key = k("empty");
        let p = file_of(&key);
        std::fs::write(&p, b"").unwrap();
        assert!(get(&key).is_none(), "0 字节的缓存必须判未命中");
        assert!(!p.exists(), "坏缓存必须顺手删掉,否则永远坏下去");
    }

    /// 超过单张上限的不许存(防图片地址被填成一部电影的直链)。
    #[test]
    fn oversized_is_not_cached() {
        let key = k("huge");
        put(&key, &vec![0u8; (MAX_ONE + 1) as usize]);
        assert!(get(&key).is_none(), "超限的东西不该进缓存");
    }

    /// 过期条目必须判未命中并删除。直接把 mtime 改老来模拟。
    #[test]
    fn expired_entry_is_a_miss_and_gets_removed() {
        let key = k("expired");
        put(&key, b"stale");
        let p = file_of(&key);
        assert!(get(&key).is_some(), "前提:刚存进去应该命中");
        // 顶到 TTL 之前
        let old = SystemTime::now() - TTL - Duration::from_secs(60);
        std::fs::File::options().write(true).open(&p).unwrap().set_modified(old).unwrap();
        assert!(get(&key).is_none(), "超过 TTL 必须判未命中");
        assert!(!p.exists(), "过期条目该被删掉");
    }

    /// 键里有 `/` `:` 这种 Windows 文件名非法字符,以及超长键,都必须能存能取。
    #[test]
    fn keys_with_path_chars_and_long_keys_work() {
        let key = format!("https://a.com:8096/Items/xyz/Images/Primary|h=480|{}", "x".repeat(500));
        let _ = std::fs::remove_file(file_of(&key)); // 同 k():不假设上次跑完是干净的
        put(&key, b"ok");
        assert_eq!(get(&key).as_deref(), Some(&b"ok"[..]), "含 :/ 的长键必须可用");
        let _ = std::fs::remove_file(file_of(&key));
    }

    /// 不同键不能撞到同一个文件上(撞了 = 用户看到张冠李戴的封面)。
    #[test]
    fn distinct_keys_do_not_collide() {
        let (a, b) = (k("collide-a"), k("collide-b"));
        put(&a, b"AAA");
        put(&b, b"BBB");
        assert_eq!(get(&a).as_deref(), Some(&b"AAA"[..]));
        assert_eq!(get(&b).as_deref(), Some(&b"BBB"[..]));
        let _ = std::fs::remove_file(file_of(&a));
        let _ = std::fs::remove_file(file_of(&b));
    }
}
