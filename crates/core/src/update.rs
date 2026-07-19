/* 应用内更新:双渠道(稳定版 / 预览版)检查 + 下载 + 校验。
   移植自 Flutter 侧 lib/core/services/update/app_update_service.dart(+ update_installer.dart),
   **比较语义逐条对齐**,Dart 那边的回归用例整套搬到了本文件底部。

   两个渠道对应 CI 的两种产物(定义落在 .github/workflows/,别在别处再造一套):
   - 预览版 = build.yml 每次推 main 产出的 `v<ver>-pre` 预发布
   - 稳定版 = publish.yml 手动把某个 -pre 提升成的正式 Release(latest)

   ★ 版本比较为什么不能用标准 semver:
     CI 的版本串形如 `1.2.0-build91`,同一个 x.y.z 会出无数次预览版迭代。
     semver 会把 `1.2.0-build88` 和 `1.2.0-build91` 的核心部分都规约成 1.2.0 判等,
     于是**预览版渠道永远检测不到新版本**。所以这里按 major>minor>patch>build 逐级比,
     最后再用「同构建号下稳定版 > 预览版」表达晋升关系。 */

use std::cmp::Ordering;
use std::path::{Path, PathBuf};

const REPO: &str = "zzzwannasleep/LinPlayer";

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    /// 只收正式发布(GitHub 的 latest)。
    Stable,
    /// 尝鲜,收最新的一个非草稿发布(通常是 -pre)。
    Prerelease,
}

impl Default for UpdateChannel {
    fn default() -> Self {
        Self::Stable
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UpdateInfo {
    /// 原始 tag(如 `v1.2.0-build91-pre`)—— 比较**用它**,不是下面那个 version。
    pub tag: String,
    /// 规约成 x.y.z,只给界面显示用。
    pub version: String,
    pub name: String,
    pub notes: String,
    pub html_url: String,
    pub prerelease: bool,
    /// 本平台该下载的那个资产(挑不出来就是 None → 前端引导去网页手动下)。
    pub asset_name: Option<String>,
    pub asset_url: Option<String>,
    pub asset_size: u64,
    /// 整个发布的资产清单(name, url),下载后找校验和要用。
    #[serde(skip)]
    pub assets: Vec<(String, String)>,
}

// ---------------------------------------------------------------------------
// 版本解析与比较
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Parsed {
    major: u64,
    minor: u64,
    patch: u64,
    build: u64,
    is_pre: bool,
}

fn parse_version(raw: &str) -> Parsed {
    use regex::Regex;
    use std::sync::OnceLock;
    static CORE: OnceLock<Regex> = OnceLock::new();
    static BUILD: OnceLock<Regex> = OnceLock::new();
    static PRE: OnceLock<Regex> = OnceLock::new();

    let core = CORE.get_or_init(|| Regex::new(r"(\d+)\.(\d+)\.(\d+)").unwrap());
    let build = BUILD.get_or_init(|| Regex::new(r"(?i)-build(\d+)").unwrap());
    // `\b` 让 `-pre` 后面必须是非单词字符或结尾 —— 免得 `-preview-x` 这种被误判。
    let pre = PRE.get_or_init(|| Regex::new(r"(?i)-pre\b").unwrap());

    let (major, minor, patch) = core
        .captures(raw)
        .map(|c| {
            (
                c[1].parse().unwrap_or(0),
                c[2].parse().unwrap_or(0),
                c[3].parse().unwrap_or(0),
            )
        })
        .unwrap_or((0, 0, 0));

    Parsed {
        major,
        minor,
        patch,
        build: build
            .captures(raw)
            .and_then(|c| c[1].parse().ok())
            .unwrap_or(0),
        is_pre: pre.is_match(raw) || raw.to_lowercase().ends_with("-pre"),
    }
}

/// `a` 比 `b` 新则 Greater。两边都吃原始 tag(可带 `v` 前缀、`-buildN`、`-pre`)。
pub fn compare_versions(a: &str, b: &str) -> Ordering {
    let (pa, pb) = (parse_version(a), parse_version(b));
    pa.major
        .cmp(&pb.major)
        .then(pa.minor.cmp(&pb.minor))
        .then(pa.patch.cmp(&pb.patch))
        .then(pa.build.cmp(&pb.build))
        // 同号同构建:稳定版 > 预览版。表达「预览版晋升为正式版」这层关系,
        // 免得装了正式版的人被劝回同号的 -pre。
        .then(pb.is_pre.cmp(&pa.is_pre))
}

/* 从发布列表里挑**版本号最大**的非草稿发布,不是列表里的第一个。

   原先的实现是「取第一个」,注释理由是「GitHub 按时间倒序返回」——
   那句话是错的。2026-07-19 实测反证:
     v1.0.0-build557-pre  id=356263112  created=05:05  ← 排第 1
     v0.1.0-build566-pre  id=356398423  created=17:35  ← 排第 2
   id、created_at、published_at **三个键都是后者更大/更晚**,却排在后面;
   而 v1.0.0-build556 又落到第 7 位,连 semver 排序也不自洽。
   结论:GitHub 这个返回顺序没写进文档、也不可依赖。

   照抄列表顺序的后果是「**降级伪装成升级**」:把代码更旧、版本号更大的包当最新版
   推给用户。我们自己就有 compare_versions,发布链路的正确性不该寄托在第三方的
   返回顺序上。抽成纯函数是为了能测 —— check() 要联网,测不动。 */
fn pick_newest_release(list: &serde_json::Value) -> Option<&serde_json::Value> {
    list.as_array()?
        .iter()
        .filter(|r| r["draft"] != true)
        .max_by(|a, b| {
            compare_versions(
                a["tag_name"].as_str().unwrap_or_default(),
                b["tag_name"].as_str().unwrap_or_default(),
            )
        })
}

/// 只给界面显示,**不参与比较**(理由见文件头)。
pub fn normalize_version(raw: &str) -> String {
    let p = parse_version(raw);
    format!("{}.{}.{}", p.major, p.minor, p.patch)
}

// ---------------------------------------------------------------------------
// 网络
// ---------------------------------------------------------------------------

/* 复用共享 client,**不要**为了「安全」另建一个。
   Flutter 侧的更新器刻意避开了 App 主客户端,因为那边是全局
   `danger_accept_invalid_certs(true)`。Rust 侧不是:`http.rs:124-174` 的
   `HostAllowlistVerifier` 只对 `allow_insecure_tls` 账号的那几个 host 跳过链校验
   (白名单来源见 config.rs:481-493),别的 host 一律走 WebPkiServerVerifier。
   github.com 进不了那个白名单,所以共享 client 对 GitHub **本来就是严格的**。

   而另建一个的代价是实实在在的:共享 client 带着用户配的**代理**(http.rs:230-235)。
   GitHub 在目标市场是被墙的 —— 自建 client 等于让所有靠代理上网的用户
   更新检查必然超时,还查不出原因。

   GitHub API 强制要求 User-Agent,否则 403;而 client() 是「其它」那条 UA 口径
   (不带默认 UA,见 [[ua-policy-three-lanes]]),所以逐请求显式加。 */
fn ua() -> String {
    format!("LinPlayer/{}", crate::http::APP_VERSION)
}

async fn get_json(url: &str) -> Result<serde_json::Value, String> {
    let r = crate::http::client()
        .get(url)
        .header("User-Agent", ua())
        .header("Accept", "application/vnd.github+json")
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| format!("检查更新失败: {e}"))?;
    if !r.status().is_success() {
        // 403 基本都是未认证的限流(60 次/小时/IP)。把状态码带出去,
        // 免得用户看到笼统的「检查失败」以为是自己网的问题。
        return Err(format!("检查更新失败: GitHub 返回 {}", r.status()));
    }
    r.json().await.map_err(|e| format!("解析发布信息失败: {e}"))
}

/// 本平台要下载的资产,按**小写子串全部命中**匹配(和 Dart 侧同一套规则)。
fn asset_keywords() -> &'static [&'static str] {
    if cfg!(windows) {
        &["windows"]
    } else {
        &["linux"]
    }
}

fn pick_asset(assets: &[(String, String, u64)]) -> Option<(String, String, u64)> {
    let kw = asset_keywords();
    assets
        .iter()
        .find(|(name, _, _)| {
            let lower = name.to_lowercase();
            kw.iter().all(|k| lower.contains(k))
        })
        .cloned()
}

/// 查有没有比 `current_tag` 新的版本。
/// - `Ok(None)` = **确实**没有更新。
/// - `Err` = 没查成(断网/限流)。两者必须分开,否则「查不动」会被说成「已是最新」。
pub async fn check(
    channel: UpdateChannel,
    current_tag: &str,
) -> Result<Option<UpdateInfo>, String> {
    let base = format!("https://api.github.com/repos/{REPO}");

    let release: serde_json::Value = match channel {
        UpdateChannel::Stable => get_json(&format!("{base}/releases/latest")).await?,
        UpdateChannel::Prerelease => {
            let list = get_json(&format!("{base}/releases?per_page=10")).await?;
            /* 取**版本号最大**的那个非草稿发布,不是列表里的第一个。

               这里原先写的是「GitHub 按时间倒序返回,取第一个」—— 那句话是错的,
               2026-07-19 实测反证:v1.0.0-build557(id 356263112,created 05:05)
               排在 v0.1.0-build566(id 356398423,created 17:35)**前面** ——
               id、created_at、published_at 三个键都是后者更大/更晚。
               GitHub 对 semver 型 tag 有自己的排法且并不自洽,这个顺序不可依赖。

               照抄列表顺序的后果是「降级伪装成升级」:把一个代码更旧、版本号更大的包
               当成最新版推给用户。我们自己有 compare_versions,就该用它排,
               别把发布链路的正确性寄托在第三方一个没写进文档的返回顺序上。 */
            match pick_newest_release(&list) {
                Some(r) => r.clone(),
                None => return Ok(None),
            }
        }
    };

    let tag = release["tag_name"].as_str().unwrap_or_default().to_string();
    if tag.is_empty() {
        return Err("发布信息里没有 tag_name".into());
    }
    if compare_versions(&tag, current_tag) != Ordering::Greater {
        return Ok(None);
    }

    let all: Vec<(String, String, u64)> = release["assets"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| {
                    Some((
                        x["name"].as_str()?.to_string(),
                        x["browser_download_url"].as_str()?.to_string(),
                        x["size"].as_u64().unwrap_or(0),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();
    let picked = pick_asset(&all);

    Ok(Some(UpdateInfo {
        version: normalize_version(&tag),
        name: release["name"].as_str().unwrap_or(&tag).to_string(),
        notes: prettify_notes(release["body"].as_str().unwrap_or_default()),
        html_url: release["html_url"].as_str().unwrap_or_default().to_string(),
        prerelease: release["prerelease"] == true,
        asset_name: picked.as_ref().map(|p| p.0.clone()),
        asset_url: picked.as_ref().map(|p| p.1.clone()),
        asset_size: picked.as_ref().map(|p| p.2).unwrap_or(0),
        assets: all.into_iter().map(|(n, u, _)| (n, u)).collect(),
        tag,
    }))
}

/// GitHub Markdown → 纯文本。前端那个更新对话框不跑 Markdown 渲染器,
/// 原样贴过去满屏 `##` 和 `**`。
fn prettify_notes(body: &str) -> String {
    use regex::Regex;
    use std::sync::OnceLock;
    static LINK: OnceLock<Regex> = OnceLock::new();
    static HEAD: OnceLock<Regex> = OnceLock::new();
    static BULLET: OnceLock<Regex> = OnceLock::new();

    let link = LINK.get_or_init(|| Regex::new(r"\[([^\]]*)\]\([^)]*\)").unwrap());
    let head = HEAD.get_or_init(|| Regex::new(r"(?m)^#{1,6}\s*").unwrap());
    let bullet = BULLET.get_or_init(|| Regex::new(r"(?m)^\s*[-*+]\s+").unwrap());

    let s = link.replace_all(body, "$1");
    let s = head.replace_all(&s, "");
    let s = bullet.replace_all(&s, "• ");
    s.replace("**", "").replace("__", "").replace('`', "").trim().to_string()
}

// ---------------------------------------------------------------------------
// 下载 + 校验
// ---------------------------------------------------------------------------

/// 下载更新包到 `dir`,校验 SHA256,返回落盘路径。
/// `on_progress(已下载, 总大小)` —— 总大小为 0 表示服务端没给 Content-Length。
pub async fn download(
    info: &UpdateInfo,
    dir: &Path,
    on_progress: impl Fn(u64, u64),
) -> Result<PathBuf, String> {
    use tokio::io::AsyncWriteExt;

    let (name, url) = match (&info.asset_name, &info.asset_url) {
        (Some(n), Some(u)) => (n.clone(), u.clone()),
        _ => return Err("这个版本没有适用于当前平台的安装包".into()),
    };

    tokio::fs::create_dir_all(dir)
        .await
        .map_err(|e| format!("创建下载目录失败: {e}"))?;
    let path = dir.join(&name);
    /* 先下到 .part,校验通过才改名到最终名。
       (上次下了一半的残包必须先删 —— 追加写会拼出一个校验必然失败的文件。)
       这个纪律不是洁癖:装机器上真出现过「半个包被当成完整包」的情况,
       同仓 translation.rs:1826-1840 的模型下载也是这个形状。 */
    let part = dir.join(format!("{name}.part"));
    let _ = tokio::fs::remove_file(&part).await;
    let _ = tokio::fs::remove_file(&path).await;

    let resp = crate::http::client()
        .get(&url)
        .header("User-Agent", ua())
        .send()
        .await
        .map_err(|e| format!("下载失败: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("下载失败: 服务器返回 {}", resp.status()));
    }
    let total = resp.content_length().unwrap_or(info.asset_size);

    let mut file = tokio::fs::File::create(&part)
        .await
        .map_err(|e| format!("写入失败: {e}"))?;
    let mut got = 0u64;
    let mut resp = resp;
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("下载中断: {e}"))?
    {
        file.write_all(&chunk).await.map_err(|e| format!("写入失败: {e}"))?;
        got += chunk.len() as u64;
        on_progress(got, total);
    }
    file.flush().await.map_err(|e| format!("写入失败: {e}"))?;
    drop(file);

    /* 校验和策略和 Dart 侧一致:
       - 找得到校验和 → 对不上就是**致命**,删文件报错(这是防篡改的意义所在)。
       - 整个发布里压根没有校验和资产 → 只跳过,不报错(老版本发布没有 SHA256SUMS)。
       别把「没有校验和」升级成错误,那会让所有历史版本都装不上。 */
    if let Some(expect) = fetch_expected_sha256(info, &name).await {
        let actual = sha256_file(&part).await?;
        if !actual.eq_ignore_ascii_case(&expect) {
            let _ = tokio::fs::remove_file(&part).await;
            return Err(format!(
                "更新包校验失败(期望 {expect},实际 {actual})。已删除,请重试。"
            ));
        }
    }

    // 校验过了才转正。到这一步 path 才存在,别处就不必再判断「这包完整吗」。
    tokio::fs::rename(&part, &path)
        .await
        .map_err(|e| format!("更新包改名失败: {e}"))?;
    Ok(path)
}

/// 在发布的资产里找这个文件的 SHA256。先看 `<资产名>.sha256` 旁挂文件,
/// 再看 SHA256SUMS 这类汇总文件。取不到就返回 None(= 跳过校验)。
async fn fetch_expected_sha256(info: &UpdateInfo, asset_name: &str) -> Option<String> {
    let client = crate::http::client();
    use regex::Regex;
    use std::sync::OnceLock;
    static HEX: OnceLock<Regex> = OnceLock::new();
    let hex = HEX.get_or_init(|| Regex::new(r"\b[a-fA-F0-9]{64}\b").unwrap());

    let lower_asset = asset_name.to_lowercase();
    let sidecar = format!("{lower_asset}.sha256");

    if let Some((_, url)) = info.assets.iter().find(|(n, _)| n.to_lowercase() == sidecar) {
        let body = client.get(url).send().await.ok()?.text().await.ok()?;
        return hex.find(&body).map(|m| m.as_str().to_string());
    }

    const SUMS: [&str; 3] = ["sha256sums", "sha256sums.txt", "checksums.txt"];
    let (_, url) = info
        .assets
        .iter()
        .find(|(n, _)| SUMS.contains(&n.to_lowercase().as_str()))?;
    let body = client.get(url).send().await.ok()?.text().await.ok()?;
    body.lines()
        .find(|l| l.to_lowercase().contains(&lower_asset))
        .and_then(|l| hex.find(l).map(|m| m.as_str().to_string()))
}

async fn sha256_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use tokio::io::AsyncReadExt;

    let mut f = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("读取更新包失败: {e}"))?;
    let mut hasher = Sha256::new();
    // 更新包上百 MB,不能整个读进内存。
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).await.map_err(|e| format!("读取更新包失败: {e}"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

// ---------------------------------------------------------------------------
// 解包
// ---------------------------------------------------------------------------

/// 把更新包解到 `dest`(会先建目录)。
///
/// ★ 防 zip-slip:只信 `enclosed_name()`。它会拒绝 `../..` 和绝对路径 —— 手写
/// `dest.join(entry.name())` 会让一个恶意 zip 往 `C:\Windows` 里写文件。
/// 这里的输入虽然过了 SHA256 校验,但校验和是从同一个发布拿的,不是独立信任源;
/// 解包器该自己站得住。同仓 plugins/installer.rs:51 是同一条纪律。
pub fn extract_zip(zip_path: &Path, dest: &Path) -> Result<(), String> {
    let f = std::fs::File::open(zip_path).map_err(|e| format!("打开更新包失败: {e}"))?;
    let mut zip = zip::ZipArchive::new(f).map_err(|e| format!("更新包不是有效的 zip: {e}"))?;
    std::fs::create_dir_all(dest).map_err(|e| format!("创建解包目录失败: {e}"))?;

    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| format!("读取更新包条目失败: {e}"))?;
        let Some(rel) = entry.enclosed_name() else {
            // 越界条目直接丢弃,不是报错 —— 报错会让一个坏条目挡住整包。
            continue;
        };
        let out = dest.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&out).map_err(|e| format!("建目录失败: {e}"))?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("建目录失败: {e}"))?;
        }
        let mut w = std::fs::File::create(&out).map_err(|e| format!("写入 {} 失败: {e}", out.display()))?;
        std::io::copy(&mut entry, &mut w).map_err(|e| format!("解包 {} 失败: {e}", out.display()))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /* 预览版渠道**不能照抄 GitHub 的返回顺序**。
       下面这组数据是 2026-07-19 从真实仓库抓的原样顺序:版本号更小、发布更早的
       v1.0.0-build557 被 GitHub 排在了第一位。旧实现 `.find(第一个非草稿)` 会选中它,
       于是给装了 0.1.0-build566 的用户推一个更旧的包 —— 降级伪装成升级。

       ★ 这条测试反向验证过:把 pick_newest_release 换回 `.find(...)` 会红在
         「选中了 v1.0.0-build557」。不是永远绿的假测试。 */
    #[test]
    fn prerelease_picks_max_version_not_list_order() {
        let list = serde_json::json!([
            { "tag_name": "v1.0.0-build557-pre", "draft": false },
            { "tag_name": "v1.0.2-build566-pre", "draft": false },
            { "tag_name": "v1.0.1-build565-pre", "draft": false },
        ]);
        let got = pick_newest_release(&list).expect("应当挑得出来");
        assert_eq!(got["tag_name"], "v1.0.2-build566-pre");
    }

    /// 草稿不能参与:它还没发布,资产可能是空的。
    #[test]
    fn prerelease_skips_drafts() {
        let list = serde_json::json!([
            { "tag_name": "v9.9.9-build999-pre", "draft": true },
            { "tag_name": "v1.0.0-build557-pre", "draft": false },
        ]);
        let got = pick_newest_release(&list).expect("应当挑得出来");
        assert_eq!(got["tag_name"], "v1.0.0-build557-pre");
        assert!(pick_newest_release(&serde_json::json!([])).is_none());
    }

    fn cmp(a: &str, b: &str) -> i32 {
        match compare_versions(a, b) {
            Ordering::Greater => 1,
            Ordering::Less => -1,
            Ordering::Equal => 0,
        }
    }

    /* 下面 6 组整套搬自 Flutter 侧 test/app_update_version_compare_test.dart,
       一条不改。它们不是凑数的:第一组就是旧实现真出过的漏检 bug —— 用 semver
       规约后 1.2.0-build88 和 1.2.0-build91 判等,预览版渠道从此再没提示过更新。 */

    #[test]
    fn same_xyz_prerelease_iterations_differ_by_build_number() {
        assert_eq!(cmp("v1.2.0-build91-pre", "1.2.0-build88"), 1);
        assert_eq!(cmp("v1.2.0-build80-pre", "1.2.0-build88"), -1);
    }

    #[test]
    fn identical_including_build_is_equal() {
        assert_eq!(cmp("1.2.0-build88", "1.2.0-build88"), 0);
        assert_eq!(cmp("v1.2.0-build88", "v1.2.0-build88"), 0);
        // 远端预览版 vs 已装同号稳定版:不该把稳定版「降级」回 pre。
        assert_eq!(cmp("v1.2.0-build88-pre", "1.2.0-build88"), -1);
    }

    #[test]
    fn core_version_outranks_build_number() {
        assert_eq!(cmp("v1.3.0-build1-pre", "1.2.0-build999"), 1);
        assert_eq!(cmp("v2.0.0", "1.9.9-build999"), 1);
        assert_eq!(cmp("v1.2.1-build1", "1.2.0-build999"), 1);
    }

    #[test]
    fn stable_beats_prerelease_at_same_build() {
        assert_eq!(cmp("v1.2.0-build88", "v1.2.0-build88-pre"), 1);
        assert_eq!(cmp("v1.2.0-build88-pre", "v1.2.0-build88"), -1);
    }

    #[test]
    fn no_build_number_fallback() {
        assert_eq!(cmp("v1.2.0", "1.0.0"), 1);
        assert_eq!(cmp("v1.0.0", "1.0.0"), 0);
    }

    #[test]
    fn normalize_is_display_only() {
        assert_eq!(normalize_version("v1.2.0-build91-pre"), "1.2.0");
        assert_eq!(normalize_version("完全不是版本号"), "0.0.0");
    }

    /// 资产按「小写子串全部命中」挑。大小写和额外后缀都不能让它挑漏。
    #[test]
    fn picks_asset_for_this_platform() {
        let assets = vec![
            ("SHA256SUMS".to_string(), "u0".to_string(), 1),
            ("LinPlayer-Linux-v1.2.0.tar.gz".to_string(), "u1".to_string(), 10),
            ("LinPlayer-Windows-v1.2.0.zip".to_string(), "u2".to_string(), 20),
        ];
        let got = pick_asset(&assets).expect("本平台该挑得出资产");
        if cfg!(windows) {
            assert_eq!(got.0, "LinPlayer-Windows-v1.2.0.zip");
        } else {
            assert_eq!(got.0, "LinPlayer-Linux-v1.2.0.tar.gz");
        }
        // SHA256SUMS 这类附属文件绝不能被当成安装包挑走。
        assert_ne!(got.0, "SHA256SUMS");
    }

    /* zip-slip:构造一个条目名带 `../` 的包,解完之后 dest **之外**不能出现任何文件。
       ★ 证明过会红:把 enclosed_name() 换成 `Path::new(entry.name())`,
         逃逸文件当场出现在上级目录,断言失败。 */
    #[test]
    fn extract_refuses_to_escape_the_destination() {
        use std::io::Write;
        let tmp = std::env::temp_dir().join("lp_zipslip_test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let dest = tmp.join("dest");
        let zip_path = tmp.join("evil.zip");

        {
            let f = std::fs::File::create(&zip_path).unwrap();
            let mut w = zip::ZipWriter::new(f);
            let opts: zip::write::FileOptions<()> =
                zip::write::FileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            w.start_file("../escaped.txt", opts).unwrap();
            w.write_all(b"pwned").unwrap();
            w.start_file("LinPlayer.exe", opts).unwrap();
            w.write_all(b"ok").unwrap();
            w.finish().unwrap();
        }

        extract_zip(&zip_path, &dest).expect("正常条目应该照常解出来");

        assert!(dest.join("LinPlayer.exe").exists(), "正常条目被误伤了");
        assert!(
            !tmp.join("escaped.txt").exists(),
            "zip-slip 逃逸成功 —— 恶意包能往 dest 外面写文件"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn markdown_notes_are_flattened() {
        let raw = "## 更新内容\n- 修了 **一个** bug\n- 见 [文档](https://x.y)\n";
        let out = prettify_notes(raw);
        assert!(!out.contains('#'), "标题号没去掉: {out}");
        assert!(!out.contains("**"), "粗体标记没去掉: {out}");
        assert!(out.contains("• 修了 一个 bug"), "列表没转成圆点: {out}");
        assert!(out.contains("见 文档"), "链接没抽出文字: {out}");
        assert!(!out.contains("https://x.y"), "链接地址应该被吃掉: {out}");
    }
}
