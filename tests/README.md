# Regression tests

`pwsh tests/run-tests.ps1` checks every feature this setup ships against a real
mpv, so an edit, an mpv update or a uosc update cannot silently break one. It
needs PowerShell 7 and the real `mpv.exe` (`updater.bat` installs the pinned build; or pass `-MpvExe`).

| Command | What runs | Time |
|---|---|---|
| `pwsh tests/run-tests.ps1 -Tier static` | config wiring only, no mpv | ~1 s |
| `pwsh tests/run-tests.ps1` | static + **headless** (mpv `--vo=null --ao=null`, notify-render `--vo=sixel`: no window, no GPU, no sound) | ~50 s |
| `pwsh tests/run-tests.ps1 -Tier gpu` | + the real renderer, **fullscreen**, on this PC's GPU | ~5 min |
| `pwsh tests/run-tests.ps1 -Tier shadercost` | static + **is the shader warm-up worth keeping?** (below): 35 cases with empty shader caches (mpv's and the AMD driver's), again, and after the warm-up, 3 runs each, fullscreen; a report with a verdict | ~45 min |
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
and in Windows PowerShell 5.1 too); the one-click install (`Invoke-OneClickCheck`, offline stand-ins for GitHub's ZIP,
the Git LFS objects, FastStream's updates.json and nodejs.org, run in Windows PowerShell 5.1: `sync-config.ps1` installs,
finds nothing to do, updates with a changed file set aside as `.mine-<time>`, deletes a dropped file unless it was
changed, leaves user state alone, refuses a bad LFS object and a git clone; `setup.ps1` installs into a new folder,
refuses a foreign folder and a clone, and returns instead of exiting as a script block (`irm | iex`);
`install-faststream.ps1` installs the helper on a private Node.js LTS, finds it up to date, never touches a helper it did
not install or one set up for another folder, refuses a Node.js zip that is not nodejs.org's; `uninstall.ps1` removes only
its own helper and refuses a clone or a foreign folder; every installer script and .bat is plain ASCII); the commit guard in `.githooks` (in a throwaway repo: taking the binaries out of git
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
| source-info | the `source` button opens a real uosc menu on a local file and on FastStream content (the fragment markers stand in via the clip's file name, like the stream-resume tests); copy (`copy:<payload>`) lands on the CLIPBOARD through mpv's `clipboard/text` AND announces the `source-copy` banner, a repeat copy replaces the banner instead of stacking, a URL payload keeps its colons (split at the first colon only), unknown verbs are ignored; "Open in mpv" (`open:<url>`) loads the stream again with the request headers and title it came with (per-file options, a comma inside a header included) |
| keys | seek keys, volume keys/wheel (10/2), mute, s/d, the deliberately unbound Z/R/W/BS |
| speed | preset keys and their per-key revert, the menu's command form, the toolbar button's step list |
| remember-speed | two processes: the speed chosen in one is restored in the next |
| auto-start | a file loaded into a paused player (also after EOF) starts playing; a pause during playback stays |
| subtitles | `c`: selects the first track, toggles visibility, loads a matching file when there is no track |
| subtitle-sync | `t`, the sync timeline, on a clip whose sound is a beep at 2/6/10/14/18 s with a .srt line on each beep: all 5 lines read (external track, `sub-lines`) and the second-mpv audio analysis finds the 5 beeps within 60 ms; Left/Right and Shift+Left/Right, the wheel on each row (and zoom on the time row, volume untouched), dragging each row (subtitles, audio, scrub), a click on a line jumps to its start, a click on the time row jumps there, a click outside the panel still plays/pauses; Esc puts both delays back, Enter/t keep them, keys normal again after; a track INSIDE the clip (made with ffmpeg, skipped without it): all lines through ffmpeg, and with ffmpeg missing the lines collected as playback reads them, kept over a seek |
| menus | the upscale and speed menus (JSON built in Lua) and right-click really open in uosc |
| autoload | sibling videos queued, the audio file next to them not (`same_type=yes`) |
| upscale | every mode, key, menu message and file type of `gpu-toggles.lua`, sharpness levels, dscale restore |
| config | mpv.conf options are in effect for local files AND FastStream files; both decode with d3d11va-copy,no (no vulkan since 2026-10-04) |
| stream-resume | two processes: resume by fs-id across a new token (announced by a small banner that goes with its file), never for local files, not on duration mismatch, forgotten when finished |
| shader-cache | ten processes, each set up by the one before: no stamp -> the video starts at once and a (headless, one-clip) warm-up runs in the background in a second mpv, ends after the video started playing, progress reaches 8/8, stamp written, control files gone; stamp matches -> fresh, no warm-up, check < 1 s; another display driver -> full warm-up, the player quits mid warm-up and the runner finds no host.ps1 or warm-up mpv left; mpv version + shaders changed -> still only a quick check, which stops after its first clip, no failure recorded by the quit; cache files missing + a warm-up that exits 1 at once (as `taskkill /F` leaves it) -> "interrupted", not recorded as failed, counted, stamp untouched; the same + a warm-up that never finishes -> abandoned after the timeout while the video plays on, failure recorded; same fingerprint -> not retried; then the menu's "Rebuild shaders" (`script-message-to shader_cache rebuild`) runs anyway: deletes mpv's compiled shaders (a faked one), clears the failure, full warm-up while the video plays; last, mpv opened with NO file (the phase has no `File`, the runner passes `--idle=yes`) and a stale cache warms by itself after `idle_delay` |

GPU (`gpu/`, plus `installer/warm-shader-cache.ps1 -Check`):

| Test | Checks |
|---|---|
| gpu-warm-cache | every chain × scale tier × 8/10-bit through d3d11va-copy is in the (copied) shader cache, checked with real playback timing in the hidden warm-up window - a miss means `installer\warm-shader-cache.ps1` should be run |
| gpu-switching | 4 rounds of 14 switches (menu, Shift+A/Y, toolbar, sharpness): right chain, on screen < 0.5 s, 0 dropped/late frames after each chain's first use, no recompiles, no renderer errors, VRAM flat; per-switch latency is reported |
| gpu-pacing | gpu-next + Vulkan context; FastStream and local files decode with d3d11va-copy; 0 dropped/late/mistimed frames at 1x and 3x for every chain, Anime at 480p, 720p and 1080p (3x, 2x and 1.33x on a 1440p screen: each takes another path through Anime4K) and Movie at 720p/1080p; render ms per frame reported |
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

## Is the shader warm-up worth keeping? (`-Tier shadercost`)

Asked 2026-10-05, and built to be run ONCE and then decided on. Without the
background warm-up (`Scripts/shader-cache`, ~3,500 lines with its tests) mpv
still keeps every shader it compiles; what a viewer would notice is the FIRST
video of each kind after a GPU driver or libplacebo update, when mpv's cache
AND the AMD driver's own cache are cold. This tier measures exactly that, on
the real GPU, fullscreen, with the whole config, in three states, each run in
a fresh mpv (libplacebo also keeps shaders in memory) and every case 3 times
(`-Repeat`; the report uses the medians):

- **cold**: mpv's cache folder empty AND the AMD driver's
  (`%LOCALAPPDATA%\AMD\VkCache`, shared with every game): the owner's folder is
  set aside (one rename - refused, with nothing changed, while a program has a
  file in it open) for the whole run, the empty stand-in is emptied again
  before every cold run, and the owner's folder is put back at the end - also
  after a failure or Ctrl+C, and if a run was killed, at the start of the next
  one (or rename `VkCache.mpv-shadercost-backup` back to `VkCache` by hand);
- **again**: the same video once more on what the cold run left in both
  caches - every later video without a warm-up (proves mpv's own cache);
- **warm**: after the player's full warm-up (`installer/warm-shader-cache.ps1`)
  into an empty folder with the driver's cache emptied too - what the warm-up
  gives after an update.

**Cases** (35, `$CostCases` in run-tests.ps1; clips made once with the tested
mpv's own encoder into `%TEMP%\mpv-regression\media-cost-v1`, ~700 MB): every
path the upscalers take on the 1440p screen - Anime at 360p/480p/576p/720p/1080p
(each Anime4K stage the scale switches on) and 2160p (scaled down), Movie at
480p/576p/720p (FSRCNNX + SSimSuperRes) and 810p/1080p (SSimSuperRes; each its
own Auto sharpness) and 2160p (no sharpener), Off at 720p/1080p/2160p; 10-bit
HEVC with Anime and Movie, 10-bit H.264 and an MPEG-2 DVD (bt.601, anamorphic)
decoded on the CPU; HDR10 1080p with Off/Anime/Movie and 2160p with Off/Movie,
HLG with Off/Movie, Dolby Vision profile 5 with Off/Movie, 8.1 and 8.4 (the
clips the warm-up ships); a song with cover art; and five cases of what a
viewer does mid-video, each action the first of its kind in the process: every
upscale switch, every Movie sharpness level (Low/Medium/High/Off/Auto),
leaving fullscreen (a window at the video's size), a half-size and a maximized
window, back to fullscreen, a picture overlay (timeline thumbnails, picture
subtitles), Video menu contrast and deband off - on SDR and HDR10.

**Measured** per run (`tests/gpu/measure-shader-cost.lua`): the first frame
(loadfile -> playback-restart, which mpv reports only once that frame is on
screen); late frames and the longest pause between two frames in the first
3 s and in the 2 s after each action; the shaders mpv compiled; how much the
driver's cache grew. No log file (it would raise libplacebo's log level and
slow the cold runs down).

**Checked**, so a run that measured the wrong thing never counts: the upscale
preset on screen, the chain (Anime4K for Anime; Movie with FSRCNNX exactly
from 2x and the sharpener exactly when enlarged, by the real display scale; no
chain for Off), no renderer or script error, and for every cold run that the
driver's cache was emptied AND grew (the driver compiled - if it did not, it
was not cold). A case without a valid run in each state makes the verdict
INCOMPLETE.

**The report** (`%TEMP%\mpv-regression\shader-cost.md`, Markdown to paste into
an issue; every run's numbers in `shader-cost.json`) shows cold / again / warm
per case and action, the cold start extra of each run (the spread), the
warm-up's own duration, and applies the **decision rule, set 2026-10-05 before
any number was seen**, to cold AND to again (start = first frame + the longest
pause in the first seconds; extra = that state minus warm):

- **DELETE**: every start extra under 500 ms and no action with a hitch;
- **KEEP**: any hitch (more than 2 extra late frames, or an extra
  pause of 250 ms or more, after an action) or a start extra of 1 s or more;
- **UNCLEAR**: otherwise (a start extra of 0.5-1 s) - judge by eye, a week with
  `shader_cache-auto=no`;
- **INCOMPLETE**: a case without a valid run in each state - fix, re-run it
  (`-Filter`).

The run of 2026-10-05 (RX 9070 XT, mpv issue #39): cold came out KEEP by the
rule (the worst start +1,061 ms, upscaler switches pausing up to +841 ms longer),
again DELETE (the worst start +12 ms, no hitch); one of the 35 cases had no valid
run, so the report said INCOMPLETE. The owner kept the warm-up and removed, the
same day, what only looked for its gaps: the player's capture log, its learned
cases and the shader gap hunt. Re-run it after a big driver or libplacebo change.

Before running: close every mpv (the tier refuses otherwise) and every game or
other program that uses the GPU (their files would keep the driver's cache
from being set aside or emptied). `-Repeat 1 -Filter 'Anime*'` gives a quick
look; the decision needs the full run.

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
