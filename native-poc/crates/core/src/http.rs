// 统一 HTTP 客户端与应用身份(UA/Device)。
// 对应 Dart 侧 app_identity:所有请求(含图片/播放流)走同一 UA,避免 CDN 因 UA 空白返回空白图/流。

pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const CLIENT_NAME: &str = "LinPlayer";

/// 统一 User-Agent。
pub fn user_agent() -> String {
    format!("{CLIENT_NAME}/{APP_VERSION}")
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

/// 全局 HTTP 客户端(带统一 UA、全局代理、按 host 的自签名白名单)。
pub fn client() -> reqwest::Client {
    if let Some(c) = CLIENT.read().ok().and_then(|g| g.clone()) {
        return c;
    }
    let mut b = reqwest::Client::builder()
        .user_agent(user_agent())
        .use_preconfigured_tls(tls_config());
    if let Some(url) = PROXY_URL.read().ok().and_then(|g| g.clone()) {
        if let Ok(p) = reqwest::Proxy::all(&url) {
            b = b.proxy(p);
        }
    }
    let c = b.build().expect("build reqwest client");
    if let Ok(mut g) = CLIENT.write() {
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
}
