// 统一 HTTP 客户端与应用身份(UA/Device)。
// 对应 Dart 侧 app_identity:所有请求(含图片/播放流)走同一 UA,避免 CDN 因 UA 空白返回空白图/流。

pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const CLIENT_NAME: &str = "LinPlayer";

/* ---------- User-Agent 口径(用户 2026-07-19 定) ----------

   访问 Emby          → `LinPlayer/{版本}`      —— emby_client() / mpv 直连取流
   多线程加载 + 预加载 → `LinPlayerPreload/{版本}` —— preload_client()(预取代理拉上游)
   其它一切           → 默认(不设 UA)          —— client()

   为什么分开:预取代理是**我们替 mpv 提前拉流**的旁路请求,和用户真正在看的那一路
   在服务端日志/风控里必须能区分开。糊成一个 UA,服主看到的就是"一个客户端同时开了
   四五路并发",最容易被当成盗刷限速。 */

/// 访问 Emby 用的 User-Agent。
pub fn user_agent() -> String {
    format!("{CLIENT_NAME}/{APP_VERSION}")
}

/// 多线程加载 / 预加载(预取代理拉上游)用的 User-Agent。
pub fn preload_user_agent() -> String {
    format!("{CLIENT_NAME}Preload/{APP_VERSION}")
}

/// 本机设备名(Emby X-Emby-Authorization 的 Device 字段用)。
pub fn device_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "PC".to_string())
}

// 全局代理运行时:同步工厂 client() 无法读配置,故用静态镜像(对标 Dart ProxyRuntime 单例)。
// 配置变更时由命令桥调 set_proxy 写入,之后新建的 client() 自动带上代理。
static PROXY_URL: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);

/// 设置/清除全局代理 URL(如 socks5://host:port / http://user:pass@host:port)。None=直连。
pub fn set_proxy(url: Option<String>) {
    if let Ok(mut g) = PROXY_URL.write() {
        *g = url;
    }
    // ★ 必须弃用旧客户端:client() 有缓存(见下面 CLIENT),不清的话改完代理要**重启才生效**
    //   —— 用户在设置页切代理、点了保存、没反应,只会以为代理功能坏了。
    //   set_insecure_hosts 一直是这么做的,这里原先漏了。
    //   ★ 三个客户端都要清:漏一个,那条路(比如 Emby 或预取)就还在用旧代理设置。
    CLIENT.write().ok().map(|mut c| *c = None);
    EMBY_CLIENT.write().ok().map(|mut c| *c = None);
    PRELOAD_CLIENT.write().ok().map(|mut c| *c = None);
}

/// 本机回环地址:**永不走用户代理**。
///
/// 前提:本产品的跨境方案是 **CF 优选反代,不挂梯**。代理设置默认 `none`,是给少数
/// 自己开了代理的用户留的口子 —— 所以这段只对那部分人生效,对默认路径是 no-op。
///
/// 我们自己在 127.0.0.1 上起了两层本地服务(CF 优选反代、多线程加载预取代理),
/// 它们的地址会经 `Account::active_line_url()` 进到播放/API 链路里。而 reqwest 的
/// `Proxy::all` 是**字面意义上的 all**:实测(见 tests::loopback_never_goes_through_proxy)
/// 连 `http://127.0.0.1:<port>` 都会被塞给那个代理 —— 代理再去连**它自己那边**的
/// 127.0.0.1,本机的服务根本不在那头:
///   - 代理在远端 → 直接连不上,「开了 CF 优选反而全挂」;
///   - 代理在本机 → 侥幸能通,但每个分段都白绕一圈。
/// 即:用户一旦同时开了代理,反而会把 CF 优选打死。故回环一律直连。
const LOOPBACK_NO_PROXY: &str = "localhost,127.0.0.1,::1";

/// 这个地址是不是本机回环(= 我们自己起的 CF 反代 / 预取代理)。
///
/// `client()` 里已由 no_proxy 兜住,但 **mpv 不是我们的 reqwest** —— 它自己带 http-proxy
/// 选项,同样不能让它把 127.0.0.1 递给用户配的代理。调用方据此决定要不要给 mpv 挂代理。
pub fn is_loopback_url(url: &str) -> bool {
    let h = host_of(url).to_ascii_lowercase();
    let h = h.trim_start_matches('[').trim_end_matches(']'); // IPv6 字面量
    h == "localhost" || h == "::1" || h.starts_with("127.")
}

// ---------------------------------------------------------------------------
// 自签名放行:按 host 白名单,而不是全局关掉证书校验
// ---------------------------------------------------------------------------
//
// 之前这里是 `.danger_accept_invalid_certs(true)` —— 全局。后果不是"少了个功能",而是
// **每台服务器的证书校验都是关的**,Account::allow_insecure_tls 这个字段纯属装饰:
// 你为了连自家 LAN 上那台自签名 Emby,顺带把公网所有 HTTPS 的中间人防护一起关了,
// 且不报任何错。这正是本项目最危险的那类 bug——不崩,只是悄悄少做了。
//
// 修法与 CF 改写点同构:收敛到唯一 choke point。自定义 rustls 校验器在握手时查白名单,
// 命中才跳过链校验;没命中的走标准 WebPKI。88 个 http 调用点一个都不用改,
// 以后新增的调用点也**绕不过去**——这是"加个 client_insecure() 让大家自觉选"做不到的。

static INSECURE_HOSTS: std::sync::RwLock<Option<std::collections::HashSet<String>>> =
    std::sync::RwLock::new(None);

/// 设置允许自签名/无效证书的 host 集合(全量替换)。宿主在配置变更时调。
/// 传 host 不带 scheme/端口/路径,如 `nas.local`。
pub fn set_insecure_hosts(hosts: impl IntoIterator<Item = String>) {
    let set: std::collections::HashSet<String> =
        hosts.into_iter().map(|h| host_of(&h).to_ascii_lowercase()).filter(|h| !h.is_empty()).collect();
    if let Ok(mut g) = INSECURE_HOSTS.write() {
        *g = Some(set);
    }
    CLIENT.write().ok().map(|mut c| *c = None); // 白名单变了 → 弃用旧客户端,下次重建
}

pub fn is_insecure_host(host: &str) -> bool {
    INSECURE_HOSTS
        .read()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.contains(&host.to_ascii_lowercase())))
        .unwrap_or(false)
}

/// 从任意形态(URL / host:port / 裸 host)里取出纯 host。IPv6 字面量保留方括号。
pub fn host_of(input: &str) -> &str {
    let rest = input.split_once("://").map(|(_, r)| r).unwrap_or(input);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let authority = authority.rsplit_once('@').map(|(_, h)| h).unwrap_or(authority);
    match authority.rfind(']') {
        // IPv6:`[::1]:8096` → `[::1]`
        Some(b) => &authority[..=b],
        None => authority.split_once(':').map(|(h, _)| h).unwrap_or(authority),
    }
}

#[derive(Debug)]
struct HostAllowlistVerifier {
    inner: std::sync::Arc<rustls::client::WebPkiServerVerifier>,
}

impl rustls::client::danger::ServerCertVerifier for HostAllowlistVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls_pki_types::CertificateDer<'_>,
        intermediates: &[rustls_pki_types::CertificateDer<'_>],
        server_name: &rustls_pki_types::ServerName<'_>,
        ocsp_response: &[u8],
        now: rustls_pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        // 白名单内:跳过链校验与主机名校验(自签名证书的 CN 通常也对不上)。
        let host = match server_name {
            rustls_pki_types::ServerName::DnsName(d) => d.as_ref().to_string(),
            rustls_pki_types::ServerName::IpAddress(ip) => format!("{ip:?}"),
            _ => String::new(),
        };
        if !host.is_empty() && is_insecure_host(&host) {
            return Ok(rustls::client::danger::ServerCertVerified::assertion());
        }
        self.inner
            .verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
    }

    // 握手签名校验只验"对方确实持有该证书的私钥",不涉信任链 —— 自签名场景同样应该验,
    // 故一律委派,不开后门。
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls_pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls_pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

fn tls_config() -> rustls::ClientConfig {
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let roots = rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let inner = rustls::client::WebPkiServerVerifier::builder_with_provider(
        std::sync::Arc::new(roots),
        provider.clone(),
    )
    .build()
    .expect("build webpki verifier");

    let mut cfg = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("rustls protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(std::sync::Arc::new(HostAllowlistVerifier { inner }))
        .with_no_client_auth();
    // use_preconfigured_tls 会让 reqwest 用我们这份 config,它自己那套 ALPN 设置不再生效 ——
    // 不补这行,h2 协商不上,所有请求悄悄降级成 HTTP/1.1(不报错,只是慢)。
    cfg.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    cfg
}

// 客户端缓存:reqwest::Client 内部是 Arc,clone 极廉价,但 build() 要解析根证书 + 建连接池,
// 每次请求重建等于扔掉 keep-alive。原来的 client() 每调一次 build 一个,这里顺手收敛。
static CLIENT: std::sync::RwLock<Option<reqwest::Client>> = std::sync::RwLock::new(None);
static EMBY_CLIENT: std::sync::RwLock<Option<reqwest::Client>> = std::sync::RwLock::new(None);
static PRELOAD_CLIENT: std::sync::RwLock<Option<reqwest::Client>> = std::sync::RwLock::new(None);

/// 通用 HTTP 客户端(**不设 UA**,走 reqwest 默认;带全局代理、按 host 的自签名白名单)。
/// 弹幕/Bangumi/Trakt/翻译/排行等第三方一律用它。
pub fn client() -> reqwest::Client {
    cached(&CLIENT, None)
}

/// 访问 Emby 的客户端(UA = `LinPlayer/{版本}`)。
pub fn emby_client() -> reqwest::Client {
    cached(&EMBY_CLIENT, Some(user_agent()))
}

/// 多线程加载 / 预加载拉上游的客户端(UA = `LinPlayerPreload/{版本}`)。
pub fn preload_client() -> reqwest::Client {
    cached(&PRELOAD_CLIENT, Some(preload_user_agent()))
}

fn cached(slot: &std::sync::RwLock<Option<reqwest::Client>>, ua: Option<String>) -> reqwest::Client {
    if let Some(c) = slot.read().ok().and_then(|g| g.clone()) {
        return c;
    }
    let mut b = reqwest::Client::builder().use_preconfigured_tls(tls_config());
    if let Some(ua) = ua {
        b = b.user_agent(ua);
    }
    if let Some(url) = PROXY_URL.read().ok().and_then(|g| g.clone()) {
        if let Ok(p) = reqwest::Proxy::all(&url) {
            // 回环永远直连(见 LOOPBACK_NO_PROXY):本机的 CF 反代/预取代理不能再钻用户代理。
            b = b.proxy(p.no_proxy(reqwest::NoProxy::from_string(LOOPBACK_NO_PROXY)));
        }
    }
    let c = b.build().expect("build reqwest client");
    if let Ok(mut g) = slot.write() {
        *g = Some(c.clone());
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_of_strips_scheme_port_path_and_userinfo() {
        assert_eq!(host_of("https://nas.local:8096/emby"), "nas.local");
        assert_eq!(host_of("nas.local:8096"), "nas.local");
        assert_eq!(host_of("nas.local"), "nas.local");
        assert_eq!(host_of("https://u:p@nas.local:8096/x"), "nas.local");
        assert_eq!(host_of("https://[::1]:8096/emby"), "[::1]");
        assert_eq!(host_of("https://[::1]/emby"), "[::1]");
    }

    #[test]
    fn insecure_allowlist_is_per_host_not_global() {
        set_insecure_hosts(["https://nas.local:8096/emby".to_string(), "SELF.example.COM".to_string()]);
        assert!(is_insecure_host("nas.local"), "白名单里的 host 该放行");
        assert!(is_insecure_host("self.example.com"), "host 比对必须大小写不敏感");
        // 这条是重点:放行一台自签名服务器,不能把整个公网的证书校验一起关掉。
        assert!(!is_insecure_host("bank.example.com"), "没登记的 host 必须仍走标准校验");
        set_insecure_hosts(Vec::<String>::new());
        assert!(!is_insecure_host("nas.local"), "清空白名单后该恢复校验");
    }

    /// TLS config 能建起来(provider/根证书/ALPN 都对)。建不起来会 panic,
    /// 那意味着所有 HTTPS 请求全挂 —— 宁可测试里炸,别在用户机器上炸。
    #[test]
    fn tls_config_builds_with_alpn() {
        let cfg = tls_config();
        assert_eq!(cfg.alpn_protocols, vec![b"h2".to_vec(), b"http/1.1".to_vec()]);
    }

    #[test]
    fn client_builds_and_is_cached() {
        let _ = client();
        let _ = client(); // 走缓存分支
    }

    /// 真实握手验证 —— 上面那些单测只证明白名单查表对,**证明不了 TLS 真的在校验**。
    /// use_preconfigured_tls 的 downcast 一旦落空、根证书装错、ring provider 没起来,
    /// 后果是"全网请求挂掉"或更糟的"洞还开着但我以为堵上了"。只有真打一次握手才知道。
    ///
    /// 要网络,故 #[ignore];跑法:
    ///   cargo test -p linplayer-core tls_verification_is_real -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "需要外网(badssl.com)"]
    async fn tls_verification_is_real() {
        // 1) 正常证书的站必须**通** —— 证明根证书/ALPN/provider 都装对了。
        set_insecure_hosts(Vec::<String>::new());
        let r = client().get("https://sha256.badssl.com/").send().await;
        assert!(r.is_ok(), "有效证书的站点应当连通,却失败了: {:?}", r.err());

        // 2) 自签名的站必须**被拒** —— 这条是整个改动的意义所在。
        //    以前全局 accept_invalid_certs=true,这里会 is_ok(),洞就在这。
        let r = client().get("https://self-signed.badssl.com/").send().await;
        assert!(r.is_err(), "自签名证书未被拒绝 —— 证书校验没生效,等于洞还开着");

        // 3) 加进白名单后必须**放行** —— 证明自签名 Emby 用户不会被误伤。
        set_insecure_hosts(["self-signed.badssl.com".to_string()]);
        let r = client().get("https://self-signed.badssl.com/").send().await;
        assert!(r.is_ok(), "白名单内的自签名站点应放行,却失败了: {:?}", r.err());

        // 4) 放行一台,不能顺带放行别台 —— 白名单是按 host 的,不是开关。
        let r = client().get("https://expired.badssl.com/").send().await;
        assert!(r.is_err(), "放行 A 站顺带放行了 B 站 —— 白名单退化成了全局开关");

        set_insecure_hosts(Vec::<String>::new());
    }

    /* 回环不许走代理 —— 用户自己开了代理时,不能把 CF 优选/预取代理一起打死。
       reqwest 的 Proxy::all 真的是 all:不显式 no_proxy,`http://127.0.0.1:<port>` 也会被
       递给那个代理。本测试起一个假代理 + 一个假本地服务(冒充 CF 反代),断言请求落在本地、
       且假代理一次都没被连过。
       反向验证:把 client() 里的 .no_proxy(...) 去掉,此测试立刻红(实测响应体变成 PROXY)。 */
    #[tokio::test]
    async fn loopback_never_goes_through_proxy() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        async fn serve(l: TcpListener, tag: &'static [u8], hit: Option<Arc<AtomicBool>>) {
            while let Ok((mut c, _)) = l.accept().await {
                if let Some(h) = &hit {
                    h.store(true, Ordering::SeqCst);
                }
                let mut b = [0u8; 1024];
                let _ = c.read(&mut b).await;
                let mut resp = b"HTTP/1.1 200 OK
Content-Length: 5

".to_vec();
                resp.extend_from_slice(tag);
                let _ = c.write_all(&resp).await;
            }
        }

        let proxy_hit = Arc::new(AtomicBool::new(false));
        let pl = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let pport = pl.local_addr().unwrap().port();
        tokio::spawn(serve(pl, b"PROXY", Some(proxy_hit.clone())));

        let ll = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let lport = ll.local_addr().unwrap().port();
        tokio::spawn(serve(ll, b"LOCAL", None));

        set_proxy(Some(format!("http://127.0.0.1:{pport}")));
        let body = client()
            .get(format!("http://127.0.0.1:{lport}/x"))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        set_proxy(None); // 复位,别影响同进程里的其它测试

        assert_eq!(body, "LOCAL", "本机回环请求被塞进了用户代理 —— CF 反代/预取代理会连不上");
        assert!(!proxy_hit.load(Ordering::SeqCst), "用户代理不该被连");
    }

    /* UA 口径(用户 2026-07-19 定):Emby=LinPlayer/版本,多线程加载/预加载=LinPlayerPreload/版本,
       其它=默认(不设)。**真起一个服务器读实际发出的请求头**,不比对字符串常量 ——
       比对常量只能证明 format! 没写错,证明不了 .user_agent() 真的挂到了那个 client 上。
       反向验证:把 preload_client() 改成 cached(&PRELOAD_CLIENT, Some(user_agent())),此测试立刻红。 */
    #[tokio::test]
    async fn each_client_sends_its_own_user_agent() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let l = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = l.local_addr().unwrap().port();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = l.accept().await {
                let mut b = [0u8; 2048];
                let n = c.read(&mut b).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&b[..n]).to_string();
                let ua = req
                    .lines()
                    .find(|l| l.to_ascii_lowercase().starts_with("user-agent:"))
                    .map(|l| l[11..].trim().to_string())
                    .unwrap_or_default(); // 没有这个头 = 空串
                let _ = tx.send(ua);
                let _ = c.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await;
            }
        });

        let url = format!("http://127.0.0.1:{port}/x");
        for (who, cli) in [
            ("emby", emby_client()),
            ("preload", preload_client()),
            ("默认", client()),
        ] {
            let _ = cli.get(&url).send().await;
            let got = rx.recv().await.expect("服务端没收到请求");
            match who {
                "emby" => assert_eq!(got, format!("LinPlayer/{APP_VERSION}"), "访问 Emby 的 UA 不对"),
                "preload" => assert_eq!(
                    got,
                    format!("LinPlayerPreload/{APP_VERSION}"),
                    "多线程加载/预加载的 UA 不对 —— 服主没法把预取旁路和真人观看分开"
                ),
                _ => assert!(
                    !got.starts_with("LinPlayer"),
                    "其它请求不该带我们的 UA(用户要求走默认),实际发出: {got:?}"
                ),
            }
        }
    }

    /* set_proxy 必须让缓存的 client 失效,否则改代理要重启才生效(静默不干活)。 */
    #[test]
    fn set_proxy_invalidates_cached_client() {
        // 三个都要填上、三个都要被清 —— 漏清任何一个,那条路就还在用旧代理设置。
        let (_, _, _) = (client(), emby_client(), preload_client());
        assert!(CLIENT.read().unwrap().is_some());
        assert!(EMBY_CLIENT.read().unwrap().is_some());
        assert!(PRELOAD_CLIENT.read().unwrap().is_some());
        set_proxy(Some("http://127.0.0.1:1".to_string()));
        assert!(CLIENT.read().unwrap().is_none(), "改了代理却还在用旧 client");
        assert!(EMBY_CLIENT.read().unwrap().is_none(), "Emby 客户端没跟着换代理");
        assert!(PRELOAD_CLIENT.read().unwrap().is_none(), "预取客户端没跟着换代理");
        set_proxy(None);
    }
}
