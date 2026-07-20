# apps/ —— 各端宿主壳

壳只负责平台相关的事：窗口/生命周期、原生播放器（mpv）合成、把
`crates/core` 的能力注册成前端可调的命令。业务逻辑不写在这里。

| 目录 | 状态 | 说明 |
|------|------|------|
| `desktop/` | 在用 | Tauri 2 壳，Windows / Linux。前端取 `ui/desktop`，产物 `target/release/app.exe` |
| `android/` | 在用 | Android TV 壳（Tauri 2 mobile）。前端取 `dist/index-tv.html`，出 APK 见 `android/README.md`。**播放器还是桩**——仓库里没有安卓 libmpv `.so`；接的时候直接链现成的，不自建 JNI 封装 |

## desktop 的几个约定

- **版本的唯一权威是 `desktop/tauri.conf.json` 的 `version`**。`build.rs` 拿它注入
  `LP_VERSION` 给 Sentry，`vite.config.ts` 拿它做 sourcemap release，
  `scripts/pack-portable.ps1` 拿它给 zip 命名。`Cargo.toml` 的 version 不参与，
  两者没有任何同步机制。
- `desktop/libmpv/libmpv-2.dll` 是 117MB 的构建输入，不入库；CI 每次现拉
  （见 `.github/workflows/build.yml`），本地需自备。
- 数据全部落在 exe 同级的 `userdata/`（绿色包），唯一出口是 `crates/core` 的 `paths.rs`。
