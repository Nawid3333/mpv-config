-- faststream-fragment.lua: an HLS stream mpv cannot open from its address plays from the files FastStream's
-- helper (27) wrote, <temp>/faststream-mpv-hls-*/0.m3u8, its fs-* tags in target.txt beside it. Phase save
-- watches the package to 0:40 and quits; phase restore opens an ordinary file with the same fs-id, which
-- resumes there: stream-resume.lua read the fs-id of the package. A script asking once the folder went (a
-- private window's, 15 s on) still has the tags: read as the file started.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

H.run(function()
	if os.getenv('MPV_TEST_PHASE') == 'restore' then
		H.expect('the same fs-id resumes where the package was left', function()
			return math.floor((mp.get_property_number('time-pos', 0) + 2.5) / 5) * 5
		end, 40)
		return
	end
	H.check('the package starts at the beginning (no saved entry yet)', mp.get_property_number('time-pos', 99) < 2)
	local done = H.expect_event('playback-restart')
	mp.commandv('seek', '40', 'absolute', 'exact')
	done(5)
	H.sleep(0.5)
	H.eq('watched to 0:40', mp.get_property_number('time-pos'), 40, 1)
	local path = mp.get_property('path')
	H.check('its folder can go', os.remove((path:gsub('[^/\\]+$', 'target.txt'))))
	H.eq('a script asking after that still has its tags', fragment.value(path, 'fs-id='), 'b2c3d4e5f6071829')
end)
