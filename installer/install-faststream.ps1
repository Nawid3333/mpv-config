<#
.SYNOPSIS
    Connects this mpv to FastStream in Firefox: the mpv helper (with its own
    Node.js) and the FastStream add-on.

.DESCRIPTION
    Part of the one-click install (installer\setup.ps1, 2026-10-09); updater.bat
    runs it again with -HelperOnly. FastStream (github.com/Nawid3333/FastStream)
    is a Firefox add-on that hands a browser video to mpv; a browser add-on
    cannot start programs, so a small helper (the fork's native-host folder)
    is registered for Firefox once.

      1. The newest FastStream release is read from its updates.json (the file
         Firefox itself updates the add-on from): version, the signed .xpi and
         its SHA-256.
      2. The helper: the fork's native-host\install.ps1 and
         faststream-mpv-host.mjs of exactly that release (the add-on and the
         helper must match), installed by the fork's own install.ps1 into
         %LOCALAPPDATA%\FastStreamMpvHost and registered under HKCU (no admin),
         pointed at this mpv.exe. It runs on Node.js: a private copy of the
         current LTS node.exe is kept in the helper's folder (node\node.exe,
         checked against nodejs.org's SHA256 list) - nothing is installed for
         the whole PC and nothing is added to PATH. A helper this script did
         not install (a FastStream developer's own) is only replaced when you
         say so (-Replace, or yes at the question).
      3. The add-on: unless Firefox already has it, the .xpi is downloaded,
         checked, and opened in Firefox, which asks to add it (one click).
         Firefox keeps it updated from then on.

    Exit codes: 0 done (also when a part was skipped on purpose), 1 error,
    2 a download failed. Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER MpvExe
    The mpv.exe FastStream should start. Default: the one next to this folder.

.PARAMETER HelperDir
    Where the helper goes. Default: %LOCALAPPDATA%\FastStreamMpvHost (the
    fork's own default, which its documentation and uninstall steps name).

.PARAMETER HelperOnly
    Only bring a helper this script installed to the newest release (updater.bat).

.PARAMETER Replace
    Replace a helper this script did not install without asking.

.PARAMETER Yes
    Ask nothing: a helper this script did not install is then left alone.

.PARAMETER NoFirefox
    Do not open the add-on in Firefox.

.PARAMETER NoRegister
    Do not register the helper for Firefox (the tests).

.PARAMETER UpdatesJson
    The release information (a URL or a file; the tests pass a file).

.PARAMETER HelperSource
    A folder with install.ps1 and faststream-mpv-host.mjs to use instead of
    downloading them (the tests).

.PARAMETER NodeDist
    Where Node.js comes from: a URL or a folder laid out like
    nodejs.org/dist (index.json, v<x>/SHASUMS256.txt, v<x>/node-v<x>-win-x64.zip).
#>
[CmdletBinding()]
param(
    [string]$MpvExe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'mpv.exe'),
    [string]$HelperDir = (Join-Path $env:LOCALAPPDATA 'FastStreamMpvHost'),
    [string]$Repo = 'Nawid3333/FastStream',
    [switch]$HelperOnly,
    [switch]$Replace,
    [switch]$Yes,
    [switch]$NoFirefox,
    [switch]$NoRegister,
    [string]$UpdatesJson,
    [string]$HelperSource,
    [string]$NodeDist = 'https://nodejs.org/dist'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:failCode = 1
$AddonId = 'thanatus@Nawid'
$MarkerName = 'installed-by-mpv-config.json'
$NodeMinMajor = 22

# A native program's output, stderr included. Windows PowerShell 5.1 turns every stderr
# line into a terminating error under 'Stop' once 2>&1 redirects it (checked
# 2026-10-09: a single warning from mpv, 7-Zip or FastStream's install.ps1 ended the
# install); the exit code decides here.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# $Base is a URL or a local folder (the tests); $Rel a path below it
function Get-Source([string]$Base, [string]$Rel, [string]$OutFile) {
    if (Test-Path -LiteralPath $Base -PathType Container) {
        Copy-Item -LiteralPath (Join-Path $Base $Rel) -Destination $OutFile -Force
        return
    }
    $url = $Base.TrimEnd('/') + '/' + $Rel
    try {
        Invoke-WebRequest -Uri $url -OutFile "$OutFile.part" -UseBasicParsing -UserAgent 'mpv-config-installer' -TimeoutSec 300
    }
    catch {
        Remove-Item -LiteralPath "$OutFile.part" -Force -ErrorAction SilentlyContinue
        $script:failCode = 2
        throw "download failed: $url : $($_.Exception.Message)"
    }
    Move-Item -LiteralPath "$OutFile.part" -Destination $OutFile -Force
}

function Read-Json([string]$PathOrUrl) {
    if (Test-Path -LiteralPath $PathOrUrl -PathType Leaf) { return Get-Content -Raw -LiteralPath $PathOrUrl | ConvertFrom-Json }
    try { return Invoke-RestMethod -Uri $PathOrUrl -UseBasicParsing -TimeoutSec 60 -UserAgent 'mpv-config-installer' }
    catch {
        $script:failCode = 2
        throw "download failed: $PathOrUrl : $($_.Exception.Message)"
    }
}

function Get-NodeMajor([string]$Exe) {
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return 0 }
    $ErrorActionPreference = 'Continue'
    try { $v = & $Exe --version 2>$null } catch { $v = '' }
    if ($LASTEXITCODE -eq 0 -and "$v" -match '^v(\d+)\.') { return [int]$Matches[1] }
    return 0
}

# A node.exe of the current LTS for the helper alone, in <HelperDir>\node.
function Install-PrivateNode([string]$Dir, [string]$Work, [string]$Dist) {
    $exe = Join-Path $Dir 'node.exe'
    $major = Get-NodeMajor $exe
    if ($major -ge $NodeMinMajor) {
        Write-Host "Node.js for the helper: v$major is there."
        return $exe
    }
    $index = if (Test-Path -LiteralPath $Dist -PathType Container) { Read-Json (Join-Path $Dist 'index.json') } else { Read-Json "$($Dist.TrimEnd('/'))/index.json" }
    $rel = @($index | Where-Object { $_.lts -and @($_.files) -contains 'win-x64-zip' })[0]
    if (-not $rel) { throw 'nodejs.org lists no LTS release for Windows x64' }
    $ver = "$($rel.version)"
    $name = "node-$ver-win-x64"
    Write-Host "Downloading Node.js $ver for the helper (~30 MB) ..." -ForegroundColor Cyan
    $sums = Join-Path $Work 'SHASUMS256.txt'
    Get-Source $Dist "$ver/SHASUMS256.txt" $sums
    $line = @(Get-Content -LiteralPath $sums | Where-Object { $_ -match "^([0-9a-f]{64})\s+$([regex]::Escape("$name.zip"))$" })[0]
    if (-not $line) { throw "SHASUMS256.txt of Node.js $ver does not list $name.zip" }
    $want = ($line -split '\s+')[0]
    $zip = Join-Path $Work "$name.zip"
    Get-Source $Dist "$ver/$name.zip" $zip
    $got = Get-Sha256 $zip
    if ($got -ne $want) { throw "$name.zip: sha256 $got does not match nodejs.org's $want" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $archive.GetEntry("$name/node.exe")
        if (-not $entry) { throw "$name.zip has no node.exe" }
        $null = New-Item -ItemType Directory -Force -Path $Dir
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$exe.new", $true)
    }
    finally { $archive.Dispose() }
    Move-Item -LiteralPath "$exe.new" -Destination $exe -Force
    if ((Get-NodeMajor $exe) -lt $NodeMinMajor) { throw "the downloaded node.exe does not run" }
    Write-Host "Node.js $ver installed for the helper." -ForegroundColor Green
    return $exe
}

function Find-Firefox {
    foreach ($hive in 'HKCU:', 'HKLM:') {
        $p = Get-ItemPropertyValue -ErrorAction SilentlyContinue "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe" '(default)'
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    foreach ($p in "$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe", "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe") {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Test-AddonInstalled {
    $profiles = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $profiles)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName "extensions\$AddonId.xpi")
        })
}

function Read-YesNo([string]$Question, [bool]$NoQuestions) {
    if ($NoQuestions) { return $false }
    try { $a = Read-Host "$Question [y/N]" } catch { return $false }
    return $a -match '^(y|yes|j|ja)$'
}

try {
    $MpvExe = [IO.Path]::GetFullPath($MpvExe)
    $work = Join-Path ([IO.Path]::GetTempPath()) ('faststream-setup-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work
    try {
        # -- the newest release -------------------------------------------------------------
        if (-not $UpdatesJson) { $UpdatesJson = "https://github.com/$Repo/releases/latest/download/updates.json" }
        $updates = Read-Json $UpdatesJson
        $entry = @($updates.addons.$AddonId.updates)[-1]
        if (-not $entry -or "$($entry.version)" -notmatch '^\d+(\.\d+)+$' -or "$($entry.update_hash)" -notmatch '^sha256:([0-9a-f]{64})$') {
            throw "$UpdatesJson does not describe a FastStream release"
        }
        $xpiHash = $Matches[1]
        $version = "$($entry.version)"
        Write-Host "FastStream $version" -ForegroundColor Cyan

        # -- the helper -------------------------------------------------------------------------
        $marker = Join-Path $HelperDir $MarkerName
        $existing = Test-Path -LiteralPath (Join-Path $HelperDir 'config.json')
        $ours = Test-Path -LiteralPath $marker
        $doHelper = $true
        if ($existing -and -not $ours) {
            $cfg = try { Get-Content -Raw -LiteralPath (Join-Path $HelperDir 'config.json') | ConvertFrom-Json } catch { $null }
            $points = if ($cfg -and $cfg.mpvPath) { " (it starts $($cfg.mpvPath))" } else { '' }
            if ($Replace) { Write-Host "Replacing the FastStream helper that was already installed$points." }
            elseif ($HelperOnly) { $doHelper = $false }
            elseif (Read-YesNo "A FastStream helper is already installed$points. Replace it, so FastStream opens THIS mpv?" $Yes) { }
            else {
                $doHelper = $false
                Write-Host 'The helper that was already installed stays as it is.' -ForegroundColor Yellow
            }
        }
        elseif ($HelperOnly -and -not $ours) {
            $doHelper = $false
        }
        if ($doHelper -and $ours) {
            $m = try { Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json } catch { $null }
            if ($HelperOnly -and $m -and "$($m.mpv)" -ne $MpvExe) {
                # set up for another mpv folder: that folder's updater looks after it
                Write-Host "The FastStream helper starts $($m.mpv), not this mpv: left as it is."
                $doHelper = $false
            }
            elseif ($m -and "$($m.version)" -eq $version -and "$($m.mpv)" -eq $MpvExe -and (Get-NodeMajor "$($m.node)") -ge $NodeMinMajor) {
                Write-Host "The FastStream helper is up to date ($version)." -ForegroundColor Green
                $doHelper = $false
            }
        }
        if ($doHelper) {
            if (-not (Test-Path -LiteralPath $MpvExe)) { throw "no mpv.exe at $MpvExe - install mpv first" }
            $node = Install-PrivateNode (Join-Path $HelperDir 'node') $work $NodeDist
            $hs = Join-Path $work 'native-host'
            $null = New-Item -ItemType Directory -Path $hs
            foreach ($f in 'install.ps1', 'faststream-mpv-host.mjs') {
                if ($HelperSource) { Copy-Item -LiteralPath (Join-Path $HelperSource $f) -Destination (Join-Path $hs $f) }
                else { Get-Source "https://raw.githubusercontent.com/$Repo/v$version/native-host" $f (Join-Path $hs $f) }
            }
            # the fork's own installer, as its documentation runs it (Windows PowerShell 5.1)
            $ps = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source
            if (-not $ps) { $ps = (Get-Process -Id $PID).Path }
            $hostArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $hs 'install.ps1'),
                '-MpvPath', $MpvExe, '-NodePath', $node, '-InstallDir', $HelperDir)
            if ($NoRegister) { $hostArgs += '-NoRegister' }
            $r = Invoke-Native $ps $hostArgs
            if ($r.Code -ne 0) { throw "the helper's install.ps1 failed (exit $($r.Code)): $($r.Out -join ' ')" }
            $info = [ordered]@{ version = $version; mpv = $MpvExe; node = $node; installed = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            [IO.File]::WriteAllText($marker, ($info | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
            Write-Host "FastStream helper $version installed: it starts $MpvExe." -ForegroundColor Green
        }

        # -- the add-on ---------------------------------------------------------------------------
        if (-not $HelperOnly -and -not $NoFirefox) {
            $firefox = Find-Firefox
            if (-not $firefox) {
                Write-Host 'Firefox is not installed. FastStream is a Firefox add-on: install Firefox (https://www.mozilla.org/firefox/), then run the setup again.' -ForegroundColor Yellow
            }
            elseif (Test-AddonInstalled) {
                Write-Host 'FastStream is already in Firefox (Firefox keeps it updated).' -ForegroundColor Green
            }
            else {
                $xpi = Join-Path ([IO.Path]::GetTempPath()) "FastStream-$version.xpi"
                Get-Source ($entry.update_link -replace '/[^/]+$', '') ($entry.update_link -replace '^.*/', '') $xpi
                $got = Get-Sha256 $xpi
                if ($got -ne $xpiHash) {
                    Remove-Item -LiteralPath $xpi -Force -ErrorAction SilentlyContinue
                    throw "the FastStream add-on download is not the signed release (sha256 $got, expected $xpiHash)"
                }
                Start-Process -FilePath $firefox -ArgumentList ('"' + $xpi + '"')
                Write-Host 'Firefox opens and asks to add FastStream: click "Add".' -ForegroundColor Green
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}
catch {
    Write-Host "install-faststream: $($_.Exception.Message)" -ForegroundColor Red
    exit $script:failCode
}
