# tests/lib/gap-media.ps1 - the corpus for `run-tests.ps1 -Tier gaps` (dot-sourced
# there, so Invoke-Mpv is in scope). Every kind of picture real playback can put
# in front of the renderer, as short files: each codec this PC decodes (and the
# path it is decoded on), bit depth, chroma layout, colour tagging (SDR bt.601 /
# bt.709 / bt.2020 / P3, HDR10, HLG), size tier (144p to 8K, 1:1 at 1440p,
# anamorphic, vertical), film grain, stills, cover art and audio-only. Each
# entry also names the conditions find-shader-gaps.lua plays it under
# (fullscreen x chain, window sizes, overlays, equalizer, rotation ...).
#
# Videos are made with this mpv's own encoder (the same one warmup.lua uses),
# stills and audio with ffmpeg (skipped without one). Real files that no
# encoder here can make - Dolby Vision profiles 5/8.1/8.4 and HDR10 with
# mastering metadata - are taken from test-media/shader-corpus if it is there
# (tests/README.md says where they come from). Everything lands in
# %TEMP%\mpv-shader-gaps-media and is reused by later runs.

# Conditions find-shader-gaps.lua knows (see its header). A video plays under
# DEFAULT; the lists below add to it.
$GapDefault = @('fs-off', 'fs-anime', 'fs-movie', 'win-1x')
$GapWindows = @('win-half', 'win-quarter', 'win-max', 'win-1x-anime', 'win-1x-movie')
$GapExtras = @('fs-movie-low', 'fs-movie-high', 'deband-off', 'equalizer', 'eq-contrast', 'eq-brightness', 'eq-gamma', 'eq-saturation', 'eq-hue',
    'rotate', 'rotate-180', 'zoom-out', 'osd', 'rgba-overlay', 'pause', 'subs')

# Size, pixel format, codec, encoder options, colour tags (mpv names -> FFmpeg
# names below), SAR, and whether a FastStream copy (its Auto preset) is played too.
$GapClips = @(
    # the matrix's own kinds, as a control: these must stay clean
    @{ Id = 'h264-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libx264'; Fs = $true; Conds = $GapWindows + $GapExtras }
    @{ Id = 'hevc10-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Fs = $true }
    @{ Id = 'h264-720'; Size = '1280x720'; Pix = 'yuv420p'; Ovc = 'libx264'; Fs = $true; Conds = $GapWindows }
    # other codecs on the GPU decoders
    @{ Id = 'hevc8-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libx265'; Fs = $true }
    @{ Id = 'av1-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libsvtav1'; Opts = 'preset=12'; Fs = $true }
    @{ Id = 'av1-10-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libsvtav1'; Opts = 'preset=12'; Fs = $true }
    @{ Id = 'av1-grain-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libsvtav1'; Opts = 'preset=12,svtav1-params=film-grain=8'; Fs = $true }
    @{ Id = 'av1-grain8-720'; Size = '1280x720'; Pix = 'yuv420p'; Ovc = 'libsvtav1'; Opts = 'preset=12,svtav1-params=film-grain=8' }
    @{ Id = 'vp9-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libvpx-vp9'; Opts = 'deadline=realtime,cpu-used=8'; Fs = $true }
    @{ Id = 'vp9-10-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libvpx-vp9'; Opts = 'deadline=realtime,cpu-used=8'; Fs = $true }
    # DVD, old rips, software-decoded formats
    @{ Id = 'mpeg2-pal-16x9'; Size = '720x576'; Pix = 'yuv420p'; Ovc = 'mpeg2video'; Sar = '64/45'; Tags = @{ Matrix = 'bt.601'; Prim = 'bt.601-625'; Trc = 'bt.1886' } }
    @{ Id = 'mpeg2-ntsc-4x3'; Size = '720x480'; Pix = 'yuv420p'; Ovc = 'mpeg2video'; Sar = '8/9'; Tags = @{ Matrix = 'bt.601'; Prim = 'bt.601-525'; Trc = 'bt.1886' } }
    @{ Id = 'mpeg4-sd-untagged'; Size = '640x352'; Pix = 'yuv420p'; Ovc = 'mpeg4' }
    @{ Id = 'h264-hi10-720'; Size = '1280x720'; Pix = 'yuv420p10le'; Ovc = 'libx264' }
    @{ Id = 'h264-hi10-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx264' }
    @{ Id = 'h264-444-1080'; Size = '1920x1080'; Pix = 'yuv444p'; Ovc = 'libx264' }
    @{ Id = 'hevc-422-10-1080'; Size = '1920x1080'; Pix = 'yuv422p10le'; Ovc = 'libx265' }
    @{ Id = 'hevc-444-1080'; Size = '1920x1080'; Pix = 'yuv444p'; Ovc = 'libx265' }
    @{ Id = 'prores-422-1080'; Size = '1920x1080'; Pix = 'yuv422p10le'; Ovc = 'prores_ks'; Opts = 'profile=3' }
    @{ Id = 'h264-fullrange-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libx264'; Tags = @{ Matrix = 'bt.709'; Prim = 'bt.709'; Trc = 'bt.1886'; Range = 'full' } }
    # colour: SD tagging on HD, bt.2020 SDR, P3
    @{ Id = 'h264-bt601-480'; Size = '854x480'; Pix = 'yuv420p'; Ovc = 'libx264'; Fs = $true; Tags = @{ Matrix = 'bt.601'; Prim = 'bt.601-525'; Trc = 'bt.1886' } }
    @{ Id = 'h264-bt601-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libx264'; Tags = @{ Matrix = 'bt.601'; Prim = 'bt.601-625'; Trc = 'bt.1886' } }
    @{ Id = 'hevc10-bt2020-sdr-2160'; Size = '3840x2160'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Tags = @{ Matrix = 'bt.2020-ncl'; Prim = 'bt.2020'; Trc = 'bt.1886' } }
    @{ Id = 'h264-p3-1080'; Size = '1920x1080'; Pix = 'yuv420p'; Ovc = 'libx264'; Tags = @{ Matrix = 'bt.709'; Prim = 'display-p3'; Trc = 'srgb' } }
    # HDR, synthetic (no mastering metadata - the real files below have it)
    @{ Id = 'hevc-hdr10-2160'; Size = '3840x2160'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Fs = $true; Tags = @{ Matrix = 'bt.2020-ncl'; Prim = 'bt.2020'; Trc = 'pq' }; Conds = $GapWindows + @('fs-movie-high', 'equalizer', 'osd', 'rgba-overlay', 'pause') }
    @{ Id = 'hevc-hdr10-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Fs = $true; Tags = @{ Matrix = 'bt.2020-ncl'; Prim = 'bt.2020'; Trc = 'pq' } }
    @{ Id = 'av1-hdr10-2160'; Size = '3840x2160'; Pix = 'yuv420p10le'; Ovc = 'libsvtav1'; Opts = 'preset=12'; Fs = $true; Tags = @{ Matrix = 'bt.2020-ncl'; Prim = 'bt.2020'; Trc = 'pq' } }
    @{ Id = 'hevc-hlg-1080'; Size = '1920x1080'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Tags = @{ Matrix = 'bt.2020-ncl'; Prim = 'bt.2020'; Trc = 'hlg' } }
    @{ Id = 'hevc-hlg-2160'; Size = '3840x2160'; Pix = 'yuv420p10le'; Ovc = 'libx265'; Tags = @{ Matrix = 'bt.2020-ncl'; Prim = 'bt.2020'; Trc = 'hlg' } }
    # sizes the matrix does not have
    @{ Id = 'h264-144'; Size = '256x144'; Pix = 'yuv420p'; Ovc = 'libx264'; Fs = $true }
    @{ Id = 'h264-240'; Size = '426x240'; Pix = 'yuv420p'; Ovc = 'libx264'; Fs = $true }
    @{ Id = 'h264-1440'; Size = '2560x1440'; Pix = 'yuv420p'; Ovc = 'libx264'; Fs = $true }
    @{ Id = 'vp9-1440'; Size = '2560x1440'; Pix = 'yuv420p'; Ovc = 'libvpx-vp9'; Opts = 'deadline=realtime,cpu-used=8'; Fs = $true }
    @{ Id = 'h264-scope-1712'; Size = '1712x720'; Pix = 'yuv420p'; Ovc = 'libx264' }
    @{ Id = 'h264-hdv-1440x1080'; Size = '1440x1080'; Pix = 'yuv420p'; Ovc = 'libx264'; Sar = '4/3' }
    @{ Id = 'h264-vertical-1080x1920'; Size = '1080x1920'; Pix = 'yuv420p'; Ovc = 'libx264' }
    @{ Id = 'hevc-8k'; Size = '7680x4320'; Pix = 'yuv420p'; Ovc = 'libx265'; Seconds = 2; Conds = @('win-half', 'win-quarter') }
)

# Stills, cover art and audio (ffmpeg): what mpv shows as one picture.
$GapStills = @(
    @{ Id = 'photo-4000x3000.jpg'; Lavfi = 'testsrc2=s=4000x3000:d=1'; Args = @('-frames:v', '1', '-q:v', '3') }
    @{ Id = 'screenshot-1920.png'; Lavfi = 'testsrc2=s=1920x1080:d=1'; Args = @('-frames:v', '1') }
    @{ Id = 'alpha-1250x752.png'; Lavfi = 'testsrc2=s=1250x752:d=1,format=rgba,colorchannelmixer=aa=0.6'; Args = @('-frames:v', '1') }
    @{ Id = 'gray-800x600.png'; Lavfi = 'testsrc2=s=800x600:d=1,format=gray'; Args = @('-frames:v', '1') }
    @{ Id = 'anim-480x270.gif'; Lavfi = 'testsrc2=s=480x270:d=2:r=12'; Args = @() }
)

$FfColour = @{
    Matrix = @{ 'bt.601' = 'smpte170m'; 'bt.709' = 'bt709'; 'bt.2020-ncl' = 'bt2020nc' }
    Prim = @{ 'bt.601-525' = 'smpte170m'; 'bt.601-625' = 'bt470bg'; 'bt.709' = 'bt709'; 'bt.2020' = 'bt2020'; 'display-p3' = 'smpte432' }
    Trc = @{ 'bt.1886' = 'bt709'; 'srgb' = 'iec61966-2-1'; 'pq' = 'smpte2084'; 'hlg' = 'arib-std-b67' }
    Range = @{ 'limited' = 'tv'; 'full' = 'pc' }
}

function Find-Ffmpeg([string]$Exe) {
    $beside = Join-Path (Split-Path -Parent $Exe) 'ffmpeg.exe'
    if (Test-Path $beside) { return $beside }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    return $cmd ? $cmd.Source : $null
}

# One clip with mpv's encoder; $null when this build cannot make it (reported).
function Build-GapClip([string]$Exe, [hashtable]$C, [string]$Dir) {
    $path = Join-Path $Dir "$($C.Id).mkv"
    if (Test-Path -LiteralPath $path) { return $path }
    $seconds = $C["Seconds"] ?? 3
    $chain = "testsrc2=size=$($C.Size):rate=24:duration=$seconds,format=$($C.Pix)"
    if ($C["Sar"]) { $chain += ",setsar=$($C["Sar"])" }
    $opts = @()
    if ($C.Ovc -in 'libx264', 'libx265') { $opts += 'preset=ultrafast' }
    if ($C["Opts"]) { $opts += $C["Opts"] }
    if ($C["Tags"]) {
        # colorspace/range ride on the frames; primaries/transfer must also be
        # encoder options (mpv's encoder drops them from the frames - cases.lua)
        $sp = @()
        if ($C["Tags"]["Matrix"]) { $sp += "colorspace=$($FfColour.Matrix[$C["Tags"]["Matrix"]])"; $opts += "colorspace=$($FfColour.Matrix[$C["Tags"]["Matrix"]])" }
        if ($C["Tags"]["Range"]) { $sp += "range=$($FfColour.Range[$C["Tags"]["Range"]])"; $opts += "color_range=$($FfColour.Range[$C["Tags"]["Range"]])" }
        if ($C["Tags"]["Prim"]) { $sp += "color_primaries=$($FfColour.Prim[$C["Tags"]["Prim"]])"; $opts += "color_primaries=$($FfColour.Prim[$C["Tags"]["Prim"]])" }
        if ($C["Tags"]["Trc"]) { $sp += "color_trc=$($FfColour.Trc[$C["Tags"]["Trc"]])"; $opts += "color_trc=$($FfColour.Trc[$C["Tags"]["Trc"]])" }
        $chain += ',setparams=' + ($sp -join ':')
    }
    $tmp = Join-Path $Dir ('encoding-' + [guid]::NewGuid().ToString('N') + '.mkv')
    $a = @('--no-config', '--really-quiet', "av://lavfi:$chain", "--o=$tmp", "--ovc=$($C.Ovc)")
    if ($opts.Count) { $a += '--ovcopts=' + ($opts -join ',') }
    $r = Invoke-Mpv $Exe $a -TimeoutSeconds 600
    if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1000) {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Add-Result 'shader-gaps' "corpus: $($C.Id)" 'INFO' "this build cannot make it, skipped: $(($r.StdErr -split "`n" | Select-Object -Last 2) -join ' ')"
        return $null
    }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Invoke-Ffmpeg([string]$Ff, [string[]]$A) {
    $p = Start-Process -FilePath $Ff -ArgumentList (@('-hide_banner', '-loglevel', 'error', '-y') + $A | ForEach-Object { $_ -match '[\s"]' ? ('"' + $_.Replace('"', '\"') + '"') : $_ }) -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}

# Builds what is missing and returns the manifest find-shader-gaps.lua reads:
# { path, label, conds[], still } per entry.
function Initialize-GapMedia([string]$Exe, [string]$Dir, [string]$RealDir) {
    New-Item -ItemType Directory -Force $Dir, (Join-Path $Dir 'fs') | Out-Null
    $list = [System.Collections.Generic.List[object]]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($c in $GapClips) {
        $path = Build-GapClip $Exe $c $Dir
        if (-not $path) { continue }
        $list.Add(@{ path = $path; label = $c.Id; conds = @($GapDefault + @($c["Conds"] ?? @())) })
        if ($c["Fs"]) {
            # the FastStream path: the native host's marker in the name turns
            # gpu-toggles' Auto preset on (decoded like any file since 2026-10-04)
            $fs = Join-Path $Dir "fs/$($c.Id)#fs-content=movie.mkv"
            if (-not (Test-Path -LiteralPath $fs)) { Copy-Item -LiteralPath $path -Destination $fs }
            $list.Add(@{ path = $fs; label = "$($c.Id) (FastStream)"; conds = @('fs-off', 'fs-anime', 'fs-movie') })
        }
    }
    $ff = Find-Ffmpeg $Exe
    if ($ff) {
        foreach ($s in $GapStills) {
            $path = Join-Path $Dir $s.Id
            if (-not (Test-Path $path)) { $null = Invoke-Ffmpeg $ff (@('-f', 'lavfi', '-i', $s.Lavfi) + $s.Args + @($path)) }
            if (Test-Path $path) { $list.Add(@{ path = $path; label = $s.Id; conds = @('still', 'still-1x', 'still-anime'); still = $true }) }
        }
        # cover art: a song with a JPEG cover (4:2:0, full range) and one with a
        # 4:4:4 cover - mpv shows it as a still, the window at the cover's size
        foreach ($cv in @(@{ Id = 'song-cover420.flac'; Size = '720x720'; Pix = 'yuvj420p' }, @{ Id = 'song-cover444.flac'; Size = '1000x1000'; Pix = 'yuvj444p' })) {
            $path = Join-Path $Dir $cv.Id
            if (-not (Test-Path $path)) {
                $jpg = Join-Path $Dir "$($cv.Id).jpg"
                $null = Invoke-Ffmpeg $ff @('-f', 'lavfi', '-i', "testsrc2=s=$($cv.Size):d=1", '-frames:v', '1', '-pix_fmt', $cv.Pix, $jpg)
                $null = Invoke-Ffmpeg $ff @('-f', 'lavfi', '-i', 'sine=f=440:d=6', '-i', $jpg, '-map', '0:a', '-map', '1:v', '-c:a', 'flac', '-c:v', 'copy', '-disposition:v:0', 'attached_pic', $path)
            }
            if (Test-Path $path) { $list.Add(@{ path = $path; label = $cv.Id; conds = @('still', 'still-1x'); still = $true }) }
        }
        $tone = Join-Path $Dir 'audio-only.flac'
        if (-not (Test-Path $tone)) { $null = Invoke-Ffmpeg $ff @('-f', 'lavfi', '-i', 'sine=f=440:d=6', '-c:a', 'flac', $tone) }
        if (Test-Path $tone) { $list.Add(@{ path = $tone; label = 'audio-only.flac'; conds = @('still', 'still-1x'); still = $true }) }
        # text subtitles in the video (ASS through libass, like uosc's own UI)
        $subs = Join-Path $Dir 'h264-1080-ass.mkv'
        $base = Join-Path $Dir 'h264-1080.mkv'
        if (-not (Test-Path $subs) -and (Test-Path $base)) {
            $ass = Join-Path $Dir 'subs.ass'
            Set-Content -LiteralPath $ass -Encoding utf8 -Value @(
                '[Script Info]', 'ScriptType: v4.00+', 'PlayResX: 1920', 'PlayResY: 1080', '',
                '[V4+ Styles]', 'Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BorderStyle, Outline, Shadow, Alignment',
                'Style: Default,Arial,64,&H00FFFFFF,&H00000000,1,3,1,2', '',
                '[Events]', 'Format: Layer, Start, End, Style, Text',
                'Dialogue: 0,0:00:00.00,0:00:03.00,Default,A subtitle line on screen')
            $null = Invoke-Ffmpeg $ff @('-i', $base, '-i', $ass, '-map', '0', '-map', '1', '-c', 'copy', $subs)
        }
        if (Test-Path $subs) { $list.Add(@{ path = $subs; label = 'h264-1080 + ASS subtitles'; conds = @('subs', 'subs-anime', 'subs-movie') }) }
    }
    else {
        Add-Result 'shader-gaps' 'corpus: stills, cover art, audio, subtitles' 'SKIP' 'no ffmpeg next to mpv.exe or on PATH'
    }
    # Real files no encoder here makes (Dolby Vision, HDR10 with mastering metadata).
    if ($RealDir -and (Test-Path $RealDir)) {
        foreach ($f in Get-ChildItem -LiteralPath $RealDir -File | Where-Object Extension -In '.mp4', '.mkv', '.ts', '.webm') {
            $list.Add(@{ path = $f.FullName; label = "real: $($f.BaseName)"; conds = @($GapDefault + @('win-half', 'win-quarter', 'pause')) })
            if ($f.Name -match 'AV1 HDR10|HEVC HDR10') {
                $fs = Join-Path $Dir "fs/$($f.BaseName)#fs-content=movie$($f.Extension)"
                if (-not (Test-Path -LiteralPath $fs)) { Copy-Item -LiteralPath $f.FullName -Destination $fs }
                $list.Add(@{ path = $fs; label = "real: $($f.BaseName) (FastStream)"; conds = @('fs-off', 'fs-anime', 'fs-movie') })
            }
        }
    }
    else {
        Add-Result 'shader-gaps' 'corpus: real HDR/Dolby Vision files' 'SKIP' "none in $RealDir (tests/README.md says where to get them)"
    }
    Add-Result 'shader-gaps' "corpus: $($list.Count) entries ready" 'INFO' ("{0:n0} s to build" -f $sw.Elapsed.TotalSeconds)
    return , $list
}
