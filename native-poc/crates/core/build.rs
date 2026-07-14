// 构建期凭据加密注入:把 GH 环境变量里的明文密钥在**编译期**加密成密文写进二进制,
// 明文永不落进产物(防 strings/反编译直接捞)。app_id 是公开标识符(X-AppId 明文发出),走明文。
//
// 注意:内置口令编译进客户端,理论上可逆——这是**混淆级**(抬高门槛),非绝对安全;
// 客户端侧签名密钥的固有天花板。要绝对安全须服务端代理签名(本项目 secret 已能内嵌即够用)。
//
// 消费的环境变量(与用户 GH workflow 一致):
//   DANDANPLAY_APP_ID(明文)/ DANDANPLAY_APP_SECRET(加密)/ TMDB_API_KEY(加密)
// 产出编译期常量:DANDAN_APP_ID / DANDAN_APP_SECRET_ENC / TMDB_API_KEY_ENC(仅非空时注入)。

use aes::cipher::{BlockEncryptMut, KeyIvInit};
use base64::Engine;

// 与运行时 secrets.rs::OBF_KEY 必须一致(AES-256-CBC/PKCS7,IV=key[0..16])。
const OBF_KEY: &[u8; 32] = b"LinPlayer-tmdb-ranking-key-v1!!!";
type Enc = cbc::Encryptor<aes::Aes256>;

fn encrypt(plain: &str) -> String {
    let enc = Enc::new(OBF_KEY.into(), OBF_KEY[..16].into());
    let ct = enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(plain.as_bytes());
    base64::engine::general_purpose::STANDARD.encode(ct)
}

fn main() {
    for k in ["DANDANPLAY_APP_ID", "DANDANPLAY_APP_SECRET", "TMDB_API_KEY"] {
        println!("cargo:rerun-if-env-changed={k}");
    }
    let app_id = std::env::var("DANDANPLAY_APP_ID").unwrap_or_default();
    let app_secret = std::env::var("DANDANPLAY_APP_SECRET").unwrap_or_default();
    let tmdb = std::env::var("TMDB_API_KEY").unwrap_or_default();

    println!("cargo:rustc-env=DANDAN_APP_ID={}", app_id.trim());
    // 仅非空才注入 -> 运行时 option_env 缺省为 None,honest 地回退「未配置」。
    if !app_secret.trim().is_empty() {
        println!("cargo:rustc-env=DANDAN_APP_SECRET_ENC={}", encrypt(app_secret.trim()));
    }
    if !tmdb.trim().is_empty() {
        println!("cargo:rustc-env=TMDB_API_KEY_ENC={}", encrypt(tmdb.trim()));
    }
}
