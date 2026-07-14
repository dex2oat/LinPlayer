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
pub fn dandan_app_secret() -> String {
    decrypt(option_env!("DANDAN_APP_SECRET_ENC").unwrap_or(""))
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

    #[test]
    fn garbage_decrypts_to_empty() {
        assert_eq!(decrypt("not-base64!!!"), "");
        assert_eq!(decrypt(""), "");
    }
}
