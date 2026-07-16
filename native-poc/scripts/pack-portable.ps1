# Build a portable (unzip-and-run) package.
# Usage:  npx tauri build   # compiles target/release/app.exe (bundle.active=false, no installer)
#         powershell -ExecutionPolicy Bypass -File scripts/pack-portable.ps1
#
# Output: dist-portable/LinPlayer/                         (app.exe renamed LinPlayer.exe + libmpv-2.dll alongside)
#         dist-portable/LinPlayer_<version>_portable_x64.zip
#
# Note: libmpv-2.dll MUST sit next to the exe (Windows searches the exe dir first at load time).
#       WebView2 runtime ships with Windows 11, no need to bundle.
# ASCII-only on purpose: PS 5.1 misreads UTF-8-without-BOM Chinese as GBK and fails to parse.

$ErrorActionPreference = "Stop"
$root    = Split-Path -Parent $PSScriptRoot
$release = Join-Path $root "target\release"
$exe     = Join-Path $release "app.exe"
$dll     = Join-Path $release "libmpv-2.dll"

if (-not (Test-Path $exe)) { throw "Missing $exe -- run 'npx tauri build' first" }
if (-not (Test-Path $dll)) { throw "Missing $dll -- build.rs should copy it; check src-tauri/libmpv/" }

$ver = (Get-Content (Join-Path $root "src-tauri\tauri.conf.json") -Raw | ConvertFrom-Json).version

$out   = Join-Path $root "dist-portable"
$stage = Join-Path $out "LinPlayer"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item $exe (Join-Path $stage "LinPlayer.exe") -Force   # rename is safe: DLL lookup is by directory, not exe name
Copy-Item $dll (Join-Path $stage "libmpv-2.dll")  -Force

$zip = Join-Path $out "LinPlayer_${ver}_portable_x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal

$sizeMB = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "OK  portable dir: $stage"
Write-Host "OK  zip:          $zip  ($sizeMB MB)"
