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
-- One file is left paused: the one a quality switch made while paused loads
-- (faststream-quality.lua), the same video in another quality. Its switch names it in
-- user-data/auto-start/keep-pause, read and cleared at the next file-loaded: a switch
-- whose file never loaded leaves no pause for the file after it (issue #96).
--
-- The delays go back to 0 when a file UNLOADS, not at the next file-loaded: by
-- then mpv has applied that file's own delays (watch-later, a per-file option,
-- --sub-delay), which must survive.

local mp = require('mp')

local KEEP_PAUSE = 'user-data/auto-start/keep-pause'

mp.register_event('file-loaded', function()
	local keep = mp.get_property_native(KEEP_PAUSE)
	if keep ~= nil then
		mp.del_property(KEEP_PAUSE)
		if keep == mp.get_property('path') then
			return
		end
	end
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
