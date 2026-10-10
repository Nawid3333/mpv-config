-- notify.lua: the small banners that every message uses. A banner shows,
-- stacks under the one before, is replaced in place by its id, hides on
-- request or after its time; mpv's own OSD text is styled like one and moved
-- under the stack (osd-margin-y-offset, the two sides' heights added). Then
-- each script's message arrives as a banner, not as mpv OSD text: speed keys
-- (a preset, s/d, on the LEFT since 2026-09-28), the subtitle key, the shader
-- keys, the sharpness menu. Whether a banner is actually PAINTED needs a real
-- OSD surface: test-notify-render.lua (--vo=sixel, reads the pixels).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function cards()
	return (mp.get_property_native('user-data/notify') or {}).cards or {}
end

-- video-info.lua draws a banner for the video this test's phases open (a
-- feature tested in test-video-info.lua); it is filtered out here, so this
-- test's ids() and invariants see only the banners it causes.
local function own(cards_list)
	local list = {}
	for _, c in ipairs(cards_list) do
		if c.id ~= 'video-info' then
			list[#list + 1] = c
		end
	end
	return list
end

local function card(id)
	for _, c in ipairs(own(cards())) do
		if c.id == id then
			return c
		end
	end
end

local function field(id, name)
	return function()
		local c = card(id)
		return c and c[name]
	end
end

local function ids()
	local list = {}
	for _, c in ipairs(own(cards())) do
		list[#list + 1] = c.id
	end
	return table.concat(list, ',')
end

-- The height mpv's OSD text is pushed down by: both stacks' heights. The
-- video-info banner standing for the phase's file (title + detail = round(40
-- x 1.35) + gap round(6 x 1.35) = 54 + 8, on the right) is part of that; the
-- checks below subtract it, so they see only what this test causes. 1.35 is
-- notify_size-size, the banners' size knob (2026-09-29).
local SIZE = 1.35
local VIDEO_INFO_HEIGHT = math.floor(40 * SIZE + 0.5) + math.floor(6 * SIZE + 0.5)

local function offset()
	local standing = 0
	for _, c in ipairs(cards()) do
		if c.id == 'video-info' and not c.left then
			standing = VIDEO_INFO_HEIGHT
		end
	end
	return mp.get_property_number('osd-margin-y-offset', 0) - standing
end

local function show(...)
	mp.commandv('script-message-to', 'notify', 'show', ...)
end

local function hide(id)
	mp.commandv('script-message-to', 'notify', 'hide', id)
end

H.run(function()
	-- mpv's own OSD text: the banners' box, top right, the title's size
	H.eq('mpv OSD text has a background box', mp.get_property('osd-border-style'), 'background-box')
	H.eq(
		'mpv OSD text sits top right',
		mp.get_property('osd-align-x') .. ' ' .. mp.get_property('osd-align-y'),
		'right top'
	)
	H.eq('mpv OSD text has the banner title size (14 x 1.19, Segoe UI)', mp.get_property_number('osd-font-size'), 17)
	H.eq('mpv OSD text box is solid black like the banners', mp.get_property('osd-back-color'), '#FF000000')
	H.eq('nothing shown: mpv OSD text at its normal place', offset(), 0)

	show('t1', 'First', '', '0')
	H.expect('a banner shows', field('t1', 'title'), 'First')
	H.eq('the size knob is applied (published for tests)', mp.get_property_native('user-data/notify').size, 1.35)
	H.expect('mpv OSD text moves under it (title-only round(28x1.35) + round(6x1.35))', offset, 46)
	-- What only a real OSD surface reaches - the banners painted, the OSD font
	-- rewrite, the 2026-09-29 crash in it - is test-notify-render.lua's job:
	-- under --vo=null draw() stops before that code.
	show('t2', 'Second', 'detail line', '0')
	H.expect('a second banner stacks under the first', ids, 't1,t2')
	H.eq('its detail line is kept', field('t2', 'detail')(), 'detail line')
	H.expect('mpv OSD text moves under both (46 + 62)', offset, 108)
	show('t1', 'First again', '', '0')
	H.expect('the same id replaces the banner', field('t1', 'title'), 'First again')
	H.eq('... where it stood', ids(), 't1,t2')
	show('t3', 'Progress', 'half way', '0', '0.5')
	H.expect('a banner with a progress line', field('t3', 'progress'), 0.5, 0.001)
	hide('t1')
	H.expect('hide removes one banner, the rest move up', ids, 't2,t3')
	show('t4', 'Short', '', '0.4')
	H.expect('a timed banner shows', field('t4', 'title'), 'Short')
	H.expect('... and goes by itself', function()
		return card('t4') == nil
	end, true, nil, 2)
	hide('t2')
	hide('t3')
	H.expect('all hidden: none left', ids, '')
	H.expect('... and mpv OSD text back at its place', offset, 0)

	-- the left side: the speed banner (2026-09-28) and a side of its own
	H.key('q')
	H.expect('speed preset key: a speed banner', field('speed', 'title'), 'Speed 3x')
	H.eq('... with its revert hint', field('speed', 'detail')(), 'same key again: back to 1x')
	H.eq('... on the LEFT side', field('speed', 'left')(), true)
	H.expect('... the OSD offset does not count it (right stack only)', offset, 0)
	H.key('d')
	H.expect('d: the same banner shows the new speed', field('speed', 'title'), 'Speed 3.1x')
	H.key('s')
	H.expect('s: likewise', field('speed', 'title'), 'Speed 3x')
	H.eq('one speed banner, not three', select(2, ids():gsub('speed', '')), 1)
	mp.set_property_number('speed', 1)
	show('t5', 'Lefty', 'on the left too', '0', '', 'left')
	H.expect('a second left-side banner stacks under the speed one', field('t5', 'title'), 'Lefty')
	H.eq(
		'... both on the left',
		tostring(field('speed', 'left')()) .. ',' .. tostring(field('t5', 'left')()),
		'true,true'
	)
	show('t6', 'Righty', '', '0')
	H.expect('a right-side banner after a left one', field('t6', 'title'), 'Righty')
	H.expect('... the OSD text moves under the right stack', offset, 46)
	hide('speed')
	hide('t5')
	hide('t6')
	H.expect('left and right cleared', ids, '')
	H.key('r')
	H.expect('r at 1x (nothing to go back to): the banner still says the speed', field('speed', 'title'), 'Speed 1x')
	hide('speed')
	H.expect('... mpv OSD text back at its place', offset, 0)

	-- every script's message is a banner
	H.key('c')
	H.expect('c on a file without subtitles: a banner', field('subtitles', 'title'), 'No subtitles')

	H.key('Shift+A')
	H.expect('Shift+A: an upscale banner', field('shaders', 'title'), 'Upscale: Anime')
	H.eq('... naming the chain', field('shaders', 'detail')(), 'Anime4K C+A (HQ)')
	H.key('Shift+A')
	H.expect('Shift+A again: upscale off', field('shaders', 'title'), 'Upscale: off')
	mp.commandv('script-message-to', 'gpu_toggles', 'set-movie-sharpness', '1')
	H.expect('the sharpness menu: a banner', field('shaders', 'title'), 'Movie sharpness: Medium')
	H.eq('... saying when it applies', field('shaders', 'detail')(), 'used when Movie is on')

	-- A long detail wraps instead of being cut at the card's edge (review,
	-- 2026-10-09: "Upscaling off here" lost its "Settings > ..." part).
	local long = 'Anime4K C+A (Fast) took 76.6 ms per frame on this GPU (21 fit) · '
		.. 'Settings > Upscaling quality runs it anyway'
	show('wrap-test', 'Upscaling off here', long, '0')
	H.wait_until(function()
		return card('wrap-test') ~= nil
	end, 2)
	local lines = field('wrap-test', 'lines')() or {}
	H.check('a long detail wraps onto 2-3 lines', #lines >= 2 and #lines <= 3, tostring(#lines))
	H.eq('... every word kept, in order', table.concat(lines, ' '), long)
	local before = offset()
	show('wrap-short', 'Short', 'one line', '0')
	H.wait_until(function()
		return card('wrap-short') ~= nil
	end, 2)
	H.eq('a short detail stays on one line', #(field('wrap-short', 'lines')() or {}), 1)
	hide('wrap-short')
	hide('wrap-test')
	H.check('the stack grew by the wrapped card (offset)', before > 0, tostring(before))
end)
