-- shader-cache (1/10): a cache with no stamp (first run, or the folder was
-- cleared) is stale. The video starts as always; once it plays, a second mpv
-- runs the warm-up in the background (here headless, one tiny clip), its
-- progress feeds the bar, and it writes the stamp.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	R.wait_playing(H)
	H.check('the video starts right away', R.until_playing() < 2, R.until_playing())
	R.wait_end(H)
	local info = R.info
	H.eq('no stamp: stale, reason "stamp"', info.reasons, 'stamp')
	H.eq('no stamp: full warm-up', info.mode, 'full')
	H.check(
		'warm-up ran and finished (' .. R.seq() .. ')',
		R.saw('warming') and info.state == 'done',
		tostring(info.state) .. ': ' .. tostring(info.summary)
	)
	H.check(
		'it ran in the background, after the video started',
		R.t.playing and R.t.warming and R.t.warming >= R.t.playing,
		string.format('playing %s, warming %s', tostring(R.t.playing), tostring(R.t.warming))
	)
	H.check(
		'the video did not wait for it (playing before it ended)',
		R.t.playing and R.t.done and R.t.playing < R.t.done,
		string.format('playing %s, done %s', tostring(R.t.playing), tostring(R.t.done))
	)
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	H.check('a full warm-up plays every run', (info.summary or ''):find('over 8 steps', 1, true) ~= nil, info.summary)
	local p = info.progress or {}
	H.check(
		'progress for the bar reached the end',
		p.total == 8 and p.done == 8,
		string.format('%s/%s', p.done, p.total)
	)
	local stamp = R.read_stamp()
	H.check('the warm-up wrote the stamp', stamp ~= nil)
	stamp = stamp or {}
	H.eq('stamp: libplacebo version', stamp.libplacebo, mp.get_property('libplacebo-version'))
	H.eq('stamp: mpv version', stamp.mpv, mp.get_property('mpv-version'))
	H.eq('stamp: driver = what the check saw', stamp.driver, (info.fingerprint or {}).driver)
	-- a CI runner may have no display adapter with a DriverVersion; this PC has two
	if (stamp.driver or 'unknown') == 'unknown' and os.getenv('CI') then
		H.info('no display driver version on this CI runner - the driver part of the fingerprint is "unknown"')
	else
		H.check('display driver version read from the registry', (stamp.driver or 'unknown') ~= 'unknown', stamp.driver)
	end
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
end)
