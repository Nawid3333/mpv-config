<#
.SYNOPSIS
    Brings this mpv folder up to date: the code, the pinned mpv build, yt-dlp.

.DESCRIPTION
    What updater.bat runs (2026-10-03; until then it was shinchiro's updater,
    which installed the newest build and left mpv.exe changed in git, to be
    committed and pushed by hand):

      1. git pull --ff-only - the code, and mpv-build.json, which CI moves to
         each new mpv build that passes the regression tests by itself
         (.github/workflows/mpv-auto-update.yml). Skipped with a note when the
         folder is not a git clone, git is missing, or the pull cannot
         fast-forward (local commits or changes in the way);
      2. installer\install-mpv.ps1 - installs the build mpv-build.json pins (a
         no-op when it is installed);
      3. yt-dlp.exe (mpv's ytdl_hook runs it for web URLs): yt-dlp -U, which
         checks its own download; a missing one is fetched from yt-dlp's
         latest release and checked against GitHub's SHA-256 digest.

    mpv's own files and yt-dlp.exe are not in git, so nothing here leaves
    anything to commit. Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Root
    The mpv folder. Default: this repo.
#>
[CmdletBinding()]
param([string]$Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Root = (Resolve-Path -LiteralPath $Root).Path
$failed = 0

# -- 1. the code and the pin ------------------------------------------------------
Write-Host '== GitHub (code and the pinned mpv build)' -ForegroundColor Cyan
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$inside = ''
if ($git) {
    # Not under 'Stop': Windows PowerShell 5.1 (updater.bat's fallback without pwsh)
    # turns a native program's redirected stderr into errors, and the first one
    # ("fatal: not a git repository" in a folder that is no clone, a ZIP download)
    # ended the script before mpv was installed. PowerShell 7.2+ does not.
    $ErrorActionPreference = 'Continue'
    try { $inside = & $git.Source -C $Root rev-parse --is-inside-work-tree 2>$null }
    catch { $inside = '' }
    finally { $ErrorActionPreference = 'Stop' }
}
if (-not $git) {
    Write-Host 'git is not installed: skipped. The pin in mpv-build.json stays as it is.' -ForegroundColor Yellow
}
elseif ($inside -ne 'true') {
    Write-Host "$Root is not a git clone: skipped." -ForegroundColor Yellow
}
else {
    & $git.Source -C $Root pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'git pull could not fast-forward (local commits or changes in the way) - pull by hand.' -ForegroundColor Yellow
        Write-Host 'Installing the build this checkout pins meanwhile.' -ForegroundColor Yellow
    }
}

# -- 2. the pinned mpv build -------------------------------------------------------
Write-Host '== mpv' -ForegroundColor Cyan
# a child process: install-mpv.ps1 ends with exit, which would end this script
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-mpv.ps1') -Root $Root
if ($LASTEXITCODE -ne 0) { $failed++ }

# -- 3. yt-dlp ---------------------------------------------------------------------
Write-Host '== yt-dlp' -ForegroundColor Cyan
$ytdlp = Join-Path $Root 'yt-dlp.exe'
try {
    if (Test-Path -LiteralPath $ytdlp) {
        & $ytdlp -U
        if ($LASTEXITCODE -ne 0) { throw "yt-dlp -U exited with $LASTEXITCODE" }
    }
    else {
        $release = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 60
        $asset = @($release.assets | Where-Object { $_.name -eq 'yt-dlp.exe' })[0]
        if (-not $asset -or $asset.digest -notmatch '^sha256:([0-9a-f]{64})$') { throw "yt-dlp $($release.tag_name) has no yt-dlp.exe with a SHA-256 digest" }
        $want = $Matches[1]
        Write-Host "Downloading yt-dlp $($release.tag_name) ..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$ytdlp.part" -UseBasicParsing
        $got = (Get-FileHash -LiteralPath "$ytdlp.part" -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $want) {
            Remove-Item -LiteralPath "$ytdlp.part" -Force
            throw "yt-dlp.exe: sha256 $got does not match GitHub's $want"
        }
        Move-Item -LiteralPath "$ytdlp.part" -Destination $ytdlp
        Write-Host "Installed yt-dlp $($release.tag_name)." -ForegroundColor Green
    }
}
catch {
    Write-Host "yt-dlp: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}

if ($failed) {
    Write-Host "`nDone, with $failed problem(s) above." -ForegroundColor Red
    exit 1
}
Write-Host "`nUp to date." -ForegroundColor Green
exit 0
