#Requires -Version 7
<#
.SYNOPSIS
    Regression tests for this mpv setup: every feature the config ships, checked
    against a real mpv so an edit or an update cannot silently break one.

.DESCRIPTION
    Three tiers, each including the ones before it:

      static    No mpv. Config wiring and the invariants AGENTS.md lists: every
                script-binding / script-message target exists, every shader file
                the presets name exists and is installed, the GLSL "//!" rule,
                mpv.conf profile scoping, the local uosc changes, badge widths,
                PowerShell files parse.
      headless  (default) Runs mpv with --vo=null --ao=null: no window, no GPU,
                no sound. Each tests/headless/test-*.lua drives the player
                through mpv's own input commands and reads properties back.
                Safe to run any time, also on a CI runner.
      gpu       The real renderer, FULLSCREEN, on this PC's GPU: shader cache
                warm for every chain, preset switching stress (chain correct,
                no dropped/late frames, no renderer errors, no VRAM growth),
                frame pacing at 1x and 3x. Skipped while any mpv is running,
                because you may be watching something.

    And one tier on its own, run by hand (~45 min, takes the screen): shadercost. Is the
    background shader warm-up worth keeping? 35 cases (every path the Anime
    and Movie upscalers take, SDR/HDR10/HLG/Dolby Vision with each chain,
    10-bit, CPU-decoded, a song with cover art, and mid-video actions: every
    upscale switch and sharpness level, window sizes, an overlay, the Video
    menu), each in a fresh mpv, 3 times in each state: cold (mpv's AND the AMD
    driver's shader caches empty - the driver's folder is set aside and put
    back), again (the same video once more without a warm-up) and warm (after
    the warm-up). tests/gpu/measure-shader-cost.lua measures first frame, late
    frames and the longest pause after each action, and checks that the right
    chain ran. A report (shader-cost.md in the work folder) applies the
    decision rule of 2026-10-05: DELETE, KEEP, UNCLEAR or INCOMPLETE.

    Isolation: tests never touch the real portable_config. They run a COPY of
    mpv.exe next to a COPY of portable_config in a temp folder (mpv's portable
    mode then resolves ~~/, ~~state/ and ~~cache/ inside that folder), so
    speed.json, stream-resume.json and the shader cache stay untouched. The
    gpu tier uses a copy of the real shader cache.

    Input: only mpv's own commands (keypress, keydown/keyup, mouse,
    script-message). Never OS-level keyboard/mouse injection.

.PARAMETER Tier
    static, headless (default) or gpu. `all` is the same as gpu. shadercost
    runs the static checks and the cold-vs-warm shader cache measurement only.

.PARAMETER Filter
    Wildcard on test names, e.g. -Filter upscale or -Filter 'speed*'. For
    shadercost: on the case names, e.g. -Filter 'Anime*'.

.PARAMETER MpvExe
    mpv.exe to test. Default: the one in this repo (updater.bat installs it;
    mpv.exe is not kept in git).

.PARAMETER WorkDir
    Scratch folder for the isolated copy, generated media and logs.

.PARAMETER Repeat
    shadercost only: runs per case in each state (default 3; the report uses
    the medians). -Repeat 1 for a quick look, not for the decision.

.PARAMETER ConfigDir
    portable_config to test. Default: this repo's. Point it at a copy to test
    an edit without touching the live config (or to check that the suite
    catches a deliberately broken one).

.EXAMPLE
    pwsh tests/run-tests.ps1
    pwsh tests/run-tests.ps1 -Tier gpu
    pwsh tests/run-tests.ps1 -Tier shadercost
    pwsh tests/run-tests.ps1 -Filter upscale
#>
[CmdletBinding()]
param(
    [ValidateSet('static', 'headless', 'gpu', 'all', 'shadercost')]
    [string]$Tier = 'headless',
    [string]$Filter = '*',
    [string]$MpvExe,
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'mpv-regression'),
    [string]$ConfigDir,
    [ValidateRange(1, 9)]
    [int]$Repeat = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Cfg = $ConfigDir ? (Resolve-Path $ConfigDir).Path : (Join-Path $RepoRoot 'portable_config')
$TestsDir = $PSScriptRoot
if (-not $MpvExe) { $MpvExe = Join-Path $RepoRoot 'mpv.exe' }
$RunHeadless = $Tier -notin @('static', 'shadercost')
$RunGpu = $Tier -in @('gpu', 'all')
$RunCost = $Tier -eq 'shadercost'

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Test, [string]$Check, [ValidateSet('PASS', 'FAIL', 'SKIP', 'INFO')][string]$Status, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Test = $Test; Check = $Check; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'DarkGreen'; FAIL = 'Red'; SKIP = 'Yellow'; INFO = 'DarkGray' }[$Status]
    $line = '  {0,-4}  {1}' -f $Status, $Check
    if ($Detail -and $Status -ne 'PASS') { $line += "  ::  $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Test-Check {
    param([string]$Test, [string]$Check, [bool]$Condition, [string]$Detail = '')
    Add-Result -Test $Test -Check $Check -Status ($Condition ? 'PASS' : 'FAIL') -Detail $Detail
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "== $Title" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# the one-click install (2026-10-09), offline: installer/setup.ps1, sync-config.ps1,
# install-faststream.ps1 and uninstall.ps1 against stand-ins for GitHub's ZIP, the
# Git LFS objects, FastStream's release and nodejs.org. Run as install.bat and
# updater.bat run them: in Windows PowerShell 5.1 when it is there.
# ---------------------------------------------------------------------------
function Invoke-OneClickCheck([string]$t) {
    $installer = Join-Path $RepoRoot 'installer'
    # every script Windows PowerShell 5.1 runs: it reads a UTF-8 file without a BOM
    # as ANSI, so one non-ASCII character in a string comes out garbled
    $nonAscii = @(Get-ChildItem (Join-Path $installer '*.ps1'), (Join-Path $RepoRoot '*.bat') | Where-Object {
            @([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count
        } | ForEach-Object Name)
    Test-Check $t 'installer scripts and .bat files are plain ASCII (Windows PowerShell 5.1, cmd)' ($nonAscii.Count -eq 0) ($nonAscii -join ', ')
    $state = @('.install-manifest.json', 'portable_config/input.conf.mine-20261009-120000')
    $notIgnored = @($state | Where-Object { & git -C $RepoRoot check-ignore -q --no-index -- $_; $LASTEXITCODE -ne 0 })
    Test-Check $t '.gitignore covers what the one-click install writes (its manifest, your set-aside files)' ($notIgnored.Count -eq 0) ($notIgnored -join ', ')

    $ob = Join-Path $WorkDir 'one-click'
    if (Test-Path $ob) { Remove-Item $ob -Recurse -Force }
    $null = New-Item -ItemType Directory $ob
    $shell = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source
    if (-not $shell) { $shell = 'pwsh' }
    function Invoke-Script([string]$Script, [string[]]$Arguments) {
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installer $Script) @Arguments 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join ' ') }
    }
    function Write-TestTree([string]$Dir, [hashtable]$Files) {
        foreach ($kv in $Files.GetEnumerator()) {
            $p = Join-Path $Dir $kv.Key
            New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
            Set-Content -LiteralPath $p $kv.Value -NoNewline
        }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # the config as GitHub's ZIP holds it: one folder <repo>-<commit>, Git LFS files as pointers
    function Build-ConfigZip([string]$Commit, [hashtable]$Files) {
        $src = Join-Path $ob "zip-$Commit"
        Write-TestTree (Join-Path $src "mpv-config-$Commit") $Files
        $zip = Join-Path $ob "$Commit.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
        return $zip
    }
    function Read-Manifest([string]$Root) {
        $p = Join-Path $Root '.install-manifest.json'
        if (Test-Path $p) { return Get-Content -Raw $p | ConvertFrom-Json }
        return $null
    }
    function Read-Text([string]$Path) { if (Test-Path -LiteralPath $Path) { return Get-Content -Raw -LiteralPath $Path } return $null }

    # -- sync-config.ps1 ------------------------------------------------------------------
    $lfs = Join-Path $ob 'lfs'
    $fontRel = 'portable_config/fonts/icons.otf'
    Write-TestTree $lfs @{ $fontRel = ('font bytes ' * 300) }
    $font = Join-Path $lfs $fontRel
    $fontSha = (Get-FileHash $font -Algorithm SHA256).Hash.ToLower()
    $pointer = "version https://git-lfs.github.com/spec/v1`noid sha256:$fontSha`nsize $((Get-Item $font).Length)`n"
    $c1, $c2, $c3 = ('1' * 40), ('2' * 40), ('3' * 40)
    $zip1 = Build-ConfigZip $c1 @{
        'mpv-build.json' = '{}'; 'portable_config/mpv.conf' = 'v1'; 'portable_config/input.conf' = 'keys v1'
        $fontRel = $pointer; 'old/gone.lua' = 'gone'; 'old2/edited.lua' = 'edited'
    }
    $zip2 = Build-ConfigZip $c2 @{
        'mpv-build.json' = '{}'; 'portable_config/mpv.conf' = 'v2'; 'portable_config/input.conf' = 'keys v2'; $fontRel = $pointer
    }
    $zip3 = Build-ConfigZip $c3 @{
        'mpv-build.json' = '{}'; 'portable_config/mpv.conf' = 'v3'; $fontRel = ($pointer -replace $fontSha, ('0' * 64))
    }
    $root = Join-Path $ob 'root'
    $r = Invoke-Script sync-config.ps1 @('-Root', $root, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs)
    $m = Read-Manifest $root
    Test-Check $t 'sync-config.ps1 installs the config from GitHub''s ZIP, Git LFS files fetched and checked' (
        $r.Code -eq 0 -and $m -and $m.commit -eq $c1 -and (Get-FileHash (Join-Path $root $fontRel)).Hash -eq $fontSha -and
        (Read-Text (Join-Path $root 'portable_config/mpv.conf')) -eq 'v1') $r.Out
    $r = Invoke-Script sync-config.ps1 @('-Root', $root, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs)
    Test-Check $t '... the same commit again: nothing to do' ($r.Code -eq 0 -and $r.Out -match 'up to date') $r.Out
    Set-Content -LiteralPath (Join-Path $root 'portable_config/input.conf') 'my keys' -NoNewline
    Set-Content -LiteralPath (Join-Path $root 'old2/edited.lua') 'my edit' -NoNewline
    Set-Content -LiteralPath (Join-Path $root 'portable_config/speed.json') '{"speed":3}' -NoNewline
    $r = Invoke-Script sync-config.ps1 @('-Root', $root, '-Zip', $zip2, '-Commit', $c2, '-LfsSource', $lfs)
    $mine = @(Get-ChildItem (Join-Path $root 'portable_config') -Filter 'input.conf.mine-*')
    Test-Check $t '... an update writes the new files' (
        $r.Code -eq 0 -and (Read-Manifest $root).commit -eq $c2 -and (Read-Text (Join-Path $root 'portable_config/mpv.conf')) -eq 'v2') $r.Out
    Test-Check $t '... a file you changed is set aside as <name>.mine-<time> before it is replaced' (
        (Read-Text (Join-Path $root 'portable_config/input.conf')) -eq 'keys v2' -and $mine.Count -eq 1 -and
        (Read-Text $mine[0].FullName) -eq 'my keys') $r.Out
    Test-Check $t '... a file the config dropped is deleted (and its empty folder), unless you changed it' (
        -not (Test-Path (Join-Path $root 'old')) -and (Read-Text (Join-Path $root 'old2/edited.lua')) -eq 'my edit') $r.Out
    Test-Check $t '... a file the config never had (your settings) is not touched' (
        (Read-Text (Join-Path $root 'portable_config/speed.json')) -eq '{"speed":3}') $r.Out
    $r = Invoke-Script sync-config.ps1 @('-Root', $root, '-Zip', $zip3, '-Commit', $c3, '-LfsSource', $lfs)
    Test-Check $t '... a Git LFS file that is not the one its pointer names: refused, nothing changed' (
        $r.Code -eq 1 -and $r.Out -match 'not the file' -and (Read-Manifest $root).commit -eq $c2 -and
        (Read-Text (Join-Path $root 'portable_config/mpv.conf')) -eq 'v2') $r.Out
    $clone = Join-Path $ob 'clone'
    $null = New-Item -ItemType Directory -Force (Join-Path $clone '.git')
    $r = Invoke-Script sync-config.ps1 @('-Root', $clone, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs)
    Test-Check $t '... a git clone is refused (git pull updates it)' ($r.Code -eq 1 -and $r.Out -match 'git clone') $r.Out

    # -- setup.ps1 ----------------------------------------------------------------------------
    $setup = Join-Path $installer 'setup.ps1'
    $sr = Join-Path $ob 'installed'
    $r = Invoke-Script setup.ps1 @('-InstallDir', $sr, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs,
        '-NoMpv', '-NoFastStream', '-NoFileTypes', '-NoShortcuts', '-Yes')
    Test-Check $t 'setup.ps1 installs into a new folder (config step; mpv, FastStream, Windows parts skipped)' (
        $r.Code -eq 0 -and (Read-Manifest $sr).commit -eq $c1) $r.Out
    $foreign = Join-Path $ob 'foreign'
    Write-TestTree $foreign @{ 'something.txt' = 'not ours' }
    $r = Invoke-Script setup.ps1 @('-InstallDir', $foreign, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs, '-NoMpv', '-Yes')
    Test-Check $t '... a folder with other files in it is refused' ($r.Code -eq 1 -and $r.Out -match 'not empty' -and -not (Read-Manifest $foreign)) $r.Out
    $r = Invoke-Script setup.ps1 @('-InstallDir', $clone, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs, '-NoMpv', '-Yes')
    Test-Check $t '... and so is a git clone' ($r.Code -eq 1 -and $r.Out -match 'git clone') $r.Out
    # through "irm | iex" it runs in the caller's session: an exit would close their window
    $cmd = "& ([scriptblock]::Create((Get-Content -Raw '$setup'))) -InstallDir '$foreign'; 'the session goes on'"
    $out = (& $shell -NoProfile -Command $cmd 2>&1) -join ' '
    Test-Check $t '... run as a script block (irm | iex), it returns instead of ending the caller''s PowerShell' ($out -match 'the session goes on') $out

    # -- install-faststream.ps1 ------------------------------------------------------------------
    $nodeExe = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source
    if (-not $nodeExe) {
        Add-Result $t 'install-faststream.ps1' 'SKIP' 'no node.exe to stand in for the Node.js download'
    }
    else {
        $dist = Join-Path $ob 'nodedist'
        $nv = 'v99.0.0'; $nn = "node-$nv-win-x64"
        $nz = Join-Path $ob 'nodezip'
        New-Item -ItemType Directory -Force (Join-Path $nz $nn), (Join-Path $dist $nv) | Out-Null
        Copy-Item $nodeExe (Join-Path $nz "$nn/node.exe")
        [IO.Compression.ZipFile]::CreateFromDirectory($nz, (Join-Path $dist "$nv/$nn.zip"))
        $nodeSha = (Get-FileHash (Join-Path $dist "$nv/$nn.zip") -Algorithm SHA256).Hash.ToLower()
        Set-Content (Join-Path $dist "$nv/SHASUMS256.txt") "$nodeSha  $nn.zip"
        # the newest non-LTS first: the script must take the LTS
        Set-Content (Join-Path $dist 'index.json') (@(
                @{ version = 'v100.0.0'; lts = $false; files = @('win-x64-zip') },
                @{ version = $nv; lts = 'Stand-in'; files = @('win-x64-zip', 'win-x64-msi') }) | ConvertTo-Json -Depth 3)
        $updatesJson = Join-Path $ob 'updates.json'
        Set-Content $updatesJson (@{ addons = @{ 'thanatus@Nawid' = @{ updates = @(@{
                            version = '9.9.9'; update_link = 'https://example.invalid/fs.xpi'; update_hash = 'sha256:' + ('0' * 64)
                        }) } } } | ConvertTo-Json -Depth 6)
        # the fork's install.ps1, standing in: it records what it was given
        $hs = Join-Path $ob 'helper-src'
        Write-TestTree $hs @{
            'faststream-mpv-host.mjs' = '// stand-in'
            'install.ps1'             = 'param([string]$MpvPath, [string]$NodePath, [string]$InstallDir, [switch]$NoRegister)
New-Item -ItemType Directory -Force $InstallDir | Out-Null
@{ mpvPath = $MpvPath; node = $NodePath; noRegister = [bool]$NoRegister } | ConvertTo-Json | Set-Content (Join-Path $InstallDir "config.json")'
        }
        $mpvStandIn = Join-Path $ob 'mpvdir/mpv.exe'
        Write-TestTree (Join-Path $ob 'mpvdir') @{ 'mpv.exe' = 'stand-in' }
        $hd = Join-Path $ob 'helper'
        $common = @('-NoRegister', '-NoFirefox', '-UpdatesJson', $updatesJson, '-HelperSource', $hs, '-NodeDist', $dist)
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hd) + $common)
        $cfg = if (Test-Path (Join-Path $hd 'config.json')) { Get-Content -Raw (Join-Path $hd 'config.json') | ConvertFrom-Json } else { $null }
        $privateNode = Join-Path $hd 'node\node.exe'
        Test-Check $t 'install-faststream.ps1 installs the helper of the release, on a private Node.js LTS (checked)' (
            $r.Code -eq 0 -and $cfg -and $cfg.mpvPath -eq $mpvStandIn -and $cfg.node -eq $privateNode -and $cfg.noRegister -and
            (Test-Path $privateNode) -and $r.Out -match "Node\.js $([regex]::Escape($nv))") $r.Out
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hd) + $common)
        Test-Check $t '... again: the helper is up to date, nothing downloaded' ($r.Code -eq 0 -and $r.Out -match 'up to date') $r.Out
        $other = Join-Path $ob 'other/mpv.exe'
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $other, '-HelperDir', $hd, '-HelperOnly', '-Yes') + $common)
        $cfg = Get-Content -Raw (Join-Path $hd 'config.json') | ConvertFrom-Json
        Test-Check $t '... the updater of ANOTHER mpv folder leaves it alone' ($r.Code -eq 0 -and $cfg.mpvPath -eq $mpvStandIn) $r.Out
        # a helper this script did not install (a FastStream developer's own)
        $dev = Join-Path $ob 'dev-helper'
        Write-TestTree $dev @{ 'config.json' = '{"mpvPath":"C:\\dev\\mpv.exe"}' }
        foreach ($mode in @(@('-Yes'), @('-HelperOnly', '-Yes'))) {
            $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $dev) + $mode + $common)
            Test-Check $t "... a helper it did not install stays as it is ($($mode -join ' '))" (
                $r.Code -eq 0 -and (Read-Text (Join-Path $dev 'config.json')) -match 'C:\\\\dev' -and
                -not (Test-Path (Join-Path $dev 'node'))) $r.Out
        }
        Set-Content (Join-Path $dist "$nv/SHASUMS256.txt") "$('0' * 64)  $nn.zip"
        $hd2 = Join-Path $ob 'helper2'
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hd2) + $common)
        Test-Check $t '... a Node.js download that is not the one nodejs.org lists is refused' (
            $r.Code -eq 1 -and $r.Out -match 'does not match' -and -not (Test-Path (Join-Path $hd2 'node\node.exe'))) $r.Out

        # -- uninstall.ps1 (the folder itself stays: -KeepFolder) -----------------------------------
        $marker = @{ version = '9.9.9'; mpv = (Join-Path $sr 'mpv.exe') } | ConvertTo-Json
        $ours = Join-Path $ob 'helper-ours'
        Write-TestTree $ours @{ 'installed-by-mpv-config.json' = $marker; 'config.json' = '{}' }
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', $ours)
        Test-Check $t 'uninstall.ps1 removes the FastStream helper the setup installed for this mpv' ($r.Code -eq 0 -and -not (Test-Path $ours)) $r.Out
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', $hd)
        Test-Check $t '... but not one set up for another mpv folder' ($r.Code -eq 0 -and (Test-Path (Join-Path $hd 'config.json'))) $r.Out
    }
    $r = Invoke-Script uninstall.ps1 @('-Root', $clone, '-Yes', '-KeepFolder', '-NoFileTypes')
    Test-Check $t 'uninstall.ps1 refuses a git clone' ($r.Code -eq 1 -and $r.Out -match 'git clone' -and (Test-Path $clone)) $r.Out
    $r = Invoke-Script uninstall.ps1 @('-Root', $foreign, '-Yes', '-KeepFolder', '-NoFileTypes')
    Test-Check $t '... and a folder the setup did not install' ($r.Code -eq 1 -and $r.Out -match 'not installed by the setup' -and (Test-Path $foreign)) $r.Out
    Remove-Item $ob -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# static checks
# ---------------------------------------------------------------------------
function Invoke-StaticCheck {
    $t = 'static'
    Write-Section 'static checks (no mpv)'

    $inputConf = Get-Content -Raw (Join-Path $Cfg 'input.conf')
    $uoscConf = Get-Content -Raw (Join-Path $Cfg 'script-opts/uosc.conf')
    $mpvConf = Get-Content (Join-Path $Cfg 'mpv.conf')
    $vendored = @('thumbfast.lua', 'autoload.lua')
    $ownScripts = Get-ChildItem (Join-Path $Cfg 'Scripts') -Filter *.lua -File | Where-Object Name -NotIn $vendored

    # -- input.conf lines are "<key> <command>" --------------------------------
    $bad = @()
    $n = 0
    foreach ($line in ($inputConf -split "`n")) {
        $n++
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        if ($l -notmatch '^\S+\s+\S') { $bad += "line ${n}: $l" }
    }
    Test-Check $t 'input.conf: every binding line is "<key> <command>"' ($bad.Count -eq 0) ($bad -join '; ')

    # -- script-binding / script-message-to targets are registered --------------
    # script name = file name without .lua, '-' -> '_' (mpv's rule)
    $sources = @{}
    foreach ($f in Get-ChildItem (Join-Path $Cfg 'Scripts') -Filter *.lua -File) {
        $sources[$f.BaseName -replace '-', '_'] = Get-Content -Raw $f.FullName
    }
    $sources['uosc'] = (Get-ChildItem (Join-Path $Cfg 'Scripts/uosc') -Recurse -Filter *.lua -File |
        ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
    # folder scripts: mpv runs Scripts/<name>/main.lua as <name> (shader-cache -> shader_cache)
    foreach ($d in Get-ChildItem (Join-Path $Cfg 'Scripts') -Directory) {
        $main = Join-Path $d.FullName 'main.lua'
        if ($d.Name -ne 'uosc' -and (Test-Path $main)) { $sources[$d.Name -replace '-', '_'] = Get-Content -Raw $main }
    }
    # built-in mpv scripts referenced from input.conf (not in this repo)
    $builtin = @{
        stats    = @('display-page-1', 'display-stats-toggle')
        commands = @('open')
        select   = @('show-properties', 'edit-input-conf')
    }

    $refText = @($inputConf, $uoscConf) + @($ownScripts | ForEach-Object { Get-Content -Raw $_.FullName })
    $refs = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($text in $refText) {
        foreach ($m in [regex]::Matches($text, 'script-binding\s+(\w+)/([\w-]+)')) {
            [void]$refs.Add("binding|$($m.Groups[1].Value)|$($m.Groups[2].Value)")
        }
        foreach ($m in [regex]::Matches($text, "script-message-to['""]?\s*,?\s*['""]?(\w+)(?![\w.(])['""]?\s*,?\s*['""]?([\w-]+)")) {
            [void]$refs.Add("message|$($m.Groups[1].Value)|$($m.Groups[2].Value)")
        }
    }
    $missing = @()
    foreach ($r in $refs) {
        $kind, $script, $name = $r -split '\|'
        if ($builtin.ContainsKey($script)) {
            if ($name -notin $builtin[$script]) { $missing += "$kind $script/$name (built-in, not allow-listed)" }
            continue
        }
        if (-not $sources.ContainsKey($script)) { $missing += "$kind $script/$name (no such script)"; continue }
        $src = $sources[$script]
        $esc = [regex]::Escape($name)
        $found = if ($kind -eq 'binding') {
            $src -match "add_(forced_)?key_binding\s*\(\s*[^,]+,\s*['""]$esc['""]" -or $src -match "bind_command\(\s*['""]$esc['""]"
        }
        else {
            $src -match "register_script_message\(\s*['""]$esc['""]"
        }
        if (-not $found) { $missing += "$kind $script/$name" }
    }
    Test-Check $t "script-binding / script-message-to targets are registered ($($refs.Count) refs)" ($missing.Count -eq 0) ($missing -join '; ')
    # script-binding only finds add_key_binding names, script-message-to only
    # register_script_message names (AGENTS.md validation item 2) - the check
    # above keys each reference kind to the matching registration call.

    # -- every message is a notify.lua banner (2026-09-26) ----------------------
    # One design for all messages: our scripts send them to notify.lua, never
    # to mpv's own OSD text (comment lines are skipped). input.conf's s/d use
    # no-osd + speed_button/show-speed for the same reason.
    $ownLua = @($ownScripts) + @(Get-ChildItem (Join-Path $Cfg 'Scripts/shader-cache') -Filter *.lua -File)
    $osdCalls = @()
    foreach ($f in $ownLua) {
        $i = 0
        foreach ($line in Get-Content $f.FullName) {
            $i++
            if ($line -notmatch '^\s*--' -and $line -match 'osd_message\s*\(|show-text|show_text') { $osdCalls += "$($f.Name):$i" }
        }
    }
    Test-Check $t 'our scripts show messages as notify.lua banners, not mpv OSD text' ($osdCalls.Count -eq 0) ($osdCalls -join ', ')
    $osdMsg = @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s]+\s+osd-msg\s' })
    Test-Check $t 'input.conf: no binding forces mpv OSD text (osd-msg)' ($osdMsg.Count -eq 0) ($osdMsg -join ' | ')
    $osdStyle = @(@('profile=osd-box', 'osd-align-x=right', 'osd-align-y=top') | Where-Object { $_ -notin $mpvConf })
    Test-Check $t 'mpv.conf styles mpv OSD text like the banners (osd-box, top right)' ($osdStyle.Count -eq 0) ($osdStyle -join ', ')
    Test-Check $t 'uosc.conf: adjust_osd_margins=no (notify.lua places mpv OSD text)' ($uoscConf -match '(?m)^adjust_osd_margins=no\s*$')

    # -- shader presets: files exist, are installed, and nothing is orphaned ----
    $toggles = Get-Content -Raw (Join-Path $Cfg 'Scripts/gpu-toggles.lua')
    $named = @([regex]::Matches($toggles, "'([\w.-]+\.glsl)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $shaderDir = Join-Path $Cfg 'shaders'
    $absent = @($named | Where-Object { -not (Test-Path (Join-Path $shaderDir $_)) })
    Test-Check $t "every shader gpu-toggles.lua names exists ($($named.Count) files)" ($absent.Count -eq 0) ($absent -join ', ')
    $installer = Get-Content -Raw (Join-Path $RepoRoot 'installer/install-shaders.ps1')
    $notInstalled = @($named | Where-Object { $installer -notmatch [regex]::Escape($_) })
    Test-Check $t 'install-shaders.ps1 installs every preset shader' ($notInstalled.Count -eq 0) ($notInstalled -join ', ')
    $orphans = @(Get-ChildItem $shaderDir -Filter *.glsl | Where-Object Name -NotIn $named | ForEach-Object Name)
    Test-Check $t 'no unused shader files in portable_config/shaders' ($orphans.Count -eq 0) ($orphans -join ', ')

    # -- GLSL: mpv/libplacebo end a block at the next "//!" ANYWHERE on a line --
    $glslBad = @()
    foreach ($f in Get-ChildItem $shaderDir -Filter *.glsl) {
        $i = 0
        foreach ($line in Get-Content $f.FullName) {
            $i++
            $pos = $line.IndexOf('//!')
            if ($pos -gt 0) { $glslBad += "$($f.Name):$i" }
        }
    }
    Test-Check $t 'GLSL: "//!" only at the start of a line (directive)' ($glslBad.Count -eq 0) ($glslBad -join ', ')

    # -- mpv.conf -------------------------------------------------------------
    $section = ''
    $global = @{}
    $profiles = [ordered]@{}
    foreach ($line in $mpvConf) {
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        if ($l -match '^\[(.+)\]$') { $section = $Matches[1]; $profiles[$section] = @(); continue }
        $key = ($l -split '=', 2)[0].Trim()
        if ($section) { $profiles[$section] += $key } else { $global[$key] = ($l -split '=', 2)[1] }
    }
    # '#' starts a comment ANYWHERE on an mpv.conf line, inside a value too:
    # "osd-back-color=#FF000000" is read as an empty value, mpv logs one error
    # line and plays on without the option (2026-09-26). Colours: r/g/b/a or
    # gray/a (0.0/1.0 = opaque black). A trailing "  # note" after a space is fine.
    $hashBad = @()
    $n = 0
    foreach ($line in $mpvConf) {
        $n++
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith('#') -or $l -notmatch '=') { continue }
        $value = (($l -split '=', 2)[1]) -replace '"[^"]*"|''[^'']*''', ''
        if ($value -match '^\s*#' -or $value -match '\S#') { $hashBad += "line ${n}: $l" }
    }
    Test-Check $t "mpv.conf: no '#' inside a value (it starts a comment - use r/g/b/a colours)" ($hashBad.Count -eq 0) ($hashBad -join ' | ')
    Test-Check $t 'mpv.conf: vo=gpu-next set explicitly (global)' ($global['vo'] -eq 'gpu-next') "vo=$($global['vo'])"
    Test-Check $t 'mpv.conf: window-dragging=no (click never becomes a drag)' ($global['window-dragging'] -eq 'no')
    # Snap Layouts and snap-on-drag need the system caption (WM_NCHITTEST ->
    # HTCAPTION/HTMAXBUTTON); with border=no mpv answers only edges and client area.
    Test-Check $t 'mpv.conf: native title bar (border=yes, title-bar not off)' (
        $global['border'] -eq 'yes' -and $global['title-bar'] -ne 'no')
    # Options each profile may set. A profile swallowing anything else is how
    # the 2026-09-21 bug happened (cache/buffer options scoped to FastStream
    # only). Adding a profile or an option to one: extend this list on purpose.
    $profileAllow = @{ 'hdr-target-peak' = @('target-peak') }
    $scopeBad = @()
    foreach ($p in $profiles.Keys) {
        if (-not $profileAllow.ContainsKey($p)) { $scopeBad += "unknown profile [$p] (add it to `$profileAllow in run-tests.ps1)"; continue }
        $extra = @($profiles[$p] | Where-Object { $_ -notlike 'profile-*' -and $_ -notin $profileAllow[$p] })
        if ($extra) { $scopeBad += "[$p] also sets: $($extra -join ', ') - global options belong ABOVE the profile block" }
    }
    Test-Check $t 'mpv.conf: profile sections contain only their own options' ($scopeBad.Count -eq 0) ($scopeBad -join '; ')

    # No vulkan video decoding anywhere (2026-10-04): with the daily builds from
    # 20261002 on, hwdec=vulkan (then FastStream's [faststream-hwdec]) lost the
    # GPU device on this RX 9070 XT - VK_ERROR_DEVICE_LOST, the window gone, the
    # driver failed until a restart. "auto" picks vulkan on this Vulkan context.
    # The warm-up decodes the way the player does, so it may not use vulkan either.
    $vkConf = @($mpvConf | Where-Object { $_ -match '^\s*hwdec\s*=.*\b(vulkan|auto)' })
    Test-Check $t 'mpv.conf: no hwdec with vulkan or auto (vulkan decoding lost the GPU device)' ($vkConf.Count -eq 0) ($vkConf -join ' | ')
    $vkInput = @(($inputConf -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\bhwdec\b.*\b(vulkan|auto)\b' })
    Test-Check $t 'input.conf: no binding sets hwdec to vulkan or auto' ($vkInput.Count -eq 0) ($vkInput -join ' | ')
    $vkWarm = @()
    foreach ($f in 'warmup.lua', 'shipped-cases.lua') {
        $i = 0
        foreach ($line in Get-Content (Join-Path $Cfg "Scripts/shader-cache/$f")) {
            $i++
            if ($line -match '^\s*--') { continue }
            # any 'vulkan' string but warmup.lua's decoder_for(), which maps it away
            if ($line -match "['""]vulkan['""]" -and $line -notmatch ':find\(') { $vkWarm += "${f}:$i" }
        }
    }
    Test-Check $t 'shader warm-up: no case or run decodes with vulkan' ($vkWarm.Count -eq 0) ($vkWarm -join ', ')

    # -- input.conf specifics --------------------------------------------------
    Test-Check $t 'input.conf: no seek key flashes the timeline (seeks are silent)' ($inputConf -notmatch 'flash-timeline')
    $seekLines = @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s]+\s+(osd-\w+\s+)?seek\b' })
    Test-Check $t 'input.conf: every seek binding is no-osd' ($seekLines.Count -eq 0) ($seekLines -join ' | ')
    Test-Check $t 'input.conf: mbtn_left = play/pause' ($inputConf -match '(?m)^mbtn_left\s+cycle pause')
    Test-Check $t 'input.conf: mbtn_left_dbl = fullscreen' ($inputConf -match '(?m)^mbtn_left_dbl\s+cycle fullscreen')
    # -cmatch: mpv key names are case-sensitive (q is a speed key here, Q is mpv's quit-watch-later)
    $quitKeys = @(($inputConf -split "`n") | Where-Object { $_ -cmatch '^\s*((?i:ctrl\+[wc])|Q)\s' })
    Test-Check $t "input.conf: mpv's own quit keys (Ctrl+w, Ctrl+c, Q) are not rebound" ($quitKeys.Count -eq 0) ($quitKeys -join ' | ')

    # -- uosc: config + the local changes that an update would drop --------------
    Test-Check $t 'uosc.conf: proximity 10000/10100 (whole UI shows together)' (
        $uoscConf -match '(?m)^proximity_in=10000' -and $uoscConf -match '(?m)^proximity_out=10100')
    foreach ($b in 'button:speed', 'button:upscale', 'button:subtitle_sync', 'button:source') {
        Test-Check $t "uosc.conf: controls has $b" ($uoscConf -match "(?m)^controls=.*\b$([regex]::Escape($b))\b")
    }
    $localChanges = @{
        'elements/Button.lua'        = 'Local change'
        'elements/ManagedButton.lua' = 'Local change'
        'elements/Timeline.lua'      = 'Local change'
        'main.lua'                   = 'Local change'
        'lib/buttons.lua'            = 'menu_command'
    }
    $uoscMain = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/main.lua')
    Test-Check $t 'uosc local change present: main.lua publishes user-data/uosc/bottom-ui (music-info.lua, subtitle-sync.lua)' (
        $uoscMain.Contains("'user-data/uosc/bottom-ui'") -and $uoscMain.Contains('volume = volume_box')) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: main.lua publishes user-data/uosc/ui-scale (notify, subtitle-sync, music-info)' (
        $uoscMain.Contains("'user-data/uosc/ui-scale'")) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: main.lua draws the buffer for streams only (local files: no hatching)' (
        $uoscMain -match 'and state\.is_stream\s*\r?\n\s*and \(#cached_ranges') 're-apply it after a uosc update (AGENTS.md)'
    $uoscTimeline = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/elements/Timeline.lua')
    Test-Check $t 'uosc local change present: Timeline.lua shows the amber time only when it differs (speed is not 1x)' (
        $uoscTimeline.Contains('state.realtime_remaining_human ~= state.content_remaining_human')) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t "uosc.conf: font_scale matches the scripts' FONT_SCALE (Segoe UI's line box)" (
        $uoscConf -match '(?m)^font_scale=1\.19\s*$' -and
        @('notify.lua', 'subtitle-sync.lua', 'music-info.lua' | Where-Object {
                (Get-Content -Raw (Join-Path $Cfg "Scripts/$_")) -notmatch '(?m)^local FONT_SCALE = 1\.19\s*$' }).Count -eq 0)
    foreach ($kv in $localChanges.GetEnumerator()) {
        $text = Get-Content -Raw (Join-Path $Cfg "Scripts/uosc/$($kv.Key)")
        Test-Check $t "uosc local change present: $($kv.Key)" ($text.Contains($kv.Value)) 're-apply it after a uosc update (AGENTS.md)'
    }

    # -- upscale badges fit uosc's icon box (4 chars) -----------------------------
    $badgeBlock = [regex]::Match($toggles, 'local UPSCALE_BADGES = \{(.*?)\n\}', 'Singleline').Groups[1].Value
    $badges = @([regex]::Matches($badgeBlock, "=\s*'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) + @('Off', 'Auto')
    $long = @($badges | Where-Object { $_.Length -gt 4 })
    Test-Check $t "upscale badges are at most 4 characters ($($badges -join ', '))" ($badgeBlock -and $long.Count -eq 0) ($long -join ', ')

    # -- mpv's build: pinned, not committed (2026-10-03) --------------------------------
    # mpv's own files and yt-dlp.exe are not in git: mpv-build.json pins the build,
    # installer/install-mpv.ps1 (updater.bat, regression-tests.yml) installs it.
    $buildJson = Get-Content -Raw (Join-Path $RepoRoot 'mpv-build.json') | ConvertFrom-Json
    $buildFiles = @($buildJson.upstream_files.PSObject.Properties.Name)
    $pinBad = @()
    if ($buildJson.tag -notmatch '^\d{8}$') { $pinBad += "tag '$($buildJson.tag)'" }
    if ($buildJson.asset -notmatch ('^mpv-{0}-{1}-git-[0-9a-f]+\.7z$' -f [regex]::Escape($buildJson.arch), $buildJson.tag)) { $pinBad += "asset '$($buildJson.asset)'" }
    if ($buildJson.url -ne "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/$($buildJson.tag)/$($buildJson.asset)") { $pinBad += "url '$($buildJson.url)'" }
    if ($buildJson.sha256 -notmatch '^[0-9a-f]{64}$') { $pinBad += 'sha256' }
    if ('mpv.exe' -notin $buildFiles) { $pinBad += 'upstream_files has no mpv.exe' }
    $pinBad += @($buildFiles | Where-Object {
            $_ -in 'updater.bat', 'installer/updater.ps1' -or $_ -match '^(portable_config|\.github|\.githooks|tests|lua-api)/' -or $_ -match '\.\.'
        } | ForEach-Object { "upstream_files names $_" })
    Test-Check $t "mpv-build.json pins a complete build ($($buildJson.tag), $($buildFiles.Count) files)" ($pinBad.Count -eq 0) ($pinBad -join '; ')
    $ownFiles = @($buildFiles) + 'yt-dlp.exe'
    $tracked = @(& git -C $RepoRoot ls-files -- @ownFiles)
    Test-Check $t "mpv's own files and yt-dlp.exe are not in git (install-mpv.ps1 installs them)" ($tracked.Count -eq 0) `
        "tracked: $($tracked -join ', ') - git rm --cached them"
    $notIgnored = @($ownFiles | Where-Object { & git -C $RepoRoot check-ignore -q --no-index -- $_; $LASTEXITCODE -ne 0 })
    Test-Check $t '.gitignore covers every file of the pinned build and yt-dlp.exe' ($notIgnored.Count -eq 0) ($notIgnored -join ', ')
    # ... and what an install or download cut short leaves next to them (install-mpv.ps1's
    # <name>.new, update.ps1's yt-dlp.exe.part): a git add -A took them in as plain blobs
    $leftovers = @(@($ownFiles | ForEach-Object { "$_.new" }) + 'yt-dlp.exe.part')
    $notIgnored = @($leftovers | Where-Object { & git -C $RepoRoot check-ignore -q --no-index -- $_; $LASTEXITCODE -ne 0 })
    Test-Check $t '.gitignore covers what a cut-short install leaves (<file>.new, yt-dlp.exe.part)' ($notIgnored.Count -eq 0) ($notIgnored -join ', ')
    if (-not $env:GITHUB_ACTIONS) {
        # INFO, not FAIL: the folder may lag behind the pin until updater.bat runs
        $exe = Join-Path $RepoRoot 'mpv.exe'
        $have = (Test-Path $exe) ? (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() : 'missing'
        $same = $have -eq $buildJson.upstream_files.'mpv.exe'
        Add-Result $t "the installed mpv.exe is the pinned build ($($buildJson.tag))" ($same ? 'PASS' : 'INFO') ($same ? '' : 'not yet - run updater.bat')
    }

    # -- privacy: this workspace is published to the public mpv-config (2026-10-03) ----
    # What mpv and the scripts write while you watch names what was watched - none of
    # it may reach git. One sample path per kind (AGENTS.md, "Public copy"). The shader
    # capture's files are no longer written (2026-10-05), but an old copy may still sit
    # in a config folder.
    $private = @(
        'portable_config/speed.json', 'portable_config/stream-resume.json', 'portable_config/movie-sharpness.json',
        'portable_config/shader-misses.log', 'portable_config/shader-cases.json', 'portable_config/speed.json.1234.tmp',
        'portable_config/cache/shader_0123456789abcdef', 'portable_config/watch_later/0123456789ABCDEF',
        'portable_config/watch_history.jsonl', 'mpv-shot0001.jpg', 'yt-dlp.conf', 'cookies.txt', 'notes.txt',
        'test-media/clip.mkv', '.claude/settings.local.json', '.env'
    )
    $notIgnored = @($private | Where-Object { & git -C $RepoRoot check-ignore -q --no-index -- $_; $LASTEXITCODE -ne 0 })
    Test-Check $t ".gitignore covers what mpv and the scripts write while you watch ($($private.Count) kinds)" ($notIgnored.Count -eq 0) ($notIgnored -join ', ')
    # the same checks the publish job runs before every copy (tests/lib/privacy.ps1),
    # over what would be published; reported as file:line, never the text
    . (Join-Path $PSScriptRoot 'lib/privacy.ps1')
    $wordsFile = & git -C $RepoRoot rev-parse --path-format=absolute --git-path info/private-words 2>$null
    $words = ($wordsFile -and (Test-Path $wordsFile)) ? @(Get-Content $wordsFile) : @()
    $findings = Get-PrivacyFinding -Root $RepoRoot -Words $words -Exclude (Get-PublishExclude $RepoRoot)
    foreach ($kv in $findings.GetEnumerator()) {
        Test-Check $t "published files: $($kv.Key)" ($kv.Value.Count -eq 0) ($kv.Value -join ', ')
    }
    if (-not ($findings.Keys -match 'private words')) {
        Add-Result $t 'published files: none of the private words' 'SKIP' 'no .git/info/private-words in this clone (CI has none; the publish job checks the PRIVATE_WORDS secret)'
    }
    # A git that cannot run must stop the check: it printed nothing, which read as clean.
    $noRepo = Join-Path $WorkDir 'privacy-no-repo'
    New-Item -ItemType Directory -Force $noRepo | Out-Null
    $privacyError = ''
    try { $null = Get-PrivacyFinding -Root $noRepo } catch { $privacyError = "$_" }
    Test-Check $t 'privacy check: a git that cannot run fails it, not "nothing found"' ($privacyError -match 'privacy check cannot tell') $privacyError

    # -- installer/install-mpv.ps1, against a stand-in build (no download) --------------
    $sevenZip = Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source
    $repo7z = Join-Path $RepoRoot '7z/7zr.exe'
    if (-not $sevenZip -and (Test-Path $repo7z) -and (Get-Item $repo7z).Length -gt 100KB) { $sevenZip = $repo7z }
    if (-not $sevenZip) {
        Add-Result $t 'install-mpv.ps1' 'SKIP' 'no 7-Zip to make a stand-in archive (git lfs pull for 7z/7zr.exe)'
    }
    else {
        $ib = Join-Path $WorkDir 'install-mpv'
        if (Test-Path $ib) { Remove-Item $ib -Recurse -Force }
        $src = Join-Path $ib 'src'
        $standIn = [ordered]@{
            'mpv.exe' = 'stand-in mpv.exe'; 'mpv.com' = 'stand-in mpv.com'; 'doc/manual.pdf' = 'manual'
            'mpv/fonts.conf' = '<fontconfig/>'; 'updater.bat' = "upstream's updater"
        }
        foreach ($kv in $standIn.GetEnumerator()) {
            $p = Join-Path $src $kv.Key
            New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
            Set-Content -LiteralPath $p $kv.Value -NoNewline
        }
        $archive = Join-Path $ib 'mpv-x86_64-v3-20990101-git-abc1234.7z'
        Push-Location $src
        try { $null = & $sevenZip a -t7z $archive * 2>&1 } finally { Pop-Location }
        function Write-StandInJson([string]$Path, [hashtable]$Change = @{}) {
            $files = [ordered]@{}
            foreach ($f in 'doc/manual.pdf', 'mpv.com', 'mpv.exe', 'mpv/fonts.conf') {
                $files[$f] = (Get-FileHash (Join-Path $src $f) -Algorithm SHA256).Hash.ToLower()
            }
            $j = [ordered]@{
                tag = '20990101'; arch = 'x86_64-v3'; asset = Split-Path -Leaf $archive
                url = 'http://127.0.0.1:9/nothing-listens-here.7z'; mpv_version = 'v0.0.0-stand-in'
                sha256 = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower(); upstream_files = $files
            }
            foreach ($kv in $Change.GetEnumerator()) {
                if ($kv.Key -like 'files:*') { $files[$kv.Key.Substring(6)] = $kv.Value } else { $j[$kv.Key] = $kv.Value }
            }
            Set-Content -LiteralPath $Path ($j | ConvertTo-Json -Depth 3)
        }
        $installer = Join-Path $RepoRoot 'installer/install-mpv.ps1'
        function Invoke-Installer([string]$Shell, [string]$Root, [string]$Json, [string[]]$More = @()) {
            $out = & $Shell -NoProfile -ExecutionPolicy Bypass -File $installer -Root $Root -BuildJson $Json @More 2>&1
            [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join ' ') }
        }
        function Test-Installed([string]$Root) {
            foreach ($f in 'doc/manual.pdf', 'mpv.com', 'mpv.exe', 'mpv/fonts.conf') {
                $a = Join-Path $Root $f
                if (-not (Test-Path $a) -or (Get-FileHash $a).Hash -ne (Get-FileHash (Join-Path $src $f)).Hash) { return $false }
            }
            return $true
        }
        $json = Join-Path $ib 'mpv-build.json'
        Write-StandInJson $json
        $root = Join-Path $ib 'root'
        New-Item -ItemType Directory $root | Out-Null
        $r = Invoke-Installer pwsh $root $json @('-Archive', $archive)
        Test-Check $t 'install-mpv.ps1 installs every file the pin lists, each checked' ($r.Code -eq 0 -and (Test-Installed $root)) $r.Out
        Test-Check $t "... and nothing else (not shinchiro's updater.bat)" (-not (Test-Path (Join-Path $root 'updater.bat'))) $r.Out
        $r = Invoke-Installer pwsh $root $json @('-Archive', $archive)
        Test-Check $t '... a second run finds it installed and changes nothing' ($r.Code -eq 0 -and $r.Out -match 'is installed') $r.Out
        Add-Content -LiteralPath (Join-Path $root 'mpv/fonts.conf') 'edited'
        $r = Invoke-Installer pwsh $root $json @('-Check')
        Test-Check $t '... -Check reports a file that differs (exit 3)' ($r.Code -eq 3 -and $r.Out -match 'fonts\.conf') $r.Out
        $r = Invoke-Installer pwsh $root $json
        Test-Check $t '... a failed download is exit 2 (CI falls back to the latest build then)' ($r.Code -eq 2) $r.Out
        $badJson = Join-Path $ib 'bad-sha.json'
        Write-StandInJson $badJson @{ sha256 = '0' * 64 }
        $r = Invoke-Installer pwsh $root $badJson @('-Archive', $archive)
        Test-Check $t '... an archive that is not the pinned one installs nothing' (
            $r.Code -eq 1 -and $r.Out -match 'does not match' -and -not (Test-Installed $root)) $r.Out
        $evilJson = Join-Path $ib 'evil.json'
        Write-StandInJson $evilJson @{ 'files:portable_config/mpv.conf' = '0' * 64 }
        $r = Invoke-Installer pwsh $root $evilJson @('-Archive', $archive)
        Test-Check $t '... a pin that names a file outside the build is refused' ($r.Code -eq 1 -and $r.Out -match 'outside the build') $r.Out
        $r = Invoke-Installer pwsh $root $json @('-Archive', $archive)
        Test-Check $t '... and a run with the right archive repairs the edited file' ($r.Code -eq 0 -and (Test-Installed $root)) $r.Out
        # updater.bat runs it with Windows PowerShell 5.1 when pwsh is not installed
        $ps51 = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source
        if ($ps51) {
            $root51 = Join-Path $ib 'root51'
            New-Item -ItemType Directory $root51 | Out-Null
            $r = Invoke-Installer $ps51 $root51 $json @('-Archive', $archive)
            Test-Check $t '... in Windows PowerShell 5.1 too' ($r.Code -eq 0 -and (Test-Installed $root51)) $r.Out
        }
        Remove-Item $ib -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-OneClickCheck $t

    # -- commit guard (.githooks), tried in a throwaway repo ----------------------------
    # 2026-09-27: an mpv update was committed on a feature branch and a pull deleted
    # mpv.exe; since 2026-10-03 the files are not in git at all and the guard keeps
    # them out (a forced add would put ~120 MB back into Git LFS).
    $hooks = Join-Path $RepoRoot '.githooks'
    $hookFiles = 'pre-commit', 'pre-push', 'post-checkout', 'post-commit', 'post-merge'
    $hookMissing = @($hookFiles | Where-Object { -not (Test-Path (Join-Path $hooks $_)) })
    Test-Check $t '.githooks: the commit guard and the git-lfs hooks are there' ($hookMissing.Count -eq 0) ($hookMissing -join ', ')
    if ($env:GITHUB_ACTIONS) {
        Add-Result $t 'this clone uses them (core.hooksPath)' 'SKIP' 'a CI checkout runs no commits'
    }
    else {
        $hooksPath = & git -C $RepoRoot config --get core.hooksPath
        Test-Check $t 'this clone uses them (core.hooksPath = .githooks)' ($hooksPath -eq '.githooks') 'run: git config core.hooksPath .githooks'
        # the identity the hook demands (rule 2a); its text is not printed
        $ident = & git -C $RepoRoot var GIT_AUTHOR_IDENT 2>$null
        $public = ($ident -match '^(.+?) <([^>]+)>') -and (Test-PublicIdentity $Matches[1] $Matches[2])
        Test-Check $t 'this clone commits under a public identity (GitHub login + its noreply address)' $public `
            'git config user.name <login>; git config user.email <id>+<login>@users.noreply.github.com'
    }
    $g = Join-Path $WorkDir 'git-guard'
    if (Test-Path $g) { Remove-Item $g -Recurse -Force }
    New-Item -ItemType Directory -Force $g | Out-Null
    Copy-Item $hooks (Join-Path $g '.githooks') -Recurse
    Copy-Item (Join-Path $RepoRoot 'mpv-build.json'), (Join-Path $RepoRoot '.gitignore') $g
    function Invoke-Git {
        $ErrorActionPreference = 'Continue'
        $out = & git -C $g @args 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join ' ') }
    }
    function Write-GuardFile([string]$Name, [string]$Text) { Set-Content -LiteralPath (Join-Path $g $Name) $Text }
    function Write-PinnedExe([string]$Sha) {
        $p = Join-Path $g 'mpv-build.json'
        [IO.File]::WriteAllText($p, ((Get-Content -Raw $p) -replace '("mpv\.exe": *")[0-9a-f]{64}', "`${1}$Sha"))
    }
    try {
        foreach ($c in @(@('init', '-q', '-b', 'main'), @('config', 'core.hooksPath', '.githooks'), @('config', 'core.autocrlf', 'false'),
                @('config', 'user.name', 'guard-test'), @('config', 'user.email', '1+guard-test@users.noreply.github.com'))) {
            $null = Invoke-Git @c
        }
        # the state until 2026-10-03: mpv's files committed
        'mpv.exe', 'yt-dlp.exe', 'script.lua' | ForEach-Object { Write-GuardFile $_ 'v1' }
        $null = Invoke-Git add -A
        $null = Invoke-Git add -f mpv.exe yt-dlp.exe
        $null = Invoke-Git commit -q --no-verify -m 'binaries committed'
        $null = Invoke-Git rm -q --cached mpv.exe yt-dlp.exe
        $r = Invoke-Git commit -q -m 'pin only'
        Test-Check $t 'commit guard: taking mpv.exe and yt-dlp.exe out of git goes through' ($r.Code -eq 0) $r.Out
        Write-GuardFile 'script.lua' 'v2'
        $r = Invoke-Git commit -q -am work
        Test-Check $t '... other work goes through' ($r.Code -eq 0) $r.Out
        $null = Invoke-Git add -A
        Test-Check $t '... .gitignore keeps them out of git add -A' (-not ((Invoke-Git diff --cached --name-only).Out -match 'mpv\.exe|yt-dlp\.exe'))
        foreach ($f in 'mpv.exe', 'yt-dlp.exe') {
            $null = Invoke-Git add -f $f
            $r = Invoke-Git commit -q -m "add $f"
            Test-Check $t "commit guard: a forced add of $f is refused" ($r.Code -ne 0 -and $r.Out -match 'not kept in git') $r.Out
            $null = Invoke-Git restore --staged -- $f
        }

        # the repository is public (2026-10-03): who commits, forced-in private files,
        # added lines. Paths and links are built here, so this file holds none itself.
        $r = Invoke-Git -c 'user.name=Jane Example' commit -q --allow-empty -m 'real name'
        Test-Check $t 'commit guard: a real name as author is refused (the noreply login is the name)' ($r.Code -ne 0 -and $r.Out -match 'not a public identity') $r.Out
        $r = Invoke-Git -c 'user.email=jane@example.org' commit -q --allow-empty -m 'real address'
        Test-Check $t '... and a real e-mail address' ($r.Code -ne 0 -and $r.Out -match 'not a public identity') $r.Out
        $r = Invoke-Git -c 'user.name=Claude' -c 'user.email=noreply@anthropic.com' commit -q --allow-empty -m 'agent'
        Test-Check $t '... Claude <noreply@anthropic.com> goes through' ($r.Code -eq 0) $r.Out
        New-Item -ItemType Directory -Force (Join-Path $g 'portable_config') | Out-Null
        Write-GuardFile 'portable_config/stream-resume.json' '{}'
        $null = Invoke-Git add -f portable_config/stream-resume.json
        $r = Invoke-Git commit -q -m 'resume state'
        Test-Check $t 'commit guard: a forced add of an ignored private file (stream-resume.json) is refused' (
            $r.Code -ne 0 -and $r.Out -match 'keeps these out') $r.Out
        $null = Invoke-Git restore --staged -- portable_config/stream-resume.json
        foreach ($leak in @(('C:' + '\Users\' + 'someone\Videos'), ('https://claude.ai/' + 'code/session_0123'))) {
            Write-GuardFile 'notes.md' "see $leak"
            $null = Invoke-Git add notes.md
            $r = Invoke-Git commit -q -m 'leak'
            Test-Check $t "commit guard: an added line with $(($leak -like '*claude*') ? 'a private claude.ai link' : 'a user folder path') is refused" (
                $r.Code -ne 0 -and $r.Out -match 'user folder path or a private claude') $r.Out
        }
        Write-GuardFile 'notes.md' 'see C:\Users\<name>\Videos'
        $null = Invoke-Git add notes.md
        $r = Invoke-Git commit -q -m 'placeholder'
        Test-Check $t '... a placeholder (C:\Users\<name>) goes through' ($r.Code -eq 0) $r.Out
        $words = Join-Path $g '.git/info/private-words'
        Set-Content -LiteralPath $words "# one per line`nJane Example"
        Write-GuardFile 'notes.md' 'written by jane example'
        $null = Invoke-Git add notes.md
        $r = Invoke-Git commit -q -m 'word'
        Test-Check $t "commit guard: a word from the clone's .git/info/private-words is refused" ($r.Code -ne 0 -and $r.Out -match 'private-words') $r.Out
        Remove-Item -LiteralPath $words
        $null = Invoke-Git reset -q --hard

        # post-merge: a pull that moves the pin says so when the installed mpv.exe is not it
        $exeSha = (Get-FileHash (Join-Path $g 'mpv.exe') -Algorithm SHA256).Hash.ToLower()
        $null = Invoke-Git switch -q -c ci-other
        Write-PinnedExe ('1' * 64)
        $null = Invoke-Git commit -q -am 'ci: pin another mpv'
        $null = Invoke-Git switch -q main
        $r = Invoke-Git merge -q --ff-only ci-other
        Test-Check $t 'after a pull that pins another mpv, post-merge says to run updater.bat' ($r.Code -eq 0 -and $r.Out -match 'updater\.bat') $r.Out
        $null = Invoke-Git switch -q -c ci-this
        Write-PinnedExe $exeSha
        $null = Invoke-Git commit -q -am 'ci: pin the installed mpv'
        $null = Invoke-Git switch -q main
        $r = Invoke-Git merge -q --ff-only ci-this
        Test-Check $t '... and nothing when the installed mpv.exe is the pinned one' ($r.Code -eq 0 -and $r.Out -notmatch 'updater\.bat') $r.Out
    }
    finally {
        Remove-Item $g -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -- publish.ps1 (the public copy, 2026-10-03), between two throwaway repos ---------
    # Leaks are built here, so this file holds none itself.
    $pw = Join-Path $WorkDir 'publish-test'
    if (Test-Path $pw) { Remove-Item $pw -Recurse -Force }
    $ws = Join-Path $pw 'workspace'
    $pub = Join-Path $pw 'public'
    New-Item -ItemType Directory -Force (Join-Path $ws 'tests/lib'), (Join-Path $ws 'notes'), $pub | Out-Null
    Copy-Item (Join-Path $RepoRoot 'tests/lib/privacy.ps1') (Join-Path $ws 'tests/lib')
    Set-Content -LiteralPath (Join-Path $ws 'a.txt') 'hello'
    Set-Content -LiteralPath (Join-Path $ws 'notes/private.md') 'by Jane Example'
    Set-Content -LiteralPath (Join-Path $ws '.publishignore') 'notes/**'
    Set-Content -LiteralPath (Join-Path $pub 'README.md') 'public'
    $who = @('-c', 'user.name=guard-test', '-c', 'user.email=1+guard-test@users.noreply.github.com')
    function Invoke-PubGit([string]$Dir) { & git -C $Dir @who @args 2>&1 | Out-Null }
    foreach ($d in $ws, $pub) {
        Invoke-PubGit $d init -q -b main
        Invoke-PubGit $d add -A
        Invoke-PubGit $d commit -q -m 'workspace'
    }
    $publish = Join-Path $RepoRoot '.github/scripts/publish.ps1'
    function Invoke-Publish {
        $out = & pwsh -NoProfile -File $publish -Workspace $ws -Public $pub -Name guard-test `
            -Email '1+guard-test@users.noreply.github.com' -Words 'Jane Example' -NoPush 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join ' ') }
    }
    try {
        $r = Invoke-Publish
        $tree = @(& git -C $pub ls-files)
        Test-Check $t 'publish.ps1: a clean workspace becomes one commit by the public identity' (
            $r.Code -eq 0 -and (& git -C $pub log -1 --format='%an|%s') -eq 'guard-test|workspace' -and 'a.txt' -in $tree -and 'README.md' -notin $tree) $r.Out
        Test-Check $t '... without the .publishignore paths or the file itself' (-not ($tree -match '^(notes/|\.publishignore$)')) ($tree -join ', ')
        $r = Invoke-Publish
        Test-Check $t '... nothing new: no commit' ($r.Code -eq 0 -and $r.Out -match 'Nothing to publish' -and (& git -C $pub rev-list --count HEAD) -eq '2') $r.Out
        $leaks = [ordered]@{
            'a user folder path' = 'C:' + '\Users\' + 'someone\Videos'
            'a private word'     = 'written by jane example'
            'an e-mail address'  = 'mail jane' + '@example.net'
        }
        foreach ($kv in $leaks.GetEnumerator()) {
            Set-Content -LiteralPath (Join-Path $ws 'a.txt') $kv.Value
            Invoke-PubGit $ws commit -q -am 'leak'
            $before = & git -C $pub rev-parse HEAD
            $r = Invoke-Publish
            Test-Check $t "publish.ps1: a copy holding $($kv.Key) is not published (and the text is not printed)" (
                $r.Code -eq 1 -and $r.Out -match 'NOT published' -and (& git -C $pub rev-parse HEAD) -eq $before -and
                -not $r.Out.Contains($kv.Value)) $r.Out
            Invoke-PubGit $pub reset -q --hard
        }
        Set-Content -LiteralPath (Join-Path $ws 'a.txt') 'hello again'
        Invoke-PubGit $ws commit -q -am 'notes from Jane Example'
        $r = Invoke-Publish
        Test-Check $t '... a commit subject with a private word is not published (generic message)' (
            $r.Code -eq 0 -and (& git -C $pub log -1 --format='%s') -eq 'Publish from the workspace') $r.Out
        # The workspace's pull requests and branches stay private: a merge goes public
        # as the pull request's title (the message body), a #<number> not at all.
        Set-Content -LiteralPath (Join-Path $ws 'a.txt') 'hello merged'
        Invoke-PubGit $ws commit -q -am 'Merge pull request #12 from guard-test/feature/x' -m 'feat: the merged change'
        $r = Invoke-Publish
        Test-Check $t '... a pull request merge goes public as its title, without its number and branch' (
            $r.Code -eq 0 -and (& git -C $pub log -1 --format='%s') -eq 'feat: the merged change') $r.Out
        Set-Content -LiteralPath (Join-Path $ws 'a.txt') 'hello numbered'
        Invoke-PubGit $ws commit -q -am 'fix: what #12 left out'
        $r = Invoke-Publish
        Test-Check $t '... a subject naming a workspace #number is not published (generic message)' (
            $r.Code -eq 0 -and (& git -C $pub log -1 --format='%s') -eq 'Publish from the workspace') $r.Out
        Set-Content -LiteralPath (Join-Path $ws 'a.txt') 'hello once more'
        Invoke-PubGit $ws commit -q -am 'more'
        & git -C $pub -c 'user.name=Jane Example' -c 'user.email=jane@example.org' commit -q --allow-empty -m 'web edit' 2>&1 | Out-Null
        $r = Invoke-Publish
        Test-Check $t 'publish.ps1: nothing is published while a public commit names someone' ($r.Code -eq 1 -and $r.Out -match 'names no one') $r.Out
    }
    finally {
        Remove-Item $pw -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -- shader cache: the startup check and the warm-up it starts stay wired --------
    $sc = Join-Path $Cfg 'Scripts/shader-cache'
    $scFiles = @('main.lua', 'fingerprint.lua', 'warmup.lua', 'host.ps1')
    $scMissing = @($scFiles | Where-Object { -not (Test-Path (Join-Path $sc $_)) })
    Test-Check $t 'shader-cache: main.lua, fingerprint.lua, warmup.lua and host.ps1 present' ($scMissing.Count -eq 0) ($scMissing -join ', ')
    # mpv auto-loads Scripts/*.lua and a folder's main.lua - the warm-up must never be a player script
    $stray = @($scFiles | Where-Object { Test-Path (Join-Path $Cfg "Scripts/$_") })
    Test-Check $t 'shader-cache: warm-up files are not top-level player scripts' ($stray.Count -eq 0) ($stray -join ', ')
    $warmPs1 = Get-Content -Raw (Join-Path $RepoRoot 'installer/warm-shader-cache.ps1')
    Test-Check $t 'warm-shader-cache.ps1 runs Scripts/shader-cache/warmup.lua' ($warmPs1 -match 'shader-cache/warmup\.lua')
    # never again a visible full-screen warm-up: both starters go through the hidden host
    Test-Check $t 'warm-shader-cache.ps1 runs it hidden (shader-cache/host.ps1)' ($warmPs1 -match 'shader-cache/host\.ps1' -and $warmPs1 -notmatch "'--fs'")
    # shipped-cases.lua: the files it ships (Dolby Vision clips no encoder can make)
    # are there - a missing one only logs "file missing" and silently drops its cases
    $shippedLua = Get-Content -Raw (Join-Path $sc 'shipped-cases.lua')
    $shippedFiles = @([regex]::Matches($shippedLua, "'(dv-[\w.]+\.mp4)'") | ForEach-Object { "clips/$($_.Groups[1].Value)" })
    $shippedMissing = @($shippedFiles | Where-Object { -not (Test-Path (Join-Path $sc $_)) })
    Test-Check $t "shader-cache: the clips shipped-cases.lua names are there ($($shippedFiles.Count))" (
        $shippedFiles.Count -gt 0 -and $shippedMissing.Count -eq 0) ($shippedMissing -join ', ')

    # -- PowerShell files parse -----------------------------------------------------
    $parseBad = @()
    foreach ($f in Get-ChildItem $RepoRoot -Recurse -Filter *.ps1 -File | Where-Object FullName -NotMatch '\\(test-media|\.git)\\') {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors) { $parseBad += "$($f.Name): $($errors[0].Message)" }
    }
    Test-Check $t 'every .ps1 file parses' ($parseBad.Count -eq 0) ($parseBad -join '; ')

    # -- Lua style (CI runs the same; skipped when stylua is not installed) ----------
    if (Get-Command stylua -ErrorAction SilentlyContinue) {
        Push-Location $RepoRoot
        try {
            $out = & stylua --check . 2>&1
            Test-Check $t 'stylua --check .' ($LASTEXITCODE -eq 0) (($out | Select-Object -First 5) -join ' ')
        }
        finally { Pop-Location }
    }
    else {
        Add-Result $t 'stylua --check .' 'SKIP' 'stylua not on PATH (CI checks it)'
    }
}

# ---------------------------------------------------------------------------
# isolated player + media
# ---------------------------------------------------------------------------
function Initialize-TestRoot {
    $item = Get-Item $MpvExe -ErrorAction SilentlyContinue
    if (-not $item -or $item.Length -lt 1MB) {
        throw "$MpvExe is missing - run updater.bat (it installs the pinned build) or pass -MpvExe."
    }
    $root = Join-Path $WorkDir 'root'
    New-Item -ItemType Directory -Force $root | Out-Null
    $exe = Join-Path $root 'mpv.exe'
    $cur = Get-Item $exe -ErrorAction SilentlyContinue
    if (-not $cur -or $cur.Length -ne $item.Length -or $cur.LastWriteTimeUtc -ne $item.LastWriteTimeUtc) {
        Copy-Item $item.FullName $exe -Force
    }
    # fresh config copy every run; no caches, no state (nor the shader capture
    # log and learned cases an older config left behind: they hold real viewing)
    $dst = Join-Path $root 'portable_config'
    & robocopy $Cfg $dst /MIR /XD cache watch_later /XF speed.json stream-resume.json shader-misses.log shader-cases.json '*.tmp' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
    New-Item -ItemType Directory -Force (Join-Path $WorkDir 'logs') | Out-Null
    return $exe
}

function Invoke-Mpv {
    param([string]$Exe, [string[]]$Arguments, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 120)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { $p.Kill($true); $p.WaitForExit() }
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result; TimedOut = $timedOut }
}

function Initialize-Clip {
    param([string]$Exe, [string]$Path, [string]$Size, [int]$Seconds, [string]$Codec = 'libx264', [string]$PixFmt = 'yuv420p')
    if (Test-Path -LiteralPath $Path) { return }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $tmp = Join-Path (Split-Path -Parent $Path) ('encoding-' + [guid]::NewGuid().ToString('N') + '.mkv')
    $opts = $Codec -eq 'libx264' ? 'preset=ultrafast,g=24' : 'preset=ultrafast'
    $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet', "av://lavfi:testsrc2=size=${Size}:rate=24:duration=$Seconds,format=$PixFmt",
        "--o=$tmp", "--ovc=$Codec", "--ovcopts=$opts") -TimeoutSeconds 300
    if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp)) { throw "encoding $Path failed: $($r.StdErr)" }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Media for the runtime tests, generated once with the tested mpv's own
# encoder and reused. Each clip sits in its own folder so autoload.lua does not
# queue its neighbours. A "#fs-content=...&fs-id=..." in a file name stands in
# for the URL fragment the FastStream native host appends: gpu-toggles.lua,
# and stream-resume.lua read it from `path`, which is the same string either way.
$MediaVersion = 'v1'
function Initialize-Media([string]$Exe, [bool]$Gpu) {
    $m = Join-Path $WorkDir "media-$MediaVersion"
    Write-Host "  preparing test media in $m" -ForegroundColor DarkGray
    Initialize-Clip $Exe (Join-Path $m 'plain/clip.mkv') 320x180 20
    Initialize-Clip $Exe (Join-Path $m 'second/clip2.mkv') 320x180 12
    Initialize-Clip $Exe (Join-Path $m 'long/long.mkv') 320x180 180
    Initialize-Clip $Exe (Join-Path $m 'subs/movie.mkv') 320x180 20
    # video-info.lua: the common anime format (10-bit HEVC), whose depth the
    # banner names. mpv's own libx265 is a 10-bit build - but its encoding
    # profile must keep its vo=lavc: a --vo=null here fails the whole encode
    # run with "Error opening/initializing the selected video_out". Same
    # command shape as Initialize-Clip otherwise.
    $tenbit = Join-Path $m 'tenbit/clip.mkv'
    if (-not (Test-Path -LiteralPath $tenbit)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $tenbit) | Out-Null
        $tmp = Join-Path (Split-Path -Parent $tenbit) ('encoding-' + [guid]::NewGuid().ToString('N') + '.mkv')
        $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet',
            'av://lavfi:testsrc2=size=320x180:rate=24:duration=10,format=yuv420p10le',
            "--o=$tmp", '--ovc=libx265', '--ovcopts=preset=ultrafast') -TimeoutSeconds 300
        if ($r.ExitCode -eq 0 -and (Test-Path $tmp)) { Move-Item -LiteralPath $tmp -Destination $tenbit -Force }
        else { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw "encoding $tenbit failed: $($r.StdErr)" }
    }
    $srt = Join-Path $m 'subs/movie.srt'
    if (-not (Test-Path $srt)) {
        Set-Content -LiteralPath $srt -Encoding utf8 -Value "1`n00:00:00,000 --> 00:00:19,000`nregression test subtitle`n"
    }
    $ep = Join-Path $m 'fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'
    Initialize-Clip $Exe $ep 320x180 120
    $token2 = Join-Path $m 'fs-anime-token2/ep1-newtoken#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'
    if (-not (Test-Path -LiteralPath $token2)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $token2) | Out-Null
        Copy-Item -LiteralPath $ep -Destination $token2
    }
    # stream-resume: an fs-id before the fragment, which is no resume key.
    $queryId = Join-Path $m 'fs-query/ep&fs-id=cccccccccccccccc#fs-content=anime.mkv'
    if (-not (Test-Path -LiteralPath $queryId)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $queryId) | Out-Null
        Copy-Item -LiteralPath $ep -Destination $queryId
    }
    # source-info: a stream URL's own xfs-page= item before the host's tags (the host drops only
    # fs-* items), which must not pass for the Site page.
    $forged = Join-Path $m 'fs-page/ep1#xfs-page=https%3A%2F%2Fevil.example%2F&fs-content=anime&fs-page=https%3A%2F%2Fsite.example%2Fwatch%3Fep%3D1%26lang%3Den.mkv'
    if (-not (Test-Path -LiteralPath $forged)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $forged) | Out-Null
        Copy-Item -LiteralPath $ep -Destination $forged
    }
    # gpu-toggles: "fs-content=anime" in a stream URL's own query and fragment, with the host's
    # movie tag after them; and in a query only, with no host fragment at all.
    foreach ($rel in 'fs-forged/ep&x=fs-content=anime#xfs-content=anime&fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv',
        'fs-forged-query/ep&x=fs-content=anime.mkv') {
        $forgedContent = Join-Path $m $rel
        if (-not (Test-Path -LiteralPath $forgedContent)) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $forgedContent) | Out-Null
            Copy-Item -LiteralPath $ep -Destination $forgedContent
        }
    }
    Initialize-Clip $Exe (Join-Path $m 'autoload/episode1.mkv') 320x180 10
    Initialize-Clip $Exe (Join-Path $m 'autoload/episode2.mkv') 320x180 10
    $song = Join-Path $m 'autoload/song.flac'
    if (-not (Test-Path $song)) {
        $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet', 'av://lavfi:sine=frequency=440:duration=3', "--o=$song", '--oac=flac')
        if (-not (Test-Path $song)) { throw "encoding $song failed: $($r.StdErr)" }
    }
    # Songs for music-info.lua: tagged (with a cover.jpg next to it, which mpv
    # loads as album art), untagged (two, so autoload queues an "up next"), and
    # a title that carries its featured artist.
    $songs = @(
        @{ Path = 'music-tagged/Nova Lane - Paper Lanterns.mp3'; Codec = 'libmp3lame'
            Meta = 'title=Paper Lanterns,artist=Nova Lane feat. Test Artist,album=Night Signals,date=2019-05-03,track=3/11,genre=Synthpop'
        }
        @{ Path = 'music-untagged/01 - Artist Name - Song Title (ft. Guest).flac'; Codec = 'flac' }
        @{ Path = 'music-untagged/02 - Other Artist - Next Song.flac'; Codec = 'flac' }
        @{ Path = 'music-feat/harbor-lights.mp3'; Codec = 'libmp3lame'; Meta = 'title=Harbor Lights (feat. Juno Vale) [Live],artist=Nova Lane;Echo Harbor' }
    )
    foreach ($s in $songs) {
        $file = Join-Path $m $s.Path
        if (Test-Path -LiteralPath $file) { continue }
        New-Item -ItemType Directory -Force (Split-Path -Parent $file) | Out-Null
        $songArgs = @('--no-config', '--really-quiet', 'av://lavfi:sine=frequency=440:duration=20', "--o=$file", "--oac=$($s.Codec)")
        if ($s.ContainsKey('Meta')) { $songArgs += "--oset-metadata=$($s.Meta)" }
        $r = Invoke-Mpv $Exe $songArgs
        if (-not (Test-Path -LiteralPath $file)) { throw "encoding $file failed: $($r.StdErr)" }
    }
    $cover = Join-Path $m 'music-tagged/cover.jpg'
    if (-not (Test-Path $cover)) {
        $dir = Split-Path -Parent $cover
        $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet', 'av://lavfi:testsrc2=size=300x300', '--frames=1', '--vo=image',
            '--vo-image-format=jpg', "--vo-image-outdir=$dir")
        $shot = Join-Path $dir '00000001.jpg'
        if (-not (Test-Path $shot)) { throw "rendering $cover failed: $($r.StdErr)" }
        Move-Item -LiteralPath $shot -Destination $cover -Force
    }
    # subtitle-sync.lua: a clip whose sound is a 1 kHz beep at 2, 6, 10, 14 and
    # 18 s (0.5 s each) and a .srt with one line on each beep, so the audio row
    # and the subtitle row must agree. The beeps are made first, in a folder of
    # their own (autoload would queue them next to the clip).
    $talk = Join-Path $m 'sync/talk.mkv'
    if (-not (Test-Path -LiteralPath $talk)) {
        $beeps = Join-Path $m 'sync-src/beeps.flac'
        New-Item -ItemType Directory -Force (Split-Path -Parent $beeps), (Split-Path -Parent $talk) | Out-Null
        $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet',
            "av://lavfi:aevalsrc=exprs='0.5*sin(2*PI*1000*t)*between(mod(t\,4)\,2\,2.5)':s=48000:d=20", "--o=$beeps", '--oac=flac')
        if (-not (Test-Path $beeps)) { throw "encoding $beeps failed: $($r.StdErr)" }
        $tmp = Join-Path (Split-Path -Parent $talk) ('encoding-' + [guid]::NewGuid().ToString('N') + '.mkv')
        $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet', 'av://lavfi:testsrc2=size=320x180:rate=24:duration=20,format=yuv420p',
            "--audio-file=$beeps", "--o=$tmp", '--ovc=libx264', '--ovcopts=preset=ultrafast,g=24', '--oac=flac') -TimeoutSeconds 300
        if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp)) { throw "encoding $talk failed: $($r.StdErr)" }
        Move-Item -LiteralPath $tmp -Destination $talk -Force
    }
    $talkSrt = Join-Path $m 'sync/talk.srt'
    if (-not (Test-Path -LiteralPath $talkSrt)) {
        $cues = foreach ($i in 0..4) { "{0}`n00:00:{1:00},000 --> 00:00:{1:00},500`nline {0}`n" -f ($i + 1), (2 + 4 * $i) }
        Set-Content -LiteralPath $talkSrt -Encoding utf8 -Value ($cues -join "`n")
    }
    # The same lines as a track inside the clip. Muxing a subtitle track needs
    # ffmpeg (mpv's encoder writes none); without it the test skips that part.
    $embedded = Join-Path $m 'sync-embedded/talk.mkv'
    if (-not (Test-Path -LiteralPath $embedded) -and (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $embedded) | Out-Null
        & ffmpeg -v error -y -i $talk -i $talkSrt -map 0 -map 1 -c copy -c:s srt $embedded
    }
    Initialize-Clip $Exe (Join-Path $m 'fs-movie/film#fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv') 320x180 20
    # an HDR10 clip (10-bit HEVC, bt.2020, PQ) for mpv.conf's [hdr-target-peak]:
    # matrix via lavfi setparams, primaries/transfer as encoder options (mpv's
    # encoder drops those two from the frames; ffprobe and mpv read them back)
    $hdr = Join-Path $m 'hdr/pq.mkv'
    if (-not (Test-Path -LiteralPath $hdr)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $hdr) | Out-Null
        $tmp = Join-Path (Split-Path -Parent $hdr) ('encoding-' + [guid]::NewGuid().ToString('N') + '.mkv')
        $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet',
            'av://lavfi:testsrc2=size=320x180:rate=24:duration=5,format=yuv420p10le,setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084',
            "--o=$tmp", '--ovc=libx265', '--ovcopts=preset=ultrafast,color_primaries=bt2020,color_trc=smpte2084') -TimeoutSeconds 300
        if ($r.ExitCode -eq 0 -and (Test-Path $tmp)) { Move-Item -LiteralPath $tmp -Destination $hdr -Force }
        else { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw "encoding $hdr failed: $($r.StdErr)" }
    }
    Initialize-Clip $Exe (Join-Path $m 'fs-mismatch/other#fs-content=movie&fs-id=a1b2c3d4e5f60718.mkv') 320x180 20
    if ($Gpu) {
        Initialize-Clip $Exe (Join-Path $m 'gpu/anime720/ep#fs-content=anime&fs-id=1111111111111111.mkv') 1280x720 60
        Initialize-Clip $Exe (Join-Path $m 'gpu/anime1080/ep#fs-content=anime&fs-id=4444444444444444.mkv') 1920x1080 60
        Initialize-Clip $Exe (Join-Path $m 'gpu/anime480/ep#fs-content=anime&fs-id=5555555555555555.mkv') 854x480 60
        Initialize-Clip $Exe (Join-Path $m 'gpu/movie720/film#fs-content=movie&fs-id=2222222222222222.mkv') 1280x720 60
        Initialize-Clip $Exe (Join-Path $m 'gpu/movie1080/film#fs-content=movie&fs-id=3333333333333333.mkv') 1920x1080 60
        Initialize-Clip $Exe (Join-Path $m 'gpu/local720/film.mkv') 1280x720 60
    }
    return $m
}

function Clear-State([string]$Root) {
    foreach ($f in 'speed.json', 'stream-resume.json', 'stream-resume.json.tmp', 'shader-misses.log', 'movie-sharpness.json') {
        Remove-Item -LiteralPath (Join-Path $Root "portable_config/$f") -ErrorAction SilentlyContinue
    }
    foreach ($f in 'stamp', 'failed', 'interrupted', 'lock', 'progress', 'args') {
        Remove-Item -LiteralPath (Join-Path $Root "portable_config/cache/shader-warmup.$f") -ErrorAction SilentlyContinue
    }
}

# Runs one test (one or more mpv processes sharing state) and records results.
function Invoke-RuntimeTest {
    param([string]$Exe, [string]$Media, [hashtable]$Test, [string[]]$ExtraArgs, [int]$TimeoutSeconds = 120)
    $root = Split-Path -Parent $Exe
    Clear-State $root
    Write-Host ''
    Write-Host "-- $($Test.Name)" -ForegroundColor White
    $phase = 0
    foreach ($ph in $Test.Phases) {
        $phase++
        $log = Join-Path $WorkDir "logs/$($Test.Name)-$phase.log"
        $script = Join-Path $TestsDir $ph.Script
        # a phase's own Args come last, so they override the tier's (last option wins)
        # a phase without a File starts mpv empty (idle), as a double-click on mpv.exe does;
        # an av:// File (a lavfi source) is opened as it is, not from the media folder
        $fileArgs = !$ph.File ? @('--idle=yes') : $ph.File -like 'av://*' ? @('--', $ph.File) : @('--', (Join-Path $Media $ph.File))
        $mpvArgs = @("--script=$script", "--log-file=$log", '--no-terminal') + $ExtraArgs + @($ph.ContainsKey('Args') ? $ph.Args : @()) + $fileArgs
        $r = Invoke-Mpv $Exe $mpvArgs @{
            MPV_TEST_MEDIA = $Media.Replace('\', '/'); MPV_TEST_ROOT = $root.Replace('\', '/'); MPV_TEST_TIMEOUT = $TimeoutSeconds - 10
        } -TimeoutSeconds $TimeoutSeconds
        $label = $Test.Phases.Count -gt 1 ? "[$phase/$($Test.Phases.Count)] " : ''
        $seen = 0
        $done = $false
        foreach ($line in ($r.StdOut -split "`r?`n")) {
            if ($line -match '^RESULT DONE ') { $done = $true }
            if ($line -match '^RESULT (PASS|FAIL|INFO) (.*?)(?: :: (.*))?$') {
                $seen++
                Add-Result -Test $Test.Name -Check ($label + $Matches[2]) -Status $Matches[1] -Detail ($Matches[3] ?? '')
            }
        }
        if ($r.TimedOut) {
            Add-Result $Test.Name "${label}mpv finished" 'FAIL' "killed after $TimeoutSeconds s - log: $log"
        }
        elseif ($seen -eq 0) {
            Add-Result $Test.Name "${label}test produced results" 'FAIL' "exit $($r.ExitCode), no RESULT lines - log: $log"
        }
        elseif (-not $done) {
            # The harness prints RESULT DONE when the test body has run to its end: without it
            # something quit mpv midway, and the checks after that point never ran (2026-10-02:
            # such a phase counted as green).
            Add-Result $Test.Name "${label}test ran to its end" 'FAIL' "exit $($r.ExitCode), no RESULT DONE - log: $log"
        }
        elseif ($r.ExitCode -ne 0 -and -not ($script:Results | Where-Object { $_.Test -eq $Test.Name -and $_.Status -eq 'FAIL' })) {
            Add-Result $Test.Name "${label}mpv exit code" 'FAIL' "exit $($r.ExitCode) - log: $log"
        }
        # A Lua error ends the WHOLE script it happens in, so its feature is gone
        # for the rest of the session while every check that already ran stays
        # green - the 2026-09-29 notify.lua crash ("[f][notify] Lua error ...").
        # No script may die in any phase.
        if (Test-Path -LiteralPath $log) {
            $died = @(Select-String -LiteralPath $log -Pattern '\]\[f\]\[|Lua error' | Select-Object -First 3)
            Add-Result $Test.Name "${label}no script died (no Lua error in the log)" ($died.Count ? 'FAIL' : 'PASS') `
            (($died | ForEach-Object { $_.Line.Trim() }) -join ' | ')
        }
        if ($ph.ContainsKey('After')) { & $ph.After $Test.Name $label }
    }
}

# Every runtime test runs with the startup shader check OFF (a test root has no
# warmed cache, so it would warm before every test); the shader-cache tests
# switch it back on per phase and run the warm-up headless on one tiny clip.
$ShaderCacheOff = '--script-opts-append=shader_cache-auto=no'
$ShaderCacheOn = @('--script-opts-append=shader_cache-auto=yes', '--script-opts-append=shader_cache-warmup_vo=null',
    '--script-opts-append=shader_cache-warmup_matrix=test', '--script-opts-append=shader_cache-start_delay=0',
    '--script-opts-append=shader_cache-idle_delay=0.5')
# a warm-up mpv with a missing script idles until it is killed or times out
$ShaderCacheIdles = $ShaderCacheOn + @('--script-opts-append=shader_cache-warmup_script=C:/nonexistent/warmup.lua')
$ShaderCacheHangs = $ShaderCacheIdles + @('--script-opts-append=shader_cache-timeout=3')
# a warm-up that exits 1 at once, as one killed with taskkill /F does
$ShaderCacheKilled = $ShaderCacheOn + @("--script-opts-append=shader_cache-warmup_script=$((Join-Path $TestsDir 'lib/warmup-killed.lua').Replace('\', '/'))")
# two rebuilds in one session: a stand-in that ends itself after 2.5 s, a 4 s timeout,
# and no warm-up started by the check itself
$ShaderCacheTwice = $ShaderCacheOn + @('--script-opts-append=shader_cache-auto=no', '--script-opts-append=shader_cache-timeout=10',
    "--script-opts-append=shader_cache-warmup_script=$((Join-Path $TestsDir 'lib/warmup-slow-killed.lua').Replace('\', '/'))")

# notify-render: a VO with a real OSD surface but no window and no GPU (see
# test-notify-render.lua). sixel writes terminal graphics to stdout, a pipe
# here, so it cannot ask a console for its size: rows/cols and pixels are
# given, 10 rows of 600 px leave 540 (the last row is never drawn on), and the
# 960x540 clip then fills the canvas - OSD pixels = screenshot pixels. A small
# window on purpose: at a height of 720 the OSD font formula's h/720 is 1 and a
# broken conversion would go unnoticed.
$RealOsd = @('--vo=sixel', '--vo-sixel-cols=80', '--vo-sixel-rows=10', '--vo-sixel-width=960', '--vo-sixel-height=600',
    '--vo-sixel-dither=none', '--vo-sixel-alt-screen=no', '--vo-sixel-config-clear=no')
$RealOsdClip = 'av://lavfi:color=c=0x3060C0:s=960x540:r=24:d=120'

# After the player quit mid warm-up: its host.ps1 and the warm-up mpv must be
# gone (mpv kills its subprocesses on exit; host.ps1's job object takes mpv).
# Matched by the work folder's own name, not 'mpv-regression' (the default): with
# -WorkDir elsewhere nothing matched and the check passed whatever was left. Not the
# whole path: a command line can carry the temp folder in its 8.3 form (RUNNER~1).
$NoWarmupLeft = {
    param([string]$Name, [string]$Label)
    $workName = [regex]::Escape((Split-Path -Leaf $WorkDir))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $left = @(Get-CimInstance Win32_Process -Filter "Name='mpv.exe' OR Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'host\.ps1|warmup\.lua' -and $_.CommandLine -match $workName })
        if ($left.Count) { Start-Sleep -Milliseconds 100 }
    } while ($left.Count -and $sw.ElapsedMilliseconds -lt 3000)
    Add-Result $Name "${Label}quitting the player ends its warm-up (no host.ps1 or warm-up mpv left)" ($left.Count ? 'FAIL' : 'PASS') `
    ($left.Count ? "still running after 3 s: $(($left | ForEach-Object { "$($_.Name) $($_.ProcessId)" }) -join ', ')" : '')
    $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$HeadlessTests = @(
    @{ Name = 'mouse'; Phases = @(@{ Script = 'headless/test-mouse.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'notify'; Phases = @(@{ Script = 'headless/test-notify.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'notify-render'; Phases = @(@{ Script = 'headless/test-notify-render.lua'; File = $RealOsdClip; Args = $RealOsd }) }
    @{ Name = 'bottom-bar'; Phases = @(@{ Script = 'headless/test-bottom-bar.lua'; File = 'subs/movie.mkv' }) }
    @{ Name = 'video-info'; Phases = @(@{ Script = 'headless/test-video-info.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'source-info'; Phases = @(@{ Script = 'headless/test-source-info.lua'; File = 'plain/clip.mkv'; Args = @('--script-opts-append=source_info-launch=no') }) }
    @{ Name = 'music-info'; Phases = @(@{ Script = 'headless/test-music-info.lua'; File = 'music-tagged/Nova Lane - Paper Lanterns.mp3' }) }
    @{ Name = 'keys'; Phases = @(@{ Script = 'headless/test-keys.lua'; File = 'long/long.mkv' }) }
    @{ Name = 'speed'; Phases = @(@{ Script = 'headless/test-speed.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'remember-speed'; Phases = @(
            @{ Script = 'headless/test-remember-speed-save.lua'; File = 'plain/clip.mkv' }
            @{ Script = 'headless/test-remember-speed-restore.lua'; File = 'plain/clip.mkv' })
    }
    @{ Name = 'auto-start'; Phases = @(@{ Script = 'headless/test-auto-start.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'subtitles'; Phases = @(@{ Script = 'headless/test-subtitles.lua'; File = 'subs/movie.mkv' }) }
    @{ Name = 'subtitle-sync'; Phases = @(@{ Script = 'headless/test-subtitle-sync.lua'; File = 'sync/talk.mkv' }) }
    @{ Name = 'menus'; Phases = @(@{ Script = 'headless/test-menus.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'autoload'; Phases = @(@{ Script = 'headless/test-autoload.lua'; File = 'autoload/episode1.mkv' }) }
    @{ Name = 'upscale'; Phases = @(@{ Script = 'headless/test-upscale.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'sharpness-memory'; Phases = @(
            @{ Script = 'headless/test-sharpness-save.lua'; File = 'plain/clip.mkv' }
            @{ Script = 'headless/test-sharpness-restore.lua'; File = 'plain/clip.mkv' })
    }
    @{ Name = 'config'; Phases = @(@{ Script = 'headless/test-config.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'stream-resume'; Phases = @(
            @{ Script = 'headless/test-stream-resume-save.lua'; File = 'fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv' }
            @{ Script = 'headless/test-stream-resume-restore.lua'; File = 'fs-anime-token2/ep1-newtoken#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv' })
    }
    @{ Name = 'shader-cache'; Phases = @(
            @{ Script = 'headless/test-shader-cache-cold.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheOn }
            @{ Script = 'headless/test-shader-cache-fresh.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheOn }
            @{ Script = 'headless/test-shader-cache-quit.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheIdles; After = $NoWarmupLeft }
            @{ Script = 'headless/test-shader-cache-quick.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheOn }
            @{ Script = 'headless/test-shader-cache-interrupted.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheKilled }
            @{ Script = 'headless/test-shader-cache-timeout.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheHangs }
            @{ Script = 'headless/test-shader-cache-failed-before.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheHangs }
            @{ Script = 'headless/test-shader-cache-rebuild.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheOn }
            @{ Script = 'headless/test-shader-cache-idle.lua'; File = $null; Args = $ShaderCacheOn }
            @{ Script = 'headless/test-shader-cache-twice.lua'; File = 'plain/clip.mkv'; Args = $ShaderCacheTwice })
    }
)

$GpuTests = @(
    @{ Name = 'gpu-switching'; Phases = @(@{ Script = 'gpu/test-switching.lua'; File = 'gpu/anime720/ep#fs-content=anime&fs-id=1111111111111111.mkv' }) }
    @{ Name = 'gpu-pacing'; Phases = @(@{ Script = 'gpu/test-pacing.lua'; File = 'gpu/anime720/ep#fs-content=anime&fs-id=1111111111111111.mkv' }) }
)

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Invoke-StaticCheck

if ($RunHeadless) {
    Write-Section 'headless tests (mpv --vo=null, isolated copy)'
    $exe = Initialize-TestRoot
    $media = Initialize-Media $exe $RunGpu
    # The whole config loads without a single warning or error. mpv only LOGS a
    # rejected option (bad value, a '#' that cut a value short, a renamed option
    # after an mpv update) and plays on without it, so this is the one place
    # such a break shows. --keep-open=no: mpv.conf's keep-open=yes would wait
    # on the last frame forever.
    if ('config-load' -like $Filter) {
        Write-Host ''
        Write-Host '-- config-load' -ForegroundColor White
        $r = Invoke-Mpv $exe @('--vo=null', '--ao=null', '--idle=no', '--keep-open=no', '--frames=1', '--msg-level=all=warn',
            $ShaderCacheOff, 'av://lavfi:color=c=black:s=64x64:d=1') -TimeoutSeconds 60
        $said = @(("$($r.StdOut)`n$($r.StdErr)" -split "`r?`n") | Where-Object { $_.Trim() })
        Test-Check 'config-load' 'mpv loads mpv.conf, profiles and scripts with no warning or error' (
            $said.Count -eq 0 -and -not $r.TimedOut -and $r.ExitCode -eq 0) (($said -join ' | ') + ($r.TimedOut ? ' (timed out)' : ''))
    }
    foreach ($test in $HeadlessTests | Where-Object { $_.Name -like $Filter }) {
        Invoke-RuntimeTest $exe $media $test @('--vo=null', '--ao=null', $ShaderCacheOff)
    }
}

if ($RunGpu) {
    Write-Section 'gpu tests (real renderer, fullscreen)'
    $running = @(Get-Process mpv -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Add-Result 'gpu' 'gpu tier' 'SKIP' "mpv is running (pid $($running.Id -join ', ')) - you may be watching; close it and re-run"
    }
    else {
        $cacheCopy = Join-Path $WorkDir 'gpu-cache'
        Remove-Item -Recurse -Force $cacheCopy -ErrorAction SilentlyContinue
        $realCache = Join-Path $Cfg 'cache'
        if (Test-Path $realCache) { Copy-Item $realCache $cacheCopy -Recurse } else { New-Item -ItemType Directory $cacheCopy | Out-Null }

        if ('gpu-warm-cache' -like $Filter) {
            Write-Host ''
            Write-Host '-- gpu-warm-cache' -ForegroundColor White
            $warm = & (Join-Path $RepoRoot 'installer/warm-shader-cache.ps1') -MpvExe $exe -CacheDir $cacheCopy -Check -Quiet
            foreach ($line in $warm) {
                if ("$line" -match '^RESULT (PASS|FAIL|INFO) (.*?)(?: :: (.*))?$') {
                    Add-Result 'gpu-warm-cache' $Matches[2] $Matches[1] ($Matches[3] ?? '')
                }
            }
        }
        foreach ($test in $GpuTests | Where-Object { $_.Name -like $Filter }) {
            Invoke-RuntimeTest $exe $media $test @('--fs', '--ao=null', "--gpu-shader-cache-dir=$cacheCopy", $ShaderCacheOff) -TimeoutSeconds 300
        }

        # The automatic warm-up for real: an EMPTY cache, the real renderer, the
        # warm-up in the background (~8 s, paused halfway), then a second start
        # that must be fresh.
        if ('gpu-auto-warm' -like $Filter) {
            $coldCache = Join-Path $WorkDir 'gpu-cold-cache'
            Remove-Item -Recurse -Force $coldCache -ErrorAction SilentlyContinue
            $on = @('--script-opts-append=shader_cache-auto=yes', "--gpu-shader-cache-dir=$coldCache")
            $clip = 'gpu/anime720/ep#fs-content=anime&fs-id=1111111111111111.mkv'
            Invoke-RuntimeTest $exe $media @{ Name = 'gpu-auto-warm'; Phases = @(
                    @{ Script = 'gpu/test-auto-warm-cold.lua'; File = $clip; Args = $on }
                    @{ Script = 'gpu/test-auto-warm-fresh.lua'; File = $clip; Args = $on })
            } @('--fs', '--ao=null', $ShaderCacheOff) -TimeoutSeconds 300
        }
    }
}

# ---------------------------------------------------------------------------
# shader cost: empty shader caches against warm ones (-Tier shadercost)
# ---------------------------------------------------------------------------
# Asked 2026-10-05: is the background warm-up (Scripts/shader-cache) worth its
# ~3,500 lines? Without it, mpv still keeps every shader it compiles; what a
# viewer would notice is the FIRST video of each kind after a GPU driver or
# libplacebo update, which leaves both mpv's cache and the AMD driver's own
# cache cold. So this tier empties both: mpv's for every cold run (a new
# folder), and the driver's (%LOCALAPPDATA%\AMD\VkCache, which games share) by
# setting the owner's folder aside for the whole run, emptying the stand-in
# before every cold run and before the warm-up, and putting the owner's back
# at the end - also after a failure or Ctrl+C, and, if a run was killed, at the
# start of the next one. measure-shader-cost.lua's header says what is
# measured; tests/README.md has the decision rule.
#
# Every case starts in a fresh mpv with the upscale setting already chosen (1 =
# Auto: a FastStream file - the #fs-content= marker in the name - gets its
# preset when it loads; 0 = Off), so the first frame is drawn through the chain.
# Together they cover every path the upscalers take (each Anime4K stage the
# scale switches on, Movie with and without FSRCNNX and the sharpener), the
# colour paths (SDR 8/10-bit, decoded on the GPU and on the CPU, bt.601 DVD,
# HDR10, HLG, Dolby Vision profiles 5/8.1/8.4) with each chain, a song with
# cover art, and what a viewer does mid-video: every upscale switch, every
# Movie sharpness level, window sizes, fullscreen, a picture overlay (timeline
# thumbnails, picture subtitles) and two Video menu settings.
function Get-CostAction([string]$Name, [string]$Kind, [string]$Value = '') { @{ name = $Name; kind = $Kind; value = $Value } }
$CostCases = @(
    # each stage of Anime4K the scale switches on (1440p screen: 4x / 3x / 2.5x / 2x / 1.33x / scaled down)
    @{ Label = 'Anime 360p'; Clip = 'h264-360'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 480p'; Clip = 'h264-480'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 576p'; Clip = 'h264-576'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 720p'; Clip = 'h264-720'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 1080p'; Clip = 'h264-1080'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 1080p, 10-bit HEVC'; Clip = 'hevc10-1080'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 720p, 10-bit H.264 (decoded on the CPU)'; Clip = 'h264hi10-720'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'Anime 2160p (scaled down)'; Clip = 'h264-2160'; Content = 'anime'; Preset = 'anime' }
    # Movie: FSRCNNX + SSimSuperRes from 2x, SSimSuperRes alone below, the sharpener only when enlarged
    @{ Label = 'Movie 480p'; Clip = 'h264-480'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Movie 576p DVD (MPEG-2, bt.601, decoded on the CPU)'; Clip = 'mpeg2-576'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Movie 720p'; Clip = 'h264-720'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Movie 810p'; Clip = 'h264-810'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Movie 1080p'; Clip = 'h264-1080'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Movie 1080p, 10-bit HEVC'; Clip = 'hevc10-1080'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Movie 2160p (scaled down)'; Clip = 'h264-2160'; Content = 'movie'; Preset = 'movie' }
    # no upscaler
    @{ Label = 'Off 720p'; Clip = 'h264-720'; Mode = '0'; Preset = 'off' }
    @{ Label = 'Off 1080p'; Clip = 'h264-1080'; Mode = '0'; Preset = 'off' }
    @{ Label = 'Off 2160p'; Clip = 'h264-2160'; Mode = '0'; Preset = 'off' }
    # HDR and Dolby Vision, each colour path with the chains (every pass compiles again per colour path)
    @{ Label = 'HDR10 1080p, Off'; Clip = 'hdr10-1080'; Mode = '0'; Preset = 'off' }
    @{ Label = 'HDR10 1080p, Anime'; Clip = 'hdr10-1080'; Content = 'anime'; Preset = 'anime' }
    @{ Label = 'HDR10 1080p, Movie'; Clip = 'hdr10-1080'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'HDR10 2160p, Off'; Clip = 'hdr10-2160'; Mode = '0'; Preset = 'off' }
    @{ Label = 'HDR10 2160p, Movie'; Clip = 'hdr10-2160'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'HLG 1080p, Off'; Clip = 'hlg-1080'; Mode = '0'; Preset = 'off' }
    @{ Label = 'HLG 1080p, Movie'; Clip = 'hlg-1080'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Dolby Vision profile 5, Off'; Clip = 'dv-p5'; Mode = '0'; Preset = 'off' }
    @{ Label = 'Dolby Vision profile 5, Movie'; Clip = 'dv-p5'; Content = 'movie'; Preset = 'movie' }
    @{ Label = 'Dolby Vision profile 8.1, Off'; Clip = 'dv-p8.1'; Mode = '0'; Preset = 'off' }
    @{ Label = 'Dolby Vision profile 8.4, Off'; Clip = 'dv-p8.4'; Mode = '0'; Preset = 'off' }
    @{ Label = 'Song with cover art'; Clip = 'song'; Mode = '0'; Preset = 'off' }
    # what a viewer does mid-video, each action the first of its kind in the process
    @{ Label = 'Anime 1080p, then every upscale switch'; Clip = 'h264-1080-long'; Content = 'anime'; Preset = 'anime'; Actions = @(
            Get-CostAction 'switch to Movie' upscale 3
            Get-CostAction 'Movie sharpness Medium' sharpness 1
            Get-CostAction 'Movie sharpness High' sharpness 1.5
            Get-CostAction 'Movie sharpness Off' sharpness 0
            Get-CostAction 'Movie sharpness Low' sharpness 0.5
            Get-CostAction 'Movie sharpness Auto' sharpness auto
            Get-CostAction 'switch to Off' upscale 0
            Get-CostAction 'switch to Anime' upscale 2)
    }
    @{ Label = 'Movie 720p, then every upscale switch'; Clip = 'h264-720-long'; Content = 'movie'; Preset = 'movie'; Actions = @(
            Get-CostAction 'Movie sharpness High' sharpness 1.5
            Get-CostAction 'Movie sharpness Low' sharpness 0.5
            Get-CostAction 'Movie sharpness Off' sharpness 0
            Get-CostAction 'Movie sharpness Auto' sharpness auto
            Get-CostAction 'switch to Anime' upscale 2
            Get-CostAction 'switch to Off' upscale 0
            Get-CostAction 'switch to Movie' upscale 3)
    }
    @{ Label = 'Anime 720p, then window sizes'; Clip = 'h264-720-long'; Content = 'anime'; Preset = 'anime'; Actions = @(
            Get-CostAction 'leave fullscreen (window at the video''s size)' fullscreen no
            Get-CostAction 'half-size window' window-scale 0.5
            Get-CostAction 'maximized window' maximize
            Get-CostAction 'back to fullscreen' fullscreen yes)
    }
    @{ Label = 'Local 1080p, Off, then overlay, Video menu, windows, upscalers'; Clip = 'h264-1080-long'; Mode = '0'; Preset = 'off'; Actions = @(
            Get-CostAction 'picture overlay (thumbnails, picture subtitles)' overlay '{overlay}'
            Get-CostAction 'Video menu: contrast +1' property contrast=1
            Get-CostAction 'Video menu: deband off' property deband=no
            Get-CostAction 'leave fullscreen (window at the video''s size)' fullscreen no
            Get-CostAction 'half-size window' window-scale 0.5
            Get-CostAction 'maximized window' maximize
            Get-CostAction 'back to fullscreen' fullscreen yes
            Get-CostAction 'switch to Anime' upscale 2
            Get-CostAction 'switch to Movie' upscale 3)
    }
    @{ Label = 'HDR10 1080p, Off, then upscalers and windows'; Clip = 'hdr10-1080'; Mode = '0'; Preset = 'off'; Actions = @(
            Get-CostAction 'switch to Anime' upscale 2
            Get-CostAction 'switch to Movie' upscale 3
            Get-CostAction 'leave fullscreen (window at the video''s size)' fullscreen no
            Get-CostAction 'back to fullscreen' fullscreen yes)
    }
)

# Clip recipes (mpv's own encoder, testsrc2 at 24 fps): size, pixel format,
# encoder, seconds (start-only cases need 12; the action cases' clips must
# outlast all their windows, or a loop seek lands in one), aspect, colour tags
# (FFmpeg names; set on the frames AND as encoder options - mpv's encoder drops
# primaries/transfer from the frames, cases.lua). dv-*: the Dolby Vision clips
# the warm-up ships (no encoder writes an RPU); song: an mp3 with a cover.jpg.
$CostHdr10 = @{ colorspace = 'bt2020nc'; color_primaries = 'bt2020'; color_trc = 'smpte2084' }
$CostClips = @{
    'h264-360'       = @{ Size = '640x360' }
    'h264-480'       = @{ Size = '854x480' }
    'h264-576'       = @{ Size = '1024x576' }
    'h264-720'       = @{ Size = '1280x720' }
    'h264-810'       = @{ Size = '1440x810' }
    'h264-1080'      = @{ Size = '1920x1080' }
    'h264-2160'      = @{ Size = '3840x2160' }
    'h264-720-long'  = @{ Size = '1280x720'; Seconds = 40 }
    'h264-1080-long' = @{ Size = '1920x1080'; Seconds = 40 }
    'hevc10-1080'    = @{ Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx265' }
    'h264hi10-720'   = @{ Size = '1280x720'; Pix = 'yuv420p10le' }
    'mpeg2-576'      = @{ Size = '720x576'; Ovc = 'mpeg2video'; Sar = '64/45'; Tags = @{ colorspace = 'smpte170m'; color_primaries = 'bt470bg'; color_trc = 'bt709' } }
    'hdr10-1080'     = @{ Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Seconds = 30; Tags = $CostHdr10 }
    'hdr10-2160'     = @{ Size = '3840x2160'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Tags = $CostHdr10 }
    'hlg-1080'       = @{ Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Tags = @{ colorspace = 'bt2020nc'; color_primaries = 'bt2020'; color_trc = 'arib-std-b67' } }
}

# The decision rule, set 2026-10-05 BEFORE any number was seen. Per case, what
# the warm-up saves = a state minus warm, medians over the repeats. "Start" =
# first frame + the longest pause in the first seconds (a chain set after the
# first frame compiles there). A hitch = an action with more than EventLate
# extra late frames or an extra pause of EventPauseMs or more. Applied to cold
# (the first video of a kind after an update) and to again (every later one,
# mpv's own cache only): any hitch, or a start extra of KeepStartMs or more ->
# KEEP (the warm-up stays; its capture log, learned cases and gap hunt went
# with this verdict, 2026-10-05); every start extra under DeleteStartMs and no hitch in both -> DELETE;
# else UNCLEAR (judge by eye: a week with shader_cache-auto=no). A run whose
# checks failed (wrong chain, an error, a driver cache that was not cold)
# never counts; a case without a valid run in every state -> INCOMPLETE.
$CostRule = @{ DeleteStartMs = 500; KeepStartMs = 1000; EventLate = 2; EventPauseMs = 250 }
$CostWindows = @{ Start = 3; Action = 2 }

# The AMD driver's own Vulkan pipeline cache, and where the owner's is kept
# while this tier runs.
$AmdCache = $env:LOCALAPPDATA ? (Join-Path (Join-Path $env:LOCALAPPDATA 'AMD') 'VkCache') : $null
$AmdBackup = $AmdCache ? "$AmdCache.mpv-shadercost-backup" : $null

function Get-AmdShaderCacheSize {
    if (-not $AmdCache -or -not (Test-Path -LiteralPath $AmdCache)) { return $null }
    # summed by hand: Measure-Object returns nothing for an empty folder (StrictMode then throws on .Sum)
    $sum = [long]0
    foreach ($f in Get-ChildItem -LiteralPath $AmdCache -Recurse -File -Force -ErrorAction SilentlyContinue) { $sum += $f.Length }
    return $sum
}

# Puts the owner's AMD cache back - set aside by this run, or by one that was
# killed. Only this run's own stand-in (what the test runs compiled) is
# deleted: after a killed run the folder there may be one the driver built
# since (games run meanwhile), and that one is kept beside it, renamed. True
# when nothing is left aside.
function Restore-AmdShaderCache([bool]$OwnStandIn = $false) {
    if (-not $AmdBackup -or -not (Test-Path -LiteralPath $AmdBackup)) { return $true }
    try {
        if (Test-Path -LiteralPath $AmdCache) {
            if ($OwnStandIn) { Remove-Item -LiteralPath $AmdCache -Recurse -Force }
            else {
                $kept = "$AmdCache.rebuilt-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Move-Item -LiteralPath $AmdCache -Destination $kept
                Write-Host "  the AMD cache found in its place is kept as $kept (delete it once all is well)" -ForegroundColor Yellow
            }
        }
        Move-Item -LiteralPath $AmdBackup -Destination $AmdCache
        Write-Host "  AMD's shader cache is back in $AmdCache" -ForegroundColor DarkGray
        return $true
    }
    catch {
        Write-Host "  AMD's shader cache could NOT be put back ($($_.Exception.Message)): close every program that uses the GPU, then rename $AmdBackup to VkCache - or run this tier again, it does that first" -ForegroundColor Red
        return $false
    }
}

# One rename (it fails, changing nothing, while a program has a file in it
# open), then an empty stand-in in its place.
function Backup-AmdShaderCache {
    Move-Item -LiteralPath $AmdCache -Destination $AmdBackup -ErrorAction Stop
    New-Item -ItemType Directory $AmdCache | Out-Null
}

function Clear-AmdShaderCache {
    Get-ChildItem -LiteralPath $AmdCache -Force | Remove-Item -Recurse -Force -ErrorAction Stop
}

function Build-CostClip([string]$Exe, [string]$Id, [string]$Path) {
    $c = $CostClips[$Id]
    $ovc = $c['Ovc'] ?? 'libx264'
    $chain = "testsrc2=size=$($c.Size):rate=24:duration=$($c['Seconds'] ?? 12),format=$($c['Pix'] ?? 'yuv420p')"
    if ($c['Sar']) { $chain += ",setsar=$($c['Sar'])" }
    $opts = @(@{ libx264 = @('preset=ultrafast', 'g=24'); libx265 = @('preset=ultrafast') }[$ovc] | Where-Object { $_ })
    if ($c['Tags']) {
        $tags = @($c['Tags'].GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" })
        $chain += ',setparams=' + ($tags -join ':')
        $opts += $tags
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $tmp = Join-Path (Split-Path -Parent $Path) ('encoding-' + [guid]::NewGuid().ToString('N') + '.mkv')
    $a = @('--no-config', '--really-quiet', "av://lavfi:$chain", "--o=$tmp", "--ovc=$ovc")
    if ($opts.Count) { $a += '--ovcopts=' + ($opts -join ',') }
    $r = Invoke-Mpv $Exe $a -TimeoutSeconds 900
    if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1000) {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        throw "making the clip $Id failed: $(($r.StdErr -split "`n" | Select-Object -Last 3) -join ' ')"
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Makes what the cases need (once, reused by later runs) and returns each
# case's file: the clip itself, or a copy whose name carries the FastStream
# marker, each in a folder of its own (autoload).
function Initialize-CostMedia([string]$Exe, [object[]]$Cases) {
    $m = Join-Path $WorkDir 'media-cost-v1'
    Write-Host "  preparing the clips in $m" -ForegroundColor DarkGray
    $paths = foreach ($c in $Cases) {
        $id = $c.Clip
        if ($id -like 'dv-*') {
            $file = Join-Path $m "$id/$id.mp4"
            if (-not (Test-Path -LiteralPath $file)) {
                New-Item -ItemType Directory -Force (Split-Path -Parent $file) | Out-Null
                Copy-Item -LiteralPath (Join-Path $Cfg "Scripts/shader-cache/clips/$id.mp4") -Destination $file
            }
        }
        elseif ($id -eq 'song') {
            $file = Join-Path $m 'song/song.mp3'
            $cover = Join-Path $m 'song/cover.jpg'
            if (-not (Test-Path -LiteralPath $file)) {
                New-Item -ItemType Directory -Force (Split-Path -Parent $file) | Out-Null
                $null = Invoke-Mpv $Exe @('--no-config', '--really-quiet', 'av://lavfi:sine=frequency=440:duration=20', "--o=$file", '--oac=libmp3lame')
                if (-not (Test-Path -LiteralPath $file)) { throw 'making the song failed' }
            }
            if (-not (Test-Path -LiteralPath $cover)) {
                $dir = Split-Path -Parent $cover
                $null = Invoke-Mpv $Exe @('--no-config', '--really-quiet', 'av://lavfi:testsrc2=size=720x720', '--frames=1', '--vo=image',
                    '--vo-image-format=jpg', "--vo-image-outdir=$dir")
                $shot = Join-Path $dir '00000001.jpg'
                if (-not (Test-Path $shot)) { throw 'making the cover art failed' }
                Move-Item -LiteralPath $shot -Destination $cover -Force
            }
        }
        else {
            $file = Join-Path $m "$id/$id.mkv"
            if (-not (Test-Path -LiteralPath $file)) { Build-CostClip $Exe $id $file }
        }
        if ($c['Content']) {
            $ext = [IO.Path]::GetExtension($file)
            $marked = Join-Path $m "$id-$($c.Content)/$id#fs-content=$($c.Content)$ext"
            if (-not (Test-Path -LiteralPath $marked)) {
                New-Item -ItemType Directory -Force (Split-Path -Parent $marked) | Out-Null
                Copy-Item -LiteralPath $file -Destination $marked
            }
            $file = $marked
        }
        $file
    }
    return , @($paths)
}

# A property of a parsed result, or $Default (StrictMode throws on a missing one).
function Get-CostValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    return $p ? $p.Value : $Default
}

function Get-Median([object[]]$Values) {
    $s = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    $n = $s.Count
    return ($n % 2) ? $s[[int](($n - 1) / 2)] : ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

# One run: a fresh mpv on the given cache folder. Not through
# Invoke-RuntimeTest: that adds --log-file, which raises libplacebo's log level
# (measure-shader-cost.lua's header); the script reports script and renderer
# errors itself. Returns the parsed result, whether every check passed, and
# how much the AMD driver's cache grew (KB, $null without one).
#
# It stops the whole tier rather than start the next fullscreen mpv when a run
# shows the GPU in trouble: on 2026-10-04 a lost Vulkan device, then more
# fullscreen starts, left the RX 9070 XT's driver failed to load (black screen,
# CM_PROB_FAILED_ADD) until a restart. Before each run the graphics card must be
# OK in Windows' eyes; after it, no timeout, no lost or removed device in mpv's
# errors, and no vulkan decoding (refused since that day, mpv.conf's hwdec).

# Why the graphics card is not fit for a run, or $null when it is.
function Get-GpuTrouble {
    $bad = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
    if ($bad.Count) { return ($bad | ForEach-Object { "$($_.FriendlyName) is $($_.Status) ($($_.Problem))" }) -join '; ' }
    return $null
}

# Why the tier must stop after a run, or $null.
function Get-CostAbortReason($Run, $Data) {
    if ($Run.TimedOut) { return 'mpv did not finish and was killed' }
    $errors = @(if ($Data -and $Data.PSObject.Properties['errors']) { $Data.errors })
    $lost = @($errors | Where-Object { "$_" -match 'DEVICE_LOST|DEVICE_REMOVED|887a0005|887a0006|Failed acquiring swapchain' })
    if ($lost.Count) { return "the GPU device was lost: $($lost[0])" }
    if ($Data -and "$(Get-CostValue $Data 'hwdec' '')" -match 'vulkan') { return "it decoded with $($Data.hwdec), which this config refuses" }
    return Get-GpuTrouble
}

function Invoke-CostCase([string]$Exe, [hashtable]$Case, [string]$Path, [string]$State, [int]$Rep, [string]$Cache, [string]$Dir, [int]$Index, [string]$Overlay) {
    $root = Split-Path -Parent $Exe
    Clear-State $root
    $test = "shader-cost ($State)"
    $tag = "$State-$Rep-$Index"
    $out = Join-Path $Dir "result-$tag.json"
    $manifest = Join-Path $Dir "case-$tag.json"
    $actions = @(@($Case['Actions'] ?? @()) | ForEach-Object { @{ name = $_.name; kind = $_.kind; value = $_.value.Replace('{overlay}', $Overlay.Replace('\', '/')) } })
    [ordered]@{
        label = $Case.Label; state = $State; repeat = $Rep; path = $Path.Replace('\', '/'); mode = $Case['Mode'] ?? '1'; preset = $Case.Preset
        expect = @(($Case.Preset -eq 'anime') ? 'Anime4K' : @()); actions = $actions
        start_seconds = $CostWindows.Start; action_seconds = $CostWindows.Action; out = $out.Replace('\', '/')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
    Write-Host ''
    Write-Host "-- $($Case.Label) ($State, run $Rep of $Repeat)" -ForegroundColor White
    $mpvArgs = @("--script=$(Join-Path $TestsDir 'gpu/measure-shader-cost.lua')", '--no-terminal', '--fs', '--ao=null',
        '--force-window=yes', '--idle=yes', '--loop-file=inf', "--gpu-shader-cache-dir=$Cache", $ShaderCacheOff,
        '--script-opts-append=gpu_toggles-remember=no',
        "--script-opts-append=shader_cost-manifest=$($manifest.Replace('\', '/'))")
    $trouble = Get-GpuTrouble
    if ($trouble) { throw "stopped before $($Case.Label) ($State $Rep): $trouble - no mpv was started" }
    $amd0 = Get-AmdShaderCacheSize
    $r = Invoke-Mpv $Exe $mpvArgs @{ MPV_TEST_ROOT = $root.Replace('\', '/'); MPV_TEST_TIMEOUT = 100 } -TimeoutSeconds 120
    $amd1 = Get-AmdShaderCacheSize
    $done = $false
    $failed = $false
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -match '^RESULT DONE ') { $done = $true }
        if ($line -match '^RESULT (PASS|FAIL|INFO) (.*?)(?: :: (.*))?$') {
            if ($Matches[1] -eq 'FAIL') { $failed = $true }
            Add-Result -Test $test -Check $Matches[2] -Status $Matches[1] -Detail ($Matches[3] ?? '')
        }
    }
    if ($r.TimedOut) { Add-Result $test "$($Case.Label) ($State $Rep): mpv finished" 'FAIL' 'killed after 120 s' }
    elseif (-not $done) { Add-Result $test "$($Case.Label) ($State $Rep): the run went to its end" 'FAIL' "exit $($r.ExitCode), no RESULT DONE" }
    $data = (Test-Path -LiteralPath $out) ? (Get-Content -Raw -LiteralPath $out | ConvertFrom-Json) : $null
    $abort = Get-CostAbortReason $r $data
    if ($abort) { throw "stopped after $($Case.Label) ($State $Rep): $abort - no further mpv is started" }
    [pscustomobject]@{
        Case = $Index; State = $State; Rep = $Rep; Data = $data
        AmdKB = ($null -ne $amd0 -and $null -ne $amd1) ? [math]::Round(($amd1 - $amd0) / 1KB) : $null
        Valid = $done -and -not $failed -and -not $r.TimedOut -and $null -ne $data -and (Get-CostValue $data 'valid' $false)
    }
}

# Medians over a case's valid runs in one state.
function Get-CostSummary([object[]]$Runs) {
    $ok = @($Runs | Where-Object { $_ -and $_.Valid })
    if ($ok.Count -eq 0) { return $null }
    $d0 = $ok[0].Data
    $windows = @(for ($k = 0; $k -lt @($d0.windows).Count; $k++) {
            [pscustomobject]@{
                Name  = @($d0.windows)[$k].name
                Late  = Get-Median @($ok | ForEach-Object { @($_.Data.windows)[$k].late })
                Pause = Get-Median @($ok | ForEach-Object { @($_.Data.windows)[$k].gap_ms })
                Chain = @($d0.windows)[$k].chain
            }
        })
    $starts = @($ok | ForEach-Object { $_.Data.first_ms + @($_.Data.windows)[0].gap_ms })
    [pscustomobject]@{
        Runs = $ok.Count; First = Get-Median @($ok | ForEach-Object { $_.Data.first_ms }); Start = Get-Median $starts; Starts = $starts
        Files = Get-Median @($ok | ForEach-Object { $_.Data.files }); AmdKB = Get-Median @($ok | ForEach-Object { $_.AmdKB })
        Windows = $windows; Video = $d0.video; Hwdec = $d0.hwdec; Chain = (Format-CostChain $d0.chain (Get-CostValue $d0 'sharpness' ''))
    }
}

# The chain in a few words: Anime4K and its pass count, or Movie's parts.
function Format-CostChain([string]$Chain, [string]$Sharpness) {
    if (-not $Chain) { return 'no upscaler' }
    $names = @($Chain -split ' ')
    if ($Chain -match 'Anime4K') { return "Anime4K ($($names.Count) shaders)" }
    $short = @($names | ForEach-Object { ($_ -replace '^FSRCNNX.*', 'FSRCNNX' -replace '^CfL_Prediction$', 'CfL' -replace '^adaptive-sharpen$', "sharpen $Sharpness") })
    return $short -join ' + '
}

function Get-CostVerdict([object[]]$Starts, [object[]]$Hitches) {
    $worst = $Starts.Count ? ($Starts | Measure-Object -Maximum).Maximum : 0
    if ($Hitches.Count -or $worst -ge $CostRule.KeepStartMs) { return 'KEEP' }
    if ($worst -lt $CostRule.DeleteStartMs) { return 'DELETE' }
    return 'UNCLEAR'
}

# The comparison and the verdict, as Markdown (to paste into the issue) and on
# the console. Returns the verdict word.
function Write-CostReport([object[]]$Cases, [object[]]$Runs, [string[]]$Header, [string]$Path) {
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add('## Shader warm-up: empty caches vs warm ones')
    $md.Add('')
    foreach ($h in $Header) { $md.Add("- $h") }
    $md.Add('')
    $md.Add('**cold** = mpv''s and the AMD driver''s shader caches empty (the first video of a kind after a driver or libplacebo update, without the warm-up); **again** = the same video once more without a warm-up (mpv''s own cache); **warm** = after the warm-up. Medians over the runs. Start = first frame + the longest pause in the first seconds; extra = that state minus warm (what the warm-up saves).')
    $md.Add('')
    $md.Add('| Case | video, decoder, chain | first frame cold / again / warm | longest pause at the start cold / again / warm | start extra cold (each run) | start extra again | shaders compiled cold / again / warm | AMD driver cache, cold |')
    $md.Add('|---|---|---|---|---|---|---|---|')
    $acts = [System.Collections.Generic.List[string]]::new()
    $starts = @{ cold = [System.Collections.Generic.List[object]]::new(); again = [System.Collections.Generic.List[object]]::new() }
    $hitches = @{ cold = [System.Collections.Generic.List[string]]::new(); again = [System.Collections.Generic.List[string]]::new() }
    $missing = [System.Collections.Generic.List[string]]::new()
    $worstCase = @{ cold = ''; again = '' }
    for ($i = 0; $i -lt $Cases.Count; $i++) {
        $label = $Cases[$i].Label
        $s = @{}
        foreach ($st in 'cold', 'again', 'warm') { $s[$st] = Get-CostSummary @($Runs | Where-Object { $_.Case -eq $i -and $_.State -eq $st }) }
        if (-not $s.cold -or -not $s.again -or -not $s.warm) {
            $missing.Add($label)
            $md.Add("| $label | no valid run in every state (see the FAIL lines) | | | | | | |")
            continue
        }
        $x = @{}
        foreach ($st in 'cold', 'again') {
            $x[$st] = [math]::Max(0, $s[$st].Start - $s.warm.Start)
            if ($x[$st] -ge (@($starts[$st]) | Measure-Object -Maximum).Maximum) { $worstCase[$st] = $label }
            $starts[$st].Add($x[$st])
        }
        $each = (@($s.cold.Starts | ForEach-Object { '+{0:n0}' -f [math]::Max(0, $_ - $s.warm.Start) }) -join ' / ')
        $md.Add(('| {0} | {1}, {2}, {3} | {4:n0} / {5:n0} / {6:n0} ms | {7:n0} / {8:n0} / {9:n0} ms | **+{10:n0} ms** ({11}) | +{12:n0} ms | {13:n0} / {14:n0} / {15:n0} | {16} |' -f $label,
                $s.warm.Video, $s.warm.Hwdec, $s.warm.Chain,
                $s.cold.First, $s.again.First, $s.warm.First, @($s.cold.Windows)[0].Pause, @($s.again.Windows)[0].Pause, @($s.warm.Windows)[0].Pause,
                $x.cold, $each, $x.again, $s.cold.Files, $s.again.Files, $s.warm.Files,
                (($null -ne $s.cold.AmdKB) ? ('{0:n0} KB' -f $s.cold.AmdKB) : 'n/a')))
        $n = [math]::Min([math]::Min(@($s.cold.Windows).Count, @($s.again.Windows).Count), @($s.warm.Windows).Count)
        for ($k = 1; $k -lt $n; $k++) {
            $w = @($s.warm.Windows)[$k]
            $mark = @()
            foreach ($st in 'cold', 'again') {
                $v = @($s[$st].Windows)[$k]
                $late = [math]::Max(0, $v.Late - $w.Late)
                $pause = [math]::Max(0, $v.Pause - $w.Pause)
                if ($late -gt $CostRule.EventLate -or $pause -ge $CostRule.EventPauseMs) {
                    $hitches[$st].Add("$label, $($v.Name): +$late late frames, +$pause ms pause")
                    $mark += "**hitch $st**"
                }
            }
            $c = @($s.cold.Windows)[$k]
            $a = @($s.again.Windows)[$k]
            $acts.Add(('| {0} | {1} | {2:n0} / {3:n0} / {4:n0} | {5:n0} / {6:n0} / {7:n0} ms | {8} |' -f $label, $c.Name, $c.Late, $a.Late, $w.Late, $c.Pause, $a.Pause, $w.Pause,
                    ($mark ? ($mark -join ', ') : 'ok')))
        }
    }
    $md.Add('')
    $md.Add('| Case | action | late frames cold / again / warm | longest pause cold / again / warm | |')
    $md.Add('|---|---|---|---|---|')
    foreach ($a in $acts) { $md.Add($a) }

    $v = @{ cold = (Get-CostVerdict @($starts.cold) @($hitches.cold)); again = (Get-CostVerdict @($starts.again) @($hitches.again)) }
    $worst = @{}
    foreach ($st in 'cold', 'again') { $worst[$st] = $starts[$st].Count ? ($starts[$st] | Measure-Object -Maximum).Maximum : 0 }
    $md.Add('')
    foreach ($st in 'cold', 'again') {
        $md.Add(('- {0}: the worst start costs +{1:n0} ms ({2}); {3} - by the rule alone: {4}' -f $st, $worst[$st], ($worstCase[$st] ? $worstCase[$st] : '-'),
                ($hitches[$st].Count ? "hitches: $($hitches[$st] -join '; ')" : 'no action hitches'), $v[$st]))
    }
    if ($missing.Count) {
        $verdict = 'INCOMPLETE'
        $why = "no valid run in every state for: $($missing -join ', ') - fix what the FAIL lines say and run it again (-Filter for those cases)"
    }
    elseif ($v.cold -eq 'KEEP' -or $v.again -eq 'KEEP') {
        $verdict = 'KEEP'
        $why = 'empty caches cost something you would see (above) - keep the warm-up'
    }
    elseif ($v.cold -eq 'DELETE' -and $v.again -eq 'DELETE') {
        $verdict = 'DELETE'
        $why = "without the warm-up every start costs under $($CostRule.DeleteStartMs) ms more, the first video after an update and every later one, and no action stutters - the warm-up saves nothing you would notice: switch it off (shader_cache-auto=no), then remove it"
    }
    else {
        $verdict = 'UNCLEAR'
        $why = "the worst start costs $($CostRule.DeleteStartMs)-$($CostRule.KeepStartMs) ms more and nothing stutters - judge by eye: a week with shader_cache-auto=no"
    }
    $md.Add('')
    $md.Add("**Verdict: $verdict** - $why.")
    $md.Add('')
    $md.Add("Rule (set 2026-10-05, before the numbers), applied to cold and to again: every start extra under $($CostRule.DeleteStartMs) ms and no hitch in both -> DELETE; a hitch (more than $($CostRule.EventLate) extra late frames, or an extra pause of $($CostRule.EventPauseMs) ms or more, after an action) or a start extra of $($CostRule.KeepStartMs) ms or more in either -> KEEP; else UNCLEAR. Runs whose checks failed do not count.")
    Set-Content -LiteralPath $Path -Value $md -Encoding utf8NoBOM
    Write-Host ''
    foreach ($l in $md) { Write-Host $l }
    return $verdict
}

if ($RunCost) {
    Write-Section 'shader cost (real renderer, fullscreen): empty shader caches vs warm ones'
    # a killed run left the owner's AMD cache aside: back first, whatever else happens
    $restored = Restore-AmdShaderCache
    $running = @(Get-Process mpv -ErrorAction SilentlyContinue)
    if (-not $restored) {
        Add-Result 'shader-cost' "the AMD driver's shader cache an earlier run set aside is back" 'FAIL' "it is still in $AmdBackup - see the red line above"
    }
    elseif ($running.Count -gt 0) {
        Add-Result 'shader-cost' 'shadercost tier' 'SKIP' "mpv is running (pid $($running.Id -join ', ')) - you may be watching; close it and re-run"
    }
    elseif (-not $AmdCache -or -not (Test-Path -LiteralPath $AmdCache)) {
        Add-Result 'shader-cost' "the AMD driver's shader cache is there to empty" 'FAIL' "not found at $AmdCache - without emptying it the cold runs are not cold (is the shader cache switched off in AMD Software?)"
    }
    else {
        $exe = Initialize-TestRoot
        $root = Split-Path -Parent $exe
        $cases = @($CostCases | Where-Object { $_.Label -like $Filter })
        # The config it measures decodes with no vulkan (the static rule, checked again here:
        # -ConfigDir can name another config), and the graphics card is fine to start with.
        $vkHwdec = @(Get-Content -LiteralPath (Join-Path $root 'portable_config/mpv.conf') | Where-Object { $_ -match '^\s*hwdec\s*=.*\b(vulkan|auto)' })
        $gpuTrouble = Get-GpuTrouble
        if ($vkHwdec.Count) {
            Add-Result 'shader-cost' 'the measured config decodes without vulkan' 'FAIL' "$($vkHwdec -join ' | ') - vulkan decoding lost the GPU device on 2026-10-04"
            $cases = @()
        }
        elseif ($gpuTrouble) {
            Add-Result 'shader-cost' 'the graphics card is OK before the first run' 'FAIL' $gpuTrouble
            $cases = @()
        }
        $costDir = Join-Path $WorkDir 'shader-cost'
        Remove-Item -Recurse -Force $costDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory $costDir | Out-Null
        # a 64x64 half-transparent BGRA picture for the overlay action
        $overlay = Join-Path $costDir 'overlay.bgra'
        [IO.File]::WriteAllBytes($overlay, [byte[]](@(255, 255, 255, 128) * 4096))
        $paths = $null
        if ($cases.Count -eq 0) {
            if (-not $vkHwdec.Count -and -not $gpuTrouble) { Add-Result 'shader-cost' 'shadercost tier' 'SKIP' "no case matches -Filter '$Filter'" }
        }
        else {
            try { $paths = Initialize-CostMedia $exe $cases }
            catch { Add-Result 'shader-cost' 'the clips are made' 'FAIL' $_.Exception.Message }
        }
        if ($paths) {
            $runs = [System.Collections.Generic.List[object]]::new()
            $warmSeconds = $null
            $aside = $false
            $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                try { Backup-AmdShaderCache }
                catch { throw "the AMD driver's shader cache could not be set aside ($($_.Exception.Message)) - close games and other programs that use the GPU, then run it again" }
                $aside = $true
                Write-Host "  the AMD driver's shader cache is set aside in $AmdBackup until this run ends" -ForegroundColor DarkGray
                for ($rep = 1; $rep -le $Repeat; $rep++) {
                    for ($i = 0; $i -lt $cases.Count; $i++) {
                        $cache = Join-Path $costDir "cache-cold-$rep-$i"
                        New-Item -ItemType Directory $cache | Out-Null
                        $cleared = $true
                        try { Clear-AmdShaderCache }
                        catch {
                            $cleared = $false
                            Add-Result 'shader-cost (cold)' "$($cases[$i].Label) (cold $rep): the AMD driver's cache emptied" 'FAIL' "$($_.Exception.Message) - a program that uses the GPU has it open; close it"
                        }
                        $run = Invoke-CostCase $exe $cases[$i] $paths[$i] 'cold' $rep $cache $costDir $i $overlay
                        if ($cleared -and $null -ne $run.AmdKB -and $run.AmdKB -le 0) {
                            Add-Result 'shader-cost (cold)' "$($cases[$i].Label) (cold $rep): the AMD driver compiled (its cache grew)" 'FAIL' 'it stayed empty, so the driver part was not cold - does it keep its cache somewhere else?'
                            $run.Valid = $false
                        }
                        if (-not $cleared) { $run.Valid = $false }
                        $runs.Add($run)
                        # the same video again, on what the cold run left in both caches
                        $runs.Add((Invoke-CostCase $exe $cases[$i] $paths[$i] 'again' $rep $cache $costDir $i $overlay))
                        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                # the warm-up as after an update: both caches empty
                Clear-AmdShaderCache
                Write-Host ''
                Write-Host '-- warm-up (full, both caches empty, hidden window)' -ForegroundColor White
                $warmCache = Join-Path $costDir 'cache-warmed'
                New-Item -ItemType Directory $warmCache | Out-Null
                $trouble = Get-GpuTrouble
                if ($trouble) { throw "stopped before the warm-up: $trouble" }
                $t = [System.Diagnostics.Stopwatch]::StartNew()
                $warm = & (Join-Path $RepoRoot 'installer/warm-shader-cache.ps1') -MpvExe $exe -CacheDir $warmCache -Quiet
                $warmSeconds = $t.Elapsed.TotalSeconds
                $warmFailed = $false
                foreach ($line in $warm) {
                    if ("$line" -match '^RESULT (PASS|FAIL|INFO) (.*?)(?: :: (.*))?$' -and ($Matches[1] -ne 'INFO' -or $Matches[2] -notmatch ': \d+ compiles$')) {
                        if ($Matches[1] -eq 'FAIL') { $warmFailed = $true }
                        Add-Result 'shader-cost warm-up' $Matches[2] $Matches[1] ($Matches[3] ?? '')
                    }
                }
                # A partly warmed cache would make the warm runs compile too, and understate what
                # an empty cache costs: no warm runs, and the verdict is INCOMPLETE.
                if ($warmFailed) { throw 'the warm-up failed: no warm runs, so no verdict' }
                $trouble = Get-GpuTrouble
                if ($trouble) { throw "stopped after the warm-up: $trouble" }
                for ($rep = 1; $rep -le $Repeat; $rep++) {
                    for ($i = 0; $i -lt $cases.Count; $i++) {
                        $cache = Join-Path $costDir "cache-warm-$rep-$i"
                        Copy-Item -LiteralPath $warmCache -Destination $cache -Recurse
                        $runs.Add((Invoke-CostCase $exe $cases[$i] $paths[$i] 'warm' $rep $cache $costDir $i $overlay))
                        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            catch {
                Add-Result 'shader-cost' 'the measurement ran through' 'FAIL' $_.Exception.Message
            }
            finally {
                if ($aside -and -not (Restore-AmdShaderCache $true)) {
                    Add-Result 'shader-cost' "the AMD driver's shader cache is back" 'FAIL' "it is still in $AmdBackup - see the red line above"
                }
            }

            $first = @($runs | Where-Object { $_.Data }) | Select-Object -First 1
            $d = $first ? $first.Data : $null
            $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" })
            $coldRuns = @($runs | Where-Object { $_.State -eq 'cold' })
            $grew = @($coldRuns | Where-Object { $null -ne $_.AmdKB -and $_.AmdKB -gt 0 })
            $header = @(
                ('{0}: {1} cases x {2} runs in each state, each run in a fresh mpv, fullscreen, the whole config ({3:n0} min)' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $cases.Count, $Repeat, $sw2.Elapsed.TotalMinutes),
                "mpv $(Get-CostValue $d 'mpv' '?'), libplacebo $(Get-CostValue $d 'libplacebo' '?'), display $(Get-CostValue $d 'display' '?')",
                "GPU: $($gpu -join '; ')",
                ("the AMD driver's own shader cache was set aside, emptied before every cold run and before the warm-up, and put back at the end; it grew in {0} of {1} cold runs (median {2:n0} KB){3}" -f $grew.Count, $coldRuns.Count,
                    (Get-Median @($grew | ForEach-Object { $_.AmdKB })),
                    (($coldRuns.Count -and $grew.Count -eq $coldRuns.Count) ? ' - the driver compiled in every one, so its part is in the cold numbers' : ' - a cold run in which it did not grow does not count')),
                (($null -ne $warmSeconds) ? ('the full warm-up with both caches empty took {0:n0} s' -f $warmSeconds) : 'the warm-up did not run'),
                ('{0} of {1} runs passed every check (wrong chain, an error, a driver cache that was not cold: such a run does not count)' -f @($runs | Where-Object Valid).Count, $runs.Count)
            )
            $report = Join-Path $WorkDir 'shader-cost.md'
            ConvertTo-Json -InputObject @($runs) -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkDir 'shader-cost.json') -Encoding utf8NoBOM
            $verdict = Write-CostReport $cases @($runs) $header $report
            Add-Result 'shader-cost' "verdict: $verdict - the report: $report" 'INFO'
        }
    }
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
$fail = @($script:Results | Where-Object Status -EQ 'FAIL')
$pass = @($script:Results | Where-Object Status -EQ 'PASS')
$skip = @($script:Results | Where-Object Status -EQ 'SKIP')
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped  ({3:n0} s, tier {4})' -f $pass.Count, $fail.Count, $skip.Count, $sw.Elapsed.TotalSeconds, $Tier) `
    -ForegroundColor ($fail.Count ? 'Red' : 'Green')
if ($fail.Count) {
    Write-Host 'Failed:' -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  [$($_.Test)] $($_.Check)  ::  $($_.Detail)" -ForegroundColor Red }
    Write-Host "Logs: $(Join-Path $WorkDir 'logs')" -ForegroundColor DarkGray
}
exit ($fail.Count ? 1 : 0)
