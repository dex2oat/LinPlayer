// 多线程加载(本地缓存预取代理)—— 迁自 Dart lib/core/network/prefetch_proxy/prefetch_proxy.dart。
//
// 起播时在 127.0.0.1:<随机端口> 起本地 HTTP 服务当播放源交给 mpv。代理用 2~4 个并发
// Range 连接对真实播放流"超前"拉取,在内存里维护有界读前缓冲,再"顺序"喂给播放器:
//   - 多连接聚合带宽 → 弱网也能喂满,少卡顿;
//   - 播放器从 localhost 读 → 抖动被缓冲吸收;
//   - 代理对上游网络错误自带重试,mpv 只面对始终在线的 localhost,弱网瞬断不冒泡。
//
// 只代理 Emby 直传流(直链/转码由调用方跳过);故只带全局 UA,无逐流鉴权头。
// 取不到文件大小 / 起服失败 → start() 返回 None,调用方回退直连在线地址。

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{watch, Mutex, Notify};
use tokio::task::JoinHandle;

const CHUNK_SIZE: u64 = 4 * 1024 * 1024; // 每段 4MB
const MAX_READ_AHEAD: u64 = 128 * 1024 * 1024; // 内存读前缓冲硬上限 128MB

/// 上游签名链失效时的重签回调:重走 PlaybackInfo 拿新直传流地址;None=不支持重签。
pub type ResignFn =
    Arc<dyn Fn() -> Pin<Box<dyn Future<Output = Option<String>> + Send>> + Send + Sync>;

fn logw(msg: &str) {
    eprintln!("[Prefetch] {msg}");
}

/// 一个运行中的代理句柄;Drop 即停服、作废在途、放行 worker 退出。
pub struct ProxyHandle {
    pub url: String,
    session: Arc<Session>,
    _accept: JoinHandle<()>,
}

impl Drop for ProxyHandle {
    fn drop(&mut self) {
        self.session.closed.store(true, Ordering::SeqCst);
        self.session.bump_gen();
        self.session.window_notify.notify_waiters();
        self.session.data_notify.notify_waiters();
    }
}

/// 启动预取代理并返回本地播放 URL;失败返回 None(调用方回退在线直链)。
///
/// `threads` 限定 2~4;`cache_limit_bytes` 为用户视频缓存上限(给读前缓冲封顶);
/// `on_invalid` 为上游失效重签回调(可 None)。
pub async fn start(
    upstream_url: String,
    threads: usize,
    cache_limit_bytes: u64,
    on_invalid: Option<ResignFn>,
) -> Option<ProxyHandle> {
    let t = threads.clamp(2, 4);
    let read_ahead = MAX_READ_AHEAD.min((CHUNK_SIZE * t as u64 * 2).max(cache_limit_bytes));

    let session = Session::create(upstream_url.clone(), t, read_ahead, on_invalid).await?;

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.ok()?;
    let port = listener.local_addr().ok()?.port();

    // 起并发 worker。
    for _ in 0..t {
        let s = session.clone();
        tokio::spawn(async move { s.worker().await });
    }

    let accept = {
        let s = session.clone();
        tokio::spawn(async move {
            loop {
                if s.closed.load(Ordering::SeqCst) {
                    break;
                }
                match listener.accept().await {
                    Ok((stream, _)) => {
                        let sc = s.clone();
                        tokio::spawn(async move {
                            if let Err(e) = sc.handle(stream).await {
                                let _ = e; // 播放器断开(seek/退出)属正常,静默
                            }
                        });
                    }
                    Err(e) => {
                        logw(&format!("本地服务监听异常: {e}"));
                        break;
                    }
                }
            }
        })
    };

    let url = format!("http://127.0.0.1:{port}/play");
    eprintln!(
        "[Prefetch] 多线程预取代理启动 {url} <- {upstream_url} ({}MB, {t} 线程, 读前缓冲 {}MB)",
        session.total_size / (1024 * 1024),
        read_ahead / (1024 * 1024),
    );
    Some(ProxyHandle {
        url,
        session,
        _accept: accept,
    })
}

struct UpstreamState {
    url: String,
    resign_disabled: bool,
    resign_in_flight: bool,
}

struct ChunkState {
    ready: HashMap<u64, Arc<Vec<u8>>>, // 已就绪分段(顺序消费后即清,内存有界)
    pending: HashSet<u64>,             // 已认领在途
    failed: HashSet<u64>,              // 永久失败(供给端遇到即断流)
    serve_chunk: u64,                  // 下一个要供给的分段
    fetch_cursor: u64,                 // 下一个要分配给 worker 的分段
}

struct Session {
    upstream: Mutex<UpstreamState>,
    total_size: u64,
    total_chunks: u64,
    content_type: String,
    read_ahead_chunks: u64,
    state: Mutex<ChunkState>,
    data_notify: Notify,   // worker -> handle:某段就绪/失败
    window_notify: Notify, // handle -> worker:窗口推进/reset
    gen_tx: watch::Sender<u64>, // seek/dispose 自增作废在途
    closed: AtomicBool,
    client: reqwest::Client,
    on_invalid: Option<ResignFn>,
}

impl Session {
    async fn create(
        upstream_url: String,
        threads: usize,
        read_ahead_bytes: u64,
        on_invalid: Option<ResignFn>,
    ) -> Option<Arc<Session>> {
        let client = crate::http::client();

        // 探总大小 + Content-Type:Range bytes=0-0 -> 206 Content-Range: bytes 0-0/<total>。
        let (total, ctype) = match tokio::time::timeout(
            Duration::from_secs(8),
            client
                .get(&upstream_url)
                .header("Range", "bytes=0-0")
                .send(),
        )
        .await
        {
            Ok(Ok(resp)) => {
                let total = resp
                    .headers()
                    .get("content-range")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.rsplit('/').next())
                    .and_then(|s| s.trim().parse::<u64>().ok())
                    .unwrap_or(0);
                let ct = resp
                    .headers()
                    .get("content-type")
                    .and_then(|v| v.to_str().ok())
                    .filter(|s| !s.is_empty())
                    .unwrap_or("video/mp4")
                    .to_string();
                (total, ct)
            }
            Ok(Err(e)) => {
                logw(&format!("探测文件大小失败: {e}"));
                (0, "video/mp4".to_string())
            }
            Err(_) => {
                logw("探测文件大小超时");
                (0, "video/mp4".to_string())
            }
        };
        if total <= CHUNK_SIZE {
            return None; // 太小或未知,没必要代理
        }

        let read_ahead_chunks = (threads as u64 * 2).max(read_ahead_bytes / CHUNK_SIZE);
        let (gen_tx, _) = watch::channel(0u64);
        Some(Arc::new(Session {
            upstream: Mutex::new(UpstreamState {
                url: upstream_url,
                resign_disabled: false,
                resign_in_flight: false,
            }),
            total_size: total,
            total_chunks: (total + CHUNK_SIZE - 1) / CHUNK_SIZE,
            content_type: ctype,
            read_ahead_chunks,
            state: Mutex::new(ChunkState {
                ready: HashMap::new(),
                pending: HashSet::new(),
                failed: HashSet::new(),
                serve_chunk: 0,
                fetch_cursor: 0,
            }),
            data_notify: Notify::new(),
            window_notify: Notify::new(),
            gen_tx,
            closed: AtomicBool::new(false),
            client,
            on_invalid,
        }))
    }

    // 把供给/取数游标重定位到字节 byte_start(首次连接 / seek)。作废旧 gen 令在途请求立刻 abort。
    /* gen 自增 = 作废在途拉取。
       ★ 绝不能写成 `gen_tx.send(gen_tx.borrow().wrapping_add(1))`:
         borrow() 返回的 Ref 持着 watch 内部 RwLock 的**读锁**,而它是临时量,
         **活到整条语句结束** —— send() 在读锁未释放时去拿写锁 → 同线程自我死锁,
         整个代理当场卡死(响应头已发出、body 一个字节都不来 = 播放器黑屏+永远缓冲)。
         send_modify 只取一次写锁,没有读 guard 存活期,故安全。 */
    fn bump_gen(&self) {
        self.gen_tx.send_modify(|g| *g = g.wrapping_add(1));
    }

    async fn reset(&self, byte_start: u64) {
        self.bump_gen();
        let chunk = byte_start / CHUNK_SIZE;
        {
            let mut st = self.state.lock().await;
            st.serve_chunk = chunk;
            st.fetch_cursor = chunk;
            st.ready.clear();
            st.pending.clear();
            st.failed.clear();
        }
        self.data_notify.notify_waiters();
        self.window_notify.notify_waiters();
    }

    // 供给推进:腾出窗口、清除已消费分段。
    async fn advance_serve(&self, next: u64) {
        {
            let mut st = self.state.lock().await;
            if next <= st.serve_chunk {
                return;
            }
            for c in st.serve_chunk..next {
                st.ready.remove(&c);
                st.failed.remove(&c);
            }
            st.serve_chunk = next;
        }
        self.window_notify.notify_waiters();
    }

    // worker:在窗口内顺序认领分段并拉取,写入就绪表。
    async fn worker(self: Arc<Self>) {
        let mut gen_rx = self.gen_tx.subscribe();
        while !self.closed.load(Ordering::SeqCst) {
            let gen = *gen_rx.borrow_and_update();

            // 认领:窗口未满且未到文件末尾才取下一段。
            let claim = {
                let mut st = self.state.lock().await;
                if st.fetch_cursor >= self.total_chunks
                    || st.fetch_cursor > st.serve_chunk + self.read_ahead_chunks - 1
                {
                    None
                } else {
                    let c = st.fetch_cursor;
                    st.fetch_cursor += 1;
                    st.pending.insert(c);
                    Some(c)
                }
            };
            let c = match claim {
                Some(c) => c,
                None => {
                    let _ = tokio::time::timeout(
                        Duration::from_millis(250),
                        self.window_notify.notified(),
                    )
                    .await;
                    continue;
                }
            };

            // 拉取,期间 gen 变化(seek/dispose)立刻 abort。
            let fetched = tokio::select! {
                r = self.fetch_chunk(c) => r,
                _ = gen_rx.changed() => None,
            };

            let voided = self.closed.load(Ordering::SeqCst) || *gen_rx.borrow() != gen;
            {
                let mut st = self.state.lock().await;
                st.pending.remove(&c);
                if !voided {
                    match &fetched {
                        Some(d) => {
                            st.ready.insert(c, Arc::new(d.clone()));
                        }
                        None => {
                            st.failed.insert(c);
                        }
                    }
                }
            }
            self.data_notify.notify_waiters();
        }
    }

    // 拉一段(带重试 + 上游失效重签)。返回 None 表示永久失败。
    async fn fetch_chunk(&self, c: u64) -> Option<Vec<u8>> {
        let start = c * CHUNK_SIZE;
        let end = (start + CHUNK_SIZE).min(self.total_size) - 1;
        for attempt in 0..3 {
            let url = self.upstream.lock().await.url.clone();
            let resp = self
                .client
                .get(&url)
                .header("Range", format!("bytes={start}-{end}"))
                .send()
                .await;
            match resp {
                Ok(r) if r.status().is_success() || r.status().as_u16() == 206 => {
                    match r.bytes().await {
                        Ok(b) if !b.is_empty() => return Some(b.to_vec()),
                        _ => {} // 空体,当作可重试
                    }
                }
                Ok(r) => {
                    // 4xx/5xx = 上游拒绝该 URL(短效签名链到期常见) → 先重签换地址,下次 attempt 用新 URL。
                    let _ = r.status();
                    self.refresh_upstream().await;
                }
                Err(_) => {} // 纯网络抖动,重试同一 URL
            }
            if attempt < 2 {
                tokio::time::sleep(Duration::from_millis(300 * (attempt + 1))).await;
            }
        }
        logw(&format!("段 {c} 拉取失败"));
        None
    }

    // 上游签名链失效 → 调用注入的重签回调换新地址(并发合并、失败停用)。
    async fn refresh_upstream(&self) {
        let cb = match &self.on_invalid {
            Some(cb) => cb.clone(),
            None => return,
        };
        {
            let mut up = self.upstream.lock().await;
            if up.resign_disabled || up.resign_in_flight {
                return;
            }
            up.resign_in_flight = true;
        }
        let fresh = cb().await;
        let mut up = self.upstream.lock().await;
        up.resign_in_flight = false;
        match fresh {
            Some(f) if !f.is_empty() && f != up.url => {
                up.url = f;
                eprintln!("[Prefetch] 上游链接失效,已重签换新地址继续拉流");
            }
            _ => {
                up.resign_disabled = true; // 拿不到有效新地址,停用避免刷接口
                logw("重签未拿到新地址,停用重签");
            }
        }
    }

    // 等待分段 c 就绪。返回 Some(bytes)=就绪;None=失败/dispose,供给端据此断流。
    async fn await_chunk(&self, c: u64) -> Option<Arc<Vec<u8>>> {
        loop {
            if self.closed.load(Ordering::SeqCst) {
                return None;
            }
            {
                let st = self.state.lock().await;
                if let Some(d) = st.ready.get(&c) {
                    return Some(d.clone());
                }
                if st.failed.contains(&c) {
                    return None;
                }
            }
            // 250ms 兜底重查:防丢失 notify 唤醒,无需逐段 oneshot 记账。
            let _ = tokio::time::timeout(Duration::from_millis(250), self.data_notify.notified())
                .await;
        }
    }

    // 处理播放器的一次 HTTP 请求(GET/HEAD,可带 Range)。mpv 是唯一受控客户端,手写最小 HTTP/1.1。
    async fn handle(self: &Arc<Self>, mut stream: TcpStream) -> std::io::Result<()> {
        let (method, range) = read_request(&mut stream).await?;

        let (start, end) = match range {
            Some((s, e)) => {
                let s = s.min(self.total_size - 1);
                let e = e.unwrap_or(self.total_size - 1).clamp(s, self.total_size - 1);
                (s, e)
            }
            None => (0, self.total_size - 1),
        };

        if range.is_some() && start >= self.total_size {
            stream
                .write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\n\r\n")
                .await?;
            return Ok(());
        }

        let len = end - start + 1;
        let mut head = String::new();
        if range.is_some() {
            head.push_str("HTTP/1.1 206 Partial Content\r\n");
            head.push_str(&format!(
                "Content-Range: bytes {start}-{end}/{}\r\n",
                self.total_size
            ));
        } else {
            head.push_str("HTTP/1.1 200 OK\r\n");
        }
        head.push_str("Accept-Ranges: bytes\r\n");
        head.push_str(&format!("Content-Type: {}\r\n", self.content_type));
        head.push_str(&format!("Content-Length: {len}\r\n\r\n"));
        stream.write_all(head.as_bytes()).await?;

        if method == "HEAD" {
            return Ok(());
        }

        // 重定位预取游标到本次请求起点(首次连接 / seek)。
        self.reset(start).await;

        let mut pos = start;
        while pos <= end && !self.closed.load(Ordering::SeqCst) {
            let c = pos / CHUNK_SIZE;
            let bytes = match self.await_chunk(c).await {
                Some(b) => b,
                None => break, // 作废/失败 -> 断流,播放器回退 fallback
            };
            let within = (pos - c * CHUNK_SIZE) as usize;
            if within >= bytes.len() {
                break;
            }
            let avail = bytes.len() - within;
            let need = (end - pos + 1) as usize;
            let n = avail.min(need);
            // write_all 在 mpv 读慢时自然阻塞 → 端到端背压,预取停在窗口内。
            stream.write_all(&bytes[within..within + n]).await?;
            pos += n as u64;
            if within + n >= bytes.len() {
                self.advance_serve(c + 1).await;
            }
        }
        Ok(())
    }
}

/// 读 HTTP 请求头至 \r\n\r\n,返回 (method, range)。mpv 客户端行为可控,只解析所需。
async fn read_request(stream: &mut TcpStream) -> std::io::Result<(String, Option<(u64, Option<u64>)>)> {
    let mut buf = Vec::with_capacity(512);
    let mut byte = [0u8; 1];
    // 逐字节读到头尾(请求头很小),避免误吞后续连接数据。
    loop {
        let n = stream.read(&mut byte).await?;
        if n == 0 {
            break;
        }
        buf.push(byte[0]);
        if buf.len() >= 4 && &buf[buf.len() - 4..] == b"\r\n\r\n" {
            break;
        }
        if buf.len() > 16 * 1024 {
            break; // 防御:头过大直接截断
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.split("\r\n");
    let method = lines
        .next()
        .and_then(|l| l.split(' ').next())
        .unwrap_or("GET")
        .to_string();
    let mut range = None;
    for line in lines {
        if let Some(v) = line
            .split_once(':')
            .filter(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
            .map(|(_, v)| v.trim())
        {
            range = parse_range(v);
        }
    }
    Ok((method, range))
}

/// 解析 `bytes=start-end` / `bytes=start-` / `bytes=-suffix`。这里 total 未知,-suffix 交给调用侧。
/// 返回 (start, end?);后缀范围 bytes=-N 用 u64::MAX 占位 start 由 handle 结合 total 处理不了,
/// 故此处直接对后缀返回 None 让其走全量(mpv 基本不发后缀范围)。
fn parse_range(header: &str) -> Option<(u64, Option<u64>)> {
    let spec = header.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (s, e) = spec.split_once('-')?;
    let (s, e) = (s.trim(), e.trim());
    if s.is_empty() {
        return None; // 后缀范围 bytes=-N:mpv 不用,交给全量
    }
    let start = s.parse::<u64>().ok()?;
    let end = if e.is_empty() {
        None
    } else {
        Some(e.parse::<u64>().ok()?)
    };
    Some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_range_forms() {
        assert_eq!(parse_range("bytes=0-1023"), Some((0, Some(1023))));
        assert_eq!(parse_range("bytes=4194304-"), Some((4194304, None)));
        assert_eq!(parse_range("bytes=-500"), None); // 后缀范围走全量
        assert_eq!(parse_range("junk"), None);
        // 多区间取第一段
        assert_eq!(parse_range("bytes=0-99,200-299"), Some((0, Some(99))));
    }

    /* 端到端:代理吐的字节必须与上游逐字节相同 —— 差一个字节 mpv 就是黑屏。
       需要真网络 + 一条真实直传流,故 #[ignore],手动:
         cargo test -p linplayer-core prefetch_serves -- --ignored --nocapture
       URL 从 LP_TEST_STREAM 环境变量取(别把签名链写进仓库)。 */
    #[tokio::test]
    #[ignore]
    async fn prefetch_serves_bytes_identical_to_upstream() {
        let url = match std::env::var("LP_TEST_STREAM") {
            Ok(u) if !u.is_empty() => u,
            _ => {
                eprintln!("跳过:未设置 LP_TEST_STREAM");
                return;
            }
        };

        let h = start(url.clone(), 3, 1024 * 1024 * 1024, None)
            .await
            .expect("代理该起得来(总长 > 4MB 的真实流)");
        eprintln!("代理地址: {}", h.url);

        let cli = crate::http::client();
        // 三处取样:头部(mpv 先读头)、跨 chunk 边界、深处 seek。
        for (name, s, e) in [
            ("头部", 0u64, 65_535u64),
            ("跨4MB边界", CHUNK_SIZE - 1024, CHUNK_SIZE + 1023),
            ("深处seek", 300 * 1024 * 1024, 300 * 1024 * 1024 + 65_535),
        ] {
            let rg = format!("bytes={s}-{e}");
            let up = cli.get(&url).header("Range", &rg).send().await.unwrap();
            let up_b = up.bytes().await.unwrap();
            let lo = cli.get(&h.url).header("Range", &rg).send().await.unwrap();
            let lo_status = lo.status();
            let lo_b = lo.bytes().await.unwrap();

            eprintln!("{name}: 上游 {} 字节 / 代理 {} 字节 (状态 {lo_status})", up_b.len(), lo_b.len());
            assert_eq!(lo_status.as_u16(), 206, "{name}: 代理该回 206");
            assert_eq!(lo_b.len(), up_b.len(), "{name}: 长度不一致");
            assert_eq!(lo_b, up_b, "{name}: 字节不一致 —— mpv 会黑屏");
        }
    }
}
