-- shader-cache (4/10): only the mpv version and shaders/presets changed -> a
-- quick check, which stops after its first clip when nothing needed
-- compiling, and updates the stamp. Also the other half of phase 3: quitting
-- mid warm-up left no failure and no control files behind. Leaves a stamp
-- claiming more cache files than exist, for phases 5 and 6.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

-- before this player's own warm-up starts
local failed_at_start = R.exists('shader-warmup.failed')

-- A quick check that compiles nothing shows no bar at all (2026-10-02: every mpv
-- update started with "Checking shaders" and "Shaders up to date").
local bar_seen = false
mp.observe_property('user-data/notify', 'native', function(_, v)
	for _, c in ipairs((v or {}).cards or {}) do
		if c.id == 'shader-cache' then
			bar_seen = true
		end
	end
end)

H.run(function()
	R.wait_playing(H)
	H.check('quitting mid warm-up (phase 3) recorded no failure', not failed_at_start)
	R.wait_end(H)
	H.eq('mpv updated, shaders changed: reasons', R.info.reasons, 'mpv+shaders')
	H.eq('mpv updated, shaders changed: only a quick check', R.info.mode, 'quick')
	H.eq('quick check finished', R.info.state, 'done', R.info.summary)
	H.check(
		'quick check stopped after the first clip (0 compiles)',
		(R.info.summary or ''):find('quick check: 0 compiles over 4 steps', 1, true) ~= nil,
		R.info.summary
	)
	H.sleep(0.5)
	H.check('a quick check that compiled nothing showed no bar', not bar_seen)
	H.eq('stamp records the current shaders', (R.read_stamp() or {}).config, (R.info.fingerprint or {}).config)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
	R.write_stamp({ files = '999999' })
end)
