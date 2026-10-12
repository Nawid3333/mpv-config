# TODO: what is open (status 2026-10-12, afternoon)

The 2026-10-11 handover's five items were worked on in the night to 2026-10-12, while Nawid
was away. On his return he said: "merge every PR and then clean up the branches and the work
trees" - **every pull request below is merged** (2026-10-12), the bots' too (mpv 20261012,
pnpm, Dependabot), and only `main` is left in both repositories. Then: "a full review of MPV
and ... of FastStream ... and how they work together. And if you find some problems, you can
fix or any improvements you can make" - section 5; its fixes are merged too.

Repo rules that still apply (see `AGENTS.md`):
- Work in a clone, never in `C:\Program Files\mpv`. That is his live install, read-only for agents.
- Run the suite (`pwsh tests/run-tests.ps1`) before a PR; a PR waits for green CI.
- Ollama helpers: only `glm-5.3-flash:cloud` (his rule of 2026-10-12, in the global CLAUDE.md).
- The FastStream side of the mpv features lives in `Nawid3333/FastStream`.

---

## 1. Merged on 2026-10-12

### mpv (Nawid3333/mpv)

| PR | What | From |
|---|---|---|
| #77 | stylua 2.6.0, and `stylua-update.yml`, which moves the pin (CI and the editor) with each StyLua release, on Dependabot's weekly rhythm | his request ("the pinned moves with it") |
| #78 | **Buffering = FastStream's buffer settings**, RAM first then disk (new `stream-buffer.lua`); his PC's 2 GB becomes the RAM budget. An empty field is no limit, 0 caps at 0 (his rule, as in FastStream - checked there too) | item 1 |
| #79 | Episode buttons hide when the FastStream helper stops beating (a helper killed hard) | item 4, mpv side |
| #80 | `check-keys.bat`: which keys each running mpv uses, and why | item 3 |
| #81 | the update path: `updater.bat` and `install.bat` no longer misread themselves when the update replaces them; `update.ps1` no longer pulls a repository the folder only sits in; `sync-config.ps1`'s temp name | the review (below) |
| #82 | TODO.md, and the review's findings below | |
| #83 | ci: pin mpv 20261012 (shinchiro), offered by mpv-auto-update after the suite passed on it | the bot |

### FastStream (Nawid3333/FastStream)

| PR | What | From |
|---|---|---|
| #452 | mpv host 10: the heartbeat (HostVersion and RequiredHostVersion 10) | item 4 |
| #453 | MPV autoplay: asks the page before counting down, says a series' end at once; a frame that never answers no longer stalls autoplay | item 5, glm's review |
| #454, #455, #457 | Dependabot's tooling updates; CI's mpv 20261012; pnpm 12.12.1 | the bots |

All were green on CI when merged, FastStream's e2e suites included (they were not run on
his PC: they open windows on his desktop).

**To get them on his PC:** run `updater.bat` in `C:\Program Files\mpv` (the config, and the
mpv 20261012 build #83 pins), and `update-local.cmd` in his FastStream checkout (it
reinstalls the helper, as host 11 since FastStream #461). FastStream released itself on the green push to `main`;
Firefox updates the add-on. The first `updater.bat` run after #81 still misreads its own
replaced file once (an error line, the update run twice), then never again.

## 2. His hand tests

- From the handover (item 2, still due): the ⏮ / ⏭ buttons and the autoplay switch on a
  stream FastStream sent; Anime lines (Settings ▸ Upscale) on the anime whose lines looked
  too thin; autoplay from a season's last episode to the next season (FastStream 1.3.82.89,
  released 2026-10-11).
- Buffering (#78): Settings ▸ Buffering shows six submenus; while a stream plays the menu's
  top line says what it is doing ("This video: predownloading, 1.7 GB in RAM, ...").
- The heartbeat (#79 + #452): end the helper in Task Manager (the `node.exe` of
  FastStreamMpvHost) while mpv plays a FastStream stream: the three buttons go within 90 s.
- The countdown (#453): at a series' last episode mpv says so at once, with no countdown.
- The keys (#80): if mpv ignores the keys again, run `check-keys.bat` while that mpv is open.
- Section 5's fixes: `n` on a local file says "Next episode - only for videos FastStream sends
  to mpv" (#84); at an episode's end with autoplay on, "next episode in 5 s" stays up for the
  5 s (FastStream #461, after `update-local.cmd`); with a FastStream window open, "Open with
  mpv-single" on a local file brings the window that plays it to the front (#86).

## 3. Decisions recorded (2026-10-12)

- Buffering: RAM first, then disk; FastStream's defaults with the RAM budget by the PC's
  memory (2 GB from 16 GB); every PC moves (his: 2 GB RAM, then disk, predownload on).
- VRAM for the buffer: no benefit (the buffer is the compressed stream, ~1 MB/s; RAM and
  disk seeked alike, 6-8 ms) - not done.
- Ollama: `glm-5.3-flash:cloud` only, as the main and only helper (global CLAUDE.md,
  Hermes' SOUL.md, the memory).

## 4. Review of both repositories (2026-10-12)

His request: "review both repos mpv and faststream ... bugs or things you can do better".
Reviewed by reading and by `glm-5.3-flash` (whole files sent through the PC's Ollama); each
finding was checked against the code before anything was changed.

### Fixed (each in a pull request above, with a test that fails without the fix)

| Where | What was wrong | PR |
|---|---|---|
| `updater.bat`, `install.bat` | cmd reads a batch file by byte offset; the update (git pull, sync-config) can replace the file, and cmd went on in the new one at the old offset: pieces of lines run as commands, the update run again, exit 9009 (measured). Now one block and a `:failed` label. The update that brings this still misreads once. | #81 |
| `stream-buffer.lua` (new) | before any review: a setting that is `false` read as its default (`cond and false or x`); after deepseek's and glm's reviews: the switch to disk could come after a burst had parked the demuxer at its limit (a paused player then stayed there), the metadata limit was set once, no free-disk guard, live detection decided on the first tick, RAM only could squeeze reading ahead to 4 MB | #78 |
| `update.ps1` | a folder INSIDE another repository (a home folder kept in git) counted as a clone, and `git pull` ran in the outer repository (glm) | #81 |
| `sync-config.ps1` | wrote each file through `<name>.new`, which overwrote a file of that name and then counted it as up to date (glm) | #81 |
| Buffering, Custom... | on CI the typed value never reached mpv's input line: the open uosc menu's own keys (type to search) can take it. The menu now makes way while the line is open and comes back after. | #78 |
| FastStream `goToEpisode` | a frame that never answered the next-episode request left `state.going` set: every later key, button and autoplay of the session did nothing, silently. Now 5 s per frame, and no further frame is asked after a timeout. | FastStream #453 |
| FastStream host `readMessage` | read the first frame and dropped the rest of the same chunk: a message posted right after `watch` was lost | FastStream #452 |
| FastStream host, Linux/macOS | the IPC socket's name had no token; without `$XDG_RUNTIME_DIR` it sits in the shared temp folder, where another account could take it first (as on Windows, #156) | FastStream #452 |

### Checked and found right (no change)

- **Anime lines "As drawn"** needs nothing in the shader warm-up: a check run with every Anime
  step as drawn (40 chains without Restore, verified in the log) compiled 0 shaders over 39
  steps - the cache from the normal warm-up covers it.
- `os.getenv` inside mpv returns UTF-8 (mpv's process code page; a `TEMP` with "ü" came out
  as `c3 bc`), so a user folder with an umlaut does not break the disk cache.
- `sync-config.ps1` and `update.ps1` (read in full): changed files are set aside, files the
  config never had are never touched, the manifest is written last, LFS objects are checked.
- `gpu-toggles.lua` and `settings.lua`: glm traced every path and found no defect.
- `stream-resume.lua` at a live stream's edge: the position counts as finished and is not saved.
- uosc keeps a submenu without an explicit `id` open across `update-menu` (it derives one from
  the parent's id and the title).
- FastStream `mpvSentUrls` (glm thought a stream sent twice would do nothing): the player's
  button and the MPV key pass no tab, and a play, a navigation or MPV mode clear it - no bug.
- FastStream's next-episode/series-end detection (`content.js`): three reviews already
  (deepseek, kimi, glm in its PR); consistent with what the countdown fix asks.

### Left as they are, on purpose

- The shader warm-up's lock is checked, then written: two mpv windows starting a warm-up in
  the same instant could both run one (more GPU work for a while, nothing breaks; glm). A
  second window that finds a warm-up running does not retry in that session - the next start
  does (by design). glm's third claim there was wrong: `mp.command_native_async` returns the
  command's id, and the timeout test shows the abort works.

- FastStream `launchDirect` (Linux/macOS) answers "started" after 500 ms; waiting for mpv's
  window would hold the reply that pauses the browser tab. By design.
- FastStream `saveOption` reads and writes the whole options blob; the autoplay switch and an
  options page saving in the same moment could lose one change. Rare; not changed.

### Observed, not ours

- YouTube's 4K AV1 format answered HTTP 403 in 2 of 4 test runs (once on the very first
  request), with yt-dlp 2026.08.19 (current). Playback then stops where the download stopped,
  with any buffer setting.

- Two flaky CI checks, each green on a re-run of the same commit: mpv's
  `test-source-info.lua` "(a copy before refusal 2)" read no clipboard on the runner (the
  Windows clipboard is shared; first time in the last 30 runs), and FastStream's
  `dialogs.e2e.mjs` a dialog's colour (main's CI was red on a flaky e2e test once too, #450).

### Wrong claims of the reviewers (measured, not changed)

- `Test-Path` on a URL "throws under Stop": it returns `False` (PowerShell 5.1 and 7).
- `git pull` / `yt-dlp -U` "die in Windows PowerShell 5.1" on their stderr: only when
  PowerShell itself redirects it (`*>` inside the script); updater.bat's console does not.

### Ollama's limit

- The Pro weekly limit was reached at 01:25 and cleared at 02:00; the two reviews it stopped
  (the shader warm-up controller, the one-click update path) ran after it.

## 5. Review of how mpv and FastStream work together (2026-10-12, afternoon)

Read by hand and by `glm-5.3-flash` (the URL contract between the host and the mpv scripts,
the playback state across files, the player's mpv button through the host into mpv,
subtitle-sync, the UI scripts), each finding checked against the code before anything was
changed.

### Fixed (merged, each with a test that fails without the fix)

| Where | What was wrong | PR |
|---|---|---|
| FastStream host + extension (host 11) | every notice FastStream showed in mpv went after notify.lua's 2 s: "next episode in 5 s" was gone 3 s before the episode, "the page brought no stream within a minute; open it in the browser to see why" before it was read. Now the countdown's stays for the countdown, sentences 6 s, and a countdown stopped with nothing else to say is taken down. | FastStream #461 |
| `faststream-episodes.lua`, notify.lua | `n` / `N` / `Ctrl+a`, the Playlist menu's entries and the Welcome tour's "Next episode" did nothing, silently, in a window FastStream does not follow. Now a banner says why; FastStream's banners got the autoplay switch's icon. | #84 |
| `remember-speed.lua` | a speed picked while the next file loads (FastStream's next episode takes seconds) was neither saved nor remembered; and a speed set right before the next file loaded could be lost to the observer seeing the next file first (CI hit that once) | #85, #87 |
| `mpv-single.exe` | after handing a file to its mpv it raised the first process named mpv with a window - with FastStream's window open, maybe that one. Now the process behind its pipe. | #86 |
| FastStream player's mpv button | a second click within 3 s was answered "sent" at once: the player said so and paused the page while the first send could still fail. Now it gets the first send's answer. | FastStream #463 |

### Checked and found right (no change)

- `video-info.lua` reads only `fs-content=` as FastStream, `source-info.lua` also `fs-id=` /
  `fs-page=`: every send carries `fs-content=` (`resolveMpvContentType` falls back to movie).
- source-info's Copy of a yt-dlp address: yt-dlp's output never carries the host's `fs-*`
  tags (FastStream sends no YouTube); only a local file literally named `...#fs-id=...` reads
  as FastStream.
- auto-start.lua "clears a pause watch-later restored" (glm): mpv's watch-later never saves
  `pause` (`configfiles.c` writes only the `watch-later-options` list; our build's list has
  no `pause`).
- The host "never uses the content type" (glm): it goes into the URL as `fs-content=`.
- subtitle-sync's `mp.unobserve_property(on_move)` (glm: "needs a handle"): mpv's Lua API
  takes the function. Its ffmpeg extraction outliving the file: mpv ends `subprocess` jobs at
  the file's end (`playback_only`, on by default).
- music-info and a music video (glm): a real video track is not "audio", so no panel over the
  picture; only the window title.

### Left as they are, on purpose

- stream-resume and live streams: mpv reports a growing duration for a stream without one
  (`demux.c`: the highest timestamp read), so the "no duration = live" guard never fires. A
  live stream watched more than 3 min behind its edge and opened again gets one pointless
  seek at the start. Rare; a fix needs a live test source the suite does not have.
- `speed.json` / `stream-resume.json` are replaced by remove-then-rename (Windows' `os.rename`
  cannot replace): a crash in those microseconds loses the saved speed, and a second mpv
  window reading just then can drop the first one's resume entry. An atomic replace needs
  `MoveFileExW` through the FFI with UTF-16 paths.
- FastStream host: two different streams sent within about a second while no mpv runs can
  start two windows (the second without IPC). A lock across host processes would close it.
- FastStream host: a stream handed to an mpv the user paused stays paused with another mpv
  config; this setup's auto-start.lua unpauses every new file. Unpausing from the host would
  let a moment of the old file's sound play.
- subtitle-sync: switching subtitle tracks quickly while the panel is open can leave one more
  ffmpeg extraction running until the file ends (its result is dropped).

### glm's limits

- The UI scripts (notify, bottom-bar, video-info, music-info): three tries, each thinking
  through its whole answer budget (32k tokens) without an answer. Its one concrete suspicion
  is checked above; these scripts have the render test and the design pass's review.

## 6. Still open after this

- His hand tests (section 2).
- Section 5's "left as they are" items, if any of them ever shows up in use.
- Item 3 itself: not reproduced; `check-keys.bat` (#80) is for the next time.
- The FastStream e2e suites were not run locally for #452/#453 (CI ran them).
