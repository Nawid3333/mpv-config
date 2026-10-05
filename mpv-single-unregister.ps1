# Reverses mpv-single-register.ps1: removes the mpv-single.File ProgId and
# its OpenWithProgids entry from every extension it was added to.
# If you'd set it as your default app for some file type, Windows will fall
# back to asking you to pick a new default the next time you open that type.
#
# What is not there is skipped; what is there but cannot be removed is named
# at the end, with exit 1 (until 2026-10-05 every error was hidden, and it said
# "Unregistered" whatever happened).

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

foreach ($ext in $extensions) {
    $key = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    if ($null -eq (Get-ItemProperty -Path $key -Name $progId -ErrorAction SilentlyContinue)) { continue }
    try {
        Remove-ItemProperty -Path $key -Name $progId
    }
    catch {
        $failed += "$ext ($($_.Exception.Message))"
    }
}

$progIdKey = "HKCU:\Software\Classes\$progId"
if (Test-Path $progIdKey) {
    try {
        Remove-Item -Path $progIdKey -Recurse -Force
    }
    catch {
        $failed += "$progId ($($_.Exception.Message))"
    }
}

if ($failed.Count -gt 0) {
    Write-Warning "Could not remove: $($failed -join '; ')"
    exit 1
}
Write-Host "Unregistered 'mpv (single instance)' ($progId)."
