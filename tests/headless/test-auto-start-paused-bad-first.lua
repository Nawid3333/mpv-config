-- auto-start.lua with start_paused, when the first entry fails and a good one
-- follows in the same playlist (a burst for the new window): the good one is
-- still the waiting window's first file, and stays paused.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.check(
		'the good entry loaded',
		(mp.get_property('path') or ''):find('clip.mkv', 1, true) ~= nil,
		mp.get_property('path')
	)
	H.sleep(1)
	H.eq('it waits paused', mp.get_property_native('pause'), true)
	H.check('... at its start', (mp.get_property_number('time-pos') or 0) < 0.5, mp.get_property('time-pos'))
end)
