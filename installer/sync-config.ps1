<#
.SYNOPSIS
    Brings a folder installed by setup.ps1 (no git) to the newest config.

.DESCRIPTION
    The one-click install (installer\setup.ps1, 2026-10-09) needs no git: this
    script downloads the config as GitHub's ZIP of one commit and copies it in.
    updater.bat (installer\update.ps1) runs it again for every update of such a
    folder; a git clone keeps using git pull and is refused here.

      1. the newest commit of -Ref is looked up (GitHub's API); the folder's
         .install-manifest.json already has it: nothing to do;
      2. the ZIP of exactly that commit is downloaded and extracted. Files Git
         LFS keeps (the uosc fonts and helper, 7z\7zr.exe, mpv-single.exe) are
         small pointer files in GitHub's ZIP: each is fetched from GitHub's LFS
         media address and checked against the SHA-256 and size its pointer
         names;
      3. every file that differs is copied in (through a new name). The
         manifest lists what the last install wrote, with each file's
         SHA-256, so:
           - a file you changed is saved next to it as <name>.mine-<time>
             before the new one replaces it;
           - a file the config no longer has is deleted - unless you changed
             it, then it stays;
           - anything the config never had (your settings, watch history,
             mpv.exe, yt-dlp.exe, the shader cache) is never touched;
      4. the new manifest is written last, so an interrupted run is simply
         repeated by the next one.

    Exit codes: 0 up to date or updated, 1 error, 2 a download failed.
    Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Root
    The installed folder. Default: the folder this script sits in.

.PARAMETER Repo
    The GitHub repository. Default: Nawid3333/mpv-config.

.PARAMETER Ref
    Branch, tag or commit. Default: main.

.PARAMETER Commit
    Skip the lookup and install this commit (setup.ps1 passes the one it
    looked up). Required with -Zip.

.PARAMETER Zip
    Use this ZIP of the repository instead of downloading it (the tests do).

.PARAMETER LfsSource
    Where Git LFS files come from: a folder holding them under their repo
    paths (the tests), or a base URL. Default: GitHub's LFS media address.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$Repo = 'Nawid3333/mpv-config',
    [string]$Ref = 'main',
    [string]$Commit,
    [string]$Zip,
    [string]$LfsSource
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:failCode = 1
$ManifestName = '.install-manifest.json'

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Download([string]$Url, [string]$OutFile) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile "$OutFile.part" -UseBasicParsing -UserAgent 'mpv-config-installer' -TimeoutSec 120
    }
    catch {
        Remove-Item -LiteralPath "$OutFile.part" -Force -ErrorAction SilentlyContinue
        $script:failCode = 2
        throw "download failed: $Url : $($_.Exception.Message)"
    }
    Move-Item -LiteralPath "$OutFile.part" -Destination $OutFile -Force
}

# a relative path from the ZIP may never leave the folder
function Test-SafePath([string]$Rel) {
    if ($Rel -match '(^|/)\.\.(/|$)' -or $Rel -match '^/' -or $Rel -match ':' -or $Rel -match '\\') { return $false }
    return $Rel -notmatch '^\.git(/|$)'
}

# Git LFS pointer: "version https://git-lfs.github.com/spec/v1", "oid sha256:<hex>", "size <n>"
function Get-LfsPointer([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt 1024) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if (-not $text.StartsWith('version https://git-lfs.github.com/spec/')) { return $null }
    if ($text -notmatch 'oid sha256:([0-9a-f]{64})') { throw "$Path is an LFS pointer without a sha256 oid" }
    $oid = $Matches[1]
    if ($text -notmatch '(?m)^size (\d+)') { throw "$Path is an LFS pointer without a size" }
    return [pscustomobject]@{ Oid = $oid; Size = [long]$Matches[1] }
}

function Copy-Over([string]$Source, [string]$Target) {
    $dir = Split-Path -Parent $Target
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $tmp = "$Target.new"
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    try {
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
        Move-Item -LiteralPath $tmp -Destination $Target
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Assert-MpvNotRunning([string]$Root) {
    $running = @(Get-Process mpv -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($running.Count) { throw "mpv is running from $Root (pid $($running.Id -join ', ')) - close it and run this again" }
}

try {
    if (-not (Test-Path -LiteralPath $Root)) { $null = New-Item -ItemType Directory -Force -Path $Root }
    $Root = (Resolve-Path -LiteralPath $Root).Path
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
        throw "$Root is a git clone - update it with git pull (updater.bat does), not with this script"
    }
    $manifestPath = Join-Path $Root $ManifestName
    $old = @{}
    $oldCommit = ''
    if (Test-Path -LiteralPath $manifestPath) {
        $m = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $oldCommit = "$($m.commit)"
        foreach ($p in $m.files.PSObject.Properties) { $old[$p.Name] = "$($p.Value)" }
        # an update follows what was installed, unless told otherwise
        if (-not $PSBoundParameters.ContainsKey('Repo') -and $m.repo) { $Repo = "$($m.repo)" }
        if (-not $PSBoundParameters.ContainsKey('Ref') -and $m.ref) { $Ref = "$($m.ref)" }
    }

    if ($Zip -and -not $Commit) { throw '-Zip needs -Commit (the commit the ZIP was made from)' }
    if (-not $Commit) {
        try {
            $Commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/commits/$Ref" -UseBasicParsing -TimeoutSec 60 `
                -Headers @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = 'mpv-config-installer' }
        }
        catch {
            $script:failCode = 2
            throw "could not ask GitHub for the newest config ($Repo $Ref): $($_.Exception.Message)"
        }
        $Commit = "$Commit".Trim()
    }
    if ($Commit -notmatch '^[0-9a-f]{40}$') { throw "not a commit: '$Commit'" }
    $short = $Commit.Substring(0, 7)
    if ($oldCommit -eq $Commit) {
        Write-Host "The config is up to date ($short)." -ForegroundColor Green
        exit 0
    }

    Assert-MpvNotRunning $Root

    $work = Join-Path ([IO.Path]::GetTempPath()) ('mpv-config-sync-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work
    try {
        if ($Zip) {
            $zipFile = (Resolve-Path -LiteralPath $Zip).Path
        }
        else {
            $zipFile = Join-Path $work 'config.zip'
            Write-Host "Downloading the config ($short) ..." -ForegroundColor Cyan
            Invoke-Download "https://codeload.github.com/$Repo/zip/$Commit" $zipFile
        }
        $x = Join-Path $work 'x'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $x)
        # GitHub puts everything in one folder named <repo>-<commit>
        $top = @(Get-ChildItem -LiteralPath $x -Force)
        $src = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $x }

        $new = [ordered]@{}
        $lfsCount = 0
        $lfsKept = 0
        foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File -Force) {
            $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/').Replace('\', '/')
            if (-not (Test-SafePath $rel)) { throw "the ZIP holds a path outside the folder: $rel" }
            $ptr = Get-LfsPointer $f.FullName
            if ($ptr) {
                $lfsCount++
                $tmp = Join-Path $work ('lfs-' + $ptr.Oid)
                $installed = Join-Path $Root $rel
                if (-not $LfsSource) { $LfsSource = "https://media.githubusercontent.com/media/$Repo/$Commit" }
                if ((Get-Sha256 $installed) -eq $ptr.Oid) {
                    # already here (2026-10-09: every update downloaded all ~19 MB again)
                    Copy-Item -LiteralPath $installed -Destination $tmp
                    $lfsKept++
                }
                elseif (Test-Path -LiteralPath $LfsSource -PathType Container) {
                    Copy-Item -LiteralPath (Join-Path $LfsSource $rel) -Destination $tmp
                }
                else {
                    $url = $LfsSource.TrimEnd('/') + '/' + (($rel -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
                    Invoke-Download $url $tmp
                }
                $got = Get-Sha256 $tmp
                if ($got -ne $ptr.Oid -or (Get-Item -LiteralPath $tmp).Length -ne $ptr.Size) {
                    throw "$rel (Git LFS): the download is not the file the config names (sha256 $got, expected $($ptr.Oid)) - nothing changed"
                }
                Copy-Item -LiteralPath $tmp -Destination $f.FullName -Force
            }
            $new[$rel] = Get-Sha256 $f.FullName
        }
        if (-not $new.Contains('mpv-build.json') -or -not $new.Contains('portable_config/mpv.conf')) {
            throw 'the download is not this config (no mpv-build.json or portable_config/mpv.conf) - nothing changed'
        }

        # the download is complete and checked; only now does anything in the folder change
        Assert-MpvNotRunning $Root
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $written = 0; $removed = 0
        $saved = [Collections.Generic.List[string]]::new()
        $keptGone = [Collections.Generic.List[string]]::new()
        foreach ($rel in $new.Keys) {
            $target = Join-Path $Root $rel
            $cur = Get-Sha256 $target
            if ($cur -eq $new[$rel]) { continue }
            # yours: changed since the last install, or never installed by it
            if ($null -ne $cur -and (-not $old.ContainsKey($rel) -or $old[$rel] -ne $cur)) {
                Copy-Item -LiteralPath $target -Destination "$target.mine-$stamp"
                $saved.Add("$rel.mine-$stamp")
            }
            Copy-Over (Join-Path $src $rel) $target
            $written++
        }
        foreach ($rel in @($old.Keys | Where-Object { -not $new.Contains($_) })) {
            $target = Join-Path $Root $rel
            $cur = Get-Sha256 $target
            if ($null -eq $cur) { continue }
            if ($cur -eq $old[$rel]) {
                Remove-Item -LiteralPath $target -Force
                $removed++
                # and the folders it leaves empty, up to the root
                $dir = Split-Path -Parent $target
                while ($dir.Length -gt $Root.Length -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
                    Remove-Item -LiteralPath $dir -Force
                    $dir = Split-Path -Parent $dir
                }
            }
            else {
                $keptGone.Add($rel)
            }
        }

        $manifest = [ordered]@{
            repo = $Repo; ref = $Ref; commit = $Commit
            installed = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            files = $new
        }
        $json = $manifest | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText("$manifestPath.new", $json, (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath "$manifestPath.new" -Destination $manifestPath -Force
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $from = if ($oldCommit) { "$($oldCommit.Substring(0, 7)) -> $short" } else { $short }
    Write-Host "Config installed ($from): $written file(s) written, $removed removed, $lfsCount from Git LFS ($($lfsCount - $lfsKept) downloaded)." -ForegroundColor Green
    foreach ($s in $saved) { Write-Host "  your changed file was saved as $s" -ForegroundColor Yellow }
    foreach ($k in $keptGone) { Write-Host "  kept $k - the config no longer has it, but you changed it" -ForegroundColor Yellow }
    exit 0
}
catch {
    Write-Host "sync-config: $($_.Exception.Message)" -ForegroundColor Red
    exit $script:failCode
}
