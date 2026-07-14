// CF 优选测速引擎 —— 迁自 Dart cf_speed_tester.dart。流程对标 XIU2/CloudflareSpeedTest:
// 1) 随机抽样 CF IP;2) TCP 握手延迟 + 丢包筛选排序;3) HTTP 校验(cdn-cgi/trace);
// 4) 对延迟最优的若干做 HTTPS 下载测速(reqwest .resolve 钉 IP + SNI=测速域名)。
//
// 相比 Dart 手写 SecureSocket,这里校验/下载走 reqwest(自带 TLS/SNI/keep-alive),
// 延迟握手走 tokio TcpStream,代码大幅收敛。

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use tokio::net::TcpStream;
use tokio::task::JoinSet;

use super::ranges::{sample_v4, sample_v6, Rng};

/// 默认测速文件:社区托管在 CF R2 上的 100MB 文件,国内较稳。
pub const DEFAULT_CF_TEST_URL: &str = "https://speedtest.291277.xyz/%E6%96%87%E4%BB%B6-100MB.bin";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum CfIpMode {
    Auto,
    V4,
    V6,
    Dual,
}

impl CfIpMode {
    pub fn from_name(name: &str) -> Self {
        match name {
            "v4" => CfIpMode::V4,
            "v6" => CfIpMode::V6,
            "dual" => CfIpMode::Dual,
            _ => CfIpMode::Auto,
        }
    }
}

#[derive(Clone, serde::Serialize)]
pub struct CfTestResult {
    pub ip: String,
    pub latency_ms: u64,
    pub loss_rate: f64,
    pub download_kbps: Option<f64>,
}

#[derive(Clone)]
pub struct CfSpeedTestOptions {
    pub sample_count: usize,
    pub latency_concurrency: usize,
    pub ping_samples: usize,
    pub ping_timeout: Duration,
    pub max_loss_rate: f64,
    pub max_latency_ms: u64,
    pub latency_tier_ms: u64,
    pub latency_keep_top: usize,
    pub download_wanted: usize,
    pub download_duration: Duration,
    pub min_download_kbps: f64,
    pub test_url: String,
    pub ip_mode: CfIpMode,
    /// HTTP 校验域名(通常是 Emby 域名);空=跳过校验。
    pub validate_host: String,
}

impl Default for CfSpeedTestOptions {
    fn default() -> Self {
        Self {
            sample_count: 256,
            latency_concurrency: 64,
            ping_samples: 4,
            ping_timeout: Duration::from_millis(1000),
            max_loss_rate: 0.5,
            max_latency_ms: 500,
            latency_tier_ms: 50,
            latency_keep_top: 24,
            download_wanted: 4,
            download_duration: Duration::from_secs(6),
            min_download_kbps: 0.0,
            test_url: DEFAULT_CF_TEST_URL.to_string(),
            ip_mode: CfIpMode::Auto,
            validate_host: String::new(),
        }
    }
}

/// 排名:延迟低优先(每 tier_ms 一档),同档内比下载速度(高者优先)。
fn rank_compare(a: &CfTestResult, b: &CfTestResult, tier_ms: u64) -> std::cmp::Ordering {
    let tier = tier_ms.max(1);
    let (ta, tb) = (a.latency_ms / tier, b.latency_ms / tier);
    if ta != tb {
        return ta.cmp(&tb);
    }
    b.download_kbps
        .unwrap_or(0.0)
        .partial_cmp(&a.download_kbps.unwrap_or(0.0))
        .unwrap_or(std::cmp::Ordering::Equal)
}

/// 按 ip_mode 抽样候选 IP。
async fn gather_ips(o: &CfSpeedTestOptions) -> Vec<String> {
    let mut rng = Rng::new();
    let mode = if o.ip_mode == CfIpMode::Auto {
        if has_ipv6().await {
            CfIpMode::Dual
        } else {
            CfIpMode::V4
        }
    } else {
        o.ip_mode
    };
    match mode {
        CfIpMode::V4 => sample_v4(o.sample_count, &mut rng),
        CfIpMode::V6 => sample_v6(o.sample_count, &mut rng),
        CfIpMode::Dual | CfIpMode::Auto => {
            let half = o.sample_count.div_ceil(2);
            let mut v = sample_v4(half, &mut rng);
            v.extend(sample_v6(half, &mut rng));
            v
        }
    }
}

/// 探测本机是否有可用 IPv6(连 CF 公共 DNS v6)。
async fn has_ipv6() -> bool {
    for ip in ["2606:4700:4700::1111", "2606:4700:4700::1001"] {
        let addr: SocketAddr = format!("[{ip}]:443").parse().unwrap();
        if tokio::time::timeout(Duration::from_millis(800), TcpStream::connect(addr))
            .await
            .map(|r| r.is_ok())
            .unwrap_or(false)
        {
            return true;
        }
    }
    false
}

/// TCP 握手延迟 + 丢包。多次握手取均值;任一成功即记录。
async fn measure_latency(ip: String, o: CfSpeedTestOptions) -> Option<CfTestResult> {
    let addr: SocketAddr = if ip.contains(':') {
        format!("[{ip}]:443").parse().ok()?
    } else {
        format!("{ip}:443").parse().ok()?
    };
    let mut success = 0u64;
    let mut total_ms = 0u64;
    for _ in 0..o.ping_samples {
        let t0 = Instant::now();
        match tokio::time::timeout(o.ping_timeout, TcpStream::connect(addr)).await {
            Ok(Ok(_s)) => {
                success += 1;
                total_ms += t0.elapsed().as_millis() as u64;
            }
            _ => {}
        }
    }
    if success == 0 {
        return None;
    }
    Some(CfTestResult {
        ip,
        latency_ms: (total_ms as f64 / success as f64).round() as u64,
        loss_rate: (o.ping_samples as f64 - success as f64) / o.ping_samples as f64,
        download_kbps: None,
    })
}

/// reqwest 客户端:把 `host` 的 DNS 钉到 `ip:443`,TLS SNI/Host 仍是 host。
fn pinned_client(host: &str, ip: &str) -> Option<reqwest::Client> {
    let addr: SocketAddr = if ip.contains(':') {
        format!("[{ip}]:443").parse().ok()?
    } else {
        format!("{ip}:443").parse().ok()?
    };
    reqwest::Client::builder()
        .resolve(host, addr)
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(10))
        .build()
        .ok()
}

/// 用 https://<host>/cdn-cgi/trace 校验候选 IP 能否为该域名提供 HTTP 服务。
/// 2xx/3xx = 边缘确实在为该域名服务(trace 由 CF 边缘直接应答,不回源)。
async fn http_validate(ip: &str, host: &str) -> bool {
    let Some(client) = pinned_client(host, ip) else {
        return false;
    };
    let url = format!("https://{host}/cdn-cgi/trace");
    match tokio::time::timeout(Duration::from_secs(4), client.get(&url).send()).await {
        Ok(Ok(resp)) => {
            let c = resp.status().as_u16();
            (200..400).contains(&c)
        }
        _ => false,
    }
}

/// HTTPS 下载测速:钉候选 IP,SNI=测速域名,GET 测速文件,在 download_duration 窗内统计吞吐。
/// 要求 200 且至少下到 64KB;返回 KB/s,失败 None。(redirect 关闭,默认测速文件直返 200)
async fn measure_download(ip: &str, test_url: &str, o: &CfSpeedTestOptions) -> Option<f64> {
    let host = reqwest::Url::parse(test_url).ok()?.host_str()?.to_string();
    let client = pinned_client(&host, ip)?;
    let resp = tokio::time::timeout(Duration::from_secs(4), client.get(test_url).send())
        .await
        .ok()?
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let mut resp = resp;
    let mut bytes = 0u64;
    let t0 = Instant::now();
    loop {
        match tokio::time::timeout(Duration::from_secs(4), resp.chunk()).await {
            Ok(Ok(Some(chunk))) => {
                bytes += chunk.len() as u64;
                if t0.elapsed() >= o.download_duration {
                    break;
                }
            }
            Ok(Ok(None)) => break, // 流结束
            _ => break,            // 错误/首字节超时
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    if secs <= 0.05 || bytes < 65536 {
        return None;
    }
    Some((bytes as f64 / 1024.0) / secs)
}

/// 分波并发映射(简单有界并发:每波跑 concurrency 个,等齐再下一波)。
async fn bounded_latency(ips: Vec<String>, o: &CfSpeedTestOptions) -> Vec<CfTestResult> {
    let mut out = Vec::new();
    for wave in ips.chunks(o.latency_concurrency.max(1)) {
        let mut set = JoinSet::new();
        for ip in wave {
            set.spawn(measure_latency(ip.clone(), o.clone()));
        }
        while let Some(r) = set.join_next().await {
            if let Ok(Some(res)) = r {
                if res.loss_rate <= o.max_loss_rate && res.latency_ms <= o.max_latency_ms {
                    out.push(res);
                }
            }
        }
    }
    out
}

/// 运行测速,返回排好序的结果(最优在前)。空 = 无可用 IP。
pub async fn run(o: CfSpeedTestOptions) -> Vec<CfTestResult> {
    let ips = gather_ips(&o).await;
    if ips.is_empty() {
        return vec![];
    }

    // 阶段一:握手延迟 + 丢包筛选。
    let mut latency = bounded_latency(ips, &o).await;
    if latency.is_empty() {
        return vec![];
    }
    latency.sort_by(|a, b| {
        a.latency_ms
            .cmp(&b.latency_ms)
            .then(a.loss_rate.partial_cmp(&b.loss_rate).unwrap_or(std::cmp::Ordering::Equal))
    });
    let mut candidates: Vec<CfTestResult> =
        latency.into_iter().take(o.latency_keep_top).collect();

    // 阶段二:HTTP 校验(并发 16)。剔除「TCP 通但 HTTP 死」的边缘。
    let host = o.validate_host.trim().to_string();
    if !host.is_empty() {
        let mut validated = Vec::new();
        for wave in candidates.chunks(16) {
            let mut set = JoinSet::new();
            for c in wave {
                let (ip, h, res) = (c.ip.clone(), host.clone(), c.clone());
                set.spawn(async move {
                    if http_validate(&ip, &h).await {
                        Some(res)
                    } else {
                        None
                    }
                });
            }
            while let Some(r) = set.join_next().await {
                if let Ok(Some(res)) = r {
                    validated.push(res);
                }
            }
        }
        if validated.is_empty() {
            return vec![]; // 没有能为该域名服务的 IP(该域名走 CF 吗?)
        }
        validated.sort_by(|a, b| a.latency_ms.cmp(&b.latency_ms));
        candidates = validated;
    }

    // 阶段三:下载测速(顺序,命中 download_wanted 个即停)。
    let mut downloaded: Vec<CfTestResult> = Vec::new();
    for c in &candidates {
        if downloaded.len() >= o.download_wanted {
            break;
        }
        if let Some(kbps) = measure_download(&c.ip, &o.test_url, &o).await {
            if kbps > 0.0 {
                let mut r = c.clone();
                r.download_kbps = Some(kbps);
                downloaded.push(r);
                downloaded.sort_by(|a, b| rank_compare(a, b, o.latency_tier_ms));
            }
        }
    }

    if !downloaded.is_empty() {
        // 满足阈值优先;都不满足按速度取最快。
        if o.min_download_kbps > 0.0 {
            let qualified: Vec<CfTestResult> = downloaded
                .iter()
                .filter(|r| r.download_kbps.unwrap_or(0.0) >= o.min_download_kbps)
                .cloned()
                .collect();
            if !qualified.is_empty() {
                return qualified;
            }
        }
        downloaded
    } else {
        // 下载全失败(测速文件被墙):退回已过 HTTP 校验的 IP(按延迟)。
        candidates
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranking_prefers_low_latency_tier_then_speed() {
        let a = CfTestResult { ip: "a".into(), latency_ms: 60, loss_rate: 0.0, download_kbps: Some(1000.0) };
        let b = CfTestResult { ip: "b".into(), latency_ms: 480, loss_rate: 0.0, download_kbps: Some(9000.0) };
        // 60ms(档 1)优于 480ms(档 9),即使 b 更快。
        assert_eq!(rank_compare(&a, &b, 50), std::cmp::Ordering::Less);
        // 同档比速度:c 更快应排前。
        let c = CfTestResult { ip: "c".into(), latency_ms: 70, loss_rate: 0.0, download_kbps: Some(5000.0) };
        let d = CfTestResult { ip: "d".into(), latency_ms: 60, loss_rate: 0.0, download_kbps: Some(1000.0) };
        assert_eq!(rank_compare(&c, &d, 50), std::cmp::Ordering::Less);
    }
}
