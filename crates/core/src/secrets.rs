// 编译期注入凭据的运行时解密。build.rs 用内置口令 AES-256-CBC 加密后注入密文,这里解回。
// 明文密钥不在二进制里(只有密文 + 混淆口令);混淆级安全,详见 build.rs 说明。
//
// 弹弹Play 官方签名(base64(sha256(AppId+Timestamp+Path+AppSecret)))与 TMDB 榜共用这套凭据。

use base64::Engine;

// 与 build.rs::OBF_KEY 必须逐字节一致。
const OBF_KEY: &[u8; 32] = b"LinPlayer-tmdb-ranking-key-v1!!!";

fn decrypt(enc: &str) -> String {
    let enc = enc.trim();
    if enc.is_empty() {
        return String::new();
    }
    use aes::cipher::{BlockDecryptMut, KeyIvInit};
    type Dec = cbc::Decryptor<aes::Aes256>;
    let Ok(ct) = base64::engine::general_purpose::STANDARD.decode(enc) else {
        return String::new();
    };
    let dec = Dec::new(OBF_KEY.into(), OBF_KEY[..16].into());
    dec.decrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(&ct)
        .map(|p| String::from_utf8_lossy(&p).trim().to_string())
        .unwrap_or_default()
}

/// 弹弹Play 官方 AppId(公开标识符,明文注入)。
pub fn dandan_app_id() -> String {
    option_env!("DANDAN_APP_ID").unwrap_or("").trim().to_string()
}

/// 弹弹Play 官方 AppSecret(密文注入,运行时解密)。
///
/// ★★ **可能是多串换行分隔的**(同一个 AppId 配多个 Secret 做配额轮换,弹弹平台支持)。
///    签名只能用**其中一串**,把整坨 `"S1\nS2"` 拿去 sha256 必然签错。
///
///    2026-07-21 事故:GitHub Secret 里放的是两串轮换密钥,而
///    - 弹幕走 `danmaku::auth_parts`,那里有 `.split('\n').find(非空)` → 正常;
///    - 排行榜走 `dandan_creds()` → 拿到整坨直接签 → **HTTP 403,整页空白**。
///    表现极具误导性:"同一个 AppId、同一个密钥,弹幕好好的,就排行榜不行",
///    看起来像弹弹平台不给排行榜权限,实际是我们自己少了一次拆分。
///    定位手法:比对两个构建里密文串的**长度**(AES-CBC 密文长度暴露明文长度),
///    本地 64 字符密文(32 字符明文=一串)vs CI 约 108 字符(≈65 字符明文=两串)。
///
///    拆分放在这里而不是各调用点:调用方只该关心"给我一个能用的密钥"。
///    danmaku 那边的 split 保留着也无害(对单串是恒等变换)。
fn first_secret(raw: &str) -> String {
    raw.split('\n').map(str::trim).find(|s| !s.is_empty()).unwrap_or("").to_string()
}

pub fn dandan_app_secret() -> String {
    first_secret(&decrypt(option_env!("DANDAN_APP_SECRET_ENC").unwrap_or("")))
}

/// 官方凭据齐备则返回 (app_id, app_secret);缺任一 → None(未配置)。
pub fn dandan_creds() -> Option<(String, String)> {
    let (id, secret) = (dandan_app_id(), dandan_app_secret());
    if id.is_empty() || secret.is_empty() {
        None
    } else {
        Some((id, secret))
    }
}

/// TMDB 密钥(密文注入,运行时解密)。空=未配置。
pub fn tmdb_key() -> String {
    decrypt(option_env!("TMDB_API_KEY_ENC").unwrap_or(""))
}

/// 构建期是否带了 TMDB 密文(决定是否亮影视榜)。
pub fn tmdb_configured() -> bool {
    option_env!("TMDB_API_KEY_ENC").map(|s| !s.trim().is_empty()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::{BlockEncryptMut, KeyIvInit};

    // 复刻 build.rs 的加密,验证 encrypt→decrypt 往返一致(与构建期注入同款)。
    fn encrypt(plain: &str) -> String {
        type Enc = cbc::Encryptor<aes::Aes256>;
        let enc = Enc::new(OBF_KEY.into(), OBF_KEY[..16].into());
        let ct = enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(plain.as_bytes());
        base64::engine::general_purpose::STANDARD.encode(ct)
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        for s in ["", "abc123", "很长的密钥DANDAN_SECRET_🔑", "a".repeat(64).as_str()] {
            assert_eq!(decrypt(&encrypt(s)), s);
        }
    }

    /* 回归:多串轮换密钥必须只取第一串。
       整坨 "S1\nS2" 拿去 sha256 会签出一个谁也认不出的签名 —— 服务端回 403,
       而排行榜当时把错误吞成空数组,现象只剩"整页空白"。
       反向验证:把 dandan_app_secret 的 first_secret 去掉,本测试立刻红。 */
    #[test]
    fn multi_secret_rotation_takes_only_the_first() {
        assert_eq!(first_secret("s1\ns2"), "s1", "多串轮换必须只取第一串,否则签名必错");
        assert_eq!(first_secret("s1\r\ns2"), "s1", "CRLF 也要能拆(GH Secret 网页粘贴常带 \\r)");
        assert_eq!(first_secret("\n\n  s1  \ns2"), "s1", "前导空行/空白要跳过并 trim");
        assert_eq!(first_secret("only"), "only", "单串必须是恒等变换,不能改变现有行为");
        assert_eq!(first_secret(""), "");
        assert_eq!(first_secret("   \n  "), "");
    }

    #[test]
    fn garbage_decrypts_to_empty() {
        assert_eq!(decrypt("not-base64!!!"), "");
        assert_eq!(decrypt(""), "");
    }
}
