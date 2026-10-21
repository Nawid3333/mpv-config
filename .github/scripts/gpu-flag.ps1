# What of a pull request CI cannot check: its runners have no GPU, so the shaders, the
# renderer and decoder options, and an mpv build whose upstream changes reach video output
# are tested only by the gpu tier on the owner's PC. Such a pull request gets:
#   - "[GPU: <areas>]" in front of its title and the label "gpu",
#   - one comment that lists what it changes there,
#   - the commit status "GPU tier (local)", pending until tests/try-gpu.ps1 has run the gpu
#     tier on the PC against exactly that commit (it sets success or failure).
# A pull request that changes nothing there loses all three (the status turns success).
#
#   pwsh .github/scripts/gpu-flag.ps1 -Pr <number>   (GH_TOKEN, GH_REPO set; gh on PATH)
#
# Dot-sourced without -Pr it only defines Get-GpuReason, for the static tier's checks.
param([int]$Pr, [string]$Repo = $env:GH_REPO)

$GpuStatus = 'GPU tier (local)'

# mpv options that decide what the GPU does: the video output and its context, scaling and
# shaders, colour and HDR, decoding, frame timing.
$GpuOption = '^(vo|gpu-.*|vulkan-.*|d3d11-.*|spirv-.*|hwdec.*|vd-lavc-film-grain|profile|' +
'scale.*|cscale.*|dscale.*|tscale.*|correct-downscaling|linear-.*|sigmoid-.*|glsl-.*|' +
'deband.*|dither.*|temporal-dither.*|error-diffusion|interpolation.*|video-sync.*|' +
'display-fps.*|swapchain-depth|target-.*|tone-mapping.*|hdr-.*|gamut-.*|icc-.*|' +
'video-output-levels|fbo-format|libplacebo-.*|blend-subtitles|opengl-.*|deinterlace.*|vf)$'

# Files of this repository that are GPU work as a whole, by area.
$GpuFile = [ordered]@{
    '^portable_config/shaders/'                  = 'shaders'
    '^installer/install-shaders\.ps1$'           = 'shaders'
    '^portable_config/Scripts/gpu-toggles\.lua$' = 'gpu-toggles'
    '^portable_config/script-opts/gpu_toggles'   = 'gpu-toggles'
    '^portable_config/Scripts/shader-cache/'     = 'shader cache'
    '^tests/gpu/'                                = 'gpu tests'
}

# The video output paths in mpv's source, by the area named in the title.
$MpvArea = [ordered]@{
    'vulkan'   = '^video/out/vulkan/'
    'gpu-next' = '^video/out/(gpu_next/|placebo/|vo_gpu_next\.c)'
    'renderer' = '^video/out/(gpu/|vo_gpu\.c|vo\.[ch]$|filter_kernels\.)'
    'd3d11'    = '^video/out/d3d11/'
    'hwdec'    = '^video/(out/hwdec/|hwdec\.|d3d\.)'
    'window'   = '^video/out/(w32_common\.|win32/)'
    'timing'   = '^player/video\.c$'
    # which decoder runs, hardware or not (vd_lavc picks d3d11va-copy)
    'decoding' = '^video/decode/'
    # colour spaces and pixel formats, what the renderer is handed
    'color'    = '^video/(csputils|mp_image|img_format|fmt-conversion|repack)'
}
# FFmpeg: the D3D11 decoding the config uses (hwdec=d3d11va-copy), and the hardware
# decoding layer under it.
$FfmpegD3d11 = '^(libavcodec/(d3d11va|dxva2|hwaccel|hwconfig)|libavutil/hwcontext(\.|_internal|_d3d11va|_dxva2))'
# The decoders of what plays here, where get_format offers D3D11VA its formats, and the
# decode layer above them: mostly code of every codec, they change often, so they count only
# when a line their diff changes (not its context) touches hardware decoding - or with no
# diff to read
$FfmpegDecoder = '^libavcodec/(h264dec|hevc/hevcdec|hevcdec|av1dec|vp9|mpeg12dec)\.c$|^libavcodec/decode\.[ch]$'
$FfmpegHwWord = 'hwaccel|HWACCEL|d3d11|D3D11|dxva|DXVA|get_format|hw_pix_fmt'
# The HDR metadata tone mapping reads (mastering display, content light level, dynamic)
$FfmpegHdr = '^(libavcodec/(h2645_sei|hevc/sei)|libavutil/(mastering_display_metadata|hdr_dynamic_metadata))'

# The reasons a change needs the gpu tier, as @{ Area; Detail } - none for a change that
# needs none.
#   Files      the pull request's files, as GitHub lists them: filename, patch (or none)
#   OldBuild   main's mpv-build.json and the pull request's (parsed), when it changes it
#   NewBuild
#   MpvFiles   the files mpv's source changed between the two builds' commits; $null when
#              GitHub could not say, which counts as a change of everything
#   FfmpegFiles  the same for FFmpeg: names, or objects with filename and patch (the diff)
#   Unread     what could not be read (a file list GitHub cut short, a build file it did not
#              return): each counts as a change the gpu tier must see - never as none
function Get-GpuReason {
    param([object[]]$Files, [object]$OldBuild, [object]$NewBuild, [string[]]$MpvFiles, [object[]]$FfmpegFiles, [string[]]$Unread)
    $reasons = [Collections.Generic.List[object]]::new()
    $add = { param($area, $detail) $reasons.Add([pscustomobject]@{ Area = $area; Detail = $detail }) }
    # a field GitHub leaves out (or a test's object lacks): $null, also under strict mode
    $field = { param($o, $n) $p = $o.PSObject.Properties[$n]; if ($p) { $p.Value } }
    foreach ($u in $Unread) { & $add 'unknown' $u }
    foreach ($f in $Files) {
        $name = $f.filename
        $patch = & $field $f 'patch'
        # a renamed file by its old name too: gpu-toggles.lua moved away is still GPU work
        $names = @($name, (& $field $f 'previous_filename')) | Where-Object { $_ }
        $area = $GpuFile.Keys | Where-Object { $k = $_; $names | Where-Object { $_ -match $k } } | Select-Object -First 1
        if ($area) {
            & $add $GpuFile[$area] $name
            continue
        }
        # GitHub sends no patch for a diff too large to show: its lines cannot be read
        if (-not $patch -and ($name -eq 'portable_config/mpv.conf' -or $name -like 'portable_config/*.lua') -and (& $field $f 'status') -ne 'removed') {
            & $add 'unknown' "$name (its diff is too large to read)"
            continue
        }
        # A line changed in mpv.conf that sets one of those options, or a script line
        # that names one in quotes (a property it sets or reads).
        $changed = @("$patch" -split "`n" | Where-Object { $_ -match '^[+-](?![+-])' } | ForEach-Object { $_.Substring(1) })
        $options = [Collections.Generic.SortedSet[string]]::new()
        if ($name -eq 'portable_config/mpv.conf') {
            foreach ($line in $changed) {
                if ($line -match '^\s*([a-z0-9-]+)\s*=' -and $Matches[1] -match $GpuOption) { [void]$options.Add($Matches[1]) }
            }
            foreach ($o in $options) { & $add 'mpv.conf' $o }
        }
        elseif ($name -like 'portable_config/*.lua') {
            foreach ($line in $changed) {
                if ($line -match '^\s*--') { continue }
                foreach ($m in [regex]::Matches($line, '[''"](?:options/|file-local-options/)?([a-z0-9-]+)[''"]')) {
                    if ($m.Groups[1].Value -match $GpuOption -and $m.Groups[1].Value -ne 'profile') { [void]$options.Add($m.Groups[1].Value) }
                }
            }
            foreach ($o in $options) { & $add 'scripts' "$(Split-Path -Leaf $name): $o" }
        }
    }
    if ($NewBuild -and $OldBuild -and "$($NewBuild.git)" -ne "$($OldBuild.git)") {
        if ($null -eq $MpvFiles) {
            & $add 'mpv' "what changed in mpv's source between $($OldBuild.git) and $($NewBuild.git) is unknown"
        }
        else {
            foreach ($area in $MpvArea.Keys) {
                $hit = @($MpvFiles | Where-Object { $_ -match $MpvArea[$area] })
                if ($hit.Count) { & $add $area "mpv: $($hit -join ', ')" }
            }
        }
    }
    if ($NewBuild -and $OldBuild -and "$($NewBuild.libplacebo)" -ne "$($OldBuild.libplacebo)") {
        & $add 'libplacebo' "$($OldBuild.libplacebo) -> $($NewBuild.libplacebo)"
    }
    if ($NewBuild -and $OldBuild -and "$($NewBuild.ffmpeg)" -ne "$($OldBuild.ffmpeg)") {
        if ($null -eq $FfmpegFiles) {
            & $add 'FFmpeg' "what changed in FFmpeg between $($OldBuild.ffmpeg) and $($NewBuild.ffmpeg) is unknown"
        }
        else {
            $hit = @()
            $hdr = @()
            foreach ($f in $FfmpegFiles) {
                $name = if ($f -is [string]) { $f } else { $f.filename }
                $diff = if ($f -is [string]) { $null } else { & $field $f 'patch' }
                $changedLines = if ($diff) { ($diff -split "`n" | Where-Object { $_ -match '^[+-](?![+-])' }) -join "`n" } else { '' }
                if ($name -match $FfmpegD3d11 -or ($name -match $FfmpegDecoder -and (-not $diff -or $changedLines -match $FfmpegHwWord))) {
                    $hit += $name
                }
                if ($name -match $FfmpegHdr) { $hdr += $name }
            }
            if ($hit.Count) { & $add 'FFmpeg d3d11va' "FFmpeg: $($hit -join ', ')" }
            if ($hdr.Count) { & $add 'FFmpeg HDR' "FFmpeg: $($hdr -join ', ')" }
        }
    }
    return , $reasons.ToArray()
}

# "[GPU: a, b, c]" for the title, at most three areas named
function Get-GpuTag([object[]]$Reasons) {
    $areas = @($Reasons | ForEach-Object Area | Select-Object -Unique)
    if (-not $areas.Count) { return '' }
    $shown = ($areas | Select-Object -First 3) -join ', '
    if ($areas.Count -gt 3) { $shown += " +$($areas.Count - 3)" }
    return "[GPU: $shown]"
}

if (-not $Pr) { return }

$ErrorActionPreference = 'Stop'
if (-not $Repo) { throw 'GH_REPO is not set' }

function Invoke-Gh([string[]]$Arguments) {
    $out = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed ($LASTEXITCODE)" }
    return $out
}
# A file of the repository at a commit, parsed; $null when it is not there.
function Get-BuildAt([string]$Sha) {
    $raw = & gh api -H 'Accept: application/vnd.github.raw' "repos/$Repo/contents/mpv-build.json?ref=$Sha"
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($raw -join "`n") | ConvertFrom-Json
}
# The files a repository's history changed between two commits, each with its diff (patch,
# none for a large one); $null when GitHub cannot say - also when it says only part: its
# compare lists at most 300 files and 250 commits.
function Get-ChangedFile([string]$Upstream, [string]$From, [string]$To) {
    if (-not $From -or -not $To) { return $null }
    $json = & gh api "repos/$Upstream/compare/$From...$To" --jq '{commits: .total_commits, files: [.files[] | {filename, patch}]}'
    if ($LASTEXITCODE -ne 0) { return $null }
    $compare = ($json -join "`n") | ConvertFrom-Json
    if ($compare.commits -ge 250 -or @($compare.files).Count -ge 300) { return $null }
    return , @($compare.files)
}

$pull = Invoke-Gh @('api', "repos/$Repo/pulls/$Pr") | ConvertFrom-Json
$sha = $pull.head.sha
$files = @(Invoke-Gh @('api', '--paginate', "repos/$Repo/pulls/$Pr/files", '--jq', '.[] | {filename, patch, status, previous_filename}') |
        ForEach-Object { $_ | ConvertFrom-Json })
$unread = @()
# GitHub lists at most 3000 files of a pull request
if ($files.Count -lt $pull.changed_files) { $unread += "GitHub listed $($files.Count) of its $($pull.changed_files) files" }
$old = $new = $mpvFiles = $ffmpegFiles = $null
if (@($files.filename) -contains 'mpv-build.json') {
    $old = Get-BuildAt $pull.base.sha
    $new = Get-BuildAt $sha
    if ($old -and $new) {
        $mpvChanged = Get-ChangedFile 'mpv-player/mpv' $old.git $new.git
        $mpvFiles = if ($null -ne $mpvChanged) { , @($mpvChanged | ForEach-Object filename) } else { $null }
        $hash = { param($v) if ("$v" -match '-g([0-9a-f]{7,})') { $Matches[1] } }
        $ffmpegFiles = Get-ChangedFile 'FFmpeg/FFmpeg' (& $hash $old.ffmpeg) (& $hash $new.ffmpeg)
    }
    else { $unread += 'mpv-build.json could not be read on both sides, so what the new build changes is not known' }
}
$reasons = Get-GpuReason -Files $files -OldBuild $old -NewBuild $new -MpvFiles $mpvFiles -FfmpegFiles $ffmpegFiles -Unread $unread
$tag = Get-GpuTag $reasons
Write-Host "#${Pr}: $(if ($tag) { $tag } else { 'nothing for the GPU' })"
foreach ($r in $reasons) { Write-Host "  $($r.Area): $($r.Detail)" }

# The status first, on this very commit: pending until the gpu tier has run on it. Before
# the title, label and comment, so a run that ends half way (cancelled by a newer push, an
# API error) never leaves a flagged pull request without it.
$states = @(Invoke-Gh @('api', "repos/$Repo/commits/$sha/statuses", '--jq', ".[] | select(.context == `"$GpuStatus`") | .state"))
if ($tag -and $states.Count -eq 0) {
    $null = Invoke-Gh @('api', '-X', 'POST', "repos/$Repo/statuses/$sha", '-f', 'state=pending', '-f', "context=$GpuStatus",
        '-f', "description=Not run yet: pwsh tests	ry-gpu.ps1 -Pr $Pr on the PC")
}

# the title
$bare = $pull.title -replace '^\[GPU[^\]]*\]\s*', ''
$title = if ($tag) { "$tag $bare" } else { $bare }
if ($title -ne $pull.title) { $null = Invoke-Gh @('api', '-X', 'PATCH', "repos/$Repo/pulls/$Pr", '-f', "title=$title") }

# the label
$labels = @($pull.labels.name)
if ($tag -and $labels -notcontains 'gpu') {
    $null = & gh label create gpu --repo $Repo --color 'D93F0B' --description 'Changes the GPU pipeline: run tests/try-gpu.ps1 before merging' 2>$null
    $null = Invoke-Gh @('api', '-X', 'POST', "repos/$Repo/issues/$Pr/labels", '-f', 'labels[]=gpu')
}
elseif (-not $tag -and $labels -contains 'gpu') {
    $null = Invoke-Gh @('api', '-X', 'DELETE', "repos/$Repo/issues/$Pr/labels/gpu")
}

# the comment, one per pull request, edited in place
$marker = '<!-- gpu-flag -->'
$existing = Invoke-Gh @('api', '--paginate', "repos/$Repo/issues/$Pr/comments", '--jq', ".[] | select(.body | contains(`"$marker`")) | .id") | Select-Object -First 1
$body = if ($tag) {
    $lines = @("This pull request changes what CI cannot test (its runners have no GPU):", '')
    $lines += @($reasons | ForEach-Object { "- **$($_.Area)**: $($_.Detail)" })
    $lines += @('', "Before merging: on the PC, with no mpv open, ``pwsh tests\try-gpu.ps1 -Pr $Pr`` runs the gpu tier against this pull request's commit (and mpv build) and sets the check **$GpuStatus**.", '', $marker)
    $lines -join "`n"
}
elseif ($new) {
    # an mpv build with nothing for the GPU: said in so many words, so it can be merged on green
    @("**Nothing GPU-related in this mpv build.** mpv's own changes since the pinned build ($($old.git) -> $($new.git)) touch no video output, decoding or colour code, libplacebo is the same, and FFmpeg's changes touch no hardware decoding: the regression suite on CI covers this update. **Merge it when every check is green.**", '', $marker) -join "`n"
}
elseif ($existing) { "Nothing GPU-related in this pull request any more.`n`n$marker" }
if ($body -and $existing) { $null = Invoke-Gh @('api', '-X', 'PATCH', "repos/$Repo/issues/comments/$existing", '-f', "body=$body") }
elseif ($body) { $null = Invoke-Gh @('api', '-X', 'POST', "repos/$Repo/issues/$Pr/comments", '-f', "body=$body") }

# nothing for the GPU: the check says so (a result try-gpu.ps1 set stays)
if (-not $tag -and ($states.Count -eq 0 -or $states[0] -eq 'pending')) {
    $null = Invoke-Gh @('api', '-X', 'POST', "repos/$Repo/statuses/$sha", '-f', 'state=success', '-f', "context=$GpuStatus",
        '-f', 'description=Nothing GPU-related changed')
}
