# install-uosc.ps1 - install uosc + thumbfast into portable_config (idempotent)
# Recreates the UI part of this setup. See RECREATE.md section 3 step 3.
#
# Both are committed in this repo, WITH local changes: uosc carries the edits
# AGENTS.md lists, and thumbfast.lua is upstream's 0f711de3 (2026-06-28) formatted
# by stylua with two functions made local. So on a clone, put them back with
#   git checkout -- portable_config/Scripts/uosc portable_config/Scripts/thumbfast.lua portable_config/fonts
# This script is for a folder without the repo's copies: it fetches upstream's,
# which lack those changes (it says so at the end). uosc's release zip holds
# scripts/uosc/ and fonts/; thumbfast is pinned to a commit.

$ErrorActionPreference = 'Stop'
# A download that stalls halfway: PowerShell 7 waits for ever (-TimeoutSec does not cover the
# body). -OperationTimeoutSeconds (7.4 and later) ends a read that gets nothing for 120 s
# (install-mpv.ps1).
$StallLimit = if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) { @{ OperationTimeoutSeconds = 120 } } else { @{} }
# Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub needs it (as install-mpv.ps1)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$cfg = Join-Path $PSScriptRoot '..\portable_config'
$scripts = Join-Path $cfg 'Scripts'
$fonts = Join-Path $cfg 'fonts'

# Both downloads are checked before anything is unpacked or installed:
# the zip against GitHub's own digest of the release asset, thumbfast.lua against the
# file at the pinned commit.
function Assert-Sha256([string]$Path, [string]$Hash, [string]$What) {
    $got = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $Hash) {
        throw "$What does not match its expected SHA-256 ($Hash, got $got): not installed."
    }
}

# --- uosc -------------------------------------------------------------------
$uoscDir = Join-Path $scripts 'uosc'
$uoscVersion = '5.13.0'  # repo tracks this exact version
$uoscSha256 = '4be9da3289285300fa374496c3f1bfd7bb20ac08e890d25bd5a06b28eebe4882'
# installed means the fonts too: they used to be copied after main.lua and never checked, so
# a run stopped in between left uosc without its icons, and every later run skipped it
$uoscFonts = @('uosc_icons.otf', 'uosc_textures.ttf')
$installed = (Test-Path (Join-Path $uoscDir 'main.lua')) -and
    -not @($uoscFonts | Where-Object { -not (Test-Path (Join-Path $fonts $_)) }).Count
$fetched = $false

if ($installed) {
    Write-Host "uosc already present at $uoscDir - skipping install" -ForegroundColor Yellow
}
else {
    Write-Host "Installing uosc v$uoscVersion ..." -ForegroundColor Cyan
    $zip = Join-Path $env:TEMP 'uosc.zip'
    $tmp = Join-Path $env:TEMP 'uosc_extract'
    try {
        $uoscUrl = "https://github.com/tomasklaen/uosc/releases/download/$uoscVersion/uosc.zip"
        Invoke-WebRequest -Uri $uoscUrl -OutFile $zip -UseBasicParsing @StallLimit
        Assert-Sha256 $zip $uoscSha256 "uosc.zip $uoscVersion"
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Join-Path $tmp 'scripts\uosc'
        if (-not (Test-Path (Join-Path $src 'main.lua'))) {
            throw "uosc.zip $uoscVersion has no scripts\uosc\main.lua - its layout changed; install it by hand"
        }
        New-Item -ItemType Directory -Force $scripts, $fonts | Out-Null
        # the fonts first: main.lua is what says "installed"
        Copy-Item (Join-Path $tmp 'fonts\*') $fonts -Recurse -Force
        Copy-Item $src $scripts -Recurse -Force
        $fetched = $true
    }
    finally {
        Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- thumbfast ---------------------------------------------------------------
$thumbfast = Join-Path $scripts 'thumbfast.lua'
if (Test-Path $thumbfast) {
    Write-Host 'thumbfast.lua already present - skipping' -ForegroundColor Yellow
}
else {
    Write-Host 'Installing thumbfast ...' -ForegroundColor Cyan
    $part = "$thumbfast.part"
    try {
        $thumbfastUrl = 'https://raw.githubusercontent.com/po5/thumbfast/0f711de3138c9bd6718209d819ac54022c23ded2/thumbfast.lua'
        Invoke-WebRequest -Uri $thumbfastUrl -OutFile $part -UseBasicParsing @StallLimit
        Assert-Sha256 $part 'a3d08e71eae8b892f6cd39f9593ea219768e709312d176bca883841b156448bf' 'thumbfast.lua at 0f711de3'
        Move-Item -LiteralPath $part -Destination $thumbfast -Force
        $fetched = $true
    }
    finally {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
}

# --- script-opts (repo tracks uosc.conf, nothing else needed) ----------------
if (-not (Test-Path (Join-Path $cfg 'script-opts\uosc.conf'))) {
    Write-Warning 'uosc.conf missing from script-opts/ - it is committed in the repo, check your clone'
}

Write-Host "`nVerify:" -ForegroundColor Green
$checks = [ordered]@{
    'uosc main.lua' = Test-Path (Join-Path $uoscDir 'main.lua')
    'uosc fonts'    = -not @($uoscFonts | Where-Object { -not (Test-Path (Join-Path $fonts $_)) }).Count
    'thumbfast'     = Test-Path $thumbfast
}
foreach ($name in $checks.Keys) { Write-Host ('  {0,-14}: {1}' -f $name, $checks[$name]) }
Write-Host "  uosc.conf     : $(Test-Path (Join-Path $cfg 'script-opts\uosc.conf'))"
if ($fetched) {
    Write-Warning ("Fetched from upstream: without this repo's local uosc changes (AGENTS.md). " +
        'In a clone, git checkout -- portable_config/Scripts/uosc portable_config/Scripts/thumbfast.lua portable_config/fonts puts them back.')
}
# a part missing is a failed install: exit 1, not a line that is easily overlooked
if ($checks.Values -contains $false) {
    Write-Host 'uosc is not complete (see above).' -ForegroundColor Red
    exit 1
}
