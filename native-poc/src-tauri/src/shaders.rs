//! Anime4K 超分档位 → glsl shader 文件。
//!
//! **档位表是用户 2026-07-11 亲自定的「纯去噪梯子」(commit a5e21885),不是官方 Mode A/B/C。**
//! 单一事实来源是 `lib/core/services/anime4k_shaders.dart`(三端共用)。抄的时候认准
//! **HEAD 版**:该 dart 在工作区有一份未提交的**回退**改动(把 Restore 梯子改了回去),
//! 照工作区抄会抄到用户已经否掉的东西 —— 本文件就这么错过一次,见下。
//!
//! ## 为什么全链路没有 Restore
//! 用户明确否掉:「Restore CNN(锐化/还原)在动态画面产生边缘振铃/拖影,**且最吃显卡**」。
//! 六档一律不含 Restore/Soft。**别加回来** —— 加回来的直接后果是真机「非常非常卡」
//! (2026-07-15 实测报障就是这个:档位表误抄成 Restore 梯子,且六档清一色 M,
//! 既有拖影又没有轻量档,标着「快速」其实一点也不快)。
//!
//! ## 梯子怎么排
//! 链路:Clamp 高光 → 去噪放大(x2) → 自动降采样回显示分辨率 →〔叠加档:二次去噪 M〕→ 收尾放大。
//! 算力从核显到壮机:单档 去噪 S / M / L;叠加档(二次去噪更净)去噪叠加 M / L / VL。
//! **档位名里的 S/M/L/VL 必须和真挂的模型对上**(用户原话:「我不知道你 Anime4K 用的什么模型」),
//! 有测试钉这条,别只改标签不改链路。
//!
//! **为什么把 .glsl 编进二进制**:绿色版是 `app.exe + libmpv-2.dll` 平铺(bundle.active=false,
//! 见 [[pc-ui-react-build]]),没有 resources 目录可用。include_str! 进去最省事,也不会因为
//! 用户改名/挪目录就找不到。首次用时落盘到 app data —— mpv 的 glsl-shaders 只收文件路径,不收内容。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 编译期嵌入(文件名, 内容)。9 个文件 ≈ 337K,与 HEAD 版 assets/mpv/shaders/ 逐一对应。
const FILES: &[(&str, &str)] = &[
    (
        "Anime4K_Clamp_Highlights.glsl",
        include_str!("../shaders/Anime4K_Clamp_Highlights.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_S.glsl",
        include_str!("../shaders/Anime4K_Upscale_Denoise_CNN_x2_S.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
        include_str!("../shaders/Anime4K_Upscale_Denoise_CNN_x2_M.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_L.glsl",
        include_str!("../shaders/Anime4K_Upscale_Denoise_CNN_x2_L.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
        include_str!("../shaders/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
    ),
    (
        "Anime4K_Upscale_CNN_x2_S.glsl",
        include_str!("../shaders/Anime4K_Upscale_CNN_x2_S.glsl"),
    ),
    (
        "Anime4K_Upscale_CNN_x2_M.glsl",
        include_str!("../shaders/Anime4K_Upscale_CNN_x2_M.glsl"),
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

/// 档位 → shader 顺序(逐字照搬 **HEAD 版** anime4k_shaders.dart 的 kAnime4KShaderPresets)。
/// 键名 modeA..modeAC 是历史键,与内容无关,别为了「名字对得上」去改键 —— 改了用户存的档位就丢了。
fn preset(level: &str) -> Option<&'static [&'static str]> {
    Some(match level {
        // 去噪 S(核显/最轻)
        "modeA" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_S.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_S.glsl",
        ],
        // 去噪 M(均衡)
        "modeB" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        // 去噪 L(清晰)
        "modeC" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_L.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        // 去噪叠加 M(M 去噪 + 二次 M 去噪,更净)
        "modeAA" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        // 去噪叠加 L(L 去噪 + 二次 M 去噪,强)
        "modeBB" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_L.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        // 去噪叠加 VL(VL 去噪 + 二次 M 去噪,壮机最强)
        "modeAC" => &[
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
        ],
        _ => return None, // off / 未知 = 关超分
    })
}

/// UI 档位清单(id, 显示名)。**逐字照搬 HEAD 版 player_screen_state.dart 的 gears**,
/// 三端同一套说法,别自己另起名(「A · 高质量」「B · 快速」是抄错表时期的产物,已作废)。
pub fn levels() -> Vec<(&'static str, &'static str)> {
    vec![
        ("off", "关闭"),
        ("modeA", "去噪 S · 核显轻量"),
        ("modeB", "去噪 M · 均衡"),
        ("modeC", "去噪 L · 清晰"),
        ("modeAA", "去噪叠加 M · 更净"),
        ("modeBB", "去噪叠加 L · 强"),
        ("modeAC", "去噪叠加 VL · 壮机"),
    ]
}

/// Anime4K 每个 pass 的触发门槛:**输出宽高都要 > 源的 1.2 倍**,否则那一 pass 整个跳过。
/// shader 源里写死的那行是:
///   `//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *`
/// 这不是我们的策略,是 Anime4K 自己的设计 —— 它是**放大器**,不放大时本就该什么都不做。
/// 有测试从嵌入的 shader 源里把这个 1.200 抠出来比对,shader 换版本改了门槛会红。
pub const WHEN_RATIO: f64 = 1.2;

/// 当前尺寸下 shader 会不会真的跑。`None` = 尺寸未知(没在播),不下结论。
/// ★ 存在的理由:mpv 收下 glsl-shaders 路径 ≠ shader 会执行。
/// 2026-07-15 真机:窗口 1770×1080 播 1920×1080,六个 pass 全被 //!WHEN 跳过,
/// 而 UI 还在报「超分已生效 · 挂载 6 个 shader」—— 典型的「不报错,只是静默不干活」。
pub fn will_run(video: Option<(f64, f64)>, output: Option<(f64, f64)>) -> Option<bool> {
    let ((vw, vh), (ow, oh)) = (video?, output?);
    if vw <= 0.0 || vh <= 0.0 {
        return None;
    }
    Some(ow / vw > WHEN_RATIO && oh / vh > WHEN_RATIO)
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

    /// 用户 2026-07-11(commit a5e21885)明确否掉 Restore:动态画面边缘振铃/拖影,且最吃显卡。
    /// 2026-07-15 这份表被误抄回 Restore 梯子 → 真机「非常非常卡」。别再加回来。
    #[test]
    fn no_preset_uses_restore() {
        for (id, _) in levels() {
            let Some(list) = preset(id) else { continue };
            for f in list {
                assert!(
                    !f.contains("Restore"),
                    "档位 {id} 挂了 Restore({f}) —— 用户明确不要:拖影且最吃显卡"
                );
            }
        }
    }

    /// 档位显示名里的 S/M/L/VL 必须就是**真挂的那个去噪模型**的规格。
    /// 用户原话:「我不知道你 Anime4K 用的什么模型」—— 名字不能和链路对不上。
    /// 抄错表那版会在这里红:那六档一个去噪放大都没有,取不到规格直接 panic。
    #[test]
    fn label_tier_matches_shader_tier() {
        for (id, label) in levels() {
            let Some(list) = preset(id) else { continue };
            // "去噪叠加 VL · 壮机" → "VL"
            let want = label
                .split('·')
                .next()
                .unwrap()
                .replace("去噪", "")
                .replace("叠加", "")
                .trim()
                .to_string();
            // 主去噪 = 链路里第一个去噪放大(叠加档的第二个恒为 M,不参与命名)。
            let got = list
                .iter()
                .find_map(|f| {
                    f.strip_prefix("Anime4K_Upscale_Denoise_CNN_x2_")
                        .and_then(|r| r.strip_suffix(".glsl"))
                })
                .unwrap_or_else(|| panic!("档位 {id}({label}) 一个去噪放大都没挂"));
            assert_eq!(want, got, "档位 {id} 标签写着 {want} 档,实际挂的是 {got} 模型");
        }
    }

    /// 叠加档 = 主去噪 + 二次去噪 M,两遍都得在(「更净」就是靠这第二遍);
    /// 单档反过来只能有一遍,否则「轻量」就不轻了。
    #[test]
    fn stacked_levels_have_second_denoise() {
        let count = |id: &str| {
            preset(id)
                .unwrap()
                .iter()
                .filter(|f| f.starts_with("Anime4K_Upscale_Denoise_CNN_x2_"))
                .count()
        };
        for id in ["modeAA", "modeBB", "modeAC"] {
            assert_eq!(count(id), 2, "叠加档 {id} 必须挂两遍去噪");
        }
        for id in ["modeA", "modeB", "modeC"] {
            assert_eq!(count(id), 1, "单档 {id} 只该挂一遍去噪");
        }
    }

    /// WHEN_RATIO 必须等于 shader 源里真写的那个数,不能是我拍脑袋的常量。
    ///
    /// 只查**对 MAIN 的门槛**(`//!WHEN OUTPUT.w MAIN.w / 1.200 > ...`)—— 那才是
    /// 「这条链到底跑不跑」的总闸,也是 will_run/提示文案依据的那个数。
    /// 故意**不查** AutoDownscalePre 的 `NATIVE` 条件:那两个是区间闸
    /// (x2 管 1.2~2.0 倍、x4 管 2.4~4.0 倍,负责把中间结果降回显示分辨率),
    /// 是另一套机制,拿 WHEN_RATIO 去套它是我第一版测试写错的地方。
    #[test]
    fn when_ratio_matches_shader_source() {
        let mut seen = 0;
        for (name, body) in FILES {
            for line in body
                .lines()
                .filter(|l| l.starts_with("//!WHEN") && l.contains("MAIN.w"))
            {
                let nums: Vec<f64> = line
                    .split_whitespace()
                    .filter_map(|t| t.parse::<f64>().ok())
                    .collect();
                assert!(!nums.is_empty(), "{name} 的 WHEN 行没解析出阈值: {line}");
                for n in nums {
                    assert!(
                        (n - WHEN_RATIO).abs() < 1e-6,
                        "{name} 的 MAIN 门槛是 {n},但 WHEN_RATIO={WHEN_RATIO} —— \
                         提示文案会报错误的数字,will_run 也会判错"
                    );
                    seen += 1;
                }
            }
        }
        assert!(seen > 0, "一个 MAIN 门槛都没扫到 —— 这条测试等于没跑,先查 shader 是不是换格式了");
    }

    /// will_run 的判据。窗口没比源大 1.2 倍 = 一帧都不跑(2026-07-15 真机就是这个数)。
    #[test]
    fn will_run_needs_output_bigger_than_source() {
        // 真机现场:1770×1080 窗口播 1920×1080 → 不跑
        assert_eq!(will_run(Some((1920.0, 1080.0)), Some((1770.0, 1080.0))), Some(false));
        // 同屏全屏 2560×1600 → 1.33×/1.48× 都过线 → 跑
        assert_eq!(will_run(Some((1920.0, 1080.0)), Some((2560.0, 1600.0))), Some(true));
        // 只有一边过线也不行(WHEN 是 宽 AND 高)
        assert_eq!(will_run(Some((1920.0, 1080.0)), Some((3840.0, 1080.0))), Some(false));
        // 恰好等于 1.2 倍:shader 用的是 `>` 不是 `>=`
        assert_eq!(will_run(Some((1000.0, 1000.0)), Some((1200.0, 1200.0))), Some(false));
        // 没在播 → 不下结论,别瞎报
        assert_eq!(will_run(None, Some((2560.0, 1600.0))), None);
        assert_eq!(will_run(Some((1920.0, 1080.0)), None), None);
        // 源尺寸是 0(mpv 还没 reconfig)→ 别除零除出 inf 说「能跑」
        assert_eq!(will_run(Some((0.0, 0.0)), Some((2560.0, 1600.0))), None);
    }

    /// 嵌入的内容不能是空的(include_str! 路径写错会静默给出空串?不会,但文件本身可能被清空)。
    #[test]
    fn embedded_files_non_empty() {
        for (n, body) in FILES {
            assert!(body.len() > 200, "{n} 内容异常短: {}", body.len());
        }
    }
}
