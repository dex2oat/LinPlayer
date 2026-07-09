# Extract native libs from mpv-android release APKs into jniLibs.
# 从 mpv-android 官方 release APK 提取整套原生库到 android/app/src/main/jniLibs。
#
# 重要：libmpv 与 libav*/libplayer 是**同一构建的一套**，必须整套一起替换，
# 只换 libmpv.so 会 ABI 不匹配。libass 已静态链接进 libmpv.so（APK 里没有独立 libass.so）。
# 版本：mpv v0.41（2026-04-25 release, libmpv commit 9ce79bca）——带 fontconfig，
# 且有 secondary-sub-pos/secondary-sub-delay。
#
# Run from project root:  powershell -ExecutionPolicy Bypass -File scripts/extract-mpv-libs.ps1

$ErrorActionPreference = "Stop"

$release = "2026-04-25"
$base = "https://github.com/mpv-android/mpv-android/releases/download/$release"
$abiMap = @{
    "arm64-v8a"   = "$base/app-default-arm64-v8a-release.apk"
    "armeabi-v7a" = "$base/app-default-armeabi-v7a-release.apk"
    "x86"         = "$base/app-default-x86-release.apk"
    "x86_64"      = "$base/app-default-x86_64-release.apk"
}

# 整套原生库（libc++_shared.so 来自 NDK/Flutter，不在此替换）。
$soNames = @(
    "libmpv.so", "libplayer.so",
    "libavcodec.so", "libavdevice.so", "libavfilter.so",
    "libavformat.so", "libavutil.so",
    "libswresample.so", "libswscale.so"
)

$jniLibsDir = "android/app/src/main/jniLibs"

foreach ($abi in $abiMap.Keys) {
    $url = $abiMap[$abi]
    $apkFile = "$env:TEMP\mpv-android-$abi.apk"
    $extractDir = "$env:TEMP\mpv-extract-$abi"
    $destDir = "$jniLibsDir\$abi"

    Write-Host "`n=== Processing $abi ===" -ForegroundColor Cyan

    if (-not (Test-Path $apkFile)) {
        Write-Host "Downloading $abi APK..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $url -OutFile $apkFile
    } else {
        Write-Host "Using cached APK" -ForegroundColor Green
    }

    if (Test-Path $extractDir) { Remove-Item -Path $extractDir -Recurse -Force }
    Expand-Archive -Path $apkFile -DestinationPath $extractDir -Force

    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    foreach ($so in $soNames) {
        $src = "$extractDir\lib\$abi\$so"
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination "$destDir\$so" -Force
            $size = (Get-Item "$destDir\$so").Length
            Write-Host ("  OK  {0}: {1:N0} bytes" -f $so, $size) -ForegroundColor Green
        } else {
            Write-Host "  MISSING $so in APK!" -ForegroundColor Red
        }
    }

    Remove-Item -Path $extractDir -Recurse -Force
}

Write-Host "`n=== Summary (jniLibs) ===" -ForegroundColor Cyan
Get-ChildItem -Path $jniLibsDir -Recurse -Filter "*.so" | ForEach-Object {
    Write-Host ("{0}: {1:N2} MB" -f $_.FullName, ($_.Length / 1MB))
}
Write-Host "`nDone. Verify libmpv version, then: flutter build apk --release" -ForegroundColor Green
