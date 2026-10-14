-- pause-flash.lua - pausing shows the UI for a moment
--
-- uosc shows its UI only when the mouse moves, so a pause made with the
-- pointer still (Space, a media key, the cursor hidden in fullscreen) changed
-- nothing on screen but the picture. Each step into pause now flashes the
-- whole UI - timeline, controls, volume, top bar: uosc's flash-ui - for
-- uosc.conf's flash_duration, the same time the volume and speed flashes stay
-- up; then it hides and the paused picture is left.
--
-- Only the change from playing to paused flashes, the stop at a file's end
-- (keep-open) included. A pause the player starts with or carries into the
-- next file (auto-start.lua clears it at file-loaded) is no change and shows
-- nothing. With the pointer over the window uosc's UI already shows, and its
-- flash then does nothing.
--
-- State for tests: user-data/pause-flash = {flashes (sent so far), ok (the
-- last one reached uosc)}.

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
