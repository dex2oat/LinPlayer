<#
.SYNOPSIS
  下载并就位 Android TV 专属的 mihomo 内核(arm32) 与 zashboard 面板。

.DESCRIPTION
  - mihomo: 取官方 armv7 (arm32) 二进制，解压后重命名为 libmihomo.so，
    放入 android/app/src/tv/jniLibs/armeabi-v7a/（仅 tv flavor 打包）。
    以 lib*.so 命名是关键：Android 安装时会把它解压到 nativeLibraryDir 并赋可执行权限，
    Android 10+ 只能从该目录执行二进制。
  - zashboard: 取官方 dist.zip，解压到 android/app/src/tv/assets/zashboard/，
    运行时由 App 复制到私有目录，作为 mihomo external-ui 提供。

  这些大体积二进制/产物不建议入库，用本脚本按需获取。

.PARAMETER MihomoVersion
  mihomo 发布版本号，形如 v1.18.10。默认拉取一个已知可用版本，可按需覆盖。

.EXAMPLE
  pwsh ./scripts/fetch_mihomo_tv.ps1 -MihomoVersion v1.18.10
#>
param(
    [string]$MihomoVersion = "v1.18.10"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$jniDir = Join-Path $repoRoot "android/app/src/tv/jniLibs/armeabi-v7a"
$assetsDir = Join-Path $repoRoot "android/app/src/tv/assets/zashboard"
# 不能用 $env:TEMP —— Linux/macOS 的 pwsh 上它是空的,Join-Path $null 直接抛错。
# CI(ubuntu-latest)靠这个脚本拉内核,写死 Windows 环境变量会让 TV 构建当场挂。
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "linplayer_tv_proxy"

New-Item -ItemType Directory -Force -Path $jniDir | Out-Null
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# ---- mihomo arm32 内核 ----
$mihomoGzName = "mihomo-android-armv7-$MihomoVersion.gz"
$mihomoUrl = "https://github.com/MetaCubeX/mihomo/releases/download/$MihomoVersion/$mihomoGzName"
$mihomoGz = Join-Path $tmp $mihomoGzName
$mihomoOut = Join-Path $jniDir "libmihomo.so"

Write-Host "下载 mihomo 内核: $mihomoUrl"
Invoke-WebRequest -Uri $mihomoUrl -OutFile $mihomoGz

Write-Host "解压 -> $mihomoOut"
$inStream = [System.IO.File]::OpenRead($mihomoGz)
$gzip = New-Object System.IO.Compression.GzipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
$outStream = [System.IO.File]::Create($mihomoOut)
$gzip.CopyTo($outStream)
$outStream.Close(); $gzip.Close(); $inStream.Close()

# 校验:内核不入库后,这个脚本就是 TV 包里有没有 mihomo 的唯一保证。
# 解出个 0 字节文件的话,构建照样成功、APK 照样能装,只是代理功能悄悄失灵 —— 必须当场炸。
$mihomoSize = (Get-Item $mihomoOut).Length
if ($mihomoSize -lt 1MB) {
    throw "mihomo 内核解压后只有 $mihomoSize 字节,明显不对(应为 10MB+)。下载或解压失败。"
}
Write-Host "mihomo 内核已就位: $mihomoOut ($([math]::Round($mihomoSize/1MB,1)) MB)"

# ---- zashboard 面板 ----
$zashUrl = "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
$zashZip = Join-Path $tmp "zashboard-dist.zip"

Write-Host "下载 zashboard 面板: $zashUrl"
Invoke-WebRequest -Uri $zashUrl -OutFile $zashZip

Write-Host "解压 -> $assetsDir"
if (Test-Path $assetsDir) { Remove-Item -Recurse -Force $assetsDir }
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
Expand-Archive -Path $zashZip -DestinationPath $assetsDir -Force

# dist.zip 可能解出一层 dist/ 目录，拍平到 assets/zashboard 根。
$inner = Join-Path $assetsDir "dist"
if ($inner -and (Test-Path $inner)) {
    Get-ChildItem -Path $inner -Force | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $assetsDir -Force
    }
    Remove-Item -Recurse -Force $inner
}

# 校验:同理,面板不入库后这里是唯一保证。index.html 缺了 = mihomo 的 external-ui 打开是白页。
$zashIndex = Join-Path $assetsDir "index.html"
if (-not (Test-Path $zashIndex)) {
    throw "zashboard 解压后找不到 index.html —— 上游 dist.zip 结构可能变了,面板会是白页。"
}
$zashCount = (Get-ChildItem -Path $assetsDir -Recurse -File).Count
Write-Host "zashboard 面板已就位: $assetsDir ($zashCount 个文件)"
Write-Host "完成。重新构建 tv flavor 即可包含内核与面板：flutter build apk --flavor tv --dart-define=FLAVOR=tv"
