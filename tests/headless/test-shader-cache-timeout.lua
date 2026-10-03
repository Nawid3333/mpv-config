-- shader-cache (6/11): fewer cache files than the stamp recorded (still) -> full
-- warm-up. This one never finishes (the runner points it at a missing script
-- and sets timeout=3): it is abandoned while the video plays on, and the
-- failure is recorded so the same fingerprint is not retried at every start.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	R.wait_playing(H)
	R.wait_end(H, 15)
	H.eq('cache files missing: reason', R.info.reasons, 'files')
	H.eq('a warm-up that never finishes is abandoned', R.info.state, 'timeout')
	H.check('abandoned after the timeout (3 s)', math.abs((R.info.seconds or 0) - 3) < 1.5, R.info.seconds)
	H.check('the video was already playing', R.t.playing ~= nil and R.t.playing <= (R.t.warming or 0))
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	H.check('the failure is recorded', R.exists('shader-warmup.failed'))
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
end)
