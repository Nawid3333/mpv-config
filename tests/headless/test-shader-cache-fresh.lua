-- shader-cache (2/10): the stamp matches - no warm-up, and the check must not
-- delay the start. Leaves a stamp with another display driver for phase 3.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	R.wait_playing(H)
	H.eq('stamp matches: fresh', R.info.state, 'fresh')
	H.check('no warm-up when fresh (' .. R.seq() .. ')', not R.saw('warming'))
	H.check('the check answers within 1 s', (R.info.check_ms or math.huge) < 1000, R.info.check_ms)
	H.info(
		string.format(
			'check took %d ms; playback started %.0f ms after the script loaded',
			R.info.check_ms or -1,
			R.until_playing() * 1000
		)
	)

	R.write_stamp({ driver = '0.0.0.0-test' })
end)
