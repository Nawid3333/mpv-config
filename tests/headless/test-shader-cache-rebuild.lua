-- shader-cache (8/10): the menu's "Rebuild shaders". The start finds the
-- fingerprint that failed before (phases 6/7), so nothing runs by itself; the
-- rebuild runs anyway: it deletes mpv's own compiled shaders (a faked one
-- stands in - a --vo=null player compiles nothing), clears the failure and
-- warms everything while the video plays on. Leaves a stamp with another
-- display driver for phase 9.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	R.wait_playing(H)
	H.eq('failed before: nothing runs by itself', R.info.state, 'failed-before')
	local fake = R.fake_object()
	-- as the menu entries send it (input.conf, gpu-toggles' upscale menu)
	mp.commandv('script-message-to', 'shader_cache', 'rebuild')
	H.wait_until(function()
		return R.saw('warming')
	end, 5)
	H.check("rebuild deleted mpv's compiled shaders", not R.exists(fake))
	H.check('rebuild cleared the recorded failure', not R.exists('shader-warmup.failed'))
	H.eq('rebuild: reason', R.info.reasons, 'manual')
	R.wait_end(H)
	H.eq('rebuild finished', R.info.state, 'done', R.info.summary)
	H.check('a rebuild is a full warm-up', (R.info.summary or ''):find('over 12 steps', 1, true) ~= nil, R.info.summary)
	H.eq('stamp: driver = the current one', (R.read_stamp() or {}).driver, (R.info.fingerprint or {}).driver)
	H.eq('the video kept playing', mp.get_property_native('pause'), false)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
	-- phase 9 (idle): a new driver, for the warm-up it starts with no file
	R.write_stamp({ driver = '0.0.0.0-idle' })
end)
