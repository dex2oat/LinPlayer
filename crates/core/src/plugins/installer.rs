//! 插件安装/加载:.ipk(就是 zip,含 manifest.json + main.js[+图标])解压落盘;从目录加载清单。
//! 安装目录扁平化为 `<plugins_root>/<id>/`(一插件一版本,重装即覆盖)。

use std::io::Read;
use std::path::{Path, PathBuf};

use super::manifest::PluginManifest;

pub struct InstalledPlugin {
    pub manifest: PluginManifest,
    pub dir: PathBuf,
    pub entry_path: PathBuf, // main.js 绝对路径
}

/// 从已解压目录加载(scan 用)。
pub fn load_from_dir(dir: &Path) -> Result<InstalledPlugin, String> {
    let manifest_path = dir.join("manifest.json");
    let raw = std::fs::read_to_string(&manifest_path)
        .map_err(|e| format!("读 manifest 失败: {e}"))?;
    let manifest = PluginManifest::parse(&raw)?;
    let entry_path = dir.join(&manifest.main);
    if !entry_path.exists() {
        return Err(format!("入口不存在: {}", manifest.main));
    }
    Ok(InstalledPlugin { manifest, dir: dir.to_path_buf(), entry_path })
}

/// 从 .ipk 字节安装到 plugins_root/<id>/。返回安装后的插件。
pub fn install_ipk_bytes(bytes: &[u8], plugins_root: &Path) -> Result<InstalledPlugin, String> {
    let reader = std::io::Cursor::new(bytes);
    let mut zip = zip::ZipArchive::new(reader).map_err(|e| format!("打开 .ipk 失败: {e}"))?;

    // 先取 manifest 校验 + 拿 id。
    let manifest = {
        let mut mf = zip
            .by_name("manifest.json")
            .map_err(|_| "包内缺少 manifest.json".to_string())?;
        let mut s = String::new();
        mf.read_to_string(&mut s).map_err(|e| format!("读 manifest 失败: {e}"))?;
        PluginManifest::parse(&s)?
    };

    let dest = plugins_root.join(&manifest.id);
    if dest.exists() {
        std::fs::remove_dir_all(&dest).map_err(|e| format!("清理旧版本失败: {e}"))?;
    }
    std::fs::create_dir_all(&dest).map_err(|e| format!("建插件目录失败: {e}"))?;

    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| format!("读包条目失败: {e}"))?;
        let Some(name) = entry.enclosed_name() else { continue };
        // 防 zip-slip:enclosed_name 已拒绝 `..`/绝对路径。
        let out = dest.join(&name);
        if entry.is_dir() {
            std::fs::create_dir_all(&out).map_err(|e| format!("建目录失败: {e}"))?;
        } else {
            if let Some(parent) = out.parent() {
                std::fs::create_dir_all(parent).map_err(|e| format!("建目录失败: {e}"))?;
            }
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).map_err(|e| format!("解压失败: {e}"))?;
            std::fs::write(&out, buf).map_err(|e| format!("写文件失败: {e}"))?;
        }
    }

    load_from_dir(&dest)
}

pub fn install_ipk_file(ipk_path: &Path, plugins_root: &Path) -> Result<InstalledPlugin, String> {
    let bytes = std::fs::read(ipk_path).map_err(|e| format!("读 .ipk 失败: {e}"))?;
    install_ipk_bytes(&bytes, plugins_root)
}

pub fn uninstall(dir: &Path) -> Result<(), String> {
    if dir.exists() {
        std::fs::remove_dir_all(dir).map_err(|e| format!("删除插件目录失败: {e}"))?;
    }
    Ok(())
}
