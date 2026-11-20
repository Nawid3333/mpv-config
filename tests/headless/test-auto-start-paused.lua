-- auto-start.lua with start_paused (mpv-single.exe --paused: the new window
-- single-instance.lua offers): mpv started with --pause keeps its first file
-- paused, and the next file it loads plays as always.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.sleep(1)
	H.eq('the first file waits paused', mp.get_property_native('pause'), true)
	H.check('... at its start', (mp.get_property_number('time-pos') or 0) < 0.5, mp.get_property('time-pos'))

	H.load(H.media_path('second/clip2.mkv'))
	-- auto-start.lua's file-loaded handler may run after the harness's
	H.expect('the next file plays', function()
		return mp.get_property_native('pause')
	end, false)
end)
