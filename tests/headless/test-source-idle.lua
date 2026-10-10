-- source-info.lua with nothing loaded (mpv started without a file, as from the
-- Start menu): the Source button names no source. It read "File", its menu
-- "Source: local file" (2026-10-10 review).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.sleep(1)
	H.eq('nothing loaded: the Source button has no badge', mp.get_property_native('user-data/source-info/badge'), '')
end, { wait_file = false })
