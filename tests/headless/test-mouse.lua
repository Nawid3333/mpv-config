-- Left-click on the video = play/pause, double-click = fullscreen.
-- Regression for 2026-09-26: with mpv's default window-dragging=yes, a press
-- that moved >= 3 px (--input-dragging-deadzone) before release became a
-- window drag and the click was dropped, in fullscreen too. mpv.conf sets
-- window-dragging=no; every click must now toggle, however much it wobbles.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.eq('window-dragging is off (mpv.conf)', mp.get_property('window-dragging'), 'no')

	for _, jitter in ipairs({ 0, 1, 3, 6, 15, 40 }) do
		local before = mp.get_property_native('pause')
		H.click(200, 100, jitter)
		H.check(
			string.format('click with %d px movement toggles pause', jitter),
			mp.get_property_native('pause') ~= before,
			'pause stayed ' .. tostring(before)
		)
	end

	-- Double-click: the DBL binding fires on the second press, each release
	-- still toggles pause - so fullscreen flips and pause ends where it began.
	local pause_before = mp.get_property_native('pause')
	local fs_before = mp.get_property_native('fullscreen')
	mp.commandv('mouse', '200', '100')
	mp.commandv('keydown', 'MBTN_LEFT')
	mp.commandv('keyup', 'MBTN_LEFT')
	mp.commandv('keydown', 'MBTN_LEFT')
	mp.commandv('keyup', 'MBTN_LEFT')
	H.sleep(0.4)
	H.check('double-click toggles fullscreen', mp.get_property_native('fullscreen') ~= fs_before)
	H.eq('double-click leaves pause as it was', mp.get_property_native('pause'), pause_before)
end)
