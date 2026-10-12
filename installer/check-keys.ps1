<#
.SYNOPSIS
    Which keys does each running mpv use? A read-only check, for the moment mpv seems
    to ignore this setup's keys.

.DESCRIPTION
    2026-10-11 the owner saw an mpv started by FastStream that did not use his keys:
    the speed keys did nothing and j/k did not seek 10 s, as with mpv's standard
    bindings, and clicking into the window did not help. Every check afterwards found
    the right mpv and the right config (TODO item 3), so this asks the mpv itself the
    next time it happens. check-keys.bat runs it; nothing is changed anywhere.

    For every running mpv.exe it shows:
      - its program file, what started it (FastStream's helper runs under node.exe)
        and its options (addresses on the command line are left out);
      - when it has an IPC pipe (--input-ipc-server; FastStream's mpv always has
        one), what it answers there: its version, its config folder, whether it
        read config files at all, and what j, k, s, d, q, g and r do - next to what
        this setup's input.conf binds them to;
      - a verdict: this setup's keys, or mpv's standard keys and why (no config,
        another config folder, another mpv).
    With this setup's keys and keys that still do nothing, the key presses reach
    another window (focus).

    Works in Windows PowerShell 5.1 and PowerShell 7. Plain ASCII.

.PARAMETER Pipe
    More pipes to ask (\\.\pipe\<name>), besides those on mpv command lines (tests).
#>
[CmdletBinding()]
param(
    # the mpv folder whose config counts as this setup's (default: the one this script
    # is in; the tests pass their copy)
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string[]]$Pipe = @(),
    [int]$TimeoutMs = 3000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = (Resolve-Path -LiteralPath $Root).Path
$InputConf = Join-Path $Root 'portable_config\input.conf'
$Keys = @('j', 'k', 's', 'd', 'q', 'g', 'r')

# What this setup's input.conf binds each key to (its command, without the #! menu text).
function Get-ExpectedBinding {
    $map = @{}
    if (-not (Test-Path -LiteralPath $InputConf)) { return $map }
    foreach ($line in Get-Content -LiteralPath $InputConf) {
        if ($line -match '^\s*(\S+)\s+(.+)$' -and $Keys -ccontains $Matches[1]) {
            $map[$Matches[1]] = ($Matches[2] -replace '\s+#.*$', '').Trim()
        }
    }
    return $map
}

# Sends the commands over an mpv JSON IPC pipe; returns request_id -> the answer.
function Invoke-MpvIpc([string]$PipePath, [object[]]$Commands, [int]$Wait) {
    $name = $PipePath -replace '^\\\\\.\\pipe\\', ''
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut)
    $answers = @{}
    try {
        $client.Connect($Wait)
        $writer = New-Object System.IO.StreamWriter($client)
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client)
        $id = 0
        foreach ($c in $Commands) {
            $id++
            $writer.Write((@{ command = $c; request_id = $id } | ConvertTo-Json -Compress -Depth 5) + "`n")
        }
        $deadline = (Get-Date).AddMilliseconds($Wait)
        while ($answers.Count -lt $Commands.Count) {
            $left = [int]($deadline - (Get-Date)).TotalMilliseconds
            if ($left -le 0) { break }
            $task = $reader.ReadLineAsync()
            if (-not $task.Wait($left)) { break }
            $line = $task.Result
            if ($null -eq $line) { break }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.PSObject.Properties['request_id'] -and $obj.request_id) { $answers[[int]$obj.request_id] = $obj }
        }
    } finally {
        $client.Dispose()
    }
    return $answers
}

# The binding mpv uses for a key: the highest priority, a strong one before a weak one.
function Get-ActiveBinding([object[]]$Bindings, [string]$Key) {
    $mine = @($Bindings | Where-Object { $_.key -ceq $Key })
    if ($mine.Count -eq 0) { return $null }
    return $mine | Sort-Object @{ Expression = { [int]$_.priority }; Descending = $true }, @{ Expression = { [bool]$_.is_weak } } |
        Select-Object -First 1
}

# Options only: addresses (a stream's URL, a file's path) stay off the screen.
function Get-OptionText([string]$CommandLine) {
    $tokens = [regex]::Matches($CommandLine, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }
    $opts = @($tokens | Select-Object -Skip 1 | Where-Object { $_ -like '--*' } | ForEach-Object {
            $_ -replace '(https?|ytdl|edl)://\S*', '<address>' -replace '(=)[A-Za-z]:\\\S*', '$1<path>'
        })
    $others = @($tokens | Select-Object -Skip 1 | Where-Object { $_ -notlike '--*' }).Count
    return (($opts -join ' ') + $(if ($others) { " (+ $others address(es))" } else { '' })).Trim()
}

$expected = Get-ExpectedBinding
Write-Host "This setup: $Root"
Write-Host ''

$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'mpv.exe'" -ErrorAction SilentlyContinue)
$pipes = [ordered]@{}
foreach ($p in $Pipe) { $pipes[$p] = $null }
if ($procs.Count -eq 0 -and $pipes.Count -eq 0) {
    Write-Host 'No mpv is running. Run this while the mpv that ignores your keys is open.'
    exit 0
}
Write-Host "mpv windows running: $($procs.Count)"
foreach ($p in $procs) {
    $parent = Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue
    $cl = [string]$p.CommandLine
    Write-Host ''
    Write-Host ("- process {0}: {1}" -f $p.ProcessId, $p.ExecutablePath)
    Write-Host ("  started by: {0}" -f $(if ($parent) { $parent.ProcessName + '.exe' } else { 'a process that has ended' }))
    Write-Host ("  options: {0}" -f $(if ($cl) { Get-OptionText $cl } else { '(not readable)' }))
    if ($p.ExecutablePath -and -not [string]::Equals((Split-Path -Parent $p.ExecutablePath), $Root, 'OrdinalIgnoreCase')) {
        Write-Host '  NOTE: another mpv than this setup''s - it has its own config, or none.'
    }
    if ($cl -match '--input-ipc-server=("[^"]+"|\S+)') {
        $pipes[$Matches[1].Trim('"')] = $p.ProcessId
    } else {
        Write-Host '  (no IPC pipe: its keys cannot be asked; FastStream''s mpv always has one)'
    }
}

foreach ($pipePath in $pipes.Keys) {
    Write-Host ''
    $owner = $pipes[$pipePath]
    Write-Host ("Asking {0}{1}:" -f $(if ($pipePath -like '*faststream-mpv*') { 'FastStream''s mpv' } else { 'the mpv on ' + $pipePath }), $(if ($owner) { " (process $owner)" } else { '' }))
    $cmds = @(
        @('get_property', 'mpv-version'),
        @('expand-path', '~~/'),
        @('get_property', 'options/config'),
        @('get_property', 'options/input-default-bindings'),
        @('get_property', 'input-bindings')
    )
    try {
        $a = Invoke-MpvIpc $pipePath $cmds $TimeoutMs
    } catch {
        Write-Host "  no answer: $($_.Exception.Message)"
        continue
    }
    if ($a.Count -lt $cmds.Count) {
        Write-Host "  only $($a.Count) of $($cmds.Count) answers came"
    }
    $val = { param($i) if ($a.ContainsKey($i) -and $a[$i].error -eq 'success') { $a[$i].data } else { $null } }
    $configDir = & $val 2
    $configOn = & $val 3
    Write-Host ("  {0}" -f (& $val 1))
    Write-Host ("  config folder: {0}" -f $configDir)
    Write-Host ("  config files read: {0}" -f $configOn)
    $bindings = @(& $val 5)
    $wrong = @()
    foreach ($k in $Keys) {
        $b = Get-ActiveBinding $bindings $k
        $cmd = if ($b) { [string]$b.cmd } else { '(nothing)' }
        $want = $expected[$k]
        $same = $want -and ($cmd -replace '\s+', ' ').Trim() -eq ($want -replace '\s+', ' ').Trim()
        if (-not $same) { $wrong += $k }
        Write-Host ("    {0}  {1,-48} {2}" -f $k, $(if ($cmd.Length -gt 48) { $cmd.Substring(0, 45) + '...' } else { $cmd }),
            $(if ($same) { 'this setup''s' } elseif ($b) { "NOT this setup's (from $($b.section))" } else { 'NOT bound' }))
    }
    # mpv writes the folder with forward slashes
    $ownConfig = $configDir -and [string]::Equals(($configDir -replace '/', '\').TrimEnd('\'), (Join-Path $Root 'portable_config'), 'OrdinalIgnoreCase')
    Write-Host ''
    if ($configOn -eq $false) {
        Write-Host '  VERDICT: this mpv was started without config files (--no-config): mpv''s standard keys.'
    } elseif (-not $ownConfig) {
        Write-Host "  VERDICT: this mpv reads another config folder ($configDir), not this setup's."
    } elseif ($wrong.Count -gt 0) {
        Write-Host ("  VERDICT: this setup's config, but these keys differ: {0}." -f ($wrong -join ', '))
    } else {
        Write-Host '  VERDICT: this mpv has this setup''s keys. If they still do nothing, the key presses go to'
        Write-Host '  another window: click into the mpv picture once, and check no other program grabs them.'
    }
}
exit 0
