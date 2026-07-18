// 多线程加载(本地缓存预取代理)—— 迁自 Dart lib/core/network/prefetch_proxy/prefetch_proxy.dart。
//
// 起播时在 127.0.0.1:<随机端口> 起本地 HTTP 服务当播放源交给 mpv。代理用 2~4 个并发
// Range 连接对真实播放流"超前"拉取,在内存里维护有界读前缓冲,再"顺序"喂给播放器:
//   - 多连接聚合带宽 → 弱网也能喂满,少卡顿;
//   - 播放器从 localhost 读 → 抖动被缓冲吸收;
//   - 代理对上游网络错误自带重试,mpv 只面对始终在线的 localhost,弱网瞬断不冒泡。
//
// ## 窗口是「每连接」的,不是全局的(2026-07-17 修:这就是「开了放不了」的根因)
// 旧版把取数窗口(serve_chunk/fetch_cursor/ready)放在 Session 上全局**共用**,每条进来的
// HTTP 请求都 reset() 把游标拽到自己的起点并 ready.clear()。mpv 探测 MKV(带大字体附件、
// 索引在末尾的片子)会在旧连接没关时就新开一条 —— 后来者一 reset,前一条正在 await 的分段
// 就再也没人去拉了:响应头已发出、body 一个字节不来 = 有流量、黑屏无声、永远缓冲。
// 现在每条连接持有自己的 Stream(独立窗口 + 独立 worker),连接之间互不干扰;
// 每条连接只**向前顺序**取数(观影场景本就是顺序的),跳转 = mpv 开新连接,而不是把
// 别人下好的缓存冲掉。共享的只有探测结果与上游地址(Origin)。
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
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;

const CHUNK_SIZE: u64 = 4 * 1024 * 1024; // 每段 4MB
/// 单连接内存读前缓冲硬上限。
///
/// 曾是 128MB,配上「窗口改成每连接」后就成了 **128MB × 活跃连接数** —— mpv 探测/跳转
/// 期间会短暂并存两条连接,峰值 256MB+ 只为缓存几秒钟的画面,不值。
/// 真正的大缓冲本来就该由 mpv 自己的 demuxer cache 扛,代理这层只需喂满它。
const MAX_READ_AHEAD: u64 = 32 * 1024 * 1024;

/// 单连接读前缓冲字节数 = 用户设的上限,钳进 [每 worker 一段, MAX_READ_AHEAD]。
///
/// ★ 原来写的是 `MAX_READ_AHEAD.min((CHUNK*threads*2).max(cache_limit))` —— `max` 用反了:
/// 用户的缓存上限本该是**天花板**(对齐 Dart 的「不超用户视频缓存上限」),那样写却成了
/// 下限,默认 1GB 直接把窗口顶到硬上限。改成 clamp,语义才和设置项的名字一致。
fn read_ahead_bytes(threads: usize, cache_limit_bytes: u64) -> u64 {
    let floor = CHUNK_SIZE * threads as u64; // 每个 worker 至少能有一段在手
    cache_limit_bytes.clamp(floor.min(MAX_READ_AHEAD), MAX_READ_AHEAD)
}

/// 上游签名链失效时的重签回调:重走 PlaybackInfo 拿新直传流地址;None=不支持重签。
pub type ResignFn =
    Arc<dyn Fn() -> Pin<Box<dyn Future<Output = Option<String>> + Send>> + Send + Sync>;

fn logw(msg: &str) {
    eprintln!("[Prefetch] {msg}");
}

/// 一个运行中的代理句柄;Drop 即停服、放行所有连接的 worker 退出。
pub struct ProxyHandle {
    pub url: String,
    origin: Arc<Origin>,
    _accept: JoinHandle<()>,
}

impl Drop for ProxyHandle {
    fn drop(&mut self) {
        self.origin.closed.store(true, Ordering::SeqCst);
    }
}

/// 启动预取代理并返回本地播放 URL;失败返回 None(调用方回退在线直链)。
///
/// `threads` 限定 2~4(每条播放连接各起这么多 worker);`cache_limit_bytes` 为用户视频
/// 缓存上限(给单连接读前缓冲封顶);`on_invalid` 为上游失效重签回调(可 None)。
pub async fn start(
    upstream_url: String,
    threads: usize,
    cache_limit_bytes: u64,
    on_invalid: Option<ResignFn>,
) -> Option<ProxyHandle> {
    let t = threads.clamp(2, 4);
    let read_ahead = read_ahead_bytes(t, cache_limit_bytes);

    let origin = Origin::probe(upstream_url.clone(), t, read_ahead, on_invalid).await?;

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.ok()?;
    let port = listener.local_addr().ok()?.port();

    let accept = {
        let o = origin.clone();
        tokio::spawn(async move {
            loop {
                if o.closed.load(Ordering::SeqCst) {
                    break;
                }
                match listener.accept().await {
                    Ok((stream, _)) => {
                        let oc = o.clone();
                        tokio::spawn(async move {
                            if let Err(e) = oc.handle(stream).await {
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
        "[Prefetch] 多线程预取代理启动 {url} <- {upstream_url} ({}MB, 每连接 {t} 线程, 读前缓冲 {}MB)",
        origin.total_size / (1024 * 1024),
        read_ahead / (1024 * 1024),
    );
    Some(ProxyHandle {
        url,
        origin,
        _accept: accept,
    })
}

struct UpstreamState {
    url: String,
    resign_disabled: bool,
    resign_in_flight: bool,
}

/// 全代理共享:探测结果 + 上游地址 + HTTP 客户端。**不含取数游标**(那是每连接的)。
struct Origin {
    upstream: Mutex<UpstreamState>,
    total_size: u64,
    content_type: String,
    threads: usize,
    read_ahead_chunks: u64,
    closed: AtomicBool,
    client: reqwest::Client,
    on_invalid: Option<ResignFn>,
}

/// 每连接的顺序取数窗口。连接结束即 done,它的 worker 随之退出、缓冲随 Arc 释放。
struct ChunkState {
    ready: HashMap<u64, Arc<Vec<u8>>>, // 已就绪分段(顺序消费后即清,内存有界)
    failed: HashSet<u64>,              // 永久失败(供给端遇到即断流)
    serve_chunk: u64,                  // 下一个要供给的分段
    fetch_cursor: u64,                 // 下一个要分配给 worker 的分段
}

struct Stream {
    origin: Arc<Origin>,
    last_chunk: u64, // 本次请求 Range 的末段(含),取到这儿就收工
    state: Mutex<ChunkState>,
    data_notify: Notify,   // worker -> serve:某段就绪/失败
    window_notify: Notify, // serve -> worker:窗口推进
    done: AtomicBool,
}

impl Origin {
    async fn probe(
        upstream_url: String,
        threads: usize,
        read_ahead_bytes: u64,
        on_invalid: Option<ResignFn>,
    ) -> Option<Arc<Origin>> {
        // 预取拉上游用 LinPlayerPreload UA(用户 2026-07-19 定):服主要能把「替 mpv
        // 提前拉的旁路请求」和「用户正在看的那一路」在日志里分开。
        let client = crate::http::preload_client();

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

        // 段数只由字节预算换算,**不再** .max(threads*2) —— 那会反过来突破预算
        // (预算 16MB / 4 线程时会算出 8 段 = 32MB)。.max(1) 只是防
        // worker 里 `serve_chunk + read_ahead_chunks - 1` 下溢。
        let read_ahead_chunks = (read_ahead_bytes / CHUNK_SIZE).max(1);
        Some(Arc::new(Origin {
            upstream: Mutex::new(UpstreamState {
                url: upstream_url,
                resign_disabled: false,
                resign_in_flight: false,
            }),
            total_size: total,
            content_type: ctype,
            threads,
            read_ahead_chunks,
            closed: AtomicBool::new(false),
            client,
            on_invalid,
        }))
    }

    /// 拉一段(带重试 + 上游失效重签)。返回 None 表示永久失败。
    ///
    /// ★ **必须校验长度**:分段是按 `pos / CHUNK_SIZE` 定位的,收下一个短包会让供给端
    /// 写完这几字节后 `advance_serve(c+1)` 把它清掉,而 `pos` 仍落在分段 c 内 →
    /// 下一轮又去 `await_chunk(c)`,可 `fetch_cursor` 早过了 c,永远没人重拉 → **永远缓冲**。
    /// 上游/CDN 截断、以及我们自家 CF 反代在 chunked 路径上遇错 break 后仍补上合法结束块
    /// (见 net/cf/proxy.rs 的 stream_body),都会产出这种「格式合法但短」的响应。
    async fn fetch_chunk(&self, c: u64) -> Option<Vec<u8>> {
        let start = c * CHUNK_SIZE;
        let end = (start + CHUNK_SIZE).min(self.total_size) - 1;
        let want = (end - start + 1) as usize;
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
                        // 长度必须**正好**是请求量,短了/长了都不能收(见函数头说明)。
                        Ok(b) if b.len() == want => return Some(b.to_vec()),
                        Ok(b) => logw(&format!(
                            "段 {c} 长度不符(要 {want} 得 {}),重试",
                            b.len()
                        )),
                        Err(_) => {} // 读体失败,可重试
                    }
                }
                Ok(r) => {
                    /* 4xx/5xx = 上游拒绝该 URL(短效签名链到期常见) → 先重签换地址,下次 attempt 用新 URL。
                       ★ 但 5xx **不一定**是链到期:开了 CF 优选时我们的上游就是本机反代,
                         它连不上 CF 时会自己造一个 502(见 net/cf/proxy.rs 的 Bad Gateway 分支)。
                         所以重签拿回同一个地址是常态,不能据此停用重签 —— 见 refresh_upstream。 */
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

    /// 上游签名链失效 → 调用注入的重签回调换新地址(并发合并)。
    ///
    /// **只有回调拿不到地址(None)才停用重签**。原来「重签回来的地址和旧的一样」也停用,
    /// 那是错的:开了 CF 优选时上游是本机反代,它一个 502(CF 那头抖一下)就会走到这里,
    /// 而重签当然还是解析出同一个 127.0.0.1 地址 —— 于是**一次网关抖动就把重签永久关掉**,
    /// 等这部片真的播到签名过期(长片常见)时,已经没人能换地址了 → 断流。
    /// 地址没变 = 这条链还是它,纯属对端/网络抖动,retry 就好,别自废武功。
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
            // 地址没变:链还有效,是对端/网关抖动(CF 反代 502 就长这样)。retry 即可,不停用。
            Some(f) if !f.is_empty() => {}
            // None / 空串 = 回调压根拿不到地址,停用避免刷接口。
            _ => {
                up.resign_disabled = true;
                logw("重签未拿到新地址,停用重签");
            }
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

        // 本连接自己的窗口:从本次请求起点向前顺序取,不碰其它连接。
        let first = start / CHUNK_SIZE;
        let st = Arc::new(Stream {
            origin: self.clone(),
            last_chunk: end / CHUNK_SIZE,
            state: Mutex::new(ChunkState {
                ready: HashMap::new(),
                failed: HashSet::new(),
                serve_chunk: first,
                fetch_cursor: first,
            }),
            data_notify: Notify::new(),
            window_notify: Notify::new(),
            done: AtomicBool::new(false),
        });
        for _ in 0..self.threads {
            let w = st.clone();
            tokio::spawn(async move { w.worker().await });
        }

        let r = st.serve(&mut stream, start, end).await;
        st.done.store(true, Ordering::SeqCst); // 供给结束 -> 本连接 worker 退出、缓冲释放
        st.window_notify.notify_waiters();
        r
    }
}

impl Stream {
    fn over(&self) -> bool {
        self.done.load(Ordering::SeqCst) || self.origin.closed.load(Ordering::SeqCst)
    }

    // worker:在窗口内顺序认领分段并拉取,写入就绪表。
    async fn worker(self: Arc<Self>) {
        while !self.over() {
            // 认领:窗口未满且未到本次请求末段才取下一段。
            let claim = {
                let mut st = self.state.lock().await;
                if st.fetch_cursor > self.last_chunk
                    || st.fetch_cursor > st.serve_chunk + self.origin.read_ahead_chunks - 1
                {
                    None
                } else {
                    let c = st.fetch_cursor;
                    st.fetch_cursor += 1;
                    Some(c)
                }
            };
            let c = match claim {
                Some(c) => c,
                None => {
                    // 窗口满(mpv 读得慢 = 背压)或已取到末段:等推进,250ms 兜底防丢唤醒。
                    let _ = tokio::time::timeout(
                        Duration::from_millis(250),
                        self.window_notify.notified(),
                    )
                    .await;
                    continue;
                }
            };

            let fetched = self.origin.fetch_chunk(c).await;
            {
                let mut st = self.state.lock().await;
                match fetched {
                    Some(d) => {
                        st.ready.insert(c, Arc::new(d));
                    }
                    None => {
                        st.failed.insert(c);
                    }
                }
            }
            self.data_notify.notify_waiters();
        }
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

    // 等待分段 c 就绪。返回 Some(bytes)=就绪;None=失败/停服,供给端据此断流。
    async fn await_chunk(&self, c: u64) -> Option<Arc<Vec<u8>>> {
        loop {
            if self.over() {
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

    // 顺序把 [start,end] 喂给播放器。
    async fn serve(&self, stream: &mut TcpStream, start: u64, end: u64) -> std::io::Result<()> {
        let mut pos = start;
        while pos <= end && !self.over() {
            let c = pos / CHUNK_SIZE;
            let bytes = match self.await_chunk(c).await {
                Some(b) => b,
                None => break, // 失败/停服 -> 断流,播放器回退 fallback
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

    /* 读前缓冲是**每连接**的,所以峰值 = 窗口 × 活跃连接数(mpv 探测/跳转时会并存两条)。
       旧公式 `MAX.min((CHUNK*t*2).max(cache_limit))` 把用户的 1GB 缓存上限当**下限**用,
       窗口直接顶到硬上限 —— 配上每连接窗口就是几百 MB 只为存几秒画面。 */
    #[test]
    fn read_ahead_is_capped_and_respects_user_limit() {
        // 默认 1GB 缓存上限:被硬上限压到 32MB,不是跟着 1GB 走。
        assert_eq!(read_ahead_bytes(3, 1024 * 1024 * 1024), MAX_READ_AHEAD);
        assert!(MAX_READ_AHEAD <= 32 * 1024 * 1024, "每连接窗口别再往上放");
        // 用户调小,就要真的小(它是天花板,不是地板)。
        assert_eq!(read_ahead_bytes(2, 16 * 1024 * 1024), 16 * 1024 * 1024);
        // 但至少给每个 worker 一段,否则 worker 抢不到活。
        assert_eq!(read_ahead_bytes(4, 1024), CHUNK_SIZE * 4);
        // 段数换算不得突破字节预算。
        for t in 2..=4 {
            for limit in [1024u64, 16 << 20, 64 << 20, 1 << 30] {
                let b = read_ahead_bytes(t, limit);
                assert!((b / CHUNK_SIZE).max(1) * CHUNK_SIZE <= MAX_READ_AHEAD, "t={t} limit={limit}");
            }
        }
    }

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

    /* 回归:并发连接互不干扰 —— 这就是旧版「开了黑屏永远缓冲」的根因。
       旧版共用全局窗口 + 每请求 reset(),第二条连接一进来就把第一条正在等的分段
       从取数计划里抹掉,第一条永远等不到 body。这里起一个假上游(本地 TCP,
       按 Range 吐确定性字节),开两条错位的连接**交替**读,旧版必挂在第二次读上。
       反向验证方式:把 Stream 的窗口换回全局共享 + 每请求 reset,此测试会超时红。 */
    #[tokio::test]
    async fn concurrent_connections_do_not_starve_each_other() {
        // 确定性内容:第 i 个字节 = (i % 251)。
        const TOTAL: u64 = 40 * 1024 * 1024;
        let byte_at = |i: u64| (i % 251) as u8;

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let (mut c, _) = match up.accept().await {
                    Ok(v) => v,
                    Err(_) => break,
                };
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let body: Vec<u8> = (s..=e).map(byte_at).collect();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {s}-{e}/{TOTAL}\r\n\
                         Content-Type: video/x-matroska\r\nContent-Length: {}\r\n\r\n",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("假上游给了 Content-Range,代理该起得来");

        // 两条连接错位并存:A 从 0 起,B 从 20MB 起(模拟 mpv 探 MKV 时旧连接没关就新开)。
        let mut a = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let mut b = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        a.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-\r\n\r\n").await.unwrap();
        b.write_all(format!("GET /play HTTP/1.1\r\nRange: bytes={}-\r\n\r\n", 20 * 1024 * 1024).as_bytes())
            .await
            .unwrap();

        // 交替读:每条都必须能持续拿到**自己**位置的正确字节。
        async fn skip_head(s: &mut TcpStream) {
            let mut one = [0u8; 1];
            let mut w = Vec::new();
            loop {
                s.read_exact(&mut one).await.unwrap();
                w.push(one[0]);
                if w.len() >= 4 && &w[w.len() - 4..] == b"\r\n\r\n" {
                    return;
                }
            }
        }
        tokio::time::timeout(Duration::from_secs(10), async {
            skip_head(&mut a).await;
            skip_head(&mut b).await;
            let (mut pa, mut pb) = (0u64, 20 * 1024 * 1024u64);
            let mut buf = vec![0u8; 64 * 1024];
            for _ in 0..24 {
                a.read_exact(&mut buf).await.unwrap();
                for (k, v) in buf.iter().enumerate() {
                    assert_eq!(*v, byte_at(pa + k as u64), "A 连接字节错位 @{}", pa + k as u64);
                }
                pa += buf.len() as u64;

                b.read_exact(&mut buf).await.unwrap();
                for (k, v) in buf.iter().enumerate() {
                    assert_eq!(*v, byte_at(pb + k as u64), "B 连接字节错位 @{}", pb + k as u64);
                }
                pb += buf.len() as u64;
            }
        })
        .await
        .expect("并发连接互相饿死 = 旧版的黑屏/永远缓冲");
    }

    /* 重签策略：只有「回调拿不到地址」才能停用重签。
       开了 CF 优选时上游是本机反代，它一个 502（CF 那头抖一下）就会触发重签，
       而重签当然还是解析出同一个 127.0.0.1 地址。旧逻辑把这当成失败并永久停用重签，
       等真的签名过期时就没人能换地址了 → 断流。
       反向验证：把 `Some(f) if !f.is_empty() => {}` 这条删掉（回到旧的 `_ =>`），
       same_url_does_not_disable_resign 立刻红。 */
    /* 顺序加载(观影软件的硬要求):并发只用来把**窗口内**的段提前拉回来,
       取数本身必须是向前顺序的 —— 不跳着下、不重复下。
       本测试跑完整一遍读取,断言上游收到的分段请求**恰好**是 0..=末段、每段一次:
         - 有重复 → 白费带宽(用户流量/服务器压力);
         - 有缺口/乱序覆盖 → 就不是顺序加载了。
       同时断言任一时刻的取数超前量不超过读前窗口(靠 serve 消费推进,而非无限狂拉)。 */
    #[tokio::test]
    async fn fetches_sequentially_without_duplicates() {
        use std::collections::BTreeSet;
        use std::sync::Mutex as StdMutex;

        const TOTAL: u64 = 40 * 1024 * 1024; // 10 段
        let seen: Arc<StdMutex<Vec<u64>>> = Arc::new(StdMutex::new(Vec::new()));

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        let seen_srv = seen.clone();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                let seen_c = seen_srv.clone();
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    // 只记真正的取数请求,探大小的 bytes=0-0 不算。
                    if e > s {
                        seen_c.lock().unwrap().push(s / CHUNK_SIZE);
                    }
                    let body = vec![0u8; (e - s + 1) as usize];
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 3, 16 * 1024 * 1024, None)
            .await
            .expect("代理该起得来");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let nl = String::from_utf8(vec![13, 10]).unwrap();
        cli.write_all(format!("GET /play HTTP/1.1{nl}Range: bytes=0-{nl}{nl}").as_bytes())
            .await
            .unwrap();

        let got = tokio::time::timeout(Duration::from_secs(30), async {
            let mut total = 0usize;
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match cli.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => total += n,
                    Err(_) => break,
                }
            }
            total
        })
        .await
        .expect("整片读完不该超时");

        let v = seen.lock().unwrap().clone();
        let uniq: BTreeSet<u64> = v.iter().copied().collect();
        let last = (TOTAL - 1) / CHUNK_SIZE;

        assert_eq!(v.len(), uniq.len(), "有分段被重复下载:{v:?}");
        assert_eq!(
            uniq,
            (0..=last).collect::<BTreeSet<u64>>(),
            "取数不是覆盖 0..={last} 的顺序全集:{uniq:?}"
        );
        // 认领顺序必须单调向前(fetch_cursor 只增)。并发下到达顺序可能微乱,
        // 故按「任意时刻的超前量」判定:任一请求都不该超出窗口太多。
        let window = read_ahead_bytes(3, 16 * 1024 * 1024) / CHUNK_SIZE;
        for (i, c) in v.iter().enumerate() {
            assert!(
                *c <= i as u64 + window,
                "第 {i} 个请求跳到了段 {c},超出窗口 {window} = 不是顺序预取"
            );
        }
        // got 是裸 socket 收到的字节,含响应头(约 150 字节),故比对时留出头部余量。
        let body = got as u64 - TOTAL;
        assert!(
            got as u64 > TOTAL && body < 1024,
            "应当把整片喂完(含响应头),实收 {got},TOTAL={TOTAL}"
        );
    }

    /* 上游返回【短于请求量】的分段时，绝不能挂死。
       旧逻辑：fetch_chunk 只要 body 非空就收下 → serve 写完这 L 字节后 advance_serve(c+1)
       把它从 ready 删掉，可 pos 仍在分段 c 内 → 下一轮又去 await_chunk(c)，
       而 fetch_cursor 早过了 c，永远没人重拉 → **永远缓冲**（和用户报的症状一模一样）。
       修后：长度对不上 = 可重试，重试用尽就标失败 → 断流，播放器回退直连。
       反向验证：把 fetch_chunk 里的长度校验去掉，本测试立刻挂死超时红。 */
    #[tokio::test]
    async fn short_upstream_chunk_breaks_stream_instead_of_hanging() {
        const TOTAL: u64 = 40 * 1024 * 1024;
        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    // 探大小的 bytes=0-0 必须诚实，否则代理压根起不来。
                    let full = e - s + 1;
                    let n = if full <= 1 { full } else { full / 4 }; // 其余一律只给 1/4
                    let body = vec![7u8; n as usize];
                    // CRLF 用字节构造:本文件里直接写转义序列会被工具链吃掉反斜杠。
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("探测阶段拿得到 Content-Range，代理该起得来");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let nl = String::from_utf8(vec![13, 10]).unwrap();
        cli.write_all(format!("GET /play HTTP/1.1{nl}Range: bytes=0-{nl}{nl}").as_bytes())
            .await
            .unwrap();

        // 不论成功与否，必须在有限时间内**结束**（EOF），不能无限挂住。
        let r = tokio::time::timeout(Duration::from_secs(20), async {
            let mut sink = Vec::new();
            let mut buf = vec![0u8; 32 * 1024];
            loop {
                match cli.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => sink.extend_from_slice(&buf[..n]),
                    Err(_) => break,
                }
            }
            sink.len()
        })
        .await;
        assert!(r.is_ok(), "上游给短包时挂死了 = 用户报的「永远缓冲」");
    }

    fn origin_with(cb: Option<ResignFn>) -> Origin {
        Origin {
            upstream: Mutex::new(UpstreamState {
                url: "http://127.0.0.1:1/s".into(),
                resign_disabled: false,
                resign_in_flight: false,
            }),
            total_size: 100 * CHUNK_SIZE,
            content_type: "video/mp4".into(),
            threads: 2,
            read_ahead_chunks: 4,
            closed: AtomicBool::new(false),
            client: crate::http::preload_client(),
            on_invalid: cb,
        }
    }

    fn resign_returning(v: Option<&'static str>) -> ResignFn {
        Arc::new(move || Box::pin(async move { v.map(|s| s.to_string()) }))
    }

    #[tokio::test]
    async fn same_url_does_not_disable_resign() {
        let o = origin_with(Some(resign_returning(Some("http://127.0.0.1:1/s"))));
        o.refresh_upstream().await;
        let up = o.upstream.lock().await;
        assert!(!up.resign_disabled, "same url = gateway hiccup (CF 502); must NOT disable resign");
        assert_eq!(up.url, "http://127.0.0.1:1/s");
    }

    #[tokio::test]
    async fn new_url_is_adopted_and_none_disables() {
        let o = origin_with(Some(resign_returning(Some("http://127.0.0.1:2/fresh"))));
        o.refresh_upstream().await;
        assert_eq!(o.upstream.lock().await.url, "http://127.0.0.1:2/fresh");

        let o2 = origin_with(Some(resign_returning(None)));
        o2.refresh_upstream().await;
        assert!(o2.upstream.lock().await.resign_disabled, "no url from callback = disable resign");
    }

    fn url_port(u: &str) -> u16 {
        u.rsplit(':')
            .next()
            .and_then(|s| s.split('/').next())
            .unwrap()
            .parse()
            .unwrap()
    }
}
