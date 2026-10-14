-- pause-flash.lua: each step into pause flashes uosc's UI (flash-ui) - by
-- key, by a click on the video, by the stop at a file's end - and nothing else
-- does: resuming, a paused player loading the next file (auto-start.lua plays
-- it).
-- What uosc then draws needs a real window (tests/README.md, not covered);
-- this checks the flash is sent and reaches uosc.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function flashes()
	return (mp.get_property_native('user-data/pause-flash') or {}).flashes or 0
end

local function reached()
	return (mp.get_property_native('user-data/pause-flash') or {}).ok
end

H.run(function()
	H.sleep(0.5)
	H.eq('a file starting to play flashes nothing', flashes(), 0)

	mp.set_property_native('pause', true)
	H.expect('pause: the UI flashes', flashes, 1)
	H.eq('... through uosc (flash-ui reached it)', reached(), true)

	mp.set_property_native('pause', false)
	H.sleep(0.5)
	H.eq('resuming flashes nothing', flashes(), 1)

	H.key('SPACE')
	H.expect('Space pauses: flashes', flashes, 2)
	H.key('SPACE')
	H.sleep(0.5)
	H.eq('... Space again resumes: no flash', flashes(), 2)

	H.click(200, 100)
	H.expect('a click on the video pauses: flashes', flashes, 3)
	H.eq('... paused', mp.get_property_native('pause'), true)

	-- the paused player loads the next file, which auto-start.lua plays
	H.load(H.media_path('second/clip2.mkv'))
	H.sleep(0.5)
	H.eq('the next file plays', mp.get_property_native('pause'), false)
	H.eq('... and its load flashed nothing', flashes(), 3)

	-- keep-open=yes pauses at the end of a file
	local duration = mp.get_property_number('duration')
	mp.commandv('seek', tostring(duration - 0.5), 'absolute', 'exact')
	H.check(
		'file plays out to its end',
		H.wait_until(function()
			return mp.get_property_native('eof-reached') == true
		end, 10)
	)
	H.expect('the stop at the end flashes too', flashes, 4)
end)
