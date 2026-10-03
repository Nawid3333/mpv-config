# Reverses mpv-single-register.ps1: removes the mpv-single.File ProgId and
# its OpenWithProgids entry from every extension it was added to.
# If you'd set it as your default app for some file type, Windows will fall
# back to asking you to pick a new default the next time you open that type.

$ErrorActionPreference = "SilentlyContinue"

$extensions = @(
    ".3g2",".3gp",".3gp2",".3gpp",".aac",".ac3",".adt",".adts",".asf",".avi",
    ".ec3",".flac",".m1v",".m2t",".m2ts",".m2v",".m3u",".m4a",".m4v",".mka",
    ".mkv",".mod",".mov",".mp2",".mp2v",".mp3",".mp4",".mp4v",".mpa",".mpe",
    ".mpeg",".mpg",".mpv2",".mts",".oga",".ogg",".ogm",".ogv",".ogx",".opus",
    ".tod",".ts",".tts",".wav",".webm",".wm",".wma",".wmv",".wpl"
)

$progId = "mpv-single.File"

foreach ($ext in $extensions) {
    Remove-ItemProperty -Path "HKCU:\Software\Classes\$ext\OpenWithProgids" -Name $progId
}

Remove-Item -Path "HKCU:\Software\Classes\$progId" -Recurse -Force

Write-Host "Unregistered 'mpv (single instance)' ($progId)."
