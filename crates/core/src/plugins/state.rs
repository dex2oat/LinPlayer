//! 每插件一份的共享状态,克隆进所有 ctx 绑定闭包。含:权限门控、HTTPS 白名单 http、
//! 存储/宿主句柄、handler/事件/生命周期的 Persistent 表、以及空转看门狗 deadline。

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rquickjs::{Ctx, Exception, Function, IntoJs, Persistent, Value};
use serde_json::{json, Value as Json};

use super::convert::{js_value_to_json, json_to_js};
use super::extensions::ExtensionRegistry;
use super::host::PluginHost;
use super::permission;
use super::storage::PluginStorage;

/// 单次进入 JS 的空转墙钟上限(无任何宿主交互超过此值 = 判失控)。
pub const WATCHDOG_MS: i64 = 30_000;

pub type PersistentFn = Persistent<Function<'static>>;

pub struct CtxState {
    pub plugin_id: String,
    pub permissions: permission::GrantedPermissions,
    pub allowed_hosts: Vec<String>,
    pub http: reqwest::Client,
    pub storage: Arc<PluginStorage>,
    pub host: Arc<dyn PluginHost>,
    pub registry: Arc<ExtensionRegistry>,
    /// 动态注册的 handler(id -> JS 函数)。
    pub handlers: Mutex<HashMap<String, PersistentFn>>,
    /// 播放事件监听(event -> [fn])。
    pub events: Mutex<HashMap<String, Vec<PersistentFn>>>,
    /// 生命周期回调(onEnable/onDisable)。
    pub lifecycle: Mutex<HashMap<String, PersistentFn>>,
    pub handler_seq: AtomicU64,
    /// 看门狗:JS 应在此毫秒(UNIX ms)前有宿主交互;0 = 关闭。
    pub deadline: Arc<AtomicI64>,
}

/// host 是否命中白名单。除精确匹配外支持 `*.example.com` 形式的子域通配
/// (线路节点这类由服务端动态分配、事先枚举不全的域名靠它)。
fn host_allowed(allowed: &[String], host: &str) -> bool {
    let h = host.to_lowercase();
    allowed.iter().any(|raw| {
        let entry = raw.to_lowercase();
        if entry == h {
            return true;
        }
        match entry.strip_prefix('*') {
            // "*.example.com" -> ".example.com";要求点分隔,防 evil-example.com 命中。
            // 只认 "*." 开头:裸 "*" 会让 suffix 为空、ends_with 恒真,
            // 一个字符就把 fail-closed 击穿成放行全网。
            Some(suffix) if suffix.starts_with('.') => h.len() > suffix.len() && h.ends_with(suffix),
            _ => false,
        }
    })
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl CtxState {
    pub fn require(&self, permission_id: &str) -> Result<(), String> {
        if self.permissions.has(permission_id) {
            Ok(())
        } else {
            Err(permission::permission_error(&self.plugin_id, permission_id))
        }
    }

    /// 刷新看门狗:有宿主交互就把死线推后。纯 JS 死循环不碰宿主 -> 不刷新 -> 到点被中断。
    pub fn bump_deadline(&self) {
        self.deadline.store(now_ms() + WATCHDOG_MS, Ordering::Relaxed);
    }

    pub fn next_handler_id(&self) -> String {
        let n = self.handler_seq.fetch_add(1, Ordering::Relaxed);
        format!("h{n}")
    }

    /// 转发平台能力(ui/player/emby/cfproxy)。调用前须已 require 权限。
    pub async fn host_call(&self, channel: &str, method: &str, args: Vec<Json>) -> Result<Json, String> {
        self.bump_deadline();
        let r = self.host.call(&self.plugin_id, channel, method, args).await;
        self.bump_deadline();
        r
    }

    // ---- http:仅 HTTPS + 白名单(fail-closed)----
    // 匹配逻辑在下面的自由函数,不然要构造整个 CtxState(含 rquickjs 句柄)才测得了。

    fn host_allowed(&self, host: &str) -> bool {
        host_allowed(&self.allowed_hosts, host)
    }

    /// 执行插件 http 请求。method ∈ get/post/delete。args 已转 JSON。
    pub async fn http_request(&self, method: &str, args: Vec<Json>) -> Result<Json, String> {
        self.require("http")?;
        self.bump_deadline();
        let url = args.first().and_then(|v| v.as_str()).unwrap_or("").to_string();
        let parsed = reqwest::Url::parse(&url).map_err(|_| format!("URL 非法: {url}"))?;
        if parsed.scheme() != "https" {
            return Err(format!("仅允许 HTTPS 请求: {url}"));
        }
        let host = parsed.host_str().unwrap_or("");
        if !self.host_allowed(host) {
            return Err(format!("域名不在白名单内: {host}"));
        }

        // opts:get/delete 在 args[1],post 在 args[2](args[1]=body)。
        let (body, opts) = if method == "post" {
            (args.get(1).cloned(), args.get(2).cloned())
        } else {
            (None, args.get(1).cloned())
        };
        let opts = opts.unwrap_or(Json::Null);
        let discard = opts.get("discardBody").and_then(|v| v.as_bool()).unwrap_or(false);

        let mut req = match method {
            "get" => self.http.get(parsed.clone()),
            "post" => self.http.post(parsed.clone()),
            "delete" => self.http.delete(parsed.clone()),
            other => return Err(format!("不支持的 http 方法: {other}")),
        };

        // query 合并。
        if let Some(q) = opts.get("query").and_then(|v| v.as_object()) {
            let pairs: Vec<(String, String)> = q
                .iter()
                .map(|(k, v)| (k.clone(), json_scalar(v)))
                .collect();
            req = req.query(&pairs);
        }
        // headers。
        if let Some(h) = opts.get("headers").and_then(|v| v.as_object()) {
            for (k, v) in h {
                req = req.header(k.as_str(), json_scalar(v));
            }
        }
        // body(post/delete)。Map/List -> JSON;字符串原样。
        let send_body = body.or_else(|| opts.get("body").cloned());
        if let Some(b) = send_body {
            match b {
                Json::String(s) => {
                    req = req.body(s);
                }
                Json::Null => {}
                other => {
                    req = req.json(&other);
                }
            }
        }

        let resp = req.send().await.map_err(|e| format!("请求失败: {e}"))?;

        // 防重定向绕白名单:最终 host 必须仍在白名单。
        let final_host = resp.url().host_str().unwrap_or("").to_string();
        if !self.host_allowed(&final_host) {
            return Err(format!("请求经重定向到了白名单外主机: {final_host}"));
        }
        let status = resp.status().as_u16();
        let headers = header_map_json(resp.headers());
        self.bump_deadline();

        if discard {
            // 按流丢弃,只统计字节数(测速用,内存恒定)。
            let mut bytes: u64 = 0;
            let mut resp = resp;
            while let Some(chunk) = resp.chunk().await.map_err(|e| format!("读流失败: {e}"))? {
                bytes += chunk.len() as u64;
                self.bump_deadline();
            }
            return Ok(json!({ "status": status, "headers": headers, "bytes": bytes }));
        }

        let text = resp.text().await.map_err(|e| format!("读响应失败: {e}"))?;
        Ok(json!({ "status": status, "headers": headers, "body": decode_body(&text) }))
    }
}

fn json_scalar(v: &Json) -> String {
    match v {
        Json::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn header_map_json(headers: &reqwest::header::HeaderMap) -> Json {
    let mut map = serde_json::Map::new();
    for (k, v) in headers {
        if let Ok(s) = v.to_str() {
            map.insert(k.as_str().to_string(), json!(s));
        }
    }
    Json::Object(map)
}

/// 响应体:像 JSON 就解析成对象/数组,否则原样字符串。
fn decode_body(text: &str) -> Json {
    let t = text.trim_start();
    if t.starts_with('{') || t.starts_with('[') {
        if let Ok(v) = serde_json::from_str::<Json>(text) {
            return v;
        }
    }
    json!(text)
}

/// FromJs 包装:在进入 async 绑定前就把 JS 值转成 owned JSON,绕开 'js 借用跨 await。
pub struct JsonVal(pub Json);

impl<'js> rquickjs::FromJs<'js> for JsonVal {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        Ok(JsonVal(js_value_to_json(&value)))
    }
}

/// async 绑定的返回:Ok(JSON) 正常 resolve;Err(msg) 抛出真 Error 对象(带 message)。
/// into_js 拿得到 ctx,所以能构造带自定义文案的异常——省掉 Dart 那套 {ok,error} 信封。
pub struct JsOut(pub Result<Json, String>);

impl<'js> IntoJs<'js> for JsOut {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        match self.0 {
            Ok(v) => json_to_js(ctx, &v),
            Err(msg) => Err(Exception::throw_message(ctx, &msg)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::host_allowed;

    fn list(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn empty_whitelist_denies_everything() {
        assert!(!host_allowed(&[], "www.uhdnow.com")); // fail-closed,空 != 放行
    }

    #[test]
    fn exact_and_case_insensitive() {
        let w = list(&["www.uhdnow.com"]);
        assert!(host_allowed(&w, "www.uhdnow.com"));
        assert!(host_allowed(&w, "WWW.UHDNOW.COM"));
        assert!(!host_allowed(&w, "uhdnow.com"));
    }

    #[test]
    fn wildcard_matches_subdomains_only() {
        let w = list(&["*.uhdnow.com"]);
        assert!(host_allowed(&w, "china-vod4.uhdnow.com"));
        assert!(host_allowed(&w, "a.b.uhdnow.com")); // 多级子域也算
        assert!(!host_allowed(&w, "uhdnow.com")); // 裸主域要单独列
        assert!(!host_allowed(&w, "evil-uhdnow.com")); // 点分隔,防前缀拼接
        assert!(!host_allowed(&w, "uhdnow.com.evil.net")); // 只看后缀,不看包含
    }

    #[test]
    fn bare_star_is_not_a_wildcard() {
        // 裸 "*" 若被当通配,一个字符就把 fail-closed 击穿成放行全网。
        assert!(!host_allowed(&list(&["*"]), "attacker.com"));
        assert!(!host_allowed(&list(&["*com"]), "attacker.com"));
    }
}
