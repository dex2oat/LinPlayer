// 设备间「扫码搬配置」—— 迁自 Dart common_config.dart + config_transfer.dart。
//
// 复用 Richasy/Rodel 的 CommonConfig 容器:每个账号 snake_case JSON 各自 AES-256-CBC/PKCS7
// 加密成 base64,装进 `{from,version,export_time,configs[],_key}`;容器带 `_key` → 任意实现
// 本格式的客户端免密可解。再 gzip + base64url 塞进二维码前缀 `LPSYNC1:`——全程离线,断网也能扫。
//
// 安全:混淆级——密钥随载荷分发,挡随手读明文凭据,不防提取密钥后解密(离线免密的固有取舍)。

use base64::Engine;

use crate::config::Account;

const PREFIX: &str = "LPSYNC1:";
const CLIENT_ID: &str = "LinPlayer";
const FORMAT_VERSION: &str = "1.0";

// LinPlayer 内置默认密钥(32B),与 Dart CommonConfig._builtinKey 逐字节一致。
const BUILTIN_KEY: &[u8; 32] = &[
    0x4c, 0x69, 0x6e, 0x50, 0x6c, 0x61, 0x79, 0x65, // "LinPlaye"
    0x72, 0x2d, 0x63, 0x6f, 0x6d, 0x6d, 0x6f, 0x6e, // "r-common"
    0x2d, 0x63, 0x6f, 0x6e, 0x66, 0x69, 0x67, 0x2d, // "-config-"
    0x6b, 0x65, 0x79, 0x2d, 0x76, 0x31, 0x21, 0x00, // "key-v1!\0"
];

fn b64() -> base64::engine::general_purpose::GeneralPurpose {
    base64::engine::general_purpose::STANDARD
}

// 单条配置 AES-256-CBC/PKCS7,IV=密钥前 16 字节(Richasy 约定)。
fn encrypt_config(plaintext: &str, key: &[u8; 32]) -> String {
    use aes::cipher::{BlockEncryptMut, KeyIvInit};
    type Enc = cbc::Encryptor<aes::Aes256>;
    let enc = Enc::new(key.into(), key[..16].into());
    let ct = enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(plaintext.as_bytes());
    b64().encode(ct)
}

fn decrypt_config(b64s: &str, key: &[u8; 32]) -> Option<String> {
    use aes::cipher::{BlockDecryptMut, KeyIvInit};
    type Dec = cbc::Decryptor<aes::Aes256>;
    let ct = b64().decode(b64s.trim()).ok()?;
    let dec = Dec::new(key.into(), key[..16].into());
    let pt = dec.decrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(&ct).ok()?;
    Some(String::from_utf8_lossy(&pt).to_string())
}

// Account ↔ CommonServiceConfig(snake_case)。
// CommonConfig 是跨客户端交换格式,所以通用字段(type/url/access_token…)保持原样;
// LinPlayer 独有的服务器设置(线路/备注/图标/源类型)挂在 `linplayer` 子对象里 ——
// 别的客户端读到未知键会忽略,而我们扫码搬家时不丢用户攒的线路和备注。
fn account_to_common(a: &Account) -> serde_json::Value {
    serde_json::json!({
        "type": "emby",
        "id": a.server,          // 以 server 为身份(config.upsert 按 server 去重)
        "name": a.user_name,
        "url": a.server,
        "username": a.user_name,
        "user_id": a.user_id,
        "access_token": a.token,
        "linplayer": {
            "name": a.name,
            "remark": a.remark,
            "icon_url": a.icon_url,
            "password": a.password,
            "lines": a.lines,
            "active_line": a.active_line,
            "allow_insecure_tls": a.allow_insecure_tls,
            "source_kind": a.source_kind,
            "source": a.source,
        },
    })
}

fn common_to_account(j: &serde_json::Value) -> Option<Account> {
    let server = j["url"].as_str().unwrap_or("").trim().trim_end_matches('/').to_string();
    if server.is_empty() {
        return None;
    }
    // 别家客户端导出的配置没有 `linplayer` 段,整段缺失时全部走默认值。
    let ext = &j["linplayer"];
    fn field<T: serde::de::DeserializeOwned + Default>(ext: &serde_json::Value, k: &str) -> T {
        serde_json::from_value(ext[k].clone()).unwrap_or_default()
    }
    Some(Account {
        server,
        token: j["access_token"].as_str().unwrap_or("").to_string(),
        user_id: j["user_id"].as_str().unwrap_or("").to_string(),
        user_name: j["username"].as_str().or_else(|| j["name"].as_str()).unwrap_or("").to_string(),
        name: field(ext, "name"),
        remark: field(ext, "remark"),
        icon_url: field(ext, "icon_url"),
        password: field(ext, "password"),
        lines: field(ext, "lines"),
        active_line: field(ext, "active_line"),
        allow_insecure_tls: field(ext, "allow_insecure_tls"),
        source_kind: field(ext, "source_kind"),
        source: field(ext, "source"),
    })
}

/// 构建 CommonConfig 容器(带 _key,任意客户端免密可解)。
fn build_container(accounts: &[Account], export_time_unix: u64) -> serde_json::Value {
    let configs: Vec<String> = accounts
        .iter()
        .map(|a| encrypt_config(&account_to_common(a).to_string(), BUILTIN_KEY))
        .collect();
    serde_json::json!({
        "from": CLIENT_ID,
        "version": FORMAT_VERSION,
        "export_time": export_time_unix,
        "configs": configs,
        "_key": b64().encode(BUILTIN_KEY),
    })
}

/// 解析容器为账号列表。优先用容器里的 `_key`,否则回退内置密钥;解不开的单条跳过。
fn parse_container(j: &serde_json::Value) -> Vec<Account> {
    let key: [u8; 32] = j["_key"]
        .as_str()
        .and_then(|s| b64().decode(s).ok())
        .and_then(|v| v.try_into().ok())
        .unwrap_or(*BUILTIN_KEY);
    let Some(configs) = j["configs"].as_array() else {
        return vec![];
    };
    configs
        .iter()
        .filter_map(|c| c.as_str())
        .filter_map(|c| decrypt_config(c, &key))
        .filter_map(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .filter_map(|v| common_to_account(&v))
        .collect()
}

/// 把账号列表编码成可放进二维码的字符串(LPSYNC1: + base64url(gzip(容器JSON)))。
pub fn encode(accounts: &[Account], export_time_unix: u64) -> String {
    use flate2::{write::GzEncoder, Compression};
    use std::io::Write;
    let json = build_container(accounts, export_time_unix).to_string();
    let mut gz = GzEncoder::new(Vec::new(), Compression::default());
    let _ = gz.write_all(json.as_bytes());
    let compressed = gz.finish().unwrap_or_default();
    format!(
        "{PREFIX}{}",
        base64::engine::general_purpose::URL_SAFE.encode(compressed)
    )
}

/// 解码扫到的字符串为账号列表。非本 App 载荷/损坏返回 Err。
pub fn decode(raw: &str) -> Result<Vec<Account>, String> {
    use flate2::read::GzDecoder;
    use std::io::Read;
    let s = raw.trim();
    let body = s.strip_prefix(PREFIX).ok_or("不是 LinPlayer 配置二维码")?;
    let gz = base64::engine::general_purpose::URL_SAFE
        .decode(body)
        .map_err(|_| "载荷 base64 解码失败")?;
    let mut json = String::new();
    GzDecoder::new(&gz[..])
        .read_to_string(&mut json)
        .map_err(|_| "载荷解压失败")?;
    let v: serde_json::Value = serde_json::from_str(&json).map_err(|_| "载荷 JSON 非法")?;
    Ok(parse_container(&v))
}

/// 按 server 合并:导入项覆盖同 server 的旧项,其余保留,新项追加。
pub fn merge(existing: &[Account], incoming: Vec<Account>) -> Vec<Account> {
    let incoming_ids: std::collections::HashSet<&str> =
        incoming.iter().map(|a| a.server.as_str()).collect();
    let mut out: Vec<Account> = existing
        .iter()
        .filter(|a| !incoming_ids.contains(a.server.as_str()))
        .cloned()
        .collect();
    out.extend(incoming);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ServerLine;

    fn acc(server: &str, name: &str) -> Account {
        Account {
            server: server.into(),
            token: "tok-secret".into(),
            user_id: "uid1".into(),
            user_name: name.into(),
            ..Default::default()
        }
    }

    #[test]
    fn encode_decode_roundtrip() {
        let accounts = vec![acc("https://a.example.com", "小明"), acc("https://b.example.com", "Bob")];
        let payload = encode(&accounts, 1_700_000_000);
        assert!(payload.starts_with(PREFIX));
        // 载荷里不含明文 token(已 AES 加密 + gzip)。
        assert!(!payload.contains("tok-secret"));
        let decoded = decode(&payload).unwrap();
        assert_eq!(decoded.len(), 2);
        assert_eq!(decoded[0].server, "https://a.example.com");
        assert_eq!(decoded[0].token, "tok-secret");
        assert_eq!(decoded[1].user_name, "Bob");
    }

    #[test]
    fn roundtrip_carries_linplayer_server_settings() {
        // 回归:扫码搬家必须把用户攒的线路/备注/图标/源类型一起搬走,不能只搬 token。
        let a = Account {
            name: "我的服".into(),
            remark: Some("家里那台".into()),
            icon_url: Some("https://icon".into()),
            allow_insecure_tls: true,
            active_line: 1,
            lines: vec![
                ServerLine { id: "1".into(), name: "直连".into(), url: "https://d".into(), remark: None },
                ServerLine { id: "2".into(), name: "CDN".into(), url: "https://c".into(), remark: Some("快".into()) },
            ],
            ..acc("https://a.example.com", "小明")
        };
        let decoded = decode(&encode(&[a], 1_700_000_000)).unwrap();
        let g = &decoded[0];
        assert_eq!(g.name, "我的服");
        assert_eq!(g.remark.as_deref(), Some("家里那台"));
        assert_eq!(g.icon_url.as_deref(), Some("https://icon"));
        assert!(g.allow_insecure_tls);
        assert_eq!(g.active_line, 1);
        assert_eq!(g.lines.len(), 2, "线路不能在搬家路上丢");
        assert_eq!(g.lines[1].url, "https://c");
        assert_eq!(g.lines[1].remark.as_deref(), Some("快"));
    }

    #[test]
    fn foreign_client_payload_without_linplayer_section_still_loads() {
        // 别家客户端导出的 CommonConfig 没有 linplayer 段,必须能读且全走默认值。
        let j = serde_json::json!({
            "type": "emby", "id": "x", "url": "https://foreign/",
            "name": "n", "username": "u", "user_id": "uid", "access_token": "t",
        });
        let a = common_to_account(&j).expect("别家配置必须能读进来");
        assert_eq!(a.server, "https://foreign", "尾斜杠要归一化");
        assert_eq!(a.token, "t");
        assert!(a.lines.is_empty());
        assert!(!a.allow_insecure_tls, "缺字段必须默认严格校验 TLS,不能默认放行");
        assert!(a.source_kind.is_emby());
    }

    #[test]
    fn rejects_foreign_payload() {
        assert!(decode("HELLO:whatever").is_err());
        assert!(decode("").is_err());
    }

    #[test]
    fn merge_dedups_by_server() {
        let existing = vec![acc("https://a", "old"), acc("https://c", "keep")];
        let incoming = vec![acc("https://a", "new")];
        let merged = merge(&existing, incoming);
        assert_eq!(merged.len(), 2); // a 被覆盖,c 保留
        let a = merged.iter().find(|x| x.server == "https://a").unwrap();
        assert_eq!(a.user_name, "new");
        assert!(merged.iter().any(|x| x.server == "https://c"));
    }
}
