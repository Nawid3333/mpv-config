-- shader-cache (11/11): two warm-ups in one session. A warm-up's timeout timer
-- used to look at whatever job was running when it fired: a "Rebuild shaders"
-- within opts.timeout of an earlier warm-up was aborted by that one's timer as
-- a "timeout" (2026-10-02), after it had already deleted the compiled shaders.
-- Here: timeout 10 s, a stand-in warm-up that ends itself after 6 s, and two
-- rebuilds one after the other - the first one's timer fires during the second.
-- A run's time also holds Windows PowerShell's and mpv's start (host.ps1), so
-- the gap between the two numbers is the start-up time a run may take: it was
-- 2.5 s / 4 s until 2026-10-04, and a CI runner went past the 1.5 s that left.
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
	-- (3.92 s was seen under load for the old 2.5 s stand-in), and a run that
	-- reached its own 10 s timer would end as 'timeout', which the state checks
	-- catch. The old bug cut the second run off when the first one's timer
	-- fired, 10 s after the first started: at most 4 s into the second, less
	-- the first one's start-up time - below the 5 s checked here.
	H.check('after its 6 s', first_s >= 5, first_s)
	local second, second_s = rebuild_and_wait()
	H.eq("the second is not aborted by the first one's timer", second, 'interrupted')
	H.check('it ran its own 6 s', second_s >= 5, second_s)
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
end)
