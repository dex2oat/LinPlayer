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

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

/// 总容量上限。用户 2026-07-15 选定 2GB(旧 Flutter 栈是 6GB,他选了更省盘的一档)。
pub const MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// 内存缓存上限。用户 2026-07-15 点名:「也得给一点去内存 128MB内存去缓存各种各样的图片」。
pub const MEM_MAX_BYTES: usize = 128 * 1024 * 1024;
/// 过期时间。超过就当没有,重新回源。
pub const TTL: Duration = Duration::from_secs(30 * 24 * 3600);
/// 单张上限。防「图片地址被填成一部电影的直链」把内存吃穿(icon_cache 同款考虑)。
const MAX_ONE: u64 = 32 * 1024 * 1024;
/// 攒够这么多新字节才做一次淘汰扫描。
/// 每次写入都扫 = 每存一张封面就 readdir 几万个文件,比不缓存还慢。
const SWEEP_EVERY: u64 = 64 * 1024 * 1024;

static ADDED_SINCE_SWEEP: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn cache_dir() -> PathBuf {
    crate::paths::cache_dir("images")
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

/* ================= 内存层(L1) =================
   磁盘层解决「重启后不用回源」,内存层解决「翻回来这一下要快」。
   两层都要:只有磁盘 = 每次重挂 <img> 都是一次 open+read+解码;只有内存 = 关了程序全没。

   淘汰用「最久未用」,数据结构就是 HashMap + 一个自增计数当时间戳:
   条目数 = 128MB / 单张约 100KB ≈ 1300,淘汰时线性扫一遍是几十微秒 ——
   为这点规模引 lru crate 不值当(而且它还得进依赖树、进安卓交叉编译)。 */
struct Mem {
    map: HashMap<String, (Vec<u8>, u64)>, // key -> (bytes, 最后使用序号)
    bytes: usize,
    tick: u64,
}

static MEM: Mutex<Option<Mem>> = Mutex::new(None);

fn with_mem<T>(f: impl FnOnce(&mut Mem) -> T) -> T {
    let mut g = MEM.lock().unwrap();
    let m = g.get_or_insert_with(|| Mem { map: HashMap::new(), bytes: 0, tick: 0 });
    f(m)
}

/// 只查内存层。给协议处理器用:命中就完全不碰磁盘。
pub fn mem_get(key: &str) -> Option<Vec<u8>> {
    with_mem(|m| {
        m.tick += 1;
        let tick = m.tick;
        let (b, used) = m.map.get_mut(key)?;
        *used = tick;
        Some(b.clone())
    })
}

/// 塞进内存层,必要时按最久未用淘汰到 90%。
///
/// 留 10% 余量而不是卡着上限:卡满了会变成「每存一张就得淘汰一张」,
/// 每次都线性扫一遍,扫描成本摊到每一次写入上。
pub fn mem_put(key: &str, bytes: &[u8]) {
    // 单张就超过内存上限 1/8 的(超大 backdrop),不进内存 —— 它会把整个缓存挤空,
    // 换来的只是它自己一张命中。磁盘层照存。
    if bytes.is_empty() || bytes.len() > MEM_MAX_BYTES / 8 {
        return;
    }
    with_mem(|m| {
        m.tick += 1;
        let tick = m.tick;
        if let Some((old, _)) = m.map.insert(key.to_string(), (bytes.to_vec(), tick)) {
            m.bytes -= old.len(); // 覆盖同一个键:先把旧的字节数减掉,否则计数只增不减
        }
        m.bytes += bytes.len();
        if m.bytes <= MEM_MAX_BYTES {
            return;
        }
        let target = MEM_MAX_BYTES / 10 * 9;
        // 按最后使用序号从旧到新排,删到 target 以下
        let mut by_age: Vec<(u64, String)> =
            m.map.iter().map(|(k, (_, u))| (*u, k.clone())).collect();
        by_age.sort_unstable();
        for (_, k) in by_age {
            if m.bytes <= target {
                break;
            }
            // ★ 别把刚放进去的那张淘汰掉(它是最新的,排在最后,正常轮不到;
            //   但单张若大于 target 就会走到这里 —— 上面的 1/8 上限已经堵死了这种情况)
            if let Some((b, _)) = m.map.remove(&k) {
                m.bytes -= b.len();
            }
        }
    })
}

/// 内存层当前占用(字节)。测试和设置页用。
pub fn mem_bytes() -> usize {
    with_mem(|m| m.bytes)
}

/// 清空内存层。**清理缓存必须连它一起清** —— 只删磁盘的话,内存里那份还在继续供图,
/// 用户看着占用变 0 却还是旧封面,那就是在骗他。
pub fn mem_clear() {
    with_mem(|m| {
        m.map.clear();
        m.bytes = 0;
    })
}

/// 读缓存(内存 → 磁盘)。未命中/已过期 → None。
///
/// ⚠️ **这是同步阻塞 IO**,调用方若在 async 上下文里,必须套 spawn_blocking。
/// 内存命中时不碰磁盘,但你没法预知会不会命中 —— 所以一律当阻塞的用。
pub fn get_2l(key: &str) -> Option<Vec<u8>> {
    if let Some(b) = mem_get(key) {
        return Some(b);
    }
    let b = get(key)?;
    mem_put(key, &b); // 磁盘命中也回填内存,下次就不碰盘了
    Some(b)
}

/// 写两层。
pub fn put_2l(key: &str, bytes: &[u8]) {
    mem_put(key, bytes);
    put(key, bytes);
}

/// 只读磁盘层。未命中/已过期 → None。
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

    /// 内存层测试**必须串行**:MEM 是进程级 static,而 cargo test 默认并行跑 ——
    /// 一个测试的 mem_clear() 会把另一个测试刚放进去的东西抹掉,
    /// 表现为「单跑绿、全跑随机红」。拿这个锁再碰内存层。
    ///
    /// 用 k() 那种「各测各的 key」在这里不管用:内存层的断言是**全局用量**(mem_bytes)
    /// 和**淘汰行为**,天然是全局的,隔离不开,只能串行。
    static MEM_TEST: Mutex<()> = Mutex::new(());
    fn mem_lock() -> std::sync::MutexGuard<'static, ()> {
        // 前一个测试 panic 会毒化锁;测试之间本就互不信任,清掉毒继续。
        MEM_TEST.lock().unwrap_or_else(|e| e.into_inner())
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

    /// 内存层:存了就该命中,且不碰磁盘。
    #[test]
    fn mem_roundtrips_without_touching_disk() {
        let _g = mem_lock();
        mem_clear();
        let key = k("mem-basic");
        mem_put(&key, b"in-memory");
        assert_eq!(mem_get(&key).as_deref(), Some(&b"in-memory"[..]));
        assert!(!file_of(&key).exists(), "mem_put 不该写盘");
        mem_clear();
    }

    /// ★ 超过 128MB 必须淘汰,否则内存无限涨 —— 用户给的就是 128MB 这个预算。
    #[test]
    fn mem_evicts_over_budget() {
        let _g = mem_lock();
        mem_clear();
        let one = 4 * 1024 * 1024; // 4MB 一张,40 张 = 160MB > 128MB
        for i in 0..40 {
            mem_put(&format!("{}-{i}", k("evict")), &vec![7u8; one]);
        }
        let used = mem_bytes();
        assert!(used <= MEM_MAX_BYTES, "内存用量 {used} 超了上限 {MEM_MAX_BYTES}");
        assert!(used > MEM_MAX_BYTES / 2, "淘汰过头了,只剩 {used} —— 那等于没缓存");
        mem_clear();
    }

    /// 淘汰必须优先扔**最久未用**的,不是最早存的。
    /// 搞反了 = 常看的封面反而先被扔,等于白缓存(磁盘层那边同理,见 get() 的 touch)。
    ///
    /// ## 配量必须算过,不能拍脑袋
    /// 这条第一版是**红的,而且怪我不怪实现**:我塞了 8+64+112=184MB,预算 128、淘汰到
    /// 115 → 要腾 69MB,而那批「中间的」总共才 64MB —— 不够,于是无论 LRU 还是 FIFO,
    /// old 都必然被扔。**那样的测试区分不了两种实现,红了也证明不了任何事。**
    /// 现在的配量:被淘汰的额度(17MB)**严格小于**中间那批的总量(80MB),
    /// 所以 old 活不活下来,只取决于它的「最后使用时间」有没有被 mem_get 顶上去。
    #[test]
    fn mem_evicts_least_recently_used_not_oldest_inserted() {
        let _g = mem_lock();
        mem_clear();
        const ONE: usize = 4 * 1024 * 1024;
        let old = k("lru-old");

        mem_put(&old, &vec![1u8; ONE]); // 最早存的那张
        for i in 0..20 {
            mem_put(&format!("{}-{i}", k("lru-mid")), &vec![2u8; ONE]); // 84MB,仍在预算内
        }
        assert!(mem_get(&old).is_some(), "前提:还没超预算,老的本就该在");
        assert!(mem_bytes() < MEM_MAX_BYTES, "前提:此时不该已经触发淘汰");

        // ★ 上面这次 mem_get 就是「最近用过」的证据。它是本测试的全部意义:
        //   若 mem_get 不更新最后使用时间,old 的时间戳还停在最早,下面必被首个扔掉。
        for i in 0..12 {
            mem_put(&format!("{}-{i}", k("lru-new")), &vec![3u8; ONE]); // 到 132MB → 触发淘汰
        }
        assert!(mem_bytes() <= MEM_MAX_BYTES, "前提:应该已经淘汰过了");
        assert!(
            mem_get(&old).is_some(),
            "刚读过的那张被淘汰了 —— 淘汰按的是存入顺序,不是最后使用时间"
        );
        mem_clear();
    }

    /// 覆盖同一个键时,字节计数不能只增不减(否则用不了多久就误判超预算、疯狂淘汰)。
    #[test]
    fn mem_overwrite_does_not_leak_byte_count() {
        let _g = mem_lock();
        mem_clear();
        let key = k("overwrite");
        mem_put(&key, &vec![0u8; 1000]);
        let after_first = mem_bytes();
        for _ in 0..50 {
            mem_put(&key, &vec![0u8; 1000]);
        }
        assert_eq!(mem_bytes(), after_first, "同一个键覆盖 50 次,字节计数涨了 —— 减法漏了");
        mem_clear();
    }

    /// 单张超大图(比如 backdrop 原图)不进内存:它会把整个缓存挤空,只换来自己一张命中。
    #[test]
    fn mem_rejects_one_huge_entry() {
        let _g = mem_lock();
        mem_clear();
        let key = k("huge-mem");
        mem_put(&key, &vec![0u8; MEM_MAX_BYTES / 8 + 1]);
        assert!(mem_get(&key).is_none(), "超大单张不该进内存层");
        assert_eq!(mem_bytes(), 0);
        mem_clear();
    }

    /// 两层联动:磁盘命中要回填内存,下次就不碰盘。
    #[test]
    fn disk_hit_backfills_memory() {
        let _g = mem_lock();
        mem_clear();
        let key = k("backfill");
        put(&key, b"on-disk"); // 只写盘
        assert!(mem_get(&key).is_none(), "前提:内存里还没有");
        assert_eq!(get_2l(&key).as_deref(), Some(&b"on-disk"[..]));
        assert_eq!(mem_get(&key).as_deref(), Some(&b"on-disk"[..]), "磁盘命中后必须回填内存");
        let _ = std::fs::remove_file(file_of(&key));
        mem_clear();
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
