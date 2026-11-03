# Session history: this mpv config repo, November 2026

Continues [`sessions-2026-10.md`](sessions-2026-10.md) (same rules: this is the
engineering log; `AGENTS.md` holds the current state and is read first).

---

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
