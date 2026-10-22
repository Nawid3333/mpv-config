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
                because you may be watching something, and while Windows reports
                a problem with a display adapter. The first lost GPU device
                (VK_ERROR_DEVICE_LOST) ends the tier: each further run would
                reset the GPU again.

    Isolation: tests never touch the real portable_config. They run a COPY of
    mpv.exe next to a COPY of portable_config in a temp folder (mpv's portable
    mode then resolves ~~/, ~~state/ and ~~cache/ inside that folder), so
    speed.json, stream-resume.json and the shader cache stay untouched. The
    gpu tier uses a copy of the real shader cache.

    Input: only mpv's own commands (keypress, keydown/keyup, mouse,
    script-message). Never OS-level keyboard/mouse injection.

.PARAMETER Tier
    static, headless (default) or gpu. `all` is the same as gpu.

.PARAMETER Filter
    Wildcard on test names, e.g. -Filter upscale or -Filter 'speed*'.

.PARAMETER MpvExe
    mpv.exe to test. Default: the one in this repo (updater.bat installs it;
    mpv.exe is not kept in git).

.PARAMETER WorkDir
    Scratch folder for the isolated copy, generated media and logs.

.PARAMETER ConfigDir
    portable_config to test. Default: this repo's. Point it at a copy to test
    an edit without touching the live config (or to check that the suite
    catches a deliberately broken one).

.EXAMPLE
    pwsh tests/run-tests.ps1
    pwsh tests/run-tests.ps1 -Tier gpu
    pwsh tests/run-tests.ps1 -Filter upscale
#>
[CmdletBinding()]
param(
    [ValidateSet('static', 'headless', 'gpu', 'all')]
    [string]$Tier = 'headless',
    [string]$Filter = '*',
    [string]$MpvExe,
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'mpv-regression'),
    [string]$ConfigDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Cfg = $ConfigDir ? (Resolve-Path $ConfigDir).Path : (Join-Path $RepoRoot 'portable_config')
$TestsDir = $PSScriptRoot
if (-not $MpvExe) { $MpvExe = Join-Path $RepoRoot 'mpv.exe' }
$RunHeadless = $Tier -ne 'static'
$RunGpu = $Tier -in @('gpu', 'all')

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
# Git LFS objects, FastStream's release and nodejs.org. Run in Windows PowerShell 5.1
# when it is there, as install.bat runs them: the stricter of the two shells they must
# work in (updater.bat prefers pwsh when it is installed; update.ps1 is run under pwsh
# below).
# ---------------------------------------------------------------------------
# A process named mpv, running from $Dir: a copy of ping (no mpv starts). Stop it with
# Close-StandInMpv.
function Open-StandInMpv([string]$Dir) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\PING.EXE') (Join-Path $Dir 'mpv.exe') -Force
    return Start-Process -FilePath (Join-Path $Dir 'mpv.exe') -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
}
function Close-StandInMpv($Process) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    $null = $Process.WaitForExit(5000)
}

function Invoke-OneClickCheck([string]$t) {
    $installer = Join-Path $RepoRoot 'installer'
    # every script Windows PowerShell 5.1 runs: it reads a UTF-8 file without a BOM
    # as ANSI, so one non-ASCII character in a string comes out garbled
    $nonAscii = @(Get-ChildItem (Join-Path $installer '*.ps1'), (Join-Path $RepoRoot 'mpv-single-*.ps1'), (Join-Path $RepoRoot '*.bat') | Where-Object {
            @([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count
        } | ForEach-Object Name)
    Test-Check $t 'installer scripts and .bat files are plain ASCII (Windows PowerShell 5.1, cmd)' ($nonAscii.Count -eq 0) ($nonAscii -join ', ')
    # a download that stalls halfway: PowerShell 7, which updater.bat uses when it is there,
    # waited for ever (measured 2026-10-10); $StallLimit gives it -OperationTimeoutSeconds
    # A call continued on the next line (a backtick at the end) counts as one: a check line by
    # line did not see such calls. A JSON reply (Invoke-RestMethod) stalls the same way: the
    # lookups of the newest release and commit had no limit (review of 2026-10-22).
    $noLimit = @(foreach ($f in 'install-faststream.ps1', 'install-mpv.ps1', 'setup.ps1', 'sync-config.ps1', 'update.ps1') {
            $lines = @(Get-Content -LiteralPath (Join-Path $installer $f))
            for ($i = 0; $i -lt $lines.Count; $i++) {
                # the name, then a space or the backtick that continues it on the next line
                if ($lines[$i] -notmatch 'Invoke-(WebRequest|RestMethod)\b') { continue }
                $call = $lines[$i]
                for ($j = $i; $j + 1 -lt $lines.Count -and $lines[$j] -match '`\s*$'; $j++) { $call += ' ' + $lines[$j + 1] }
                if (($call -match '-OutFile' -or $call -match 'Invoke-RestMethod') -and $call -notmatch '@StallLimit') { "$f`:$($i + 1)" }
            }
        })
    Test-Check $t 'every download and API reply updater.bat or the setup can run in PowerShell 7 ends when it stalls ($StallLimit)' ($noLimit.Count -eq 0) ($noLimit -join ', ')
    # A GPU run asks Test-GpuFit at its own start, never in a foreach's collection: that one
    # is read whole before the first run, and a lost device did not stop the next (AGENTS.md:
    # a device loss is reproduced at most once).
    $gpuAskedEarly = @(Select-String -LiteralPath $PSCommandPath -Pattern 'foreach\s*\([^)]*Test-GpuFit' | ForEach-Object LineNumber)
    Test-Check $t 'run-tests.ps1: every GPU run asks whether the GPU is fit at its own start' ($gpuAskedEarly.Count -eq 0) "line(s) $($gpuAskedEarly -join ', ')"
    # updater.bat while its update replaces it (git pull, sync-config), and install.bat run
    # from an installed folder while the setup syncs it: cmd reads a batch file by byte
    # offset, and went on in the new file at the old offset - pieces of lines run as commands,
    # the update again in a loop (2026-10-12). A stand-in for the script it runs rewrites a
    # copy with a longer header and exits 0, then 1: one run each, its exit code, no error line.
    $selfDir = Join-Path $WorkDir 'bat-self'
    $null = New-Item -ItemType Directory -Force (Join-Path $selfDir 'installer')
    $emptyIn = Join-Path $selfDir 'stdin.txt'
    Set-Content -LiteralPath $emptyIn '' -NoNewline
    foreach ($pair in @(@('updater.bat', 'update.ps1'), @('install.bat', 'setup.ps1'))) {
        $bat, $runner = $pair
        foreach ($code in 0, 1) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot $bat) -Destination (Join-Path $selfDir $bat) -Force
            Set-Content -LiteralPath (Join-Path $selfDir "installer/$runner") -NoNewline -Value (
                "`$bat = Join-Path (Split-Path `$PSScriptRoot -Parent) '$bat'; `$text = [IO.File]::ReadAllText(`$bat); " +
                '[IO.File]::WriteAllText($bat, "@echo off`r`n:: a longer header, as a new version could bring one, so that every later line moves`r`n" + ' +
                '$text.Substring($text.IndexOf("`r`n") + 2)); Write-Host ''script ran''; exit ' + $code)
            $selfOut = Join-Path $selfDir "out-$bat-$code.txt"
            $selfErr = Join-Path $selfDir "err-$bat-$code.txt"
            $p = Start-Process cmd.exe -ArgumentList "/d /c `"$(Join-Path $selfDir $bat)`"" -PassThru -WindowStyle Hidden `
                -RedirectStandardInput $emptyIn -RedirectStandardOutput $selfOut -RedirectStandardError $selfErr
            $done = $p.WaitForExit(60000)
            if (-not $done) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            $runs = @(Select-String -LiteralPath $selfOut -Pattern 'script ran').Count
            $errs = @(Get-Content -LiteralPath $selfErr | Where-Object { $_.Trim() })
            Test-Check $t "$bat survives $runner replacing it (exit $code)" (
                $done -and $p.ExitCode -eq $code -and $runs -eq 1 -and $errs.Count -eq 0) (
                "exit $(if ($done) { $p.ExitCode } else { 'timeout' }), ran $runs time(s), errors: $($errs -join ' | ')")
        }
    }
    # update.ps1 in a folder INSIDE another repository (glm's review, 2026-10-12): git says
    # "inside a work tree" there too, and git pull ran in the outer repository. -ConfigOnly:
    # step 1 only. The control: the repository's own top does pull (no remote: it fails).
    $outer = Join-Path $WorkDir ('update-outer-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Force (Join-Path $outer 'mpv')
    & git -C $outer init -q 2>$null
    $self = (Get-Process -Id $PID).Path
    $inner = (& $self -NoProfile -File (Join-Path $installer 'update.ps1') -Root (Join-Path $outer 'mpv') -ConfigOnly 2>&1 | Out-String)
    $top = (& $self -NoProfile -File (Join-Path $installer 'update.ps1') -Root $outer -ConfigOnly 2>&1 | Out-String)
    Test-Check $t 'update.ps1 does not git pull a repository the mpv folder only sits in' (
        $inner -match 'inside another git repository' -and $inner -notmatch 'git pull failed' -and $top -match 'git pull failed') (
        (($inner + ' | ' + $top) -replace '\s+', ' ').Trim())
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
    # "run it again to repair": an install file gone (an antivirus) comes back, a changed one stays
    Remove-Item -LiteralPath (Join-Path $root 'portable_config/mpv.conf')
    Set-Content -LiteralPath (Join-Path $root 'old/gone.lua') 'mine' -NoNewline
    $r = Invoke-Script sync-config.ps1 @('-Root', $root, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs)
    Test-Check $t '... the same commit with a file gone: it is put back, a file you changed stays as it is' (
        $r.Code -eq 0 -and (Read-Text (Join-Path $root 'portable_config/mpv.conf')) -eq 'v1' -and
        (Read-Text (Join-Path $root 'old/gone.lua')) -eq 'mine' -and
        @(Get-ChildItem (Join-Path $root 'old') -Filter 'gone.lua.mine-*').Count -eq 0) $r.Out
    Set-Content -LiteralPath (Join-Path $root 'old/gone.lua') 'gone' -NoNewline
    Set-Content -LiteralPath (Join-Path $root 'portable_config/input.conf') 'my keys' -NoNewline
    Set-Content -LiteralPath (Join-Path $root 'old2/edited.lua') 'my edit' -NoNewline
    Set-Content -LiteralPath (Join-Path $root 'portable_config/speed.json') '{"speed":3}' -NoNewline
    # an empty LFS source: the font is already installed, so nothing may be fetched
    $noLfs = Join-Path $ob 'lfs-empty'
    $null = New-Item -ItemType Directory -Force $noLfs
    $r = Invoke-Script sync-config.ps1 @('-Root', $root, '-Zip', $zip2, '-Commit', $c2, '-LfsSource', $noLfs)
    $mine = @(Get-ChildItem (Join-Path $root 'portable_config') -Filter 'input.conf.mine-*')
    Test-Check $t '... an update writes the new files' (
        $r.Code -eq 0 -and (Read-Manifest $root).commit -eq $c2 -and (Read-Text (Join-Path $root 'portable_config/mpv.conf')) -eq 'v2') $r.Out
    Test-Check $t '... a Git LFS file already installed is not downloaded again' ($r.Code -eq 0 -and $r.Out -match '\(0 downloaded\)') $r.Out
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
    # a folder with a space, given with a trailing backslash (tab completion adds one): the
    # child scripts got -Root "...\new folder\" and the \" swallowed every argument after it.
    # Its name has a letter outside ASCII too (u umlaut), as a Windows account's can.
    $srSpace = Join-Path $ob ('new folder ' + [char]0xFC)
    $r = Invoke-Script setup.ps1 @('-InstallDir', "$srSpace\", '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs,
        '-NoMpv', '-NoFastStream', '-NoFileTypes', '-NoShortcuts', '-Yes')
    Test-Check $t '... and into a folder with a space, given with a trailing backslash' (
        $r.Code -eq 0 -and (Read-Manifest $srSpace).commit -eq $c1) $r.Out
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
        # the fork's install.ps1, standing in: it records what it was given, and writes a
        # line to stderr as a warning does - which ended Windows PowerShell 5.1's install
        # under 'Stop' until 2026-10-09 (installer\*.ps1 Invoke-Native)
        $hs = Join-Path $ob 'helper-src'
        Write-TestTree $hs @{
            'faststream-mpv-host.mjs' = '// stand-in'
            'install.ps1'             = 'param([string]$MpvPath, [string]$NodePath, [string]$InstallDir, [switch]$NoRegister)
[Console]::Error.WriteLine("a note on stderr")
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot "faststream-mpv-host.mjs") (Join-Path $InstallDir "faststream-mpv-host.mjs")
Set-Content (Join-Path $InstallDir "com.faststream.mpv.bat") "@echo off"
Set-Content (Join-Path $InstallDir "com.faststream.mpv.json") "{}"
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
        Test-Check $t '... again: the helper is up to date, nothing downloaded' (
            $r.Code -eq 0 -and $r.Out -match 'helper is up to date' -and $r.Out -match "Node\.js for the helper: $([regex]::Escape($nv)) is up to date" -and
            $r.Out -notmatch 'Downloading') $r.Out
        Remove-Item -LiteralPath (Join-Path $hd 'faststream-mpv-host.mjs')
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hd) + $common)
        Test-Check $t '... a helper file gone (an antivirus): installed again, not "up to date"' (
            $r.Code -eq 0 -and $r.Out -notmatch 'helper is up to date' -and (Test-Path (Join-Path $hd 'faststream-mpv-host.mjs'))) $r.Out
        $other = Join-Path $ob 'other/mpv.exe'
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $other, '-HelperDir', $hd, '-HelperOnly', '-Yes') + $common)
        $cfg = Get-Content -Raw (Join-Path $hd 'config.json') | ConvertFrom-Json
        Test-Check $t '... the updater of ANOTHER mpv folder leaves it alone' ($r.Code -eq 0 -and $cfg.mpvPath -eq $mpvStandIn) $r.Out
        # an mpv folder with a letter outside ASCII (a Windows account named with an umlaut): Windows
        # PowerShell 5.1 read the marker, UTF-8 without a BOM, as ANSI - the helper was never
        # up to date, its own folder's updater left it alone, and uninstall kept it
        $mpvUml = Join-Path $srSpace 'mpv.exe'
        Write-TestTree $srSpace @{ 'mpv.exe' = 'stand-in' }
        $hdu = Join-Path $ob 'helper-umlaut'
        $null = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvUml, '-HelperDir', $hdu) + $common)
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvUml, '-HelperDir', $hdu, '-HelperOnly', '-Yes') + $common)
        Test-Check $t '... an mpv folder with a letter outside ASCII: its updater finds the helper up to date' (
            $r.Code -eq 0 -and $r.Out -match 'up to date') $r.Out
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
        # a newer LTS release: the helper's Node.js follows it, the helper itself up to date
        # (issue #96: any node.exe from 22 on was kept for good, no security release reached it)
        $nv2 = 'v99.0.1'; $nn2 = "node-$nv2-win-x64"
        $nz2 = Join-Path $ob 'nodezip2'
        New-Item -ItemType Directory -Force (Join-Path $nz2 $nn2), (Join-Path $dist $nv2) | Out-Null
        Copy-Item $nodeExe (Join-Path $nz2 "$nn2/node.exe")
        [IO.Compression.ZipFile]::CreateFromDirectory($nz2, (Join-Path $dist "$nv2/$nn2.zip"))
        $nodeSha2 = (Get-FileHash (Join-Path $dist "$nv2/$nn2.zip") -Algorithm SHA256).Hash.ToLower()
        Set-Content (Join-Path $dist "$nv2/SHASUMS256.txt") "$nodeSha2  $nn2.zip"
        Set-Content (Join-Path $dist 'index.json') (@(
                @{ version = $nv2; lts = 'Stand-in'; files = @('win-x64-zip', 'win-x64-msi') },
                @{ version = $nv; lts = 'Stand-in'; files = @('win-x64-zip', 'win-x64-msi') }) | ConvertTo-Json -Depth 3)
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hd) + $common)
        Test-Check $t '... a newer Node.js LTS replaces the helper''s own, the helper up to date' (
            $r.Code -eq 0 -and $r.Out -match "Downloading Node\.js $([regex]::Escape($nv2))" -and
            (Read-Text (Join-Path $hd 'node\node-version.txt')) -eq $nv2 -and (Test-Path $privateNode)) $r.Out
        # nodejs.org out of reach: the one there stays, and the update does not fail for it
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hd, '-NoRegister', '-NoFirefox',
                '-UpdatesJson', $updatesJson, '-HelperSource', $hs, '-NodeDist', (Join-Path $ob 'no-such-nodedist')))
        Test-Check $t '... nodejs.org out of reach keeps the helper''s Node.js, and the run succeeds' (
            $r.Code -eq 0 -and $r.Out -match 'could not be asked' -and (Test-Path $privateNode)) $r.Out

        # The helper's files run only as the release lists them (native-host.sha256): from the
        # tag, whatever answered there ran - a moved tag, a changed or broken download.
        $sha = { param($p) (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
        $goodSums = Join-Path $ob 'native-host.sha256'
        Set-Content $goodSums ("{0}  install.ps1`n{1}  faststream-mpv-host.mjs" -f (& $sha (Join-Path $hs 'install.ps1')), (& $sha (Join-Path $hs 'faststream-mpv-host.mjs')))
        $badSums = Join-Path $ob 'native-host-bad.sha256'
        Set-Content $badSums ("{0}  install.ps1`n{1}  faststream-mpv-host.mjs" -f ('0' * 64), (& $sha (Join-Path $hs 'faststream-mpv-host.mjs')))
        $hdSums = Join-Path $ob 'helper-sums'
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hdSums, '-HelperSums', $goodSums) + $common)
        Test-Check $t 'install-faststream.ps1 installs helper files that match the release''s native-host.sha256' (
            $r.Code -eq 0 -and (Test-Path (Join-Path $hdSums 'config.json'))) $r.Out
        $hdBad = Join-Path $ob 'helper-badsums'
        $r = Invoke-Script install-faststream.ps1 (@('-MpvExe', $mpvStandIn, '-HelperDir', $hdBad, '-HelperSums', $badSums) + $common)
        Test-Check $t '... and refuses one that does not, before running anything of it' (
            $r.Code -ne 0 -and $r.Out -match 'install\.ps1 is not the one FastStream 9\.9\.9 released' -and -not (Test-Path (Join-Path $hdBad 'config.json'))) $r.Out
        $installerText = Get-Content -Raw (Join-Path $installer 'install-faststream.ps1')
        Test-Check $t '... and downloads always check them against the release''s own list' (
            $installerText.Contains('"https://github.com/$Repo/releases/download/v$version/native-host.sha256"') -and
            $installerText -match 'elseif \(-not \$HelperSource\)')

        # node.exe's SHA-256 comes from a list nodejs.org serves the same way: it must also be
        # signed by the OpenJS Foundation (one byte changed: the signature no longer holds).
        $distBad = Join-Path $ob 'nodedist-bad'
        $nzBad = Join-Path $ob 'nodezip-bad'
        New-Item -ItemType Directory -Force (Join-Path $nzBad $nn), (Join-Path $distBad $nv) | Out-Null
        $bytes = [IO.File]::ReadAllBytes($nodeExe)
        $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
        [IO.File]::WriteAllBytes((Join-Path $nzBad "$nn/node.exe"), $bytes)
        [IO.Compression.ZipFile]::CreateFromDirectory($nzBad, (Join-Path $distBad "$nv/$nn.zip"))
        Set-Content (Join-Path $distBad "$nv/SHASUMS256.txt") "$((Get-FileHash (Join-Path $distBad "$nv/$nn.zip") -Algorithm SHA256).Hash.ToLower())  $nn.zip"
        Set-Content (Join-Path $distBad 'index.json') (@(@{ version = $nv; lts = 'Stand-in'; files = @('win-x64-zip') }) | ConvertTo-Json -Depth 3)
        $hdNode = Join-Path $ob 'helper-badnode'
        $r = Invoke-Script install-faststream.ps1 @('-MpvExe', $mpvStandIn, '-HelperDir', $hdNode, '-NoRegister', '-NoFirefox',
            '-UpdatesJson', $updatesJson, '-HelperSource', $hs, '-NodeDist', $distBad)
        Test-Check $t 'install-faststream.ps1 refuses a node.exe the OpenJS Foundation did not sign, and installs no helper' (
            $r.Code -ne 0 -and $r.Out -match 'not signed by the OpenJS Foundation' -and -not (Test-Path (Join-Path $hdNode 'node\node.exe')) -and
            -not (Test-Path (Join-Path $hdNode 'config.json'))) $r.Out

        # -- uninstall.ps1 (the folder itself stays: -KeepFolder) -----------------------------------
        $marker = @{ version = '9.9.9'; mpv = (Join-Path $sr 'mpv.exe') } | ConvertTo-Json
        $ours = Join-Path $ob 'helper-ours'
        Write-TestTree $ours @{ 'installed-by-mpv-config.json' = $marker; 'config.json' = '{}' }
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', $ours)
        Test-Check $t 'uninstall.ps1 removes the FastStream helper the setup installed for this mpv' ($r.Code -eq 0 -and -not (Test-Path $ours)) $r.Out
        # Firefox keeps the helper's node.exe running: a running program cannot be deleted, and
        # the uninstall broke off with the folder half gone (a copy of ping stands in for node)
        $busy = Join-Path $ob 'helper-busy'
        Write-TestTree $busy @{ 'installed-by-mpv-config.json' = $marker; 'config.json' = '{}' }
        New-Item -ItemType Directory -Force (Join-Path $busy 'node') | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\PING.EXE') (Join-Path $busy 'node\node.exe') -Force
        $node = Start-Process -FilePath (Join-Path $busy 'node\node.exe') -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
        try {
            $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', $busy)
            Test-Check $t '... also while its node.exe runs (it is stopped first)' ($r.Code -eq 0 -and -not (Test-Path $busy) -and $node.HasExited) $r.Out
        }
        finally {
            Stop-Process -Id $node.Id -Force -ErrorAction SilentlyContinue
        }
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', $hd)
        Test-Check $t '... but not one set up for another mpv folder' ($r.Code -eq 0 -and (Test-Path (Join-Path $hd 'config.json'))) $r.Out
        $r = Invoke-Script uninstall.ps1 @('-Root', $srSpace, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', $hdu)
        Test-Check $t '... and removes it for a folder with a letter outside ASCII' ($r.Code -eq 0 -and -not (Test-Path $hdu)) $r.Out

        # -- the Start menu (folders of the test's own, never the real one): the entries
        # setup.ps1 made go, and the folder only once nothing else is in it; it took the whole
        # folder, with anything the user had put there (review of 2026-10-14)
        $wsh = New-Object -ComObject WScript.Shell
        $newLink = {
            param([string]$Dir, [string]$Name, [string]$Target)
            $null = New-Item -ItemType Directory -Force $Dir
            $link = $wsh.CreateShortcut((Join-Path $Dir "$Name.lnk"))
            $link.TargetPath = $Target
            $link.Save()
        }
        $menuMine = Join-Path $ob 'menu-with-mine'
        & $newLink $menuMine 'mpv' (Join-Path $sr 'mpv.exe')
        & $newLink $menuMine 'Update mpv' (Join-Path $sr 'updater.bat')
        & $newLink $menuMine 'My notes' (Join-Path $env:WINDIR 'notepad.exe')
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', (Join-Path $ob 'no-helper'), '-MenuDir', $menuMine)
        Test-Check $t "uninstall.ps1 removes this mpv's Start menu entries and keeps the user's own" (
            $r.Code -eq 0 -and -not (Test-Path (Join-Path $menuMine 'mpv.lnk')) -and
            -not (Test-Path (Join-Path $menuMine 'Update mpv.lnk')) -and (Test-Path (Join-Path $menuMine 'My notes.lnk'))) $r.Out
        $menuOurs = Join-Path $ob 'menu-ours'
        foreach ($name in 'mpv', 'Update mpv', 'Uninstall mpv') { & $newLink $menuOurs $name (Join-Path $sr 'mpv.exe') }
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', (Join-Path $ob 'no-helper'), '-MenuDir', $menuOurs)
        Test-Check $t '... and the folder, once only its own entries were in it' ($r.Code -eq 0 -and -not (Test-Path $menuOurs)) $r.Out
    }
    # "Open with" another mpv registered (2026-10-09: the owner's Program Files mpv, for the
    # whole PC) - a stand-in key under HKCU, never a real App Paths entry
    $appKey = 'HKCU:\Software\mpv-config-tests\AppPaths-mpv.exe'
    $null = New-Item -Path $appKey -Force
    Set-ItemProperty -Path $appKey -Name '(default)' -Value (Join-Path $env:WINDIR 'System32\cmd.exe')
    try {
        $sr2 = Join-Path $ob 'installed2'
        $r = Invoke-Script setup.ps1 @('-InstallDir', $sr2, '-Zip', $zip1, '-Commit', $c1, '-LfsSource', $lfs,
            '-NoMpv', '-NoFastStream', '-NoShortcuts', '-Yes', '-AppPathsKeys', $appKey)
        Test-Check $t 'setup.ps1 leaves Open with to another mpv that is registered' ($r.Code -eq 0 -and $r.Out -match 'Another mpv is registered') $r.Out
        $r = Invoke-Script uninstall.ps1 @('-Root', $sr2, '-Yes', '-KeepFolder', '-AppPathsKey', $appKey)
        Test-Check $t "uninstall.ps1 does not unregister another mpv's Open with" (
            $r.Code -eq 0 -and $r.Out -match 'belong to another mpv' -and
            (Get-ItemPropertyValue $appKey '(default)') -like '*cmd.exe') $r.Out
    }
    finally {
        Remove-Item -Path 'HKCU:\Software\mpv-config-tests' -Recurse -Force -ErrorAction SilentlyContinue
    }
    $r = Invoke-Script uninstall.ps1 @('-Root', $clone, '-Yes', '-KeepFolder', '-NoFileTypes')
    Test-Check $t 'uninstall.ps1 refuses a git clone' ($r.Code -eq 1 -and $r.Out -match 'git clone' -and (Test-Path $clone)) $r.Out
    $r = Invoke-Script uninstall.ps1 @('-Root', $foreign, '-Yes', '-KeepFolder', '-NoFileTypes')
    Test-Check $t '... and a folder the setup did not install' ($r.Code -eq 1 -and $r.Out -match 'not installed by the setup' -and (Test-Path $foreign)) $r.Out
    # an mpv running from another folder whose name starts the same (installed-old for
    # installed) is not this folder's: it blocked the update and the uninstall
    $other = Open-StandInMpv "$sr-old"
    try {
        # an update with something to write (the up-to-date check comes before the mpv one)
        $rs = Invoke-Script sync-config.ps1 @('-Root', $sr, '-Zip', $zip2, '-Commit', $c2, '-LfsSource', $noLfs)
        $ru = Invoke-Script uninstall.ps1 @('-Root', $sr, '-Yes', '-KeepFolder', '-NoFileTypes', '-HelperDir', (Join-Path $ob 'no-helper'))
    }
    finally { Close-StandInMpv $other }
    Test-Check $t 'sync-config.ps1 runs while an mpv from another folder whose name starts the same runs' ($rs.Code -eq 0) $rs.Out
    Test-Check $t '... and so does uninstall.ps1' ($ru.Code -eq 0) $ru.Out
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

    # -- the FastStream fragment is read in one place (issue #96) -----------------------------
    # script-modules/faststream-fragment.lua holds the contract (whole items after the first
    # '#', the last of a name counting); six copies of its loop had to change alike.
    # A search for a tag's text (find('fs-...')) is a parser too: source-info's failure banner
    # had one, which the gmatch pattern alone did not see (review of 2026-10-14).
    # Any of Lua's searches (find, match, gmatch, gsub), in either spelling of the tag: a Lua
    # pattern writes fs%-page, which the check for 'fs-' alone did not see. Not one anchored
    # at the start ('^fs%-'): that checks one item the module already split (source-info).
    $fsSearch = "(find|match|gmatch|gsub)\(\s*['""](?!\^)[^'""]*fs(%-|-)"
    $guardSees = @(@("path:find('fs-page=')", "path:find('#fs-id=')", "path:find('fs%-page=')", "url:match('[#&]fs%-id=([^&]+)')",
            "s:gsub('fs%-content=%a+', '')", "u:gmatch('fs%-quality=([^&]*)')") | Where-Object { $_ -match $fsSearch })
    $guardLeaves = @(@("item:find('^fs%-')", "fragment.value(path, 'fs-content=')") | Where-Object { $_ -match $fsSearch })
    Test-Check $t "the fragment guard sees every spelling of a search for a tag ($($guardSees.Count) of 6), and not an item's own check" (
        $guardSees.Count -eq 6 -and $guardLeaves.Count -eq 0) ($guardLeaves -join ', ')
    $ownParsers = @(foreach ($f in $ownLua) {
            Select-String -LiteralPath $f.FullName -SimpleMatch -Pattern ".. '&'):gmatch(" | ForEach-Object { "$($f.Name):$($_.LineNumber)" }
            Select-String -LiteralPath $f.FullName -Pattern $fsSearch | ForEach-Object { "$($f.Name):$($_.LineNumber)" }
        })
    Test-Check $t 'no script reads the FastStream fragment by itself (script-modules/faststream-fragment.lua)' ($ownParsers.Count -eq 0) ($ownParsers -join ', ')

    # -- utils.subprocess(_detached) takes { args = {...} } ------------------
    # mpv's subprocess_detached is `mp.commandv("run", unpack(t.args))`: a bare array
    # threw, and source-info's "Open in browser" opened nothing from 2026-10-02 (#20) to
    # 2026-10-10. Its tests run with source_info-launch=no, so only this line sees it.
    $bareArgs = @()
    foreach ($f in $ownLua) {
        $i = 0
        foreach ($line in Get-Content $f.FullName) {
            $i++
            if ($line -notmatch '^\s*--' -and $line -match 'utils\.subprocess(_detached)?\s*\(' -and $line -notmatch 'utils\.subprocess(_detached)?\s*\(\s*\{\s*args\s*=') { $bareArgs += "$($f.Name):$i" }
        }
    }
    Test-Check $t 'utils.subprocess(_detached) is called with { args = ... }' ($bareArgs.Count -eq 0) ($bareArgs -join ', ')
    $osdMsg = @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s]+\s+osd-msg\s' })
    Test-Check $t 'input.conf: no binding forces mpv OSD text (osd-msg)' ($osdMsg.Count -eq 0) ($osdMsg -join ' | ')
    $osdStyle = @(@('profile=osd-box', 'osd-align-x=right', 'osd-align-y=top') | Where-Object { $_ -notin $mpvConf })
    Test-Check $t 'mpv.conf styles mpv OSD text like the banners (osd-box, top right)' ($osdStyle.Count -eq 0) ($osdStyle -join ', ')
    Test-Check $t 'uosc.conf: adjust_osd_margins=no (notify.lua places mpv OSD text)' ($uoscConf -match '(?m)^adjust_osd_margins=no\s*$')

    # -- shader presets: files exist, match their source, and nothing is orphaned --
    $toggles = Get-Content -Raw (Join-Path $Cfg 'Scripts/gpu-toggles.lua')
    $named = @([regex]::Matches($toggles, "'([\w.-]+\.glsl)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $shaderDir = Join-Path $Cfg 'shaders'
    $absent = @($named | Where-Object { -not (Test-Path (Join-Path $shaderDir $_)) })
    Test-Check $t "every shader gpu-toggles.lua names exists ($($named.Count) files)" ($absent.Count -eq 0) ($absent -join ', ')
    # The committed shaders are the only copy (no installer fetches them again): a changed byte
    # shows against the SHA-256 the notices list with each one's source.
    $notices = Get-Content -Raw (Join-Path $RepoRoot 'THIRD-PARTY-NOTICES.md')
    $listed = @{}
    foreach ($m in [regex]::Matches($notices, '(?m)^\| `([\w.-]+\.glsl)` \|.*\| `([0-9a-f]{64})` \|\s*$')) { $listed[$m.Groups[1].Value] = $m.Groups[2].Value }
    $shaderNames = @(Get-ChildItem $shaderDir -Filter *.glsl | ForEach-Object Name)
    $hashBad = @($shaderNames | Where-Object { $listed[$_] -ne (Get-FileHash -LiteralPath (Join-Path $shaderDir $_) -Algorithm SHA256).Hash.ToLowerInvariant() }) +
        @($listed.Keys | Where-Object { $_ -notin $shaderNames } | ForEach-Object { "$_ (listed, no such file)" })
    Test-Check $t "THIRD-PARTY-NOTICES.md names every shader's source and SHA-256, and each file matches ($($listed.Count) rows)" ($hashBad.Count -eq 0) ($hashBad -join ', ')
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
        # a bare flag (save-position-on-quit) has no "=": under strict mode [1] threw, and
        # the whole suite stopped with no result
        $parts = @($l -split '=', 2)
        if ($section) { $profiles[$section] += $key } else { $global[$key] = if ($parts.Count -gt 1) { $parts[1] } else { 'yes' } }
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
    # yt-dlp's only default JS runtime is Deno: without this, YouTube links lose their formats once it goes
    Test-Check $t 'mpv.conf: yt-dlp may solve YouTube''s challenges with Node.js (ytdl-raw-options js-runtimes=node)' (
        $global['ytdl-raw-options-append'] -eq 'js-runtimes=node') "ytdl-raw-options-append=$($global['ytdl-raw-options-append'])"
    # auto_profiles off (its load-and-unload raced the first hooks: config-load's CI flake),
    # which only works while no profile has a condition
    $conds = @($mpvConf | Where-Object { $_ -match '^\s*profile-cond\s*=' })
    Test-Check $t 'mpv.conf: load-auto-profiles=no, and no profile-cond it would silently ignore' (
        $global['load-auto-profiles'] -eq 'no' -and $conds.Count -eq 0) "load-auto-profiles=$($global['load-auto-profiles']); profile-cond lines: $($conds.Count)"
    # Snap Layouts and snap-on-drag need the system caption (WM_NCHITTEST ->
    # HTCAPTION/HTMAXBUTTON); with border=no mpv answers only edges and client area.
    Test-Check $t 'mpv.conf: native title bar (border=yes, title-bar not off)' (
        $global['border'] -eq 'yes' -and $global['title-bar'] -ne 'no')
    # Options each profile may set. A profile swallowing anything else is how
    # the 2026-09-21 bug happened (cache/buffer options scoped to FastStream
    # only). Adding a profile or an option to one: extend this list on purpose.
    # (none since 2026-10-09: [hdr-target-peak] became Scripts/settings.lua's HDR brightness)
    $profileAllow = @{}
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
    # uosc takes a menu title part starting with --- as a separator only when it is all it
    # says: "Video > Shaders (phase 3, ...) ---" was a greyed-out menu item with that text
    # (2026-10-10). Every part of every #! title that has --- in it must be just ---.
    $menuParts = @(($inputConf -split "`n") | Where-Object { $_ -match '#!\s*(.*)$' } | ForEach-Object {
            ($_ -replace '^.*?#!\s*', '') -split '\s*>\s*' })
    $badSeparators = @($menuParts | Where-Object { $_ -match '---' -and $_.Trim() -ne '---' })
    Test-Check $t "input.conf: every menu separator is a plain --- ($(@($menuParts | Where-Object { $_.Trim() -eq '---' }).Count))" (
        $badSeparators.Count -eq 0) ($badSeparators -join ' | ')
    $seekLines = @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s]+\s+(osd-\w+\s+)?seek\b' })
    Test-Check $t 'input.conf: every seek binding is no-osd' ($seekLines.Count -eq 0) ($seekLines -join ' | ')
    # every seek key is an instant keyframe seek (2026-10-09, the user: "make it instant ... I can
    # live with it when it is not exact"); absolute seeks are exact unless they say keyframes
    $seekKeys = @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s]+\s+no-osd\s+seek\s' })
    # and shows where it landed: the timeline for 2.5 s (the owner, 2026-10-21), the same on every key
    $unflashed = @($seekKeys | Where-Object { $_ -notmatch ';\s*script-message-to uosc flash-elements timeline 2500(\s|$)' })
    Test-Check $t "input.conf: every seek key shows the timeline for 2.5 s ($($seekKeys.Count) keys)" (
        $seekKeys.Count -ge 16 -and $unflashed.Count -eq 0) ($unflashed -join ' | ')
    $exactKeys = @($seekKeys | Where-Object { $_ -match '\bexact\b' -or ($_ -match '\babsolute' -and $_ -notmatch '\+keyframes\b') })
    Test-Check $t "input.conf: every seek key is an instant keyframe seek ($($seekKeys.Count) keys)" (
        $seekKeys.Count -ge 16 -and $exactKeys.Count -eq 0) ($exactKeys -join ' | ')
    Test-Check $t 'uosc.conf: the timeline wheel seeks by keyframe (timeline_step without !)' ($uoscConf -match '(?m)^timeline_step=\d+\s*$')
    Test-Check $t 'input.conf: mbtn_left = play/pause' ($inputConf -match '(?m)^mbtn_left\s+cycle pause')
    Test-Check $t 'input.conf: mbtn_left_dbl = fullscreen' ($inputConf -match '(?m)^mbtn_left_dbl\s+cycle fullscreen')
    # mpv's own keys are off: input.conf binds every key that works, the window's close
    # button (CLOSE_WIN) and the quit keys too - without them the window would not close
    Test-Check $t "mpv.conf: input-default-bindings=no (only input.conf's keys)" (@($mpvConf | Where-Object { $_ -match '^\s*input-default-bindings\s*=\s*no\s*$' }).Count -eq 1)
    # -cmatch: a one-letter key is case-sensitive (q is the 3x key; Q, Caps Lock's q, is unbound)
    # (pairs, not a hashtable: its keys ignore case, and Q and q are two keys)
    $mustBind = @(@('CLOSE_WIN', 'quit'), @('Ctrl+w', 'quit'), @('Ctrl+c', 'quit 4'), @('Ctrl+q', 'quit-watch-later'),
        @('q', 'script-binding speed_presets/preset 3'))
    $unbound = @($mustBind | Where-Object { $inputConf -cnotmatch "(?m)^$([regex]::Escape($_[0]))\s+$([regex]::Escape($_[1]))\s*(#|$)" } |
            ForEach-Object { $_[0] })
    Test-Check $t "input.conf: the close button and quit keys quit, q stays the 3x key ($($mustBind.Count) keys)" ($unbound.Count -eq 0) ($unbound -join ', ')
    # A key bound twice does what its later line says: mpv compares a one-letter key with its
    # case (q, Q) and a named key or modifier without it (ESC = esc, Ctrl+w = ctrl+w); Shift
    # with a letter is that letter's capital (Shift+A = A, Shift+q = Q).
    $normKey = {
        param([string]$Key)
        $null = $Key -match '^((?i:(shift|ctrl|alt|meta)\+)*)(.+)$'
        $mods, $name = $Matches[1].ToLowerInvariant(), $Matches[3]
        if ($name.Length -eq 1) {
            if ($mods -match 'shift\+') { $mods = $mods -replace 'shift\+'; if ($name -cmatch '^[a-z]$') { $name = $name.ToUpperInvariant() } }
        } else { $name = $name.ToLowerInvariant() }
        # one order for the modifiers: Ctrl+Alt+x = Alt+Ctrl+x
        (@($mods -split '\+' | Where-Object { $_ } | Sort-Object) + $name) -join '+'
    }
    # key -> command (its trailing comment and repeated spaces dropped)
    $keyNames = @()
    $binds = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s]' })) {
        $key, $cmd = $line.Trim() -split '\s+', 2
        $name = & $normKey $key
        $keyNames += $name
        $binds[$name] = (($cmd -replace '\s+#.*$') -replace '\s+', ' ').Trim()
    }
    $twice = @($keyNames | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object Name)
    Test-Check $t "input.conf: no key is bound twice ($($keyNames.Count) keys)" ($twice.Count -eq 0) ($twice -join ', ')
    # Caps Lock + q (the 3x key) arrives as Q: bound to mpv's quit-and-save it quit the player
    Test-Check $t 'input.conf: Q is unbound (Caps Lock + q must not quit)' (-not $binds.ContainsKey('Q'))

    # -- uosc: config + the local changes that an update would drop --------------
    Test-Check $t 'uosc.conf: animation_duration=0 (the controls appear at once, no fades)' ($uoscConf -match '(?m)^animation_duration=0\s*$')
    # The pause indicator fades over 300 ms hard-coded in uosc: manual shows it only on
    # uosc's flash-pause-indicator command, and nothing sends that (his pick, 2026-10-14).
    $flashKeys = @(($inputConf -split "`n") | Where-Object { $_ -match '^\s*[^#\s].*flash-pause-indicator' })
    Test-Check $t 'uosc.conf: pause_indicator=manual and no key flashes it (no pause flash)' (
        $uoscConf -match '(?m)^pause_indicator=manual\s*$' -and $flashKeys.Count -eq 0) ($flashKeys -join ' | ')
    Test-Check $t 'uosc.conf: proximity 10000/10100 (whole UI shows together)' (
        $uoscConf -match '(?m)^proximity_in=10000' -and $uoscConf -match '(?m)^proximity_out=10100')
    foreach ($b in 'button:speed', 'button:upscale', 'button:subtitle_sync', 'button:source', 'button:settings',
        'button:episode_prev', 'button:episode_next', 'button:autoplay') {
        Test-Check $t "uosc.conf: controls has $b" ($uoscConf -match "(?m)^controls=.*\b$([regex]::Escape($b))\b")
    }
    # the episode buttons and the gap after them wait for faststream-episodes.lua's flag: without
    # it uosc draws an unpushed managed button as a question mark, and the gap stays (2026-10-11)
    $episodeShown = '<user-data/faststream-episodes/shown>'
    Test-Check $t 'uosc.conf: the episode buttons and their gap show only with user-data/faststream-episodes/shown' (
        $uoscConf -match "(?m)^controls=.*,$([regex]::Escape(($episodeShown + 'button:episode_prev,' + $episodeShown + 'button:episode_next,' +
            $episodeShown + 'button:autoplay,' + $episodeShown + 'gap,')))")
    # one Quality button (faststream-quality.lua): uosc's own stream-quality button stays out
    # (a second, dead one), and Editions hides while the editions are a stream's variants
    $controlsLine = [regex]::Match($uoscConf, '(?m)^controls=(.*)$').Groups[1].Value
    Test-Check $t 'uosc.conf: one Quality button (faststream_quality behind its flag, no stream-quality, Editions behind the editions flag)' (
        $controlsLine.Contains('<user-data/faststream-quality/shown>button:faststream_quality,') -and
        $controlsLine.Contains(',<!user-data/faststream-quality/editions>editions,') -and
        @($controlsLine -split ',' | Where-Object { $_ -match 'stream-quality$' }).Count -eq 0) $controlsLine
    $localChanges = @{
        'elements/Button.lua'        = 'Local change'
        'elements/ManagedButton.lua' = 'Local change'
        'elements/Timeline.lua'      = 'Local change'
        'main.lua'                   = 'Local change'
        'lib/buttons.lua'            = 'menu_command'
    }
    $uoscMain = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/main.lua')
    Test-Check $t 'uosc local change present: main.lua publishes user-data/uosc/bottom-ui (music-info.lua, subtitle-sync.lua)' (
        $uoscMain.Contains("'user-data/uosc/bottom-ui'") -and $uoscMain.Contains('volume = volume_box') -and
        $uoscMain.Contains('Also with both gone (disable-elements') -and -not $uoscMain.Contains('if controls or timeline then')) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: main.lua publishes user-data/uosc/ui-scale (notify, subtitle-sync, music-info)' (
        $uoscMain.Contains("'user-data/uosc/ui-scale'")) 're-apply it after a uosc update (AGENTS.md)'
    # uosc's macOS and Linux ziggy: 11.8 MB of LFS that every install and update fetched for a
    # Windows-only setup, and a uosc update brings them back
    $ziggy = @(Get-ChildItem -Force (Join-Path $Cfg 'Scripts/uosc/bin') | ForEach-Object Name)
    Test-Check $t 'uosc local change present: bin/ holds only ziggy-windows.exe' (($ziggy -join ',') -eq 'ziggy-windows.exe') "$($ziggy -join ', ') - re-apply it after a uosc update (AGENTS.md)"
    # without it the seek keys' 2500 is dropped and the timeline flashes for flash_duration (1 s)
    $uoscElement = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/elements/Element.lua')
    $uoscElements = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/elements/Elements.lua')
    Test-Check $t 'uosc local change present: flash-elements takes a duration (the seek keys'' 2.5 s timeline)' (
        $uoscMain.Contains('Elements:flash(comma_split(elements), tonumber(duration))') -and
        $uoscElements.Contains('element:flash(duration)') -and
        $uoscElement.Contains('duration = duration or options.flash_duration') -and
        $uoscElement.Contains('self._flash_out_timer.timeout = duration / 1000')) 're-apply it after a uosc update (AGENTS.md)'
    $uoscCursor = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/lib/cursor.lua')
    Test-Check $t 'uosc local change present: cursor.lua shows nothing for a pointer back over the window at the same pixel' (
        $uoscCursor.Contains('cursor.last_hover == false and mouse.hover and same_pixel')) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: cursor.lua hides the UI with the pointer resting on it (autohide_over_controls)' (
        $uoscCursor.Contains('self.is_dragging_prevented and options.autohide_over_controls <= 0') -and
        $uoscCursor.Contains('not self:is_primary_held()') -and $uoscMain.Contains('autohide_over_controls = 0,') -and
        $uoscConf -match '(?m)^autohide_over_controls=3000\s*$') 're-apply it after a uosc update (AGENTS.md)'
    # the feature tour names the keys input.conf binds, with the same command (settings.lua's
    # Welcome menu, 2026-10-09)
    $welcomeLua = Get-Content -Raw (Join-Path $Cfg 'Scripts/settings.lua')
    $tourRuns = @([regex]::Matches($welcomeLua, "run\(\s*'[^']*',\s*'([^']+)',\s*'([^']+)'\s*\)"))
    $tourBad = @()
    $tourKeys = 0
    foreach ($m in $tourRuns) {
        $key, $cmd = $m.Groups[1].Value, $m.Groups[2].Value
        if ($key -notmatch '^((Shift|Ctrl|Alt)\+)*\w$') { continue } # 'Settings', 'source button': not keys
        $tourKeys++
        if ($inputConf -notmatch "(?m)^$([regex]::Escape($key))\s+$([regex]::Escape($cmd))(\s|$)") { $tourBad += "$key -> $cmd" }
    }
    Test-Check $t "settings.lua: each key the feature tour names runs that command in input.conf ($tourKeys keys)" (
        $tourKeys -gt 5 -and $tourBad.Count -eq 0) ($tourBad -join '; ')
    $uoscIntl = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/lib/intl.lua')
    Test-Check $t 'uosc local change present: intl.lua reads the subtitle languages from settings.json (settings.lua)' (
        $uoscIntl.Contains("'~~state/settings.json'") -and $uoscIntl.Contains('settings_slang() or')) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: main.lua draws the buffer for streams only (local files: no hatching)' (
        $uoscMain -match 'and state\.is_stream\s*\r?\n\s*and \(#cached_ranges') 're-apply it after a uosc update (AGENTS.md)'
    $uoscTimeline = Get-Content -Raw (Join-Path $Cfg 'Scripts/uosc/elements/Timeline.lua')
    Test-Check $t 'uosc local change present: Timeline.lua shows the amber time only when it differs (speed is not 1x)' (
        $uoscTimeline.Contains('state.realtime_remaining_human ~= state.content_remaining_human')) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: Timeline.lua leaves the end time to destination_time=total (the pair is for the remaining times)' (
        $uoscTimeline.Contains("options.destination_time ~= 'total'")) 're-apply it after a uosc update (AGENTS.md)'
    Test-Check $t 'uosc local change present: Timeline.lua seeks a click by keyframe (instant), not exact' (
        $uoscTimeline.Contains("mp.commandv('seek', self:get_time_at_x(cursor.x), 'absolute+keyframes')")) 're-apply it after a uosc update (AGENTS.md)'
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
    # A TAB in these files is a backslash an editing tool read as an escape: "tests\try-gpu.ps1"
    # became "tests<TAB>ry-gpu.ps1" in a check's description. Nothing else here is a TAB
    # (Lua is indented with them, so it is not searched). No -I: a file saved as UTF-16 is
    # binary to git, and would be skipped. git grep exits 1 for no match, above 1 failing.
    $tabbed = @(& git -C $RepoRoot grep -l -e "`t" -- '*.md' '*.ps1' '*.psm1' '*.yml' '*.cs' '*.conf' '*.bat')
    Test-Check $t 'Markdown, PowerShell, workflow, C#, .conf and .bat files hold no TAB (an eaten "\t")' (
        $LASTEXITCODE -le 1 -and $tabbed.Count -eq 0) "git grep exit $LASTEXITCODE; $($tabbed -join ', ')"
    # Any other control character is such an escape too: "\b" in a regex became a backspace,
    # and the stall check above matched no line at all (2026-10-22). The license texts' page
    # breaks and the manual extracted from a PDF are the only ones on purpose.
    $controls = @(& git -C $RepoRoot grep -l -I -P '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' -- . ':!LICENSES' ':!doc/manual.txt')
    Test-Check $t 'no tracked text file holds a control character (an eaten "\b", "\f" ...)' (
        $LASTEXITCODE -le 1 -and $controls.Count -eq 0) "git grep exit $LASTEXITCODE; $($controls -join ', ')"
    if (-not $env:GITHUB_ACTIONS) {
        # INFO, not FAIL: the folder may lag behind the pin until updater.bat runs
        $exe = Join-Path $RepoRoot 'mpv.exe'
        $have = (Test-Path $exe) ? (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() : 'missing'
        $same = $have -eq $buildJson.upstream_files.'mpv.exe'
        Add-Result $t "the installed mpv.exe is the pinned build ($($buildJson.tag))" ($same ? 'PASS' : 'INFO') ($same ? '' : 'not yet - run updater.bat')
    }

    # -- privacy: this repository is public -------------------------------------------
    # What mpv and the scripts write while you watch names what was watched - none of
    # it may reach git. One sample path per kind (AGENTS.md, "Public repository"). The shader
    # capture's files are no longer written (2026-10-05), but an old copy may still sit
    # in a config folder.
    $private = @(
        'portable_config/speed.json', 'portable_config/stream-resume.json', 'portable_config/movie-sharpness.json',
        'portable_config/stream-resume.json.corrupt-20261010-120000', 'portable_config/settings.json.corrupt-20261013-120000',
        'portable_config/shader-misses.log', 'portable_config/shader-cases.json', 'portable_config/speed.json.1234.tmp',
        'portable_config/cache/shader_0123456789abcdef', 'portable_config/watch_later/0123456789ABCDEF',
        'portable_config/watch_history.jsonl', 'mpv-shot0001.jpg', 'yt-dlp.conf', 'cookies.txt', 'notes.txt',
        'portable_config/settings.json', 'portable_config/upscale.json', 'portable_config/welcome.json',
        'test-media/clip.mkv', '.claude/settings.local.json', '.env'
    )
    $notIgnored = @($private | Where-Object { & git -C $RepoRoot check-ignore -q --no-index -- $_; $LASTEXITCODE -ne 0 })
    Test-Check $t ".gitignore covers what mpv and the scripts write while you watch ($($private.Count) kinds)" ($notIgnored.Count -eq 0) ($notIgnored -join ', ')
    # the same checks CI's privacy job runs on every push (tests/lib/privacy.ps1), over
    # every tracked file; reported as file:line, never the text
    . (Join-Path $PSScriptRoot 'lib/privacy.ps1')
    $wordsFile = & git -C $RepoRoot rev-parse --path-format=absolute --git-path info/private-words 2>$null
    $words = ($wordsFile -and (Test-Path $wordsFile)) ? @(Get-Content $wordsFile) : @()
    $findings = Get-PrivacyFinding -Root $RepoRoot -Words $words
    foreach ($kv in $findings.GetEnumerator()) {
        Test-Check $t "tracked files: $($kv.Key)" ($kv.Value.Count -eq 0) ($kv.Value -join ', ')
    }
    if (-not ($findings.Keys -match 'private words')) {
        Add-Result $t 'tracked files: none of the private words' 'SKIP' 'no .git/info/private-words in this clone (CI has none; its privacy job checks the PRIVATE_WORDS secret)'
    }
    # A git that cannot run must stop the check: it printed nothing, which read as clean.
    $noRepo = Join-Path $WorkDir 'privacy-no-repo'
    New-Item -ItemType Directory -Force $noRepo | Out-Null
    $privacyError = ''
    try { $null = Get-PrivacyFinding -Root $noRepo } catch { $privacyError = "$_" }
    Test-Check $t 'privacy check: a git that cannot run fails it, not "nothing found"' ($privacyError -match 'privacy check cannot tell') $privacyError
    # CI's commit check (Get-CommitFinding) and the masking of a word in a reported path, in
    # a throwaway repo. Leaks are built here, so this file holds none itself.
    $pr = Join-Path $WorkDir 'privacy-commits'
    if (Test-Path $pr) { Remove-Item $pr -Recurse -Force }
    New-Item -ItemType Directory -Force $pr | Out-Null
    $pw = @('-c', 'user.name=guard-test', '-c', 'user.email=1+guard-test@users.noreply.github.com', '-c', 'core.hooksPath=')
    function Write-PrivacyCommit([string[]]$Message, [string[]]$Git = @()) {
        & git -C $pr @pw @Git commit -q --allow-empty @($Message | ForEach-Object { '-m'; $_ }) 2>&1 | Out-Null
        & git -C $pr rev-parse --short HEAD
    }
    try {
        & git -C $pr init -q -b main 2>&1 | Out-Null
        $base = Write-PrivacyCommit 'base'
        $clean = Write-PrivacyCommit @('clean work', ('Co-Authored-By: Claude <noreply' + '@anthropic.com>'))
        $bot = Write-PrivacyCommit @('bump an action', ('Signed-off-by: dependabot[bot] <support' + '@github.com>'))
        $web = Write-PrivacyCommit 'merged on the website' -Git @('-c', 'user.name=GitHub', '-c', 'user.email=noreply@github.com', '-c', 'author.name=guard-test', '-c', 'author.email=1+guard-test@users.noreply.github.com')
        $word = Write-PrivacyCommit 'notes from jane example'
        $path = Write-PrivacyCommit ('see C:' + '\Users\' + 'someone\Videos')
        $mail = Write-PrivacyCommit ('from jane' + '@example.net')
        $who = Write-PrivacyCommit 'work' -Git @('-c', 'user.name=Jane Doe', '-c', 'user.email=jane@example.org')
        $cf = Get-CommitFinding -Root $pr -Range "$base..HEAD" -Words @('# a comment', 'Jane Example')
        $want = [ordered]@{
            'every author and committer is a public identity'                       = $who
            'no commit message holds a user folder path or private claude.ai link' = $path
            'no commit message holds an e-mail address but noreply ones'          = $mail
            'no commit message holds a private word'                               = $word
        }
        $bad = @(foreach ($kv in $want.GetEnumerator()) {
                $got = @($cf[$kv.Key]) -join ','
                if ($got -ne $kv.Value) { "$($kv.Key): got '$got', want '$($kv.Value)'" }
            })
        # the eight commits really exist (a failed commit returns the one before it again)
        $made = @($base, $clean, $bot, $web, $word, $path, $mail, $who | Select-Object -Unique).Count -eq 8
        Test-Check $t "privacy, CI's commit check: each kind of leak names its commit (short sha only); a noreply co-author, Dependabot's sign-off and GitHub as committer pass" (
            $made -and $bad.Count -eq 0 -and $cf.Count -eq 4) "$($bad -join '; ') (8 distinct commits: $made)"
        Set-Content -LiteralPath (Join-Path $pr 'by Jane Example.txt') 'x'
        & git -C $pr add -A 2>&1 | Out-Null
        $named = @((Get-PrivacyFinding -Root $pr -Words @('Jane Example'))['no file name holds a private word'])
        Test-Check $t '... a reported path holds no private word (*** in its place)' (
            $named.Count -eq 1 -and $named[0] -eq 'by ***.txt') ($named -join ', ')
        # a name with a letter outside ASCII, which git prints quoted unless told otherwise
        $umlaut = 'M' + [char]0x00FC + 'ller'
        Set-Content -LiteralPath (Join-Path $pr "notes of $umlaut.txt") 'x'
        & git -C $pr add -A 2>&1 | Out-Null
        $named = @((Get-PrivacyFinding -Root $pr -Words @($umlaut))['no file name holds a private word'])
        Test-Check $t '... also a word with a letter outside ASCII in a file name' ($named.Count -eq 1) ($named -join ', ')
        $savedUser = $env:USERNAME
        try {
            $env:USERNAME = 'Ana Lee'
            $spaced = ConvertTo-PublicText ('C:/' + 'Users/Ana Lee/AppData/run.log')
        }
        finally { $env:USERNAME = $savedUser }
        Test-Check $t "privacy: a user name with a space is hidden whole, also in a path written with /" ($spaced -notmatch 'Lee|Ana') $spaced
        # what tests/try-gpu.ps1 posts to a pull request's status and comment (public)
        $raw = "log: $env:TEMP\mpv-try-gpu\work\logs\gpu-1.log on $env:COMPUTERNAME by $env:USERNAME, see D:" + '\Users\' + 'jane\notes, by Jane Example'
        $public = ConvertTo-PublicText $raw @('# a comment', 'Jane Example')
        Test-Check $t "privacy: what try-gpu.ps1 posts names no user folder, no user or PC name and no private word" (
            $public -match '%TEMP%\\mpv-try-gpu\\work' -and $public -match 'D:\\Users\\<name>\\notes' -and $public -notmatch '(?i)jane' -and
            -not $public.Contains($env:COMPUTERNAME) -and -not $public.Contains($env:USERNAME)) $public
    }
    finally {
        Remove-Item $pr -Recurse -Force -ErrorAction SilentlyContinue
    }

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
        # an mpv running from another folder whose name starts the same (root-old for root) is
        # not this folder's: it blocked the update
        Add-Content -LiteralPath (Join-Path $root 'mpv/fonts.conf') 'edited'
        $sibling = Join-Path $ib 'root-old'
        $other = Open-StandInMpv $sibling
        try { $r = Invoke-Installer pwsh $root $json @('-Archive', $archive) }
        finally { Close-StandInMpv $other }
        Test-Check $t '... with an mpv running from another folder whose name starts the same' ($r.Code -eq 0 -and (Test-Installed $root)) $r.Out
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
    Invoke-RegisterCheck $t

    # -- mpv-single.exe is built from the mpv-single.cs next to it ---------------------
    # Both are committed, the exe through Git LFS, where no diff shows what it was built
    # from: an exe built before the last edit of the source would go unnoticed. It carries
    # its source as a resource (stored as it is), so this is the same text. A checkout
    # without Git LFS (CI) holds a pointer instead.
    $singleExe = Join-Path $RepoRoot 'mpv-single.exe'
    $singleBytes = [IO.File]::ReadAllBytes($singleExe)
    if ($singleBytes.Length -lt 1024) {
        Add-Result $t 'mpv-single.exe holds the mpv-single.cs it was built from' 'SKIP' 'a Git LFS pointer in this checkout'
    }
    else {
        $source = [IO.File]::ReadAllBytes((Join-Path $RepoRoot 'mpv-single.cs'))
        $found = [Text.Encoding]::Latin1.GetString($singleBytes).Contains([Text.Encoding]::Latin1.GetString($source))
        Test-Check $t 'mpv-single.exe holds the mpv-single.cs it was built from' $found `
            'rebuild it with the command in mpv-single.cs (with /resource:mpv-single.cs) and commit both'
    }

    # -- what a pull request changes that CI cannot test on a GPU (gpu-flag.ps1) ----------
    # Its title gets "[GPU: <areas>]" and its check "GPU tier (local)" waits for the gpu
    # tier on the PC; a change outside the GPU pipeline must stay unflagged, or the flag
    # means nothing. The 20261018 -> 20261020 build is a real case: vulkan and hwdec_vulkan
    # in mpv, a new libplacebo, FFmpeg without D3D11 changes.
    . (Join-Path $RepoRoot '.github/scripts/gpu-flag.ps1')
    $file = { param($name, $patch) [pscustomobject]@{ filename = $name; patch = $patch } }
    $old = [pscustomobject]@{ git = '01e2533f31'; libplacebo = 'v7.376.0 (a)'; ffmpeg = 'N-127617-g94cba3150' }
    $new = [pscustomobject]@{ git = '6a262d11f6'; libplacebo = 'v7.377.0 (b)'; ffmpeg = 'N-127734-g38ac3a923' }
    $flagCases = @(
        @{ Name = 'a shader'; Files = @(& $file 'portable_config/shaders/Anime4K_Clamp_Highlights.glsl' ''); Want = '[GPU: shaders]' }
        @{ Name = 'gpu-toggles.lua, once'; Files = @(& $file 'portable_config/Scripts/gpu-toggles.lua' "@@`n+mp.set_property('glsl-shaders', x)"); Want = '[GPU: gpu-toggles]' }
        @{ Name = "mpv.conf's hwdec"; Files = @(& $file 'portable_config/mpv.conf' "@@`n-hwdec=d3d11va-copy,no`n+hwdec=auto"); Want = '[GPU: mpv.conf]' }
        @{ Name = "mpv.conf's OSD font size"; Files = @(& $file 'portable_config/mpv.conf' "@@`n-osd-font-size=30`n+osd-font-size=32"); Want = '' }
        @{ Name = 'a script that sets target-peak'; Files = @(& $file 'portable_config/Scripts/settings.lua' "@@`n+`tmp.set_property('target-peak', peak)"); Want = '[GPU: scripts]' }
        @{ Name = 'hwdec in a Lua comment'; Files = @(& $file 'portable_config/Scripts/settings.lua' "@@`n+`t-- set 'hwdec' elsewhere"); Want = '' }
        @{ Name = 'docs'; Files = @(& $file 'README.md' "@@`n+hwdec=auto"); Want = '' }
        @{ Name = 'the 20261020 build'; Files = @(& $file 'mpv-build.json' ''); Old = $old; New = $new
            Mpv = @('player/lua.c', 'video/out/hwdec/hwdec_vulkan.c', 'video/out/vulkan/context.c'); Ffmpeg = @('libavformat/hls.c')
            Want = '[GPU: vulkan, hwdec, libplacebo]'
        }
        @{ Name = 'a build with nothing for the GPU'; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = 'aaaaaaaaaa'; libplacebo = $old.libplacebo; ffmpeg = 'N-1-gbbbbbbb' }
            Mpv = @('player/command.c'); Ffmpeg = @('libavformat/hls.c'); Want = ''
        }
        @{ Name = "a build whose mpv changes GitHub cannot list"; Files = @(& $file 'mpv-build.json' ''); Old = $old; New = $new
            Mpv = $null; Ffmpeg = @(); Want = '[GPU: mpv, libplacebo]'
        }
        @{ Name = 'gpu-toggles.lua renamed'; Files = @([pscustomobject]@{ filename = 'portable_config/Scripts/toggles.lua'
                    previous_filename = 'portable_config/Scripts/gpu-toggles.lua'; status = 'renamed'; patch = $null
                }); Want = '[GPU: gpu-toggles]'
        }
        @{ Name = 'a file list GitHub cut short'; Files = @(& $file 'README.md' "@@`n+x"); Unread = @('GitHub listed 3000 of its 4000 files')
            Want = '[GPU: unknown]'
        }
        @{ Name = 'a script only renamed (no diff, nothing changed in it)'; Files = @([pscustomobject]@{
                    filename = 'portable_config/Scripts/bar.lua'; previous_filename = 'portable_config/Scripts/foo.lua'
                    status = 'renamed'; changes = 0; patch = $null
                }); Want = ''
        }
        @{ Name = 'an mpv.conf diff too large to show'; Files = @([pscustomobject]@{ filename = 'portable_config/mpv.conf'; status = 'modified'; patch = $null })
            Want = '[GPU: unknown]'
        }
        @{ Name = "mpv's decoder choice"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = 'cccccccccc'; libplacebo = $old.libplacebo; ffmpeg = $old.ffmpeg }
            Mpv = @('video/decode/vd_lavc.c'); Ffmpeg = @(); Want = '[GPU: decoding]'
        }
        @{ Name = "mpv's colour code"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = 'dddddddddd'; libplacebo = $old.libplacebo; ffmpeg = $old.ffmpeg }
            Mpv = @('video/csputils.c', 'stream/stream_curl.c'); Ffmpeg = @(); Want = '[GPU: color]'
        }
        @{ Name = "FFmpeg's hardware decoding layer"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = $old.git; libplacebo = $old.libplacebo; ffmpeg = 'N-3-geeeeeee' }
            Mpv = @(); Ffmpeg = @('libavutil/hwcontext.c'); Want = '[GPU: FFmpeg d3d11va]'
        }
        @{ Name = 'the 20261021 build (stream_curl only)'; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = 'e471496c56'; libplacebo = $old.libplacebo; ffmpeg = 'N-127893-g9a861e968' }
            Mpv = @('stream/stream_curl.c'); Want = ''
            # its real diffs: decode.c's change is subtitle text, hevcdec.c's film grain -
            # "hwaccel" only in a context line around it
            Ffmpeg = @(
                [pscustomobject]@{ filename = 'libavcodec/decode.c'; patch = "@@`n+const char *ff_decode_subtitle_text(AVCodecContext *avctx, const AVPacket *avpkt)" }
                [pscustomobject]@{ filename = 'libavcodec/hevc/hevcdec.c'; patch = "@@`n-        av_assert1(ret >= 0);`n+        if (ret < 0) {`n     }`n `n     if (s->avctx->hwaccel) {" }
                'libavformat/hls.c')
        }
        @{ Name = "a decoder's change to its D3D11VA formats"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = $old.git; libplacebo = $old.libplacebo; ffmpeg = 'N-4-gfffffff' }; Mpv = @()
            Ffmpeg = @([pscustomobject]@{ filename = 'libavcodec/hevc/hevcdec.c'; patch = "@@`n-        *fmt++ = AV_PIX_FMT_D3D11;`n+        if (sps->bit_depth == 8) *fmt++ = AV_PIX_FMT_D3D11;" })
            Want = '[GPU: FFmpeg d3d11va]'
        }
        @{ Name = "FFmpeg's HDR metadata"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = $old.git; libplacebo = $old.libplacebo; ffmpeg = 'N-5-g1111111' }; Mpv = @()
            Ffmpeg = @('libavcodec/h2645_sei.c'); Want = '[GPU: FFmpeg HDR]'
        }
        @{ Name = "mpv's scaler kernels"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = '2222222222'; libplacebo = $old.libplacebo; ffmpeg = $old.ffmpeg }
            Mpv = @('video/out/filter_kernels.c'); Ffmpeg = @(); Want = '[GPU: renderer]'
        }
        @{ Name = "FFmpeg's D3D11 decoding"; Files = @(& $file 'mpv-build.json' ''); Old = $old
            New = [pscustomobject]@{ git = $old.git; libplacebo = $old.libplacebo; ffmpeg = 'N-2-gcccccccc' }
            Mpv = @(); Ffmpeg = @('libavcodec/d3d11va.c'); Want = '[GPU: FFmpeg d3d11va]'
        }
    )
    $flagBad = @(foreach ($c in $flagCases) {
            $got = Get-GpuTag (Get-GpuReason -Files $c.Files -OldBuild $c['Old'] -NewBuild $c['New'] -MpvFiles $c['Mpv'] -FfmpegFiles $c['Ffmpeg'] -Unread $c['Unread'])
            if ($got -ne $c.Want) { "$($c.Name): got '$got', want '$($c.Want)'" }
        })
    Test-Check $t "gpu-flag.ps1 flags what CI cannot test on a GPU, and nothing else ($($flagCases.Count) cases)" ($flagBad.Count -eq 0) ($flagBad -join '; ')

    # mpv-auto-update.yml cancelled between pushing mpv-update and opening its pull request
    # left a branch that read as "waits for the owner's merge" on every later run: its
    # cancel step deletes that branch, and only that one (tests/lib/cancel-step.sh). Git for
    # Windows' bash, found from git itself: a bare "bash" can be WSL's.
    $cancelCheck = "mpv-auto-update.yml's cancel step deletes an mpv-update left without its pull request, and nothing else"
    $gitPath = & git --exec-path 2>$null
    $bash = if ($gitPath) { Join-Path (Split-Path (Split-Path (Split-Path $gitPath))) 'bin/bash.exe' }
    if ($bash -and (Test-Path -LiteralPath $bash)) {
        $out = @(& $bash (Join-Path $RepoRoot 'tests/lib/cancel-step.sh') (Join-Path $RepoRoot '.github/workflows/mpv-auto-update.yml') 2>&1)
        Test-Check $t $cancelCheck ($LASTEXITCODE -eq 0) (@($out | Where-Object { "$_" -notlike 'PASS *' }) -join '; ')
    }
    else {
        Add-Result $t $cancelCheck 'SKIP' "no Git for Windows bash next to git ($bash)"
    }

    # -- commit and push guards (.githooks), tried in a throwaway repo ------------------
    # 2026-09-27: an mpv update was committed on a feature branch and a pull deleted
    # mpv.exe; since 2026-10-03 the files are not in git at all and the guard keeps
    # them out (a forced add would put ~120 MB back into Git LFS).
    $hooks = Join-Path $RepoRoot '.githooks'
    $hookFiles = 'pre-commit', 'pre-push', 'privacy.sh', 'post-checkout', 'post-commit', 'post-merge'
    $hookMissing = @($hookFiles | Where-Object { -not (Test-Path (Join-Path $hooks $_)) })
    Test-Check $t '.githooks: the commit and push guards, their privacy.sh and the git-lfs hooks are there' ($hookMissing.Count -eq 0) ($hookMissing -join ', ')
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
    $bare = Join-Path $WorkDir 'git-guard-remote'
    foreach ($d in $g, $bare) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
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
        # the older noreply form, without the numeric id: CI's identity check refuses it too
        $r = Invoke-Git -c 'user.email=guard-test@users.noreply.github.com' commit -q --allow-empty -m 'old noreply'
        Test-Check $t '... a noreply address without its numeric id is refused' ($r.Code -ne 0 -and $r.Out -match 'not a public identity') $r.Out
        New-Item -ItemType Directory -Force (Join-Path $g 'portable_config') | Out-Null
        Write-GuardFile 'portable_config/stream-resume.json' '{}'
        $null = Invoke-Git add -f portable_config/stream-resume.json
        $r = Invoke-Git commit -q -m 'resume state'
        Test-Check $t 'commit guard: a forced add of an ignored private file (stream-resume.json) is refused' (
            $r.Code -ne 0 -and $r.Out -match 'keeps these out') $r.Out
        $null = Invoke-Git restore --staged -- portable_config/stream-resume.json
        $leaks = [ordered]@{
            'a user folder path'               = 'C:' + '\Users\' + 'someone\Videos'
            'a user folder path in lower case' = 'c:' + '\users\' + 'someone\videos'
            'a private claude.ai link'         = 'https://claude.ai/' + 'code/session_0123'
            'a private claude.ai artifact link'  = 'https://claude.ai/' + 'artifacts/0123'
            # a name that starts with a letter beyond ASCII (an E with acute accent)
            'a user folder path with a non-ASCII name' = 'C:' + '\Users\' + [char]0x00C9 + 'mile\Videos'
        }
        foreach ($kv in $leaks.GetEnumerator()) {
            Write-GuardFile 'notes.md' "see $($kv.Value)"
            $null = Invoke-Git add notes.md
            $r = Invoke-Git commit -q -m 'leak'
            Test-Check $t "commit guard: an added line with $($kv.Key) is refused" (
                $r.Code -ne 0 -and $r.Out -match 'user folder path or a private claude') $r.Out
        }
        Write-GuardFile 'notes.md' 'see C:\Users\<name>\Videos'
        $null = Invoke-Git add notes.md
        $r = Invoke-Git commit -q -m 'placeholder'
        Test-Check $t '... a placeholder (C:\Users\<name>) goes through' ($r.Code -eq 0) $r.Out
        Write-GuardFile 'notes.md' ('mail jane' + '@example.net')
        $null = Invoke-Git add notes.md
        $r = Invoke-Git commit -q -m 'address'
        Test-Check $t 'commit guard: an added line with an e-mail address is refused' ($r.Code -ne 0 -and $r.Out -match 'holds an e-mail address') $r.Out
        Write-GuardFile 'notes.md' ('by guard-test <1+guard-test' + '@users.noreply.github.com>')
        $null = Invoke-Git add notes.md
        $r = Invoke-Git commit -q -m 'noreply address'
        Test-Check $t '... a noreply one goes through' ($r.Code -eq 0) $r.Out
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
        # ... nor in a linked worktree (git worktree add, a dev's): it has no mpv of its own
        $wt = Join-Path (Split-Path -Parent $g) 'guard-worktree'
        $null = Invoke-Git worktree add -q -b ci-wt $wt
        $null = Invoke-Git switch -q -c ci-third
        Write-PinnedExe ('2' * 64)
        $null = Invoke-Git commit -q -am 'ci: pin a third mpv'
        $null = Invoke-Git switch -q main
        $ErrorActionPreference = 'Continue'
        $out = & git -C $wt merge -q --ff-only ci-third 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Test-Check $t '... nor in a linked worktree, which has no mpv of its own' ($code -eq 0 -and ($out -join ' ') -notmatch 'updater\.bat') ($out -join ' ')
        $null = Invoke-Git worktree remove --force $wt

        # pre-push: the history is public too, so every commit a push adds is checked - also
        # one the commit guard never saw (--no-verify, a clone without the hooks). The remote
        # gets main as it is (the forced-in mpv.exe above included: public already).
        $null = & git init -q --bare $bare 2>&1
        $null = Invoke-Git remote add origin $bare
        $null = Invoke-Git push -q --no-verify origin main
        Write-GuardFile 'script.lua' 'v3'
        $null = Invoke-Git commit -q -am 'more work' -m ('Co-Authored-By: Claude <noreply' + '@anthropic.com>')
        $r = Invoke-Git push -q origin main
        $published = (Invoke-Git rev-parse main).Out
        Test-Check $t 'push guard: a clean commit goes out (a noreply co-author named in it)' (
            $r.Code -eq 0 -and (& git -C $bare rev-parse main) -eq $published) $r.Out
        Set-Content -LiteralPath $words 'Jane Example'
        $pushLeaks = [ordered]@{
            'a private word in a commit message'          = { Invoke-Git commit -q --no-verify --allow-empty -m 'notes from jane example' }
            'a user folder path in a commit message'      = { Invoke-Git commit -q --no-verify --allow-empty -m ('see C:' + '\Users\' + 'someone\Videos') }
            'an e-mail address in a commit message'       = { Invoke-Git commit -q --no-verify --allow-empty -m ('from jane' + '@example.net') }
            'an added line with a private word'           = { Write-GuardFile 'notes.md' 'written by jane example'; Invoke-Git commit -q --no-verify -am 'notes' }
            'an added line with an e-mail address'        = { Write-GuardFile 'notes.md' ('mail jane' + '@example.net'); Invoke-Git commit -q --no-verify -am 'notes' }
            'a word one commit adds and the next removes' = {
                Write-GuardFile 'notes.md' 'written by jane example'; Invoke-Git commit -q --no-verify -am 'notes'
                Write-GuardFile 'notes.md' 'written'; Invoke-Git commit -q -am 'notes fixed'
            }
            'a real name as author'                       = { Invoke-Git -c 'user.name=Jane Doe' commit -q --no-verify --allow-empty -m 'work' }
            'a forced-in ignored file'                    = {
                Write-GuardFile 'portable_config/stream-resume.json' '{}'
                Invoke-Git add -f portable_config/stream-resume.json; Invoke-Git commit -q --no-verify -m 'state'
            }
        }
        foreach ($kv in $pushLeaks.GetEnumerator()) {
            $null = & $kv.Value
            $r = Invoke-Git push -q origin main
            Test-Check $t "push guard: $($kv.Key) is refused, nothing reaches the remote, the text is not printed" (
                $r.Code -ne 0 -and $r.Out -match 'Push refused' -and (& git -C $bare rev-parse main) -eq $published -and
                $r.Out -notmatch 'jane|someone') $r.Out
            $null = Invoke-Git reset -q --hard $published
        }
        # what the remote gets besides commits: the branch name (a word a name can hold: a
        # PC name), an annotated tag
        Add-Content -LiteralPath $words 'janes-laptop'
        $r = Invoke-Git push -q origin 'main:refs/heads/fix-janes-laptop'
        Test-Check $t 'push guard: a branch name with a private word is refused (the finding does not name it)' (
            $r.Code -ne 0 -and $r.Out -match 'a pushed branch or tag: the name the remote gets' -and
            -not (& git -C $bare rev-parse -q --verify fix-janes-laptop)) $r.Out
        $r = Invoke-Git push -q origin ('main:refs/heads/ping-jane' + '@example.net')
        Test-Check $t '... and one with an e-mail address' (
            $r.Code -ne 0 -and $r.Out -match 'the name the remote gets holds an e-mail address' -and
            -not (& git -C $bare rev-parse -q --verify ('ping-jane' + '@example.net'))) $r.Out
        $r = Invoke-Git push -q origin ('main:refs/heads/claude' + '.ai/chat/2a9cb8')
        Test-Check $t '... and one with a private claude.ai link' (
            $r.Code -ne 0 -and $r.Out -match 'the name the remote gets holds a private claude.ai link' -and
            -not (& git -C $bare rev-parse -q --verify ('claude' + '.ai/chat/2a9cb8'))) $r.Out
        $null = Invoke-Git tag -a v-test -m 'for jane example'
        $r = Invoke-Git push -q origin v-test
        Test-Check $t "... an annotated tag whose message holds one too" (
            $r.Code -ne 0 -and $r.Out -match 'Push refused' -and -not (& git -C $bare rev-parse -q --verify v-test)) $r.Out
        $null = Invoke-Git tag -d v-test
        # mpv's own manual names an example user folder (users\USERNAME): both guards let it in
        New-Item -ItemType Directory -Force (Join-Path $g 'doc') | Out-Null
        Write-GuardFile 'doc/manual.txt' ("the example is C:" + "\users\USERNAME\mpv`nreport bugs to mpv-team" + '@example.net')
        $null = Invoke-Git add doc/manual.txt
        $r = Invoke-Git commit -q -m 'manual'
        $r2 = Invoke-Git push -q origin main
        Test-Check $t "... mpv's manual with its example user folder and its authors' addresses is committed and pushed" ($r.Code -eq 0 -and $r2.Code -eq 0) "$($r.Out) $($r2.Out)"
        $published = (Invoke-Git rev-parse main).Out
        Remove-Item -LiteralPath $words
        $null = Invoke-Git switch -q -c feature
        Write-GuardFile 'script.lua' 'v4'
        $null = Invoke-Git commit -q -am 'feature work'
        $r = Invoke-Git push -q origin feature
        Test-Check $t "... a new branch: only its own commits are checked (main's public history holds mpv.exe)" (
            $r.Code -eq 0 -and (& git -C $bare rev-parse feature) -eq (Invoke-Git rev-parse feature).Out) $r.Out
    }
    finally {
        Remove-Item $g, $bare -Recurse -Force -ErrorAction SilentlyContinue
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
# mpv-single.exe (what Explorer starts for mpv's file types), built from
# mpv-single.cs, with single-instance.lua: files opened at once - Explorer
# starts one launcher per selected file, within a few milliseconds - go into
# ONE mpv (in mpv's GUI mode), all of them in its playlist; a file opened later
# replaces them in that mpv, never in one that plays a stream; the banner's way
# out (accept) puts the old files back and plays the new one on in a second mpv,
# from where it got to; Ctrl opens a new mpv; with only a stream playing a local
# file gets its own mpv; an mpv without the script (on the one pipe name older
# launchers used) still gets the file. mpv runs with vo=null/ao=null, so no
# window: which window is in front (the launcher's choice among several local
# ones) is not covered. The players' pipes have a prefix of their own
# (MPV_SINGLE_PIPE_PREFIX): a file the owner opens meanwhile never lands in one.
# ---------------------------------------------------------------------------
function Invoke-LauncherCheck([string]$Exe, [string]$Media) {
    $t = 'mpv-single'
    Write-Host ''
    Write-Host "-- $t" -ForegroundColor White
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { Add-Result $t 'mpv-single.exe' 'SKIP' 'no .NET Framework csc.exe to build it'; return }
    $running = @(Get-Process mpv, mpv-single -ErrorAction SilentlyContinue)
    if ($running.Count) { Add-Result $t 'mpv-single.exe' 'SKIP' "an mpv runs (pid $($running.Id -join ', ')): the owner may be watching"; return }
    $dir = Join-Path $WorkDir 'mpv-single'
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $dir 'portable_config'), (Join-Path $dir 'media'), (Join-Path $dir 'other') | Out-Null
    $built = & $csc /nologo /target:winexe "/out:$(Join-Path $dir 'mpv-single.exe')" (Join-Path $RepoRoot 'mpv-single.cs') 2>&1
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'mpv-single.exe'))) { Add-Result $t 'mpv-single.cs builds' 'FAIL' ($built -join ' '); return }
    # mpv.com too, which the launcher starts: the pinned build's folder, not the test root
    $bin = Split-Path -Parent (Get-Item -LiteralPath $MpvExe).FullName
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'mpv.com'))) { Add-Result $t 'mpv-single.exe' 'SKIP' "no mpv.com next to $MpvExe"; return }
    foreach ($f in 'mpv.exe', 'mpv.com', 'd3dcompiler_43.dll') {
        if (Test-Path -LiteralPath (Join-Path $bin $f)) { Copy-Item -LiteralPath (Join-Path $bin $f) $dir }
    }
    # mpv players that are not the launcher's: another folder's mpv.exe
    Copy-Item -LiteralPath (Join-Path $dir 'mpv.exe') (Join-Path $dir 'other/mpv.exe')
    # a file plays on (a slow runner would reach the next one between two checks), and the
    # banner's offer outlasts the checks
    Copy-Item -LiteralPath (Join-Path $Cfg 'Scripts/single-instance.lua') (Join-Path $dir 'portable_config/single-instance.lua')
    Set-Content -LiteralPath (Join-Path $dir 'portable_config/mpv.conf') (
        "vo=null`nao=null`nkeep-open=no`nidle=no`nload-scripts=no`nscript=~~/single-instance.lua`n" +
        "script-opts=single_instance-banner_seconds=60`nloop-file=inf")
    foreach ($n in 'a', 'b', 'c', 'd', 'e', 'f', 'g') { Copy-Item -LiteralPath (Join-Path $Media 'plain/clip.mkv') (Join-Path $dir "media/$n.mkv") }
    $launcher = Join-Path $dir 'mpv-single.exe'
    $open = { param([string]$Name) Start-Process -FilePath $launcher -ArgumentList ('"' + (Join-Path $dir "media/$Name.mkv") + '"') }
    $players = { @(Get-Process mpv -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $dir 'mpv.exe') }) }
    $launchersDone = {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt 20000 -and
            @(Get-Process mpv-single -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $launcher }).Count) { Start-Sleep -Milliseconds 100 }
    }
    $waitFor = {
        param([scriptblock]$Done, [int]$Ms = 5000)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not (& $Done) -and $clock.ElapsedMilliseconds -lt $Ms) { Start-Sleep -Milliseconds 200 }
    }
    # one command to the mpv behind a pipe; its reply's data
    $call = {
        param([string]$Pipe, [string]$Command)
        $client = $null
        try {
            $client = [IO.Pipes.NamedPipeClientStream]::new('.', $Pipe, [IO.Pipes.PipeDirection]::InOut)
            $client.Connect(3000)
            $writer = [IO.StreamWriter]::new($client)
            $writer.AutoFlush = $true
            $reader = [IO.StreamReader]::new($client)
            $writer.WriteLine('{"command":' + $Command + ',"request_id":41}')
            for ($i = 0; $i -lt 50; $i++) {
                $line = $reader.ReadLineAsync()
                if (-not $line.Wait(3000)) { return $null }
                if ($line.Result -match '"request_id":\s*41') { return ($line.Result | ConvertFrom-Json).data }
            }
            return $null
        }
        catch { return $null }
        finally { if ($client) { $client.Dispose() } }
    }
    $ask = { param([string]$Pipe, [string]$Name) & $call $Pipe ('["get_property","' + $Name + '"]') }
    # the pipe of the mpv with this process id
    $pipeOf = {
        param([int]$ProcessId)
        foreach ($p in [IO.Directory]::GetFiles('\\.\pipe\') -replace '^.*\\' -like "$prefix*") {
            if ((& $ask $p 'pid') -eq $ProcessId) { return $p }
        }
    }
    $prefix = 'mpv-regression-single'
    $stream = $other = $bare = $null
    try {
        $env:MPV_SINGLE_PIPE_PREFIX = $prefix
        foreach ($n in 'a', 'b', 'c') { & $open $n }
        & $launchersDone
        # the old launcher ended at once: its mpv players start a moment later
        Start-Sleep -Milliseconds 1500
        $first = @(& $players)
        $main = if ($first.Count -eq 1) { & $pipeOf $first[0].Id }
        $playlist = if ($main) { & $ask $main 'playlist-count' }
        Test-Check $t 'three files opened at once go into one mpv' ($first.Count -eq 1 -and $main) "$($first.Count) mpv players, pipe $main"
        Test-Check $t '... all three in its playlist' ($playlist -eq 3) "playlist-count $playlist"
        # as mpv.exe started from Explorer: a window at once, also for a song with no picture
        $mode = if ($main) { & $ask $main 'player-operation-mode' }
        Test-Check $t "... in mpv's GUI mode (pseudo-gui), not mpv.com's console mode" ($mode -eq 'pseudo-gui') "player-operation-mode $mode"

        # Beside it: an mpv that plays a stream on a pipe of the launcher's kind, and a second
        # mpv with no pipe (FastStream's, say). The file goes to neither; the window raised
        # after the hand-off is the one of the mpv behind the pipe (it was the first process
        # named mpv with a window). MPV_SINGLE_RAISE_LOG makes the launcher write the process id
        # it would raise, and raise nothing on this desktop.
        $streamPipe = "$prefix-stream"
        $stream = Start-Process -FilePath (Join-Path $dir 'other/mpv.exe') -PassThru -WindowStyle Hidden -ArgumentList '--no-config',
        '--idle=yes', '--vo=null', '--ao=null', "--input-ipc-server=\\.\pipe\$streamPipe", 'av://lavfi:testsrc=duration=600'
        $other = Start-Process -FilePath (Join-Path $dir 'other/mpv.exe') -ArgumentList '--no-config', '--idle=yes', '--vo=null', '--ao=null' -PassThru -WindowStyle Hidden
        & $waitFor { (& $ask $streamPipe 'path') -like 'av://*' }
        $raiseLog = Join-Path $dir 'raised.txt'
        # the burst's first file: whichever launcher got the gate first
        $was = & $ask $main 'filename'
        $env:MPV_SINGLE_RAISE_LOG = $raiseLog
        try { & $open 'd' }
        finally { Remove-Item Env:MPV_SINGLE_RAISE_LOG -ErrorAction SilentlyContinue }
        & $launchersDone
        # The launcher has handed it over; a slow machine's mpv may take a moment to swap.
        & $waitFor { (& $ask $main 'playlist-count') -eq 1 -and (& $ask $main 'filename') -eq 'd.mkv' }
        $count = @(& $players).Count
        $playlist = & $ask $main 'playlist-count'
        $file = & $ask $main 'filename'
        Test-Check $t '... a file opened later replaces them, in the same mpv' (
            $count -eq 1 -and $playlist -eq 1 -and $file -eq 'd.mkv') "$count mpv players, playlist-count $playlist, playing $file"
        $streamPath = & $ask $streamPipe 'path'
        Test-Check $t '... not in the mpv that plays a stream' ($streamPath -like 'av://*') "the stream mpv plays $streamPath"
        $served = & $ask $main 'pid'
        $raised = if (Test-Path -LiteralPath $raiseLog) { (Get-Content -LiteralPath $raiseLog -Raw).Trim() } else { 'nothing' }
        Test-Check $t '... and the window raised is that mpv''s, not another one''s' (
            $null -ne $served -and $raised -eq [string]$served) "raised $raised, the pipe's mpv $served, the others $($stream.Id), $($other.Id)"
        $offered = & $ask $main 'user-data/single-instance'
        Test-Check $t '... and its banner offers the old files back' ($was -and "$($offered.offer.old)" -like "*$was") "was playing $was; $($offered | ConvertTo-Json -Compress)"

        # the banner clicked: a second mpv plays the new file on, the first the old ones
        $played = & $ask $main 'time-pos'
        $null = & $call $main '["script-message-to","single_instance","accept"]'
        & $waitFor { @(& $players).Count -eq 2 } 10000
        & $launchersDone
        $second = @(& $players | Where-Object { $_.Id -ne $served })
        $secondPipe = if ($second.Count -eq 1) { & $pipeOf $second[0].Id }
        $file = if ($secondPipe) { & $ask $secondPipe 'filename' }
        # its start, not its time-pos: the launcher waits for a window that vo=null never
        # opens, and the file plays on meanwhile
        $start = if ($secondPipe) { & $ask $secondPipe 'file-local-options/start' }
        $at = if ("$start" -match '[\d.]+') { [double]$Matches[0] } else { $null }
        Test-Check $t 'the banner''s click: the new file goes on in a second mpv' ($second.Count -eq 1 -and $file -eq 'd.mkv') "$($second.Count) new mpv players, playing $file"
        Test-Check $t '... from where it got to' ($null -ne $at -and $null -ne $played -and $at -ge $played - 0.1 -and $at -le $played + 1.5) "start $start, was at $played"
        & $waitFor { (& $ask $main 'filename') -eq $was }
        $file = & $ask $main 'filename'
        $playlist = & $ask $main 'playlist-count'
        Test-Check $t '... and the old files come back in the first' ($file -eq $was -and $playlist -eq 3) "playing $file (was $was), playlist-count $playlist"

        # Ctrl held (MPV_SINGLE_CTRL: no key press is sent): a new mpv, the others untouched
        $env:MPV_SINGLE_CTRL = '1'
        try { & $open 'e' }
        finally { Remove-Item Env:MPV_SINGLE_CTRL -ErrorAction SilentlyContinue }
        & $launchersDone
        & $waitFor { @(& $players).Count -eq 3 }
        $count = @(& $players).Count
        $file = & $ask $main 'filename'
        Test-Check $t 'a file opened with Ctrl held gets a new mpv' ($count -eq 3 -and $file -eq $was) "$count mpv players, the first plays $file"

        # only a stream plays: a local file gets an mpv of its own
        & $players | Stop-Process -Force -ErrorAction SilentlyContinue
        & $waitFor { @(& $players).Count -eq 0 }
        & $open 'f'
        & $launchersDone
        & $waitFor { @(& $players).Count -eq 1 }
        $count = @(& $players).Count
        $streamPath = & $ask $streamPipe 'path'
        Test-Check $t 'with only a stream playing, a local file gets its own mpv' (
            $count -eq 1 -and $streamPath -like 'av://*') "$count mpv players, the stream mpv plays $streamPath"

        # an mpv without single-instance.lua, on the pipe name older launchers gave every mpv
        & $players | Stop-Process -Force -ErrorAction SilentlyContinue
        $stream | Stop-Process -Force -ErrorAction SilentlyContinue
        & $waitFor { @(& $players).Count -eq 0 }
        $bare = Start-Process -FilePath (Join-Path $dir 'other/mpv.exe') -PassThru -WindowStyle Hidden -ArgumentList '--no-config',
        '--idle=yes', '--vo=null', '--ao=null', "--input-ipc-server=\\.\pipe\$prefix", ('"' + (Join-Path $dir 'media/a.mkv') + '"')
        & $waitFor { (& $ask $prefix 'filename') -eq 'a.mkv' }
        & $open 'g'
        & $launchersDone
        & $waitFor { (& $ask $prefix 'filename') -eq 'g.mkv' }
        $file = & $ask $prefix 'filename'
        $count = @(& $players).Count
        Test-Check $t 'an mpv without single-instance.lua (an older launcher''s) still gets the file' (
            $file -eq 'g.mkv' -and $count -eq 0) "it plays $file; $count new mpv players"
    }
    finally {
        Remove-Item Env:MPV_SINGLE_PIPE_PREFIX -ErrorAction SilentlyContinue
        foreach ($p in $stream, $other, $bare) { if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue } }
        & $players | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process mpv-single -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $launcher } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# mpv-single-register.ps1 / -unregister.ps1, on stand-in roots under
# HKCU:\Software\mpv-config-tests (never the real file types), in Windows
# PowerShell 5.1 as the .bat files run them: mpv's own entries of this folder's
# mpv open through mpv-single.exe - a PC-wide one (mpv-install.bat) gets the
# user's command over it, the user's own (mpv --register) is replaced - while a
# disc handler and another mpv's entry stay; a second run changes nothing;
# unregister puts back exactly what was there.
# ---------------------------------------------------------------------------
function Invoke-RegisterCheck([string]$t) {
    $base = 'HKCU:\Software\mpv-config-tests\single'
    $merged = "$base\merged" # what Windows reads: the PC's entries with the user's over them
    $user = "$base\user" # the user's own (HKCU\Software\Classes)
    $dir = Join-Path $WorkDir 'register'
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Force $dir
    foreach ($f in 'mpv-single-register.ps1', 'mpv-single-unregister.ps1') { Copy-Item -LiteralPath (Join-Path $RepoRoot $f) $dir }
    Set-Content -LiteralPath (Join-Path $dir 'mpv-single.exe') '' # register only checks that it is there
    $mpv = Join-Path $dir 'mpv.exe'
    $launcher = '"' + (Join-Path $dir 'mpv-single.exe') + '" "%1"'
    $pcCommand = "`"$mpv`"  -- `"%L`"" # mpv-install.bat's, its two spaces included
    $userCommand = "`"$mpv`" -- `"%L`"" # mpv --register's
    $set = {
        param([string]$Root, [string]$Name, [string]$Verb, [string]$Command)
        $key = "$Root\$Name\shell\$Verb\command"
        $null = New-Item -Path $key -Force
        Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $Command
    }
    $get = {
        param([string]$Root, [string]$Name, [string]$Verb, [string]$Value = '')
        $key = Get-Item -LiteralPath "$Root\$Name\shell\$Verb\command" -ErrorAction SilentlyContinue
        if ($key -and $key.GetValueNames() -contains $Value) { "$($key.GetValue($Value))" }
    }
    $ps51 = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source
    $shell = $ps51 ? $ps51 : (Get-Process -Id $PID).Path
    $run = {
        param([string]$Script, [string[]]$More)
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir $Script) -ClassesRoot $user @More 2>&1 | Out-String
        @{ Code = $LASTEXITCODE; Out = $out.Trim() }
    }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    try {
        foreach ($verb in 'play', 'open') { & $set $merged 'io.mpv.mp3' $verb $pcCommand }
        & $set $merged 'Applications\mpv.exe' 'play' $pcCommand
        & $set $merged 'io.mpv.dvd' 'play' "`"$mpv`" dvd:// --dvd-device=`"%L`""
        & $set $merged 'io.mpv.mkv' 'play' "`"C:\Other mpv\mpv.exe`" -- `"%L`""
        foreach ($root in $merged, $user) { & $set $root 'io.mpv.file' 'open' $userCommand }
        foreach ($root in $merged, $user) { & $set $root 'io.mpv.wav' 'open' $userCommand }
        # another program in a type's Open with: it stays when unregister has gone
        $null = New-Item -Path "$user\.mkv\OpenWithProgids" -Force
        Set-ItemProperty -LiteralPath "$user\.mkv\OpenWithProgids" -Name 'Other.File' -Value ''

        $r = & $run 'mpv-single-register.ps1' @('-MergedRoot', $merged, '-Quiet')
        Test-Check $t 'mpv-single-register.ps1 runs' ($r.Code -eq 0) $r.Out
        Test-Check $t "... a PC-wide mpv file type opens through mpv-single.exe, both verbs (the user's command over it)" (
            (& $get $user 'io.mpv.mp3' 'play') -eq $launcher -and (& $get $user 'io.mpv.mp3' 'open') -eq $launcher -and
            (& $get $user 'io.mpv.mp3' 'play' 'mpv-single-was') -eq '') "play: $(& $get $user 'io.mpv.mp3' 'play')"
        Test-Check $t '... so does Open with > mpv' ((& $get $user 'Applications\mpv.exe' 'play') -eq $launcher) "$(& $get $user 'Applications\mpv.exe' 'play')"
        Test-Check $t "... and the user's own (mpv --register), its command kept for the way back" (
            (& $get $user 'io.mpv.file' 'open') -eq $launcher -and (& $get $user 'io.mpv.file' 'open' 'mpv-single-was') -eq $userCommand) `
            "$(& $get $user 'io.mpv.file' 'open') / was $(& $get $user 'io.mpv.file' 'open' 'mpv-single-was')"
        Test-Check $t "... a disc handler and another mpv's file type stay as they are" (
            -not (Test-Path -LiteralPath "$user\io.mpv.dvd") -and -not (Test-Path -LiteralPath "$user\io.mpv.mkv")) ''
        Test-Check $t "... and 'mpv (single instance)' is in Open with" (
            (Get-ItemProperty -LiteralPath "$user\.mp3\OpenWithProgids" -Name 'mpv-single.File' -ErrorAction SilentlyContinue) -and
            (& $get $user 'mpv-single.File' 'open') -eq $launcher) ''

        # the user's commands as Windows would read them now, then a second run
        & $set $merged 'io.mpv.file' 'open' $launcher
        $r = & $run 'mpv-single-register.ps1' @('-MergedRoot', $merged, '-Quiet')
        Test-Check $t '... run again, it keeps the commands it kept the first time' (
            $r.Code -eq 0 -and (& $get $user 'io.mpv.file' 'open' 'mpv-single-was') -eq $userCommand -and
            (& $get $user 'io.mpv.mp3' 'play' 'mpv-single-was') -eq '') $r.Out

        # another mpv registered since (mpv --register from its own folder): its command, our note
        $otherCommand = "`"C:\Other mpv\mpv.exe`" -- `"%L`""
        Set-ItemProperty -LiteralPath "$user\io.mpv.wav\shell\open\command" -Name '(default)' -Value $otherCommand

        $r = & $run 'mpv-single-unregister.ps1' @()
        Test-Check $t 'mpv-single-unregister.ps1 runs' ($r.Code -eq 0) $r.Out
        Test-Check $t "... leaves an entry another mpv registered since as that mpv's, only its note gone" (
            (& $get $user 'io.mpv.wav' 'open') -eq $otherCommand -and $null -eq (& $get $user 'io.mpv.wav' 'open' 'mpv-single-was')) `
            "$(& $get $user 'io.mpv.wav' 'open') / was $(& $get $user 'io.mpv.wav' 'open' 'mpv-single-was')"
        Test-Check $t '... the commands over the PC-wide entries are gone' (
            -not (Test-Path -LiteralPath "$user\io.mpv.mp3") -and -not (Test-Path -LiteralPath "$user\Applications\mpv.exe")) ''
        Test-Check $t "... the user's own entry has its command back" (
            (& $get $user 'io.mpv.file' 'open') -eq $userCommand -and $null -eq (& $get $user 'io.mpv.file' 'open' 'mpv-single-was')) `
            "$(& $get $user 'io.mpv.file' 'open')"
        Test-Check $t "... and 'mpv (single instance)' is gone" (
            -not (Test-Path -LiteralPath "$user\mpv-single.File") -and
            -not (Get-ItemProperty -LiteralPath "$user\.mp3\OpenWithProgids" -Name 'mpv-single.File' -ErrorAction SilentlyContinue)) ''
        # register made a key for every type that had none; they went with it
        $typeKeys = @(Get-ChildItem -LiteralPath $user | Where-Object PSChildName -Like '.*' | ForEach-Object PSChildName)
        Test-Check $t '... with the type keys it made, and another program in a type''s Open with kept' (
            ($typeKeys -join ',') -eq '.mkv' -and
            $null -ne (Get-ItemProperty -LiteralPath "$user\.mkv\OpenWithProgids" -Name 'Other.File' -ErrorAction SilentlyContinue)) "type keys left: $($typeKeys -join ', ')"
    }
    finally {
        Remove-Item -LiteralPath 'HKCU:\Software\mpv-config-tests' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
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
    # log and learned cases an older config left behind, the watch history, or a damaged
    # state file kept aside: they hold real viewing)
    $dst = Join-Path $root 'portable_config'
    & robocopy $Cfg $dst /MIR /XD cache watch_later /XF speed.json stream-resume.json shader-misses.log shader-cases.json settings.json upscale.json welcome.json watch_history.jsonl '*.corrupt-*' '*.tmp' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
    # /MIR leaves an excluded file alone: one copied by an older run goes here
    Get-ChildItem -LiteralPath $dst -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'watch_history.jsonl' -or $_.Name -like '*.corrupt-*' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
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
    param([string]$Exe, [string]$Path, [string]$Size, [int]$Seconds, [string]$Codec = 'libx264', [string]$PixFmt = 'yuv420p', [int]$Rate = 24)
    if (Test-Path -LiteralPath $Path) { return }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    # the container follows $Path's extension (mpv picks the muxer by it: .mkv, .ts)
    $tmp = Join-Path (Split-Path -Parent $Path) ('encoding-' + [guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($Path))
    $opts = $Codec -eq 'libx264' ? "preset=ultrafast,g=$Rate" : 'preset=ultrafast'
    $r = Invoke-Mpv $Exe @('--no-config', '--really-quiet', "av://lavfi:testsrc2=size=${Size}:rate=${Rate}:duration=$Seconds,format=$PixFmt",
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
    # faststream-quality.lua: one video in two sizes, as a stream's own qualities. two.edl
    # makes them editions the way ytdl_hook makes YouTube's formats (one program_id each,
    # titled like yt-dlp's format names), master.m3u8 an HLS master over MPEG-TS copies
    # (lavf makes its variants editions), and the test adds v360.ts to another clip as a
    # second video track (variants mpv lists as tracks). Loaded by their .edl/.m3u8 names,
    # for which autoload.lua queues no neighbours.
    $variants = Join-Path $m 'variants'
    # 360p at 60 fps: its rows are named 360p60, its badge only fits 360p
    foreach ($v in @(@{ Size = '320x180'; Rate = 24 }, @{ Size = '640x360'; Rate = 60 })) {
        $size = $v.Size
        $height = $size.Split('x')[1]
        Initialize-Clip $Exe (Join-Path $variants "v$height.mkv") $size 20 -Rate $v.Rate
        Initialize-Clip $Exe (Join-Path $variants "v$height.ts") $size 20 -Rate $v.Rate
        [IO.File]::WriteAllText((Join-Path $variants "v$height.m3u8"), ("#EXTM3U`n#EXT-X-VERSION:3`n#EXT-X-TARGETDURATION:20`n" +
                "#EXT-X-MEDIA-SEQUENCE:0`n#EXT-X-PLAYLIST-TYPE:VOD`n#EXTINF:20.0,`nv$height.ts`n#EXT-X-ENDLIST`n"))
    }
    [IO.File]::WriteAllText((Join-Path $variants 'master.m3u8'), ("#EXTM3U`n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360`nv360.m3u8`n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180`nv180.m3u8`n"))
    $edl = "# mpv EDL v0`n"
    foreach ($v in @(@{ Id = 0; Title = '134 - 640x360 (360p60)'; File = 'v360.mkv' }, @{ Id = 1; Title = '160 - 320x180 (180p)'; File = 'v180.mkv' })) {
        $edl += "!new_stream`n!no_clip`n!track_meta,title=%$($v.Title.Length)%$($v.Title),program_id=$($v.Id)`n$($v.File)`n"
    }
    [IO.File]::WriteAllText((Join-Path $variants 'two.edl'), $edl)
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
    # the same video with its subtitle only in a sub\ folder beside it (sub-file-paths)
    $folderSrt = Join-Path $m 'subs-folder/sub/movie.srt'
    if (-not (Test-Path -LiteralPath $folderSrt)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $folderSrt) | Out-Null
        Copy-Item -LiteralPath (Join-Path $m 'subs/movie.mkv') (Join-Path $m 'subs-folder/movie.mkv')
        Copy-Item -LiteralPath $srt $folderSrt
    }
    $ep = Join-Path $m 'fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'
    Initialize-Clip $Exe $ep 320x180 120
    $token2 = Join-Path $m 'fs-anime-token2/ep1-newtoken#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'
    if (-not (Test-Path -LiteralPath $token2)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $token2) | Out-Null
        Copy-Item -LiteralPath $ep -Destination $token2
    }
    # stream-resume: the episode sent from a private window (fs-private=1), which keeps nothing.
    $privateEp = Join-Path $m 'fs-private/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718&fs-private=1&fs-page=x.mkv'
    if (-not (Test-Path -LiteralPath $privateEp)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $privateEp) | Out-Null
        Copy-Item -LiteralPath $ep -Destination $privateEp
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
        # a track number and a title only, and a band whose name is a number
        @{ Path = 'music-numbered/07 - Quiet Harbor.flac'; Codec = 'flac' }
        @{ Path = 'music-band-number/311 - Amber.flac'; Codec = 'flac' }
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
    foreach ($f in 'speed.json', 'stream-resume.json', 'stream-resume.json.tmp', 'shader-misses.log', 'movie-sharpness.json',
        'settings.json', 'upscale.json', 'welcome.json') {
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
        # the first-start welcome banner (welcome.lua) would show in every test: off unless a phase turns it on
        $mpvArgs = @("--script=$script", "--log-file=$log", '--no-terminal', '--script-opts-append=welcome-auto=no') +
        $ExtraArgs + @($ph.ContainsKey('Args') ? $ph.Args : @()) + $fileArgs
        # MPV_TEST_PHASE: a test that runs the same script in several processes tells them apart by it
        $vars = @{
            MPV_TEST_MEDIA = $Media.Replace('\', '/'); MPV_TEST_ROOT = $root.Replace('\', '/'); MPV_TEST_TIMEOUT = $TimeoutSeconds - 10
            MPV_TEST_PHASE = $ph.ContainsKey('Phase') ? $ph.Phase : ''
        }
        # a phase's own Env goes to its mpv too (ytdl-node: a LOCALAPPDATA of its own)
        if ($ph.ContainsKey('Env')) { foreach ($k in $ph.Env.Keys) { $vars[$k] = $ph.Env[$k] } }
        $r = Invoke-Mpv $Exe $mpvArgs $vars -TimeoutSeconds $TimeoutSeconds
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
        if (Test-GpuLost $Test.Name $label $log) { return }
        if ($ph.ContainsKey('After')) { & $ph.After $Test.Name $label }
    }
}

# A lost GPU device is a driver reset: no further run may follow it (on
# 2026-10-12 a series of them crashed Windows). True, with a FAIL, when the
# run's log shows one; Get-GpuTrouble then stops every later GPU run.
$script:GpuLost = $null
function Test-GpuLost([string]$Name, [string]$Label, [string]$Log) {
    if (-not (Test-Path -LiteralPath $Log)) { return $false }
    $lost = Select-String -LiteralPath $Log -Pattern 'DEVICE_LOST|DEVICE_REMOVED|887a0005|887a0006' | Select-Object -First 1
    if (-not $lost) { return $false }
    $script:GpuLost = $lost.Line.Trim()
    Add-Result $Name "${Label}the GPU device was not lost" 'FAIL' $script:GpuLost
    return $true
}

# Why the GPU must not be used for another run, or $null.
function Get-GpuTrouble {
    if ($script:GpuLost) { return "the GPU device was lost in an earlier run ($script:GpuLost)" }
    $bad = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
    if ($bad.Count) { return ($bad | ForEach-Object { "$($_.FriendlyName) is $($_.Status) ($($_.Problem))" }) -join '; ' }
    return $null
}

# For the gpu tier: false (and a SKIP) when the GPU is not fit for the next run.
function Test-GpuFit([string]$Name) {
    $why = Get-GpuTrouble
    if ($why) { Add-Result $Name 'gpu run' 'SKIP' "$why - no further GPU run" }
    return -not $why
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

# settings: before the third process, the test root becomes a PC that ran this config
# before settings.lua existed - no settings.json, a speed.json (remember-speed.lua)
$MakeLegacyPc = {
    $cfgDir = Join-Path $root 'portable_config'
    Remove-Item -LiteralPath (Join-Path $cfgDir 'settings.json') -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $cfgDir 'speed.json') '{"speed":1}' -NoNewline
}

# settings: before the fourth process, a settings.json from before 2026-10-12, with the
# old Buffering choice (2 GB, as the owner had it)
$MakeOldBufferPc = {
    $cfgDir = Join-Path $root 'portable_config'
    Set-Content -LiteralPath (Join-Path $cfgDir 'settings.json') -NoNewline `
        '{"slang":"de,en","alang":"de,en","hdr_peak":350,"buffer":"xlarge","buffer_wait":3}'
}

# settings: before the fifth process, a settings.json that is no JSON. It counted as no
# file yet, and the defaults went over it without a word (#96): it is kept beside now.
$DamageSettingsFile = {
    Set-Content -LiteralPath (Join-Path $root 'portable_config/settings.json') -NoNewline '{"slang":"de,en", broken'
}

# ytdl-node: a LOCALAPPDATA of the test's own, first without the one-click install's private
# node.exe, then (after the first process) with a stand-in for it
$FakeLocalAppData = Join-Path $WorkDir 'localappdata'
Remove-Item -LiteralPath $FakeLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $FakeLocalAppData | Out-Null
$MakePrivateNode = {
    $dir = Join-Path $FakeLocalAppData 'FastStreamMpvHost\node'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'node.exe') 'a stand-in' -NoNewline
}

# welcome: the third process is a first start again, with no file
$ForgetWelcome = {
    Remove-Item -LiteralPath (Join-Path $root 'portable_config/welcome.json') -ErrorAction SilentlyContinue
}

# stream-resume: a damaged state file (not JSON). Every save skipped it, so resuming had
# ended for every stream for good (2026-10-10 review): the next save keeps it beside and
# writes a new one.
$DamageResumeFile = {
    Set-Content -LiteralPath (Join-Path $root 'portable_config/stream-resume.json') '{"a1b2c3d4e5f60718": {"pos": 4' -NoNewline
}
$ResumeSavedAnew = {
    param($Name, $Label)
    $cfgDir = Join-Path $root 'portable_config'
    $saved = try { Get-Content -Raw -LiteralPath (Join-Path $cfgDir 'stream-resume.json') | ConvertFrom-Json } catch { $null }
    $pos = if ($saved) { $saved.'a1b2c3d4e5f60718'.pos } else { $null }
    Add-Result $Name "${Label}a damaged stream-resume.json: the position is saved anew" `
    $(if ($pos -ge 39 -and $pos -le 41) { 'PASS' } else { 'FAIL' }) "saved: $pos"
    $aside = @(Get-ChildItem -LiteralPath $cfgDir -Filter 'stream-resume.json.corrupt-*')
    Add-Result $Name "${Label}... and the damaged file is kept beside it" $(if ($aside.Count) { 'PASS' } else { 'FAIL' }) ''
    $aside | Remove-Item
}

$HeadlessTests = @(
    @{ Name = 'mouse'; Phases = @(@{ Script = 'headless/test-mouse.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'notify'; Phases = @(@{ Script = 'headless/test-notify.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'notify-render'; Phases = @(@{ Script = 'headless/test-notify-render.lua'; File = $RealOsdClip; Args = $RealOsd }) }
    # a window narrower than a banner: the same surface, 320 pixels wide
    @{ Name = 'notify-narrow'; Phases = @(@{ Script = 'headless/test-notify-narrow.lua'; File = $RealOsdClip
            Args = $RealOsd + @('--vo-sixel-cols=40', '--vo-sixel-rows=5', '--vo-sixel-width=320', '--vo-sixel-height=300')
        })
    }
    # an OSD surface for the banner's box (the click's target); 2 frames a second, so sixel
    # writes little while the clips play
    @{ Name = 'single-instance'; Phases = @(@{ Script = 'headless/test-single-instance.lua'; File = 'plain/clip.mkv'
            Args = $RealOsd + @('--vf=fps=2', '--script-opts-append=single_instance-banner_seconds=2')
        })
    }
    @{ Name = 'bottom-bar'; Phases = @(@{ Script = 'headless/test-bottom-bar.lua'; File = 'subs/movie.mkv' }) }
    @{ Name = 'video-info'; Phases = @(@{ Script = 'headless/test-video-info.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'source-info'; Phases = @(@{ Script = 'headless/test-source-info.lua'; File = 'plain/clip.mkv'; Args = @('--script-opts-append=source_info-launch=no') }) }
    # test_local: its entries are local stems (no scheme), which only the tests take
    @{ Name = 'faststream-quality'; Phases = @(
            @{ Script = 'headless/test-faststream-quality.lua'; File = 'plain/clip.mkv'; Args = @('--script-opts-append=faststream_quality-test_local=yes') }
            # the stream's own qualities: HLS and EDL editions, video tracks (media's variants/)
            @{ Script = 'headless/test-faststream-quality.lua'; File = 'plain/clip.mkv'; Phase = 'variants' }
            # uosc started late: no scripts but the quality button's, uosc loaded after 2 s
            @{ Script = 'headless/test-faststream-quality.lua'; File = 'plain/clip.mkv'; Phase = 'late-uosc'; Args = @('--load-scripts=no', '--script=~~/Scripts/faststream-quality.lua', '--script-opts-append=faststream_quality-test_local=yes') })
    }
    @{ Name = 'music-info'; Phases = @(@{ Script = 'headless/test-music-info.lua'; File = 'music-tagged/Nova Lane - Paper Lanterns.mp3' }) }
    @{ Name = 'keys'; Phases = @(@{ Script = 'headless/test-keys.lua'; File = 'long/long.mkv' }) }
    @{ Name = 'faststream-episodes'; Phases = @(
            @{ Script = 'headless/test-faststream-episodes.lua'; File = 'plain/clip.mkv'; Args = @('--script-opts-append=faststream_episodes-heartbeat_stale=2') }
            # the script alone, no uosc: its buttons must not be shown before uosc has them
            @{ Script = 'headless/test-faststream-episodes-no-uosc.lua'; File = 'fs-movie/film#fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv'
                Args = @('--load-scripts=no', '--script=~~/Scripts/faststream-episodes.lua')
            })
    }
    @{ Name = 'speed'; Phases = @(@{ Script = 'headless/test-speed.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'remember-speed'; Phases = @(
            @{ Script = 'headless/test-remember-speed-save.lua'; File = 'plain/clip.mkv' }
            @{ Script = 'headless/test-remember-speed-restore.lua'; File = 'plain/clip.mkv' }
            @{ Script = 'headless/test-remember-speed-first-load.lua'; File = 'plain/clip.mkv' })
    }
    @{ Name = 'auto-start'; Phases = @(@{ Script = 'headless/test-auto-start.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'pause-flash'; Phases = @(@{ Script = 'headless/test-pause-flash.lua'; File = 'plain/clip.mkv' }) }
    # an OSD surface: uosc lays out (and publishes user-data/uosc/bottom-ui) only with one; a
    # sound track, or uosc draws no volume slider
    @{ Name = 'ui-hover'; Phases = @(@{ Script = 'headless/test-ui-hover.lua'; File = $RealOsdClip
            Args = $RealOsd + @('--audio-file=av://lavfi:sine=frequency=440:duration=120')
        })
    }
    # the same OSD surface; the sound track gives the volume key a slider to flash instead
    @{ Name = 'seek-flash'; Phases = @(@{ Script = 'headless/test-seek-flash.lua'; File = $RealOsdClip
            Args = $RealOsd + @('--audio-file=av://lavfi:sine=frequency=440:duration=120')
        })
    }
    @{ Name = 'source-info-idle'; Phases = @(@{ Script = 'headless/test-source-idle.lua'; File = $null }) }
    @{ Name = 'subtitles'; Phases = @(@{ Script = 'headless/test-subtitles.lua'; File = 'subs/movie.mkv' }) }
    @{ Name = 'subtitle-folder'; Phases = @(@{ Script = 'headless/test-subtitle-folder.lua'; File = 'subs-folder/movie.mkv' }) }
    @{ Name = 'subtitle-sync'; Phases = @(@{ Script = 'headless/test-subtitle-sync.lua'; File = 'sync/talk.mkv' }) }
    @{ Name = 'subtitle-sync-retry'; Phases = @(@{ Script = 'headless/test-subtitle-sync-retry.lua'; File = 'sync/talk.mkv' }) }
    @{ Name = 'subtitle-sync-lanes'; Phases = @(@{ Script = 'headless/test-subtitle-sync-lanes.lua'; File = 'sync/talk.mkv' }) }
    @{ Name = 'menus'; Phases = @(@{ Script = 'headless/test-menus.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'autoload'; Phases = @(@{ Script = 'headless/test-autoload.lua'; File = 'autoload/episode1.mkv' }) }
    @{ Name = 'upscale'; Phases = @(@{ Script = 'headless/test-upscale.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'sharpness-memory'; Phases = @(
            @{ Script = 'headless/test-sharpness-save.lua'; File = 'plain/clip.mkv' }
            @{ Script = 'headless/test-sharpness-restore.lua'; File = 'plain/clip.mkv' })
    }
    @{ Name = 'config'; Phases = @(@{ Script = 'headless/test-config.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'state-file'; Phases = @(@{ Script = 'headless/test-state-file.lua'; File = 'plain/clip.mkv' }) }
    @{ Name = 'settings'; Phases = @(
            @{ Script = 'headless/test-settings.lua'; File = 'plain/clip.mkv'; Phase = 'new' }
            @{ Script = 'headless/test-settings.lua'; File = 'plain/clip.mkv'; Phase = 'restored'; After = $MakeLegacyPc }
            @{ Script = 'headless/test-settings.lua'; File = 'plain/clip.mkv'; Phase = 'legacy'; After = $MakeOldBufferPc }
            @{ Script = 'headless/test-settings.lua'; File = 'plain/clip.mkv'; Phase = 'migrated'; After = $DamageSettingsFile }
            @{ Script = 'headless/test-settings.lua'; File = 'plain/clip.mkv'; Phase = 'damaged' })
    }
    @{ Name = 'ytdl-node'; Phases = @(
            @{ Script = 'headless/test-ytdl-node.lua'; File = 'plain/clip.mkv'; Phase = 'none'; Env = @{ LOCALAPPDATA = $FakeLocalAppData }; After = $MakePrivateNode }
            @{ Script = 'headless/test-ytdl-node.lua'; File = 'plain/clip.mkv'; Phase = 'private'; Env = @{ LOCALAPPDATA = $FakeLocalAppData } })
    }
    @{ Name = 'stream-buffer'; Phases = @(
            @{ Script = 'headless/test-stream-buffer.lua'; File = 'plain/clip.mkv'; Phase = 'stream'; Args = @('--script-opts-append=stream_buffer-local_is_stream=yes', '--script-opts-append=stream_buffer-headroom_mb=0') }
            @{ Script = 'headless/test-stream-buffer.lua'; File = 'plain/clip.mkv'; Phase = 'local' })
    }
    @{ Name = 'screens'; Phases = @(
            @{ Script = 'headless/test-screens.lua'; File = 'plain/clip.mkv'; Phase = 'first' }
            @{ Script = 'headless/test-screens.lua'; File = 'plain/clip.mkv'; Phase = 'again' })
    }
    @{ Name = 'welcome'; Phases = @(
            @{ Script = 'headless/test-welcome.lua'; File = 'plain/clip.mkv'; Phase = 'first'; Args = @('--script-opts-append=welcome-auto=yes') }
            @{ Script = 'headless/test-welcome.lua'; File = 'plain/clip.mkv'; Phase = 'again'; Args = @('--script-opts-append=welcome-auto=yes'); After = $ForgetWelcome }
            @{ Script = 'headless/test-welcome.lua'; File = $null; Phase = 'idle'; Args = @('--script-opts-append=welcome-auto=yes') })
    }
    @{ Name = 'stream-resume'; Phases = @(
            @{ Script = 'headless/test-stream-resume-save.lua'; File = 'fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv' }
            @{ Script = 'headless/test-stream-resume-restore.lua'; File = 'fs-anime-token2/ep1-newtoken#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'; After = $DamageResumeFile }
            @{ Script = 'headless/test-stream-resume-save.lua'; File = 'fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'; After = $ResumeSavedAnew })
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
    # installer/check-keys.ps1 (2026-10-12): asks every running mpv over its
    # IPC pipe which keys it uses. Two test mpvs on pipes of their own (never FastStream's):
    # one with this setup's config, one with --no-config; in Windows PowerShell 5.1, which
    # check-keys.bat uses on a PC without PowerShell 7.
    if ('check-keys' -like $Filter) {
        Write-Host ''
        Write-Host '-- check-keys' -ForegroundColor White
        $own = "mpv-regression-keys-own-$PID"
        $bare = "mpv-regression-keys-bare-$PID"
        $procs = @(
            (Start-Process $exe -PassThru -WindowStyle Hidden -ArgumentList '--vo=null', '--ao=null', '--idle=yes', $ShaderCacheOff,
                '--script-opts-append=welcome-auto=no', "--input-ipc-server=\\.\pipe\$own"),
            (Start-Process $exe -PassThru -WindowStyle Hidden -ArgumentList '--no-config', '--vo=null', '--ao=null', '--idle=yes',
                "--input-ipc-server=\\.\pipe\$bare"))
        try {
            $ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
            $shell = $ps51 ? $ps51.Source : (Get-Process -Id $PID).Path
            $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'installer/check-keys.ps1') -Root (Split-Path -Parent $exe) 2>&1 | Out-String
            $blocks = $out -split 'Asking '
            $ownBlock = ($blocks | Where-Object { $_ -like "*$own*" }) -join ''
            $bareBlock = ($blocks | Where-Object { $_ -like "*$bare*" }) -join ''
            Test-Check 'check-keys' "check-keys.ps1: an mpv with this setup's config has this setup's keys" (
                $ownBlock -match "VERDICT: this mpv has this setup's keys") ($ownBlock.Trim() -replace '\s+', ' ')
            Test-Check 'check-keys' 'check-keys.ps1: an mpv started with --no-config has the standard keys, and says why' (
                $bareBlock -match 'without config files \(--no-config\)') ($bareBlock.Trim() -replace '\s+', ' ')
        }
        finally {
            $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($test in $HeadlessTests | Where-Object { $_.Name -like $Filter }) {
        Invoke-RuntimeTest $exe $media $test @('--vo=null', '--ao=null', $ShaderCacheOff)
    }
    if ('mpv-single' -like $Filter) { Invoke-LauncherCheck $exe $media }
}

if ($RunGpu) {
    Write-Section 'gpu tests (real renderer, fullscreen)'
    $running = @(Get-Process mpv -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Add-Result 'gpu' 'gpu tier' 'SKIP' "mpv is running (pid $($running.Id -join ', ')) - you may be watching; close it and re-run"
    }
    elseif (-not (Test-GpuFit 'gpu')) {}
    else {
        $cacheCopy = Join-Path $WorkDir 'gpu-cache'
        Remove-Item -Recurse -Force $cacheCopy -ErrorAction SilentlyContinue
        $realCache = Join-Path $Cfg 'cache'
        if (Test-Path $realCache) { Copy-Item $realCache $cacheCopy -Recurse } else { New-Item -ItemType Directory $cacheCopy | Out-Null }

        if ('gpu-warm-cache' -like $Filter -and (Test-GpuFit 'gpu-warm-cache')) {
            Write-Host ''
            Write-Host '-- gpu-warm-cache' -ForegroundColor White
            $warmLog = Join-Path $WorkDir 'logs/gpu-warm-cache.log'
            $warm = & (Join-Path $RepoRoot 'installer/warm-shader-cache.ps1') -MpvExe $exe -CacheDir $cacheCopy -Check -Quiet -LogFile $warmLog
            foreach ($line in $warm) {
                if ("$line" -match '^RESULT (PASS|FAIL|INFO) (.*?)(?: :: (.*))?$') {
                    Add-Result 'gpu-warm-cache' $Matches[2] $Matches[1] ($Matches[3] ?? '')
                }
            }
            $null = Test-GpuLost 'gpu-warm-cache' '' $warmLog
        }
        # Each one asked at its own start: in the foreach's pipeline every test was asked before
        # the first ran, and a device lost in one did not stop the next from rendering again.
        foreach ($test in @($GpuTests | Where-Object { $_.Name -like $Filter })) {
            if (-not (Test-GpuFit $test.Name)) { continue }
            Invoke-RuntimeTest $exe $media $test @('--fs', '--ao=null', "--gpu-shader-cache-dir=$cacheCopy", $ShaderCacheOff) -TimeoutSeconds 300
        }

        # The automatic warm-up for real: an EMPTY cache, the real renderer, the
        # warm-up in the background (~8 s, paused halfway), then a second start
        # that must be fresh.
        if ('gpu-auto-warm' -like $Filter -and (Test-GpuFit 'gpu-auto-warm')) {
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
