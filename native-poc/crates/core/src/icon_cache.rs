// 服务器图标:下载 / 本地缓存 / 用户本地上传。
//
// 为什么吐 data URI 而不是本地路径:Tauri 的 assetProtocol 默认关着,前端读不了本地文件;
// 为一张几十 KB 的图去开 asset 协议 + 配 scope,不如直接把字节 base64 给它。
// ponytail: 图标就这么大;真到要缓存大图的那天再开 asset 协议。

use base64::Engine;
use std::path::PathBuf;

/// 单张图标上限。防的是「图标地址被填成一部电影的直链」这种事:
/// 不设限就会把整部片读进内存再 base64,内存直接翻三倍。
const MAX_ICON_BYTES: u64 = 4 * 1024 * 1024;

fn cache_dir() -> PathBuf {
    let d = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LinPlayer")
        .join("icons");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// server_id(是个 URL)不能直接当文件名 —— 里面有 `:` `/`,Windows 上直接建不了。
fn key_of(server_id: &str) -> String {
    server_id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

fn path_of(server_id: &str) -> PathBuf {
    cache_dir().join(key_of(server_id))
}

/// 按内容嗅探 MIME。不能信扩展名/Content-Type:Emby 的 `/Users/x/Images/Primary`
/// 不带扩展名,而有些反代会把 Content-Type 抹成 application/octet-stream,
/// 那样拼出来的 data URI 浏览器不认,图标就变成一个碎图标 —— 不报错,只是不显示。
fn sniff_mime(b: &[u8]) -> &'static str {
    match b {
        [0x89, b'P', b'N', b'G', ..] => "image/png",
        [0xFF, 0xD8, 0xFF, ..] => "image/jpeg",
        [b'G', b'I', b'F', b'8', ..] => "image/gif",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
        [0x00, 0x00, 0x01, 0x00, ..] => "image/x-icon",
        _ if b.starts_with(b"<svg") || b.starts_with(b"<?xml") => "image/svg+xml",
        _ => "image/png",
    }
}

fn to_data_uri(bytes: &[u8]) -> String {
    format!(
        "data:{};base64,{}",
        sniff_mime(bytes),
        base64::engine::general_purpose::STANDARD.encode(bytes)
    )
}

/// 取图标:缓存命中直接返回;未命中则从 `url` 下载并缓存。
/// 返回 data URI。取不到返回 Err —— 由 UI 决定回退内置图标,别在这儿假装成功返回空串。
pub async fn get(
    http: &reqwest::Client,
    server_id: &str,
    url: Option<&str>,
) -> Result<String, String> {
    let p = path_of(server_id);
    if let Ok(b) = std::fs::read(&p) {
        if !b.is_empty() {
            return Ok(to_data_uri(&b));
        }
    }
    let url = url.filter(|u| !u.trim().is_empty()).ok_or("该服务器没有图标地址")?;
    // 本地路径也走这条(用户上传后 icon_url 存的是本地路径):按文件读。
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return set_from_file(server_id, url);
    }
    let resp = http.get(url).send().await.map_err(|e| format!("下载图标失败: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("下载图标失败: HTTP {}", resp.status()));
    }
    if let Some(n) = resp.content_length() {
        if n > MAX_ICON_BYTES {
            return Err(format!("图标过大({n} 字节)"));
        }
    }
    let bytes = resp.bytes().await.map_err(|e| format!("读图标失败: {e}"))?;
    // Content-Length 可以缺席或撒谎,拿到实际字节后再判一次。
    if bytes.len() as u64 > MAX_ICON_BYTES {
        return Err(format!("图标过大({} 字节)", bytes.len()));
    }
    if bytes.is_empty() {
        return Err("图标是空文件".into());
    }
    std::fs::write(&p, &bytes).map_err(|e| format!("写图标缓存失败: {e}"))?;
    Ok(to_data_uri(&bytes))
}

/// 用户从本地挑一张图当服务器图标:拷进缓存,返回 data URI。
pub fn set_from_file(server_id: &str, file_path: &str) -> Result<String, String> {
    let meta = std::fs::metadata(file_path).map_err(|e| format!("读不到该文件: {e}"))?;
    if meta.len() > MAX_ICON_BYTES {
        return Err(format!("图片过大({} 字节),上限 4MB", meta.len()));
    }
    let bytes = std::fs::read(file_path).map_err(|e| format!("读图片失败: {e}"))?;
    if bytes.is_empty() {
        return Err("图片是空文件".into());
    }
    std::fs::write(path_of(server_id), &bytes).map_err(|e| format!("写图标缓存失败: {e}"))?;
    Ok(to_data_uri(&bytes))
}

/// 清掉某服的图标缓存(换了图标地址/用户要求重取时)。
pub fn clear(server_id: &str) {
    let _ = std::fs::remove_file(path_of(server_id));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_is_filename_safe() {
        // URL 里的 : 和 / 在 Windows 上根本建不了文件,必须先净化。
        let k = key_of("https://smart.example.com:8096/emby");
        assert!(!k.contains(':') && !k.contains('/'));
        assert_eq!(k, "https___smart_example_com_8096_emby");
    }

    #[test]
    fn different_servers_never_share_a_cache_slot() {
        assert_ne!(key_of("https://a.com"), key_of("https://b.com"));
    }

    #[test]
    fn mime_sniffed_from_bytes_not_extension() {
        assert_eq!(sniff_mime(&[0x89, b'P', b'N', b'G', 0, 0]), "image/png");
        assert_eq!(sniff_mime(&[0xFF, 0xD8, 0xFF, 0xE0]), "image/jpeg");
        assert_eq!(sniff_mime(b"GIF89a"), "image/gif");
        assert_eq!(sniff_mime(b"RIFF\0\0\0\0WEBPVP8 "), "image/webp");
        assert_eq!(sniff_mime(b"<svg xmlns=\"x\">"), "image/svg+xml");
    }

    #[test]
    fn data_uri_shape() {
        let u = to_data_uri(&[0x89, b'P', b'N', b'G', 1, 2, 3]);
        assert!(u.starts_with("data:image/png;base64,"), "拼错前缀浏览器就不认: {u}");
    }

    #[test]
    fn local_file_roundtrips_through_cache() {
        let dir = std::env::temp_dir().join(format!("lp_icon_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("pic.png");
        std::fs::write(&src, [0x89, b'P', b'N', b'G', 9, 9]).unwrap();
        let id = format!("https://icon-test-{}.example.com", std::process::id());

        let uri = set_from_file(&id, src.to_str().unwrap()).unwrap();
        assert!(uri.starts_with("data:image/png;base64,"));
        // 存进去后必须能从缓存读回同一张,否则每次开服务器页都要重下。
        assert!(path_of(&id).exists());
        clear(&id);
        assert!(!path_of(&id).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn empty_or_missing_file_is_err_not_silent_success() {
        let id = format!("https://icon-empty-{}.example.com", std::process::id());
        assert!(set_from_file(&id, "definitely/not/here.png").is_err());
        let dir = std::env::temp_dir().join(format!("lp_icon_empty_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let empty = dir.join("empty.png");
        std::fs::write(&empty, b"").unwrap();
        // 空文件必须报错:返回个 data:image/png;base64, 空串,UI 会显示成碎图标,查都没处查。
        assert!(set_from_file(&id, empty.to_str().unwrap()).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
