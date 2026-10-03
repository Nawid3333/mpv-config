-- shader-cache (2/11): the stamp matches - no warm-up, and the check must not
-- delay the start. Also the capture: a new object in the cache folder after a
-- change (here a faked one, after switching to Anime) is logged with what was
-- on screen. Leaves a stamp with another display driver for phase 3.
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

	H.sleep(0.5) -- the capture's own start-up scan settles
	H.check('capture: nothing logged before a compile', R.info.captured == nil, R.info.captured)
	local fake = R.fake_object()
	mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', '2')
	H.wait_until(function()
		return (R.info.captured or 0) > 0
	end, 5)
	H.eq('capture: a new shader after a change is counted', R.info.captured, 1)
	local line = R.last_capture() or ''
	H.check(
		'capture: logged with what was on screen',
		line:find('  +1  ', 1, true) and line:find('| Anime |', 1, true) and line:find('[cache fresh]', 1, true),
		line
	)
	H.info(string.format('capture scan took %d ms', R.info.scan_ms or -1))
	-- the gap is LEARNED too (cases.lua): title-free cases the next full
	-- warm-up replays. The compile came right at a preset switch, so - like
	-- the log line's "(before: ...)" - both states are learned: Anime, and
	-- the one before the switch.
	H.expect('capture: the gap is learned - the state on screen and the one before the switch', function()
		return R.info.cases
	end, 2)
	local anime, before = nil, nil
	for _, c in ipairs(R.read_cases().cases or {}) do
		if c.chain == 'anime' then
			anime = c
		elseif c.chain == 'off' then
			before = c
		end
	end
	H.check('... the Anime state', anime ~= nil, R.cases_text())
	H.check('... and the state before it (no upscaler)', before ~= nil, R.cases_text())
	anime = anime or {}
	H.eq('... its size', (anime.w or 0) .. 'x' .. (anime.h or 0), '320x180')
	-- the decoder this mpv really used: 'no' on a runner without a GPU decoder,
	-- d3d11va-copy on a PC with one (mpv.conf's hwdec works under --vo=null)
	local used = mp.get_property('hwdec-current', 'no')
	H.eq('... its decoder path', anime.hwdec, used == '' and 'no' or used)
	H.check('... and no title in the file (clip.mkv)', not R.cases_text():find('clip', 1, true), R.cases_text())
	os.remove(R.path(fake))
	-- the next phases start without learned cases (phase 9 sets its own)
	R.write_cases({})

	R.write_stamp({ driver = '0.0.0.0-test' })
end)
