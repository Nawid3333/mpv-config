#Requires -Version 7
<#
.SYNOPSIS
    Pre-compiles every upscale shader chain into mpv's shader cache, so no video
    ever waits for a shader compile.

.DESCRIPTION
    mpv (gpu-next/libplacebo) caches compiled shaders in portable_config/cache.
    A chain that is not in the cache yet costs up to ~0.3 s before its first
    frame. mpv checks this by itself at every start and, when the cache went
    stale, rebuilds it in the background while the video plays, with a small
    bar top right (portable_config/Scripts/shader-cache). This script runs the
    same warm-up on request, the same way: in a window that is never shown
    (Scripts/shader-cache/host.ps1), so nothing covers the screen or takes a
    key; progress shows here, Ctrl+C stops it. It steps through short generated
    clips in every combination the presets can hit (scale tiers, 8/10-bit,
    local-file and FastStream decode paths) with Off, Anime and Movie, and
    writes the stamp the startup check compares against.

    Fine to run while mpv plays; it only refuses while a player is warming the
    same cache. tests/run-tests.ps1 -Tier gpu runs it with -Check against a
    COPY of the cache to report whether the real cache is warm.

.PARAMETER MpvExe
    mpv.exe to use (the portable_config next to it is the config). Default: this repo's.

.PARAMETER CacheDir
    Shader cache folder. Default: mpv's own (portable_config/cache).

.PARAMETER Check
    Report instead of warm: exits 1 if any chain had to be compiled. Writes no stamp.

.PARAMETER Quiet
    Only emit the RESULT lines (used by the test runner).

.PARAMETER LogFile
    Also write mpv's full log (includes every compiled shader's source).
#>
[CmdletBinding()]
param(
    [string]$MpvExe,
    [string]$CacheDir,
    [switch]$Check,
    [switch]$Quiet,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $MpvExe) { $MpvExe = Join-Path $repo 'mpv.exe' }
if (-not (Test-Path -LiteralPath $MpvExe) -or (Get-Item -LiteralPath $MpvExe).Length -lt 1MB) { throw "$MpvExe is missing - run updater.bat (it installs the pinned build)." }

$config = Join-Path (Split-Path -Parent $MpvExe) 'portable_config'
$cache = $CacheDir ? $CacheDir : (Join-Path $config 'cache')
New-Item -ItemType Directory -Force $cache | Out-Null
# The same control files main.lua uses (fingerprint.lua): its lock is fresh
# for the warm-up timeout (270 s) + 60 s.
$lock = Join-Path $cache 'shader-warmup.lock'
$progressFile = Join-Path $cache 'shader-warmup.progress'
if ((Test-Path -LiteralPath $lock) -and ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds -lt 330) {
    Write-Output 'RESULT FAIL shader warm-up :: mpv is warming this shader cache right now - let it finish'
    exit 2
}

# The same process main.lua starts: only the scripts a warm-up needs.
$scripts = Join-Path $config 'Scripts'
$lines = @(
    $MpvExe, # host.ps1: line 1 is the exe, then one argument per line
    '--load-scripts=no',
    "--script=$(Join-Path $scripts 'gpu-toggles.lua')",
    "--script=$(Join-Path $scripts 'uosc')",
    "--script=$(Join-Path $scripts 'notify.lua')",
    "--script=$(Join-Path $scripts 'settings.lua')",
    "--script=$(Join-Path $scripts 'shader-cache/warmup.lua')",
    '--ao=null', '--force-window=yes', '--idle=yes', '--no-terminal', '--input-ipc-server=',
    "--script-opts-append=shader_warmup-check=$($Check ? 'yes' : 'no')",
    # it steps through the Movie sharpness levels: not the user's choice to remember
    '--script-opts-append=gpu_toggles-remember=no',
    '--script-opts-append=settings-write=no'
)
# Warming steps untimed (a stepped frame shows at once, ~5 ms instead of ~92);
# -Check keeps real playback timing, so it tests what a real video needs.
if (-not $Check) { $lines += '--untimed' }
if ($CacheDir) { $lines += "--gpu-shader-cache-dir=$CacheDir" }
if ($LogFile) { $lines += "--log-file=$LogFile" }
$argsFile = Join-Path ([IO.Path]::GetTempPath()) "mpv-shader-warmup-$PID.args"
[IO.File]::WriteAllLines($argsFile, [string[]]$lines, [Text.UTF8Encoding]::new($false))

# Windows PowerShell 5.1, as main.lua starts it (host.ps1 is written for it).
$psi = [System.Diagnostics.ProcessStartInfo]::new('powershell.exe')
foreach ($a in '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scripts 'shader-cache/host.ps1'), '-ArgsFile', $argsFile) {
    $psi.ArgumentList.Add($a)
}
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true

if (-not $Quiet) { Write-Host "$($Check ? 'Checking' : 'Compiling') shaders in the background (Ctrl+C stops) ..." }
$results = @()
$exitCode = 2
Set-Content -LiteralPath $lock -Value $PID
try {
    Remove-Item -LiteralPath $progressFile -ErrorAction SilentlyContinue
    $p = [System.Diagnostics.Process]::Start($psi)
    $read = $p.StandardOutput.ReadLineAsync()
    while ($true) {
        if (-not $read.Wait(250)) {
            # warmup.lua's progress: "<done> <total>", what it draws, its title
            $pl = if (-not $Quiet) { Get-Content -LiteralPath $progressFile -ErrorAction SilentlyContinue }
            if ($pl -and $pl[0] -match '^(\d+) (\d+)$' -and [int]$Matches[2] -gt 0) {
                $pct = [math]::Min(100, [int](100 * [int]$Matches[1] / [int]$Matches[2]))
                Write-Progress -Activity ($pl[2] ?? 'Compiling shaders') -Status "$pct %  $($pl[1])" -PercentComplete $pct
            }
            continue
        }
        $line = $read.Result
        if ($null -eq $line) { break } # the warm-up closed its output: it is exiting
        $read = $p.StandardOutput.ReadLineAsync()
        if ($line -notlike 'RESULT *') { continue }
        $results += $line
        if ($Quiet) { Write-Output $line }
        elseif ($line -like 'RESULT FAIL*') { Write-Host "  $line" -ForegroundColor Red }
        elseif ($line -notlike 'RESULT INFO*: 0 compiles' -and $line -notlike 'RESULT INFO warmed:*' -and $line -notlike 'RESULT INFO quick check:*') {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
    }
    $p.WaitForExit()
    $exitCode = $p.ExitCode
} finally {
    # also on Ctrl+C: the host goes with this console, and the warm-up with the host
    if (-not $Quiet) { Write-Progress -Activity 'Compiling shaders' -Completed }
    foreach ($f in $lock, $progressFile, $argsFile) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
}
if (-not $Quiet) {
    $summary = $results | Where-Object { $_ -match '^RESULT (PASS|FAIL) |warmed:' } | Select-Object -Last 1
    Write-Host ($summary ?? "the warm-up exited with $exitCode") -ForegroundColor ($exitCode ? 'Yellow' : 'Green')
}
exit $exitCode
