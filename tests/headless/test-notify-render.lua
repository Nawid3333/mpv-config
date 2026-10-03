-- notify.lua on a REAL OSD surface: the banners are actually painted.
--
-- Why (2026-09-29): draw() reached code that runs only once the OSD has a real
-- size (set_osd_scale) and crashed there - "bad argument #2 (number expected,
-- got boolean)". A Lua error ends the whole script, so from the first draw on
-- no banner was ever painted again, and test-notify.lua stayed green: under
-- --vo=null osd-dimensions is 0x0 and draw() returns before that code.
--
-- run-tests.ps1 runs this one under --vo=sixel: terminal graphics written to
-- stdout, no window, no GPU - measured the same day, sixel and kitty are the
-- VOs in this build that give a real OSD size headless (null and tct report
-- 0x0, image draws subtitles only; kitty writes ~50x more than sixel). The
-- checks read PIXELS: a software screenshot with the OSD (screenshot-raw
-- window) must show each banner's black box and white text exactly where
-- notify.lua says it drew it (the card's `box`, published only after
-- canvas:update()). The clip is a solid 960x540 colour, paused: the
-- screenshot comes out at the video's size and the runner sizes sixel's
-- canvas to match, so a box pixel is a screenshot pixel; a still, undithered
-- frame keeps sixel's output small.
local utils = require('mp.utils')
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function cards()
	return (mp.get_property_native('user-data/notify') or {}).cards or {}
end

local function card(id)
	for _, c in ipairs(cards()) do
		if c.id == id then
			return c
		end
	end
end

local function drawn(id)
	return function()
		local c = card(id)
		return c ~= nil and c.box ~= nil
	end
end

local function show(...)
	mp.commandv('script-message-to', 'notify', 'show', ...)
end

local function hide(id)
	mp.commandv('script-message-to', 'notify', 'hide', id)
end

local function osd_size()
	local d = mp.get_property_native('osd-dimensions') or {}
	return d.w or 0, d.h or 0
end

-- What the window shows (video + OSD), rendered in software as RGBA bytes,
-- with the factor from OSD pixels (the box) to screenshot pixels.
local function shot()
	local r = mp.command_native({ 'screenshot-raw', 'window', 'rgba' })
	if type(r) ~= 'table' or not r.data then
		return nil
	end
	local w, h = osd_size()
	r.sx, r.sy = r.w / w, r.h / h
	return r
end

-- R, G, B at OSD pixel (x, y)
local function pixel(s, x, y)
	local i = math.floor(y * s.sy) * s.stride + math.floor(x * s.sx) * 4 + 1
	return s.data:byte(i, i + 2)
end

-- The four corners of a box, 3 px inside: the box's own padding, never text.
local function corners(b)
	return {
		{ b.x + 3, b.y + 3 },
		{ b.x + b.w - 4, b.y + 3 },
		{ b.x + 3, b.y + b.h - 4 },
		{ b.x + b.w - 4, b.y + b.h - 4 },
	}
end

-- 'ok' when every corner is solid black (the box is there), else the first
-- corner that is not, with its colour.
local function box_black(s, b)
	for _, p in ipairs(corners(b)) do
		local r, g, bl = pixel(s, p[1], p[2])
		if math.max(r, g, bl) > 10 then
			return string.format('(%d,%d) is %d,%d,%d', p[1], p[2], r, g, bl)
		end
	end
	return 'ok'
end

-- White text pixels inside a box (the title is white on black).
local function white_pixels(s, b)
	local n = 0
	for y = b.y, b.y + b.h - 1 do
		for x = b.x, b.x + b.w - 1 do
			local r, g, bl = pixel(s, x, y)
			if math.min(r, g, bl) >= 200 then
				n = n + 1
			end
		end
	end
	return n
end

-- The box is painted: black corners and a legible (white) title inside.
local function check_painted(name, id)
	local c = card(id)
	local s = shot()
	if not H.check(name .. ': drawn (box published)', c and c.box, 'no box for ' .. id) then
		return
	end
	if not H.check(name .. ': screenshot-raw window works', s, 'no screenshot') then
		return
	end
	local w, h = osd_size()
	local b = c.box
	H.check(
		name .. ': inside the window',
		b.x >= 0 and b.y >= 0 and b.x + b.w <= w and b.y + b.h <= h and b.w > 20 and b.h > 20,
		string.format('box %d,%d %dx%d on %dx%d', b.x, b.y, b.w, b.h, w, h)
	)
	H.eq(name .. ': its black box is on screen', box_black(s, b), 'ok')
	local white = white_pixels(s, b)
	H.check(name .. ': its title is on screen (white text)', white >= 30, white .. ' white pixels')
	return b
end

H.run(function()
	mp.set_property_native('pause', true)
	-- video-info.lua's banner for this clip would move ours; the test owns the stack
	hide('video-info')
	H.expect('no banner to begin with', function()
		return #cards()
	end, 0)

	local w, h = osd_size()
	if
		not H.check(
			'the VO gives a real OSD surface (the path --vo=null never reaches)',
			w > 0 and h > 0,
			w .. 'x' .. h
		)
	then
		return
	end
	-- set_osd_scale() ran (it is where the 2026-09-29 crash was): mpv's own OSD
	-- text is sized for this surface, the window scaling switched off
	H.expect('mpv OSD text: window scaling off', function()
		return mp.get_property('osd-scale-by-window')
	end, 'no')
	-- with the window scaling off these options are REAL pixels: the banners'
	-- own px() values (design x uosc scale x size knob). Until 2026-10-02 the
	-- font was still divided by h/720 - 2/3 of the banner title at 1080p.
	local scale = mp.get_property_number('user-data/uosc/ui-scale') or h / 720
	local size = (mp.get_property_native('user-data/notify') or {}).size or 1
	local function px(v)
		return math.floor(v * scale * size + 0.5)
	end
	H.expect('mpv OSD text: font = the banner title (14 x 1.19 for Segoe UI)', function()
		return mp.get_property_number('osd-font-size')
	end, px(14 * 1.19))
	H.eq('mpv OSD text: box padding scaled like the banners', mp.get_property_number('osd-shadow-offset'), px(7))
	H.eq(
		"mpv OSD text: right margin = the banners' right edge",
		mp.get_property_number('osd-margin-x'),
		px(14) + px(7) + 1
	)
	H.eq("mpv OSD text: top margin = the banners' top", mp.get_property_number('osd-margin-y'), px(46) + px(7))

	local before = shot()
	if before then
		H.info(string.format('OSD %dx%d, screenshot %dx%d', w, h, before.w, before.h))
	end
	show('render-1', 'Banner render test', 'second line', '0')
	H.expect('a banner is drawn', drawn('render-1'), true, nil, 3)
	local b1 = check_painted('first banner', 'render-1')

	-- the one the crash took: every banner AFTER the first draw
	show('render-2', 'Second banner', '', '0')
	H.expect('a second banner is drawn', drawn('render-2'), true, nil, 3)
	local b2 = check_painted('second banner', 'render-2')
	if b1 and b2 then
		H.check('... under the first', b2.y >= b1.y + b1.h, string.format('y %d vs %d+%d', b2.y, b1.y, b1.h))
	end

	-- a real script's banner, on the left stack
	H.key('q')
	H.expect('speed key: its banner is drawn', drawn('speed'), true, nil, 3)
	local bs = check_painted('speed banner', 'speed')
	if bs then
		H.check('... on the left', bs.x + bs.w < w / 2, string.format('x %d, w %d', bs.x, bs.w))
		-- its icon (the speed button's) in the accent colour #4CC2FF, drawn
		-- from uosc's icon font: a wrong font name draws the icon's NAME as
		-- accent text, which reaches past the icon's column (padding + icon,
		-- under 0.9 x the banner's height) into the title
		local s = shot()
		local column = bs.x + math.floor(bs.h * 0.9)
		local inside, outside = 0, 0
		if s then
			for y = bs.y, bs.y + bs.h - 1 do
				for x = bs.x, bs.x + bs.w - 1 do
					local r, g, bl = pixel(s, x, y)
					if bl >= 200 and g >= 150 and g <= 230 and r <= 140 then
						if x <= column then
							inside = inside + 1
						else
							outside = outside + 1
						end
					end
				end
			end
		end
		H.check('... with its icon, in the accent colour', inside >= 15, inside .. ' accent pixels')
		-- CI checks the repo out WITHOUT Git LFS (no LFS quota spent), so
		-- fonts/uosc_icons.otf is a ~130-byte pointer there and no icon font
		-- exists at all (uosc's own buttons have none either): the name is
		-- drawn as text whatever notify.lua does. Real font only.
		local font = utils.file_info(mp.command_native({ 'expand-path', '~~/fonts/uosc_icons.otf' }))
		if font and font.size > 10000 then
			H.check(
				'... a glyph in its own column, not its name as text',
				outside == 0,
				outside .. ' accent pixels right of it'
			)
		else
			H.info(
				'icon glyph check skipped: fonts/uosc_icons.otf is a Git LFS pointer in this checkout (no icon font)'
			)
		end
	end
	mp.set_property_number('speed', 1)

	hide('render-1')
	hide('render-2')
	hide('speed')
	H.expect('all hidden', function()
		return #cards()
	end, 0)
	H.sleep(0.2)
	local after = shot()
	if b1 and before and after then
		local r0, g0, bl0 = pixel(before, b1.x + 3, b1.y + 3)
		local r1, g1, bl1 = pixel(after, b1.x + 3, b1.y + 3)
		H.check(
			'hidden: the video shows where the banner was',
			math.max(r1, g1, bl1) > 10 and math.abs(r1 - r0) + math.abs(g1 - g0) + math.abs(bl1 - bl0) <= 12,
			string.format('before %d,%d,%d, after %d,%d,%d', r0, g0, bl0, r1, g1, bl1)
		)
	end
end)
