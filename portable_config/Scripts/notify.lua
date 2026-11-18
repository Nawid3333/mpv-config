-- notify.lua - the small banners top right: every message this setup shows.

local mp = require('mp')
local opt = require('mp.options')
local assdraw = require('mp.assdraw')

-- Design sizes in 720-line units, times uosc's interface scale (user-data/uosc/ui-scale): real pixels, like uosc's.
local TOP = 46 -- below uosc's top bar and window buttons
local RIGHT = 14
local LEFT = 14 -- the left stack's margin (side=left)
local GAP = 6
local PAD_X = 10
local TITLE_SIZE, DETAIL_SIZE = 14, 11
-- Segoe UI (osd-font) has a 1.19x taller line box than Arial, and libass sizes text by it (uosc.conf font_scale).
local FONT_SCALE = 1.19
-- text tops inside a banner; Segoe UI's taller line box (FONT_SCALE) puts
-- the glyphs lower in it
local TITLE_Y, DETAIL_Y = 4, 21
local HEIGHT_TITLE, HEIGHT_DETAIL, HEIGHT_PROGRESS = 28, 40, 44
local PROGRESS_WIDTH = 270
local MAX_WIDTH = 380
local DEFAULT_SECONDS = 2
-- uosc.conf's border_radius: the rounding of uosc's menus, buttons and tooltips.
local RADIUS = 6
local PROGRESS_HEIGHT = 3
local ICON_SIZE, ICON_SIZE_TALL, ICON_GAP = 16, 20, 8
-- mpv's own OSD text box (mpv.conf's osd-box block): libass pads the box by
-- osd-shadow-offset on every side.
local OSD_BOX_PAD = 7
-- &HBBGGRR& colours, alpha 00 = opaque; the same black as mpv.conf's osd-back-color.
local BOX, BOX_ALPHA = '000000', '00'
-- White at ~10 %, like a Windows 11 flyout's stroke: invisible on a bright picture, an outline over a black letterbox.
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
	-- FastStream's notices (its helper sends them: autoplay, the next episode) and
	-- the episode keys without it (faststream-episodes.lua): the autoplay switch's icon
	['faststream'] = 'playlist_play',
	['welcome'] = 'waving_hand', -- the first start (welcome.lua)
	['single-instance'] = 'open_in_new', -- "Play this in a new window" (single-instance.lua)
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

-- uosc's interface scale; a display-height fallback until uosc publishes it.
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

---@param v number
---@return number
local function px(v)
	return math.floor(v * scale * user_size + 0.5)
end

-- Bound up front: the ui-scale observer below calls draw(), which is defined further down.
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

-- mpv's own OSD text (mpv.conf's osd-box) must come out where and as big as a banner; its scaled pixels follow
-- the window, not uosc's scale, so osd-scale-by-window=no makes them real pixels and the banners' px() values go in.
local osd_scaled = nil
local function set_osd_scale()
	local w, h = mp.get_osd_size()
	if not w or not h or h <= 0 then
		return
	end
	local pad = px(OSD_BOX_PAD)
	-- libass draws the box ~1.5 px further right than the text's margin says
	local values = { px(TITLE_SIZE * FONT_SCALE), pad, px(RIGHT) + pad + 1, px(TOP) + pad }
	local key = table.concat(values, ',')
	if key ~= osd_scaled then
		osd_scaled = key
		-- osd-scale-by-window is a yes/no option: set_property_number with a boolean throws in the real renderer.
		mp.set_property('osd-scale-by-window', 'no')
		mp.set_property_number('osd-font-size', values[1])
		mp.set_property_number('osd-shadow-offset', values[2])
		mp.set_property_number('osd-margin-x', values[3])
		mp.set_property_number('osd-margin-y', values[4])
	end
end

-- A backslash gets a zero-width no-break space after it (as osc.lua does), braces are escaped: no override tag.
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

-- A too-wide detail wraps onto up to MAX_DETAIL_LINES lines; what still does not fit is clipped on the last.
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
---@param limit number the widest it may be, real pixels: MAX_WIDTH, or less in a narrow window
---@return number width, number height real pixels
local function card_size(card, limit)
	local height = card.progress and px(HEIGHT_PROGRESS) or card.detail ~= '' and px(HEIGHT_DETAIL) or px(HEIGHT_TITLE)
	if card.progress then
		card.lines = { card.detail }
		return math.min(px(PROGRESS_WIDTH), limit), height
	end
	if not card.width or card.width_scale ~= scale or card.width_limit ~= limit then
		local detail_size = px(DETAIL_SIZE * FONT_SCALE)
		-- a few words wide at least, however narrow the window
		card.lines = wrap(card.detail, detail_size, math.max(limit - icon_width(card) - 2 * px(PAD_X), px(60)))
		local text = text_width(card.title, px(TITLE_SIZE * FONT_SCALE))
		for _, line in ipairs(card.lines) do
			text = math.max(text, text_width(line, detail_size))
		end
		card.width = math.min(limit, math.ceil(text) + icon_width(card) + 2 * px(PAD_X))
		card.width_scale, card.width_limit = scale, limit
	end
	return card.width, height + (#card.lines - 1) * px(DETAIL_LINE)
end

local native_offset = 0
-- mpv's own OSD text starts under the right stack's last banner; the left stack does not move it.
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
	-- A window narrower than a card: the card fits the window, its detail wrapped narrower, a long title cut.
	local limit = px(MAX_WIDTH)
	if known then
		limit = math.max(math.min(limit, w - left - right), 4 * pad_x)
	end
	local events = {}
	local y_right, y_left = top, top
	for _, card in ipairs(cards) do
		local bw, bh = card_size(card, limit)
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
	-- a progress bar's card has a fixed width and its detail on one line (card_size):
	-- without the bar again, it is measured and wrapped anew
	if (card.progress == nil) ~= (tonumber(progress) == nil) then
		card.width = nil
	end
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
