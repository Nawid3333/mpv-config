# What this repository pins or copies from elsewhere that no other workflow keeps current (his
# request, 2026-10-24): Dependabot moves only the GitHub Actions here, mpv-auto-update.yml the
# mpv build, stylua-update.yml stylua. The rest is compared with its upstream's newest:
#   - the linters' pins in the workflow files (lua-language-server, PSScriptAnalyzer, and
#     stylua as a second look): GITHUB_TOKEN may not push a change to .github/workflows/*,
#     so they go on the issue;
#   - the copied code (uosc, thumbfast, autoload.lua), the shaders' sources and 7-Zip's
#     7zr.exe, from the versions THIRD-PARTY-NOTICES.md records.
# One issue, "Upstream updates to look at", lists what is behind and is closed once nothing is.
# autoload.lua, kept unchanged from mpv, is offered on ONE rolling pull request (branch
# autoload-update) with its notice moved, and the regression tests started on it.
#
#   pwsh .github/scripts/upstream-watch.ps1 -Run [-DryRun]   (GH_TOKEN, GH_REPO set; gh on PATH)
#
# -DryRun only reads and reports (a pull request's run of the workflow). Dot-sourced without
# -Run it only defines its functions (Get-Recorded), for the static tier's checks.
param([switch]$Run, [switch]$DryRun, [string]$Repo = $env:GH_REPO, [string]$Owner = $env:OWNER)

$IssueTitle = 'Upstream updates to look at'
$AutoloadBranch = 'autoload-update'

# What this repository records for each item: name -> @{ Recorded; File }. A value that is
# not found is $null, which the static tier's check turns red.
function Get-Recorded([string]$Root) {
    $lint = Get-Content -Raw (Join-Path $Root '.github/workflows/lint-lua.yml')
    $psLint = Get-Content -Raw (Join-Path $Root '.github/workflows/powershell-lint.yml')
    $notices = Get-Content -Raw (Join-Path $Root 'THIRD-PARTY-NOTICES.md')
    $first = { param($Text, $Pattern) $m = [regex]::Match($Text, $Pattern); $m.Success ? $m.Groups[1].Value : $null }
    [ordered]@{
        'lua-language-server' = @{ Recorded = (& $first $lint 'LLS_VERSION:\s*([0-9][0-9.]*)'); File = '.github/workflows/lint-lua.yml' }
        'PSScriptAnalyzer'    = @{ Recorded = (& $first $psLint "\`$version = '([0-9][0-9.]*)'"); File = '.github/workflows/powershell-lint.yml' }
        'stylua'              = @{ Recorded = (& $first $lint '(?m)^ *version: (v[0-9][0-9.]*) *$'); File = '.github/workflows/lint-lua.yml' }
        'uosc'                = @{ Recorded = (& $first $notices '\[uosc\]\(https://github\.com/tomasklaen/uosc\) v([0-9][0-9.]*)'); File = 'portable_config/Scripts/uosc/' }
        'thumbfast'           = @{ Recorded = (& $first $notices "\[thumbfast\][^|]*upstream's commit ``([0-9a-f]{7,40})``"); File = 'portable_config/Scripts/thumbfast.lua' }
        'autoload.lua'        = @{ Recorded = (& $first $notices "TOOLS/lua/autoload\.lua``\), as of upstream's commit ``([0-9a-f]{7,40})``"); File = 'portable_config/Scripts/autoload.lua' }
        'Anime4K'             = @{ Recorded = (& $first $notices '\[Anime4K\]\(https://github\.com/bloc97/Anime4K\) (v[0-9][0-9.]*)'); File = 'portable_config/shaders/Anime4K_*.glsl' }
        'FSRCNNX'             = @{ Recorded = (& $first $notices 'FSRCNN-TensorFlow release ([0-9][0-9.]*)'); File = 'portable_config/shaders/FSRCNNX_x2_16-0-4-1.glsl' }
        'SSimSuperRes'        = @{ Recorded = (& $first $notices 'dyphire/mpv-config at `([0-9a-f]{7,40})`'); File = 'portable_config/shaders/SSimSuperRes.glsl' }
        'CfL_Prediction'      = @{ Recorded = (& $first $notices 'glsl-chroma-from-luma-prediction at `([0-9a-f]{7,40})`'); File = 'portable_config/shaders/CfL_Prediction.glsl' }
        '7-Zip'               = @{ Recorded = (& $first $notices '\[7-Zip\]\(https://www\.7-zip\.org/\) ([0-9][0-9.]*)'); File = '7z/7zr.exe' }
        'adaptive-sharpen'    = @{ Recorded = (& $first $notices "\[igv's port\]\(https://gist\.github\.com/igv/8a77e4eb8276753b54bb94c1c50c317e\) at revision ``([0-9a-f]{7,40})``"); File = 'portable_config/shaders/adaptive-sharpen.glsl' }
    }
}

# The first item, or $null for none: under StrictMode an empty array's [0] throws.
function Get-First($Items) {
    $all = @($Items)
    $all.Count ? $all[0] : $null
}

function Invoke-GhJson([string[]]$Arguments) {
    # stderr apart: a warning gh prints there must not land in the JSON
    $errors = [System.Collections.Generic.List[string]]::new()
    $out = & gh @Arguments 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $errors.Add("$_") } else { $_ } }
    if ($LASTEXITCODE) { throw "gh $($Arguments -join ' ') failed: $($errors -join ' ')" }
    ($out -join "`n") | ConvertFrom-Json
}

# The newest commit of a repository (or of one file in it): @{ Sha; Date }.
function Get-NewestCommit([string]$UpstreamRepo, [string]$Path = '') {
    $query = $Path ? "?path=$([uri]::EscapeDataString($Path))&per_page=1" : '?per_page=1'
    $c = Get-First (Invoke-GhJson @('api', "repos/$UpstreamRepo/commits$query"))
    if (-not $c) { throw "no commit in $UpstreamRepo$($Path ? " for $Path" : '')" }
    @{ Sha = $c.sha; Date = ([datetime]$c.commit.committer.date).ToUniversalTime().ToString('yyyy-MM-dd') }
}

function Get-LatestTag([string]$UpstreamRepo) {
    (Invoke-GhJson @('api', "repos/$UpstreamRepo/releases/latest")).tag_name
}

# Whether a newer version than the recorded one is out.
function Test-NewerVersion([string]$Recorded, [string]$Newest) {
    [version]($Newest.TrimStart('v')) -gt [version]($Recorded.TrimStart('v'))
}

# Each item: its upstream's newest, whether it is behind, and what to do then.
function Get-Watch([hashtable]$Rec) {
    $rows = [System.Collections.Generic.List[object]]::new()
    # Every row has every field (StrictMode reads them all). An upstream that cannot be read
    # (no release, a tag that is no version, the API down) is a row of its own, Failed: the
    # others are still reported, and the run ends red.
    $add = {
        param($Name, $Newest, $Behind, $Link, $Todo, $Sha = $null, $Date = $null)
        $rows.Add([pscustomobject]@{ Name = $Name; Recorded = $Rec[$Name].Recorded; Newest = $Newest; Behind = $Behind
                Link = $Link; Todo = $Todo; Sha = $Sha; Date = $Date; Failed = $null })
    }
    $fail = {
        param($Name, $Message)
        $rows.Add([pscustomobject]@{ Name = $Name; Recorded = $Rec[$Name].Recorded; Newest = 'not read'; Behind = $false
                Link = ''; Todo = "could not read upstream: $Message"; Sha = $null; Date = $null; Failed = $Message })
    }
    $tag = {
        param($Name, $UpstreamRepo, $Todo)
        try {
            $newest = Get-LatestTag $UpstreamRepo
            & $add $Name $newest (Test-NewerVersion $Rec[$Name].Recorded $newest) "https://github.com/$UpstreamRepo/releases/tag/$newest" $Todo
        }
        catch { & $fail $Name $_.Exception.Message }
    }
    $commit = {
        param($Name, $UpstreamRepo, $Path, $Todo)
        try {
            $c = Get-NewestCommit $UpstreamRepo $Path
            & $add $Name "$($c.Sha.Substring(0, 12)) ($($c.Date))" (-not $c.Sha.StartsWith($Rec[$Name].Recorded)) "https://github.com/$UpstreamRepo/commits/$($c.Sha)" $Todo $c.Sha $c.Date
        }
        catch { & $fail $Name $_.Exception.Message }
    }
    & $tag 'lua-language-server' 'LuaLS/lua-language-server' 'move LLS_VERSION and its SHA-256 in lint-lua.yml'
    try {
        # The gallery's own API: Find-Module can stop to ask for the NuGet provider on a fresh runner.
        $entries = Invoke-RestMethod -Uri "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='PSScriptAnalyzer'" -UseBasicParsing
        $stable = @($entries | ForEach-Object { $_.properties } | Where-Object { $_.IsPrerelease.'#text' -ne 'true' } |
                ForEach-Object { [version]$_.Version } | Sort-Object -Descending)
        if (-not $stable) { throw 'the PowerShell Gallery lists no stable release' }
        $psa = $stable[0].ToString()
        & $add 'PSScriptAnalyzer' $psa (Test-NewerVersion $Rec['PSScriptAnalyzer'].Recorded $psa) "https://www.powershellgallery.com/packages/PSScriptAnalyzer/$psa" 'move $version in powershell-lint.yml, then fix what the new rules find'
    }
    catch { & $fail 'PSScriptAnalyzer' $_.Exception.Message }
    & $tag 'stylua' 'JohnnyMorganz/StyLua' 'stylua-update.yml offers it; if its pull request does not come, move it by hand'
    & $tag 'uosc' 'tomasklaen/uosc' 'update the folder, re-apply every "Local change" (AGENTS.md lists them)'
    & $commit 'thumbfast' 'po5/thumbfast' 'thumbfast.lua' 're-apply the two local changes (THIRD-PARTY-NOTICES.md)'
    & $commit 'autoload.lua' 'mpv-player/mpv' 'TOOLS/lua/autoload.lua' 'offered on a pull request (autoload-update)'
    & $tag 'Anime4K' 'bloc97/Anime4K' 'judge it by eye first (AGENTS.md: Anime4K stays the Anime preset), new SHA-256s'
    & $tag 'FSRCNNX' 'igv/FSRCNN-TensorFlow' 'new file and SHA-256; the gpu tier'
    & $commit 'SSimSuperRes' 'dyphire/mpv-config' 'shaders/igv/SSimSuperRes.glsl' 'new file and SHA-256; the gpu tier'
    & $commit 'CfL_Prediction' 'Artoriuz/glsl-chroma-from-luma-prediction' 'CfL_Prediction.glsl' 'new file and SHA-256; the gpu tier'
    # 7-Zip's own site links its downloads to these releases; each asset has its SHA-256 there.
    & $tag '7-Zip' 'ip7z/7zip' 'replace 7z/7zr.exe with the release''s 7zr.exe (its SHA-256 on the release), and its row in THIRD-PARTY-NOTICES.md'
    try {
        # The gist's newest revision (its own version string inside the shader is another thing),
        # read from its git repository: the gists API refuses the Actions token (HTTP 403,
        # "Resource not accessible by integration"). A gist revision is that repository's commit.
        $head = git ls-remote https://gist.github.com/8a77e4eb8276753b54bb94c1c50c317e.git HEAD 2>&1
        if ($LASTEXITCODE) { throw "git ls-remote of the gist failed: $($head -join ' ')" }
        $rev = ("$head" -split '\s+')[0]
        if ($rev -notmatch '^[0-9a-f]{40}$') { throw "the gist's HEAD is no commit: $head" }
        & $add 'adaptive-sharpen' $rev.Substring(0, 12) (-not $rev.StartsWith($Rec['adaptive-sharpen'].Recorded)) 'https://gist.github.com/igv/8a77e4eb8276753b54bb94c1c50c317e/revisions' 're-apply the local curve_height change, new SHA-256; the gpu tier'
    }
    catch { & $fail 'adaptive-sharpen' $_.Exception.Message }
    $rows
}

function Format-Report($Rows, [string]$AutoloadPr) {
    $lines = @('| | This repository | Upstream''s newest | To do |', '|---|---|---|---|')
    foreach ($r in $Rows) {
        $todo = ($r.Behind -or $r.Failed) ? $r.Todo : 'current'
        if ($r.Name -eq 'autoload.lua' -and $r.Behind -and $AutoloadPr) { $todo = "offered on $AutoloadPr" }
        $newest = $r.Link ? "[$($r.Newest)]($($r.Link))" : $r.Newest
        $lines += "| $($r.Name) | $($r.Recorded) | $newest | $todo |"
    }
    $lines -join "`n"
}

# autoload.lua at upstream's newest commit on the rolling branch, its notice moved with it, the
# regression tests and the Lua lint started there; the pull request's link, or $null.
function Submit-Autoload($Row, [string]$Root) {
    $existing = Invoke-GhJson @('pr', 'list', '--repo', $Repo, '--state', 'open', '--head', $AutoloadBranch, '--json', 'number,url')
    $pr = Get-First $existing
    # The branch offers this commit already: its pull request is open, or was closed unmerged,
    # which skips the commit until a newer one comes (as stylua-update.yml does).
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:GH_TOKEN"))
    # through git's environment, not its command line, where any process could read it
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
    $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $auth"
    git -C $Root fetch -q --depth=1 origin "refs/heads/$AutoloadBranch" 2>$null
    if (-not $LASTEXITCODE) {
        $offered = git -C $Root show "FETCH_HEAD:THIRD-PARTY-NOTICES.md" | Out-String
        if ($offered -match "TOOLS/lua/autoload\.lua``\), as of upstream's commit ``$($Row.Sha.Substring(0, 8))") {
            Write-Host "Branch $AutoloadBranch offers $($Row.Sha.Substring(0, 8)) already$($pr ? " ($($pr.url))" : ' (its pull request was closed unmerged: skipped until a newer commit)')."
            return $pr ? $pr.url : $null
        }
    }
    $raw = "https://raw.githubusercontent.com/mpv-player/mpv/$($Row.Sha)/TOOLS/lua/autoload.lua"
    $file = Join-Path $Root 'portable_config/Scripts/autoload.lua'
    Invoke-WebRequest -Uri $raw -OutFile $file -UseBasicParsing
    $notices = Join-Path $Root 'THIRD-PARTY-NOTICES.md'
    $text = Get-Content -Raw $notices
    $moved = [regex]::Replace($text, "(TOOLS/lua/autoload\.lua``\), as of upstream's commit ``)[0-9a-f]{7,40}(`` \()[0-9-]{10}(\))",
        "`${1}$($Row.Sha.Substring(0, 8))`${2}$($Row.Date)`${3}")
    if ($moved -eq $text) { throw 'THIRD-PARTY-NOTICES.md: the autoload.lua row was not found' }
    [System.IO.File]::WriteAllText($notices, $moved)
    # A newer commit that left the file as it was still moves the notice: offered alone, or
    # the item stays "behind" every week.
    $fileChanged = [bool](git -C $Root status --porcelain -- portable_config/Scripts/autoload.lua)
    git -C $Root config user.name 'github-actions[bot]'
    git -C $Root config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    git -C $Root switch -q -c $AutoloadBranch
    if ($LASTEXITCODE) { throw "could not make the branch $AutoloadBranch" }
    git -C $Root add portable_config/Scripts/autoload.lua THIRD-PARTY-NOTICES.md
    git -C $Root commit -q -m "autoload.lua: mpv's newest ($($Row.Sha.Substring(0, 8)), $($Row.Date))"
    if ($LASTEXITCODE) { throw 'could not commit autoload.lua' }
    git -C $Root push -q -f origin "HEAD:refs/heads/$AutoloadBranch"
    if ($LASTEXITCODE) { throw 'could not push the autoload-update branch' }
    foreach ($workflow in 'regression-tests.yml', 'lint-lua.yml') {
        & gh workflow run $workflow --repo $Repo --ref $AutoloadBranch
        if ($LASTEXITCODE) { throw "could not start $workflow on $AutoloadBranch" }
    }
    $title = "autoload.lua: mpv's newest ($($Row.Sha.Substring(0, 8)))"
    $body = Join-Path ([System.IO.Path]::GetTempPath()) 'autoload-pr.md'
    @(
        "@$Owner mpv changed TOOLS/lua/autoload.lua (commit $($Row.Sha.Substring(0, 12)), $($Row.Date)). **It waits for your merge.**"
        ''
        "- Upstream: https://github.com/mpv-player/mpv/commits/master/TOOLS/lua/autoload.lua"
        ($fileChanged ? '- The file is copied unchanged from upstream, and its row in THIRD-PARTY-NOTICES.md moves with it.' :
            '- The file at that commit is the one here already: only its row in THIRD-PARTY-NOTICES.md moves.')
        '- The regression tests and the Lua lint run on this branch (this workflow starts them: a pull request it opens starts none by itself).'
        ''
        'This pull request keeps up: a newer commit moves here.'
    ) | Set-Content -Path $body -Encoding utf8
    if ($pr) {
        & gh pr edit $pr.number --repo $Repo --title $title --body-file $body | Out-Null
        if ($LASTEXITCODE) { throw "could not update $($pr.url)" }
        return $pr.url
    }
    $url = & gh pr create --repo $Repo --base main --head $AutoloadBranch --title $title --body-file $body --assignee $Owner
    if ($LASTEXITCODE) { throw 'could not open the autoload.lua pull request' }
    $url
}

if (-not $Run) { return }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$rec = Get-Recorded $root
$missing = @($rec.Keys | Where-Object { -not $rec[$_].Recorded })
if ($missing) { throw "not found in this repository's files: $($missing -join ', ')" }
$rows = Get-Watch $rec
$behind = @($rows | Where-Object Behind)
$autoloadPr = $null
$autoload = $rows | Where-Object Name -EQ 'autoload.lua'
if ($autoload.Behind -and -not $DryRun) { $autoloadPr = Submit-Autoload $autoload $root }
$report = Format-Report $rows $autoloadPr
$summary = $env:GITHUB_STEP_SUMMARY
if ($summary) { Add-Content -Path $summary -Value "$report`n" }
Write-Output $report
Write-Output "$($behind.Count) of $($rows.Count) behind upstream."
if ($DryRun) { return }

# The one issue, open or closed (by its exact title). One the owner closed while something
# was behind stays closed until the report changes (something newer, or caught up): a new
# issue every week for the same thing is noise.
$failed = @($rows | Where-Object Failed)
$issue = Get-First (Invoke-GhJson @('issue', 'list', '--repo', $Repo, '--state', 'all', '--search', "in:title `"$IssueTitle`"", '--json', 'number,title,state,body') |
        Where-Object title -EQ $IssueTitle | Sort-Object { $_.state -ne 'OPEN' }, { -$_.number })
if ($behind.Count -eq 0) {
    if ($issue -and $issue.state -eq 'OPEN') {
        & gh issue close $issue.number --repo $Repo --comment 'Everything this issue watched is at its upstream''s newest now.' | Out-Null
        if ($LASTEXITCODE) { throw "could not close issue #$($issue.number)" }
    }
}
else {
    $body = @(
        "@$Owner Something this repository pins or copies is behind its upstream. This issue is kept up to date once a week (upstream-watch.yml) and closes when nothing is behind."
        ''
        $report
        ''
        'Dependabot (GitHub Actions), mpv-auto-update.yml (the mpv build) and stylua-update.yml (stylua) keep their own pull requests; yt-dlp, Node.js and the FastStream helper come new with each install and update.'
    ) -join "`n"
    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) 'upstream-issue.md'
    [System.IO.File]::WriteAllText($bodyFile, $body)
    $same = $issue -and ($issue.body -replace "`r", '').Trim() -eq $body.Trim()
    if (-not $issue) {
        & gh issue create --repo $Repo --title $IssueTitle --body-file $bodyFile --assignee $Owner | Out-Null
        if ($LASTEXITCODE) { throw 'could not open the issue' }
    }
    elseif ($issue.state -ne 'OPEN' -and $same) {
        Write-Output "Issue #$($issue.number) was closed with this same report: left closed."
    }
    elseif (-not $same) {
        if ($issue.state -ne 'OPEN') {
            & gh issue reopen $issue.number --repo $Repo | Out-Null
            if ($LASTEXITCODE) { throw "could not reopen issue #$($issue.number)" }
        }
        & gh issue edit $issue.number --repo $Repo --body-file $bodyFile | Out-Null
        if ($LASTEXITCODE) { throw "could not update issue #$($issue.number)" }
    }
}
# An upstream that could not be read is reported above, and the run ends red for it.
if ($failed) { throw "could not read: $(($failed | ForEach-Object Name) -join ', ')" }
