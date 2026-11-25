# Open items

- **The Up next card's look**: four variants (A-D) were drawn for the owner on 2026-11-25; his pick is pending.
  Then `Scripts/queue/panel.lua`'s `draw_card` takes that look.
- **A "what's next" card for local files** (his wish, 2026-11-25): bottom right while the UI shows, the next playlist
  entry with a picture - the cover for music, a frame for video (a hidden mpv grabbing it to raw BGRA, then
  `overlay-add`, as thumbfast does). For a queued stream maybe a frame too, never for a private window's: measure
  first. FastStream's autoplay episode cannot have one (it is sent only once the stream ends).
