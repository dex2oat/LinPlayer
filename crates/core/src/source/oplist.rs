// OpenList 在线令牌服务(api.oplist.org)客户端。
//
// 解决的问题:用户不是各家网盘的开发者,拿不到 AppID/AppSecret。这个服务替大家持有凭据 ——
// 用户在它的网页上点一次授权拿到 refresh_token,客户端凭此换取**各家官方 API 的 access_token**。
// 于是 OneDrive/Google Drive/Dropbox/阿里云盘 全部走官方有文档的接口,不必逆向、不怕改版。
//
// 端点形状抄自 OpenList 各 driver 的 `_refreshToken()`(drivers/{onedrive,google_drive,
// dropbox,aliyundrive_open}/util.go),三个 query 参数是硬契约,少一个就 404:
//   GET {api}/{provider}/renewapi?refresh_ui=<refresh_token>&server_use=true&driver_txt=<driver>
//
// ★ 返回的 refresh_token **会轮换**,且旧值当场作废(阿里云盘尤其严格)。
//   不回写持久化的话,重启后拿老 token 去刷 = 必失败 = 用户被迫反复重新授权。
//   回写通道见 `MediaSourceBackend::take_rotated_credentials`。
use super::{SourceError, SourceServer};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

/// 官方公共实例。国内用户可在设置里改成 `https://api.oplist.org.cn`,
/// 或自建一份(OpenListTeam/OpenList-APIPages,AGPL,可一键部署到 CF Workers)。
pub const DEFAULT_API: &str = "https://api.oplist.org";

/// 用户可覆盖的键(存在 SourceServer.extra 里)。
pub const EXTRA_API: &str = "oplist_api";
pub const EXTRA_DRIVER_TXT: &str = "oplist_driver_txt";
pub const EXTRA_REFRESH: &str = "refresh_token";

pub struct Tokens {
    pub access_token: String,
    pub refresh_token: String,
}

/// 打一次 renewapi。provider/driver_txt 见各 backend 的常量。
pub async fn renew(
    http: &reqwest::Client,
    api_base: &str,
    provider: &str,
    driver_txt: &str,
    refresh_token: &str,
) -> Result<Tokens, SourceError> {
    if refresh_token.is_empty() {
        return Err(SourceError::auth("尚未授权，请先获取令牌"));
    }
    let base = api_base.trim_end_matches('/');
    let url = format!("{base}/{provider}/renewapi");
    let resp = http
        .get(&url)
        .query(&[
            ("refresh_ui", refresh_token),
            ("server_use", "true"),
            ("driver_txt", driver_txt),
        ])
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("连接令牌服务失败({base}): {e}")))?;
    // 404 是「refresh_token 失效或 driver_txt 不匹配」的典型表现,单独给句人话。
    let status = resp.status();
    let v: Value = resp.json().await.map_err(|e| {
        if status == reqwest::StatusCode::NOT_FOUND {
            SourceError::auth("授权已失效，请重新获取令牌")
        } else {
            SourceError::msg(format!("令牌服务响应异常({status}): {e}"))
        }
    })?;
    let access = v["access_token"].as_str().unwrap_or_default().to_string();
    let refresh = v["refresh_token"].as_str().unwrap_or_default().to_string();
    if access.is_empty() || refresh.is_empty() {
        // 服务端把错因放在 text 字段,原样透出去比"未知错误"有用得多。
        let msg = v["text"].as_str().filter(|s| !s.is_empty()).unwrap_or(
            "令牌服务未返回令牌，多半是 refresh_token 已失效，请重新获取",
        );
        return Err(SourceError::auth(msg.to_string()));
    }
    Ok(Tokens { access_token: access, refresh_token: refresh })
}

/// 四个 oplist 系后端共用的令牌管理:access 缓存 + refresh 轮换 + 待落盘标记。
pub struct OplistAuth {
    provider: &'static str,
    default_driver_txt: &'static str,
    /// server.id -> access_token
    access: Mutex<HashMap<String, String>>,
    /// server.id -> 当前最新 refresh_token(含轮换后的)
    refresh: Mutex<HashMap<String, String>>,
    /// 自上次取走以来 refresh_token 变过的 server.id
    dirty: Mutex<HashSet<String>>,
}

impl OplistAuth {
    pub fn new(provider: &'static str, default_driver_txt: &'static str) -> Self {
        Self {
            provider,
            default_driver_txt,
            access: Mutex::new(HashMap::new()),
            refresh: Mutex::new(HashMap::new()),
            dirty: Mutex::new(HashSet::new()),
        }
    }

    fn api_base(&self, server: &SourceServer) -> String {
        server
            .extra
            .get(EXTRA_API)
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or(DEFAULT_API)
            .to_string()
    }

    fn driver_txt(&self, server: &SourceServer) -> String {
        server
            .extra
            .get(EXTRA_DRIVER_TXT)
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or(self.default_driver_txt)
            .to_string()
    }

    /// 当前 refresh_token:优先内存里轮换后的新值,回落存盘值(extra 或 token 字段)。
    fn current_refresh(&self, server: &SourceServer) -> String {
        if let Some(t) = self.refresh.lock().unwrap().get(&server.id) {
            if !t.is_empty() {
                return t.clone();
            }
        }
        server
            .extra
            .get(EXTRA_REFRESH)
            .cloned()
            .or_else(|| server.token.clone())
            .unwrap_or_default()
    }

    /// 取 access_token。force=true 时无视缓存强制刷新(收到 401 后调用)。
    pub async fn access_token(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        force: bool,
    ) -> Result<String, SourceError> {
        if !force {
            if let Some(a) = self.access.lock().unwrap().get(&server.id) {
                if !a.is_empty() {
                    return Ok(a.clone());
                }
            }
        }
        let old = self.current_refresh(server);
        let t = renew(
            http,
            &self.api_base(server),
            self.provider,
            &self.driver_txt(server),
            &old,
        )
        .await?;
        self.access
            .lock()
            .unwrap()
            .insert(server.id.clone(), t.access_token.clone());
        if t.refresh_token != old {
            self.refresh
                .lock()
                .unwrap()
                .insert(server.id.clone(), t.refresh_token);
            self.dirty.lock().unwrap().insert(server.id.clone());
        }
        Ok(t.access_token)
    }

    /// 轮换后待落盘的凭据。取走即清标记(值仍留在内存供本次会话继续用)。
    pub fn take_rotated(&self, server_id: &str) -> Option<HashMap<String, String>> {
        if !self.dirty.lock().unwrap().remove(server_id) {
            return None;
        }
        let t = self.refresh.lock().unwrap().get(server_id).cloned()?;
        Some(HashMap::from([(EXTRA_REFRESH.to_string(), t)]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server_with(extra: &[(&str, &str)]) -> SourceServer {
        SourceServer {
            id: "s1".into(),
            extra: extra.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            ..Default::default()
        }
    }

    /// 令牌服务地址必须可被用户覆盖 —— 官方实例挂掉/被 CF 拦 IP 时,
    /// 用户改个地址(自建或国内实例)就能活,否则四个源同时变砖且无解。
    #[test]
    fn api_base_and_driver_txt_fall_back_to_defaults_but_stay_overridable() {
        let auth = OplistAuth::new("onedrive", "onedrive_pr");
        let plain = server_with(&[]);
        assert_eq!(auth.api_base(&plain), DEFAULT_API);
        assert_eq!(auth.driver_txt(&plain), "onedrive_pr");

        let custom = server_with(&[
            (EXTRA_API, "https://api.oplist.org.cn/"),
            (EXTRA_DRIVER_TXT, "onedrive_cn"),
        ]);
        assert_eq!(auth.api_base(&custom), "https://api.oplist.org.cn/");
        assert_eq!(auth.driver_txt(&custom), "onedrive_cn");

        // 空串要当作"没填"而不是"填了空" —— 否则表单留空会把请求打到根路径。
        let blank = server_with(&[(EXTRA_API, "   "), (EXTRA_DRIVER_TXT, "")]);
        assert_eq!(auth.api_base(&blank), DEFAULT_API);
        assert_eq!(auth.driver_txt(&blank), "onedrive_pr");
    }

    /// refresh_token 的读取优先级:内存轮换值 > extra > token 字段。
    /// 顺序错了会拿早已作废的旧值去刷新,表现为"用一会儿就掉登录"。
    #[test]
    fn current_refresh_prefers_rotated_value_over_stored() {
        let auth = OplistAuth::new("alicloud", "alicloud_qr");
        let mut s = server_with(&[(EXTRA_REFRESH, "stored-token")]);
        assert_eq!(auth.current_refresh(&s), "stored-token");

        auth.refresh.lock().unwrap().insert("s1".into(), "rotated-token".into());
        assert_eq!(auth.current_refresh(&s), "rotated-token");

        // extra 缺失时回落 token 字段(账密型表单把令牌填在这)。
        s.extra.clear();
        auth.refresh.lock().unwrap().clear();
        s.token = Some("legacy-token".into());
        assert_eq!(auth.current_refresh(&s), "legacy-token");
    }

    /// 轮换标记只在真的变了之后置位,且取走一次就清 —— 每次调用都返回 Some
    /// 会让上层每个请求都写一次配置文件。
    #[test]
    fn rotated_credentials_are_reported_once_per_change() {
        let auth = OplistAuth::new("dropbox", "dropboxs_go");
        assert_eq!(auth.take_rotated("s1"), None, "没变过不该报");

        auth.refresh.lock().unwrap().insert("s1".into(), "new".into());
        auth.dirty.lock().unwrap().insert("s1".into());
        assert_eq!(
            auth.take_rotated("s1"),
            Some(HashMap::from([(EXTRA_REFRESH.to_string(), "new".to_string())]))
        );
        assert_eq!(auth.take_rotated("s1"), None, "取走后不该重复报");
        // 值本身要留着,本次会话后续请求还得用它。
        assert_eq!(auth.refresh.lock().unwrap().get("s1").unwrap(), "new");
    }
}
