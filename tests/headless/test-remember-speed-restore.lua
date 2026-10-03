-- remember-speed.lua, process 2 of 2 (see test-remember-speed-save.lua).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.eq('a fresh mpv process restores the last speed (2.5x)', mp.get_property_number('speed'), 2.5, 0.001)
	-- Restored once per process, not per file: a later file keeps the speed
	-- the user has now, not the saved one.
	mp.set_property_number('speed', 1.5)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('the next file keeps the current speed', mp.get_property_number('speed'), 1.5, 0.001)

	-- Within one process, a switch between a video and a song sets the speed of that
	-- kind (2026-10-02: a song after a 3x episode played at 3x).
	H.load(H.media_path('autoload/song.flac'))
	H.eq('a song after a video plays at 1x', mp.get_property_number('speed'), 1, 0.001)
	mp.set_property_number('speed', 1.25)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('the next video gets the video speed back', mp.get_property_number('speed'), 1.5, 0.001)
	H.load(H.media_path('autoload/song.flac'))
	H.eq('and the next song the song speed', mp.get_property_number('speed'), 1.25, 0.001)
	local f = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json', 'r')
	local content = f and f:read('*a') or ''
	if f then
		f:close()
	end
	H.check('a song never writes its speed into speed.json', content:find('1.5', 1, true) ~= nil, content)
end)
