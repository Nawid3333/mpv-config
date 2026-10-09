<#
.SYNOPSIS
    Brings this mpv folder up to date: the code, the pinned mpv build, yt-dlp.

.DESCRIPTION
    What updater.bat runs (2026-10-03; until then it was shinchiro's updater,
    which installed the newest build and left mpv.exe changed in git, to be
    committed and pushed by hand):

      1. git pull --ff-only - the code, and mpv-build.json, which CI moves to
         each new mpv build the owner merges (.github/workflows/mpv-auto-update.yml).
         Skipped with a note when git is missing or the pull cannot
         fast-forward (local commits or changes in the way). A folder the
         one-click install made (installer\setup.ps1, no git: it has an
         .install-manifest.json) gets the newest config through
         installer\sync-config.ps1 instead (GitHub's ZIP, your own changes
         kept as <name>.mine-<time>);
      2. installer\install-mpv.ps1 - installs the build mpv-build.json pins (a
         no-op when it is installed);
      3. yt-dlp.exe (mpv's ytdl_hook runs it for web URLs): yt-dlp -U, which
         checks its own download; a missing one is fetched from yt-dlp's
         latest release and checked against GitHub's SHA-256 digest;
      4. the FastStream helper, if the one-click install set it up for this
         mpv: brought to FastStream's newest release (the add-on updates
         itself in Firefox, and the two must match). A helper someone
         installed by hand (a FastStream developer's) is never touched.

    mpv's own files and yt-dlp.exe are not in git, so nothing here leaves
    anything to commit. Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Root
    The mpv folder. Default: this repo.

.PARAMETER NoFastStream
    Skip step 4 (setup.ps1 installs the helper itself right after).
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [switch]$NoFastStream
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Root = (Resolve-Path -LiteralPath $Root).Path
$failed = 0
# a child process: these scripts end with exit, which would end this script
$ps = (Get-Process -Id $PID).Path

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
if ($inside -ne 'true' -and (Test-Path -LiteralPath (Join-Path $Root '.install-manifest.json'))) {
    # installed by setup.ps1: no git, the config comes as GitHub's ZIP
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-config.ps1') -Root $Root
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'The config could not be updated - installing the build this folder pins meanwhile.' -ForegroundColor Yellow
        $failed++
    }
}
elseif (-not $git) {
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

# -- 4. the FastStream helper the one-click install set up -------------------------
$marker = Join-Path $env:LOCALAPPDATA 'FastStreamMpvHost\installed-by-mpv-config.json'
if (-not $NoFastStream -and (Test-Path -LiteralPath $marker)) {
    Write-Host '== FastStream helper' -ForegroundColor Cyan
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-faststream.ps1') -MpvExe (Join-Path $Root 'mpv.exe') -HelperOnly -Yes
    if ($LASTEXITCODE -ne 0) { $failed++ }
}

if ($failed) {
    Write-Host "`nDone, with $failed problem(s) above." -ForegroundColor Red
    exit 1
}
Write-Host "`nUp to date." -ForegroundColor Green
exit 0
