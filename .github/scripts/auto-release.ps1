# What a push to main becomes once CI has passed on it: a release of exactly that commit
# (.github/workflows/auto-release.yml), as in the owner's other repositories. The config has
# no version number of its own, so the tag is the day and a count of that day,
# v2026.10.22.1, set on the tested commit itself: no version commit lands on main.
#
#   pwsh .github/scripts/auto-release.ps1 -Sha <full commit sha> [-DryRun]   (GH_TOKEN, GH_REPO set; gh on PATH)
#
# -DryRun prints the tag and the notes it would publish and changes nothing.
param(
    [Parameter(Mandatory)][string]$Sha,
    [string]$Repo = $env:GH_REPO,
    [switch]$DryRun,
    [int]$LintWaitSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Gh([string[]]$Arguments) {
    $out = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed ($LASTEXITCODE)" }
    return $out
}

# gh's exit code alone, for a lookup whose "not found" is an answer
function Test-Gh([string[]]$Arguments) {
    $null = & gh @Arguments 2>$null
    return $LASTEXITCODE -eq 0
}

if ($Sha -notmatch '^[0-9a-f]{40}$') { throw "-Sha is '$Sha', not a full commit SHA" }
if (-not $Repo) { throw 'No repository: set GH_REPO or pass -Repo' }
$short = $Sha.Substring(0, 7)

# Only main's newest commit: when main moved on while CI ran, the newer commit's own run
# releases, and its notes cover this commit's pull request too.
$head = Invoke-Gh @('api', "repos/$Repo/commits/main", '--jq', '.sha')
if ($head -ne $Sha) {
    Write-Host "::notice::main moved on to $head after CI tested $short; that commit's run releases it."
    exit 0
}

# This setup's release tags and the commits they point at.
$tagPattern = '^v\d{4}\.\d{2}\.\d{2}\.\d+$'
$tags = @(Invoke-Gh @('api', '--paginate', "repos/$Repo/tags", '--jq', '.[] | [.name, .commit.sha] | @tsv') |
        Where-Object { $_ } | ForEach-Object {
            $name, $commit = $_ -split "`t"
            [pscustomobject]@{ Name = $name; Sha = $commit }
        } | Where-Object Name -Match $tagPattern)

# A re-run: the commit has its release already. A tag of it without one (a run that
# stopped in between) gets its release below.
$tag = @($tags | Where-Object Sha -EQ $Sha | ForEach-Object Name | Select-Object -First 1)
if ($tag.Count -and (Test-Gh @('release', 'view', $tag[0], '--repo', $Repo, '--json', 'tagName'))) {
    Write-Host "::notice::$short is released already ($($tag[0]))."
    exit 0
}

# CI's suite started this run; the two linters are workflows of their own. A docs-only push
# runs neither (paths-ignore); one that runs must pass. A red one shows its own X, so this
# run only says why it releases nothing.
$lints = @('Lua lint', 'PowerShell lint')
$deadline = (Get-Date).AddSeconds($LintWaitSeconds)
while ($true) {
    $runs = @(Invoke-Gh @('api', "repos/$Repo/actions/runs?head_sha=$Sha&event=push&per_page=100", '--jq',
            '.workflow_runs[] | [.name, .status, (.conclusion // "")] | @tsv') |
            Where-Object { $_ } | ForEach-Object {
                $name, $status, $conclusion = $_ -split "`t"
                [pscustomobject]@{ Name = $name; Status = $status; Conclusion = $conclusion }
            } | Where-Object Name -In $lints)
    $open = @($runs | Where-Object Status -NE 'completed')
    if (-not $open.Count) { break }
    if ((Get-Date) -gt $deadline) { throw "Still running after $LintWaitSeconds s: $(($open | ForEach-Object Name) -join ', ')" }
    Start-Sleep -Seconds 20
}
$red = @($runs | Where-Object Conclusion -NE 'success')
if ($red.Count) {
    Write-Host "::notice::$short is not released: $(($red | ForEach-Object { "$($_.Name) $($_.Conclusion)" }) -join ', ')."
    exit 0
}

# The notes: one line of this setup's own, then GitHub's list of the pull requests since the
# last release.
$build = (Invoke-Gh @('api', '-H', 'Accept: application/vnd.github.raw+json', "repos/$Repo/contents/mpv-build.json?ref=$Sha") |
        Out-String | ConvertFrom-Json).tag
$header = "The config as of $short, tested by CI, with mpv build $build (mpv-build.json). " +
"A new PC: README.md, ""Install""; an installed copy updates with updater.bat."
$previous = if (Test-Gh @('api', "repos/$Repo/releases/latest")) { Invoke-Gh @('api', "repos/$Repo/releases/latest", '--jq', '.tag_name') }

if (-not $tag.Count) {
    $day = (Get-Date).ToUniversalTime().ToString('yyyy.MM.dd', [Globalization.CultureInfo]::InvariantCulture)
    $count = 1 + (@($tags | Where-Object Name -Like "v$day.*" | ForEach-Object { [int]$_.Name.Split('.')[3] }) + 0 | Measure-Object -Maximum).Maximum
    $tag = @("v$day.$count")
}
$tag = $tag[0]

if ($DryRun) {
    $preview = @('api', "repos/$Repo/releases/generate-notes", '-f', "tag_name=$tag", '-f', "target_commitish=$Sha", '--jq', '.body')
    if ($previous) { $preview += @('-f', "previous_tag_name=$previous") }
    Write-Host "Would release $short as $tag (previous release: $(if ($previous) { $previous } else { 'none' }))."
    Write-Host "--- notes ---`n$header`n`n$((Invoke-Gh $preview) -join "`n")"
    exit 0
}

# The tag first, through the API: a name another run took meanwhile is refused, and the next
# count of the day is tried.
if (-not (Test-Gh @('api', "repos/$Repo/git/ref/tags/$tag"))) {
    for ($try = 1; ; $try++) {
        if (Test-Gh @('api', "repos/$Repo/git/refs", '-f', "ref=refs/tags/$tag", '-f', "sha=$Sha")) { break }
        if ($try -ge 5 -or -not (Test-Gh @('api', "repos/$Repo/git/ref/tags/$tag"))) { throw "Could not create the tag $tag" }
        $parts = $tag.Split('.')
        $tag = "$($parts[0]).$($parts[1]).$($parts[2]).$([int]$parts[3] + 1)"
    }
}

$create = @('release', 'create', $tag, '--repo', $Repo, '--verify-tag', '--latest',
    '--title', "mpv-config $($tag.Substring(1))", '--notes', $header, '--generate-notes')
if ($previous) { $create += @('--notes-start-tag', $previous) }
Invoke-Gh $create
Write-Host "Released $short as $tag."
