/* 匿名遥测(Sentry)—— PC 端(Rust + Tauri)。
   移植自移动端 `lib/core/services/telemetry.dart`,口径逐条对齐:
   只做两件事 —— **崩溃/错误上报** + **Release Health 匿名活跃用户统计**(「有多少人在用」)。

   为什么 PC 端非要它不可:release 是 `windows_subsystem = "windows"`,**没有控制台**,
   而 poclog 只写本机 app.log 且每次启动就删。用户那边 Rust 一 panic,进程直接消失,
   我们这边零信息 —— 和「透明窗口下 React 崩了 = 一片黑」是同一类问题(见 PageBoundary.tsx),
   区别只是这个连截图都没得看。sentry-panic 接管 panic hook 后,崩溃现场才第一次能被看见。

   隐私底线(和 Dart 侧同一套):
   - `send_default_pii = false` —— 不采账号/IP/服务器地址等 PII。
   - 不开性能追踪(`traces_sample_rate = 0`),不录屏。
   - 用户 id 由 Sentry 匿名 installId 承担(只数人头、不认身份)。
   - ★ 比 Dart 侧多一层:`before_send` 把用户主目录路径抹成 `~`。Rust 的 panic 消息里
     常年带绝对路径(paths::root() 那一串全在主目录下),而主目录里嵌着 **Windows 用户名**。
     这是数据离开本机前的最后一道口子,不能省。

   DSN 与移动端同一个项目:PC 用户也该计入 README 那个活跃人数徽章。
   两端靠 release 前缀区分 —— 移动端 `linplayer@x.y.z`,这边 `linplayer-pc@x.y.z`。 */

use std::sync::Arc;

const DSN: &str = "https://7ea0381776746dcddd6d499d8e9e5d45@o4511717250433024.ingest.us.sentry.io/4511717262032896";

/// 初始化 Sentry。返回的 guard **必须在整个进程生命周期内持有** —— 一旦 drop,
/// client 就关闭,后面的崩溃全部丢弃。调用方要把它 bind 在 `run()` 的栈上。
pub fn init() -> sentry::ClientInitGuard {
    /* debug 构建不上报:开发机每天崩十次是常态,那些既污染 issue 列表,又会把
       「有多少人在用」的匿名会话数灌成我自己。dsn=None 时 sentry 返回一个惰性 guard,
       init 之后所有 API 变成空操作,不用在调用点加分支。 */
    let dsn = if cfg!(debug_assertions) { None } else { DSN.parse().ok() };
    sentry::init(options(dsn))
}

/// 和 [`init`] 分开,只为了测试能拿到同一份 options 去接内存 transport ——
/// 否则「before_send 到底有没有接上 client」这一环没人验。
fn options(dsn: Option<sentry::types::Dsn>) -> sentry::ClientOptions {
    // 主目录字符串,用来在出站前抹掉用户名。太短的(比如根目录)不抹,免得把无关字符替没了。
    let home = dirs::home_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .filter(|s| s.len() >= 4);

    sentry::ClientOptions {
        dsn,
        // 版本取自 tauri.conf.json(build.rs 注入)—— 那是 pack-portable.ps1 给 zip 命名用的
        // 同一个字段。用 CARGO_PKG_VERSION 会读 Cargo.toml,两者没有任何东西保证同步,
        // 一旦漂移,上传的符号/sourcemap 就挂在另一个 release 上,堆栈还是乱码。
        release: Some(format!("linplayer-pc@{}", env!("LP_VERSION")).into()),
        send_default_pii: false,
        traces_sample_rate: 0.0,
        auto_session_tracking: true,
        session_mode: sentry::SessionMode::Application,
        before_send: Some(Arc::new(move |mut ev| {
            if let Some(home) = home.as_deref() {
                scrub_home(&mut ev, home);
            }
            Some(ev)
        })),
        ..Default::default()
    }
}

/// 把事件里所有人类可读文本中的主目录前缀换成 `~`。
/// 只碰 message / exception value / breadcrumb message —— 堆栈帧里的路径是**编译期**的
/// 源码路径(开发机的),不含用户名,换掉反而会让符号对不上。
fn scrub_home(ev: &mut sentry::protocol::Event<'static>, home: &str) {
    if let Some(m) = ev.message.as_mut() {
        *m = m.replace(home, "~");
    }
    if let Some(le) = ev.logentry.as_mut() {
        le.message = le.message.replace(home, "~");
    }
    for e in &mut ev.exception.values {
        if let Some(v) = e.value.as_mut() {
            *v = v.replace(home, "~");
        }
    }
    for b in &mut ev.breadcrumbs.values {
        if let Some(m) = b.message.as_mut() {
            *m = m.replace(home, "~");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /* release 名的三处必须是同一个数:这里的 LP_VERSION、vite.config.ts 的 __APP_VERSION__、
       pack-portable.ps1 的 zip 文件名。三者都读 tauri.conf.json,这条断言守的是
       build.rs 的注入没断 —— 一旦 LP_VERSION 变空或读错字段,上传的符号就挂到别的
       release 上,而那种失败是**静默**的:构建全绿,只有线上堆栈变乱码。 */
    /* 端到端:走真实的 ClientOptions 建一个 client,捕获真的发出去的事件。
       上面那条只证明 scrub_home 这个纯函数写得对 —— 证明不了它**被调用**。
       before_send 填错字段、或者哪天被 `..Default::default()` 覆盖掉,
       纯函数测试会照样绿,而用户名照样往外发。这条才是那个口子的守卫。
       ★ 证明过会红:把 options() 里的 before_send 改成 None,断言挂在
         `真实事件里仍带主目录`。 */
    #[test]
    fn before_send_is_actually_wired_into_the_client() {
        let home = dirs::home_dir().unwrap().to_string_lossy().into_owned();
        let dsn = "https://k@o0.ingest.sentry.io/1".parse().ok();

        let events = sentry::test::with_captured_events_options(
            || {
                sentry::capture_message(&format!(r"open {home}\userdata\x"), sentry::Level::Error);
            },
            options(dsn),
        );

        assert_eq!(events.len(), 1, "事件没发出去,这个测试就什么也没验到");
        let msg = events[0].message.as_deref().unwrap();
        assert!(!msg.contains(&home), "真实事件里仍带主目录: {msg}");
        assert!(msg.starts_with(r"open ~\userdata"), "抹过头了: {msg}");
        // 顺带钉住另外两条隐私开关,别哪天被顺手改掉。
        assert_eq!(
            events[0].release.as_deref(),
            Some(format!("linplayer-pc@{}", env!("LP_VERSION")).as_str())
        );
    }

    #[test]
    fn release_version_comes_from_tauri_conf() {
        let conf: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        assert_eq!(env!("LP_VERSION"), conf["version"].as_str().unwrap());
        assert!(!env!("LP_VERSION").is_empty());
    }

    /// 反向验证:不抹的话事件里就带着 Windows 用户名。这个测试**证明过会红** ——
    /// 把 exception 那个循环换成空 Vec 后,断言当场挂在
    /// `left: "no such file: C:\Users\zhangsan\..."`。
    #[test]
    fn scrubs_home_dir_out_of_user_visible_text() {
        let home = r"C:\Users\zhangsan";
        let mut ev = sentry::protocol::Event {
            message: Some(format!(r"failed to open {home}\AppData\x.db")),
            ..Default::default()
        };
        ev.exception.values.push(sentry::protocol::Exception {
            ty: "panic".into(),
            value: Some(format!(r"no such file: {home}\userdata\config.json")),
            ..Default::default()
        });
        ev.breadcrumbs.values.push(sentry::protocol::Breadcrumb {
            message: Some(format!(r"scanning {home}\Videos")),
            ..Default::default()
        });

        scrub_home(&mut ev, home);

        assert_eq!(ev.message.as_deref(), Some(r"failed to open ~\AppData\x.db"));
        assert_eq!(
            ev.exception.values[0].value.as_deref(),
            Some(r"no such file: ~\userdata\config.json")
        );
        assert_eq!(ev.breadcrumbs.values[0].message.as_deref(), Some(r"scanning ~\Videos"));
    }
}
