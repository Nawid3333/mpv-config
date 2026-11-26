# Open leads (review of 2026-11-26)

Seen in the code during the review and not reproduced: each is a lead, not a fact, until a test
shows it (AGENTS.md, "Data, not guesses"). They are small or rare, so they wait. A fixed one moves
to doc/history with its test; one found to be no bug is struck from this list with the reason.

- **auto-release.yml**: its concurrency group is per commit (`auto-release-<sha>`), so two pushes
  to main whose CI ends at the same time run at once, and both can pick the same `vYYYY.MM.DD.N`.
  A group for all of them would let GitHub cancel a waiting run (a grey X on main, which reads
  as a failure).
- **subtitle-sync.lua**: the audio analyser's subprocess has no time limit, so a hung one stops
  every later chunk (`audio.running` stays set); a chunk whose analyser stopped part-way with some
  output counts as `done`, and its missing part stays a gap in the timeline.
- **subtitle-toggle.lua**: the subtitle match by file name is fuzzy: `Episode 1` can take
  `Episode 12`'s subtitles. mpv's own `sub-auto=fuzzy` does the same.
- **source-info.lua**: an open Source menu keeps the previous file's links after a file change.
- **single-instance.lua**: a "Play in a new window" whose mpv fails to start says nothing.
- **shader-cache/**: two mpv windows starting together can both decide to warm up; the warm-up's
  240 s hard stop is counted as a failure, not as "too slow".
