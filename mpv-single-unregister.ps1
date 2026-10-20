# Reverses mpv-single-register.ps1: mpv's own file types get back the command
# they had (the one kept in mpv-single-was; '' = the PC's entry, so the user's
# command over it goes), and the mpv-single.File ProgId and its OpenWithProgids
# entries go. If you'd set "mpv (single instance)" as your default app for some
# file type, Windows will ask you to pick a new default the next time you open
# that type.
#
# What is not there is skipped; what is there but cannot be removed is named
# at the end, with exit 1.
#
# -ClassesRoot: where register wrote (the tests).
param(
    [string]$ClassesRoot = 'HKCU:\Software\Classes'
)

$ErrorActionPreference = "Stop"

$extensions = @(
    ".3g2",".3gp",".3gp2",".3gpp",".aac",".ac3",".adt",".adts",".asf",".avi",
    ".ec3",".flac",".m1v",".m2t",".m2ts",".m2v",".m3u",".m4a",".m4v",".mka",
    ".mkv",".mod",".mov",".mp2",".mp2v",".mp3",".mp4",".mp4v",".mpa",".mpe",
    ".mpeg",".mpg",".mpv2",".mts",".oga",".ogg",".ogm",".ogv",".ogx",".opus",
    ".tod",".ts",".tts",".wav",".webm",".wm",".wma",".wmv",".wpl"
)

$progId = "mpv-single.File"
$failed = @()

# Removes a key and then each parent up to $Top that is left empty.
function Remove-EmptyUp([string]$Path, [string]$Top) {
    Remove-Item -LiteralPath $Path -Recurse -Force
    $parent = Split-Path -Parent $Path
    while ($parent -and $parent.Length -gt $Top.Length) {
        $key = Get-Item -LiteralPath $parent -ErrorAction SilentlyContinue
        if (-not $key -or $key.SubKeyCount -gt 0 -or $key.ValueCount -gt 0) { break }
        Remove-Item -LiteralPath $parent -Force
        $parent = Split-Path -Parent $parent
    }
}

# mpv's own file types: every command register replaced - and still this
# folder's launcher: one another mpv's register wrote since is that mpv's now
$launcherCommand = '"' + (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'mpv-single.exe') + '" "%1"'
$names = @('Applications\mpv.exe', 'mpv.File')
$classes = Get-Item -LiteralPath $ClassesRoot -ErrorAction SilentlyContinue
if ($classes) { $names += $classes.GetSubKeyNames() | Where-Object { $_ -like 'io.mpv.*' } }
foreach ($name in ($names | Sort-Object -Unique)) {
    foreach ($verb in 'open', 'play') {
        $path = "$ClassesRoot\$name\shell\$verb\command"
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $key -or $key.GetValueNames() -notcontains 'mpv-single-was') { continue }
        try {
            $was = "$($key.GetValue('mpv-single-was'))"
            if ("$($key.GetValue(''))" -ne $launcherCommand) {
                Remove-ItemProperty -LiteralPath $path -Name 'mpv-single-was'
            }
            elseif ($was -eq '') {
                Remove-EmptyUp $path "$ClassesRoot\$name"
                # the ProgId itself too, when nothing else was in it
                $top = Get-Item -LiteralPath "$ClassesRoot\$name" -ErrorAction SilentlyContinue
                if ($top -and $top.SubKeyCount -eq 0 -and $top.ValueCount -eq 0) { Remove-Item -LiteralPath "$ClassesRoot\$name" -Force }
            }
            else {
                Set-ItemProperty -LiteralPath $path -Name '(default)' -Value $was
                Remove-ItemProperty -LiteralPath $path -Name 'mpv-single-was'
            }
        }
        catch {
            $failed += "$name $verb ($($_.Exception.Message))"
        }
    }
}

foreach ($ext in $extensions) {
    $key = "$ClassesRoot\$ext\OpenWithProgids"
    if ($null -eq (Get-ItemProperty -Path $key -Name $progId -ErrorAction SilentlyContinue)) { continue }
    try {
        Remove-ItemProperty -Path $key -Name $progId
    }
    catch {
        $failed += "$ext ($($_.Exception.Message))"
    }
}

$progIdKey = "$ClassesRoot\$progId"
if (Test-Path $progIdKey) {
    try {
        Remove-Item -Path $progIdKey -Recurse -Force
    }
    catch {
        $failed += "$progId ($($_.Exception.Message))"
    }
}

Add-Type -Namespace MpvSingle -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
[MpvSingle.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

if ($failed.Count -gt 0) {
    Write-Warning "Could not remove: $($failed -join '; ')"
    exit 1
}
Write-Host "Unregistered 'mpv (single instance)': mpv's file types start mpv.exe again."
