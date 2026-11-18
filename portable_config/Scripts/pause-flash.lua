-- pause-flash.lua - pausing shows the UI for a moment

local mp = require('mp')

local flashes = 0
local started = false

mp.observe_property('pause', 'bool', function(_, paused)
	if not started then
		started = true -- the observer's first call reports the current value
		return
	end
	if not paused or mp.get_property_native('idle-active') then
		return
	end
	flashes = flashes + 1
	-- a failed command returns nil (AGENTS.md validation item 3): uosc not loaded
	local ok = mp.command('script-binding uosc/flash-ui') == true
	mp.set_property_native('user-data/pause-flash', { flashes = flashes, ok = ok })
end)
