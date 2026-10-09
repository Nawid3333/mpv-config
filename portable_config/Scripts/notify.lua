-- notify.lua - the small banners top right: every message this setup shows.
--
-- One look for all of them (2026-09-26, at the user's request: the resume note
-- "stays too long and is too big" - make it like the shader compiling banner,
-- and make everything else match it). Before, the shader warm-up drew its own
-- bar top right, the resume note was big centered text for 6 s, and the other
-- scripts used mp.osd_message: mpv's plain white text top left, where uosc's
-- title bar covers it. Now every script sends its message here, and this
-- script is the only one that draws them: one stack, top right, below uosc's
-- top bar and window buttons, in the shader bar's design (solid black box,
-- white title, grey detail line, a thin progress line when there is progress).
--
-- mpv's OWN OSD text (menu actions like Contrast +, screenshots, show-text from
-- vendored scripts) cannot be drawn here - no script sees it. mpv.conf gives it
-- the same look instead (osd-box: the same dark box, top right, the title's
-- size) and this script keeps it right under the stack (osd-margin-y-offset),
-- so the two never overlap.
--
-- From a script or input.conf:
--   script-message-to notify show <id> <title> [detail] [seconds] [progress] [side] [icon]
--   script-message-to notify hide <id>
-- id        a banner with the same id is replaced where it stands (five speed
--           key presses show one banner, not five)
-- detail    the grey second line; '' for none
-- seconds   how long it stays; '' = DEFAULT_SECONDS, 0 = until replaced/hidden
-- progress  0..1 draws the progress line; the banner then has a fixed width,
--           so a changing percentage does not make it jump
-- side      "left" draws it top LEFT instead of top right; '' = right. Banners
--           of the two sides stack separately (the speed banner is on the
--           left, 2026-09-28, so it sits away from the video info).
-- icon      a Material icon name from uosc's icon font (fonts/uosc_icons.otf,
--           family MaterialIconsRound-Regular, the name is a ligature); '' = the
--           icon ICONS below gives the id, '-' = none.
--
-- The card (2026-10-02, design pass: "modern and cohesive"): rounded like
-- uosc's own menus and buttons, a hairline edge so a black banner still has a
-- shape over a black letterbox, and on the left the SAME icon as the toolbar
-- button the message belongs to (the speed banner wears the speed button's
-- icon, the shader messages the upscale button's ...), in the one accent
-- colour this setup uses (ACCENT: the sync tool's drag colour, the progress
-- line). Fonts are mpv.conf's osd-font (Segoe UI), like uosc.
--
-- Size (2026-09-29, at the user's request: "banners are a bit small, make
-- them bigger"): every constant is the design unit multiplied by both the
-- interface scale and SIZE, a script-opt (default 1.35). SIZE applies to the
-- fonts, the card metrics and mpv's own OSD text alike, so everything stays
-- one design. Set size=1 in script-opts/notify_size.conf to go back.
--
-- State for tests: user-data/notify = { cards = { {id, title, detail,
-- progress, left, box}, ... } }, top to bottom, right side first; user-data/notify
-- .size = the effective SIZE (tests assert the opt is applied). box = {x, y,
-- w, h}, the rectangle in OSD pixels, is there only once the banner has been
-- DRAWN (published after canvas:update(), so an error while drawing leaves it
-- out); with no OSD surface (--vo=null) nothing is drawn and no card has one.

local mp = require('mp')
local opt = require('mp.options')
local assdraw = require('mp.assdraw')

-- Design sizes in 720-line units, the same numbers as before, multiplied at
-- draw time by the interface scale so they come out as real pixels. Before
-- 2026-09-29 the banners drew on a fixed 720-line canvas, which made them
-- SHRINK WITH THE WINDOW while uosc's own elements (real pixels x uosc's
-- scale) kept their size - at a small window the banners became too small to
-- read. Now they scale exactly with uosc's UI (state.scale = hidpi x
-- fullscreen factor, published as user-data/uosc/ui-scale by a marked local
-- change in uosc/main.lua).
local TOP = 46 -- below uosc's top bar and window buttons
local RIGHT = 14
local LEFT = 14 -- the left stack's margin (side=left)
local GAP = 6
local PAD_X = 10
local TITLE_SIZE, DETAIL_SIZE = 14, 11
-- Text sizes are multiplied by this at draw time: mpv.conf's osd-font (Segoe
-- UI) has a 1.19x taller line box than the Arial these sizes were designed
-- with, and libass sizes text by that box (uosc.conf font_scale, same value).
local FONT_SCALE = 1.19
-- text tops inside a banner; 2 units higher than the Arial-era 6/23: Segoe
-- UI's taller line box (FONT_SCALE) puts the glyphs that much lower in it
local TITLE_Y, DETAIL_Y = 4, 21
local HEIGHT_TITLE, HEIGHT_DETAIL, HEIGHT_PROGRESS = 28, 40, 44
local PROGRESS_WIDTH = 270
local MAX_WIDTH = 380
local DEFAULT_SECONDS = 2
-- Corners: uosc.conf's border_radius (6), the same rounding as uosc's menus,
-- buttons and tooltips. The progress line is a rounded bar of its own.
local RADIUS = 6
local PROGRESS_HEIGHT = 3
-- The icon column: the icon's size on a one-line / two-line card, and the
-- space between it and the text.
local ICON_SIZE, ICON_SIZE_TALL, ICON_GAP = 16, 20, 8
-- mpv's own OSD text box (mpv.conf's osd-box block): libass pads the box by
-- osd-shadow-offset on every side.
local OSD_BOX_PAD = 7
-- &HBBGGRR& colours, alpha 00 = opaque. OLED black, solid (2026-09-26, at the
-- user's request; until then 69 % opaque): mpv.conf's osd-back-color is the
-- same #FF000000, so a banner and mpv's boxed OSD text match.
local BOX, BOX_ALPHA = '000000', '00'
-- The hairline edge: white at ~10 %, like a Windows 11 flyout's stroke - on a
-- bright picture it is invisible, over a black letterbox it outlines the card.
local EDGE, EDGE_ALPHA = 'FFFFFF', 'E6'
local TITLE_COLOR, DETAIL_COLOR = 'FFFFFF', 'B4B4B4'
-- The one accent colour (#4CC2FF, Windows 11's dark-mode accent): banner
-- icons and the progress line here, the dragged row in subtitle-sync.lua.
local ACCENT = 'FFC24C'

-- Each banner wears the icon of the toolbar button or menu it belongs to
-- (uosc_icons, the font uosc draws its buttons with).
local ICONS = {
	['speed'] = 'speed', -- the speed button
	['shaders'] = 'auto_awesome', -- the upscale button
	['shader-cache'] = 'auto_awesome',
	['video-info'] = 'theaters', -- uosc's video button
	['subtitles'] = 'subtitles', -- uosc's subtitles button
	['subtitle-sync'] = 'sync', -- the sync tool's button
	['source-copy'] = 'content_copy', -- the source menu's Copy entries
	['stream-error'] = 'language', -- the source button: a FastStream stream that did not open
	['resume'] = 'history',
	['settings'] = 'settings', -- Settings menu choices (settings.lua)
	['welcome'] = 'waving_hand', -- the first start (welcome.lua)
}

-- The user's size knob: 1 = the original design, 1.35 = noticeably bigger.
-- Read from script-opts/notify_size.conf ("size=1.35") or
-- --script-opts=notify_size-size=<n>.
local o = { size = 1.35 }
opt.read_options(o, 'notify_size')

---@param n any
---@return number|nil
local function sane_size(n)
	n = tonumber(n)
	return n and n >= 0.6 and n <= 4 and n or nil
end
local user_size = sane_size(o.size) or 1.35

---@type {id: string, title: string, detail: string, progress: number|nil, left: boolean|nil, icon: string|nil, timer: table|nil, width: number|nil, width_scale: number|nil, box: table|nil}[]
local cards = {}

local canvas = mp.create_osd_overlay('ass-events')
canvas.z = 3000 -- above uosc (2000, uosc/lib/utils.lua)

-- Measures text with libass itself: a hidden overlay that only returns its
-- bounds. Called when a banner's text changes, never per frame.
local meter = mp.create_osd_overlay('ass-events')
meter.hidden = true
meter.compute_bounds = true

-- The scale every metric is multiplied by: uosc's interface scale, read from
-- its user-data hook. A display-height fallback until uosc publishes (it may
-- load after the first banner) keeps that first banner reasonable.
local scale = 1
local function read_scale()
	local s = mp.get_property_number('user-data/uosc/ui-scale')
	if s and s > 0 then
		scale = s
		return
	end
	local _, h = mp.get_osd_size()
	if h and h > 0 then
		scale = h / 720
	end
end

--- A design value as REAL pixels: design x interface scale x user size.
---@param v number
---@return number
local function px(v)
	return math.floor(v * scale * user_size + 0.5)
end

-- Draw() is defined further down; the ui-scale observer below can fire on a
-- property change, so it needs the name bound up front - without this, Lua
-- compiles its draw() call as a nil GLOBAL lookup (undefined-global).
local draw

mp.observe_property('user-data/uosc/ui-scale', 'number', function()
	read_scale()
	for _, card in ipairs(cards) do
		card.width = nil
	end
	if #cards > 0 then
		draw()
	end
end)

-- mpv's OWN OSD text (mpv.conf's osd-box block: font 14, box padding 7,
-- margins 22/53 - the banners' title size and edges at a 720-line window)
-- must come out exactly where and as big as a banner would. Its "scaled
-- pixels" follow the window height, not uosc's interface scale, so this
-- switches that off (osd-scale-by-window=no: every one of those options is
-- then in REAL pixels) and writes the banners' own px() values into all of
-- them whenever the scale or the window changes.
-- Until 2026-10-02 only the font was rewritten, and still divided by the
-- window-height ratio although the window scaling had just been switched off:
-- at 1080p the text came out at 2/3 of the banner title's size, at 1440p
-- fullscreen at about half, and the unscaled 22/53 margins put its box 8 px
-- past the banners' right edge (seen on a screenshot).
local osd_scaled = nil
local function set_osd_scale()
	local w, h = mp.get_osd_size()
	if not w or not h or h <= 0 then
		return
	end
	local pad = px(OSD_BOX_PAD)
	-- libass draws the box ~1.5 px further right than the text's margin says
	-- (measured on a 2560x1440 screenshot when this was 22 = 14 + 7 + 1)
	local values = { px(TITLE_SIZE * FONT_SCALE), pad, px(RIGHT) + pad + 1, px(TOP) + pad }
	local key = table.concat(values, ',')
	if key ~= osd_scaled then
		osd_scaled = key
		-- osd-scale-by-window is a yes/no OPTION: setting it through
		-- set_property_number with false crashed draw() with "bad argument
		-- #2 (number expected, got boolean)" in the real renderer - the
		-- exception killed every banner after it. Options go through
		-- set_property, which accepts no as a string.
		mp.set_property('osd-scale-by-window', 'no')
		mp.set_property_number('osd-font-size', values[1])
		mp.set_property_number('osd-shadow-offset', values[2])
		mp.set_property_number('osd-margin-x', values[3])
		mp.set_property_number('osd-margin-y', values[4])
	end
end

-- Text into an ASS event: a backslash gets a zero-width no-break space after
-- it (mpv's own osc.lua does the same), braces are escaped, so a file name
-- can never start an override tag.
---@param str string
---@return string
local function ass_escape(str)
	return (str:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('[\r\n]+', ' '))
end

-- \rDefault first, as uosc does: mpv.conf's osd-box style applies to every
-- overlay event that keeps the OSD style, and would draw a second box.
---@param x number
---@param y number
---@param size number
---@param color string
---@param str string
---@param clip string|nil
---@return string
local function text_event(x, y, size, color, str, clip)
	return string.format(
		'{\\rDefault\\an7\\pos(%d,%d)\\q2\\blur0\\bord0\\shad0\\fs%d\\1c&H%s&%s}%s',
		x,
		y,
		size,
		color,
		clip or '',
		ass_escape(str)
	)
end

--- A filled rectangle with rounded corners (radius 0 = square), optionally
--- with a 1 px edge in another colour.
---@return string
local function rect_event(x, y, w, h, color, alpha, radius, edge)
	local path = assdraw.ass_new()
	if radius and radius > 0 then
		path:round_rect_cw(0, 0, w, h, math.min(radius, w / 2, h / 2))
	else
		path:rect_cw(0, 0, w, h)
	end
	-- path.scale: assdraw stores coordinates at 2^(scale-1) for sub-pixel
	-- corners; \p must name the same scale
	return string.format(
		'{\\rDefault\\an7\\pos(%d,%d)\\blur0\\bord%d\\shad0\\1c&H%s&\\1a&H%s&\\3c&H%s&\\3a&H%s&\\p%d}%s{\\p0}',
		x,
		y,
		edge and 1 or 0,
		color,
		alpha,
		edge and EDGE or color,
		edge and EDGE_ALPHA or alpha,
		path.scale,
		path.text
	)
end

--- An icon from uosc's icon font, centred on (x, y): the family uosc's own
--- ass:icon() names, the icon's name as text (the font turns it into the glyph).
---@return string
local function icon_event(x, y, size, name, clip)
	return string.format(
		'{\\rDefault\\an5\\pos(%d,%d)\\fnMaterialIconsRound-Regular\\b0\\q2\\blur0\\bord0\\shad0\\fs%d\\1c&H%s&%s}%s',
		x,
		y,
		size,
		ACCENT,
		clip or '',
		name
	)
end

---@param card table
---@return number real pixels the icon column takes, 0 without an icon
local function icon_width(card)
	if not card.icon then
		return 0
	end
	return px(card.detail ~= '' and ICON_SIZE_TALL or ICON_SIZE) + px(ICON_GAP)
end

---@param str string
---@param size number real pixels
---@return number
local function text_width(str, size)
	if str == '' then
		return 0
	end
	meter.res_x, meter.res_y = canvas.res_x, canvas.res_y
	meter.data = text_event(0, 0, size, TITLE_COLOR, str)
	local bounds = meter:update()
	if type(bounds) == 'table' and bounds.x1 and bounds.x0 then
		return bounds.x1 - bounds.x0
	end
	return #str * size * 0.55 -- the OSD has no size yet: a fair estimate
end

-- A detail too wide for the card wraps, word by word, onto up to
-- MAX_DETAIL_LINES lines (review, 2026-10-09: it was clipped at the card's edge,
-- and the longer banners - "Upscaling off here ... Settings > Upscaling quality
-- runs it anyway" - lost exactly the part that says what to do). Whatever does
-- not fit even then goes on the last line, clipped as before.
local DETAIL_LINE = 15
local MAX_DETAIL_LINES = 3

---@param str string
---@param size number font size, real pixels
---@param room number the width a line may take, real pixels
---@return string[] lines
local function wrap(str, size, room)
	if str == '' or text_width(str, size) <= room then
		return { str }
	end
	local lines, line = {}, ''
	for word in str:gmatch('%S+') do
		local try = line == '' and word or (line .. ' ' .. word)
		if line ~= '' and text_width(try, size) > room then
			lines[#lines + 1] = line
			line = word
		else
			line = try
		end
	end
	if line ~= '' then
		lines[#lines + 1] = line
	end
	while #lines > MAX_DETAIL_LINES do
		lines[MAX_DETAIL_LINES] = lines[MAX_DETAIL_LINES] .. ' ' .. table.remove(lines, MAX_DETAIL_LINES + 1)
	end
	return lines
end

---@param card table
---@return number width, number height real pixels
local function card_size(card)
	local height = card.progress and px(HEIGHT_PROGRESS) or card.detail ~= '' and px(HEIGHT_DETAIL) or px(HEIGHT_TITLE)
	if card.progress then
		card.lines = { card.detail }
		return px(PROGRESS_WIDTH), height
	end
	if not card.width or card.width_scale ~= scale then
		local detail_size = px(DETAIL_SIZE * FONT_SCALE)
		card.lines = wrap(card.detail, detail_size, px(MAX_WIDTH) - icon_width(card) - 2 * px(PAD_X))
		local text = text_width(card.title, px(TITLE_SIZE * FONT_SCALE))
		for _, line in ipairs(card.lines) do
			text = math.max(text, text_width(line, detail_size))
		end
		card.width = math.min(px(MAX_WIDTH), math.ceil(text) + icon_width(card) + 2 * px(PAD_X))
		card.width_scale = scale
	end
	return card.width, height + (#card.lines - 1) * px(DETAIL_LINE)
end

local native_offset = 0
-- mpv's own OSD text starts right under the last banner of the RIGHT stack.
-- The left stack is a separate corner mpv's right-aligned OSD text cannot
-- land on, so its height does not move the text.
---@param offset number
local function set_native_offset(offset)
	offset = math.floor(offset + 0.5)
	if offset ~= native_offset then
		native_offset = offset
		mp.set_property_number('osd-margin-y-offset', offset)
	end
end

---@param drawn boolean|nil the canvas was just updated: publish each card's box
local function publish(drawn)
	local list = {}
	for i, card in ipairs(cards) do
		list[i] = {
			id = card.id,
			title = card.title,
			detail = card.detail,
			progress = card.progress,
			left = card.left,
			icon = card.icon,
			lines = card.lines,
			box = drawn and card.box or nil,
		}
	end
	mp.set_property_native('user-data/notify', { cards = list, size = user_size })
end

draw = function()
	read_scale()
	if #cards == 0 then
		publish()
		canvas:remove()
		set_native_offset(0)
		return
	end
	local w, h = mp.get_osd_size()
	local known = w and h and w > 0 and h > 0
	-- The canvas is the display's own size: real-pixel drawing, like uosc's.
	canvas.res_x, canvas.res_y = known and w or 1280, known and h or 720
	local top, right, left, gap, pad_x = px(TOP), px(RIGHT), px(LEFT), px(GAP), px(PAD_X)
	local events = {}
	local y_right, y_left = top, top
	for _, card in ipairs(cards) do
		local bw, bh = card_size(card)
		local x0 = card.left and left or w - right - bw
		local y = card.left and y_left or y_right
		local icon_w = icon_width(card)
		local text_x = x0 + pad_x + icon_w
		-- Text that does not fit is cut at the padding, not drawn past the box.
		local clip = string.format('\\clip(%d,%d,%d,%d)', text_x, y, x0 + bw - pad_x, y + bh)
		card.box = { x = x0, y = y, w = bw, h = bh }
		events[#events + 1] = rect_event(x0, y, bw, bh, BOX, BOX_ALPHA, px(RADIUS), true)
		if card.icon then
			local size = px(card.detail ~= '' and ICON_SIZE_TALL or ICON_SIZE)
			-- centred on the text lines, not on a progress card's bar
			-- centred on the text: the whole card, except a progress card's bar strip
			local text_h = card.progress and (card.detail ~= '' and px(HEIGHT_DETAIL) or px(HEIGHT_TITLE)) or bh
			events[#events + 1] = icon_event(x0 + pad_x + size / 2, y + text_h / 2, size, card.icon)
		end
		events[#events + 1] =
			text_event(text_x, y + px(TITLE_Y), px(TITLE_SIZE * FONT_SCALE), TITLE_COLOR, card.title, clip)
		if card.detail ~= '' then
			for i, line in ipairs(card.lines or { card.detail }) do
				events[#events + 1] = text_event(
					text_x,
					y + px(DETAIL_Y) + (i - 1) * px(DETAIL_LINE),
					px(DETAIL_SIZE * FONT_SCALE),
					DETAIL_COLOR,
					line,
					clip
				)
			end
		end
		if card.progress then
			-- a rounded bar under the text, across the whole card
			local track = bw - 2 * pad_x
			local bar_h = math.max(2, px(PROGRESS_HEIGHT))
			local bar_y = y + bh - px(6) - math.floor(bar_h / 2)
			local fill = math.floor(track * math.max(0, math.min(1, card.progress)))
			events[#events + 1] = rect_event(x0 + pad_x, bar_y, track, bar_h, 'FFFFFF', 'D0', bar_h / 2)
			if fill > 0 then
				events[#events + 1] =
					rect_event(x0 + pad_x, bar_y, math.max(fill, bar_h), bar_h, ACCENT, '00', bar_h / 2)
			end
		end
		if card.left then
			y_left = y + bh + gap
		else
			y_right = y + bh + gap
		end
	end
	set_native_offset(y_right - top)
	set_osd_scale()
	if not known then
		publish()
		return -- headless, or no window yet: osd-dimensions redraws once there is one
	end
	canvas.data = table.concat(events, '\n')
	canvas:update()
	publish(true)
end

---@param id string
---@return integer|nil
local function find(id)
	for i, card in ipairs(cards) do
		if card.id == id then
			return i
		end
	end
end

---@param id string
local function hide(id)
	local i = find(id)
	if not i then
		return
	end
	if cards[i].timer then
		cards[i].timer:kill()
	end
	table.remove(cards, i)
	draw()
end

---@param id string
---@param title string
---@param detail string|nil
---@param seconds string|nil
---@param progress string|nil
---@param side string|nil "left" draws the banner top left instead of top right
---@param icon string|nil a uosc_icons name; '' or nil = ICONS[id], '-' = none
local function show(id, title, detail, seconds, progress, side, icon)
	if not id or id == '' or not title then
		return
	end
	local i = find(id)
	local card = i and cards[i] or { id = id }
	if not i then
		cards[#cards + 1] = card
	end
	detail = detail or ''
	if card.title ~= title or card.detail ~= detail then
		card.width = nil
	end
	card.title, card.detail = title, detail
	card.progress = tonumber(progress)
	card.left = side == 'left'
	if icon == '-' then
		icon = nil
	elseif not icon or icon == '' then
		icon = ICONS[id]
	end
	if card.icon ~= icon then
		card.width = nil
	end
	card.icon = icon
	if card.timer then
		card.timer:kill()
		card.timer = nil
	end
	local duration = tonumber(seconds) or DEFAULT_SECONDS
	if duration > 0 then
		card.timer = mp.add_timeout(duration, function()
			hide(id)
		end)
	end
	draw()
end

mp.register_script_message('show', show)
mp.register_script_message('hide', hide)

mp.observe_property('osd-dimensions', 'native', function()
	read_scale()
	set_osd_scale()
	if #cards > 0 then
		for _, card in ipairs(cards) do
			card.width = nil -- measured without a window, or hinting changed
		end
		draw()
	end
end)

publish()
