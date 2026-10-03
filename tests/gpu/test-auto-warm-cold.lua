-- gpu-auto-warm (1/2): the real thing - an EMPTY shader cache, the real
-- renderer. The startup check finds no stamp, the FastStream anime file starts
-- as always, and the warm-up compiles every chain in the background (its own
-- mpv in a window that is never shown) while the video plays. Halfway through,
-- the player is paused: that must not stop the warm-up (a separate process),
-- and while both ran the video must not have dropped or delayed a frame.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

local function counters()
	return {
		dropped = mp.get_property_number('frame-drop-count', 0),
		delayed = mp.get_property_number('vo-delayed-frame-count', 0),
		mistimed = mp.get_property_number('mistimed-frame-count', 0),
	}
end

H.run(function()
	R.wait_playing(H)
	H.check('the video starts right away', R.until_playing() < 3, R.until_playing())
	H.wait_until(function()
		return R.saw('warming')
	end, 10)
	H.eq('empty cache: stale, reason "stamp"', R.info.reasons, 'stamp')
	local c0 = counters()
	-- play through the first half, then pause
	H.wait_until(function()
		local p = R.info.progress
		return R.info.state ~= 'warming' or (p and p.total > 0 and p.done * 2 >= p.total)
	end, 60)
	local c1 = counters()
	local p = R.info.progress or {}
	local paused_at = string.format('%s of %s steps', tostring(p.done), tostring(p.total))
	mp.set_property_native('pause', true)
	local still_warming = R.info.state == 'warming'
	R.wait_end(H, 120)
	H.eq('warm-up finished', R.info.state, 'done', R.info.summary)
	H.check(
		'pausing the player did not stop it (paused at ' .. paused_at .. ')',
		still_warming and R.info.state == 'done'
	)
	local n = tonumber((R.info.summary or ''):match('warmed: (%d+) compiles'))
	H.check('it compiled the chains into the empty cache', n ~= nil and n > 0, R.info.summary)
	H.eq('no dropped frames while the video played next to it', c1.dropped - c0.dropped, 0)
	H.eq('no delayed frames while the video played next to it', c1.delayed - c0.delayed, 0)
	H.info(string.format('mistimed frames meanwhile: %d', c1.mistimed - c0.mistimed))
	H.check('stamp written', R.read_stamp() ~= nil)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
	H.info(string.format('cold warm-up took %.1f s: %s', R.info.seconds or -1, R.info.summary or '?'))
end)
