-- remember-speed.lua, process 1 of 2: choose a speed, then quit. The runner
-- starts a FRESH mpv for test-remember-speed-restore.lua, which asserts the
-- speed came back (AGENTS.md validation item 6a: an in-process check cannot
-- tell "restored" from "still set in this process").
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.eq('fresh state starts at 1x', mp.get_property_number('speed'), 1, 0.001)
	H.key('b') -- the 2.5x preset
	H.expect('b sets 2.5x', function()
		return mp.get_property_number('speed')
	end, 2.5, 0.001)
	H.sleep(0.3)
	local f = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json', 'r')
	local content = f and f:read('*a') or ''
	if f then
		f:close()
	end
	H.check('speed.json written with 2.5', content:find('2.5', 1, true) ~= nil, content)
end)
