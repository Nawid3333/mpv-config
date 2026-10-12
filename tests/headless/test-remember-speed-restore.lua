-- remember-speed.lua, process 2 of 3 (see test-remember-speed-save.lua).
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
	-- the saved speed itself, not a search for "1.5": a file holding 1.25 as well passed that
	H.eq(
		'a song never writes its speed into speed.json',
		(require('mp.utils').parse_json(content) or {}).speed,
		1.5,
		0.001
	)

	-- A speed picked while the next video loads (FastStream's next episode takes
	-- seconds): track-list is empty then, so the observer cannot tell a video, and
	-- until 2026-10-12 that speed was neither saved nor the video speed after the
	-- next song. The hook sets it and holds the load 0.3 s, as a key press would.
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('(a video at the video speed)', mp.get_property_number('speed'), 1.5, 0.001)
	local during_load = nil
	mp.add_hook('on_load', 50, function(hook)
		if during_load then
			mp.set_property_number('speed', during_load)
			during_load = nil
			hook:defer()
			mp.add_timeout(0.3, function()
				hook:cont()
			end)
		end
	end)
	during_load = 2
	H.load(H.media_path('plain/clip.mkv'))
	H.eq('a speed picked while the next video loaded stays', mp.get_property_number('speed'), 2, 0.001)
	H.expect('... and is saved', function()
		local file = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json', 'r')
		local text = file and file:read('*a') or ''
		if file then
			file:close()
		end
		return (require('mp.utils').parse_json(text) or {}).speed
	end, 2, 0.001)
	H.load(H.media_path('autoload/song.flac'))
	H.eq('(the song speed)', mp.get_property_number('speed'), 1.25, 0.001)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('... and is the video speed after a song', mp.get_property_number('speed'), 2, 0.001)

	-- The same while a song loads after a video: the picked speed wins over the
	-- song speed the switch would set.
	during_load = 3
	H.load(H.media_path('autoload/song.flac'))
	H.eq('a speed picked while a song loads after a video stays', mp.get_property_number('speed'), 3, 0.001)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('(the video speed comes back)', mp.get_property_number('speed'), 2, 0.001)
	H.load(H.media_path('autoload/song.flac'))
	H.eq('... and the picked speed is the song speed', mp.get_property_number('speed'), 3, 0.001)

	-- A speed the file brings along (watch-later's saved one; here a per-file
	-- option, applied the same way before on_load) is that file's, not a pick:
	-- never saved as the video speed.
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('(the video speed again)', mp.get_property_number('speed'), 2, 0.001)
	local restarted = H.expect_event('playback-restart')
	mp.commandv('loadfile', H.media_path('plain/clip.mkv'), 'replace', '-1', 'speed=1.75')
	H.check('(the file with its own speed loads)', restarted(15))
	H.eq('(it plays at its own speed)', mp.get_property_number('speed'), 1.75, 0.001)
	H.sleep(0.5)
	local file = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json', 'r')
	local text = file and file:read('*a') or ''
	if file then
		file:close()
	end
	H.eq(
		'a speed the file brings along is not saved as the video speed',
		(require('mp.utils').parse_json(text) or {}).speed,
		2,
		0.001
	)
	-- ... nor when that file goes
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('the next video plays at the video speed again', mp.get_property_number('speed'), 2, 0.001)
	H.sleep(0.5)
	file = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json', 'r')
	text = file and file:read('*a') or ''
	if file then
		file:close()
	end
	H.eq('... and speed.json still holds it', (require('mp.utils').parse_json(text) or {}).speed, 2, 0.001)
end)
