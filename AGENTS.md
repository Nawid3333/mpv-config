# Agent handoff for this mpv setup

A portable Windows mpv for anime and films, tuned for an AMD RX 9070 XT. Its
owner uses it for three things, and everything else serves them:

1. **Speed keys**: presets 2x-16x that toggle back, fine steps, the speed remembered.
2. **The FastStream connection**: the owner's Firefox extension sends web streams to
   mpv through a native helper (resume, episodes, autoplay, buffering, source links).
3. **Upscaling**: GLSL shader chains (Anime4K for anime, FSRCNNX/SSimSuperRes for films).

This file says how the setup fits together, what must not be undone, and how to work
on it. The decisions' history and measurements are in `doc/history/`;
`doc/history/agents-notes-until-2026-10-12.md` is this file's previous, long
version. **When this file and the code disagree, the code wins - then fix this file.**
Keep it short: a new fact goes here in one line, its story into doc/history.

## Rules

- **The live install is read-only.** The owner runs mpv from `C:\Program Files\mpv`,
  this repository's main working tree. Work in a git worktree outside it
  (`GIT_LFS_SKIP_SMUDGE=1 git worktree add ...`), branch + pull request for every
  change, merge after green CI, then delete the branch: only `main` stays.
- **He may be watching.** Before starting any mpv, check
  `Get-CimInstance Win32_Process -Filter "Name='mpv.exe'"`; while one runs, only
  static checks (stylua, lua-language-server, PSScriptAnalyzer, the static tier).
  An mpv whose command line names `127.0.0.1:<port>` belongs to FastStream's e2e
  suite, not to him; never put such a URL or `\\.\pipe\faststream-mpv` on a test's
  command line.
- **A GPU device loss is reproduced at most once.** `VK_ERROR_DEVICE_LOST` (or a
  black/garbage window) is a reset in the AMD driver; repeating it crashed Windows
  on 2026-10-12 (bugcheck 0x13A), and on 2026-10-04 left the driver failed until a
  restart. After the first one: `Get-PnpDevice -Class Display`, then work from
  logs and files. Ask before any further GPU run.
- **No OS input injection** (`keybd_event`, `SendInput`, ...): tests drive mpv
  through its own `keypress`/`keydown`/`mouse`/`script-message` commands. A real
  Ctrl+Shift once switched the owner's keyboard layout.
- **No system-wide Windows changes** for an mpv wish (a global title-bar size was
  reverted for affecting every app).
- **Public repository.** This repository (`Nawid3333/mpv-config`) is public, and so
  is all of it: every tracked file, commit message, branch name, pull request, issue,
  comment and Actions log (the private `Nawid3333/mpv` it was published from until
  2026-10-21 is archived). Nothing personal may be in any of them: no `C:\Users\<name>`
  or private drive paths (write `%LOCALAPPDATA%` or `~~state`), no real names or
  e-mail addresses, no titles of what he watches (test fixtures use made-up names), no
  private claude.ai links. `.githooks` (switched on per clone: `git config
  core.hooksPath .githooks`) refuses such lines, a non-noreply identity and the words
  in `.git/info/private-words` at each commit, and at each push every commit going
  out, messages, branch and tag names included; CI's privacy job checks every tracked
  file, the new commits and a pull request's branch name on every pull request and push
  to main, with the same list as the `PRIVATE_WORDS` secret (update both). A branch
  pushed without a pull request reaches no CI: there the push guard is all. All of these
  read text only: a binary (LFS included) is not searched - an image or an exe is
  checked by eye. GitHub's own checks run as well: CodeQL (default setup), secret
  scanning with push protection, Dependabot security updates; and the repository runs an
  action only when it is pinned to a full commit SHA (Dependabot moves the pins). Nothing checks a
  pull request's or issue's title, text and comments: write them the same way. Every
  file that records viewing (watch_later/, watch_history.jsonl, stream-resume.json,
  screenshots, yt-dlp cookies, root `*.txt` notes) is gitignored: a new kind of state
  file goes into `.gitignore` AND the static tier's sample list.
- **Helpers.** Side work (reviews, drafts, second opinions) goes to Ollama's
  `glm-5.3-flash:cloud` only (the owner's global instructions); no Claude
  subagents unless he asks. Check every answer against the code: a glm finding,
  and a glm "no findings" too, is a lead, never a fact.
- **Data, not guesses** (the owner, 2026-10-22). A cause, a fix or "it works" goes
  into a pull request, a commit or a report only once it was measured or run; until
  then it says "not established". Reproduce a bug before testing its fix, and show
  the test red without the fix. Pull requests are merged here only when every check
  is green on the commit being merged (update the branch first if main moved).
- **Comments say why**, not when or who: history belongs in doc/history and git.

## How it fits together

**Docs.** `RECREATE.md` is the fresh-PC runbook (a new clone sets its noreply git
identity and `core.hooksPath` there, step 2); it points here for current
behaviour, so defaults and policy are updated here only. `doc/manual.txt` is a
local copy of mpv's manual: grep it before guessing what an option does. Its first line
names the build it came from; when a merged build changes `doc/manual.pdf` (its SHA-256 in
mpv-build.json), make it again (RECREATE.md section 5).

**Layout.** `portable_config/` next to `mpv.exe` (portable mode: `~~/`, `~~state/`,
`~~cache/` all resolve there). `mpv.conf`, `input.conf` (keys, and the right-click
menu from trailing menu comments - uosc reads them), `Scripts/*.lua`,
`script-modules/` (code the scripts load with `dofile`, not scripts themselves: mpv
runs every file and folder in `Scripts/`; `state-file.lua` writes every state file
whole or not at all and keeps a damaged one aside), `script-opts/*.conf`, `shaders/` (only the files the presets use, committed as
their sources published them, except the locally modified `adaptive-sharpen.glsl`).
A new shader goes into `shaders/`, `gpu-toggles.lua` (a preset naming a missing file
drops it with only a warning) and THIRD-PARTY-NOTICES.md's shader table (its source and
SHA-256, which the static tier checks against the file). Never write `//!` inside a
shader, comments included: libplacebo ends the block there.

**The mpv build is pinned, not committed.** `mpv-build.json` names one of
shinchiro's builds (url, sha256, every file's SHA-256); `installer/install-mpv.ps1`
makes a folder match it; `updater.bat` (= `installer/update.ps1`) does `git pull`
(or `sync-config.ps1` for a one-click install), install-mpv, `yt-dlp -U`, and
refreshes a FastStream helper the one-click install set up.
`.github/workflows/mpv-auto-update.yml` offers each new build that passes the suite
as ONE rolling pull request (`mpv-update`); CI has no GPU, so the owner merges it.
shinchiro builds mpv's newest commit daily: a build of a commit mpv's own CI failed is
never offered (one that it still tests waits a day).
mpv's own files and `yt-dlp.exe` are gitignored; the pre-commit hook refuses them.
**Releases**: every push to main whose CI passes (the suite, and both linters when they run)
is released by `auto-release.yml`: tag `vYYYY.MM.DD.N` on the tested commit, GitHub's list of
the pull requests since the last release, the mpv build named. Nothing downloads them (the
one-click install takes main's ZIP).

**One-click install** for other PCs (`install.bat` / `installer/setup.ps1`): into
`%LOCALAPPDATA%\Programs\mpv`, no admin, no git: the config comes as GitHub's ZIP
(`sync-config.ps1`, a manifest of what it wrote, user changes set aside as
`.mine-<time>`), FastStream's helper on a private Node.js, `uninstall.bat`. The helper's
two files run only when they match the release's `native-host.sha256`, node.exe only when
signed by the OpenJS Foundation (`install-faststream.ps1`).
Installer scripts are plain ASCII and run native programs through `Invoke-Native`
(Windows PowerShell 5.1 turns a redirected stderr line into a terminating error).

**Opening files** (`mpv-single.exe`, built from `mpv-single.cs` - rebuild and commit both,
the command is in its header; it is LFS and carries its source, which the static tier
compares): `mpv-single-register.bat` points mpv's own file
types (`io.mpv.*`, `mpv.File`, `Applications\mpv.exe`, this folder's mpv only) at it with a
per-user command over them, the old one kept in `mpv-single-was` for the unregister;
`mpv-register.bat`/`mpv-install.bat` write mpv.exe back, so run it again after them (the
one-click setup runs it). A local file goes to the front-most mpv window (not a minimized one) that plays a local
file or nothing - each mpv the launcher starts has its own pipe `mpv-single-<id>` - never to
a stream's window; `single-instance.lua` takes it and offers the banner. Ctrl held, or
`--new-window`: a new mpv; files opened together: one playlist.

**Scripts** (each publishes its state as `user-data/<name>` for the tests):

| Script | Job |
|---|---|
| `speed-presets.lua` | preset keys: same key again = back to the speed before it (per key) |
| `speed-button.lua` | toolbar speed button (badge, click = next step, right-click = menu), the speed banner |
| `remember-speed.lua` | `~~state/speed.json`; videos only; a song/video switch sets that kind's speed; a speed picked while a file loads wins |
| `pause-flash.lua` | each step into pause flashes uosc's whole UI (`flash-ui`, uosc.conf's `flash_duration`, shared with the volume/speed flashes) |
| `auto-start.lua` | an inherited pause is cleared at file-loaded, except for a quality switch made while paused (`user-data/auto-start/keep-pause`); sub/audio delay back to 0 at unload |
| `gpu-toggles.lua` | the upscale state (Off/Auto/Anime/Movie), quality High/Fast/Auto (measured per GPU, `~~state/upscale.json`), screen override, Movie sharpness, the upscale button and menus |
| `shader-cache/` | background shader warm-up in a hidden second mpv when the cache is stale (`fingerprint.lua`), "Rebuild shaders" |
| `settings.lua` | per-PC settings and their menus (`~~state/settings.json`): buffering, start/stall wait, languages, HDR brightness per screen; the Welcome menu |
| `welcome.lua` | first-start banner, F1 tour |
| `stream-buffer.lua` | per-file buffering of streams the FastStream way (RAM budget, then disk) |
| `stream-resume.lua` | resume FastStream streams by `fs-id` (`~~state/stream-resume.json`, 7 days) |
| `faststream-episodes.lua` | previous/next episode and autoplay buttons while the helper follows the window |
| `faststream-quality.lua` | the one Quality button and menu (uosc's own `stream-quality` is not in the bar): the page's files (`fs-quality=` fragment item, FastStream host 12+; loadfile from the same second, http(s) only), else the stream's own variants - mpv makes an HLS master's and YouTube's (ytdl_hook `all_formats`) editions, switched in place as a file-local `edition` (uosc's Editions button hides meanwhile), DASH's tracks (file-local `vid`); one row per height |
| `source-info.lua` | the source button: stream URL, original URL, site page; copy/open |
| `notify.lua` | the only drawer of messages: banners top right (speed: top left) |
| `bottom-bar.lua` | the control bar's scrim; lifts subtitles above it |
| `video-info.lua`, `music-info.lua` | resolution banner; song title and details panel |
| `subtitle-sync.lua` | `t`: the sync timeline (audio loudness + subtitle lines, drag to shift) |
| `subtitle-toggle.lua`, `title-bar.lua` | `c` smart subtitles; black Windows title bar (DWM) |
| `single-instance.lua` | takes mpv-single.exe's hand-off (`open replace\|append`); after a replace mid-file the banner "Play this in a new window" (8 s; click: the old playlist back at its second, the new file on in a new window) |
| `uosc/`, `thumbfast.lua`, `autoload.lua` | vendored (uosc 5.13.0, current) |

**uosc local changes**, marked `Local change` in its code, re-applied after every uosc
update - uosc is updated in this repository, never by its own updater, which would
replace the folder and drop them (a static check guards each): managed buttons take a `menu_command`
(right-click); `user-data/uosc/bottom-ui` and `user-data/uosc/ui-scale` are
published; the timeline shows a second (real-time) remaining time only when it
differs and hatches the buffer for streams only; a timeline click seeks by
keyframe; `flash-elements` takes a duration (ms) of its own, for the seek keys' timeline;
`lib/intl.lua` reads the UI language from settings.json; `lib/cursor.lua` takes the
pointer back over the window at the same pixel (another window covered it) for no move,
and hides the UI with the pointer resting on it too (`autohide_over_controls`, 3 s; not
while the left button is held or a menu is open); `bin/` keeps only `ziggy-windows.exe` (the
macOS and Linux builds were 11.8 MB of LFS that every install fetched).

**FastStream contract** (the extension and helper live in `Nawid3333/FastStream`):
the helper starts mpv with `--force-window=immediate` and appends URL-fragment
items to the stream URL - `fs-content=anime|movie`, `fs-id=<16 hex>` (resume key),
`fs-private=1` (a private window's stream: stream-resume keeps nothing, since
2026-10-14), `fs-page=<encoded page URL>`. Scripts read the LAST whole item of the fragment
(after the first `#`, split on `&`), never a match anywhere in the URL. The helper
sets `user-data/faststream/connected`, `.../autoplay` and `.../heartbeat` (every
30 s; stale after 90 s), and hears `script-message faststream-next|previous|autoplay|pause` (pause: Space and a click on
the video; FastStream's extension stops an end's autoplay countdown with it, autoplay stays on).
mpv tells no observer when a user-data key is deleted. FastStream never sends
YouTube; YouTube links pasted into mpv go through `ytdl_hook` and `yt-dlp.exe`, which
solves YouTube's challenges with Node.js (mpv.conf `ytdl-raw-options`; Deno is not needed).

**Upscaling.** Auto applies a chain to FastStream content only (`fs-content=`);
local files stay off unless Anime or Movie is picked. Anime = Anime4K C+A (Fast:
Anime4K's low-end template). Movie by the real display scale: SSimSuperRes below
2x, FSRCNNX + SSimSuperRes from 2x; both with CfL chroma and adaptive-sharpen on
the OUTPUT hook (Auto strength = scale - 1, 0.5-1.5). Quality Auto times the high
chain once per screen and source size (`vo-passes`) and drops to Fast, then off,
over half a frame. `user-data/gpu-toggles/applied` counts actions (keys, messages, and
each file's `file-loaded` re-evaluation, which the warm-up counts in) - the warm-up waits
on it, so no other automatic re-apply may go through `entry()`. A change to the
warm-up's matrix or shipped cases needs a `WARMUP_VERSION` bump in fingerprint.lua
(that is what triggers a full warm-up). Accepted: a chain's first use in a process
can make 0-4 frames late (its files parsed on the render thread); preloading chains
at startup was rejected as a visible race.

## Decisions - do not undo without the owner

- **Anime4K stays** the Anime preset (chosen by eye over ArtCNN and CuNNy). No
  faithful 2x CNN for anime, no vf/ONNX upscaler (no temporal consistency, cannot
  follow the speed keys), no frame interpolation.
- **No Vulkan video decoding**: `hwdec=d3d11va-copy,no` everywhere (it lost the
  GPU device on FastStream streams). Rendering stays Vulkan (`gpu-context=winvk,d3d11`;
  D3D11 compiles the big shaders 10-20 s each).
- **Window**: native title bar (`border=yes`, Windows does Snap); a click on the
  video only toggles pause (`window-dragging=no`).
- **Seeks are instant keyframe seeks**, without OSD text; numbers jump by percent. Each
  seek key shows the timeline for 2.5 s (the owner, 2026-10-21: a skip has to show where
  it landed; from 2026-09-25 they flashed nothing, to match FastStream).
- **`video-sync=audio`**: FreeSync smooths judder, and reaches mpv only in
  fullscreen with an Adrenalin per-app profile set to FreeSync On.
- **target-peak** (HDR brightness) applies to HDR sources only; set globally it dims SDR.
  **target-contrast** stays default: a true-black UI would cost the film's shadows.
- **Two user-facing presets**, Anime and Movie: the cycle stays Off/Auto/Anime/Movie.
- **cache-pause-initial** is on only until a file first plays (settings.lua re-arms
  it in on_load): mpv applies it after every seek, which stalled each seek on a stream.
- **Start and stalls is Adaptive** by default (the owner, 2026-10-14: no fixed wait,
  start as soon as the stream can play through): the start waits at most the old 3 s,
  a stall by the line's speed (at most 10 s). Measured on a throttled line: starting
  at once stalled right after the start on HLS, and a long first wait meant seconds of
  black on a slow line. The fixed choices stay in the menu.
- **The shader warm-up stays**, slimmed (measured 2026-10-05).
- **Builds are offered, never auto-installed**: the owner merges the mpv-update PR.
- **Opened files: local with local** (the owner, 2026-10-20): a file from Explorer replaces
  what plays in the mpv window used last that plays a local file or nothing; a stream's
  window (FastStream, any URL) is never taken over. The second window is the banner's click
  or Ctrl - no ask-every-time dialog.
- **mpv's own keys are off** (`input-default-bindings=no`, the owner, 2026-10-22: only his
  keys, so he knows what each does): input.conf binds every key that works, the basics too
  (`CLOSE_WIN` = the window's X and Alt+F4, Ctrl+w / Ctrl+c, Ctrl+q quits and saves, f/Esc,
  PgUp/PgDn, Ctrl+s, Ctrl+v, media keys); the rest of mpv's is in the right-click menu.
  `Q` stays unbound: Caps Lock + q (his 3x key) arrives as Q. **Bind no key he did not ask
  for** (mpv reads Shift+r and Caps Lock + r both as R: a capital is a Shift key too).

## Testing

`pwsh tests/run-tests.ps1` (static + headless, about a minute here and five on CI,
no window, never touches the live config - it runs copies in
`%TEMP%\mpv-regression`); `-Tier static` (no mpv); `-Tier gpu` (real renderer
fullscreen, only with no mpv open and the owner's go-ahead; it stops at the first
lost GPU device) - due for any change to shaders, gpu-toggles, renderer/hwdec
options or the pinned build. Such a pull request (and an mpv build whose video output,
decoding or colour code, libplacebo or FFmpeg hardware decoding changed) gets `[GPU: <areas>]` in its title, the
label gpu, a comment saying what, and the check "GPU tier (local)", pending until
`pwsh tests\try-gpu.ps1 -Pr <n>` (no mpv open) has run the gpu tier on its commit and
build in a folder of its own (`gpu-flag.yml`, `.github/scripts/gpu-flag.ps1`). An mpv build
with none of that says so in a comment: the owner merges it on green (2026-10-21). A fork's
pull request (read-only token) and Dependabot's get no flag: look at a fork's changes for GPU
areas yourself. Manual probes: give the clip no siblings
(`autoload.lua` queues them) and back up `speed.json` (remember-speed restores and
rewrites it); judge upscaling on `test-media/`'s clean clips (gitignored), never on
a soft low-bitrate film - one misled a Movie decision once. CI runs static + headless on every
push that changes more than docs (`*.md`, `doc/`; such a run ends green at once), and the
linters skip docs-only changes too; its privacy job runs on every push. `tests/README.md` has the harness rules: `H.expect` for a value an action
changes, `H.sleep` then `H.eq` for one that must not; a new feature gets a test, and
a deliberate break of it must turn it red. Before a Lua change: `stylua --check .`
(pinned version) and lua-language-server in directory mode (`--check .` in a copy
next to `.luarc.json` and `lua-api/`; its single-file mode checks nothing). CI's Lua lint
runs both on every push and pull request (lls pinned with its SHA-256 in lint-lua.yml).

**Validation checklist** (code comments cite these numbers):

1. input.conf parses (the static tier checks it).
2. `script-binding <script>/<name>` reaches only `mp.add_key_binding` handlers;
   `script-message-to <script> <name>` only `mp.register_script_message` ones -
   not interchangeable. A handler that needs the binding's `arg` must be `complex`.
3. A failing `mp.command`/`commandv` returns a value - check it; `pcall` does not
   see the failure.
4. (Historical) a filter string built with a value holding `=`, `:` or `|` needs
   mpv's `%N%` quoting.
5. Every shader a preset names exists in `shaders/` (a missing one is dropped with
   only a warning).
6. An upscale-chain change is measured in the real player: `glsl-shaders` and
   `vo-passes`, and `frame-drop-count`/`vo-delayed-frame-count`/`mistimed-frame-count`
   at 1x and 3x.
6a. Anything that persists is tested in two processes: one sets, a fresh mpv checks.
7. "It did not crash" proves nothing for rendering: look at the frame
   (`screenshot-to-file ... window`, or PrintWindow on the real window).
8. An `hwdec`/`gpu-context` change is verified with a real decoded video, not a
   synthetic lavfi source (hwdec only engages for real decoder input).

## Troubleshooting

- **UI drawn as coloured blocks, a black window, `VK_ERROR_DEVICE_LOST`** (2026-10-12):
  bad compiled shaders cached in BOTH mpv's `portable_config/cache` and AMD's
  per-application cache (`%LOCALAPPDATA%\AMD\VkCache`, files named
  `<app hash><device hash>*.parc`; the app hash is per exe path). They re-poison
  each other: clear both - right-click > Video > Upscale > Rebuild shaders, and
  Adrenalin > Settings > Graphics > Advanced > Reset Shader Cache. The same build
  ran fine from another path; the build was not the cause. The suite's copy
  (`%TEMP%\mpv-regression\root\mpv.exe`) has its own AMD files: a device loss in the
  gpu tier's cold-cache test alone is those gone stale - delete the `.parc` files a
  gpu tier run writes, then run that test once (2026-10-15).
- **An mpv.conf option silently ignored**: `#` starts a comment anywhere, also in a
  value; mpv logs one "Error parsing option" line. The headless `config-load` check
  fails on any warning while loading.
- **Options after a `[profile]` header** belong to that profile: profiles go last.
- **"client removed during hook handling"** (config-load, CI only): mpv's auto_profiles
  registered its hooks and unloaded itself while one was pending. mpv.conf has
  `load-auto-profiles=no`; a `profile-cond=` needs it back at `auto`.
- **Changing any `sub-*`/`osd-*` option** empties libass's caches (the next frame
  re-renders every subtitle): write such options only when the value changes.
- **A batch file that runs an update** must not read past it (cmd reads by byte
  offset; the update can replace the file): one parenthesized block and a label.
- **Keys not working in a FastStream window**: `check-keys.bat` while it is open.
- **The UI shows by itself during a film**: with the cursor still hidden, that was Windows
  handing the pointer back after another window covered it (fixed, `lib/cursor.lua`). If
  the cursor shows too, the mouse itself reported a move: mpv shows the cursor on any move.
- **The UI stays up and never goes**: Tab (`uosc/toggle-ui`) pins it until Tab again (the
  cursor hides, the UI stays); a menu or the sync panel open keeps it by design. A pointer
  resting on the bar hides it after 3 s (uosc.conf `autohide_over_controls`; uosc itself never).
- **Normal, not a problem**: a low GPU load at 1x (the card clocks down); the
  duplicate AMD layer and `VK_LAYER_OBS_HOOK` warnings `vulkaninfo` prints.

## Open items

None: the items the review of 2026-10-22 left are done (doc/history). A new open item or hand
test starts a new `TODO.md`; finished work goes to doc/history.
