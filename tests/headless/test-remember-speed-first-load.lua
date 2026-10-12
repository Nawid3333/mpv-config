-- remember-speed.lua, process 3 of 3: a speed picked while the FIRST video of a
-- process loads (a key pressed during a FastStream stream's seconds of loading)
-- wins over the saved speed (2x, left by test-remember-speed-restore.lua).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

-- Registered in the main chunk: mpv opens the first file only after it ran.
local picked = false
mp.add_hook('on_load', 50, function(hook)
	if not picked then
		picked = true
		mp.set_property_number('speed', 4)
		hook:defer()
		mp.add_timeout(0.3, function()
			hook:cont()
		end)
	end
end)

H.run(function()
	H.eq(
		'a speed picked while the first video loads wins over the saved one',
		mp.get_property_number('speed'),
		4,
		0.001
	)
	H.expect('... and is saved', function()
		local file = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json', 'r')
		local text = file and file:read('*a') or ''
		if file then
			file:close()
		end
		return (require('mp.utils').parse_json(text) or {}).speed
	end, 4, 0.001)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('the next video keeps it (restored once per process)', mp.get_property_number('speed'), 4, 0.001)
end)
