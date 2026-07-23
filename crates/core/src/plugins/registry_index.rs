//! 插件市场索引:多源订阅 + 聚合 + sha256 校验。
//!
//! 分发模型(2026-07-23 定):**官方源 + 用户自定义源订阅 + 本地安装**。
//! 官方源不可删只可禁;第三方源的插件在 UI 上打「第三方源」徽章,安装前弹权限确认。
//!
//! 通道口径见 `docs/PLUGINS_V2_PLAN.md` 6.4:**registry 和 .ipk 都走 GitHub raw,
//! 不要"优化"到 Cloudflare**(用户实测:国内 CF 有地方会被阻断,GitHub 反而更稳)。
//! 图标在构建期压成 data URI 内联进 registry.json,所以卡片永远不碎图、零额外请求。

use serde::{Deserialize, Serialize};
use serde_json::Value as Json;

/// 用户订阅的一个插件源。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PluginSource {
    pub id: String,
    pub name: String,
    pub url: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// 官方源。**可禁不可删** —— 删掉之后新用户开箱即空,再想找回来只能手打 URL。
    #[serde(default)]
    pub builtin: bool,
}

fn yes() -> bool {
    true
}

/// registry.json 里的一个版本条目。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct RegistryVersion {
    pub version: String,
    #[serde(default)]
    pub api_version: u32,
    #[serde(default)]
    pub min_app_version: Option<String>,
    #[serde(default)]
    pub package_url: String,
    /// 包的 sha256(小写十六进制)。**v2 新增** —— v1 既无签名也无校验和。
    #[serde(default)]
    pub sha256: Option<String>,
    #[serde(default)]
    pub published_at: Option<String>,
    #[serde(default)]
    pub changelog: Option<String>,
}

/// registry.json 里的一个插件。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RegistryPlugin {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub author: String,
    /// 构建期内联的 data URI。见本文件头注释。
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub targets: Vec<String>,
    /// 权限摘要:上移到 registry,**市场不下载包就能展示权限**。
    #[serde(default)]
    pub permissions: Vec<String>,
    #[serde(default)]
    pub contributes: Option<Json>,
    #[serde(default)]
    pub versions: Vec<RegistryVersion>,
    /// 聚合时填:这条来自哪个源。第三方源要在卡片上打徽章。
    #[serde(default)]
    pub source_id: String,
    #[serde(default)]
    pub source_name: String,
    #[serde(default)]
    pub from_builtin: bool,
}

impl RegistryPlugin {
    /// 当前宿主能装的最新版本。
    ///
    /// **必须自己按版本号取最大,不能信数组顺序** —— 本仓库在 GitHub Releases 上
    /// 栽过一模一样的跟头(id/created/published 三个键的返回顺序全是反的),
    /// 见 [release-version-monotonicity]。
    pub fn best_version(&self, host_api_version: u32) -> Option<&RegistryVersion> {
        self.versions
            .iter()
            .filter(|v| v.api_version == 0 || v.api_version <= host_api_version)
            .max_by(|a, b| compare_versions(&a.version, &b.version))
    }
}

/// 语义化版本比较。缺段按 0 补,非数字段按 0(宽松:registry 是外部数据,
/// 一条写歪的版本号不该让整个市场炸掉)。
pub fn compare_versions(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |s: &str| -> Vec<u64> {
        s.split(['-', '+'])
            .next()
            .unwrap_or("")
            .split('.')
            .map(|p| p.parse::<u64>().unwrap_or(0))
            .collect()
    };
    let (va, vb) = (parse(a), parse(b));
    for i in 0..va.len().max(vb.len()) {
        let x = va.get(i).copied().unwrap_or(0);
        let y = vb.get(i).copied().unwrap_or(0);
        match x.cmp(&y) {
            std::cmp::Ordering::Equal => {}
            other => return other,
        }
    }
    std::cmp::Ordering::Equal
}

/// 一次解析的结果。**跳过数必须带出去** —— 见 [`parse_registry`]。
pub struct ParsedRegistry {
    pub plugins: Vec<RegistryPlugin>,
    /// 认不出来、被跳过的条目数。
    pub skipped: usize,
}

/// 解析一份 registry.json。
///
/// 单条坏了跳过,不让一个写歪的条目废掉整个源 —— 但**跳了多少必须报出来**。
/// 2026-07-23 实测:官方源还是 v1 schema(`author` 是对象不是字符串),
/// 于是 8 条**全部**被静默跳过,前端拿到的是「0 个插件、0 个错误」——
/// 和「这个源本来就是空的」一模一样,没有任何线索指向"格式不对"。
pub fn parse_registry(raw: &str) -> Result<ParsedRegistry, String> {
    let v: Json = serde_json::from_str(raw).map_err(|e| format!("registry JSON 非法: {e}"))?;
    let arr = v
        .get("plugins")
        .and_then(|x| x.as_array())
        .ok_or("registry 缺少 plugins 数组")?;
    let mut out = Vec::new();
    let mut skipped = 0usize;
    for item in arr {
        match serde_json::from_value::<RegistryPlugin>(item.clone()) {
            Ok(p) if !p.id.is_empty() && !p.versions.is_empty() => out.push(p),
            _ => skipped += 1,
        }
    }
    Ok(ParsedRegistry { plugins: out, skipped })
}

/// 把多个源的插件聚合成一张列表。
///
/// **按 id 去重,官方源优先** —— 第三方源不能靠重名覆盖掉官方插件,
/// 那是最直接的一条投毒路径。同为第三方时先到先得(源的顺序即用户排的优先级)。
pub fn merge_sources(per_source: Vec<Vec<RegistryPlugin>>) -> Vec<RegistryPlugin> {
    let mut out: Vec<RegistryPlugin> = Vec::new();
    for list in per_source {
        for p in list {
            match out.iter_mut().find(|e| e.id == p.id) {
                Some(existing) => {
                    // 已有的是官方源 -> 保留;已有的是第三方而新的是官方 -> 换成官方。
                    if !existing.from_builtin && p.from_builtin {
                        *existing = p;
                    }
                }
                None => out.push(p),
            }
        }
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

/// 校验下载下来的包。registry 里声明了 sha256 就必须对上。
///
/// **声明了却对不上一律拒装**。没声明的只能放行(老源没这个字段),
/// 但 UI 要能看出来「这个包没有校验和」。
pub fn verify_package(expected_sha256: Option<&str>, bytes: &[u8]) -> Result<(), String> {
    let Some(expected) = expected_sha256.map(|s| s.trim().to_lowercase()) else {
        return Ok(());
    };
    if expected.is_empty() {
        return Ok(());
    }
    let actual = sha256_hex(bytes);
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "插件包校验失败(可能已损坏或被篡改)\n期望 {expected}\n实际 {actual}"
        ))
    }
}

/// SHA-256。用 `sha2`(仓库已因别处依赖引入)。
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plugin(id: &str, versions: &[(&str, u32)], builtin: bool) -> RegistryPlugin {
        RegistryPlugin {
            id: id.into(),
            name: id.into(),
            description: String::new(),
            author: String::new(),
            icon: None,
            category: None,
            tags: vec![],
            targets: vec![],
            permissions: vec![],
            contributes: None,
            versions: versions
                .iter()
                .map(|(v, api)| RegistryVersion {
                    version: (*v).into(),
                    api_version: *api,
                    min_app_version: None,
                    package_url: String::new(),
                    sha256: None,
                    published_at: None,
                    changelog: None,
                })
                .collect(),
            source_id: String::new(),
            source_name: String::new(),
            from_builtin: builtin,
        }
    }

    /// **不能信数组顺序**。本仓库在 GitHub Releases 上栽过同一个跟头
    /// (id/created/published 三个键的返回顺序全是反的),预览版渠道因此
    /// 永远收不到更新。这条钉的就是那个教训。
    #[test]
    fn best_version_picks_the_max_not_the_first_or_last() {
        let p = plugin("a.b", &[("1.10.0", 2), ("1.9.0", 2), ("1.2.0", 2)], true);
        assert_eq!(p.best_version(2).unwrap().version, "1.10.0", "1.10 > 1.9,不是字典序");

        let reversed = plugin("a.b", &[("0.1.0", 2), ("2.0.0", 2)], true);
        assert_eq!(reversed.best_version(2).unwrap().version, "2.0.0");
    }

    /// 宿主装不了的高 apiVersion 要被跳过,回退到能装的那一版 ——
    /// 而不是让用户看到一个点了就报错的「最新版」。
    #[test]
    fn best_version_skips_versions_the_host_cannot_load() {
        let p = plugin("a.b", &[("1.0.0", 2), ("2.0.0", 3)], true);
        assert_eq!(p.best_version(2).unwrap().version, "1.0.0");
        assert_eq!(p.best_version(3).unwrap().version, "2.0.0");
        // 一个都装不了就是 None,不能硬塞一个
        let all_new = plugin("a.b", &[("2.0.0", 9)], true);
        assert!(all_new.best_version(2).is_none());
    }

    #[test]
    fn version_compare_handles_ragged_and_garbage() {
        use std::cmp::Ordering::*;
        assert_eq!(compare_versions("1.10.0", "1.9.0"), Greater);
        assert_eq!(compare_versions("1.0", "1.0.0"), Equal, "缺段按 0 补");
        assert_eq!(compare_versions("1.0.0-beta", "1.0.0"), Equal, "预发布后缀不参与");
        assert_eq!(compare_versions("x.y.z", "0.0.0"), Equal, "写歪的版本号不该炸");
    }

    /// 第三方源不能靠重名覆盖官方插件 —— 那是最直接的一条投毒路径。
    #[test]
    fn official_source_wins_id_collisions_regardless_of_order() {
        let official = vec![plugin("com.linplayer.hello", &[("1.0.0", 2)], true)];
        let evil = vec![plugin("com.linplayer.hello", &[("9.9.9", 2)], false)];

        // 第三方先加载
        let merged = merge_sources(vec![evil.clone(), official.clone()]);
        assert_eq!(merged.len(), 1);
        assert!(merged[0].from_builtin, "官方源必须赢");
        assert_eq!(merged[0].versions[0].version, "1.0.0");

        // 官方先加载
        let merged = merge_sources(vec![official, evil]);
        assert!(merged[0].from_builtin, "顺序反过来结果也要一样");
    }

    #[test]
    fn merge_keeps_distinct_plugins_and_sorts_by_name() {
        let a = vec![plugin("z.z", &[("1.0.0", 2)], true)];
        let b = vec![plugin("a.a", &[("1.0.0", 2)], false)];
        let merged = merge_sources(vec![a, b]);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].id, "a.a", "按名字排序");
    }

    /// 声明了 sha256 就必须对上。这是 v2 唯一的包完整性防线
    /// (决策 D11:只做校验和不做签名)。
    #[test]
    fn declared_sha256_must_match() {
        let bytes = b"hello plugin package";
        let good = sha256_hex(bytes);
        assert!(verify_package(Some(&good), bytes).is_ok());
        assert!(verify_package(Some(&good.to_uppercase()), bytes).is_ok(), "大小写不该影响");
        assert!(verify_package(Some("  ".to_string().as_str()), bytes).is_ok(), "空白视为没声明");
        assert!(verify_package(None, bytes).is_ok(), "老源没这个字段,只能放行");

        let e = verify_package(Some(&"0".repeat(64)), bytes).unwrap_err();
        assert!(e.contains("校验失败"), "{e}");
        // 内容改一个字节就必须挂
        assert!(verify_package(Some(&good), b"hello plugin packagf").is_err());
    }

    #[test]
    fn sha256_matches_known_vector() {
        // 空串的 SHA-256,写死是为了防「换了实现结果全变但测试仍绿」
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    /// 一条写歪的条目不该废掉整个源。
    /// 全军覆没必须能被看见。「0 个插件 + 0 个错误」和「这个源是空的」长得一模一样,
    /// 而前者的真实原因(schema 对不上)不给出来,用户只会以为市场坏了。
    #[test]
    fn a_source_whose_entries_all_fail_reports_how_many_were_skipped() {
        // 这就是 2026-07-23 官方源的真实形状:author 是对象不是字符串。
        let v1 = r#"{"schemaVersion":1,"plugins":[
            {"id":"a.b","name":"旧插件","author":{"name":"LinPlayer"},
             "versions":[{"version":"1.0.0"}]},
            {"id":"c.d","name":"也旧","author":{"name":"LinPlayer"},
             "versions":[{"version":"1.0.0"}]}
        ]}"#;
        let r = parse_registry(v1).unwrap();
        assert!(r.plugins.is_empty(), "v1 的 author 对象在 v2 结构上必然解不出来");
        assert_eq!(r.skipped, 2, "跳了几条必须报出来,否则和空源没法区分");
    }

    #[test]
    fn one_bad_entry_does_not_kill_the_whole_registry() {
        let raw = r#"{"schemaVersion":2,"plugins":[
            {"id":"a.b","name":"好的","versions":[{"version":"1.0.0"}]},
            {"name":"缺 id","versions":[{"version":"1.0.0"}]},
            {"id":"c.d","name":"没版本","versions":[]},
            "根本不是对象",
            {"id":"e.f","name":"也好","versions":[{"version":"2.0.0"}]}
        ]}"#;
        let r = parse_registry(raw).unwrap();
        assert_eq!(r.plugins.len(), 2);
        assert_eq!(r.skipped, 3, "坏掉的三条要记账");
        assert_eq!(r.plugins[0].id, "a.b");
        assert_eq!(r.plugins[1].id, "e.f");

        // 但整体不是 registry 就该报错
        assert!(parse_registry("{}").is_err());
        assert!(parse_registry("не json").is_err());
    }
}
