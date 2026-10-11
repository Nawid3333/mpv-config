-- faststream-episodes.lua with no uosc to send its buttons to: the runner starts
-- mpv with --load-scripts=no and this one script (as before uosc has started).
-- FastStream follows the window and a FastStream stream plays, yet the flag
-- uosc.conf's disposition reads stays false: uosc would draw buttons it never
-- got as question marks (deepseek review, 2026-10-11).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	mp.set_property_native('user-data/faststream/connected', true)
	H.sleep(0.8) -- past the script's first push at 0.5 s
	local buttons = mp.get_property_native('user-data/faststream-episodes/buttons') or {}
	H.eq(
		'the script runs and would show the buttons (episode_next pushed with hide=false)',
		(buttons.episode_next or {}).hide,
		false
	)
	H.eq(
		'no uosc: user-data/faststream-episodes/shown stays false',
		mp.get_property_native('user-data/faststream-episodes/shown'),
		false
	)
end)
