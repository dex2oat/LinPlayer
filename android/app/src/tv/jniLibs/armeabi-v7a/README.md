# TV 专属 mihomo 内核目录

此目录仅在构建 **tv** flavor 时被打包（见 `android/app/build.gradle.kts` 的 `sourceSets`）。

放置文件：`libmihomo.so`（mihomo 的 arm32/armv7 二进制，重命名为 `lib*.so`）。

为什么命名为 `lib*.so`：Android 安装时会把 jniLibs 中的 `.so` 解压到应用的
`nativeLibraryDir` 并赋予可执行权限。Android 10+ 出于安全限制，**只能从
`nativeLibraryDir` 执行二进制**，因此把内核伪装成 `.so` 是通行做法（Clash/SagerNet 同理）。

获取方式（不入库，按需拉取）：

```powershell
pwsh ./scripts/fetch_mihomo_tv.ps1 -MihomoVersion v1.18.10
```

本地要构建 tv flavor 就得先跑一次这个脚本，否则 APK 里没有内核 ——
**注意它不会构建失败**，只是装上后代理功能用不了，别以为是代码 bug。

CI 侧：`.github/workflows/build.yml` 的 `build-android-tv` job 已在
`flutter build` 前加了 `Fetch TV proxy kernel` 步骤，无需手工干预。

> 历史教训：内核与面板曾被误提进仓库（28MB + 310 个文件），与本文直接矛盾，
> 且当时 CI 根本没跑这个脚本 —— 等于文档说不入库、实际靠入库的那份在撑着。
> 现已 `git rm --cached` 出库 + 入 `.gitignore` + CI 补拉取步骤。改动这块时三者要同步。

mobile / iOS / 桌面 / Apple TV 均不包含此内核。
