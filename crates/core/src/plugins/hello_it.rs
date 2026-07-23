//! 端到端集成:跑真插件全链路。
//!
//! 覆盖两条主线:
//!  1. **面板线**:引擎启动 -> onEnable 注册 panel -> 触发拿数据 -> 设置页 showForm
//!     改存储 -> 再触发验证变化(ctx.log / storage / extensions 动态注册 / ui / 生命周期 /
//!     manifest 静态贡献的具名 handler)。
//!  2. **数据源线**:`ctx.sources.register` 的三个函数经 `PluginSourceBackend` 变成
//!     真正的 `MediaSourceBackend`,能列目录、能搜索、能解析播放地址。
//!     **这条是插件系统 v2 的核心承诺,不端到端跑一遍等于没做。**

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value as Json};

use super::host::PluginHost;
use super::manager::PluginManager;
use crate::source::plugin_source::PluginSourceBackend;
use crate::source::{MediaSourceBackend, SourceServer};

const HELLO_MANIFEST: &str = r#"{
  "id": "com.linplayer.hello",
  "version": "1.0.0",
  "apiVersion": 2,
  "name": "Hello 示例",
  "author": "LinPlayer",
  "description": "最小教程型插件",
  "category": "tools",
  "main": "main.js",
  "permissions": ["ui", "storage", "extensions"],
  "contributes": {
    "panels": [
      { "id": "settings", "title": "Hello 设置", "slot": "settings", "handler": "openSettings" }
    ]
  }
}"#;

// ★ 这段 JS 是插件作者能照抄的**唯一官方样板**,所以它必须和真实前端对得上。
//   两处曾经是错的,而且错得完全静默:
//     1. 面板 handler 返回 `{metrics:[...]}` —— 那是 v1 形状。v2 的渲染器
//        (`ui/shared/plugin-ui.ts::sanitizeTree`)按 `t` 字段分派,没有 `t` 的对象
//        走 default 分支返回 null,**面板画出来是一片空白**;
//     2. showForm 的字段写 `key` / `default` —— 真实映射(`formTree`)读的是
//        `id` / `value`,没有 `id` 的控件会被整棵消毒掉,**表单一片空白**。
//   两处都不报错、不进日志。而本文件的 TestHost 是硬编码返回值的假宿主,
//   从来没跑到那两段映射 —— 编译绿、单测绿、功能坏。
const HELLO_MAIN: &str = r#"
'use strict';
async function homeMetric() {
  var name = (await ctx.storage.get('name')) || 'World';
  return { t: 'col', children: [ { t: 'stat', label: '问候', value: 'Hello, ' + name } ] };
}
async function openSettings() {
  var name = (await ctx.storage.get('name')) || '';
  var values = await ctx.ui.showForm({
    title: 'Hello 设置',
    fields: [ { id: 'name', label: '称呼', type: 'text', value: name } ],
    submitLabel: '保存', cancelLabel: '取消'
  });
  if (!values) return;
  await ctx.storage.set('name', (values.name || 'World').trim());
  ctx.ui.showToast('已保存');
  await register();
}
async function register() {
  await ctx.extensions.unregister('panels', 'hello');
  await ctx.extensions.register('panels', {
    id: 'hello', title: '问候', slot: 'home.stats', handler: homeMetric
  });
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

fn write_plugin(base: &std::path::Path, id: &str, manifest: &str, main_js: &str) {
    let dir = base.join("plugins").join(id);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("manifest.json"), manifest).unwrap();
    std::fs::write(dir.join("main.js"), main_js).unwrap();
}

/// 每个测试各自一个临时根 —— 共用会互相踩(插件状态是落盘的)。
fn temp_base(tag: &str) -> std::path::PathBuf {
    let base = std::env::temp_dir().join(format!("lp_it_{tag}_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    base
}

#[tokio::test]
async fn hello_plugin_full_lifecycle() {
    let base = temp_base("hello");
    write_plugin(&base, "com.linplayer.hello", HELLO_MANIFEST, HELLO_MAIN);

    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;

    // 扫到 1 个插件,初始禁用。
    let list = mgr.list();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["status"], "disabled");

    // 启用 -> 引擎启动 + onEnable 注册 panel。
    mgr.enable("com.linplayer.hello").await.unwrap();
    let hs = mgr.panels_in_slot("home.stats");
    assert_eq!(hs.len(), 1, "onEnable 应往 home.stats 挂 1 个面板");
    assert_eq!(hs[0]["id"], "hello");
    // manifest 静态贡献的设置页挂在 settings,不该混进 home.stats
    assert_eq!(mgr.panels_in_slot("settings").len(), 1);

    // 触发面板 handler(动态函数)-> 默认 "Hello, World"。
    let r = mgr
        .trigger_extension("com.linplayer.hello", "panels", "hello", json!([]))
        .await
        .unwrap();
    // 断言按**真实渲染器认得的形状**来 —— 断在一个渲染器根本不认的形状上,
    // 等于测试和界面各说各话。
    assert_eq!(r["t"], "col");
    assert_eq!(r["children"][0]["t"], "stat");
    assert_eq!(r["children"][0]["label"], "问候");
    assert_eq!(r["children"][0]["value"], "Hello, World");

    // 触发设置页(manifest 静态贡献,具名 handler openSettings)->
    // showForm 返回 {name:小明} -> storage.set -> 重注册。
    mgr.trigger_extension("com.linplayer.hello", "panels", "settings", json!([]))
        .await
        .unwrap();

    // 再触发 -> 应变成 "Hello, 小明"(证 storage 读写 + 动态 handler 全通)。
    let r2 = mgr
        .trigger_extension("com.linplayer.hello", "panels", "hello", json!([]))
        .await
        .unwrap();
    assert_eq!(r2["children"][0]["value"], "Hello, 小明");

    // 禁用 -> 贡献清空。
    mgr.disable("com.linplayer.hello").await;
    assert_eq!(mgr.panels_in_slot("home.stats").len(), 0);
    assert_eq!(mgr.panels_in_slot("settings").len(), 0);

    let _ = std::fs::remove_dir_all(&base);
}

const SRC_MANIFEST: &str = r#"{
  "id": "com.test.source",
  "version": "1.0.0",
  "apiVersion": 2,
  "name": "测试数据源",
  "category": "source",
  "permissions": ["sources", "storage"],
  "contributes": {
    "dataSources": [
      { "id": "demo", "name": "演示源",
        "auth": { "fields": [ { "id": "base_url", "label": "地址", "type": "url" } ] } }
    ]
  }
}"#;

/// 三个函数 = 一个完整数据源。故意让 search 抛 unsupported、
/// resolvePlay 回带 headers/字幕/清晰度的完整结构。
const SRC_MAIN: &str = r#"
'use strict';
ctx.onEnable(async function () {
  await ctx.sources.register('demo', {
    async listDir(dirId, server) {
      if (!dirId) {
        return [
          { id: '/movies', name: '电影', isDir: true },
          { id: '/a.mkv',  name: 'a.mkv', size: 123, thumb: 'https://x/t.jpg',
            raw: { fid: 'F1' } },
          { id: '/cover.jpg', name: 'cover.jpg' }
        ];
      }
      return [ { id: dirId + '/b.mp4', name: 'b.mp4', raw: { base: server.baseUrl } } ];
    },
    async search(q) { throw ctx.errors.unsupported(); },
    async resolvePlay(entry, qualityId, server) {
      return {
        url: server.baseUrl + '/stream?f=' + entry.raw.fid + '&q=' + (qualityId || 'auto'),
        httpHeaders: { Referer: server.baseUrl },
        userAgent: 'DemoPlugin/1.0',
        subtitles: [ { url: 'https://x/a.ass', title: '中文', language: 'chi' } ],
        qualities: [ { id: '1080', label: '1080P', rank: 2 }, { id: '720', label: '720P', rank: 1 } ],
        quality: qualityId || '1080'
      };
    }
  });
});
"#;

/// **插件即数据源的端到端证明。**
///
/// 插件写三个函数 -> 经 `PluginSourceBackend` 变成 `MediaSourceBackend` ->
/// 浏览 / 搜索降级 / 解析播放地址全部走通。这条链断了,v2 最大的卖点就是空的。
#[tokio::test]
async fn plugin_contributed_source_works_as_a_real_backend() {
    let base = temp_base("src");
    write_plugin(&base, "com.test.source", SRC_MANIFEST, SRC_MAIN);

    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;
    mgr.enable("com.test.source").await.unwrap();

    // manifest 静态声明 + 运行时注册的是同一个 id,注册表里只该有一条。
    let sources = mgr.data_sources();
    assert_eq!(sources.len(), 1, "同 id 的静态声明和运行时注册应合并成一条");
    assert_eq!(sources[0].0, "com.test.source");
    assert_eq!(sources[0].1, "demo");
    /* ★ 合并要**保住 manifest 的描述字段**。第一版是整条替换,于是插件一注册回调,
       manifest 里的 name 和 auth 表单就没了 —— 「添加服务器」页会给出一个
       没有任何输入框、名字还退化成源 id 的插件源。真机端到端才暴露出来。 */
    assert_eq!(sources[0].2, "演示源", "展示名必须来自 manifest,不能退化成源 id");
    let decl = mgr.extensions_by_type("dataSources");
    assert_eq!(
        decl[0]["data"]["auth"]["fields"][0]["id"], "base_url",
        "manifest 声明的登录表单字段必须活到运行时,否则通用数据源插件根本没法登录"
    );

    let backend = PluginSourceBackend::new("com.test.source", "demo", Arc::downgrade(&mgr));
    assert_eq!(backend.kind().as_str(), "plugin:com.test.source/demo");

    let http = reqwest::Client::new();
    let server = SourceServer {
        id: "s1".into(),
        base_url: "https://nas.example.com".into(),
        ..Default::default()
    };

    // ---- 列根目录 ----
    let root = backend.list_dir(&http, &server, None).await.unwrap();
    assert_eq!(root.len(), 3);
    assert!(root[0].is_dir, "第一条是目录");
    assert!(root[1].is_video, "a.mkv 没填 isVideo,要按宿主扩展名表判为视频");
    assert!(!root[2].is_video, "cover.jpg 不是视频");
    assert_eq!(root[1].size, Some(123));
    assert_eq!(root[1].thumb_url.as_deref(), Some("https://x/t.jpg"));

    // ---- 进子目录:server 要能透到插件里 ----
    let sub = backend.list_dir(&http, &server, Some("/movies")).await.unwrap();
    assert_eq!(sub.len(), 1);
    assert_eq!(sub[0].id, "/movies/b.mp4");
    assert_eq!(
        sub[0].raw.as_ref().unwrap()["base"], "https://nas.example.com",
        "插件应拿得到用户配置的 baseUrl"
    );

    // ---- 搜索:插件抛 unsupported,要被还原成「不支持」而不是一次失败 ----
    let e = backend.search(&http, &server, "关键词").await.err().unwrap();
    assert_eq!(e.message, "该源不支持搜索");
    assert!(!e.is_auth);

    // ---- 解析播放 ----
    let play = backend.resolve_play(&http, &server, &root[1], Some("720")).await.unwrap();
    assert_eq!(play.url, "https://nas.example.com/stream?f=F1&q=720", "raw 要能回传给插件复用");
    assert_eq!(play.title, "a.mkv", "插件没给 title 就用条目名兜底");
    assert_eq!(play.http_headers.get("Referer").unwrap(), "https://nas.example.com");
    assert_eq!(play.user_agent_override.as_deref(), Some("DemoPlugin/1.0"));
    assert_eq!(play.subtitles.len(), 1);
    assert_eq!(play.subtitles[0].language.as_deref(), Some("chi"));
    assert_eq!(play.qualities.len(), 2);
    assert_eq!(play.selected_quality_id.as_deref(), Some("720"));

    // ---- 禁用后源必须消失 ----
    // 留着的话,分派表里会挂着一个永远调不通的后端,用户点进去只会转圈。
    mgr.disable("com.test.source").await;
    assert!(mgr.data_sources().is_empty(), "禁用后数据源必须从注册表摘掉");
    let after = backend.list_dir(&http, &server, None).await;
    assert!(after.is_err(), "插件已禁用,再调必须报错而不是返回空目录");

    let _ = std::fs::remove_dir_all(&base);
}

/// **参数写错必须当场炸,不能悄悄注册一条废的。**
///
/// `ctx.extensions.register` 是 (类型, 描述),`ctx.sources.register` 是 (源id, 描述) ——
/// 两个形状不一样,写混很自然。老代码对 `register('panels','stats',{…})` 照单全收:
/// descriptor 收到字符串 'stats',data 存成裸字符串、id 自动编一个 `ext_7`,注册返回成功。
/// 结果是插件已启用、面板出现在 slot 列表里、render 永远返回 null,**全程没有一句报错**。
#[tokio::test]
async fn registering_with_a_non_object_descriptor_fails_loudly() {
    const M: &str = r#"{"id":"com.test.badreg","version":"1.0.0","apiVersion":2,
      "name":"写错参数","permissions":["extensions"]}"#;
    // 多写了一个参数:descriptor 拿到的是字符串 'stats'
    const JS: &str = r#"
'use strict';
ctx.onEnable(async function () {
  await ctx.extensions.register('panels', 'stats', { title: '面板', slot: 'home.stats' });
});
"#;
    let base = temp_base("badreg");
    write_plugin(&base, "com.test.badreg", M, JS);
    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;
    mgr.enable("com.test.badreg").await.unwrap();

    // 一条废贡献都不许留下
    assert!(
        mgr.panels_in_slot("home.stats").is_empty(),
        "参数写错时不该注册出任何面板"
    );
    assert!(
        mgr.extensions_by_type("panels").is_empty(),
        "不该出现自动编号的 ext_N 幽灵贡献"
    );
    // onEnable 抛出的错必须留在记录上 —— 被 `let _ =` 吞掉的话,
    // 界面上这个插件是「已启用、无错误」,面板却永远空白。
    let info = mgr.list().into_iter().find(|p| p["id"] == "com.test.badreg").unwrap();
    let err = info["error"].as_str().unwrap_or("");
    assert!(
        err.contains("onEnable"),
        "onEnable 的失败必须能被用户看见,实际 error={:?} status={:?}",
        info["error"], info["status"]
    );

    let _ = std::fs::remove_dir_all(&base);
}

/// 没有 `sources` 权限就不能注册数据源 —— 否则用户在授权弹窗里只看到「扩展界面」,
/// 却被挂上了一个能联网、能出现在服务器列表里的源。
#[tokio::test]
async fn registering_a_source_without_the_permission_is_denied() {
    let base = temp_base("srcperm");
    write_plugin(
        &base,
        "com.test.sneaky",
        r#"{"id":"com.test.sneaky","version":"1.0.0","apiVersion":2,"name":"Sneaky",
            "category":"tools","permissions":["extensions","ui"]}"#,
        r#"
        globalThis.__err = null;
        ctx.onEnable(async function(){
          try { await ctx.sources.register('x', { listDir: function(){ return []; } }); }
          catch(e){ globalThis.__err = String(e && e.message ? e.message : e); }
          await ctx.extensions.register('actions', {
            id:'probe', title:'p', handler: function(){ return globalThis.__err; }
          });
        });
        "#,
    );

    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;
    mgr.enable("com.test.sneaky").await.unwrap();

    let r = mgr
        .trigger_extension("com.test.sneaky", "actions", "probe", json!([]))
        .await
        .unwrap();
    let msg = r.as_str().unwrap_or("");
    assert!(msg.contains("缺少权限"), "应因缺 sources 权限被拒: {msg}");
    assert!(mgr.data_sources().is_empty(), "被拒之后不该留下任何数据源");

    mgr.disable("com.test.sneaky").await;
    let _ = std::fs::remove_dir_all(&base);
}

#[tokio::test]
async fn permission_denied_without_grant() {
    // 一个申请 extensions 但不含 http 的插件调用 ctx.http 应抛权限错。
    let base = temp_base("perm");
    write_plugin(
        &base,
        "com.test.noperm",
        r#"{"id":"com.test.noperm","version":"1.0.0","apiVersion":2,"name":"NoPerm",
            "category":"tools","permissions":["extensions","ui"]}"#,
        r#"
        globalThis.__err = null;
        ctx.onEnable(async function(){
          try { await ctx.http.get('https://example.com/'); }
          catch(e){ globalThis.__err = String(e && e.message ? e.message : e); }
          await ctx.extensions.register('actions', {
            id:'probe', title:'p', handler: function(){ return globalThis.__err; }
          });
        });
        "#,
    );

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

/// v1 插件必须被挡在门外并给出**能读懂**的理由。
/// 静默跳过的话,用户只会看到「插件列表是空的」,查不出为什么。
#[tokio::test]
async fn v1_plugin_is_rejected_with_a_readable_reason() {
    let base = temp_base("v1");
    write_plugin(
        &base,
        "com.old.plugin",
        r#"{"id":"com.old.plugin","version":"1.0.0","name":"Old",
            "permissions":["ui","extensions"],
            "extends":{"homeStats":[{"id":"s","title":"t","handler":"h"}]}}"#,
        "ctx.onEnable(function(){});",
    );

    let mgr = PluginManager::new(base.clone(), Arc::new(TestHost));
    mgr.init().await;
    assert!(mgr.list().is_empty(), "v1 插件不该被扫进列表");

    // 直接解析要能给出指向性错误(扫描时静默跳过,但安装路径会把这句话给用户看)
    let e = super::manifest::PluginManifest::parse(
        r#"{"id":"com.old.plugin","version":"1.0.0","name":"Old"}"#,
    )
    .unwrap_err();
    assert!(e.contains("旧版本") && e.contains("插件市场"), "{e}");

    let _ = std::fs::remove_dir_all(&base);
}
