-- shader-cache (9/10): mpv opened with nothing to play (a double-click on
-- mpv.exe) and a stale cache (another display driver, from phase 8). No video
-- start to keep clear, so it warms after a moment of idle (idle_delay, 0.5 s
-- here) instead of waiting for a file.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

H.run(function()
	H.check('no file loaded', mp.get_property_native('idle-active') == true)
	R.wait_end(H)
	H.eq('driver changed: reason', R.info.reasons, 'driver')
	H.eq('it warmed with nothing loaded', R.info.state, 'done', R.info.summary)
	H.check('nothing was played', R.t.playing == nil)
	H.eq('stamp: driver = the current one', (R.read_stamp() or {}).driver, (R.info.fingerprint or {}).driver)
	H.check('lock, progress and args files cleaned up', #R.leftovers() == 0, table.concat(R.leftovers(), ', '))
end, { wait_file = false })
