#Requires -Version 5.1
<#
.SYNOPSIS
    Replace the bundled libmpv-2.dll on Windows with the full shinchiro build to enable PGS/SUP bitmap subtitles.

.DESCRIPTION
    media-kit's Windows libmpv prebuild disables most FFmpeg decoders, including hdmv_pgs_subtitle,
    so PGS/SUP graphic subtitles are silently dropped. This script downloads shinchiro's full mpv dev
    package and replaces libmpv-2.dll in the Flutter Windows build output.

    Usage after build:
        .\windows\scripts\upgrade_libmpv_for_pgs.ps1

    From CMake build this script runs by default. To skip, set:
        $env:LINPLAYER_SKIP_LIBMPV_UPGRADE = "1"
        flutter build windows

.PARAMETER BuildOutput
    Flutter Windows build output directory. If omitted, Release/Debug under build/windows/x64/runner are searched.

.PARAMETER DownloadUrl
    Direct URL to a shinchiro mpv-dev-x86_64 .7z archive. Defaults to the latest known release.

    SECURITY · CVE-2026-8461 (PixelSmash): shinchiro full builds bundle ffmpeg with the
    magicyuv decoder enabled, which has a heap OOB write fixed only in FFmpeg 8.1.2
    (2026-06-17). The pinned 20260610 build predates that fix. Bump this URL to the first
    shinchiro release dated >= 20260618 (which ships patched ffmpeg) when available.
    Until then, the player blacklists the magicyuv decoder at runtime (vd=-magicyuv in
    lib/core/services/mpv_player_adapter.dart), so the bundled-ffmpeg version is not
    exploitable via this CVE regardless.
#>
[CmdletBinding()]
param(
    [string]$BuildOutput = "",
    # CVE-2026-8461: keep this >= 20260618 once shinchiro publishes a post-fix build (see .PARAMETER DownloadUrl).
    [string]$DownloadUrl = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260610/mpv-dev-x86_64-20260610-git-304426c.7z",
    [switch]$AllowFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$global:ErrorActionPreference = "Stop"
trap {
    Write-Warning "libmpv升级脚本遇到错误: $_"
    if ($AllowFailure) {
        exit 0
    }
    exit 1
}

function Find-BuildOutputDirectory {
    param([string]$hint)
    if ($hint -and (Test-Path -LiteralPath $hint)) {
        return $hint
    }
    $candidates = @(
        "..\..\build\windows\x64\runner\Release"
        "..\..\build\windows\x64\runner\Debug"
    )
    foreach ($c in $candidates) {
        $p = Join-Path $PSScriptRoot $c
        if (Test-Path -LiteralPath $p) {
            return $p
        }
    }
    throw "Flutter Windows build output directory not found. Please specify -BuildOutput."
}

function Get-UpgradeTargetDirectories {
    param([string]$PrimaryOutputDirectory)

    $resolvedPrimary = (Resolve-Path -LiteralPath $PrimaryOutputDirectory).Path
    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.Add($resolvedPrimary)

    $dirInfo = Get-Item -LiteralPath $resolvedPrimary
    if ($dirInfo.Name -in @("Release", "Debug", "Profile") -and
        $dirInfo.Parent -and
        $dirInfo.Parent.Name -eq "runner" -and
        $dirInfo.Parent.Parent) {
        $buildRoot = $dirInfo.Parent.Parent.FullName
        $sharedLibmpvDir = Join-Path $buildRoot "libmpv"
        $sharedLibmpvDll = Join-Path $sharedLibmpvDir "libmpv-2.dll"
        if (Test-Path -LiteralPath $sharedLibmpvDll) {
            $targets.Add((Resolve-Path -LiteralPath $sharedLibmpvDir).Path)
        }
    } elseif ($dirInfo.Name -eq "libmpv" -and $dirInfo.Parent) {
        $runnerRoot = Join-Path $dirInfo.Parent.FullName "runner"
        foreach ($config in @("Release", "Debug", "Profile")) {
            $candidateDir = Join-Path $runnerRoot $config
            $candidateDll = Join-Path $candidateDir "libmpv-2.dll"
            if (Test-Path -LiteralPath $candidateDll) {
                $targets.Add((Resolve-Path -LiteralPath $candidateDir).Path)
            }
        }
    }

    return $targets | Select-Object -Unique
}

function Invoke-DownloadFile {
    param([string]$url, [string]$outFile)
    Write-Host "Downloading full libmpv package: $url"
    $progressPreference = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
        if ($curl) {
            & $curl.Source -L --fail --output $outFile $url
            if ($LASTEXITCODE -ne 0) {
                throw "curl download failed (exit=$LASTEXITCODE)"
            }
        } else {
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
        }
    } finally {
        $ProgressPreference = $progressPreference
    }
    if (-not (Test-Path -LiteralPath $outFile)) {
        throw "Download failed: $outFile does not exist"
    }
    Write-Host "Downloaded: $outFile ($((Get-Item $outFile).Length) bytes)"
}

function Expand-SevenZipArchive {
    param([string]$archive, [string]$destination)
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if ($tar) {
        Write-Host "Extracting with tar: $archive"
        & tar -xf "$archive" -C "$destination"
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed (exit=$LASTEXITCODE)"
        }
        return
    }
    $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
    if (-not $sevenZip) {
        $sevenZip = Get-Command "${env:ProgramFiles}\7-Zip\7z.exe" -ErrorAction SilentlyContinue
    }
    if (-not $sevenZip) {
        $sevenZip = Get-Command "${env:ProgramFiles(x86)}\7-Zip\7z.exe" -ErrorAction SilentlyContinue
    }
    if (-not $sevenZip) {
        throw "Neither tar nor 7-Zip found. Install 7-Zip or use Windows 11 to extract .7z files."
    }
    Write-Host "Extracting with 7-Zip: $archive"
    & $sevenZip x "$archive" -o"$destination" -y
    if ($LASTEXITCODE -ne 0) {
        throw "7z extraction failed (exit=$LASTEXITCODE)"
    }
}

function Remove-PathWithRetry {
    param(
        [string]$Path,
        [switch]$Recurse,
        [int]$MaxAttempts = 5,
        [int]$DelayMilliseconds = 400
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($Recurse) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            return $true
        } catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Warning "Temporary path cleanup skipped: $Path ($($_.Exception.Message))"
                return $false
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    return $false
}

function Get-LibmpvDllPath {
    param([string]$extractDir)
    $dll = Get-ChildItem -Path $extractDir -Recurse -Filter "libmpv-2.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) {
        throw "libmpv-2.dll not found in extracted archive"
    }
    return $dll.FullName
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-UpgradeManifest {
    param([string]$OutputDirectory)

    $manifestPath = Join-Path $OutputDirectory "libmpv-upgrade.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse existing libmpv-upgrade.json, ignoring it: $($_.Exception.Message)"
        return $null
    }
}

function Get-ManifestProperty {
    param(
        $Manifest,
        [string]$Name
    )

    if ($null -eq $Manifest) {
        return $null
    }

    $property = $Manifest.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Write-UpgradeManifest {
    param(
        [string]$OutputDirectory,
        [string]$SourceUrl,
        [string]$DllPath,
        [string]$BackupPath,
        [string]$SourceDllSha256
    )

    $dllInfo = Get-Item -LiteralPath $DllPath
    $dllSha256 = Get-FileSha256 -Path $DllPath
    $backupLength = 0
    $backupSha256 = ""
    if (Test-Path -LiteralPath $BackupPath) {
        $backupInfo = Get-Item -LiteralPath $BackupPath
        $backupLength = $backupInfo.Length
        $backupSha256 = Get-FileSha256 -Path $BackupPath
    }

    $manifestPath = Join-Path $OutputDirectory "libmpv-upgrade.json"
    $manifest = [ordered]@{
        manifestVersion = 2
        upgradedAtUtc = [DateTime]::UtcNow.ToString("o")
        downloadUrl = $SourceUrl
        dllPath = $DllPath
        dllLength = $dllInfo.Length
        dllSha256 = $dllSha256
        sourceDllSha256 = $SourceDllSha256
        backupPath = $BackupPath
        backupLength = $backupLength
        backupSha256 = $backupSha256
        verifiedBy = "downloaded-full-build-sha256-match"
    } | ConvertTo-Json

    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8
}

function Upgrade-LibmpvTarget {
    param(
        [string]$OutputDirectory,
        [string]$SourceUrl,
        [string]$SourceDll,
        [string]$SourceDllSha256,
        [long]$SourceDllLength
    )

    $targetDll = Join-Path $OutputDirectory "libmpv-2.dll"
    if (-not (Test-Path -LiteralPath $targetDll)) {
        throw "libmpv-2.dll not found in target directory: $OutputDirectory"
    }

    $backup = "$targetDll.orig"
    $existingManifest = Read-UpgradeManifest -OutputDirectory $OutputDirectory
    $existingManifestVersion = Get-ManifestProperty -Manifest $existingManifest -Name "manifestVersion"
    $existingSourceDllSha256 = Get-ManifestProperty -Manifest $existingManifest -Name "sourceDllSha256"
    if ($existingManifest -and
        $existingManifestVersion -and
        [int]$existingManifestVersion -ge 2 -and
        $existingSourceDllSha256) {
        $currentTargetSha256 = Get-FileSha256 -Path $targetDll
        if ($currentTargetSha256 -eq $existingSourceDllSha256) {
            Write-Host "libmpv-2.dll 已经匹配已验证的完整版哈希，跳过升级: $OutputDirectory"
            return
        }
    }

    $targetDllSha256 = Get-FileSha256 -Path $targetDll
    if ($targetDllSha256 -eq $SourceDllSha256) {
        Write-Host "libmpv-2.dll 已与下载的完整版一致，跳过复制: $OutputDirectory"
        Write-UpgradeManifest -OutputDirectory $OutputDirectory -SourceUrl $SourceUrl -DllPath $targetDll -BackupPath $backup -SourceDllSha256 $SourceDllSha256
        return
    }

    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $targetDll -Destination $backup -Force
        Write-Host "Backed up original libmpv-2.dll to $backup"
    }

    Copy-Item -LiteralPath $SourceDll -Destination $targetDll -Force
    $replacedTargetSha256 = Get-FileSha256 -Path $targetDll
    if ($replacedTargetSha256 -ne $SourceDllSha256) {
        if (Test-Path -LiteralPath $backup) {
            Copy-Item -LiteralPath $backup -Destination $targetDll -Force
        }
        throw "Replacement completed but verification failed: target libmpv-2.dll hash does not match the downloaded full build ($OutputDirectory)"
    }

    Write-Host "Replaced libmpv-2.dll with the full build: $targetDll size=$SourceDllLength sha256=$SourceDllSha256"
    Write-UpgradeManifest -OutputDirectory $OutputDirectory -SourceUrl $SourceUrl -DllPath $targetDll -BackupPath $backup -SourceDllSha256 $SourceDllSha256
}

# ---------------------------------------------------------------------------
$outDir = Find-BuildOutputDirectory $BuildOutput
Write-Host "Target directory: $outDir"

$targetDirectories = Get-UpgradeTargetDirectories -PrimaryOutputDirectory $outDir
Write-Host "Upgrade targets: $($targetDirectories -join ', ')"

$primaryTargetDll = Join-Path $outDir "libmpv-2.dll"
if (-not (Test-Path -LiteralPath $primaryTargetDll)) {
    # 干净构建：基础 libmpv-2.dll 由 Flutter 的 install 步骤在本 POST_BUILD 之后才复制进
    # 输出目录（鸡生蛋）。此处优雅跳过而非 throw —— 否则首次/清理后构建必然失败。DLL 就位
    # 后的下一次构建（或手动运行本脚本）会完成 PGS/SUP 完整版升级。
    Write-Warning "libmpv-2.dll 尚未生成（干净构建首次运行），跳过 PGS 升级；DLL 就位后下次构建会自动完成升级。"
    exit 0
}

$tempBase = Join-Path $env:TEMP "linplayer_libmpv_upgrade"
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
$tempRoot = Join-Path $tempBase ([guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$archiveFile = Join-Path $tempRoot "mpv-dev-full.7z"
$extractDir = Join-Path $tempRoot "mpv-dev-full"

if (Test-Path -LiteralPath $archiveFile) {
    Remove-PathWithRetry -Path $archiveFile | Out-Null
}
if (Test-Path -LiteralPath $extractDir) {
    Remove-PathWithRetry -Path $extractDir -Recurse | Out-Null
}

Invoke-DownloadFile -url $DownloadUrl -outFile $archiveFile
Expand-SevenZipArchive -archive $archiveFile -destination $extractDir
$sourceDll = Get-LibmpvDllPath -extractDir $extractDir
$sourceDllSha256 = Get-FileSha256 -Path $sourceDll
$sourceDllLength = (Get-Item -LiteralPath $sourceDll).Length

foreach ($targetDirectory in $targetDirectories) {
    Upgrade-LibmpvTarget `
        -OutputDirectory $targetDirectory `
        -SourceUrl $DownloadUrl `
        -SourceDll $sourceDll `
        -SourceDllSha256 $sourceDllSha256 `
        -SourceDllLength $sourceDllLength
}
Write-Host "libmpv upgrade completed for $($targetDirectories.Count) target(s)."

$archiveRemoved = Remove-PathWithRetry -Path $archiveFile
$extractRemoved = Remove-PathWithRetry -Path $extractDir -Recurse
$tempRemoved = Remove-PathWithRetry -Path $tempRoot -Recurse
if ($archiveRemoved -and $extractRemoved -and $tempRemoved) {
    Write-Host "Temporary files cleaned up."
} else {
    Write-Warning "Temporary files were not fully cleaned up. You can remove $tempRoot later if needed."
}
