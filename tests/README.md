# Regression tests

`pwsh tests/run-tests.ps1` checks every feature this setup ships against a real
mpv, so an edit, an mpv update or a uosc update cannot silently break one. It
needs PowerShell 7 and the real `mpv.exe` (`updater.bat` installs the pinned build; or pass `-MpvExe`).

| Command | What runs | Time |
|---|---|---|
| `pwsh tests/run-tests.ps1 -Tier static` | config wiring only, no mpv | ~1 s |
| `pwsh tests/run-tests.ps1` | static + **headless** (mpv `--vo=null --ao=null`, notify-render `--vo=sixel`: no window, no GPU, no sound) | ~50 s |
| `pwsh tests/run-tests.ps1 -Tier gpu` | + the real renderer, **fullscreen**, on this PC's GPU | ~5 min |
| `pwsh tests/run-tests.ps1 -Tier gaps` | static + the **shader gap hunt** (below): every kind of video after a full warm-up, fullscreen | ~7 min |
| `... -Filter upscale` | only tests whose name matches | |
| `... -ConfigDir <copy>` | test another `portable_config` (a worktree, an experiment) | |

Exit code 0 = everything passed. Failures print their mpv log path
(`%TEMP%\mpv-regression\logs`). CI (`.github/workflows/regression-tests.yml`)
runs static + headless on every push; the gpu tier is local only.

## Rules the suite follows (keep them when adding tests)

- **Never touches the live setup.** Tests run a *copy* of `mpv.exe` next to a
  *copy* of `portable_config` in `%TEMP%\mpv-regression\root`, so mpv's portable
  mode resolves `~~/`, `~~state/` and `~~cache/` there: `speed.json`,
  `stream-resume.json` and the shader cache are never written. The gpu tier
  uses a copy of the real shader cache.
- **No OS input.** Keys and clicks go through mpv's own commands (`keypress`,
  `keydown`/`keyup`, `mouse`, `script-message`), which enter mpv's input layer
  where a real key or click would. Never `keybd_event`/`SendInput`.
- **The gpu tier refuses to run while any mpv is open** - you may be watching.
- **Test media is generated** with the tested mpv's own encoder (libx264/x265)
  into `%TEMP%\mpv-regression\media-v1`, once. A `#fs-content=...&fs-id=...` in a
  file name stands in for the fragment the FastStream native host appends to
  stream URLs: every script reads it from `path`, the same string either way.
  Each clip has its own folder so `autoload.lua` does not queue neighbours.

## What is covered

Static (`run-tests.ps1`): input.conf syntax; every `script-binding` /
`script-message-to` target in input.conf, uosc.conf and our scripts is
registered with the matching mechanism (AGENTS.md validation item 2); every
shader the presets name exists, is installed by `install-shaders.ps1`, and
nothing unused is left; the GLSL `//!` rule; `vo=gpu-next`, `window-dragging=no`;
profile sections hold only their own options (the 2026-09-21 scoping bug); no `#` inside an mpv.conf value (it starts a comment and silently empties the value);
silent seek keys; mpv's own quit keys untouched; every message is a notify.lua banner (no `mp.osd_message`/`show-text` in our scripts, no `osd-msg` bindings), mpv.conf styles mpv's own OSD text to match (osd-box, top right) and uosc does not move it (`adjust_osd_margins=no`); uosc proximity + toolbar
buttons + the local uosc changes (`menu_command` on managed buttons, `user-data/uosc/bottom-ui`, `user-data/uosc/ui-scale`); badge width; `button:source` in uosc.conf's controls; mpv's build is pinned, not committed
(`mpv-build.json` is a complete pin, mpv's files and yt-dlp.exe are not in git and `.gitignore` covers each; outside CI,
INFO whether the installed mpv.exe is the pinned one); `installer/install-mpv.ps1` against a stand-in build made with 7-Zip,
no download (it installs every listed file and nothing else, a second run changes nothing, `-Check` exit 3, a failed
download exit 2, a wrong archive installs nothing, a pin naming a file outside the build is refused, a re-run repairs,
and in Windows PowerShell 5.1 too); the commit guard in `.githooks` (in a throwaway repo: taking the binaries out of git
goes through, a forced add of mpv.exe or yt-dlp.exe is refused; a real name or e-mail as author, a forced-in private file,
an added user folder path, private claude.ai link or private word is refused, a placeholder path goes through; post-merge
says to run updater.bat after a pull that pins another mpv and says nothing when the installed one is it) and, outside CI,
that this clone uses them (`core.hooksPath`) and commits under a public identity; privacy (the public copy,
`tests/lib/privacy.ps1`, AGENTS.md "Public copy"): `.gitignore` covers every kind of runtime state, and no file that would
be published is ignored or holds a user folder path, a private claude.ai link, a non-noreply e-mail or a word from
`.git/info/private-words` (reported as file:line only); `.github/scripts/publish.ps1` between two throwaway repos (a clean
copy becomes one commit without the .publishignore paths, nothing new = no commit, each kind of leak is refused without
printing it, a private word in the commit subject is replaced, a public commit that names someone stops it); the shader-cache files (incl. host.ps1) are in place, the warm-up is
not a top-level player script and the manual script runs it hidden; every `.ps1` parses; stylua (when installed).

Headless (`headless/test-*.lua`):

| Test | Feature |
|---|---|
| config-load | the real mpv loads mpv.conf, its profiles and every script with no warning or error at `--msg-level=all=warn` (mpv only logs a rejected option and plays on) |
| music-info | songs: window title "Artist – Title (feat. X)" from tags, from the file name without tags (track number dropped), feat. moved out of artist and title, several artists joined; details/format/up-next lines; the panel follows uosc's bottom-bar visibility (simulated) with cover art and always shows without; a plain video untouched |
| notify | the banners top right: stack, replace by id, hide, time out, progress line; the size knob (`notify_size-size`, default 1.35) is applied (published to `user-data/notify`); mpv's own OSD text styled like them and moved under the stack (`osd-margin-y-offset`); speed keys (preset, s/d), `c`, Shift+A and the sharpness menu each show a banner |
| notify-render | the banners are really PAINTED, on a real OSD surface: `--vo=sixel` (terminal graphics to stdout - no window, no GPU; `--vo=null` has no OSD size, so notify.lua never reaches its drawing code there, which is how the 2026-09-29 crash that killed every banner passed the suite), a 960x540 canvas with a 960x540 clip, so a box pixel is a screenshot pixel. `screenshot-raw window` (video + OSD in software) must show each banner's black box and white title exactly where notify.lua says it drew it (`box`, published after `canvas:update()`); two stacked banners and a speed key's banner on the left; the video again where a hidden banner was; mpv's own OSD text switched to real pixels (`osd-scale-by-window=no`) with the banners' own font (14 x 1.19 x scale x size), box padding and margins; the speed banner's icon is a glyph in the accent colour inside its column (the glyph part only where `fonts/uosc_icons.otf` is the real font - CI checks out without Git LFS, so there it is a pointer and no icon font exists; an INFO line says so). Breaks checked: the crash fix reverted, `canvas:update()` dropped, a transparent box, a black title, the font still divided by `h/720` (the pre-2026-10-02 formula), the icon font misnamed (its name drawn as text), the test run under `--vo=null` - each turns it red |
| bottom-bar | subtitles rise above uosc's bottom bar while it shows (its `user-data/uosc/bottom-ui`, simulated - a headless uosc publishes none) and come back down with its fade: a text track through `sub-margin-y-offset` (exact value, half way at half visibility, nothing while subtitles are hidden), an ASS track through `sub-pos` on top of the user's own position (a step made while lifted moves that position), above the sync tool's open panel too; watch-later never stores `sub-pos`. Breaks checked: the lift never applied |
| mouse | click = play/pause even when the pointer moves while pressed (`window-dragging=no`); double-click = fullscreen |
| video-info | a video announces itself as a small banner when its real size is known (title = the resolution, detail = codec · pixel depth · source), one banner for every file, gone with its file, none for songs (with or without cover art); the 10-bit clip is HEVC, made with mpv's own libx265 |
| source-info | the `source` button opens a real uosc menu on a local file and on FastStream content (the fragment markers stand in via the clip's file name, like the stream-resume tests); copy (`copy:<payload>`) lands on the CLIPBOARD through mpv's `clipboard/text` AND announces the `source-copy` banner, a repeat copy replaces the banner instead of stacking, a URL payload keeps its colons (split at the first colon only), unknown verbs are ignored |
| keys | seek keys, volume keys/wheel (10/2), mute, s/d, the deliberately unbound Z/R/W/BS |
| speed | preset keys and their per-key revert, the menu's command form, the toolbar button's step list |
| remember-speed | two processes: the speed chosen in one is restored in the next |
| auto-start | a file loaded into a paused player (also after EOF) starts playing; a pause during playback stays |
| subtitles | `c`: selects the first track, toggles visibility, loads a matching file when there is no track |
| subtitle-sync | `t`, the sync timeline, on a clip whose sound is a beep at 2/6/10/14/18 s with a .srt line on each beep: all 5 lines read (external track, `sub-lines`) and the second-mpv audio analysis finds the 5 beeps within 60 ms; Left/Right and Shift+Left/Right, the wheel on each row (and zoom on the time row, volume untouched), dragging each row (subtitles, audio, scrub), a click on a line jumps to its start, a click on the time row jumps there, a click outside the panel still plays/pauses; Esc puts both delays back, Enter/t keep them, keys normal again after; a track INSIDE the clip (made with ffmpeg, skipped without it): all lines through ffmpeg, and with ffmpeg missing the lines collected as playback reads them, kept over a seek |
| menus | the upscale and speed menus (JSON built in Lua) and right-click really open in uosc |
| autoload | sibling videos queued, the audio file next to them not (`same_type=yes`) |
| upscale | every mode, key, menu message and file type of `gpu-toggles.lua`, sharpness levels, dscale restore |
| config | mpv.conf options are in effect for local files AND FastStream files; hwdec switches per file |
| stream-resume | two processes: resume by fs-id across a new token (announced by a small banner that goes with its file), never for local files, not on duration mismatch, forgotten when finished |
| shader-cache | ten processes, each set up by the one before: no stamp -> the video starts at once and a (headless, one-clip) warm-up runs in the background in a second mpv, ends after the video started playing, progress reaches 8/8, stamp written, control files gone; stamp matches -> fresh, no warm-up, check < 1 s, and the capture logs a (faked) new cache object after a preset switch with what was on screen and LEARNS it as title-free cases - the state on screen and the one before the switch, as the log line's "(before: ...)" (`shader-cases.json`: chain, size, decoder; no file name); another display driver -> full warm-up, the player quits mid warm-up and the runner finds no host.ps1 or warm-up mpv left, the capture ignores what a warm-up writes; mpv version + shaders changed -> still only a quick check, which stops after its first clip, no failure recorded by the quit; cache files missing + a warm-up that exits 1 at once (as `taskkill /F` leaves it) -> "interrupted", not recorded as failed, counted, stamp untouched; the same + a warm-up that never finishes -> abandoned after the timeout while the video plays on, failure recorded; same fingerprint -> not retried; then the menu's "Rebuild shaders" (`script-message-to shader_cache rebuild`) runs anyway: deletes mpv's compiled shaders (a faked one), clears the failure, full warm-up while the video plays; learned cases (two left by the rebuild phase: a software-decoded yuv444p bt.601/sRGB full-range clip through Anime at 1.5x, and the empty window) are replayed by the next full warm-up after the matrix (8 + 2 steps, the clip made under its exact recipe name), the old capture log is imported (real gaps only, both states of a "(before: ...)" line, a title containing "|" dropped, a stale line skipped) and the menu's status banner counts them; last, mpv opened with NO file (the phase has no `File`, the runner passes `--idle=yes`) and a stale cache warms by itself after `idle_delay` |

GPU (`gpu/`, plus `installer/warm-shader-cache.ps1 -Check`):

| Test | Checks |
|---|---|
| gpu-warm-cache | every chain × scale tier × 8/10-bit × both decode paths is in the (copied) shader cache, checked with real playback timing in the hidden warm-up window - a miss means `installer\warm-shader-cache.ps1` should be run |
| gpu-switching | 4 rounds of 14 switches (menu, Shift+A/Y, toolbar, sharpness): right chain, on screen < 0.5 s, 0 dropped/late frames after each chain's first use, no recompiles, no renderer errors, VRAM flat; per-switch latency is reported |
| gpu-pacing | gpu-next + Vulkan context; FastStream files decode with vulkan, local files with d3d11va-copy; 0 dropped/late/mistimed frames at 1x and 3x for every chain, Anime at 480p, 720p and 1080p (3x, 2x and 1.33x on a 1440p screen: each takes another path through Anime4K) and Movie at 720p/1080p; render ms per frame reported |
| gpu-auto-warm | the startup check for real: an EMPTY cache -> the FastStream anime file starts at once, the real warm-up (full matrix, ~8 s) compiles in the background, the player is paused halfway and the warm-up still finishes, 0 dropped/delayed frames while both ran; the next start is fresh, and Anime/Movie/Off then compile nothing |

Every runtime test runs with the startup shader check off
(`shader_cache-auto=no` - a test root has no warmed cache, so it would warm
before each test); only shader-cache and gpu-auto-warm switch it on, per
phase (`Args` in the phase entry, appended last so it wins).

After every phase the runner also reads its mpv log: **no script may die**. A
Lua error ends the whole script it happens in (logged `[f][<script>] Lua
error: ...`), so its feature is gone for the rest of the session while every
check that already ran stays green - notify.lua's 2026-09-29 crash. A Lua error
in any script, not only the one a test is about, fails that phase (checked: an
`error()` in video-info.lua's handler turns the video-info test red).

Synthetic mouse input: the tool reads where a press was when its handler runs,
a moment after the press. A test that sends `keydown` and the first `mouse`
move in the same instant makes that first step the origin (traced 2026-09-27:
1/5 of every drag went missing); `test-subtitle-sync.lua`'s `drag()` waits
50 ms after the press, as a hand does.

Not covered (needs a real window and pointer, or lives outside this repo): what
uosc draws (layout, the two remaining times, badges on screen), the sync panel's
look (checked by screenshot in a hidden window when it was built), thumbfast
previews, `mpv-single.exe`, the FastStream extension/native host, file
associations, the installers' downloads.

## The shader gap hunt (`-Tier gaps`)

Answers one question: after the background warm-up, does any real video still
have to compile a shader? It warms an **empty** shader cache exactly as the
player does (`installer/warm-shader-cache.ps1`: hidden window, warmup.lua's
matrix + `shipped-cases.lua`), then `tests/gpu/find-shader-gaps.lua` plays a
corpus on that cache in a player with the **whole** config, fullscreen on the
real GPU, and counts per condition what had to be made: GLSL->SPIR-V compiles
and new `shader_<hex>` objects in the cache folder (what the player's own
capture logs). Any of them is a gap - a FAIL with a title-free case
(cases.lua's format) - and all gaps also land in
`%TEMP%\mpv-regression\shader-gaps.json`. A slow pipeline creation with
nothing new in the cache is only an INFO (a cache hit that took > 2 ms).

The corpus (`tests/lib/gap-media.ps1`, built once into
`%TEMP%\mpv-shader-gaps-media`, ~1 min): H.264/HEVC/AV1/VP9 on both GPU
decoders (local file and the FastStream path), MPEG-2 PAL/NTSC, MPEG-4, Hi10,
4:2:2/4:4:4, ProRes, full range; bt.601/bt.709/bt.2020/Display P3, HDR10,
HLG; 144p to 8K, 1440p (1:1 fullscreen), 2.39:1, anamorphic, vertical; AV1
film grain; JPEG/PNG (rgb, rgba, gray)/GIF stills, cover art (4:2:0, 4:4:4),
audio only; ASS subtitles. Each entry plays under its conditions: fullscreen
with Off/Anime/Movie, a window at the video's size (how mpv opens a local file
here), half, quarter and maximized windows, Movie Low/High, Deband off, each
equalizer setting, rotation 90/180, zoom, mpv's OSD text, an RGBA overlay
(thumbnails, picture subtitles), paused; plus mpv's empty window.

**Real files** cover what no encoder here makes: put Jellyfin's test videos
(https://repo.jellyfin.org/test-videos/, CC BY-SA) in
`test-media/shader-corpus/` (gitignored; in a worktree, next to the tested
mpv.exe) - the 1080p Dolby Vision P5/P8.1/P8.4 and the 1080p/4K HEVC and AV1
HDR10 files (~450 MB). Without them the hunt runs on the synthetic corpus and
says so (SKIP).

Closing a gap: add a case to `portable_config/Scripts/shader-cache/shipped-cases.lua`
that reproduces it (its header says how: a clip recipe, or a shipped file for
Dolby Vision; the decoder; the chain; 1:1, a ratio or a source size; the menu
setting), bump `WARMUP_VERSION` in fingerprint.lua, and run the hunt again
until it is clean. Re-run it after anything that can change which shaders run:
a new libplacebo, render options in mpv.conf, a new shader or chain, a new
kind of file you watch.

History (2026-10-02, RX 9070 XT, 2560x1440): 57 gaps of 252 steps with the
matrix alone -> 12 of 312 with the first shipped cases (all Dolby Vision but
one) -> 1 with the DV clips (an 8K film in a window at x0.31: a new downscale
tap count) -> 0 of 324 with the downscale sweep, in two runs from an
empty cache. What it cannot cover: Dolby Vision titles whose RPU uses
reshaping the three shipped clips do not (libplacebo builds that pass from the
RPU's structure), and windows dragged to arbitrary sizes beyond the tap steps
the sweep covers. The player's capture and its learned cases (cases.lua) still
catch those: a miss is learned the first time and replayed in every warm-up.

## Upscaler benchmark (`upscale-bench/`, Linux, optional)

Not part of `run-tests.ps1`: it answers whether one upscale chain draws a
better picture than another - against a clean reference, with real x264
encodes at the 1080p/720p/480p-on-1440p ratios, in mpv's own renderer (the
pinned Windows build under Wine, on the CPU). For a new model, a new libplacebo
or a chain change. Setup, use and its traps: `upscale-bench/README.md`;
the 2026-10-03 results: `doc/history/sessions-2026-10.md`.

## Adding a test

1. Write `tests/headless/test-<name>.lua` (or `tests/gpu/`): load the harness
   with the `dofile(...)` line every test starts with, and put the body in
   `H.run(function() ... end)`. Use `H.expect(name, getter, want)` for values an
   action should change (it waits - scripts react asynchronously and CI is
   slower), `H.eq`/`H.check` after an `H.sleep` for values that must *not*
   change, `H.load(path)` to switch files, `H.key('x')`/`H.click(x, y, jitter)`
   for input. The file name must start with `test-`, so its mpv script name
   never collides with a real script's.
2. Register it in `$HeadlessTests`/`$GpuTests` in `run-tests.ps1` with the file
   it opens (and a second phase for anything that must survive a restart). A
   test of something a script DRAWS needs a real OSD surface: give its phase
   `Args = $RealOsd` and `File = $RealOsdClip` like notify-render (an `av://`
   File is opened as it is, not from the media folder).
3. Break the feature on purpose (`-ConfigDir` with an edited copy) and check
   the test fails. A test that cannot fail proves nothing.
