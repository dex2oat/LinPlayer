use std::path::Path;

fn main() {
    // 链接 libmpv(libmpv/mpv.lib)
    let manifest = env!("CARGO_MANIFEST_DIR");
    let libdir = Path::new(manifest).join("libmpv");
    println!("cargo:rustc-link-search=native={}", libdir.display());
    println!("cargo:rustc-link-lib=dylib=mpv");

    /* ★ 双显卡笔记本:把本进程钉到**独显**上。
       实测(2026-07-15,用户真机 Intel UHD + RTX 5060 Laptop):mpv 日志里
       `Device Name: Intel(R) UHD Graphics` —— Anime4K 整条 CNN 链跑在**核显**上,
       5060 全程没参与,于是「5060 超分卡」。原因是 D3D11 默认适配器在混合显卡本上
       是接显示器的那块(核显),而 LinPlayer.exe 是个新面孔,NVIDIA 驱动的程序配置库里
       没有它 → 落到默认的「集显」档。
       这两个导出符号是 NVIDIA Optimus / AMD Enduro **官方的**进程级切卡开关,
       驱动在加载时读主 exe 的导出表。比硬编码 `d3d11-adapter=NVIDIA` 好:
       不认厂商名字、单显卡机器上天然是空操作。
       ⚠️ 必须同时有 `#[used]` 的静态量(lib.rs)和这里的 /EXPORT —— Rust exe 默认
       没有导出表,只写 #[no_mangle] 驱动是看不见的,而且**不会报错,只是继续用核显**。
       改动后务必回读 mpv 日志的 `Device Name:` 确认,别默认它生效了。 */
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-arg-bins=/EXPORT:NvOptimusEnablement");
        println!("cargo:rustc-link-arg-bins=/EXPORT:AmdPowerXpressRequestHighPerformance");
    }

    // 把 libmpv-2.dll 拷到产物目录(target/<profile>/),让 exe 运行时能找到
    if let Ok(out) = std::env::var("OUT_DIR") {
        // OUT_DIR = target/<profile>/build/<pkg>/out  -> 上溯 3 层到 target/<profile>
        if let Some(profile_dir) = Path::new(&out).ancestors().nth(3) {
            let src = libdir.join("libmpv-2.dll");
            let dst = profile_dir.join("libmpv-2.dll");
            let _ = std::fs::copy(&src, &dst);
        }
    }

    tauri_build::build();
}
