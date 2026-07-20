use std::path::Path;

fn main() {
    /* 版本的唯一权威是 tauri.conf.json(见 apps/README.md)。CARGO_PKG_VERSION 读的是
       Cargo.toml,两者没有任何同步机制 —— 用错了会让「检查更新」拿一个假的当前版本去比,
       表现为永远提示有新版或永远说已是最新,都不报错。 */
    let manifest = env!("CARGO_MANIFEST_DIR");
    let conf_path = Path::new(manifest).join("tauri.conf.json");
    let conf: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&conf_path).expect("read tauri.conf.json"))
            .expect("parse tauri.conf.json");
    let version = conf["version"].as_str().expect("tauri.conf.json 缺 version");
    println!("cargo:rustc-env=LP_VERSION={version}");
    println!("cargo:rerun-if-changed=tauri.conf.json");

    tauri_build::build();
}
