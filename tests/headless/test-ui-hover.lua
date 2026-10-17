-- uosc shows its UI on a mouse move and only then (uosc/lib/cursor.lua, a local
-- change): the pointer coming back over the window at the pixel where it was is
-- no move. Windows takes the pointer from the window whenever another window
-- covers it for a moment (a notification, an overlay) and gives it back with
-- the same position; mpv reports that as MOUSE_LEAVE, then MOUSE_ENTER alone
-- (w32_common.c). Upstream uosc showed the whole UI for cursor-autohide on it,
-- with the pointer still and the cursor hidden - the UI that flashed by itself
-- during a film.
--
-- keypress MOUSE_LEAVE / MOUSE_ENTER reach the same place in mpv's input layer
-- as the window's own events (input.c feed_key). The bar's visibility is uosc's
-- user-data/uosc/bottom-ui, which uosc publishes only with an OSD surface: the
-- runner gives this test --vo=sixel (no window, no GPU), like notify-render.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function visibility()
	local bottom = mp.get_property_native('user-data/uosc/bottom-ui')
	return bottom and bottom.visibility
end

local function move(x, y)
	mp.commandv('mouse', tostring(x), tostring(y))
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

	-- the pointer enters the window and moves: the UI shows
	mp.commandv('keypress', 'MOUSE_ENTER')
	move(300, 200)
	H.expect('a mouse move shows the UI', visibility, 1)
	-- mpv.conf's cursor-autohide=1000; uosc hides with the cursor
	H.expect('... and it hides with the cursor (cursor-autohide)', visibility, 0, nil, 4)

	-- another window covers the pointer for a moment, then goes
	mp.commandv('keypress', 'MOUSE_LEAVE')
	H.sleep(0.2)
	mp.commandv('keypress', 'MOUSE_ENTER')
	H.sleep(0.6)
	H.eq('the pointer back over the window where it was (nothing moved): the UI stays hidden', visibility(), 0)

	move(302, 201)
	H.expect('the next real move, 2 px, shows it', visibility, 1)

	mp.commandv('keypress', 'MOUSE_LEAVE')
	H.expect('the pointer leaving the window hides it', visibility, 0)
	mp.commandv('keypress', 'MOUSE_ENTER')
	H.sleep(0.6)
	H.eq('... and coming back at the same pixel shows nothing', visibility(), 0)

	-- the pointer really leaves and comes back somewhere else
	mp.commandv('keypress', 'MOUSE_LEAVE')
	H.sleep(0.2)
	mp.commandv('keypress', 'MOUSE_ENTER')
	move(500, 300)
	H.expect('the pointer coming back at another place shows it', visibility, 1)
	H.expect('... and it hides again with the cursor', visibility, 0, nil, 4)
	mp.commandv('keypress', 'MOUSE_LEAVE')
	H.sleep(0.2)
	mp.commandv('keypress', 'MOUSE_ENTER')
	H.sleep(0.6)
	H.eq('a second cover-and-uncover shows nothing either', visibility(), 0)
end)
