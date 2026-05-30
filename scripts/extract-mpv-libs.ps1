# Extract libraries from mpv-android APKs
# Run this in PowerShell from the project root

$ErrorActionPreference = "Stop"

$abiMap = @{
    "arm64-v8a" = "https://github.com/mpv-android/mpv-android/releases/download/2026-04-25/app-default-arm64-v8a-release.apk"
    "armeabi-v7a" = "https://github.com/mpv-android/mpv-android/releases/download/2026-04-25/app-default-armeabi-v7a-release.apk"
    "x86" = "https://github.com/mpv-android/mpv-android/releases/download/2026-04-25/app-default-x86-release.apk"
    "x86_64" = "https://github.com/mpv-android/mpv-android/releases/download/2026-04-25/app-default-x86_64-release.apk"
}

$jniLibsDir = "android/app/src/main/jniLibs"

foreach ($abi in $abiMap.Keys) {
    $url = $abiMap[$abi]
    $apkFile = "$env:TEMP\mpv-android-$abi.apk"
    $extractDir = "$env:TEMP\mpv-extract-$abi"
    $destDir = "$jniLibsDir\$abi"
    
    Write-Host "`n=== Processing $abi ===" -ForegroundColor Cyan
    
    # Download APK
    if (-not (Test-Path $apkFile)) {
        Write-Host "Downloading $abi APK..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $url -OutFile $apkFile
    } else {
        Write-Host "Using cached APK" -ForegroundColor Green
    }
    
    # Extract
    if (Test-Path $extractDir) {
        Remove-Item -Path $extractDir -Recurse -Force
    }
    Expand-Archive -Path $apkFile -DestinationPath $extractDir -Force
    
    # Create dest dir
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    
    # Copy libass.so
    $libassSource = "$extractDir\lib\$abi\libass.so"
    if (Test-Path $libassSource) {
        Copy-Item -Path $libassSource -Destination "$destDir\libass.so" -Force
        $size = (Get-Item "$destDir\libass.so").Length
        Write-Host "✅ libass.so: $size bytes" -ForegroundColor Green
    } else {
        Write-Host "⚠️ libass.so not found in APK" -ForegroundColor Yellow
    }
    
    # Copy libmpv.so
    $libmpvSource = "$extractDir\lib\$abi\libmpv.so"
    if (Test-Path $libmpvSource) {
        Copy-Item -Path $libmpvSource -Destination "$destDir\libmpv.so" -Force
        $size = (Get-Item "$destDir\libmpv.so").Length
        Write-Host "✅ libmpv.so: $size bytes ($(($size/1MB).ToString('F2')) MB)" -ForegroundColor Green
    } else {
        Write-Host "❌ libmpv.so not found!" -ForegroundColor Red
    }
    
    # Cleanup
    Remove-Item -Path $extractDir -Recurse -Force
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Get-ChildItem -Path $jniLibsDir -Recurse -Filter "*.so" | ForEach-Object {
    Write-Host "$($_.FullName): $([math]::Round($_.Length/1MB,2)) MB"
}

Write-Host "`nDone! Now run: flutter build apk --release" -ForegroundColor Green