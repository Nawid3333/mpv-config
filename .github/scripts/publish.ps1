<#
.SYNOPSIS
    Publishes this private workspace (Nawid3333/mpv) to the public Nawid3333/mpv-config,
    after checking that nothing personal goes with it.

.DESCRIPTION
    Run by .github/workflows/publish.yml once the regression tests passed on main.
    -Public is a clone of the public repository. This script replaces its files with the
    workspace's tracked files (minus .publishignore), then checks exactly what it is about
    to commit (tests/lib/privacy.ps1, with -Words = the PRIVATE_WORDS secret) and that
    every commit already in the public history names no one, and commits the copy as ONE
    commit by -Name/-Email (a public identity: GitHub login + noreply address). The
    workspace's own history, branches and pull requests never reach the public repository.
    A finding stops it: exit 1, nothing committed, findings as file:line or commit hash
    only (never the text). Exit 0 also when there is nothing new to publish.

.PARAMETER NoPush
    Commit in -Public but do not push (the regression suite's test of this script).
#>
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Public,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Email,
    [string[]]$Words = @(),
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
$Public = (Resolve-Path -LiteralPath $Public).Path
. (Join-Path $Workspace 'tests/lib/privacy.ps1')

function Invoke-Git {
    $out = & git @args 2>&1
    if ($LASTEXITCODE) { throw "git $($args[0..2] -join ' ') ... failed: $out" }
    $out
}

if (-not (Test-PublicIdentity $Name $Email)) {
    throw 'the publishing identity must be a GitHub login with its noreply address'
}

# 1. what is published: the workspace's tracked files, minus .publishignore
$files = @((& git -C $Workspace ls-files -z -- . @(Get-PublishExclude $Workspace)) -split "`0" | Where-Object { $_ })
if (-not $files.Count) { throw 'the workspace lists no files' }

# 2. Git LFS: the workspace checkout holds pointers; download only the objects the
#    public repository does not have yet, so the push can upload them
$have = @{}
foreach ($l in @(& git -C $Public lfs ls-files --long 2>$null)) { $have[($l -split ' ', 3)[0]] = $true }
$need = @(foreach ($l in @(& git -C $Workspace lfs ls-files --long 2>$null)) {
        $oid, $null, $path = $l -split ' ', 3
        if (-not $have[$oid] -and $path -in $files) { $path }
    })
if ($need.Count) { $null = Invoke-Git -C $Workspace lfs pull --include ($need -join ',') }

# 3. the public tree becomes exactly that list
$null = Invoke-Git -C $Public rm -r -q --cached --ignore-unmatch -- .
Get-ChildItem -LiteralPath $Public -Force | Where-Object Name -NE '.git' | Remove-Item -Recurse -Force
foreach ($f in $files) {
    $dst = Join-Path $Public $f
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Workspace $f) -Destination $dst
}
$null = Invoke-Git -C $Public add -A

# 4. check what is about to be committed, and the public history
$problems = @()
foreach ($kv in (Get-PrivacyFinding -Root $Public -Words $Words -Index).GetEnumerator()) {
    if ($kv.Value.Count) { $problems += "$($kv.Key) - found in: $($kv.Value -join ', ')" }
}
$named = @(& git -C $Public log --format='%h%x09%an%x09%ae%x09%cn%x09%ce' | ForEach-Object {
        $c = $_ -split "`t"
        $committerOk = (Test-PublicIdentity $c[3] $c[4]) -or ($c[3] -eq 'GitHub' -and $c[4] -eq 'noreply@github.com')
        if (-not (Test-PublicIdentity $c[1] $c[2]) -or -not $committerOk) { $c[0] }
    })
if ($named.Count) { $problems += "every public commit names no one - found in: $($named -join ', ')" }
if ($problems.Count) {
    Write-Host 'NOT published - the public copy would contain:'
    $problems | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

# 5. one commit, only when something changed
if (-not (& git -C $Public status --porcelain)) {
    Write-Host 'Nothing to publish: mpv-config already matches the workspace.'
    exit 0
}
$subject = & git -C $Workspace log -1 --format=%s
$message = (Test-PublicText $subject $Words) ? $subject : 'Publish from the workspace'
$null = Invoke-Git -C $Public -c "user.name=$Name" -c "user.email=$Email" commit -q -m $message
if ($NoPush) {
    Write-Host "Committed, not pushed (-NoPush): $message"
    exit 0
}
$branch = & git -C $Public rev-parse --abbrev-ref HEAD
$lfsFiles = @(& git -C $Public lfs ls-files 2>$null)
if ($lfsFiles.Count) { $null = Invoke-Git -C $Public lfs push origin $branch }
$null = Invoke-Git -C $Public push -q origin "HEAD:$branch"
Write-Host "Published: $message"
