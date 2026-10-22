-- uosc shows its UI on a mouse move and only then (uosc/lib/cursor.lua, a local
-- change): the pointer coming back over the window at the pixel where it was is
-- no move. Windows takes the pointer from the window whenever another window
-- covers it for a moment (a notification, an overlay) and gives it back with
-- the same position; mpv reports that as MOUSE_LEAVE, then MOUSE_ENTER alone
-- (w32_common.c). Upstream uosc showed the whole UI for cursor-autohide on it,
-- with the pointer still and the cursor hidden - the UI that flashed by itself
-- during a film. And the opposite: with the pointer resting ON the bar uosc never
-- hid the UI; it now goes after uosc.conf's autohide_over_controls (3 s), not
-- during a drag.
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

	-- The pointer resting ON the bar (lib/cursor.lua, uosc.conf autohide_over_controls=3000):
	-- upstream never hid the UI there, so a pointer parked on the bottom edge (the
	-- timeline) kept it up for good. Positions from uosc's own layout.
	local bottom = mp.get_property_native('user-data/uosc/bottom-ui')
	local timeline_y = math.floor((bottom.timeline_top + bottom.height) / 2)
	move(400, timeline_y)
	H.expect('the pointer on the timeline shows the UI', visibility, 1)
	H.sleep(1.8)
	H.eq('... resting there it stays past cursor-autohide (1 s): a tooltip can be read', visibility(), 1)
	H.expect('... and goes once the pointer has rested 3 s', visibility, 0, nil, 3)

	local v = bottom.volume
	if H.check('uosc reports the volume slider', type(v) == 'table', 'no volume box in bottom-ui') then
		move(math.floor((v.ax + v.bx) / 2), math.floor((v.ay + v.by) / 2))
		H.expect('the pointer on the volume slider shows the UI', visibility, 1)
		H.sleep(1.8)
		H.eq('... it stays past 1 s there too', visibility(), 1)
		H.expect('... and goes after the 3 s rest', visibility, 0, nil, 3)
	end

	-- a drag on the timeline: the left button held, the pointer still
	move(420, timeline_y)
	H.expect('back on the timeline: shown', visibility, 1)
	mp.commandv('keydown', 'MBTN_LEFT')
	H.sleep(4)
	H.eq('the left button held on the timeline for 4 s (a drag): the UI stays', visibility(), 1)
	mp.commandv('keyup', 'MBTN_LEFT')
	H.sleep(1.8)
	H.eq('... released: it stays the rest time first', visibility(), 1)
	H.expect('... then goes', visibility, 0, nil, 3)

	-- The controls and the timeline both switched off (uosc's disable-elements): bottom-ui
	-- kept the value it last had, and bottom-bar.lua drew its scrim and lifted the subtitles
	-- over a bar that was not there.
	-- another pixel: the same one is no move
	move(440, timeline_y)
	H.expect('the pointer on the timeline shows the bar again', visibility, 1)
	mp.commandv('script-message-to', 'uosc', 'disable-elements', 'test', 'controls,timeline')
	H.expect('both switched off: bottom-ui says the bar is gone', visibility, 0)
	mp.commandv('script-message-to', 'uosc', 'disable-elements', 'test', '')
end)
