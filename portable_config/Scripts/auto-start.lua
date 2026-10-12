-- auto-start.lua - every newly loaded file starts playing, with no leftover delays
--
-- `pause`, `sub-delay` and `audio-delay` are global options: they carry over to
-- the next file in the same process. FastStream's next episode and
-- mpv-single.exe both hand the next file to the running player (loadfile
-- replace), so a file paused by the user - or at its end, keep-open=yes pauses
-- there - left the next one sitting on its first frame, and a delay set for one
-- episode shifted every later one.
--
-- The pause is cleared once per file, at file-loaded: a pause during playback
-- stays. A pause set during the load itself is cleared too (it cannot be told
-- from an inherited one). The cache's own buffering pause (paused-for-cache) is
-- separate and untouched.
--
-- The delays go back to 0 when a file UNLOADS, not at the next file-loaded: by
-- then mpv has applied that file's own delays (watch-later, a per-file option,
-- --sub-delay), which must survive.

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
