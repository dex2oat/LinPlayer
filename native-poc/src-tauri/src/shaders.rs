//! Anime4K 超分档位 → glsl shader 文件。
//!
//! 档位映射逐字对齐旧 Flutter `lib/core/services/anime4k_shaders.dart`(那是三端
//! 共用的既定档位,别自己改顺序 —— 顺序就是 shader pipeline)。
//!
//! **为什么把 .glsl 编进二进制**:绿色版是 `app.exe + libmpv-2.dll` 平铺(bundle.active=false,
//! 见 [[pc-ui-react-build]]),没有 resources 目录可用。7 个文件共 164K,include_str! 进去
//! 最省事,也不会因为用户改名/挪目录就找不到。首次用时落盘到 app data —— mpv 的
//! glsl-shaders 只收文件路径,不收内容。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 编译期嵌入(文件名, 内容)。
const FILES: &[(&str, &str)] = &[
    (
        "Anime4K_Clamp_Highlights.glsl",
        include_str!("../shaders/Anime4K_Clamp_Highlights.glsl"),
    ),
    (
        "Anime4K_Restore_CNN_M.glsl",
        include_str!("../shaders/Anime4K_Restore_CNN_M.glsl"),
    ),
    (
        "Anime4K_Restore_CNN_Soft_M.glsl",
        include_str!("../shaders/Anime4K_Restore_CNN_Soft_M.glsl"),
    ),
    (
        "Anime4K_Upscale_CNN_x2_M.glsl",
        include_str!("../shaders/Anime4K_Upscale_CNN_x2_M.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
        include_str!("../shaders/Anime4K_Upscale_Denoise_CNN_x2_M.glsl"),
    ),
    (
        "Anime4K_AutoDownscalePre_x2.glsl",
        include_str!("../shaders/Anime4K_AutoDownscalePre_x2.glsl"),
    ),
    (
        "Anime4K_AutoDownscalePre_x4.glsl",
        include_str!("../shaders/Anime4K_AutoDownscalePre_x4.glsl"),
    ),
];

/// 档位 → shader 顺序(逐字照搬 anime4k_shaders.dart 的 kAnime4KShaderPresets)。
/// 注意 modeAA/modeBB 里同一个 shader 会出现两次 —— 那是故意的(双 Restore),别去重。
fn preset(level: &str) -> Option<&'static [&'static str]> {
    Some(match level {
        "modeA" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "modeB" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_Soft_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "modeC" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "modeAA" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
            "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "modeBB" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_Soft_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_Restore_CNN_Soft_M.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        "modeAC" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        _ => return None, // off / 未知 = 关超分
    })
}

/// UI 档位清单(id, 显示名)。顺序即草稿「更多 · 超分」面板的排列。
pub fn levels() -> Vec<(&'static str, &'static str)> {
    vec![
        ("off", "关闭"),
        ("modeA", "A · 高质量"),
        ("modeB", "B · 快速"),
        ("modeC", "C · 去噪"),
        ("modeAA", "A+A · 极致"),
        ("modeBB", "B+B · 均衡"),
        ("modeAC", "C+A · 去噪+"),
    ]
}

/// 把嵌入的 shader 落盘到 dir(已存在且大小一致就跳过),返回 文件名→绝对路径。
fn ensure_files(dir: &Path) -> Result<HashMap<&'static str, PathBuf>, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("建 shader 目录失败: {e}"))?;
    let mut map = HashMap::new();
    for (name, body) in FILES {
        let p = dir.join(name);
        // 内容是编译期常量,长度一致即认为已是当前版本(避免每次起播重写 7 个文件)。
        let fresh = std::fs::metadata(&p)
            .map(|m| m.len() == body.len() as u64)
            .unwrap_or(false);
        if !fresh {
            std::fs::write(&p, body).map_err(|e| format!("写 {name} 失败: {e}"))?;
        }
        map.insert(*name, p);
    }
    Ok(map)
}

/// 档位 → 可直接喂给 mpv glsl-shaders 的绝对路径列表。off/未知 → 空列表(=关超分)。
pub fn shader_paths(dir: &Path, level: &str) -> Result<Vec<String>, String> {
    let Some(list) = preset(level) else {
        return Ok(vec![]);
    };
    let files = ensure_files(dir)?;
    list.iter()
        .map(|n| {
            files
                .get(n)
                .map(|p| p.to_string_lossy().into_owned())
                .ok_or_else(|| format!("缺少 shader: {n}"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 档位表里引用的每个文件都必须真的嵌进来了 —— 否则运行时才炸(超分点了没反应)。
    #[test]
    fn every_preset_file_is_embedded() {
        for (id, _) in levels() {
            let Some(list) = preset(id) else { continue };
            for f in list {
                assert!(
                    FILES.iter().any(|(n, _)| n == f),
                    "档位 {id} 引用了未嵌入的 shader: {f}"
                );
            }
        }
    }

    /// off/未知不该挂任何 shader。
    #[test]
    fn off_yields_no_shaders() {
        assert!(preset("off").is_none());
        assert!(preset("nonsense").is_none());
        assert!(preset("modeA").is_some());
    }

    /// modeAA 是双 Restore:同名 shader 出现两次是特性,别被"去重优化"掉。
    #[test]
    fn double_restore_keeps_duplicate() {
        let list = preset("modeAA").unwrap();
        let n = list.iter().filter(|f| **f == "Anime4K_Restore_CNN_M.glsl").count();
        assert_eq!(n, 2, "modeAA 必须挂两遍 Restore");
    }

    /// 嵌入的内容不能是空的(include_str! 路径写错会静默给出空串?不会,但文件本身可能被清空)。
    #[test]
    fn embedded_files_non_empty() {
        for (n, body) in FILES {
            assert!(body.len() > 200, "{n} 内容异常短: {}", body.len());
        }
    }
}
