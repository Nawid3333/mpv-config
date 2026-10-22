# Open items

Found by the full review of 2026-10-22 and confirmed in the code; not fixed yet because each
needs more than the headless suite can show. Finished work goes to doc/history, and this file
goes when it is empty.

## bottom-bar.lua: the lift ignores a moved sub-pos

The lift that moves subtitles above uosc's bar is computed from the subtitles' default place
(`sub-pos` 100). The right-click menu moves them (Subtitles > Position > Up / Down), and then
the lifted line lands that many percent of the frame too high or too low: after a few "Down"
steps it stays partly behind the bar, after "Up" steps it floats above it with a gap. Both
lift paths have it: ASS and picture subtitles (through `sub-pos`) and text subtitles
(through `sub-margin-y-offset`).

- Needed first: which height `sub-pos` counts in for each kind (the manual: "% of the screen
  height"; for ASS with `ass-use-margins=no` the video, for text subtitles probably the
  window). Settle it by looking at rendered frames (AGENTS.md validation item 7): a real
  window, so only with no mpv open and the owner's go-ahead for a visible test window.
- Then the lift from the subtitles' real place, and a test per kind with `sub-pos` 90 and 110.

## bottom-bar.lua: a sub-pos step while a clamped lift is applied

`set_pos()` clamps `sub-pos` to 0..150, but `adopt_user_pos()` takes the user's position
back as "what is set + the lift". With the user's own `sub-pos` near the top (10) and a lift
of 30 points, the written value is 0; a step to 5 then counts as a user position of 35, and
the bar hiding puts the subtitles there. Goes with the item above (the same code), with a
test that steps `sub-pos` while lifted.
