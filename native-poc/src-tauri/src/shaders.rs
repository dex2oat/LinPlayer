//! 超分/画质增强档位 → glsl shader 链。
//!
//! ## 设计口径(用户 2026-07-15 定,推翻此前所有版本)
//! 用户原话:「为什么要用还原呢?不应该是**锐化+去噪**吗」「我也需要**窗口模式下也能锐化/去噪**」,
//! 并点名参考 hooke007/mpv_PlayKit。
//!
//! **核心教训:锐化/去噪 和 放大 是两件事,别糅成一坨。**
//! 此前六档全是 Anime4K 的 CNN **放大**链,而 Anime4K 每个 CNN pass 都带门槛
//! `//!WHEN OUTPUT.w MAIN.w / 1.200 > ...` —— 输出没比源大 1.2 倍就**一帧都不跑**。
//! 于是窗口里播 1080p(输出 1770×1080 < 源 1920×1080)点什么档位都毫无变化。
//! PlayKit 的做法才是对的:**锐化归锐化(门槛是参数,任何尺寸都跑),放大归放大(才看尺寸)**:
//! ```text
//! AMD_CAS_luma_RT   //!WHEN STR            ← 参数,窗口模式照跑
//! AMD_FSR1_RCAS_RT  //!WHEN SHARP 4.0 <    ← 参数,窗口模式照跑
//! Denoise_Bilateral //!WHEN 无             ← 永远跑
//! AMD_FSR1_EASU     //!WHEN OUTPUT.w HOOKED.w 1.0 * > ...  ← 放大器,才看尺寸
//! ```
//!
//! ## 前三档必须「窗口也能用」
//! modeA/B/C 只放**不挑尺寸**的 pass。`works_at_any_size()` 从 shader 源里现算这件事
//! (不手工维护名单),`levels()` 的第三个字段声明它,并有测试钉住两者一致 ——
//! 标着「窗口可用」却全是放大 pass,就是又一次「假装开了」。
//!
//! ## 历史(别再走回头路)
//! - Restore CNN:用户 2026-07-11(a5e21885)明确否掉 —— 动态画面边缘振铃/拖影,且最吃显卡。
//!   现在他又问了一遍「为什么要用还原」。**别加回来**,有测试钉。
//! - 纯 Anime4K CNN 去噪梯子(S/M/L/VL):看着合理,实际窗口模式下全程空转。只留 VL 作壮机全屏档。
//!
//! ## 为什么把 .glsl 编进二进制
//! 绿色版是 `app.exe + libmpv-2.dll` 平铺(bundle.active=false,见 [[pc-ui-react-build]]),
//! 没有 resources 目录可用。首次用时落盘到 app data —— mpv 的 glsl-shaders 只收文件路径。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 编译期嵌入(文件名, 内容)。CAS/FSR/Denoise_Bilateral 取自 hooke007/mpv_PlayKit
/// (AMD FSR/CAS 与 Anime4K 均为 MIT)。
const FILES: &[(&str, &str)] = &[
    // —— 不挑尺寸的效果 pass(窗口模式也跑) ——
    (
        "AMD_CAS_luma_RT.glsl",
        include_str!("../shaders/AMD_CAS_luma_RT.glsl"),
    ),
    (
        "AMD_FSR1_RCAS_RT.glsl",
        include_str!("../shaders/AMD_FSR1_RCAS_RT.glsl"),
    ),
    (
        "Anime4K_Denoise_Bilateral_Mean.glsl",
        include_str!("../shaders/Anime4K_Denoise_Bilateral_Mean.glsl"),
    ),
    (
        "Anime4K_Denoise_Bilateral_Mode.glsl",
        include_str!("../shaders/Anime4K_Denoise_Bilateral_Mode.glsl"),
    ),
    // —— 放大器(要输出>源才跑) ——
    (
        "AMD_FSR1_EASU.glsl",
        include_str!("../shaders/AMD_FSR1_EASU.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
        include_str!("../shaders/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
    ),
    (
        "Anime4K_Upscale_CNN_x2_M.glsl",
        include_str!("../shaders/Anime4K_Upscale_CNN_x2_M.glsl"),
    ),
    // —— 辅助 pass(自己不产生可见效果) ——
    (
        "Anime4K_Clamp_Highlights.glsl",
        include_str!("../shaders/Anime4K_Clamp_Highlights.glsl"),
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

/// 辅助 pass:自己不产生可见效果,只服务于放大链(高光钳位 / 降回显示分辨率)。
/// 判断「这档在窗口下有没有效果」时不算数 —— 只有它们跑起来等于什么都没发生。
const HELPERS: &[&str] = &[
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
];

/// Anime4K CNN pass 的尺寸门槛:输出宽高都要 > 源的 1.2 倍。
/// shader 源里写死的是 `//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *`。
/// 有测试从嵌入的源里抠出这个数比对。
pub const WHEN_RATIO: f64 = 1.2;

fn body_of(name: &str) -> &'static str {
    FILES.iter().find(|(n, _)| *n == name).map(|(_, b)| *b).unwrap_or("")
}

/// 这个 shader 是不是「只有放大才跑」—— 直接看它的 `//!WHEN` 里有没有拿 OUTPUT 比尺寸。
/// **从源里现算,不手工维护名单**:换 shader 文件时结论自动跟着变,不会留下过期的白名单。
fn is_upscale_gated(name: &str) -> bool {
    body_of(name)
        .lines()
        .any(|l| l.starts_with("//!WHEN") && l.contains("OUTPUT."))
}

/// 这档在**任意尺寸**(含窗口模式、缩小播放)下有可见效果吗?
/// 判据:存在至少一个「非辅助、且不挑尺寸」的 pass。
///
/// ⚠️ 语义是「**有效果**」,不是「**全部 pass 都跑**」。FSR 档(modeAA/BB)在窗口下
/// EASU 放大那半会被跳过、RCAS 锐化那半照跑 → 判 true,即「退化成只锐化」。
/// 这是第一版写错的地方:我照直觉把 FSR 档标成 false,是 window_ok_flag_matches_shader_gates
/// 红了才发现 RCAS 的门槛(`//!WHEN SHARP 4.0 <`)是**参数**不是尺寸。
pub fn works_at_any_size(level: &str) -> bool {
    preset(level).is_some_and(|p| {
        p.files
            .iter()
            .any(|f| !HELPERS.contains(f) && !is_upscale_gated(f))
    })
}

/// 当前尺寸下这档会不会真的有效果。`None` = 尺寸未知(没在播),不下结论。
/// ★ 存在的理由:mpv 收下 glsl-shaders 路径 ≠ shader 会执行。
/// 2026-07-15 真机:窗口 1770×1080 播 1920×1080,六个 CNN pass 全被 //!WHEN 跳过,
/// 而 UI 还在报「超分已生效 · 挂载 6 个 shader」—— 典型的「不报错,只是静默不干活」。
pub fn will_run(level: &str, video: Option<(f64, f64)>, output: Option<(f64, f64)>) -> Option<bool> {
    if preset(level).is_none() {
        return None; // off / 未知
    }
    if works_at_any_size(level) {
        return Some(true); // 锐化/去噪档:不挑尺寸,永远有效果
    }
    let ((vw, vh), (ow, oh)) = (video?, output?);
    if vw <= 0.0 || vh <= 0.0 {
        return None;
    }
    Some(ow / vw > WHEN_RATIO && oh / vh > WHEN_RATIO)
}

/// 一个档位 = shader 链 + 这条链的**调好的参数**。
pub struct Preset {
    /// **顺序就是 pipeline**:先去噪(在源分辨率上最干净)→ 再放大 → 最后锐化。
    pub files: &'static [&'static str],
    /// 喂 mpv `glsl-shader-opts` 的 `K=V,K=V`。空 = 这条链没有可调参数。
    ///
    /// ⚠️ 只能写**本档 files 里真实存在**的 `//!PARAM` —— mpv 遇到不认识的参数名会
    /// 整条 opts 拒掉(于是锐化强度静默回到默认)。有测试逐档钉这件事。
    pub opts: &'static str,
}

/// 档位 → shader 链 + 参数。
/// 键名 modeA..modeAC 是历史键,与内容无关 —— 别为了「名字对得上」去改键,改了用户存的档位就丢。
///
/// ## 强度是**档位设计的一部分**,不是用户的活(用户 2026-07-15 定)
/// 原话:「强度不是靠用户调的 是让你设计挡位的 我说看不太出来 你就把各个档位都调高不就好了吗
/// 用户又不会调」。此前我加了个 0~100 的 stepper 让用户自己找甜点 —— 那是把设计责任外包给用户。
/// 现在每档的参数**在这里调死**,梯度由档位名承诺(轻/推荐/强),UI 上没有任何数字可拧。
///
/// 参数怎么来的(别拍脑袋改,先看这段):
/// - `STR`(CAS,0.0~1.0,**越大越锐**):shader 默认 0.5 = 只开一半,就是「看不太出来」的根因。
///   代码 `peak = -1.0 / mix(8.0, 5.0, STR)`。0 = 不跑(`//!WHEN STR`)。
/// - `SHARP`(RCAS,0.0~4.0,**越小越锐**):代码 `sharp = exp2(-SHARP)`,默认 0.2 本就接近最锐,
///   所以放大档的提升空间不在这儿。4.0 = 不跑(`//!WHEN SHARP 4.0 <`)。
fn preset(level: &str) -> Option<Preset> {
    Some(match level {
        // ——— 窗口模式也生效(不挑尺寸) ———
        // 「轻」也比 shader 默认(0.5)高一档:用户的基线是「默认档我看不出来」。
        "modeA" => Preset { files: &["AMD_CAS_luma_RT.glsl"], opts: "STR=0.60" },
        // Denoise_Bilateral 没有 //!PARAM,强度靠换 Mean(温和)/Mode(更狠)两个算法拉开。
        "modeB" => Preset { files: &["Anime4K_Denoise_Bilateral_Mean.glsl"], opts: "" },
        "modeC" => Preset {
            files: &["Anime4K_Denoise_Bilateral_Mode.glsl", "AMD_CAS_luma_RT.glsl"],
            opts: "STR=0.85",
        },
        // ★「强」档:CAS 挂 LUMA、RCAS 挂 MAIN(见各自 //!HOOK)—— **不同阶段,可以叠**,
        //   这是能在窗口里做出「一眼看得见」的唯一办法,两个都拉到各自最锐端。
        //   再往上没有了:STR>1 / SHARP<0 超出 //!MAXIMUM,mpv 会夹回去。
        "modeD" => Preset {
            files: &[
                "Anime4K_Denoise_Bilateral_Mode.glsl",
                "AMD_CAS_luma_RT.glsl",
                "AMD_FSR1_RCAS_RT.glsl",
            ],
            opts: "STR=1.00,SHARP=0.00",
        },
        // ——— 放大档(要输出 > 源才生效,即全屏/大窗口) ———
        // FSR1 官方链:EASU 放大 → RCAS 锐化。RCAS 门槛是参数,窗口下会退化成「只锐化」。
        "modeAA" => Preset {
            files: &["AMD_FSR1_EASU.glsl", "AMD_FSR1_RCAS_RT.glsl"],
            opts: "SHARP=0.00",
        },
        "modeBB" => Preset {
            files: &[
                "Anime4K_Denoise_Bilateral_Mode.glsl",
                "AMD_FSR1_EASU.glsl",
                "AMD_FSR1_RCAS_RT.glsl",
            ],
            opts: "SHARP=0.00",
        },
        // 唯一保留的重型 CNN 档(壮机 + 全屏)。VL 模型 143K,这才是真「超分」。
        // Anime4K CNN 没有 //!PARAM —— 权重写死在模型里,强度不可调,只能换模型大小。
        "modeAC" => Preset {
            files: &[
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
            ],
            opts: "",
        },
        _ => return None, // off / 未知 = 关
    })
}

/// UI 档位清单 `(id, 显示名, 窗口模式是否也生效)`。
/// 第三个字段直接给 UI 画「窗口可用 / 需放大」的角标 —— 让用户点之前就知道,
/// 而不是点完看不出变化再去猜。有测试钉它必须等于 works_at_any_size()。
///
/// 名字里的 轻/推荐/强 就是强度梯度的**唯一**出口 —— 参数在 preset() 里调死。
pub fn levels() -> Vec<(&'static str, &'static str, bool)> {
    vec![
        ("off", "关闭", true),
        ("modeA", "锐化 · 轻", true),
        ("modeB", "去噪 · 轻", true),
        ("modeC", "锐化+去噪 · 推荐", true),
        ("modeD", "锐化+去噪 · 强", true),
        // FSR 档:全屏放大 + 锐化;窗口下 EASU 被跳过、RCAS 照锐化 → 仍有效果,故 true。
        ("modeAA", "放大+锐化 · FSR1", true),
        ("modeBB", "放大+锐化+去噪 · FSR1", true),
        // 唯一「不放大就完全没效果」的档 —— 全链 CNN 都带尺寸门槛。
        ("modeAC", "去噪放大 · Anime4K VL · 壮机", false),
    ]
}

/// 档位 → `glsl-shader-opts` 的值。off/未知 → 空串(=清掉上一档的参数)。
pub fn shader_opts(level: &str) -> &'static str {
    preset(level).map(|p| p.opts).unwrap_or("")
}

/// 把嵌入的 shader 落盘到 dir(已存在且大小一致就跳过),返回 文件名→绝对路径。
fn ensure_files(dir: &Path) -> Result<HashMap<&'static str, PathBuf>, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("建 shader 目录失败: {e}"))?;
    let mut map = HashMap::new();
    for (name, body) in FILES {
        let p = dir.join(name);
        // 内容是编译期常量,长度一致即认为已是当前版本(避免每次起播重写)。
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

/// 档位 → 可直接喂给 mpv glsl-shaders 的绝对路径列表。off/未知 → 空列表(=关)。
pub fn shader_paths(dir: &Path, level: &str) -> Result<Vec<String>, String> {
    let Some(p) = preset(level) else {
        return Ok(vec![]);
    };
    let files = ensure_files(dir)?;
    p.files
        .iter()
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
        for (id, _, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for f in p.files {
                assert!(
                    FILES.iter().any(|(n, _)| n == f),
                    "档位 {id} 引用了未嵌入的 shader: {f}"
                );
            }
        }
    }

    /// 抠出一个 shader 里所有 `//!PARAM X` 的参数名。
    fn params_of(file: &str) -> Vec<&'static str> {
        body_of(file)
            .lines()
            .filter_map(|l| l.trim().strip_prefix("//!PARAM "))
            .map(|s| s.trim())
            .collect()
    }

    /// ★★ 本档 opts 里写的每个参数名,都必须真的存在于**本档挂载的 shader** 里。
    ///
    /// 这是新设计(强度烧进档位)唯一会静默失效的地方:mpv 遇到不认识的参数名会把
    /// **整条 glsl-shader-opts 拒掉** —— 于是锐化悄悄回到默认 STR=0.5,正是用户
    /// 「看不太出来」的那个状态,而且不报错。
    /// 典型踩法:给只挂 CAS 的 modeA 写上 `SHARP=0`(RCAS 根本没加载)。
    #[test]
    fn every_preset_opt_names_a_param_that_this_preset_loads() {
        for (id, label, _) in levels() {
            let Some(p) = preset(id) else { continue };
            let available: Vec<&str> = p.files.iter().flat_map(|f| params_of(f)).collect();
            for kv in p.opts.split(',').filter(|s| !s.is_empty()) {
                let key = kv.split('=').next().unwrap().trim();
                assert!(
                    available.contains(&key),
                    "档位 {id}({label}) 的 opts 设了 {key},但它挂的 shader {:?} 里没有 //!PARAM {key} —— \
                     mpv 会拒掉整条 opts,强度静默回默认",
                    p.files
                );
            }
        }
    }

    /// 每档的参数值必须落在 shader 声明的 //!MINIMUM~//!MAXIMUM 内,且**不等于「不跑」的那个端点**。
    /// 防的是:手滑把 modeD 写成 SHARP=4.0 → `//!WHEN SHARP 4.0 <` 为假 → 这档最猛的那个 pass
    /// 一帧都不跑,UI 还显示「强」。
    #[test]
    fn preset_opt_values_are_in_range_and_actually_run() {
        let dead = [("STR", 0.0), ("SHARP", 4.0)]; // 各自 //!WHEN 为假的值
        for (id, label, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for kv in p.opts.split(',').filter(|s| !s.is_empty()) {
                let (key, val) = kv.split_once('=').expect("opts 必须是 K=V");
                let v: f64 = val.parse().unwrap_or_else(|_| panic!("{id} 的 {kv} 不是数字"));
                assert!((0.0..=4.0).contains(&v), "{id}({label}) 的 {kv} 超出任何已知参数范围");
                if let Some((_, d)) = dead.iter().find(|(k, _)| *k == key) {
                    assert!(
                        (v - d).abs() > 1e-9,
                        "{id}({label}) 把 {key} 设成了 {v} —— 那正是它 //!WHEN 为假的值,这个 pass 一帧都不会跑"
                    );
                }
            }
        }
    }

    /// 强度梯度必须真的**单调递增**:轻 < 推荐 < 强。
    /// 用户的原话是「你就把各个档位都调高不就好了吗」—— 光有档位名没有梯度就是骗人。
    /// 注意 CAS 的 STR 越大越锐,所以这里比的是 STR 本身。
    #[test]
    fn sharpen_ladder_is_monotonic_and_above_shader_default() {
        let str_of = |id: &str| -> f64 {
            preset(id)
                .unwrap()
                .opts
                .split(',')
                .find_map(|kv| kv.strip_prefix("STR="))
                .unwrap_or_else(|| panic!("{id} 没设 STR"))
                .parse()
                .unwrap()
        };
        let (light, rec, strong) = (str_of("modeA"), str_of("modeC"), str_of("modeD"));
        assert!(light < rec && rec < strong, "锐化梯度必须 轻({light}) < 推荐({rec}) < 强({strong})");
        // 连最轻的一档都必须高于 shader 自带默认 0.5 —— 默认值就是用户说「看不出来」的那个。
        assert!(light > 0.5, "最轻档 STR={light} 没超过 shader 默认 0.5,等于没调");
        assert_eq!(strong, 1.0, "最强档必须顶到 //!MAXIMUM");
    }

    /// off/未知必须返回空 opts —— 否则切回「关闭」时上一档的参数还挂在 mpv 上。
    #[test]
    fn off_clears_opts() {
        assert_eq!(shader_opts("off"), "");
        assert_eq!(shader_opts("nonsense"), "");
        assert_eq!(shader_opts("modeD"), "STR=1.00,SHARP=0.00");
    }

    /// off/未知不该挂任何 shader。
    #[test]
    fn off_yields_no_shaders() {
        assert!(preset("off").is_none());
        assert!(preset("nonsense").is_none());
        assert!(preset("modeA").is_some());
    }

    /// 用户 2026-07-11(a5e21885)明确否掉 Restore:动态画面边缘振铃/拖影,且最吃显卡。
    /// 2026-07-15 他又问了一遍「为什么要用还原」。别再加回来。
    #[test]
    fn no_preset_uses_restore() {
        for (id, _, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for f in p.files {
                assert!(
                    !f.contains("Restore"),
                    "档位 {id} 挂了 Restore({f}) —— 用户两次明确不要:拖影且最吃显卡"
                );
            }
        }
    }

    /// ★ levels() 里声明的「窗口可用」必须和 shader 源里的门槛一致。
    /// 这是本文件的核心承诺:标着窗口可用却全是放大 pass = 又一次「假装开了」。
    #[test]
    fn window_ok_flag_matches_shader_gates() {
        for (id, label, claims_any_size) in levels() {
            if preset(id).is_none() {
                continue;
            }
            assert_eq!(
                claims_any_size,
                works_at_any_size(id),
                "档位 {id}({label}) 声明窗口可用={claims_any_size},但按 shader 源里的 //!WHEN 算是 {} —— \
                 要么改链路要么改声明,别让 UI 撒谎",
                works_at_any_size(id)
            );
        }
    }

    /// 用户点名要的:前三档必须在窗口模式下真有效果(锐化/去噪),一个尺寸门槛都不许有。
    #[test]
    fn first_three_levels_work_in_windowed_mode() {
        for id in ["modeA", "modeB", "modeC"] {
            assert!(works_at_any_size(id), "{id} 必须窗口模式下就能生效");
            // 缩小播放(1770×1080 窗口播 1920×1080,真机现场)也必须有效果
            assert_eq!(
                will_run(id, Some((1920.0, 1080.0)), Some((1770.0, 1080.0))),
                Some(true),
                "{id} 在真机那个窗口尺寸下必须有效果"
            );
        }
    }

    /// 放大档在窗口下确实不生效 —— 这不是 bug,是 shader 的设计,但必须如实告诉用户。
    #[test]
    fn upscale_levels_need_upscaling() {
        // 纯 CNN 档:窗口(0.92×)不跑,全屏 2560×1600(1.33×/1.48×)才跑
        assert_eq!(will_run("modeAC", Some((1920.0, 1080.0)), Some((1770.0, 1080.0))), Some(false));
        assert_eq!(will_run("modeAC", Some((1920.0, 1080.0)), Some((2560.0, 1600.0))), Some(true));
        // 只有一边过线也不行(WHEN 是 宽 AND 高)
        assert_eq!(will_run("modeAC", Some((1920.0, 1080.0)), Some((3840.0, 1080.0))), Some(false));
        // 恰好 1.2 倍:shader 用的是 `>` 不是 `>=`
        assert_eq!(will_run("modeAC", Some((1000.0, 1000.0)), Some((1200.0, 1200.0))), Some(false));
        // 没在播 / 源尺寸为 0(mpv 还没 reconfig)→ 不下结论,别除零除出 inf 说「能跑」
        assert_eq!(will_run("modeAC", None, Some((2560.0, 1600.0))), None);
        assert_eq!(will_run("modeAC", Some((0.0, 0.0)), Some((2560.0, 1600.0))), None);
        // off 不下结论
        assert_eq!(will_run("off", Some((1920.0, 1080.0)), Some((1770.0, 1080.0))), None);
    }

    /// WHEN_RATIO 必须等于 shader 源里真写的那个数,不能是我拍脑袋的常量。
    /// 只查**对 MAIN 的门槛** —— 那才是「这条链跑不跑」的总闸。故意不查 AutoDownscalePre 的
    /// `NATIVE` 区间闸(x2 管 1.2~2.0 倍、x4 管 2.4~4.0 倍),那是另一套机制。
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

    /// is_upscale_gated 是从源里现算的,先验它在已知样本上判得对(不然上面几条全是空转)。
    #[test]
    fn upscale_gate_detection_is_sane() {
        assert!(is_upscale_gated("AMD_FSR1_EASU.glsl"), "EASU 是放大器,必须判成挑尺寸");
        assert!(is_upscale_gated("Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"));
        assert!(!is_upscale_gated("AMD_CAS_luma_RT.glsl"), "CAS 的 //!WHEN STR 是参数,不挑尺寸");
        assert!(!is_upscale_gated("AMD_FSR1_RCAS_RT.glsl"), "RCAS 的 //!WHEN SHARP 是参数,不挑尺寸");
        assert!(!is_upscale_gated("Anime4K_Denoise_Bilateral_Mode.glsl"), "去噪没有 WHEN,永远跑");
        // 名字不存在时别默默返回 false 把「不挑尺寸」栽给一个不存在的文件
        assert_eq!(body_of("不存在.glsl"), "");
    }

    /// params_of 是上面两条 opts 测试的地基,先验它在已知样本上抠得对(不然那两条全是空转)。
    #[test]
    fn param_extraction_is_sane() {
        assert_eq!(params_of("AMD_CAS_luma_RT.glsl"), vec!["STR"]);
        assert!(params_of("AMD_FSR1_RCAS_RT.glsl").contains(&"SHARP"));
        assert!(params_of("Anime4K_Denoise_Bilateral_Mode.glsl").is_empty(), "去噪没有可调参数");
        assert!(params_of("AMD_FSR1_EASU.glsl").is_empty());
    }

    /// 嵌入的内容不能是空的(文件被清空/拉取失败会静默变成空串)。
    #[test]
    fn embedded_files_non_empty() {
        for (n, body) in FILES {
            assert!(body.len() > 200, "{n} 内容异常短: {}", body.len());
            assert!(body.contains("//!HOOK"), "{n} 不像个 mpv user shader(没有 //!HOOK)");
        }
    }
}
