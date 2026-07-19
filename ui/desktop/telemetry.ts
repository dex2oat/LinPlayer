/* 匿名遥测(Sentry)—— PC 端前端。和 Rust 侧 `apps/desktop/src/telemetry.rs` 是一对:
   那边接 Rust panic,这边接 JS 异常。**同一个 DSN、同一个 release 名**,所以一次崩溃
   两边的证据落在同一处。

   为什么前端非要它不可:Tauri 窗口是**透明的**(要露出垫在下面的 mpv),React 一抛错
   整棵树卸载 = 屏幕一片黑,用户只会报「黑屏」。PageBoundary 把渲染期的错拦在了页内,
   但它按设计只吃**渲染期** —— 事件处理器里的抛错、await 的 rejection 一个都接不到,
   而且这个项目此前**没有任何** window.onerror / unhandledrejection 监听。
   Sentry.init 补的正是这缺掉的另一半。

   隐私底线(和 Rust 侧、和移动端 telemetry.dart 同一套):
   - sendDefaultPii=false(v8 默认),不采 IP/账号。
   - 不开性能追踪、不开 Session Replay(不录屏)。
   - ★ tracePropagationTargets=[] —— 绝不给用户自己的 Emby/网盘/CDN 出站请求塞遥测头。
     这条和 Dart 侧的 `tracePropagationTargets.clear()` 是同一个理由:那些是**用户的**
     服务器,我们没资格往它的请求里加东西。
   - ★ beforeSend 抹掉 URL 里的 api_key/token/密码类 query —— 前端的报错消息里常年
     带着请求 URL,而本项目的 Emby 请求 URL 就带 token。 */

import * as Sentry from "@sentry/react";

const DSN =
  "https://7ea0381776746dcddd6d499d8e9e5d45@o4511717250433024.ingest.us.sentry.io/4511717262032896";

/** 值要被抹掉的 query 参数名(小写比对)。 */
const SECRET_QUERY = ["api_key", "apikey", "x-emby-token", "token", "access_token", "pw", "password", "sign", "authorization"];

/** 把文本里所有 `xxx=<值>` 形式的敏感 query 换成 `xxx=<redacted>`。 */
export function redactSecrets(text: string): string {
  return text.replace(/([?&#]|\b)([A-Za-z_][\w-]*)=([^&\s"'<>]+)/g, (m, sep, key, _v) =>
    SECRET_QUERY.includes(key.toLowerCase()) ? `${sep}${key}=<redacted>` : m,
  );
}

function scrub<T>(v: T): T {
  return typeof v === "string" ? (redactSecrets(v) as unknown as T) : v;
}

export function initTelemetry() {
  Sentry.init({
    dsn: DSN,
    // dev 下不上报:每天热重载崩十次,既污染 issue 列表,又把「有多少人在用」的
    // 匿名会话数灌成我自己。
    enabled: import.meta.env.PROD,
    // 必须和 Rust 侧 `linplayer-pc@{version}` 逐字一致 —— sourcemap 是按 release 挂的,
    // 对不上就等于没传,线上堆栈还是 index-a1b2c3.js:1:48291。
    release: `linplayer-pc@${__APP_VERSION__}`,
    sendDefaultPii: false,
    tracesSampleRate: 0,
    tracePropagationTargets: [],
    beforeSend(event) {
      if (event.message) event.message = scrub(event.message);
      for (const ex of event.exception?.values ?? []) ex.value = scrub(ex.value);
      for (const bc of event.breadcrumbs ?? []) {
        bc.message = scrub(bc.message);
        if (bc.data?.url) bc.data.url = scrub(bc.data.url);
      }
      if (event.request?.url) event.request.url = scrub(event.request.url);
      return event;
    },
  });
}
