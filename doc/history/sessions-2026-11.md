# Session history: this mpv config repo, November 2026

Continues [`sessions-2026-10.md`](sessions-2026-10.md) (same rules: this is the
engineering log; `AGENTS.md` holds the current state and is read first).

---

## 2026-11-03: a skip to the end reaches the end (FastStream autoplay)

- The owner's report: after a skip to the end of an episode - `x`, `k`, or the timeline -
  FastStream's MPV autoplay mostly did not start.
- Measured with a copy of this config (mpv `vo=null`/`ao=null`, the URL loaded over IPC on a
  pipe of its own), followed by the FastStream helper's own `watchMpv` (the end detection the
  extension's relay watch shares: `eof-reached` false to true, an `end-file` eof, or 0.5 s or
  less left when mpv pauses or a seek lands). Streams: a 734 s film as HLS from a local server
  throttled to 2 MB/s, in two shapes - audio and video muxed in 6 s segments, and VOE's (a
  video playlist plus two audio renditions with playlists of their own); and a 2-minute muxed
  one, read whole at once.
  - At 1x, `x` with 39 s left: the seek landed at 695.6 s, 1 s on, and playback went on; no
    end within 14 s. `k` three times with 21 s left: landed 14 s before the end. `x` four times
    from 537 s: landed at 652 s. Paused, mpv stayed where it landed. mpv's log, each time:
    `[lavf] Seek failed (Operation not permitted)`. Muxed and VOE-shaped alike.
  - The whole file buffered: `x` past the end was taken from the buffer and ended the file at
    once. So it depended on whether the end was buffered yet, which right after the start
    it is not.
  - The timeline at its very end (uosc's `seek <duration> absolute+keyframes`): landed on the
    keyframe 2 s before the end; playing, the end came 2 s later; paused, never. uosc pauses
    mpv while the button is held and gives the old state back on release.
  - Trap: the first runs played at the copy's saved 3x and looked like successes - 14 s of
    waiting played the rest through. When the end came after the key told them apart.
- Cause: a relative seek past the end that the buffer cannot serve goes to the demuxer, and
  lavf's HLS demuxer refused it (the log line above); mpv then went on from where the demuxer
  was reading, the end of the buffer. A seek to exactly the duration was taken.
- Fix: `skip-forward.lua` for `x`, `k`, Right and the media Forward key: a skip that would pass
  the end, or land in its last second, is `seek <duration> absolute+exact`, and playback goes
  on; uosc's timeline does the same when let go on its last pixel (a local change). On both
  734 s streams with the real keys (`keypress`): every case ended - one key 0.13-0.24 s after
  it, playing or paused; repeated presses ended with the press that passed the end (mpv's log:
  the first three went out as relative seeks, the fourth to the end). Without the last-second
  margin, `k` paused with the target 0.3 s before the end landed 2.4 s before it on the muxed
  stream.
- Why playback goes on: on the suite's clip (one 180 s MPEG-TS segment as HLS, keyframes 1 s
  apart) the exact seek to 180 s showed the last frame (179.958 s) with mpv's video
  "playing (paused)" and no `eof-reached` - the end comes only when playback asks for the frame
  after it. Playing on reaches it, and keep-open pauses there again, as at any end.
- Test: `skip-to-end` - keys: that clip read only ~1.5 s ahead, the buffer dropped before each
  case, paused, `x`, `k`, Right and Forward from spots whose end is not buffered, and a skip
  inside the file unchanged; timeline: a click on its last pixel ends the file, one in the
  middle stays a keyframe seek (`--vo=sixel` surface). On CI without the fix (#29's first two
  commits): `x` from 150 s landed at 152 s, `k` from 172 s at 174 s, Forward from 140 s at
  142 s - each the end of the buffer - and the timeline's last pixel did not end the file.
  Right (to 0.5 s before the end) ended there without the fix: the last-second margin rests
  on the measurement above, not on this test. The first run kept each case's buffer, and only
  `x` was red: the others found the end buffered by the case before.

## 2026-11-03: downloaded subtitles go after a week, and never into git

- The owner's question: why a subtitle he had fetched for one film (on 2026-11-01) was still
  in `portable_config/subtitles`.
- Why: uosc's "Download subtitles" (OpenSubtitles) saves a stream's subtitles in
  `subtitles_directory` (uosc.conf: `~~/subtitles`; a local file's go next to it), and nothing
  deleted them. FastStream's helper writes its own subtitles into the temp folder, not there.
  mpv does not load them again by itself: for a URL, `--sub-file-paths` scans only absolute
  paths and the config's `sub` folder (manual). And the folder was not in `.gitignore`: a
  `git add -A` in the install would have put a film's name into this public repository.
- His choice: keep them a week, then delete them by themselves.
- `subtitle-cleanup.lua`: each start deletes the files there with a subtitle extension mpv
  knows (`sub-auto-exts`, any case) that are older than 7 days; other files and folders stay,
  and one that cannot be deleted waits for the next start. `.gitignore` takes the folder, the
  static tier's privacy sample list a file in it, and the suite's config copies leave it out.
- Test: `subtitle-cleanup` - a start with no folder; then, with two 8-day-old subtitles, one
  of now, an old picture and a folder, the next start deletes just the two.

## 2026-11-03: mpv builds held back by mpv's macOS CI

- Issue #28: shinchiro's builds of 2026-11-01, -02 and -03 were each "built from a commit mpv's
  own CI failed", so none was offered and main kept 20261021. The owner asked whether a pull
  request fixes it, and for the failing CI not to come back.
- mpv's checks on those three commits (GitHub's check runs): one job failed each time, `macos
  (xcode-27, macos-27-arm)` (a new Xcode preview), and the other macOS jobs were cancelled with
  it; on a687796d9d one of fifteen runs of the `cache` job was cancelled too. Every Windows
  (msys2, mingw, win32), Linux, BSD and lint job passed. The gate counted any failed or
  cancelled check run as mpv's CI failing.
- `.github/scripts/upstream-ci.ps1` now gives the verdict: macOS jobs do not count (nothing of
  them is in a Windows build; `swift` is a lint on Ubuntu and still counts), a job counts as
  passed when one of its runs passed (a re-run after a flake, or a job several workflow runs
  share), and the failed jobs are named in the issue. On the real checks of the three
  commits: failed with the old filter, passed with the script; with one msys2 job made to
  fail, failed, naming it. The static tier holds nine cases and the way the workflow calls it.
- The builds still go through this suite and the owner's merge as before.

## 2026-11-19/20: the cross-repository audit, and FastStream's offer

- The audit of this repo and FastStream as one system (the hand-off of a stream to mpv) is
  recorded in FastStream's `docs/history/reviews.md`, "The cross-repository audit, FastStream
  and mpv-config": what was found, measured, disproved and left open. Its fixes here:
  - #49: a stream from the helper's HLS package is buffered and labelled as a network stream,
    also with `#` in the temp path (M1, M2).
  - #50: such streams draw the buffer and fetch no thumbnails, the source menu shows "Stream
    URL", and the episode keys name the right reason (D2-D4).
  - #51: `faststream-private.lua` removes a private window's package when mpv moves on or
    closes (D1, with FastStream's helper 29).
- #52 and #54: two main-CI failures, both timing in the tests (`test-notify.lua` raced
  notify.lua's offset before publish; the launcher check tripped StrictMode reading the offer
  before it existed).
- #53 and #55: the "Play here" / "Play in a new window" banners, for a file opened from
  Explorer (`single-instance.lua`) and for a stream FastStream sends (`faststream-offer.lua`,
  with FastStream #786). The click code is one module (`script-modules/banner-click.lua`) with
  one guard for every script's banners; reviews by glm, Codex and the Claude API reviewer are
  in the pull requests.

## 2026-11-25: "Add to queue" (#60)

- The owner's wish: a stream FastStream sends while a window plays can wait behind what plays, as a playlist; the
  same for files opened from Explorer. His decisions: the queue goes before FastStream's autoplay (no autoplay while
  anything is queued; the queue's last item's end goes on with its tab's next episode); the same countdown as autoplay
  before each item, Space stops it; private windows too; the panel shows only queued items (never autoload's folder
  playlist: uosc's playlist button has those) and exists only while something is queued; click to play, x, Clear and
  drag to reorder; an offer left alone goes to the queue.
- Built as `Scripts/queue/` (main.lua the queue, panel.lua the Up next panel), a third offer banner in
  faststream-offer.lua and single-instance.lua, compact offer banners (notify.lua, 0.85), and FastStream helper 33
  (FastStream #846: the stream and its per-file options go to `script-message-to queue add-stream`).
- Found on the way, each shown red first: a `loadfile` with `options = {}` fails (mpv's Lua takes an empty table for
  an array: every Explorer file was refused); the x's hit box lay under its row's (hit_at looks from the last box
  back); the queue put the global keep-open back over FastStream's file-local one; a click right after a move was
  resolved where the mouse-pos observer last said (CI log: the click meant for one row removed another); a seek in
  the test came while the next file loaded and was dropped. glm's review found three ways the queue stalled at an
  end (only the eof-reached edge started the countdown: queued at an end, the first moved, the counted one removed;
  `follow_end` now follows every change) and, in FastStream, autoplay never came back when the queue was emptied at
  an end it held (`resumeHeldEnd`). Its two other findings (press and release swapped in
  `set_key_bindings`, `choices.queue` a table) did not hold against mpv's code and CI.
- notify-render failed once at its first check (`osd-dimensions` 0x0 under vo=sixel, read without a wait) and passed
  in the next run: not changed here, not established as a race.
- Open: the Up next card's look (four variants offered, his pick pending) and a "what's next" card for local files
  (cover or frame): TODO.md.

## 2026-11-25: updater.bat updates a helper installed by hand

- After FastStream #846 (helper 33) the owner ran updater.bat and Firefox updated the add-on, and FastStream said
  the helper was out of date: his was installed by hand from a FastStream checkout (system Node.js, no setup
  marker), and update.ps1 left every such helper alone, to keep a developer's own. He asked why updater.bat cannot
  do it. Now install-faststream.ps1 -HelperOnly (update.ps1's step 4) also takes one installed by hand that starts
  this mpv, when its HostVersion is older than the release's: the release's files (checked against
  native-host.sha256), its own Node.js kept (a private one only when it does not run), no marker. One as new or
  newer, or for another mpv, stays. Shown red first: the older helper stayed at 32 on main's installer.

## 2026-11-25: the Up next card (#61)

- TODO.md's two items, done as the owner picked them: the card's look A (compact: picture, three lines, +N, the
  countdown's line) of four drawn variants; the card for local files too - without a queue it shows the playlist's
  next local file, with uosc's UI and in a file's last 5 s (he changed 10 to 5, for the queue's card as well); a
  queued stream keeps the queue's icon (his call: a second mpv for a stream's frame is too much, a frame is for local
  files); a song's card sits inside music-info's panel, in its right column, and that panel's "Up next:" line goes.
- The picture comes from a short hidden mpv in encoding mode (no window, no GPU), one raw BGRA frame, shown with
  `overlay-add` as thumbfast does. Measured before it was wired in: with the scale filter set at `file-loaded`, 3 of
  3 runs wrote the source's own size and format (the decoder was made first); set at `on_preloaded`, 5 of 5 were the
  card's size, the seek a third in took effect (the frame differs from a run without it), a cover came square and a
  song without one wrote its tags only. `--aid=no` had hidden the audio track from `current-tracks` (every song read
  as no song): `track-list` is read instead.
- On CI the frame came (`ready`) but was never counted as shown: overlay-add has no result, so `mp.command_native`
  gives nil on success too and only an error means failure (glm's review named it as well, with what it would have
  done: a hidden card leaving its frame on screen). glm also had music-info observe the card's own key, which a
  publish without it may not reach (not established either way; the whole table is observed now). Its third
  finding (`playlist()` never returning the current entry) did not hold.
- The GPU flag named probe.lua's `vf`: it runs only in the hidden encode-mode mpv, never in the player. The owner
  chose to exempt that file (`$NoGpuScript` in gpu-flag.ps1, three static cases: that file, the same line in a
  player script, a file renamed onto it).
- TODO.md is gone; AGENTS.md's open items are none again.

## 2026-11-21/22: install.bat on its own

- A review of the installer scripts (glm-5.3-flash) found, and a run confirmed: `install.bat`
  without a setup beside it ran the fetched setup through `powershell -Command`, which joins
  and splits its arguments again (`-InstallDir "C:\My mpv"`: "no positional parameter accepts
  mpv") and drops the setup's exit code (a failed install ended with 0). It now downloads the
  setup to a folder of its own in `%TEMP%`, runs it with `-File` and removes the folder; the static
  tier runs it against a stand-in setup fetched from a `file:` URL. `setup.ps1 -Zip` checks for
  `sync-config.ps1` beside it, as a fetched setup now has a folder too.
