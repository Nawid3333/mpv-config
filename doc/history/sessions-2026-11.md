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
