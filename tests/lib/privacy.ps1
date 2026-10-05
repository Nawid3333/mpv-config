# Privacy checks (2026-10-03), shared by the static tier (tests/run-tests.ps1) and the
# publish job (.github/scripts/publish.ps1): this private workspace is published to the
# public Nawid3333/mpv-config, and nothing personal may go with it.
# A finding is reported as file:line or a path, never the text: CI logs are read by
# more people than the files.

# The pathspecs that keep a path out of the public copy: .publishignore (one git
# pathspec glob per line, e.g. notes/**; # starts a comment) and the file itself.
function Get-PublishExclude([string]$Root) {
    $list = @(':(exclude).publishignore')
    $file = Join-Path $Root '.publishignore'
    if (Test-Path -LiteralPath $file) {
        $list += @(Get-Content -LiteralPath $file | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { ":(exclude,glob)$_" })
    }
    $list
}

# A commit identity that names no one: a GitHub noreply address whose name is its
# login (<id>+<login>@users.noreply.github.com), or Claude <noreply@anthropic.com>.
function Test-PublicIdentity([string]$Name, [string]$Email) {
    if ($Email -eq 'noreply@anthropic.com') { return $Name -eq 'Claude' }
    if ($Email -match '^\d+\+([^@]+)@users\.noreply\.github\.com$') { return $Name -eq $Matches[1] }
    return $false
}

# A line of text (a commit subject) that may go public: no user folder path, private
# claude.ai link, e-mail address or private word.
function Test-PublicText([string]$Text, [string[]]$Words = @()) {
    if ($Text -match '[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9_]|claude\.ai/(code|artifact|chat|share)/|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}') {
        return $false
    }
    foreach ($w in $Words) {
        $w = $w.Trim()
        if ($w -and -not $w.StartsWith('#') -and $Text.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    return $true
}

# Every check over the files that are published: an ordered map check -> findings
# (file:line or path). -Index searches the index instead of the work tree (the publish
# job scans what it is about to commit). -Words: the private words (real name, user
# name, PC name ...) - the clone's .git/info/private-words, or the PRIVATE_WORDS secret.
function Get-PrivacyFinding {
    param([string]$Root, [string[]]$Words = @(), [string[]]$Exclude = @(), [switch]$Index)
    $cached = $Index ? @('--cached') : @()
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
            throw "git $($GitArgs[0]) failed (exit $LASTEXITCODE): the privacy check cannot tell what would be published"
        }
        , $out
    }
    $r = [ordered]@{}
    # (& $git ...) is the array itself: inside @() it became one element, the array
    $r['no tracked file is one .gitignore excludes'] = & $git (@('ls-files', '-ci', '--exclude-standard', '--', '.') + $Exclude)
    $r['no user folder path (C:\Users\<name>) or private claude.ai link'] = & $at (& $git (@('grep') + $cached + @(
                '-I', '-n', '-E', '[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9_]|claude\.ai/(code|artifact|chat|share)/', '--', '.') + $Exclude) 1)
    $r['no e-mail address but noreply ones'] = & $at @((& $git (@('grep') + $cached + @(
                    '-I', '-n', '-o', '-E', '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '--', '.', ':(exclude)doc/manual.txt') + $Exclude) 1) |
            Where-Object { $_ -notmatch '(noreply@anthropic\.com|noreply@github\.com|@users\.noreply\.github\.com|@example\.(com|org))$' })
    $Words = @($Words | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($Words.Count) {
        $e = @($Words | ForEach-Object { '-e'; $_ })
        $r["none of the $($Words.Count) private words"] = & $at (& $git (@('grep') + $cached + @('-I', '-n', '-i', '-F') + $e + @('--', '.') + $Exclude) 1)
        $r['no file name holds a private word'] = @((& $git (@('ls-files', '--', '.') + $Exclude)) | Where-Object {
                $path = $_
                @($Words | Where-Object { $path.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
            })
    }
    $r
}
