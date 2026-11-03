# What mpv's own CI said of the commit a shinchiro build was made from, for
# .github/workflows/mpv-auto-update.yml: a build of a commit that CI failed is not offered.
#
#   gh api --paginate --slurp "repos/mpv-player/mpv/commits/<sha>/check-runs?per_page=100" > checks.json
#   pwsh .github/scripts/upstream-ci.ps1 -ChecksFile checks.json
#
# prints one line: the verdict - passed, failed, pending (a job still runs, or GitHub no
# longer vouches for it: "stale") or none (no checks: a docs change) - a tab, and the failed
# jobs' names, comma-separated. Dot-sourced without -ChecksFile it only defines Get-UpstreamCi,
# for the static tier's checks.
param([string]$ChecksFile)

# Jobs whose verdict says nothing about shinchiro's Windows build: mpv's macOS builds and
# tests. One of them can fail for reasons of its own (a new Xcode preview) and cancel the
# others with it while every Windows, Linux, BSD and lint job passes; counting them kept
# every new build away (doc/history/sessions-2026-11.md).
$UpstreamIgnoredJob = '^macos\b'

# Conclusions that are a failure, unless another run of the same job passed.
$UpstreamFailed = @('failure', 'timed_out', 'cancelled', 'startup_failure', 'action_required')

# $Pages: the check-runs pages (gh api --paginate --slurp), each with its check_runs.
# Returns @{ Verdict = passed|failed|pending|none; Failed = names of the failed jobs }.
function Get-UpstreamCi($Pages) {
    $runs = @($Pages | ForEach-Object { $_.check_runs } | Where-Object { $_ -and $_.name -notmatch $UpstreamIgnoredJob })
    if ($runs.Count -eq 0) { return @{ Verdict = 'none'; Failed = @() } }
    $failed = [System.Collections.Generic.List[string]]::new()
    $pending = $false
    # A job runs more than once on a commit when it is re-run (after a flake) or when
    # several workflow runs share it: one run of it that passed is its verdict.
    foreach ($job in ($runs | Group-Object name)) {
        $states = @($job.Group | ForEach-Object {
                if ($_.status -ne 'completed' -or $_.conclusion -eq 'stale') { 'pending' } else { [string]$_.conclusion }
            })
        if ($states -contains 'success') { continue }
        if (@($states | Where-Object { $_ -in $UpstreamFailed }).Count) { $failed.Add($job.Name) }
        elseif ($states -contains 'pending') { $pending = $true }
        # skipped or neutral: no verdict against it
    }
    $verdict = $failed.Count ? 'failed' : $pending ? 'pending' : 'passed'
    return @{ Verdict = $verdict; Failed = @($failed) }
}

if ($ChecksFile) {
    $ErrorActionPreference = 'Stop'
    $result = Get-UpstreamCi (Get-Content -Raw -LiteralPath $ChecksFile | ConvertFrom-Json)
    "$($result.Verdict)`t$($result.Failed -join ', ')"
}
