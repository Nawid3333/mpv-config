# Makes a file opened from Explorer play in the mpv window already open
# (mpv-single.exe, see mpv-single.cs) instead of starting another mpv. Per user
# (HKCU), no admin:
#
# 1. mpv's own file types open through mpv-single.exe - the entries
#    mpv-install.bat (io.mpv.<ext>) or mpv --register (io.mpv.file,
#    Applications\mpv.exe) made, whichever your default player is. Only entries
#    whose command starts THIS folder's mpv.exe or mpv.com with nothing but the
#    file are changed: the disc handlers and another mpv's entries stay. An entry
#    of the whole PC (HKLM) gets a per-user command over it - Windows reads the
#    user's first; an entry of this user's has its command replaced. Either way
#    the command it had is kept beside the new one (mpv-single-was, '' for none)
#    for mpv-single-unregister.ps1.
# 2. "mpv (single instance)" in Open with (ProgId mpv-single.File) for the types
#    below, for a PC where mpv's own types are not registered.
#
# Windows does not let a script pick the default app (UserChoice is
# hash-protected, to stop exactly this kind of hijacking). If mpv is not your
# default player yet: right-click a file -> Open with -> Choose another app ->
# mpv -> Always.
#
# mpv-install.bat and mpv --register write mpv.exe back into their entries: run
# this again after them. mpv-single-unregister.ps1 undoes all of it.
#
# -ClassesRoot (where it writes) and -MergedRoot (what Windows reads: the user's
# entries over the PC's) are there for the tests.
param(
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [string]$MergedRoot = 'Registry::HKEY_CLASSES_ROOT',
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$exeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $exeDir "mpv-single.exe"
$mpvExePath = Join-Path $exeDir "mpv.exe"
$launcherCommand = '"' + $exePath + '" "%1"'

if (-not (Test-Path $exePath)) {
    Write-Error "mpv-single.exe not found next to this script ($exePath). Build it first (see mpv-single.cs)."
    exit 1
}

# mpv's entries whose command starts this folder's mpv with only the file
function Get-MpvCommand {
    $names = @('Applications\mpv.exe', 'mpv.File')
    $merged = Get-Item -LiteralPath $MergedRoot -ErrorAction SilentlyContinue
    if ($merged) { $names += $merged.GetSubKeyNames() | Where-Object { $_ -like 'io.mpv.*' } }
    $mpvs = @((Join-Path $exeDir 'mpv.exe'), (Join-Path $exeDir 'mpv.com'))
    foreach ($name in ($names | Sort-Object -Unique)) {
        foreach ($verb in 'open', 'play') {
            $key = Get-Item -LiteralPath "$MergedRoot\$name\shell\$verb\command" -ErrorAction SilentlyContinue
            $command = if ($key) { "$($key.GetValue(''))" } else { '' }
            if ($command -match '^\s*"?(?<exe>[^"]+?)"?\s+(--\s+)?"%[1L]"\s*$' -and $mpvs -contains $Matches.exe) {
                [pscustomobject]@{ Name = $name; Verb = $verb; Command = $command }
            }
        }
    }
}

$changed = 0
foreach ($entry in @(Get-MpvCommand)) {
    $userKey = "$ClassesRoot\$($entry.Name)\shell\$($entry.Verb)\command"
    $own = Get-Item -LiteralPath $userKey -ErrorAction SilentlyContinue
    # IMPORTANT: New-Item -Force on an EXISTING registry key deletes and
    # recreates it (unlike the filesystem): only for a missing one.
    $was = if ($own) { "$($own.GetValue(''))" } else { '' }
    # a run before this one wrote it: what it kept stays
    if ($was -eq $launcherCommand) { continue }
    if (-not $own) { New-Item -Path $userKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $userKey -Name '(default)' -Value $launcherCommand
    New-ItemProperty -LiteralPath $userKey -Name 'mpv-single-was' -Value $was -PropertyType String -Force | Out-Null
    $changed++
}

$extensions = @(
    ".3g2",".3gp",".3gp2",".3gpp",".aac",".ac3",".adt",".adts",".asf",".avi",
    ".ec3",".flac",".m1v",".m2t",".m2ts",".m2v",".m3u",".m4a",".m4v",".mka",
    ".mkv",".mod",".mov",".mp2",".mp2v",".mp3",".mp4",".mp4v",".mpa",".mpe",
    ".mpeg",".mpg",".mpv2",".mts",".oga",".ogg",".ogm",".ogv",".ogx",".opus",
    ".tod",".ts",".tts",".wav",".webm",".wm",".wma",".wmv",".wpl"
)

$progId = "mpv-single.File"
$progIdKey = "$ClassesRoot\$progId"

New-Item -Path $progIdKey -Force | Out-Null
Set-ItemProperty -Path $progIdKey -Name "(default)" -Value "mpv media file (single instance)"

New-Item -Path "$progIdKey\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$progIdKey\DefaultIcon" -Name "(default)" -Value "$mpvExePath,0"

New-Item -Path "$progIdKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$progIdKey\shell\open\command" -Name "(default)" -Value $launcherCommand

foreach ($ext in $extensions) {
    # Only create the key if it's actually missing (New-Item -Force above).
    $owp = "$ClassesRoot\$ext\OpenWithProgids"
    if (-not (Test-Path $owp)) {
        New-Item -Path $owp -Force | Out-Null
    }
    Set-ItemProperty -Path $owp -Name $progId -Value "" -Type String
}

# Explorer reads the new commands at once, not after a sign-out
Add-Type -Namespace MpvSingle -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
[MpvSingle.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

if (-not $Quiet) {
    if ($changed) {
        Write-Host "mpv's file types ($changed commands) now open in the mpv window already open."
    }
    else {
        Write-Host "mpv's own file types are not registered here (mpv-register.bat or installer\mpv-install.bat does that)."
    }
    Write-Host "Also offered: 'mpv (single instance)' ($progId) in Open with for $($extensions.Count) file types."
    Write-Host "Hold Ctrl while opening a file for a new window."
}
