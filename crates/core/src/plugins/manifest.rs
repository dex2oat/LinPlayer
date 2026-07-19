//! manifest.json 解析 + 严格校验(港自 Dart plugin_manifest.dart)。
//!
//! 本 App 无 Apple 目标,故只支持 `runtime: js`;声明 data/addon 直接拒绝(那两种是 iOS
//! App Store 合规专用,见旧 SPEC §5.5)。

use serde_json::Value;

use super::extensions::ExtensionType;

/// manifest 里 `extends` 的一条静态扩展声明。
#[derive(Clone, Debug)]
pub struct ExtensionDecl {
    pub type_: ExtensionType,
    pub data: Value, // 描述对象(含 id/title/handler 名等)
}

#[derive(Clone, Debug)]
pub struct PluginManifest {
    pub id: String,
    pub version: String,
    pub name: String,
    pub author: String,
    pub description: String,
    /// 入口 JS 文件名(相对插件目录),默认 main.js。
    pub main: String,
    pub permissions: Vec<String>,
    pub extensions: Vec<ExtensionDecl>,
    /// HTTPS 白名单(空 = 拒绝所有出网,fail-closed)。
    pub http_allowed_hosts: Vec<String>,
    pub icon: Option<String>,
    pub homepage: Option<String>,
    pub min_app_version: Option<String>,
    /// 原始 JSON(展示/备份用)。
    pub raw: Value,
}

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

        // runtime:只收 js(缺省即 js)。data/addon 明确拒绝。
        if let Some(rt) = v.get("runtime").and_then(|x| x.as_str()) {
            if !rt.trim().is_empty() && rt.trim() != "js" {
                return Err(format!("本 App 仅支持 runtime: js(当前 {rt});data/addon 为 iOS 专用,不受支持"));
            }
        }

        // permissions:字符串数组,只能是已知权限。
        let mut permissions = Vec::new();
        if let Some(pv) = v.get("permissions") {
            let arr = pv.as_array().ok_or("permissions 必须是数组")?;
            for p in arr {
                let s = p.as_str().ok_or("permissions 数组元素必须是字符串")?;
                if !super::permission::is_known(s) {
                    return Err(format!("未知权限: {s}"));
                }
                if !permissions.iter().any(|x| x == s) {
                    permissions.push(s.to_string());
                }
            }
        }

        // extends:{ extensionType: descriptor | [descriptor,...] }
        let mut extensions = Vec::new();
        if let Some(ev) = v.get("extends") {
            let obj = ev.as_object().ok_or("extends 必须是对象")?;
            for (key, val) in obj {
                let type_ = ExtensionType::from_id(key)
                    .ok_or_else(|| format!("未知扩展点类型: {key}"))?;
                let items = match val {
                    Value::Array(a) => a.clone(),
                    other => vec![other.clone()],
                };
                for item in items {
                    if !item.is_object() {
                        return Err(format!("扩展点 {key} 的描述必须是对象"));
                    }
                    extensions.push(ExtensionDecl { type_, data: item });
                }
            }
        }

        let http_allowed_hosts = v
            .get("httpAllowedHosts")
            .and_then(|x| x.as_array())
            .map(|a| a.iter().filter_map(|e| e.as_str().map(|s| s.to_string())).collect())
            .unwrap_or_default();

        let opt = |f: &str| v.get(f).and_then(|x| x.as_str()).map(|s| s.trim().to_string());

        Ok(PluginManifest {
            id,
            version,
            name,
            author: opt("author").unwrap_or_else(|| "未知作者".to_string()),
            description: opt("description").unwrap_or_default(),
            main: opt("main").filter(|s| !s.is_empty()).unwrap_or_else(|| "main.js".to_string()),
            permissions,
            extensions,
            http_allowed_hosts,
            icon: opt("icon"),
            homepage: opt("homepage"),
            min_app_version: opt("minAppVersion"),
            raw: v,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hello_manifest() {
        let m = PluginManifest::parse(
            r#"{"id":"com.linplayer.hello","version":"1.0.0","name":"Hello",
                "permissions":["ui","storage","extensions"],
                "extends":{"settingsPages":[{"id":"settings","title":"设置","handler":"openSettings"}]}}"#,
        )
        .unwrap();
        assert_eq!(m.id, "com.linplayer.hello");
        assert_eq!(m.permissions.len(), 3);
        assert_eq!(m.extensions.len(), 1);
        assert_eq!(m.extensions[0].type_, ExtensionType::SettingsPages);
    }

    #[test]
    fn rejects_bad_id_and_unknown_perm_and_data_runtime() {
        assert!(PluginManifest::parse(r#"{"id":"nodot","version":"1.0.0","name":"x"}"#).is_err());
        assert!(PluginManifest::parse(r#"{"id":"a.b","version":"x","name":"x"}"#).is_err());
        assert!(PluginManifest::parse(
            r#"{"id":"a.b","version":"1.0.0","name":"x","permissions":["fs"]}"#
        )
        .is_err());
        assert!(PluginManifest::parse(
            r#"{"id":"a.b","version":"1.0.0","name":"x","runtime":"data"}"#
        )
        .is_err());
    }
}
