<#
.SYNOPSIS
    Runs the gpu tier on this PC against a pull request - its config and its mpv build -
    and sets the pull request's check "GPU tier (local)" to the result.

.DESCRIPTION
    CI has no GPU, so a pull request that changes the shaders, the renderer or decoder
    options, or an mpv build whose video output changed, carries the pending check
    "GPU tier (local)" (.github/scripts/gpu-flag.ps1). This settles it:

      1. refuses while any mpv runs (you may be watching), after any commit lost the GPU
         device here or a run on the GPU never finished (AGENTS.md: a device loss is
         reproduced at most once; -Force after deciding to try again), and for a fork's
         pull request unless -TrustFork;
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
    Run although a commit lost the GPU device here before, or a run on the GPU never
    finished (a crash, a black screen): it clears those marks.

.PARAMETER TrustFork
    Run a pull request from a fork: its own installer, warm-up and suite run on this PC.

.PARAMETER Filter
    Only these tests (run-tests.ps1 -Filter), for a quick look again: such a run sets no
    check, since it does not cover the tier.

.EXAMPLE
    pwsh tests\try-gpu.ps1 -Pr 116
#>
param(
    [int]$Pr,
    [switch]$Force,
    [switch]$TrustFork,
    [string]$Filter = '*'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Context = 'GPU tier (local)'
$Here = Join-Path $env:TEMP 'mpv-try-gpu'
# commits that lost the GPU device here, one file each, and `running` while a run is on the
# GPU: either stops the next run until -Force (a device loss is reproduced at most once)
$LostDir = Join-Path $env:LOCALAPPDATA 'mpv-try-gpu\device-lost'
$runningMark = Join-Path $LostDir 'running'

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

# The pull request's status and comment are public (AGENTS.md, "Public repository"), and a
# failed check's detail names its log under %TEMP%, inside the user folder: what leaves
# this PC goes through ConvertTo-PublicText first.
. (Join-Path $PSScriptRoot 'lib/privacy.ps1')
$privateWords = @()
$wordsFile = & git -C $RepoRoot rev-parse --path-format=absolute --git-path info/private-words 2>$null
if ($wordsFile -and (Test-Path -LiteralPath $wordsFile)) { $privateWords = @(Get-Content -LiteralPath $wordsFile) }

$running = @(Get-CimInstance Win32_Process -Filter "Name='mpv.exe'")
if ($running.Count) {
    Write-Host "An mpv runs (pid $($running.ProcessId -join ', ')): you may be watching. Close it and run this again." -ForegroundColor Yellow
    exit 1
}
# This clone's repository, wherever the script is started from
Push-Location $RepoRoot
try { $repo = Invoke-Gh @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner') }
finally { Pop-Location }
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
# A fork's pull request runs its own installer, warm-up and suite on this PC, logged in to
# gh and git: only when asked, after reading what it changes.
if ($pull.head.repo.full_name -ne $repo -and -not $TrustFork) {
    Write-Host "#$Pr comes from $($pull.head.repo.full_name), not ${repo}: its scripts would run here. Read its changes, then run again with -TrustFork." -ForegroundColor Red
    exit 1
}
$lostMark = Join-Path $LostDir $sha
# Any commit's loss, not only this one's: the next build of the rolling update pull request
# is a new commit with the same change.
$marks = @(Get-ChildItem -LiteralPath $LostDir -File -ErrorAction SilentlyContinue)
if ($marks.Count -and -not $Force) {
    foreach ($mark in $marks) {
        $what = if ($mark.Name -eq 'running') { 'a GPU run that never finished (a crash, a black screen?)' } else { "commit $($mark.Name.Substring(0, 7)) lost the GPU device" }
        Write-Host "$what - $(Get-Content -Raw -LiteralPath $mark.FullName)" -ForegroundColor Red
    }
    Write-Host 'A device loss is reproduced at most once: decide, then run again with -Force (it clears these).' -ForegroundColor Red
    exit 1
}
if ($Force) { $marks | Remove-Item -Force }

Write-Host "#$Pr ($($pull.title)), commit $($sha.Substring(0, 7))" -ForegroundColor White
Write-Host 'The gpu tier plays test videos FULLSCREEN for a few minutes. Leave the PC alone meanwhile.' -ForegroundColor Yellow

$wt = Join-Path $Here "pr-$Pr"
$work = Join-Path $Here 'work'
$log = Join-Path $Here "pr-$Pr-$($sha.Substring(0, 7)).log"
$null = New-Item -ItemType Directory -Force $Here
$lost = $null
$notRun = @()
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
    # From here on the GPU renders: the mark stays if this run never ends (a crash, a black
    # screen and a reboot) or loses the device, and stops the next run.
    $null = New-Item -ItemType Directory -Force $LostDir
    Set-Content -LiteralPath $runningMark -Value "$(Get-Date -Format s): #$Pr, commit $($sha.Substring(0, 7))"
    Write-Host '-- its shader cache' -ForegroundColor White
    $warmLog = Join-Path $Here "pr-$Pr-warm.log"
    & pwsh -NoProfile -File (Join-Path $wt 'installer\warm-shader-cache.ps1') -MpvExe (Join-Path $wt 'mpv.exe') -Quiet -LogFile $warmLog
    $warmCode = $LASTEXITCODE
    # the empty cache's warm-up is the riskiest run, and it was not looked at
    if ((Test-Path -LiteralPath $warmLog) -and (Select-String -LiteralPath $warmLog -Pattern 'DEVICE_LOST|DEVICE_REMOVED|887a000[56]' -Quiet)) {
        $lost = 'the shader warm-up lost the GPU device'
        Set-Content -LiteralPath $lostMark -Value "$(Get-Date -Format s): $lost"
        throw $lost
    }
    if ($warmCode -ne 0) { throw "warm-shader-cache.ps1 failed ($warmCode)" }

    Write-Host '-- run-tests.ps1 -Tier gpu' -ForegroundColor White
    & pwsh -NoProfile -File (Join-Path $wt 'tests\run-tests.ps1') -Tier gpu -Filter $Filter -MpvExe (Join-Path $wt 'mpv.exe') -WorkDir $work 2>&1 |
        Tee-Object -FilePath $log | Out-Host
    $text = Get-Content -Raw -LiteralPath $log
    $summary = [regex]::Match($text, '(\d+) passed, (\d+) failed, (\d+) skipped')
    $failedLines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+FAIL\s' } | ForEach-Object { $_.Trim() })
    $lost = $failedLines | Where-Object { $_ -match 'the GPU device was not lost' } | Select-Object -First 1
    if ($lost) {
        Set-Content -LiteralPath $lostMark -Value "$(Get-Date -Format s): $lost"
    }
    else {
        # ended, and the device kept: the next run may go
        Remove-Item -LiteralPath $runningMark -Force -ErrorAction SilentlyContinue
    }
    $gpu = (Get-CimInstance Win32_VideoController | Select-Object -First 1)
    $where = "$($gpu.Name), driver $($gpu.DriverVersion)"
    # The gpu tier skipped as a whole (an mpv started meanwhile, a display adapter not OK:
    # run-tests.ps1's "gpu tier" / "gpu run" SKIP) ran no GPU test: not a pass.
    $notRun = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+SKIP\s+gpu (tier|run)\b' } | ForEach-Object { ($_ -split '::', 2)[-1].Trim() } | Select-Object -First 1)
    $passed = -not $notRun.Count -and $summary.Success -and [int]$summary.Groups[2].Value -eq 0 -and [int]$summary.Groups[1].Value -gt 0
    $result = if ($notRun.Count) { "not run: $($notRun[0])" }
    elseif ($summary.Success) { "$($summary.Groups[1].Value) passed, $($summary.Groups[2].Value) failed" }
    else { 'no summary (the run broke off)' }
}
catch {
    $passed = $false
    $result = "did not run: $($_.Exception.Message)"
    $failedLines = @()
    $where = 'this PC'
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
# A tier that did not run leaves the check pending: the pull request still waits for one.
# One with a test that failed (a lost device among them, after which the rest is skipped)
# did run, and failed.
$state = if ($passed) { 'success' } elseif ($notRun.Count -and -not $failedLines.Count) { 'pending' } else { 'failure' }
$verdict = if ($passed) { 'passed' } elseif ($notRun.Count -and -not $failedLines.Count) { 'NOT RUN' } else { 'FAILED' }
$result = ConvertTo-PublicText $result $privateWords
$where = ConvertTo-PublicText $where $privateWords
$description = "$result on $where"
if ($description.Length -gt 140) { $description = $description.Substring(0, 137) + '...' }
$null = Invoke-Gh @('api', '-X', 'POST', "repos/$repo/statuses/$sha", '-f', "state=$state", '-f', "context=$Context", '-f', "description=$description")
$body = @("**$Context**: $verdict on commit $($sha.Substring(0, 7)) - $result, on $where.")
# flat, a line each: nested in @(), the lines were joined with spaces into one
if ($failedLines.Count) { $body += @('', '```') + @($failedLines | Select-Object -First 30 | ForEach-Object { ConvertTo-PublicText $_ $privateWords }) + @('```') }
if ($lost) { $body += @('', 'The GPU device was lost: this commit is not run here again without `-Force` (a device loss is reproduced at most once).') }
$null = Invoke-Gh @('api', '-X', 'POST', "repos/$repo/issues/$Pr/comments", '-f', "body=$($body -join "`n")")
Write-Host ''
Write-Host "#${Pr}: $Context $state - $result" -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
Write-Host "Log: $log"
exit $(if ($passed) { 0 } else { 1 })
