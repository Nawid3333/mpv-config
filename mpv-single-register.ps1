# Registers mpv-single.exe as a selectable "Open with" app (per-user, HKCU) for
# the same media file types mpv itself registers for (mirrors mpv --register,
# i.e. the mpv.File ProgId), under a separate ProgId: mpv-single.File.
#
# This does NOT change any file's default app - Windows blocks scripts from
# doing that directly (UserChoice is hash-protected since Windows 8 to stop
# exactly this kind of hijacking). You still need to pick it yourself:
#   Right-click a file -> Open with -> More apps -> "mpv (single instance)"
#   -> check "Always use this app" -> OK.
# (Or: Settings -> Apps -> Default apps -> pick it per extension.)
#
# Run mpv-single-unregister.ps1 to remove everything this script adds.

$ErrorActionPreference = "Stop"

$exeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $exeDir "mpv-single.exe"
$mpvExePath = Join-Path $exeDir "mpv.exe"

if (-not (Test-Path $exePath)) {
    Write-Error "mpv-single.exe not found next to this script ($exePath). Build it first (see mpv-single.cs)."
    exit 1
}

$extensions = @(
    ".3g2",".3gp",".3gp2",".3gpp",".aac",".ac3",".adt",".adts",".asf",".avi",
    ".ec3",".flac",".m1v",".m2t",".m2ts",".m2v",".m3u",".m4a",".m4v",".mka",
    ".mkv",".mod",".mov",".mp2",".mp2v",".mp3",".mp4",".mp4v",".mpa",".mpe",
    ".mpeg",".mpg",".mpv2",".mts",".oga",".ogg",".ogm",".ogv",".ogx",".opus",
    ".tod",".ts",".tts",".wav",".webm",".wm",".wma",".wmv",".wpl"
)

$progId = "mpv-single.File"
$progIdKey = "HKCU:\Software\Classes\$progId"

New-Item -Path $progIdKey -Force | Out-Null
Set-ItemProperty -Path $progIdKey -Name "(default)" -Value "mpv media file (single instance)"

New-Item -Path "$progIdKey\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$progIdKey\DefaultIcon" -Name "(default)" -Value "$mpvExePath,0"

New-Item -Path "$progIdKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$progIdKey\shell\open\command" -Name "(default)" -Value ('"' + $exePath + '" "%1"')

foreach ($ext in $extensions) {
    # IMPORTANT: New-Item -Force on an EXISTING registry key deletes and
    # recreates it (unlike the filesystem), which would wipe out every other
    # app already listed here. Only create the key if it's actually missing.
    $owp = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    if (-not (Test-Path $owp)) {
        New-Item -Path $owp -Force | Out-Null
    }
    Set-ItemProperty -Path $owp -Name $progId -Value "" -Type String
}

Write-Host "Registered 'mpv (single instance)' ($progId) for $($extensions.Count) file types."
Write-Host "Now set it as default per file type: right-click a file -> Open with -> More apps -> 'mpv (single instance)' -> Always use this app."
