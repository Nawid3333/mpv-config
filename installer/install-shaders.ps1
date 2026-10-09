# install-shaders.ps1 - download the GLSL shaders the upscale presets use into
# portable_config/shaders (idempotent; safe to re-run). See RECREATE.md
# section 3 step 4.
#
# Only the files gpu-toggles.lua actually references are installed (trimmed
# 2026-09-21 from the full Anime4K pack + ArtCNN + SSimDownscaler, none of
# which any preset uses any more - keep this list in sync with the presets):
#  - Anime4K v4.0.1 (bloc97/Anime4K release zip): the 6 files of the Anime
#    preset (UPSCALE_ANIME): Clamp_Highlights, Upscale_Denoise_CNN_x2_VL,
#    AutoDownscalePre_x2, AutoDownscalePre_x4, Restore_CNN_M, Upscale_CNN_x2_M;
#    and since 2026-10-09 the 3 more of its "Fast" set (UPSCALE_ANIME_FAST, the
#    upscaling quality for slower GPUs - Anime4K's own low-end template):
#    Upscale_Denoise_CNN_x2_M, Restore_CNN_S, Upscale_CNN_x2_S.
#  - FSRCNNX (igv/FSRCNN-TensorFlow release 1.1): Movie preset at >=2x.
#  - SSimSuperRes (canonical copy from dyphire/mpv-config; igv's own repos are
#    gone; LGPL, Shiandow), pinned to commit 07619250dd3f (2023-01-24, the
#    file's last change there, byte-identical to the repo's copy; it was
#    fetched from master until 2026-10-02): Movie preset at every ratio.
#  - adaptive-sharpen.glsl (bacondither, igv's mpv port) is NOT downloaded: the
#    repo carries a locally modified copy (curve_height turned into a runtime
#    PARAM - see the note at the top of the file), and upstream's plain copy
#    would silently ignore the Movie sharpness setting. Below it is only
#    checked to be there (git checks its content); restore it with
#    `git checkout -- portable_config/shaders`.
#  - CfL_Prediction (Artoriuz/glsl-chroma-from-luma-prediction, MIT), pinned to
#    upstream commit 066dff964b83 (2026-08-15): Movie preset chroma upscaling.
# Anything else (the rest of Anime4K, ArtCNN, SSimDownscaler, ...) can be
# fetched by hand or restored from git history if a future experiment wants it.
#
# Every downloaded file is checked against the SHA-256 of the repo's copy (its
# text with CRLF read as LF, as git checks it out): a file that is there but
# damaged - a download cut short used to count as "already present" for good -
# is fetched again, a download goes to a .part file first, and one that does
# not match is refused (2026-10-02).

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub needs it (as install-mpv.ps1)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$dst = Join-Path $PSScriptRoot '..\portable_config\shaders'
New-Item -ItemType Directory -Path $dst -Force | Out-Null

$anime4kZip = 'https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip'
$anime4kFiles = [ordered]@{
    'Anime4K_Clamp_Highlights.glsl'          = 'a2a9bf7fbc1d75d09660ca2e701e4d7fb0cf5457b94da47e1825032fa2b3671a'
    'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl' = '359c48fe5a317fbc6b706ce368401eef496e84ed98abac7a43efebca2b65d79b'
    'Anime4K_AutoDownscalePre_x2.glsl'       = '8c58291740146bd766a4d73f132775a797fe80f7d07919b5d767e27a5dc85656'
    'Anime4K_AutoDownscalePre_x4.glsl'       = '5af62d8cd844916dc1126613e13bad3beab195787f93a71200b47c6ec78f2e41'
    'Anime4K_Restore_CNN_M.glsl'             = '67ea3ed26539e8de3b7d307688535d2ff17e8d147e11dda0247da7770dbecf41'
    'Anime4K_Upscale_CNN_x2_M.glsl'          = '716e02098a68f0d648761f2b96b4dd139e1cb09b174bb369fca3aa34328fff7e'
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl'  = '8c72b042e2301fe66a45c3089720459148e2504cd72af16f9c0d5017ff14181e'
    'Anime4K_Restore_CNN_S.glsl'             = '97c24dc370ab300c108bfaa09db7f175aeff343674842c299cf3940a3d330427'
    'Anime4K_Upscale_CNN_x2_S.glsl'          = '4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4'
}
$glslFiles = @(
    @{ u = 'https://github.com/igv/FSRCNN-TensorFlow/releases/download/1.1/FSRCNNX_x2_16-0-4-1.glsl'; n = 'FSRCNNX_x2_16-0-4-1.glsl'; h = 'd5a24a271e5d9a3f7f7a053b150c460a44c25b3cf7f770857d57cc3a2e1c9965' },
    @{ u = 'https://raw.githubusercontent.com/dyphire/mpv-config/07619250dd3fcb85e1ad5843ba91f6b4cd560d21/shaders/igv/SSimSuperRes.glsl'; n = 'SSimSuperRes.glsl'; h = 'a8b27115840c60045250411b375e0188000217258ad776eeb51724c97815460f' },
    @{ u = 'https://raw.githubusercontent.com/Artoriuz/glsl-chroma-from-luma-prediction/066dff964b83aa34e893de25d590874bf8c8e94f/CfL_Prediction.glsl'; n = 'CfL_Prediction.glsl'; h = 'f9d12d38d4bab4d9db266b5982c81fadca907396212e22fd8b2c1ca2f317b716' }
)

# Tracked in git, not downloaded (see the header).
$repoFiles = @('adaptive-sharpen.glsl')

$ProgressPreference = 'SilentlyContinue'

# SHA-256 of a shader's text with CRLF read as LF: git checks these out LF
# (.gitattributes), and an upstream copy with CRLF is the same shader.
function Get-ShaderHash([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

# True when the file is there and is the expected shader.
function Test-Shader([string]$Path, [string]$Hash) {
    return (Test-Path -LiteralPath $Path) -and ((Get-ShaderHash $Path) -eq $Hash)
}

# Puts a downloaded or extracted file in place once it is the expected shader.
function Install-Shader([string]$Source, [string]$Name, [string]$Hash) {
    if ((Get-ShaderHash $Source) -ne $Hash) {
        throw "$Name does not match its expected SHA-256 ($Hash): not installed."
    }
    Move-Item -LiteralPath $Source -Destination (Join-Path $dst $Name) -Force
}

# --- Anime4K (only the files the Anime preset uses, out of the release zip) ---
$missingA4k = @($anime4kFiles.Keys | Where-Object { -not (Test-Shader (Join-Path $dst $_) $anime4kFiles[$_]) })
if ($missingA4k.Count -eq 0) {
    Write-Host 'Anime4K files already present - skipping' -ForegroundColor Yellow
}
else {
    Write-Host 'Downloading Anime4K v4.0.1 ...' -ForegroundColor Cyan
    $zip = Join-Path $env:TEMP 'Anime4K_v4.0.zip'
    $tmp = Join-Path $env:TEMP 'a4k_extract'
    try {
        Invoke-WebRequest -Uri $anime4kZip -OutFile $zip -UseBasicParsing
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        foreach ($n in $missingA4k) {
            Install-Shader (Join-Path $tmp $n) $n $anime4kFiles[$n]
        }
    }
    finally {
        Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- single glsl files -------------------------------------------------------
foreach ($f in $glslFiles) {
    $target = Join-Path $dst $f.n
    if (Test-Shader $target $f.h) {
        Write-Host "$($f.n) already present - skipping" -ForegroundColor Yellow
    }
    else {
        Write-Host "Downloading $($f.n) ..." -ForegroundColor Cyan
        $part = "$target.part"
        try {
            Invoke-WebRequest -Uri $f.u -OutFile $part -UseBasicParsing
            Install-Shader $part $f.n $f.h
        }
        finally {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- verify ------------------------------------------------------------------
Write-Host "`nVerify:" -ForegroundColor Green
$missing = @()
foreach ($n in $anime4kFiles.Keys) {
    $ok = Test-Shader (Join-Path $dst $n) $anime4kFiles[$n]
    if (-not $ok) { $missing += $n }
    Write-Host "  $n : $ok"
}
foreach ($f in $glslFiles) {
    $ok = Test-Shader (Join-Path $dst $f.n) $f.h
    if (-not $ok) { $missing += $f.n }
    Write-Host "  $($f.n) : $ok"
}
foreach ($n in $repoFiles) {
    $ok = Test-Path (Join-Path $dst $n)
    if (-not $ok) { $missing += $n }
    Write-Host "  $n : $ok"
}
if ($missing.Count -gt 0) {
    Write-Warning "Shader install incomplete (missing or damaged: $($missing -join ', ')) - re-run this script;"
    Write-Warning "adaptive-sharpen.glsl comes from git: git checkout -- portable_config/shaders"
    exit 1
}

Write-Host "`nThe upscale presets (upscale button: left-click cycles Off / Auto / Anime / Movie;" -ForegroundColor Green
Write-Host 'Shift+A turns Anime on and off, Shift+Y Movie):' -ForegroundColor Green
Write-Host '  Anime            : Anime4K C+A (HQ), all resolutions; quality Fast: Anime4K C+A (Fast)'
Write-Host '  Movie (<2x)      : SSimSuperRes + CfL chroma + adaptive-sharpen'
Write-Host '  Movie (>=2x)     : FSRCNNX + SSimSuperRes + CfL chroma + adaptive-sharpen'
Write-Host '  (sharpening strength: upscale menu > Movie sharpness, default in script-opts/gpu_toggles.conf)'
Write-Host '  (Auto only applies to FastStream content and picks Anime/Movie by content type;'
Write-Host '   Movie picks its row by the real display scale - see gpu-toggles.lua)'
