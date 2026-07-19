//! 端到端集成:跑真 hello 插件全链路(引擎启动 -> onEnable 注册 homeStats -> 触发拿 metrics ->
//! 触发设置页 showForm 改存储 -> 再触发验证变化)。一次覆盖:引擎/ctx.log/storage/extensions
//! 动态注册(函数 handler)/ui.showForm(宿主)/manifest 静态 settingsPages(具名 handler)/生命周期。

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value as Json};

use super::host::PluginHost;
use super::manager::PluginManager;

const HELLO_MANIFEST: &str = r#"{
  "id": "com.linplayer.hello",
  "version": "1.0.0",
  "name": "Hello 示例",
  "author": "LinPlayer",
  "description": "最小教程型插件",
  "main": "main.js",
  "permissions": ["ui", "storage", "extensions"],
  "extends": {
    "settingsPages": [
      { "id": "settings", "title": "Hello 设置", "handler": "openSettings" }
    ]
  }
}"#;

// 与仓库 com.linplayer.hello/1.0.0/main.js 逐字一致(证新引擎无需改插件源即可跑)。
const HELLO_MAIN: &str = r#"
'use strict';
async function homeMetric() {
  var name = (await ctx.storage.get('name')) || 'World';
  return { metrics: [{ label: '问候', value: 'Hello, ' + name }] };
}
async function openSettings() {
  var name = (await ctx.storage.get('name')) || '';
  var values = await ctx.ui.showForm({
    title: 'Hello 设置',
    fields: [ { key: 'name', label: '称呼', type: 'text', default: name } ],
    submitLabel: '保存', cancelLabel: '取消'
  });
  if (!values) return;
  await ctx.storage.set('name', (values.name || 'World').trim());
  ctx.ui.showToast('已保存');
  await register();
}
async function register() {
  await ctx.extensions.unregister('homeStats', 'hello');
  await ctx.extensions.register('homeStats', { id: 'hello', title: '问候', handler: homeMetric });
}
ctx.onEnable(async function () {
  ctx.log.info('Hello 插件已启用');
  await register();
});
ctx.onDisable(function () { ctx.log.info('Hello 插件已禁用'); });
"#;

/// 测试宿主:showForm 返回填好的 {name:"小明"},其余返回 null。
struct TestHost;

#[async_trait]
impl PluginHost for TestHost {
    async fn call(&self, _pid: &str, channel: &str, method: &str, _args: Vec<Json>) -> Result<Json, String> {
        match (channel, method) {
            ("ui", "showForm") => Ok(json!({ "name": "小明" })),
            _ => Ok(Json::Null),
        }
    }
    fn log(&self, _pid: &str, _level: &str, _msg: &str) {}
}

fn setup_hello(base: &std::path::Path) {
    let dir = base.join("plugins").join("com.linplayer.hello");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("manifest.json"), HELLO_MANIFEST).unwrap();
    std::fs::write(dir.join("main.js"), HELLO_MAIN).unwrap();
}

#[tokio::test]
async fn hello_plugin_full_lifecycle() {
    let base = std::env::temp_dir().join(format!("lp_hello_it_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    setup_hello(&base);

    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;

    // 扫到 1 个插件,初始禁用。
    let list = mgr.list();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["status"], "disabled");

    // 启用 -> 引擎启动 + onEnable 注册 homeStats。
    mgr.enable("com.linplayer.hello").await.unwrap();
    let hs = mgr.extensions_by_type("homeStats");
    assert_eq!(hs.len(), 1, "onEnable 应注册 1 个 homeStats");
    assert_eq!(hs[0]["id"], "hello");

    // 触发 homeStats handler(动态函数)-> 默认 "Hello, World"。
    let r = mgr
        .trigger_extension("com.linplayer.hello", "homeStats", "hello", json!([]))
        .await
        .unwrap();
    assert_eq!(r["metrics"][0]["label"], "问候");
    assert_eq!(r["metrics"][0]["value"], "Hello, World");

    // 触发设置页(manifest 静态 settingsPages,具名 handler openSettings)->
    // showForm 返回 {name:小明} -> storage.set -> 重注册。
    mgr.trigger_extension("com.linplayer.hello", "settingsPages", "settings", json!([]))
        .await
        .unwrap();

    // 再触发 homeStats -> 应变成 "Hello, 小明"(证 storage 读写 + 动态 handler 全通)。
    let r2 = mgr
        .trigger_extension("com.linplayer.hello", "homeStats", "hello", json!([]))
        .await
        .unwrap();
    assert_eq!(r2["metrics"][0]["value"], "Hello, 小明");

    // 禁用 -> 扩展清空。
    mgr.disable("com.linplayer.hello").await;
    assert_eq!(mgr.extensions_by_type("homeStats").len(), 0);

    let _ = std::fs::remove_dir_all(&base);
}

#[tokio::test]
async fn permission_denied_without_grant() {
    // 一个申请 storage 但不含 http 的插件调用 ctx.http 应抛权限错。
    let base = std::env::temp_dir().join(format!("lp_perm_it_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let dir = base.join("plugins").join("com.test.noperm");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("manifest.json"),
        r#"{"id":"com.test.noperm","version":"1.0.0","name":"NoPerm","permissions":["extensions"]}"#,
    )
    .unwrap();
    // 顶层就调 ctx.http.get(无 http 权限)-> reject;再注册一个 action handler 报告结果。
    std::fs::write(
        dir.join("main.js"),
        r#"
        globalThis.__err = null;
        ctx.onEnable(async function(){
          try { await ctx.http.get('https://example.com/'); }
          catch(e){ globalThis.__err = String(e && e.message ? e.message : e); }
          await ctx.extensions.register('actions', { id:'probe', title:'p', handler: function(){ return globalThis.__err; } });
        });
        "#,
    )
    .unwrap();

    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;
    mgr.enable("com.test.noperm").await.unwrap();
    let r = mgr
        .trigger_extension("com.test.noperm", "actions", "probe", json!([]))
        .await
        .unwrap();
    let msg = r.as_str().unwrap_or("");
    assert!(msg.contains("缺少权限"), "应因缺 http 权限被拒: {msg}");

    mgr.disable("com.test.noperm").await;
    let _ = std::fs::remove_dir_all(&base);
}
