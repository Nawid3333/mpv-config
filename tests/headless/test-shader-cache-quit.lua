-- shader-cache (3/10): a different display driver means a full warm-up in the
-- background. Quitting the player while it runs must end it: the runner checks
-- right after this phase that no host.ps1 or warm-up mpv is left, and phase 4
-- that no failure was recorded. The runner points this warm-up at a missing
-- script, so it idles until killed - a warm-up that would run for minutes,
-- without a race against a fast one finishing first.
-- Leaves a stamp that differs only in the shaders and the mpv version, for
-- phase 4.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	R.wait_playing(H)
	H.wait_until(function()
		return R.saw('warming')
	end, 10)
	H.eq('driver changed: reason', R.info.reasons, 'driver')
	H.eq('driver changed: full warm-up', R.info.mode, 'full')
	H.eq('the warm-up runs while the video plays', R.info.state, 'warming')
	H.check('its lock is taken', R.exists('shader-warmup.lock'))
	-- lets the host start its mpv, so the quit has a running warm-up to end
	H.sleep(2)
	H.eq('still running when the player quits', R.info.state, 'warming')
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	R.write_stamp({ config = '00000000', mpv = 'v0.0.0-test' })
	-- H.run returning quits the player mid warm-up
end)
