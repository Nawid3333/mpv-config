# Regression tests

`pwsh tests/run-tests.ps1` checks every feature this setup ships against a real
mpv, so an edit, an mpv update or a uosc update cannot silently break one. It
needs PowerShell 7 and the real `mpv.exe` (`updater.bat` installs the pinned build; or pass `-MpvExe`).

| Command | What runs | Time |
|---|---|---|
| `pwsh tests/run-tests.ps1 -Tier static` | config wiring only, no mpv | ~1 s |
| `pwsh tests/run-tests.ps1` | static + **headless** (mpv `--vo=null --ao=null`, notify-render `--vo=sixel`: no window, no GPU, no sound) | ~50 s |
| `pwsh tests/run-tests.ps1 -Tier gpu` | + the real renderer, **fullscreen**, on this PC's GPU | ~5 min |
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
- **The gpu tier refuses to run while any mpv is open** - you may be watching -
  and while Windows reports a problem with a display adapter. The first lost GPU
  device (`VK_ERROR_DEVICE_LOST` in a log) ends the tier: each further run would
  reset the GPU again, and on 2026-10-12 a series of resets crashed Windows.
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
buttons + the local uosc changes (`menu_command` on managed buttons, `user-data/uosc/bottom-ui`, `user-data/uosc/ui-scale`); badge width; `button:source` in uosc.conf's controls, and the
episode buttons with their gap behind `<user-data/faststream-episodes/shown>`; mpv's build is pinned, not committed
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
its own helper and refuses a clone or a foreign folder; every installer script and .bat is plain ASCII); the commit and push
guards in `.githooks` (in a throwaway repo: taking the binaries out of git
goes through, a forced add of mpv.exe or yt-dlp.exe is refused; a real name or e-mail as author, a forced-in private file,
an added user folder path, private claude.ai link or private word is refused, a placeholder path goes through; post-merge
says to run updater.bat after a pull that pins another mpv and says nothing when the installed one is it; against a bare
remote, a push of commits made with `--no-verify` is refused, nothing reaching the remote and no text printed, for a private
word, user folder path or e-mail address in a message, a private word in an added line, one a later commit removes again, a
real name as author and a forced-in ignored file, and so are a branch name and an annotated tag's message with a private
word; a clean commit naming a noreply co-author goes out, mpv's manual with its example user folder is committed and pushed,
and a new branch is checked for its own commits only) and, outside CI, that this clone uses them (`core.hooksPath`) and
commits under a public identity; privacy (the repository is public, `tests/lib/privacy.ps1`, AGENTS.md "Public
repository"): `.gitignore` covers every kind of runtime state, and no tracked file is ignored or holds a user folder path, a
private claude.ai link, a non-noreply e-mail or a word from `.git/info/private-words` (reported as file:line only, a word in
a path as `***`); CI's commit check, in a throwaway repo, names each leaking commit (identity, path, e-mail, word in its
message) by short sha and passes a noreply co-author, Dependabot's sign-off and GitHub as committer (CI's privacy job runs
both with the `PRIVATE_WORDS` secret on every push, docs included); the shader-cache files (incl. host.ps1) are in place, the warm-up is
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
| faststream-episodes | the previous / next episode buttons and the autoplay switch (`faststream-episodes.lua`), the test standing in for the FastStream helper: hidden on a local file, while FastStream does not follow the window (`user-data/faststream/connected` never set, false, or deleted - mpv tells no observer about a deleted key, so the script looks again each second), for `fs-content=` only in a query and with nothing loaded; shown for a FastStream stream it follows (also after a delete and a new `true`, and for the text `yes`); icons and tooltips; the switch follows `user-data/faststream/autoplay`; each button's command and `Ctrl+a` send `faststream-previous` / `-next` / `-autoplay`; `Ctrl+a` is input.conf's alone (no mpv default, no script binds it). A second process runs the script with no uosc (`--load-scripts=no`): the flag stays false, so uosc never shows buttons it has not got. Breaks checked: local files counted, `connected` ignored, the switch stuck off, a button sending the wrong message, no second look after a delete, idle not followed, `Ctrl+a` unbound or also bound by a script, the flag set before uosc has the buttons |
| faststream-quality | the `fs-quality=` fragment item (FastStream's page qualities) under made-up stream names an `on_load` hook maps to a clip: the list and the playing entry published, the button shown with the playing quality as badge, `open-menu` opens a real uosc menu (type `faststream-quality`), activating the playing entry loads nothing, another one is loaded with the same fragment, the position and the request headers (`user-data/faststream-quality/last-load`); a tag with a `file:` entry and one without a url keeps one entry: no list, the button hidden. Run with `faststream_quality-test_local=yes` (its entries are local stems; outside the tests only http(s) ones count). Phase `variants`: the stream's own qualities from the media's `variants/` (one video in 180p, and 360p at 60 fps): an HLS master and an EDL with a `program_id` per stream (as ytdl_hook writes YouTube's formats) are editions - 360p60 plays (badge 360p), a switch shows 180p from the same position, uosc's Editions button hides, and the next file starts at its own default edition; a clip with one size offers nothing; the 360p clip added as a second video track makes them tracks (`vid`) |
| speed | preset keys and their per-key revert, the menu's command form, the toolbar button's step list |
| remember-speed | three processes: the speed chosen in one is restored in the next; a speed picked while a file loads wins over that restore (the first video) and over the video/song switch |
| auto-start | a file loaded into a paused player (also after EOF) starts playing; a pause during playback stays |
| pause-flash | each step into pause (the property, Space, a click on the video, the stop at a file's end) sends uosc's `flash-ui` and it reaches uosc; resuming and a paused player loading the next file send none |
| ui-hover | uosc's UI shows on a mouse move and hides with the cursor, and the pointer coming back over the window at the pixel where it was (`MOUSE_LEAVE` then `MOUSE_ENTER` with no move: what Windows sends when another window covers the pointer for a moment) shows nothing - hidden or just shown; a real move after it, and a return at another place, still show it. The pointer resting ON the bar (the timeline, the volume slider) keeps the UI past cursor-autohide and hides it after uosc.conf's `autohide_over_controls` (3 s) - uosc itself kept it for good - but never while the left button is held there (a drag). `--vo=sixel` like notify-render (uosc publishes `user-data/uosc/bottom-ui` only with an OSD surface), and a lavfi sound track (no audio, no volume slider). Breaks checked: `lib/cursor.lua` before each change (3 checks red each time), the held-button guard dropped (2 red) |
| subtitles | `c`: selects the first track, toggles visibility, loads a matching file when there is no track |
| subtitle-folder | mpv.conf's `sub-file-paths`: a subtitle in a `sub\` folder next to the video loads with it (`;` between folders on Windows) |
| subtitle-sync | `t`, the sync timeline, on a clip whose sound is a beep at 2/6/10/14/18 s with a .srt line on each beep: all 5 lines read (external track, `sub-lines`) and the second-mpv audio analysis finds the 5 beeps within 60 ms; Left/Right and Shift+Left/Right, the wheel on each row (and zoom on the time row, volume untouched), dragging each row (subtitles, audio, scrub), a click on a line jumps to its start, a click on the time row jumps there, a click outside the panel still plays/pauses; Esc puts both delays back, Enter/t keep them, keys normal again after; a track INSIDE the clip (made with ffmpeg, skipped without it): all lines through ffmpeg, and with ffmpeg missing the lines collected as playback reads them, kept over a seek |
| menus | the upscale and speed menus (JSON built in Lua) and right-click really open in uosc |
| autoload | sibling videos queued, the audio file next to them not (`same_type=yes`) |
| upscale | every mode, key, menu message and file type of `gpu-toggles.lua`, sharpness levels, dscale restore; quality Auto (High, Fast, off where neither fits - Anime then stays off, never falls through to Movie) |
| config | mpv.conf options are in effect for local files AND FastStream files; both decode with d3d11va-copy,no (no vulkan since 2026-10-04) |
| sharpness-memory | two processes: the Movie sharpness picked in the menu is restored in the next (`~~state/movie-sharpness.json`) |
| settings | three processes: a new install starts on mpv's defaults with the buffer recommended for this PC's memory, a menu choice applies at once and is saved; a fresh process restores it; a PC that ran this config before the settings existed keeps the old values (de,en, 350 nits, 1 GB, 3 s) |
| screens | two processes: each screen (`screen-seen W H Hz` stands in for what Windows reports) keeps its own HDR brightness, a new one is announced by a banner and starts at Auto, a size reported before its refresh rate is the known screen of that size, 0x0 is ignored; the next process knows the screens |
| welcome | three processes: the first start shows the welcome banner once and remembers it, the next start shows none, an idle first start (no file) also opens the Welcome menu |
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

A baseline is read only once the player has settled: `path` changes before the
other scripts' `file-loaded` handlers run (auto-start.lua clears an inherited
pause there), so a test that read `pause` right after a hand-off saw the old
file's pause - `H.expect` the value it builds on first. mpv reports a local path
with `\` on Windows: compare paths normalized (`test-single-instance.lua`'s `norm`).

Not covered (needs a real window and pointer, or lives outside this repo): what
uosc draws (layout, the two remaining times, badges on screen), the sync panel's
look (checked by screenshot in a hidden window when it was built), thumbfast
previews, the FastStream extension/native host, file associations, the
installers' downloads.

`mpv-single.exe` (what Explorer starts for mpv's file types) is checked in the headless tier,
built from `mpv-single.cs` with .NET Framework's `csc.exe` into its own folder, with
`single-instance.lua`, mpv with `vo=null`/`ao=null`: three files opened at once go into one mpv
(in mpv's GUI mode) and its playlist; a file opened later replaces them in that mpv, not in one
that plays a stream; the banner's way out plays it on in a second mpv from where it got to and
puts the old files back; Ctrl opens a new mpv (`MPV_SINGLE_CTRL`: no key press is sent); with
only a stream playing a local file gets its own mpv; an mpv without the script (on the old pipe
name) still gets the file. Its players' pipes have their own prefix (`MPV_SINGLE_PIPE_PREFIX`),
so a file opened from Explorer meanwhile never lands in one. Not covered: which of several
windows is in front (no window under `vo=null`). It is skipped while any mpv runs (the owner
may be watching) and where `mpv.com` is missing. `test-single-instance.lua` covers the banner
itself on a real OSD surface (its box, a click and a double click on it, the old playlist back
at its second, a burst's file not queued twice); the static tier runs
`mpv-single-register.ps1`/`-unregister.ps1` on stand-in registry keys.

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
