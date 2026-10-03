-- shader-cache (11/11): two warm-ups in one session. A warm-up's timeout timer
-- used to look at whatever job was running when it fired: a "Rebuild shaders"
-- within opts.timeout of an earlier warm-up was aborted by that one's timer as
-- a "timeout" (2026-10-02), after it had already deleted the compiled shaders.
-- Here: timeout 4 s, a stand-in warm-up that ends itself after 2.5 s, and two
-- rebuilds one after the other - the first one's timer fires during the second.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

local function rebuild_and_wait()
	mp.commandv('script-message-to', 'shader_cache', 'rebuild')
	H.wait_until(function()
		return R.info.state == 'warming'
	end, 5)
	H.wait_until(function()
		return R.info.state ~= 'warming'
	end, 15)
	return R.info.state, R.info.seconds or 0
end

H.run(function()
	R.wait_playing(H)
	local first, first_s = rebuild_and_wait()
	H.eq('the first warm-up ends by itself', first, 'interrupted')
	-- Durations have a floor, no ceiling: a busy PC only makes a run longer
	-- (3.92 s was seen under load), and a run that reached its own 4 s timer
	-- would end as 'timeout', which the state checks catch. The old bug cut
	-- the second run off when the first one's timer fired, about 1.5 s in.
	H.check('after its 2.5 s', first_s >= 2, first_s)
	local second, second_s = rebuild_and_wait()
	H.eq("the second is not aborted by the first one's timer", second, 'interrupted')
	H.check('it ran its own 2.5 s', second_s >= 2, second_s)
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
end)
