-- Each seek key shows uosc's timeline for 2.5 s (input.conf: `script-message-to uosc
-- flash-elements timeline 2500`; a local uosc change gives the flash its own duration),
-- so a skip shows where in the file it landed. uosc.conf's flash_duration (1 s) stays
-- the volume's and the pause's. The timeline's visibility is uosc's
-- user-data/uosc/bottom-ui, which uosc publishes only with an OSD surface: the runner
-- gives this test --vo=sixel (no window, no GPU), like ui-hover.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function visibility()
	local bottom = mp.get_property_native('user-data/uosc/bottom-ui')
	return bottom and bottom.visibility
end

H.run(function()
	if
		not H.check(
			'uosc lays out its bottom bar (user-data/uosc/bottom-ui)',
			H.wait_until(function()
				return visibility() ~= nil
			end, 5),
			'no bottom-ui published: no OSD surface (the runner passes --vo=sixel)'
		)
	then
		return
	end
	H.eq('the UI is hidden while nobody touches the mouse', visibility(), 0)

	H.key('k')
	H.expect('k (10 s on) shows the timeline', visibility, 1)
	H.check('... and seeks', (mp.get_property_number('time-pos') or 0) >= 9, mp.get_property('time-pos'))
	H.sleep(1.6)
	H.eq('... still there after 1.6 s (flash_duration alone is 1 s)', visibility(), 1)
	H.expect('... and gone by itself', visibility, 0, nil, 3)

	-- the arrow keys and the percent keys too (the static tier checks every seek key)
	for _, key in ipairs({ 'LEFT', '5' }) do
		H.key(key)
		H.expect(key .. ' shows the timeline', visibility, 1)
		H.expect('... and it goes by itself', visibility, 0, nil, 4)
	end

	H.key('UP')
	H.sleep(0.5)
	H.eq('a volume key shows no timeline (its own flash is the volume bar)', visibility(), 0)
end)
