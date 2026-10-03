-- gpu-auto-warm (2/2): the next start after the warm-up is fresh (no second
-- warm-up), and what the warm-up cached is what the player needs: starting
-- the anime file (Auto -> Anime) and switching to Movie and Off compiles
-- nothing.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

local compiles = 0
mp.enable_messages('debug')
mp.register_event('log-message', function(e)
	if e.prefix == 'vo/gpu-next/libplacebo' and e.text:find('shaderc compile status', 1, true) then
		compiles = compiles + 1
	end
end)

H.run(function()
	R.wait_playing(H)
	-- the check runs off the playback path, so playback can start first (it
	-- read "checking" at 598 ms once, the check still busy right after the
	-- 21 s warm-up of phase 1): its RESULT is what counts here
	H.expect('after the warm-up: fresh', function()
		return R.info.state
	end, 'fresh', nil, 5)
	H.check('no second warm-up (' .. R.seq() .. ')', not R.saw('warming'))
	H.info(
		string.format(
			'check %d ms, playback started %.0f ms after the script loaded',
			R.info.check_ms or -1,
			R.until_playing() * 1000
		)
	)
	H.sleep(1)
	for _, mode in ipairs({ '3', '0', '2' }) do
		mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', mode)
		H.sleep(1)
	end
	H.eq('Anime at start, then Movie and Off: 0 compiles', compiles, 0)
end)
