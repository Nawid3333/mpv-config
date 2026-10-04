-- auto-start.lua - every newly loaded file starts playing immediately
--
-- Reported 2026-09-19: "sometimes when I start an anime via FastStream in mpv
-- the video does not start, I still have to hit enter or start". Root cause:
-- mpv's `pause` option is GLOBAL - it carries across files within one mpv
-- process (manual, "Per-File Options": an option changed at runtime is not
-- reset when a new file plays). Both of this setup's "next episode" paths hand
-- the file to an ALREADY-RUNNING player via loadfile:
--   - FastStream's native host reuses its single instance (set_property for
--     headers/title, then `loadfile <url> replace` over its IPC pipe)
--   - mpv-single.exe swaps the running window's playlist the same way
-- If the previous file was paused when the next one arrived - paused by the
-- user (common since the mbtn_left click-to-pause binding) or paused AT EOF
-- (keep-open=yes in mpv.conf "will act like set pause yes on EOF" - manual) -
-- the new file inherits pause=yes, renders its first frame, and sits there
-- until a manual unpause. A FRESH mpv spawn is unaffected (pause defaults to
-- no), which is exactly why this only happens "sometimes".
--
-- Fix: clear the inherited pause once per file, at file-loaded - i.e. only at
-- the load boundary. A pause at any point DURING a file's playback is
-- respected (file-loaded does not fire again until the next load), so
-- click-to-pause, space, and the uosc timeline scrub-pause all keep working.
-- The one boundary case: a pause set during the load window itself (between
-- loadfile and file-loaded, ~1-3s on a network stream) is indistinguishable
-- from an inherited pause and is cleared too - acceptable, since the
-- overwhelmingly common pause at that moment is the inherited one.
--
-- Delays too (2026-10-02): sub-delay and audio-delay are global options as
-- well, so a delay set for one episode (the sync tool's Enter, Ctrl+/-, the menu)
-- silently shifted the subtitles or sound of every later file in the window.
-- They are set back to 0 when a file UNLOADS; within a file they stay.
-- Not at the next file-loaded, as until 2026-10-04: by then mpv has already
-- applied that file's own delays - the ones "Quit & save position" / "Save
-- position now" stored (watch-later restores sub-delay and audio-delay with
-- the position), a per-file option, --sub-delay on the command line - and the
-- reset threw them away (measured: a file reopened after Q came back at its
-- position with both delays 0). In the on_unload hook the core waits for this
-- script, and a delay the file brought along is put back to the value from
-- before the file by mpv itself afterwards (its file-local backup).
--
-- Not affected: paused-for-cache (mpv's internal buffering pause) is a
-- separate mechanism from the `pause` property and is not touched, so
-- cache-pause-initial=yes in mpv.conf still buffers before starting.

local mp = require('mp')

mp.register_event('file-loaded', function()
	if mp.get_property_native('pause') then
		mp.set_property_native('pause', false)
	end
end)

mp.add_hook('on_unload', 50, function()
	for _, name in ipairs({ 'sub-delay', 'audio-delay' }) do
		if (mp.get_property_number(name) or 0) ~= 0 then
			mp.set_property_number(name, 0)
		end
	end
end)
