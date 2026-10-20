<#
.SYNOPSIS
    Runs the gpu tier on this PC against a pull request - its config and its mpv build -
    and sets the pull request's check "GPU tier (local)" to the result.

.DESCRIPTION
    CI has no GPU, so a pull request that changes the shaders, the renderer or decoder
    options, or an mpv build whose video output changed, carries the pending check
    "GPU tier (local)" (.github/scripts/gpu-flag.ps1). This settles it:

      1. refuses while any mpv runs (you may be watching), and for a commit that lost
         the GPU device here before (AGENTS.md: a device loss is reproduced at most
         once; -Force after deciding to try again);
      2. checks the pull request's commit out into a folder of its own under %TEMP%
         (a git worktree) and installs the mpv build its mpv-build.json pins there
         (installer\install-mpv.ps1): the mpv in this folder is not touched;
      3. warms that build's shader cache (installer\warm-shader-cache.ps1, hidden, as a PC
         does by itself after an update), then runs tests\run-tests.ps1 -Tier gpu there
         (static + headless + the real renderer, FULLSCREEN, about ten minutes: the screen
         shows test videos meanwhile);
      4. sets "GPU tier (local)" on that commit to success or failure, comments the
         result on the pull request, and removes the folder.

.PARAMETER Pr
    The pull request. Default: the one open pull request labelled gpu.

.PARAMETER Force
    Run although this commit lost the GPU device here before.

.PARAMETER Filter
    Only these tests (run-tests.ps1 -Filter), for a quick look again: such a run sets no
    check, since it does not cover the tier.

.EXAMPLE
    pwsh tests\try-gpu.ps1 -Pr 116
#>
param(
    [int]$Pr,
    [switch]$Force,
    [string]$Filter = '*'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Context = 'GPU tier (local)'
$Here = Join-Path $env:TEMP 'mpv-try-gpu'
# commits that lost the GPU device here, one file each
$LostDir = Join-Path $env:LOCALAPPDATA 'mpv-try-gpu\device-lost'

function Invoke-Gh([string[]]$Arguments) {
    $out = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed ($LASTEXITCODE)" }
    return $out
}
function Invoke-Git([string[]]$Arguments) {
    $out = & git -C $RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($out -join ' ')" }
    return $out
}

$running = @(Get-CimInstance Win32_Process -Filter "Name='mpv.exe'")
if ($running.Count) {
    Write-Host "An mpv runs (pid $($running.ProcessId -join ', ')): you may be watching. Close it and run this again." -ForegroundColor Yellow
    exit 1
}
$repo = Invoke-Gh @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
if (-not $Pr) {
    $open = @(Invoke-Gh @('pr', 'list', '--repo', $repo, '--state', 'open', '--label', 'gpu', '--json', 'number', '--jq', '.[].number'))
    if ($open.Count -ne 1) {
        Write-Host "Open pull requests labelled gpu: $(if ($open.Count) { $open -join ', ' } else { 'none' }). Name one: -Pr <number>." -ForegroundColor Yellow
        exit 1
    }
    $Pr = [int]$open[0]
}
$pull = Invoke-Gh @('api', "repos/$repo/pulls/$Pr") | ConvertFrom-Json
$sha = $pull.head.sha
$lostMark = Join-Path $LostDir $sha
if ((Test-Path -LiteralPath $lostMark) -and -not $Force) {
    Write-Host "Commit $($sha.Substring(0, 7)) of #$Pr lost the GPU device on this PC before ($(Get-Content -Raw -LiteralPath $lostMark)). A device loss is reproduced at most once: decide, then run again with -Force." -ForegroundColor Red
    exit 1
}

Write-Host "#$Pr ($($pull.title)), commit $($sha.Substring(0, 7))" -ForegroundColor White
Write-Host 'The gpu tier plays test videos FULLSCREEN for a few minutes. Leave the PC alone meanwhile.' -ForegroundColor Yellow

$wt = Join-Path $Here "pr-$Pr"
$work = Join-Path $Here 'work'
$log = Join-Path $Here "pr-$Pr-$($sha.Substring(0, 7)).log"
$null = New-Item -ItemType Directory -Force $Here
$lost = $null
try {
    if (Test-Path -LiteralPath $wt) { $null = & git -C $RepoRoot worktree remove --force $wt 2>&1 }
    # a folder deleted by hand leaves git's record of it, and the add below would refuse
    $null = Invoke-Git @('worktree', 'prune')
    $null = Invoke-Git @('fetch', '-q', 'origin', "pull/$Pr/head")
    $null = Invoke-Git @('worktree', 'add', '--detach', $wt, $sha)

    Write-Host '-- the mpv build it pins' -ForegroundColor White
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $wt 'installer\install-mpv.ps1') -Root $wt
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $wt 'mpv.exe'))) { throw "install-mpv.ps1 failed ($LASTEXITCODE)" }

    # The folder's cache is empty; the gpu tier checks the real one is warm, as mpv leaves it
    # after an update (it warms it by itself in the background).
    Write-Host '-- its shader cache' -ForegroundColor White
    & pwsh -NoProfile -File (Join-Path $wt 'installer\warm-shader-cache.ps1') -MpvExe (Join-Path $wt 'mpv.exe') -Quiet
    if ($LASTEXITCODE -ne 0) { throw "warm-shader-cache.ps1 failed ($LASTEXITCODE)" }

    Write-Host '-- run-tests.ps1 -Tier gpu' -ForegroundColor White
    & pwsh -NoProfile -File (Join-Path $wt 'tests\run-tests.ps1') -Tier gpu -Filter $Filter -MpvExe (Join-Path $wt 'mpv.exe') -WorkDir $work 2>&1 |
        Tee-Object -FilePath $log | Out-Host
    $text = Get-Content -Raw -LiteralPath $log
    $summary = [regex]::Match($text, '(\d+) passed, (\d+) failed, (\d+) skipped')
    $failedLines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+FAIL\s' } | ForEach-Object { $_.Trim() })
    $lost = $failedLines | Where-Object { $_ -match 'the GPU device was not lost' } | Select-Object -First 1
    if ($lost) {
        $null = New-Item -ItemType Directory -Force $LostDir
        Set-Content -LiteralPath $lostMark -Value "$(Get-Date -Format s): $lost"
    }
    $gpu = (Get-CimInstance Win32_VideoController | Select-Object -First 1)
    $where = "$($gpu.Name), driver $($gpu.DriverVersion)"
    $passed = $summary.Success -and [int]$summary.Groups[2].Value -eq 0 -and [int]$summary.Groups[1].Value -gt 0
    $result = if ($summary.Success) { "$($summary.Groups[1].Value) passed, $($summary.Groups[2].Value) failed" } else { 'no summary (the run broke off)' }
}
catch {
    $passed = $false
    $result = "did not run: $($_.Exception.Message)"
    $failedLines = @()
    $where = $env:COMPUTERNAME
}
finally {
    if (Test-Path -LiteralPath $wt) { $null = & git -C $RepoRoot worktree remove --force $wt 2>&1 }
}

if ($Filter -ne '*') {
    Write-Host ''
    Write-Host "#${Pr} -Filter ${Filter}: $result (no check set: not the whole tier)" -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    Write-Host "Log: $log"
    exit $(if ($passed) { 0 } else { 1 })
}
$state = if ($passed) { 'success' } else { 'failure' }
$description = "$result on $where"
if ($description.Length -gt 140) { $description = $description.Substring(0, 137) + '...' }
$null = Invoke-Gh @('api', '-X', 'POST', "repos/$repo/statuses/$sha", '-f', "state=$state", '-f', "context=$Context", '-f', "description=$description")
$body = @("**$Context**: $(if ($passed) { 'passed' } else { 'FAILED' }) on commit $($sha.Substring(0, 7)) - $result, on $where.")
if ($failedLines.Count) { $body += @('', '```', ($failedLines | Select-Object -First 30), '```') }
if ($lost) { $body += @('', 'The GPU device was lost: this commit is not run here again without `-Force` (a device loss is reproduced at most once).') }
$null = Invoke-Gh @('api', '-X', 'POST', "repos/$repo/issues/$Pr/comments", '-f', "body=$($body -join "`n")")
Write-Host ''
Write-Host "#${Pr}: $Context $state - $result" -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
Write-Host "Log: $log"
exit $(if ($passed) { 0 } else { 1 })
