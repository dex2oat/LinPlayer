# apps/android —— Android TV 宿主壳

Tauri 2 mobile 壳,产物是能装在 Android TV 上的 APK。前端取 `dist/index-tv.html`
(vite 多入口,见根 `vite.config.ts`),不是桌面那套 `index.html`。

## 怎么出包

```bash
bash scripts/build-android-apk.sh            # release APK
bash scripts/build-android-apk.sh --debug    # debug APK
LP_ANDROID_PKG=linplayer-android bash scripts/build-android.sh   # 只验交叉编译,不打包
```

产物:`gen/android/app/build/outputs/apk/universal/release/app-universal-release-unsigned.apk`

**不要直接 `npx tauri android build`**:gradle 会转手调 cargo 编 aarch64,而
rquickjs-sys 在安卓必须现跑 bindgen —— libclang/resource-dir/sysroot/INCLUDE
那一整套 Windows 宿主特有的坑,逐条说明写在 `scripts/build-android.sh` 顶部。
上面那个脚本就是把那批环境变量喂给 tauri CLI。

## 几个不能想当然的地方

- **数据根必须由宿主显式喂。** 安卓没有 XDG/AppData,更没有「exe 同级 userdata/」,
  `paths::root()` 的默认解析会落到进程无权写的地方。壳在 `setup()` 里拿沙盒目录调
  `paths::set_root()`,而它**只在 `root()` 第一次被调用之前有效** —— 所以整块状态
  初始化(含 `AppConfig::load()`)都搬进了 setup,不能像桌面那样在 `run()` 顶部做。
- **APK 体积要按住 `CARGO_PROFILE_RELEASE_DEBUG=false`。** 根 `Cargo.toml` 的
  `debug = "line-tables-only"` 是给 Windows/Sentry 的,MSVC 把调试信息放独立 .pdb
  所以 exe 体积不变;ELF 会把它留在 `.so` 里一起打进 APK。实测 105MB → 21MB。
- **播放器目前是桩。** 仓库里一个安卓 libmpv `.so` 都没有(Flutter 删除时一并没了)。
  `play` / `play_local` / `source_play` / `seek` / `set_pause` / `set_track` /
  `status` / `tracks` / `stop_playback` / `report_progress` 全部注册成明确报错的桩,
  文案是「Android 播放器未接入(缺 libmpv .so)」。**不注册**会让前端抛通用的
  "command not found",**假装成功返回空数据**则会让上层以为播起来了 —— 两个都更糟。
  接入 .so 后替换实现即可,注册表不用动。
- **`gen/android/` 的工程骨架入库、构建产物不入库**(见根 `.gitignore`)。
  Tauri 的模板已经带了 `LEANBACK_LAUNCHER`,不用手改 manifest。

## 命令清单

`tv-commands.txt` 是 TV UI 真实会调的 63 个命令,由 `ui/tv` 的 import 反推得到。
`src/lib.rs` 的单测拿它和 `generate_handler!` 逐条对账 —— 漏注册**不会编译报错**,
只在用户走到那个页面时炸,所以让测试当守门人。

签名和返回类型是从 `apps/desktop/src/lib.rs` **逐字照抄**的:前端
`ui/shared/api.ts` 的 TS 类型和它们逐字段对应,改个名字前端就静默拿到 undefined。
