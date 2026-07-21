//! 手机控制台:电视在局域网上开一个小网页,手机扫码打开就能当遥控器用 ——
//! 走位、播放控制、搜索、改设置、加/切服务器,全在手机键盘上做。
//!
//! ## 为什么是这个形态
//! 电视没摄像头,所以「手机出码电视扫」不存在;能走的只有**电视出码、手机扫**。
//! 而手机扫到的必须是它自己能打开的东西 —— 于是电视自己当一小台 HTTP 服务器。
//! 走局域网而不是云中转:不花服务器钱、断外网也能用、什么都不出家门。
//!
//! ## 这一层管什么、不管什么
//! 本模块只做**传输**:监听、路由、发那一页 HTML。所有业务(登录/切服/搜索/设置/
//! 按键注入)由宿主壳注入的 [`Handler`] 处理 —— 那些能力全在 `apps/android` 的
//! 命令层里,core 不认识 tauri,也不该认识。
//!
//! ## 安全边界
//! * 路径带一次性 token(只在二维码和电视屏幕上出现),同局域网的其它设备猜不到;
//! * 只监听局域网,不做任何 UPnP/端口映射,出不了家门;
//! * 用户能在设置里整个关掉(默认开,否则"遥控器"每次要先去电视上打开,等于没有)。
//!
//! ⚠️ 明文 HTTP。局域网内能抓包的人能看到密码 —— 这和「在同一个 Wi-Fi 下用 http://
//! 访问自建 Emby」是同一档风险,不额外引入 TLS(自签证书在手机浏览器上只会弹警告,
//! 反而把用户教成无视警告)。

use std::future::Future;
use std::net::UdpSocket;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// 业务处理器:`(接口名, JSON 请求体) -> JSON 响应体`。
///
/// 接口名是 `/api/` 后面那一段(如 `state` / `key` / `login`)。
/// 返回的字符串原样当 `application/json` 发回去;出错也请返回 JSON
/// (形如 `{"error":"…"}`),别返回空串 —— 手机那边 `res.json()` 会炸。
pub type Handler = Arc<
    dyn Fn(String, String) -> Pin<Box<dyn Future<Output = String> + Send>> + Send + Sync + 'static,
>;

/// 运行中的控制台服务。Drop 即停服。
pub struct Companion {
    /// 二维码里要编的地址,形如 `http://192.168.1.7:53211/c/1a2b3c4d5e6f`。
    /// None = 服务在跑,但探测不到本机地址(见 [`Companion::ip_error`])。
    pub url: Option<String>,
    /// 实际监听端口。IP 探不到时界面靠它给用户一条可自查的线索。
    pub port: u16,
    /// IP 探测失败的原因;None = 一切正常。**别把它和"服务没起来"混为一谈**。
    pub ip_error: Option<String>,
    task: JoinHandle<()>,
}

impl Drop for Companion {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// 起服。绑 0.0.0.0 随机端口,返回带 token 的可扫地址。
///
/// ★ **拿不到局域网 IP 不算失败**。服务照起(0.0.0.0 上谁都能连),只是二维码里
///   写不出地址 —— 这时 `url` 为 None、`ip_error` 说明原因,界面照样能显示端口和
///   排查提示。上一版把这两件事捆在一起:IP 探测一失手,整个手机遥控直接不存在,
///   而界面只会说"未开启",完全查不下去。
pub async fn start(handler: Handler) -> Result<Companion, String> {
    let listener = TcpListener::bind(("0.0.0.0", 0))
        .await
        .map_err(|e| format!("监听失败: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let base = format!("/c/{}", one_time_token());
    let (ip, ip_error) = match lan_ip() {
        Some(ip) => (Some(ip), None),
        None => (
            None,
            Some("探测不到本机局域网地址(所有出口都不通?)".to_string()),
        ),
    };
    let url = ip.as_ref().map(|ip| format!("http://{ip}:{port}{base}"));

    let task = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { break };
            let h = handler.clone();
            let base = base.clone();
            tokio::spawn(async move {
                let _ = serve(stream, &base, h).await;
            });
        }
    });

    Ok(Companion { url, port, ip_error, task })
}

/// 一个连接一次请求(手机浏览器发完就等回,不复用也没关系)。
async fn serve(mut s: TcpStream, base: &str, handler: Handler) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(2048);
    let mut chunk = [0u8; 2048];
    // 先把头读全,再按 Content-Length 补身体。请求体都是小 JSON,8KB 封顶足够。
    let head_end = loop {
        let n = s.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = find(&buf, b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > 8192 {
            return Ok(());
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut it = head.split_whitespace();
    let method = it.next().unwrap_or("").to_string();
    let path = it.next().unwrap_or("").to_string();

    // 页面本体。末尾多一个 `/` 也认 —— 手机浏览器/扫码器补斜杠是常事。
    if path == base || path == format!("{base}/") {
        return reply(&mut s, "200 OK", "text/html; charset=utf-8", PAGE).await;
    }

    let Some(rest) = path.strip_prefix(&format!("{base}/api/")) else {
        // token 不对或路径不认:一律 404,别透露任何别的信息。
        return reply(&mut s, "404 Not Found", "text/plain; charset=utf-8", "").await;
    };
    if method != "POST" {
        return reply(&mut s, "405 Method Not Allowed", "text/plain", "").await;
    }

    let want = content_length(&head).unwrap_or(0).min(64 * 1024);
    while buf.len() - head_end < want {
        let n = s.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let body = String::from_utf8_lossy(&buf[head_end..]).to_string();
    let out = handler(rest.to_string(), body).await;
    reply(&mut s, "200 OK", "application/json; charset=utf-8", &out).await
}

async fn reply(s: &mut TcpStream, status: &str, ctype: &str, body: &str) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    s.write_all(head.as_bytes()).await?;
    s.write_all(body.as_bytes()).await?;
    s.flush().await
}

fn find(h: &[u8], needle: &[u8]) -> Option<usize> {
    h.windows(needle.len()).position(|w| w == needle)
}

fn content_length(head: &str) -> Option<usize> {
    head.lines()
        .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|v| v.trim().parse().ok())
}

/// 本机局域网地址。UDP connect 不发包,只是让内核挑一条出口路由 —— 拿它的源地址即可,
/// 不需要枚举网卡(那要么加依赖,要么各平台各写一套)。目标用公网 DNS 只是当"方向",
/// 断外网也照样能得到网卡地址。
fn lan_ip() -> Option<String> {
    /* ★ 试**多个**目标,不是一个。connect 只是让内核挑一条路由,而"哪条路由存在"
       各家网络不一样:没有外网的内网只有私网路由,DNS 被墙的环境到 8.8.8.8 可能
       无路由,有的盒子还挂着 VPN。任一目标能选出路由就够了。
       (上一版只打 223.5.5.5 一个目标,一失手整个功能就消失。) */
    const PROBES: [&str; 5] = [
        "223.5.5.5:80",    // 阿里 DNS:国内一般通
        "114.114.114.114:80",
        "8.8.8.8:80",
        "192.168.1.1:80",  // 纯内网(没外网也有路由)最常见的两个网关段
        "10.0.0.1:80",
    ];
    for target in PROBES {
        let Ok(s) = UdpSocket::bind("0.0.0.0:0") else { continue };
        if s.connect(target).is_err() {
            continue;
        }
        let Ok(addr) = s.local_addr() else { continue };
        let ip = addr.ip();
        if ip.is_loopback() || ip.is_unspecified() {
            continue;
        }
        return Some(ip.to_string());
    }
    None
}

/// 一次性路径 token。不是密钥,只是让同局域网的别人猜不中这个路径。
fn one_time_token() -> String {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let h = Sha256::digest(n.to_le_bytes());
    h.iter().take(6).map(|b| format!("{b:02x}")).collect()
}

/// 手机上那一页。不引任何外部资源 —— 局域网里没外网也要能开。
const PAGE: &str = include_str!("companion.html");

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn echo_handler(seen: Arc<Mutex<Vec<(String, String)>>>) -> Handler {
        Arc::new(move |name, body| {
            let seen = seen.clone();
            Box::pin(async move {
                seen.lock().unwrap().push((name.clone(), body.clone()));
                format!("{{\"ok\":true,\"api\":\"{name}\"}}")
            })
        })
    }

    #[test]
    fn token_is_hex12_and_varies() {
        let a = one_time_token();
        assert_eq!(a.len(), 12);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
    }

    /// 页面里必须真的带着那几个功能区 —— 这条挡的是「HTML 被改瘦了但没人发现」。
    #[test]
    fn page_has_all_tabs() {
        for t in ["遥控", "播放", "搜索", "服务器", "设置"] {
            assert!(PAGE.contains(t), "手机页缺了「{t}」这一块");
        }
        assert!(PAGE.contains("/api/"), "页面没有任何接口调用,等于个死页");
    }

    /// 端到端:起服 → GET 拿页面 → POST 打接口 → 处理器收到正确的接口名和请求体。
    /// 顺带证明**路径 token 有效** —— 换个路径必须 404,处理器一次都不该被调到。
    #[tokio::test]
    async fn serves_page_and_routes_api() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let Ok(srv) = start(echo_handler(seen.clone())).await else {
            eprintln!("跳过:CI 无局域网地址");
            return;
        };
        let http = reqwest::Client::new();

        let base = srv.url.clone().expect("本机应当探得到局域网地址");
        let html = http.get(&base).send().await.unwrap().text().await.unwrap();
        assert!(html.contains("<html"), "根路径没返回页面");

        // 猜错 token:必须 404,且业务处理器一次都不能被调用
        let wrong = format!(
            "{}/deadbeefdead/api/state",
            base.rsplit_once("/c/").unwrap().0
        );
        let r = http.post(&wrong).body("{}").send().await.unwrap();
        assert_eq!(r.status(), 404, "错 token 竟然没被挡住");

        let r = http
            .post(format!("{base}/api/key"))
            .body(r#"{"k":"up"}"#)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(r.contains("\"api\":\"key\""));

        let s = seen.lock().unwrap();
        assert_eq!(s.len(), 1, "处理器被调的次数不对(错 token 那次漏进来了?)");
        assert_eq!(s[0].0, "key");
        assert_eq!(s[0].1, r#"{"k":"up"}"#);
    }
}
