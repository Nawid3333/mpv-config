<#
.SYNOPSIS
    Installs the mpv build mpv-build.json pins into this folder.

.DESCRIPTION
    mpv's own files (mpv.exe, mpv.com, d3dcompiler_43.dll, the manual, the
    register/install batch files, mpv\fonts.conf) are not kept in git since
    2026-10-03. mpv-build.json names the shinchiro build this setup uses, and CI
    moves it to each new build that passes the regression tests
    (.github/workflows/mpv-auto-update.yml). This script brings the folder to
    that build:

      1. every file the json lists (upstream_files) is checked against its
         SHA-256 - all there and equal: nothing to do;
      2. otherwise the archive is downloaded (the json's url, ~35 MB, to TEMP)
         and checked against the json's sha256, extracted to a temporary folder,
         each file checked against the json once more and copied in.

    Only the files the json lists are installed. shinchiro's own updater
    (updater.bat, installer\updater.ps1) is not among them: this repo's
    updater.bat runs installer\update.ps1, which runs this.

    Exit codes: 0 installed (or already was), 1 error, 2 the download failed
    (CI falls back to the latest build then), 3 -Check found it not installed.
    Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Root
    The folder to install into. Default: this repo (the mpv folder).

.PARAMETER BuildJson
    The pin. Default: <Root>\mpv-build.json, else the one next to this script.

.PARAMETER Archive
    Use this .7z instead of downloading the json's url (the tests do).

.PARAMETER Check
    Only report whether the pinned build is installed; change nothing.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$BuildJson,
    [string]$Archive,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub needs it
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:failCode = 1

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-7zExe {
    $cmd = Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $dir = Get-ItemPropertyValue -ErrorAction SilentlyContinue 'HKLM:\SOFTWARE\7-Zip' 'Path'
    if ($dir -and (Test-Path (Join-Path $dir '7z.exe'))) { return (Join-Path $dir '7z.exe') }
    # the repo's own copy (Git LFS: a small pointer file until git lfs pull)
    $repo7z = Join-Path (Split-Path $PSScriptRoot -Parent) '7z\7zr.exe'
    if ((Test-Path $repo7z) -and (Get-Item $repo7z).Length -gt 100KB) { return $repo7z }
    throw 'no 7-Zip found: install 7-Zip, or run git lfs pull for 7z\7zr.exe'
}

# The json may only ever name files of the build itself - never this repo's
# config, scripts, tests or workflows, never a path outside the folder.
function Test-SafePath([string]$Rel) {
    if ($Rel -match '(^|[\\/])\.\.([\\/]|$)' -or $Rel -match '^[\\/]' -or $Rel -match ':') { return $false }
    return $Rel -notmatch '^(portable_config|\.github|\.githooks|tests|lua-api|\.git)([\\/]|$)'
}

# Replaces a file through a new name: a file left from the original install can
# carry Program Files' read-only ACL for users while its folder still lets them
# delete and create (installer\updater.ps1 did, 2026-10-03).
function Copy-BuildFile([string]$Source, [string]$Target) {
    $dir = Split-Path -Parent $Target
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $tmp = "$Target.new"
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
    Move-Item -LiteralPath $tmp -Destination $Target
}

try {
    $Root = (Resolve-Path -LiteralPath $Root).Path
    if (-not $BuildJson) {
        $BuildJson = Join-Path $Root 'mpv-build.json'
        if (-not (Test-Path -LiteralPath $BuildJson)) { $BuildJson = Join-Path (Split-Path $PSScriptRoot -Parent) 'mpv-build.json' }
    }
    $build = Get-Content -Raw -LiteralPath $BuildJson | ConvertFrom-Json
    $files = [ordered]@{}
    foreach ($p in $build.upstream_files.PSObject.Properties) { $files[$p.Name] = $p.Value.ToLowerInvariant() }
    if (-not ($build.tag -and $build.asset -and $build.url -and $build.sha256 -match '^[0-9a-f]{64}$' -and $files.Contains('mpv.exe'))) {
        throw "$BuildJson is not a complete pin (tag, asset, url, sha256, upstream_files with mpv.exe)"
    }
    $unsafe = @($files.Keys | Where-Object { -not (Test-SafePath $_) })
    if ($unsafe.Count) { throw "mpv-build.json names files outside the build: $($unsafe -join ', ') - refusing" }

    $label = "mpv $($build.tag)" + $(if ($build.mpv_version) { " ($($build.mpv_version))" } else { '' })
    $differ = @($files.Keys | Where-Object { (Get-Sha256 (Join-Path $Root $_)) -ne $files[$_] })
    if ($differ.Count -eq 0) {
        Write-Host "$label is installed." -ForegroundColor Green
        exit 0
    }
    if ($Check) {
        Write-Host "$label is not installed; these files differ or are missing: $($differ -join ', ')" -ForegroundColor Yellow
        exit 3
    }

    # mpv.exe cannot be replaced while this folder's mpv runs
    $running = @(Get-Process mpv -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($running.Count) { throw "mpv is running from $Root (pid $($running.Id -join ', ')) - close it and run this again" }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('mpv-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work
    try {
        if ($Archive) {
            $file = (Resolve-Path -LiteralPath $Archive).Path
        }
        else {
            $file = Join-Path $work $build.asset
            Write-Host "Downloading $($build.asset) ..." -ForegroundColor Cyan
            try {
                Invoke-WebRequest -Uri $build.url -OutFile "$file.part" -UseBasicParsing -UserAgent 'mpv-pin-installer'
            }
            catch {
                $script:failCode = 2
                throw "download failed: $($build.url): $($_.Exception.Message)"
            }
            Move-Item -LiteralPath "$file.part" -Destination $file
        }
        $got = Get-Sha256 $file
        if ($got -ne $build.sha256.ToLowerInvariant()) {
            throw "$(Split-Path -Leaf $file): sha256 $got does not match mpv-build.json ($($build.sha256)) - nothing installed"
        }
        $x = Join-Path $work 'x'
        $7z = Get-7zExe
        $out = & $7z x -y "-o$x" $file 2>&1
        if ($LASTEXITCODE -ne 0) { throw "7-Zip could not extract $(Split-Path -Leaf $file) (exit $LASTEXITCODE): $($out | Select-Object -Last 3)" }
        # every file proven before the first one is copied
        foreach ($rel in $files.Keys) {
            $sha = Get-Sha256 (Join-Path $x $rel)
            if ($null -eq $sha) { throw "the archive has no $rel - nothing installed" }
            if ($sha -ne $files[$rel]) { throw "the archive's $rel is not the file mpv-build.json names - nothing installed" }
        }
        foreach ($rel in $differ) {
            Copy-BuildFile (Join-Path $x $rel) (Join-Path $Root $rel)
            Write-Host "  $rel"
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $still = @($files.Keys | Where-Object { (Get-Sha256 (Join-Path $Root $_)) -ne $files[$_] })
    if ($still.Count) { throw "installed, but these files still differ: $($still -join ', ')" }
    Write-Host "Installed $label ($($differ.Count) of $($files.Count) files)." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "install-mpv: $($_.Exception.Message)" -ForegroundColor Red
    exit $script:failCode
}
