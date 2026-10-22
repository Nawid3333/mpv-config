-- bottom-bar.lua: while uosc's bottom bar shows, subtitles rise above it - in
-- one step, not with each step of its fade (every new value empties libass's
-- caches, see bottom-bar.lua's header) - and come back down once it is gone:
-- text subtitles through sub-margin-y-offset, ASS subtitles through sub-pos on
-- top of the user's own position, which a step made while lifted moves and the
-- bar's hiding returns to. The scrim needs a real
-- OSD surface (its pixels are on the 2026-10-02 PR's screenshots); headless
-- only the lift is reachable.
--
-- The bar is user-data/uosc/bottom-ui, which uosc publishes - a headless uosc
-- has no OSD size and publishes nothing, so this test sets it (the shape uosc
-- publishes, a 720-line window: controls from y 620, timeline from 672).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function bar(visibility)
	mp.set_property_native('user-data/uosc/bottom-ui', {
		visibility = visibility,
		controls_top = 620,
		timeline_top = 672,
		height = 720,
	})
end

local function offset()
	return mp.get_property_number('sub-margin-y-offset')
end

local function pos()
	return mp.get_property_number('sub-pos')
end

local function state(name)
	return function()
		return (mp.get_property_native('user-data/bottom-bar') or {})[name]
	end
end

local function codec()
	local t = mp.get_property_native('current-tracks/sub')
	return t and t.codec
end

H.run(function()
	local later = mp.get_property_native('watch-later-options') or {}
	local stored = false
	for _, name in ipairs(later) do
		stored = stored or name == 'sub-pos'
	end
	H.check('watch-later never stores sub-pos (a lifted value would stick to the file)', not stored)

	-- the .srt next to the clip (sub-auto): a text subtitle
	H.expect('a text subtitle is selected', codec, 'subrip')
	bar(0)
	H.expect('bar hidden: subtitles where they are', offset, 0)
	-- bottom of a text subtitle = sub-margin-y (34) above the window's bottom;
	-- it must end 10 above the controls: (720 - (620 - 10)) - 34 = 76
	bar(1)
	H.expect('bar shown: text subtitles rise above it (sub-margin-y-offset)', offset, 76)
	H.eq('... through the margin, the option meant for it', state('mode')(), 'margin')
	H.eq('... sub-pos untouched', pos(), 100)
	-- the user's own sub-pos moves text subtitles by % of the window (720 lines here,
	-- measured on rendered frames): the lift starts from there, so the line still ends
	-- 10 above the controls - it rose by the full 76 whatever sub-pos said
	mp.set_property_number('sub-pos', 90)
	H.expect('sub-pos 90 (72 higher): only the rest is lifted, 4', offset, 4)
	mp.set_property_number('sub-pos', 110)
	H.expect('sub-pos 110 (72 lower): 148', offset, 148)
	mp.set_property_number('sub-pos', 80)
	H.expect('sub-pos 80 (above the bar already): not lifted', offset, 0)
	mp.set_property_number('sub-pos', 100)
	H.expect('sub-pos 100 again: 76', offset, 76)
	bar(0)
	H.expect('bar hidden: back down', offset, 0)
	-- from hidden, so the value read cannot be the one left by the step before
	bar(0.5)
	H.expect('half faded in: already all the way up (one step)', offset, 76)
	bar(0)
	H.expect('bar hidden again: back down', offset, 0)
	-- a whole fade in and out, as uosc publishes it (a value per frame): two
	-- changes of the subtitle option, not one per step
	local changes = 0
	local function count()
		changes = changes + 1
	end
	mp.observe_property('sub-margin-y-offset', 'number', count)
	H.sleep(0.1)
	changes = 0 -- the observer's first call reports the current value
	for _, v in ipairs({ 0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1, 0.85, 0.7, 0.55, 0.4, 0.25, 0.1, 0 }) do
		bar(v)
		H.sleep(0.05)
	end
	H.sleep(0.2)
	mp.unobserve_property(count)
	H.eq('a full fade in and out: the subtitle option changed twice (up, down)', changes, 2)
	mp.set_property_bool('sub-visibility', false)
	bar(1)
	H.expect('subtitles hidden: nothing to lift', state('mode'), nil)
	H.eq('... no margin offset', offset(), 0)
	mp.set_property_bool('sub-visibility', true)
	H.expect('shown again: lifted at once', offset, 76)
	bar(0)
	H.expect('... and down with the bar', offset, 0)

	-- an ASS track: its own margins ignore sub-margin-y-offset, so sub-pos
	-- carries the lift. Its bottom is assumed 2 % of the frame above the
	-- video's edge: (720 - 14.4) - 610 = 95.6 px = 13.28 % of 720.
	local dir = mp.get_property('path'):match('^(.*[/\\])') or ''
	local ass = dir .. 'bottom-bar-test.ass'
	local f = io.open(ass, 'w')
	H.check('could write an ASS file next to the clip', f ~= nil, ass)
	if not f then
		return
	end
	f:write(
		'[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n\n[V4+ Styles]\n'
			.. 'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, '
			.. 'Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n'
			.. 'Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\n\n'
			.. '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
			.. 'Dialogue: 0,0:00:00.00,0:00:19.00,Default,,0,0,0,,an ASS line\n'
	)
	f:close()
	mp.commandv('sub-add', ass, 'select')
	H.expect('an ASS subtitle is selected', codec, 'ass')
	bar(1)
	H.expect('ASS: lifted through sub-pos', pos, 100 - 95.6 / 720 * 100, 0.05)
	H.eq('... in pos mode', state('mode')(), 'pos')
	H.eq('... the margin offset is not used for it', offset(), 0)
	-- the user moves the subtitles up while they are lifted: that is one step
	-- from the user's OWN position, which the fade then returns to; the lifted
	-- line stays just above the bar (sub-pos moves ASS by % of the video)
	mp.commandv('add', 'sub-pos', '-1')
	H.expect("a step while lifted: the user's position is 99", state('sub_pos'), 99, 0.001)
	H.expect('... the line stays just above the bar', pos, 100 - 95.6 / 720 * 100, 0.05)
	bar(0)
	H.expect("bar hidden: back at the user's own position", pos, 99, 0.001)
	-- lifted from where the user's sub-pos puts the line: 90 (72 higher) and 110 end
	-- at the same place above the bar, 80 is above it already
	for _, user in ipairs({ 90, 110 }) do
		mp.set_property_number('sub-pos', user)
		H.expect('user sub-pos ' .. user .. ': hidden bar, there', pos, user, 0.001)
		bar(1)
		H.expect('... shown: just above the bar, as from 100', pos, 100 - 95.6 / 720 * 100, 0.05)
		bar(0)
		H.expect('... hidden: back at ' .. user, pos, user, 0.001)
	end
	mp.set_property_number('sub-pos', 80)
	bar(1)
	H.sleep(0.3)
	H.eq('user sub-pos 80, above the bar already: not lifted', pos(), 80, 0.001)
	bar(0)
	mp.set_property_number('sub-pos', 100)
	os.remove(ass)

	-- the sync tool's panel sits where the controls are: subtitles stay above
	-- it while it is open, whether uosc's bar shows or not
	mp.set_property_native(
		'user-data/subtitle-sync',
		{ open = true, panel = { x0 = 14, y0 = 500, x1 = 1266, y1 = 612 } }
	)
	H.expect('sync panel open: lifted above the panel', pos, 100 - (705.6 - 490) / 720 * 100, 0.05)
	mp.set_property_native('user-data/subtitle-sync', { open = false })
	H.expect('sync panel closed: back down', pos, 100, 0.001)
end)
