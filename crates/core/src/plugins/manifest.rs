//! manifest.json 解析 + 严格校验。
//!
//! **v2(apiVersion: 2)**。相对 v1 的破坏性变更:
//!   - `extends`(8 个平级扩展点) -> `contributes`(4 类 × slot),见 `contributions.rs`
//!   - 删 `runtime` 字段:v1 的 `data`/`addon` 是 iOS App Store 合规专用,苹果全线已不做
//!   - 删 `emby.credentials` / `cfproxy` 权限,加 `sources` / `sandbox`
//!   - `httpAllowedHosts` 支持 `$sourceServer` 令牌(见下)
//!
//! **不做 v1 兼容层**:官方仓库总共 8 个插件,全部重写比养两套概念便宜,
//! 而且 `emby.credentials` 这个刚删掉的攻击面会被兼容层拖回来。

use serde_json::Value;

use super::contributions::{ContributionKind, ACTION_CONTEXTS, PANEL_SLOTS};

/// 当前宿主支持的插件 API 版本。
pub const API_VERSION: u32 = 2;

/// `httpAllowedHosts` 里的运行时令牌:展开成**用户在「添加服务器」里亲手填的**
/// 那个 base_url 的 origin。
///
/// 没有它,数据源插件是废的 —— 白名单是发布期固定的,而通用数据源插件
/// (OpenList / 飞牛 / 任意自建)发布时不可能知道用户自建服务器的域名,
/// 裸 `*` 又被明确堵死(见 `state.rs` 的 `bare_star_is_not_a_wildcard`)。
pub const TOKEN_SOURCE_SERVER: &str = "$sourceServer";

/// manifest 里 `contributes` 的一条静态贡献声明。
#[derive(Clone, Debug)]
pub struct ContributionDecl {
    pub kind: ContributionKind,
    pub data: Value,
}

#[derive(Clone, Debug)]
pub struct PluginManifest {
    pub id: String,
    pub version: String,
    pub api_version: u32,
    pub name: String,
    pub author: String,
    pub description: String,
    /// 市场分类:source / ui / player / notify / tools。
    pub category: String,
    /// 适配端:pc / mobile / tv。空 = 不限。
    pub targets: Vec<String>,
    /// 入口 JS 文件名(相对插件目录),默认 main.js。
    pub main: String,
    pub permissions: Vec<String>,
    pub contributions: Vec<ContributionDecl>,
    /// HTTPS 白名单(空 = 拒绝所有出网,fail-closed)。可含 `$sourceServer` 令牌。
    pub http_allowed_hosts: Vec<String>,
    pub icon: Option<String>,
    pub homepage: Option<String>,
    pub license: Option<String>,
    pub min_app_version: Option<String>,
    /// 原始 JSON(展示/备份用)。
    pub raw: Value,
}

pub const CATEGORIES: &[&str] = &["source", "ui", "player", "notify", "tools"];
pub const TARGETS: &[&str] = &["pc", "mobile", "tv"];

fn id_valid(id: &str) -> bool {
    // 反向域名:至少一个点,仅字母数字/点/连字符/下划线,每段非空。
    let segs: Vec<&str> = id.split('.').collect();
    segs.len() >= 2
        && segs.iter().all(|s| {
            !s.is_empty()
                && s.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        })
}

fn version_valid(v: &str) -> bool {
    // 宽松语义化:major.minor.patch,允许 -/+ 后缀。
    let core = v.split(['-', '+']).next().unwrap_or("");
    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

impl PluginManifest {
    pub fn parse(json: &str) -> Result<Self, String> {
        let v: Value = serde_json::from_str(json).map_err(|e| format!("manifest JSON 非法: {e}"))?;
        Self::from_value(v)
    }

    pub fn from_value(v: Value) -> Result<Self, String> {
        let req = |field: &str| -> Result<String, String> {
            match v.get(field).and_then(|x| x.as_str()) {
                Some(s) if !s.trim().is_empty() => Ok(s.trim().to_string()),
                _ => Err(format!("缺少或非法字段: {field}")),
            }
        };

        let id = req("id")?;
        if !id_valid(&id) {
            return Err(format!("id 必须为反向域名格式(如 com.example.foo),当前: {id}"));
        }
        let version = req("version")?;
        if !version_valid(&version) {
            return Err(format!("version 必须为语义化版本(如 1.0.0),当前: {version}"));
        }
        let name = req("name")?;

        // apiVersion 门禁。缺省视为 1(v1 插件没这个字段),直接拒。
        let api_version = v.get("apiVersion").and_then(|x| x.as_u64()).unwrap_or(1) as u32;
        if api_version < API_VERSION {
            return Err(format!(
                "该插件是旧版本(apiVersion {api_version}),本应用需要 {API_VERSION};请到插件市场获取新版"
            ));
        }
        if api_version > API_VERSION {
            return Err(format!(
                "该插件需要更新的应用版本(apiVersion {api_version} > {API_VERSION});请先升级 LinPlayer"
            ));
        }

        // v1 的 runtime 字段已删除。撞上就明确告诉用户这是老插件,别让他去查 JSON 语法。
        if v.get("runtime").is_some() {
            return Err(
                "manifest 含已废弃的 runtime 字段(v1 遗留,曾用于 iOS 合规);请使用 v2 规范重新打包"
                    .to_string(),
            );
        }
        if v.get("extends").is_some() {
            return Err(
                "manifest 含已废弃的 extends 字段;v2 改用 contributes,见插件开发文档".to_string(),
            );
        }

        // permissions:字符串数组,只能是已知权限。已删除的权限单独给人话。
        let mut permissions = Vec::new();
        if let Some(pv) = v.get("permissions") {
            let arr = pv.as_array().ok_or("permissions 必须是数组")?;
            for p in arr {
                let s = p.as_str().ok_or("permissions 数组元素必须是字符串")?;
                if let Some(why) = super::permission::removed_reason(s) {
                    return Err(format!("权限「{s}」在新版本已移除:{why}"));
                }
                if !super::permission::is_known(s) {
                    return Err(format!("未知权限: {s}"));
                }
                if !permissions.iter().any(|x| x == s) {
                    permissions.push(s.to_string());
                }
            }
        }

        let category = v
            .get("category")
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| "tools".to_string());
        if !CATEGORIES.contains(&category.as_str()) {
            return Err(format!(
                "未知分类: {category}(可选 {})",
                CATEGORIES.join(" / ")
            ));
        }

        let mut targets = Vec::new();
        if let Some(tv) = v.get("targets") {
            let arr = tv.as_array().ok_or("targets 必须是数组")?;
            for t in arr {
                let s = t.as_str().ok_or("targets 数组元素必须是字符串")?.trim();
                if !TARGETS.contains(&s) {
                    return Err(format!("未知目标端: {s}(可选 {})", TARGETS.join(" / ")));
                }
                if !targets.iter().any(|x| x == s) {
                    targets.push(s.to_string());
                }
            }
        }

        // contributes:{ kind: descriptor | [descriptor,...] }
        let contributions = parse_contributions(&v, &permissions)?;

        let http_allowed_hosts = parse_allowed_hosts(&v)?;

        let opt = |f: &str| v.get(f).and_then(|x| x.as_str()).map(|s| s.trim().to_string());

        Ok(PluginManifest {
            id,
            version,
            api_version,
            name,
            author: opt("author").unwrap_or_else(|| "未知作者".to_string()),
            description: opt("description").unwrap_or_default(),
            category,
            targets,
            main: opt("main").filter(|s| !s.is_empty()).unwrap_or_else(|| "main.js".to_string()),
            permissions,
            contributions,
            http_allowed_hosts,
            icon: opt("icon"),
            homepage: opt("homepage"),
            license: opt("license"),
            min_app_version: opt("minAppVersion"),
            raw: v,
        })
    }

    /// 这个插件贡献的全部数据源 `(源id, 展示名)`。
    pub fn data_sources(&self) -> Vec<(String, String)> {
        self.contributions
            .iter()
            .filter(|c| c.kind == ContributionKind::DataSources)
            .filter_map(|c| {
                let sid = c.data.get("id")?.as_str()?.to_string();
                let name = c
                    .data
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&sid)
                    .to_string();
                Some((sid, name))
            })
            .collect()
    }

    /// 白名单里是否含 `$sourceServer` 令牌 —— 有就说明它要访问用户自己填的服务器地址,
    /// 「添加服务器」页要据此提示用户。
    pub fn wants_source_server_host(&self) -> bool {
        self.http_allowed_hosts
            .iter()
            .any(|h| h == TOKEN_SOURCE_SERVER)
    }
}

fn parse_contributions(v: &Value, permissions: &[String]) -> Result<Vec<ContributionDecl>, String> {
    let mut out = Vec::new();
    let Some(cv) = v.get("contributes") else {
        return Ok(out);
    };
    let obj = cv.as_object().ok_or("contributes 必须是对象")?;
    for (key, val) in obj {
        let kind = ContributionKind::from_id(key)
            .ok_or_else(|| format!("未知贡献点类型: {key}"))?;
        // 没声明对应权限就不许贡献 —— 否则用户在授权弹窗里看不到、却被悄悄挂上了东西。
        let need = kind.required_permission();
        if !permissions.iter().any(|p| p == need) {
            return Err(format!(
                "contributes.{key} 需要声明权限「{need}」,但 permissions 里没有"
            ));
        }
        let items = match val {
            Value::Array(a) => a.clone(),
            other => vec![other.clone()],
        };
        for item in items {
            if !item.is_object() {
                return Err(format!("contributes.{key} 的描述必须是对象"));
            }
            validate_contribution(kind, &item)?;
            out.push(ContributionDecl { kind, data: item });
        }
    }
    Ok(out)
}

fn validate_contribution(kind: ContributionKind, item: &Value) -> Result<(), String> {
    let key = kind.id();
    let id = item.get("id").and_then(|v| v.as_str()).unwrap_or("").trim();
    if id.is_empty() {
        return Err(format!("contributes.{key} 的每一条都必须有非空 id"));
    }
    match kind {
        ContributionKind::Panels => {
            let slot = item.get("slot").and_then(|v| v.as_str()).unwrap_or("");
            if !PANEL_SLOTS.contains(&slot) {
                return Err(format!(
                    "panels[{id}] 的 slot 非法: {slot:?}(可选 {})",
                    PANEL_SLOTS.join(" / ")
                ));
            }
        }
        ContributionKind::Actions => {
            // context 缺省为 global。
            let cx = item.get("context").and_then(|v| v.as_str()).unwrap_or("global");
            if !ACTION_CONTEXTS.contains(&cx) {
                return Err(format!(
                    "actions[{id}] 的 context 非法: {cx:?}(可选 {})",
                    ACTION_CONTEXTS.join(" / ")
                ));
            }
        }
        ContributionKind::SandboxViews => {
            let entry = item.get("entry").and_then(|v| v.as_str()).unwrap_or("").trim();
            if entry.is_empty() {
                return Err(format!("sandboxViews[{id}] 必须指定 entry(插件内的 html 文件)"));
            }
            // 逃生舱的 entry 是要拼进 lpplugin:// 路径的,先在这一层挡掉穿越。
            if entry.contains("..") || entry.starts_with('/') || entry.starts_with('\\') {
                return Err(format!("sandboxViews[{id}] 的 entry 必须是插件目录内的相对路径"));
            }
        }
        ContributionKind::DataSources => {
            if let Some(auth) = item.get("auth") {
                let fields = auth
                    .get("fields")
                    .and_then(|v| v.as_array())
                    .ok_or_else(|| format!("dataSources[{id}] 的 auth.fields 必须是数组"))?;
                for f in fields {
                    let fid = f.get("id").and_then(|v| v.as_str()).unwrap_or("").trim();
                    if fid.is_empty() {
                        return Err(format!("dataSources[{id}] 的 auth.fields 每项都要有 id"));
                    }
                }
            }
        }
    }
    Ok(())
}

fn parse_allowed_hosts(v: &Value) -> Result<Vec<String>, String> {
    let Some(arr) = v.get("httpAllowedHosts").and_then(|x| x.as_array()) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for e in arr {
        let s = e
            .as_str()
            .ok_or("httpAllowedHosts 数组元素必须是字符串")?
            .trim()
            .to_string();
        if s.is_empty() {
            continue;
        }
        // `$` 开头的一律当令牌:拼错的令牌不能被当成一个普通(且永远匹配不上的)域名
        // 静默放过 —— 那样插件作者会对着一个「域名不在白名单内」的报错查半天域名。
        if s.starts_with('$') && s != TOKEN_SOURCE_SERVER {
            return Err(format!(
                "httpAllowedHosts 含未知令牌: {s}(目前只支持 {TOKEN_SOURCE_SERVER})"
            ));
        }
        if !out.contains(&s) {
            out.push(s);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v2(extra: &str) -> String {
        format!(
            r#"{{"id":"com.example.foo","version":"1.0.0","apiVersion":2,"name":"Foo"{extra}}}"#
        )
    }

    #[test]
    fn parses_v2_manifest_with_contributes() {
        let m = PluginManifest::parse(&v2(
            r#","category":"source","targets":["pc","tv"],
               "permissions":["sources","extensions","http","storage"],
               "httpAllowedHosts":["$sourceServer","cdn.example.com"],
               "contributes":{
                 "dataSources":[{"id":"mysrc","name":"我的网盘",
                    "auth":{"fields":[{"id":"base_url","label":"地址","type":"url"}]}}],
                 "panels":[{"id":"stats","title":"流量","slot":"home.stats","handler":"render"}]
               }"#,
        ))
        .unwrap();
        assert_eq!(m.api_version, 2);
        assert_eq!(m.category, "source");
        assert_eq!(m.targets, vec!["pc", "tv"]);
        assert_eq!(m.contributions.len(), 2);
        assert_eq!(m.data_sources(), vec![("mysrc".to_string(), "我的网盘".to_string())]);
        assert!(m.wants_source_server_host());
    }

    /// apiVersion 是**唯一**挡住 v1 插件的闸门。缺省必须视为 1 并拒绝 ——
    /// 把「没写」当成「最新」会让所有老包直接装进来然后各种半死不活。
    #[test]
    fn api_version_gate_rejects_v1_and_future() {
        let missing = PluginManifest::parse(r#"{"id":"a.b","version":"1.0.0","name":"x"}"#);
        assert!(missing.is_err(), "缺 apiVersion 必须当 v1 拒掉");
        assert!(missing.unwrap_err().contains("旧版本"));

        let too_new = PluginManifest::parse(
            r#"{"id":"a.b","version":"1.0.0","apiVersion":99,"name":"x"}"#,
        );
        assert!(too_new.unwrap_err().contains("升级 LinPlayer"));
    }

    /// v1 的字段撞上来要给「这是老插件」而不是 JSON 语法错 ——
    /// 后者会让插件作者去查引号,查半天。
    #[test]
    fn v1_leftover_fields_get_a_pointed_error() {
        let rt = PluginManifest::parse(&v2(r#","runtime":"data""#)).unwrap_err();
        assert!(rt.contains("runtime"), "{rt}");
        let ext = PluginManifest::parse(&v2(r#","extends":{"homeStats":{"id":"a"}}"#)).unwrap_err();
        assert!(ext.contains("contributes"), "{ext}");
    }

    #[test]
    fn removed_permissions_explain_themselves() {
        let e = PluginManifest::parse(&v2(r#","permissions":["emby.credentials"]"#)).unwrap_err();
        assert!(e.contains("已移除"), "{e}");
        assert!(e.contains("设置页"), "要告诉作者改怎么做,不能只说不行: {e}");
        let e = PluginManifest::parse(&v2(r#","permissions":["cfproxy"]"#)).unwrap_err();
        assert!(e.contains("内置"), "{e}");
    }

    /// 没声明权限就不许贡献。漏了这条,插件能在用户没看见任何提示的情况下
    /// 注册数据源/沙箱视图 —— 授权弹窗就成了摆设。
    #[test]
    fn contributing_requires_the_matching_permission() {
        let e = PluginManifest::parse(&v2(
            r#","contributes":{"dataSources":[{"id":"s"}]}"#,
        ))
        .unwrap_err();
        assert!(e.contains("sources"), "{e}");

        let e = PluginManifest::parse(&v2(
            r#","permissions":["extensions"],"contributes":{"sandboxViews":[{"id":"v","entry":"ui.html"}]}"#,
        ))
        .unwrap_err();
        assert!(e.contains("sandbox"), "{e}");

        // 声明了就放行
        assert!(PluginManifest::parse(&v2(
            r#","permissions":["sandbox"],"contributes":{"sandboxViews":[{"id":"v","entry":"ui.html"}]}"#,
        ))
        .is_ok());
    }

    #[test]
    fn panel_slot_and_action_context_are_validated() {
        let e = PluginManifest::parse(&v2(
            r#","permissions":["extensions"],"contributes":{"panels":[{"id":"p","slot":"nowhere"}]}"#,
        ))
        .unwrap_err();
        assert!(e.contains("slot"), "{e}");

        let e = PluginManifest::parse(&v2(
            r#","permissions":["extensions"],"contributes":{"actions":[{"id":"a","context":"bogus"}]}"#,
        ))
        .unwrap_err();
        assert!(e.contains("context"), "{e}");

        // context 缺省 global
        assert!(PluginManifest::parse(&v2(
            r#","permissions":["extensions"],"contributes":{"actions":[{"id":"a","title":"t"}]}"#,
        ))
        .is_ok());
    }

    /// 逃生舱的 entry 会被拼进 `lpplugin://<id>/<entry>` 去读文件。
    /// 这里是**第一道**穿越防线(第二道在协议处理器里)。
    #[test]
    fn sandbox_entry_rejects_path_traversal() {
        for bad in ["../../etc/passwd", "/etc/passwd", "a/../../b", "\\windows\\x"] {
            let src = v2(&format!(
                r#","permissions":["sandbox"],"contributes":{{"sandboxViews":[{{"id":"v","entry":"{}"}}]}}"#,
                bad.replace('\\', "\\\\")
            ));
            assert!(
                PluginManifest::parse(&src).is_err(),
                "穿越路径 {bad} 不该通过 manifest 校验"
            );
        }
        assert!(PluginManifest::parse(&v2(
            r#","permissions":["sandbox"],"contributes":{"sandboxViews":[{"id":"v","entry":"ui/index.html"}]}"#,
        ))
        .is_ok());
    }

    /// 拼错的令牌必须报错,不能当成一个「永远匹配不上的域名」静默放过 ——
    /// 那样作者会对着「域名不在白名单内」去查域名,查不出来。
    #[test]
    fn unknown_allowed_host_token_is_rejected() {
        let e = PluginManifest::parse(&v2(r#","httpAllowedHosts":["$sourceserver"]"#)).unwrap_err();
        assert!(e.contains("未知令牌"), "{e}");
        assert!(PluginManifest::parse(&v2(r#","httpAllowedHosts":["$sourceServer"]"#)).is_ok());
    }

    #[test]
    fn rejects_bad_id_version_category_and_target() {
        assert!(PluginManifest::parse(r#"{"id":"nodot","version":"1.0.0","apiVersion":2,"name":"x"}"#).is_err());
        assert!(PluginManifest::parse(r#"{"id":"a.b","version":"x","apiVersion":2,"name":"x"}"#).is_err());
        assert!(PluginManifest::parse(&v2(r#","permissions":["fs"]"#)).is_err());
        assert!(PluginManifest::parse(&v2(r#","category":"bogus"#)).is_err());
        assert!(PluginManifest::parse(&v2(r#","targets":["ios"]"#)).is_err(), "苹果全线不做");
    }
}
