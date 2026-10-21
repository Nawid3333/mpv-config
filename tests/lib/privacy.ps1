# Privacy checks (2026-10-03), shared by the static tier (tests/run-tests.ps1) and CI's
# privacy job (.github/workflows/regression-tests.yml): this repository is public, and
# nothing personal may be in it. The hooks in .githooks check each commit and push.
# A finding is reported as file:line or a path, never the text: a CI log would repeat it.

# A commit identity that names no one: a GitHub noreply address whose name is its
# login (<id>+<login>@users.noreply.github.com), or Claude <noreply@anthropic.com>.
function Test-PublicIdentity([string]$Name, [string]$Email) {
    if ($Email -eq 'noreply@anthropic.com') { return $Name -eq 'Claude' }
    if ($Email -match '^\d+\+([^@]+)@users\.noreply\.github\.com$') { return $Name -eq $Matches[1] }
    return $false
}

# Every check over the tracked files: an ordered map check -> findings (file:line or
# path). -Words: the private words (real name, user name, PC name ...) - the clone's
# .git/info/private-words, or the PRIVATE_WORDS secret.
function Get-PrivacyFinding {
    param([string]$Root, [string[]]$Words = @())
    # git grep -n prints path:line:text - keep path:line (always arrays: Count under StrictMode)
    $at = { param($lines) , @($lines | Where-Object { $_ } | ForEach-Object { ($_ -split ':', 3)[0..1] -join ':' }) }
    # A git that could not run (no repository, a locked index) printed nothing, which read
    # as "nothing found", and the gate passed (until 2026-10-05). git grep's exit 1 is "no
    # match", a result; anything else not 0 stops the check.
    $repo = $Root
    $git = {
        param([string[]]$GitArgs, [int]$NoMatch = -1)
        $out = @(& git -C $repo @GitArgs)
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $NoMatch) {
            throw "git $($GitArgs[0]) failed (exit $LASTEXITCODE): the privacy check cannot tell what the repository holds"
        }
        , $out
    }
    $r = [ordered]@{}
    # (& $git ...) is the array itself: inside @() it became one element, the array
    $r['no tracked file is one .gitignore excludes'] = & $git @('ls-files', '-ci', '--exclude-standard', '--', '.')
    # -i: Windows paths are written in any case; mpv's own manual has its example path
    # in lower case (users\USERNAME), like its e-mail addresses below
    $r['no user folder path (C:\Users\<name>) or private claude.ai link'] = & $at (& $git @(
            'grep', '-I', '-n', '-i', '-E', '[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9_]|claude\.ai/(code|artifact|chat|share)/', '--', '.', ':(exclude)doc/manual.txt') 1)
    $r['no e-mail address but noreply ones'] = & $at @((& $git @(
                'grep', '-I', '-n', '-o', '-E', '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '--', '.', ':(exclude)doc/manual.txt') 1) |
            Where-Object { $_ -notmatch '(noreply@anthropic\.com|noreply@github\.com|support@github\.com|@users\.noreply\.github\.com|@example\.(com|org))$' })
    $Words = @($Words | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($Words.Count) {
        $e = @($Words | ForEach-Object { '-e'; $_ })
        $r["none of the $($Words.Count) private words"] = & $at (& $git (@('grep', '-I', '-n', '-i', '-F') + $e + @('--', '.')) 1)
        $r['no file name holds a private word'] = @((& $git @('ls-files', '--', '.')) | Where-Object {
                $path = $_
                @($Words | Where-Object { $path.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
            })
    }
    # A finding is a path, and a path can hold the word itself: *** in its place
    foreach ($key in @($r.Keys)) {
        $r[$key] = @($r[$key] | ForEach-Object { Hide-PrivateWord $_ $Words })
    }
    $r
}

# Every check over the commits of a range (CI passes a push's before..after, or a pull
# request's base..head): an ordered map check -> findings, each a short sha, never any
# message text. The hooks check the same before a push; this catches a commit pushed
# from a clone without them. -Words as in Get-PrivacyFinding.
function Get-CommitFinding {
    param([string]$Root, [string]$Range, [string[]]$Words = @())
    $repo = $Root
    $git = {
        param([string[]]$GitArgs)
        $out = @(& git -C $repo @GitArgs)
        if ($LASTEXITCODE -ne 0) {
            throw "git $($GitArgs[0]) failed (exit $LASTEXITCODE): the privacy check cannot tell what the repository holds"
        }
        , $out
    }
    # one record per commit: short sha, the four identity fields, then the message (which
    # holds newlines), separated by U+001F
    $sep = [char]0x1f
    $commits = @((& $git @('rev-list', $Range)) | ForEach-Object {
            $f = @(((& $git @('log', '-1', '--format=%h%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%B', $_)) -join "`n") -split $sep, 6)
            [pscustomobject]@{ Sha = $f[0]; Author = $f[1]; AuthorEmail = $f[2]; Committer = $f[3]; CommitterEmail = $f[4]; Message = $f[5] }
        })
    $r = [ordered]@{}
    # GitHub itself commits a merge or an edit made on the website
    $r['every author and committer is a public identity'] = @($commits | Where-Object {
            $byGitHub = $_.Committer -eq 'GitHub' -and $_.CommitterEmail -eq 'noreply@github.com'
            -not ((Test-PublicIdentity $_.Author $_.AuthorEmail) -and ($byGitHub -or (Test-PublicIdentity $_.Committer $_.CommitterEmail)))
        } | ForEach-Object { $_.Sha })
    $r['no commit message holds a user folder path or private claude.ai link'] = @($commits |
            Where-Object { $_.Message -match '[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9_]|claude\.ai/(code|artifact|chat|share)/' } |
            ForEach-Object { $_.Sha })
    # (support@github.com: Dependabot signs its commits with it)
    $r['no commit message holds an e-mail address but noreply ones'] = @($commits | Where-Object {
            @([regex]::Matches($_.Message, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}') |
                Where-Object { $_.Value -notmatch '(noreply@anthropic\.com|noreply@github\.com|support@github\.com|@users\.noreply\.github\.com|@example\.(com|org))$' }).Count
        } | ForEach-Object { $_.Sha })
    $Words = @($Words | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($Words.Count) {
        $r['no commit message holds a private word'] = @($commits | Where-Object {
                $msg = $_.Message
                @($Words | Where-Object { $msg.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
            } | ForEach-Object { $_.Sha })
    }
    $r
}

# $Text with each of $Words (already trimmed) replaced by ***, in any case
function Hide-PrivateWord([string]$Text, [string[]]$Words) {
    foreach ($w in $Words) {
        if ($w) { $Text = [regex]::Replace($Text, [regex]::Escape($w), '***', 'IgnoreCase') }
    }
    $Text
}
