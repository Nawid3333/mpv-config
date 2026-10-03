-- shader-cache (5/11): fewer cache files than the stamp recorded -> full
-- warm-up, which is ended from outside (the runner swaps in a warm-up that
-- exits 1, like taskkill /F). That is not the warm-up's own failure: nothing
-- is recorded as failed, the stamp stays stale so the next start retries, and
-- the count of interruptions for this fingerprint is kept (3 in a row = failed).
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	R.wait_playing(H)
	R.wait_end(H, 15)
	H.eq('cache files missing: reason', R.info.reasons, 'files')
	H.eq('a warm-up killed from outside is "interrupted"', R.info.state, 'interrupted')
	H.check('it is not recorded as failed', not R.exists('shader-warmup.failed'))
	local f = io.open(R.path('shader-warmup.interrupted'), 'r')
	local text = f and f:read('*a') or ''
	if f then
		f:close()
	end
	H.check('the interruption is counted (times=1)', text:find('times=1', 1, true) ~= nil, text)
	H.eq('stamp untouched, so the next start retries', (R.read_stamp() or {}).files, '999999')
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
end)
