-- queue/panel.lua - what comes next, bottom right under uosc's volume slider and above its controls: one card "Up
-- next" - the queue's first item, else the playlist's next local file - with its picture (a video's frame, a song's
-- cover: picture.lua; a stream the queue icon), while uosc's bar shows, in a file's last seconds, alone for a moment
-- after something was queued and during the countdown. A song's card sits in music-info.lua's panel instead, while
-- that shows. The whole queue while the pointer is on the card: a click on a row plays it now, its x removes it, a
-- drag moves it, Clear empties the queue; a click on a local file's card plays it now. Drawn like notify.lua's
-- banners; real pixels, uosc's interface scale.

local mp = require('mp')
local assdraw = require('mp.assdraw')

-- Design sizes, times uosc's interface scale and notify.lua's size knob (the banners' sizes, so both match).
local GAP = 10 -- from uosc's controls and its volume slider
local PAD = 9
local CARD_H, ROW_H, HEAD_H = 46, 34, 32
local PIC_W, PIC_H = 60, 34 -- the picture's box: a 16:9 frame fills it, a cover is square
local PIC_PAD = 6
local CARD_W, LIST_W = 300, 342
local ICON = 17
local TITLE, DETAIL, LABEL = 11.4, 8.8, 8.8
local FONT_SCALE = 1.19 -- Segoe UI's taller line box (notify.lua, uosc.conf font_scale)
local RADIUS = 6
local BAR = 2.3 -- the countdown line
local PEEK_SECONDS = 4 -- after something was queued
local END_SECONDS = 5 -- the last seconds of a file show what comes next (the owner, 2026-11-25)
local LEAVE_SECONDS = 0.4 -- the list stays that long after the pointer left it
local DRAG_PX = 6 -- a press that moves further is a drag, not a click

local BOX, EDGE, EDGE_ALPHA = '000000', 'FFFFFF', 'E6'
local TITLE_COLOR, DETAIL_COLOR, ACCENT = 'FFFFFF', 'B4B4B4', 'FFC24C'
local HOVER_BOX = '1F1F1F'
local OVERLAY_ID = 41 -- overlay-add's ids are mpv-wide: thumbfast has 42

local size = 1.35
do
	local opts = { size = 1.35 }
	require('mp.options').read_options(opts, 'notify_size')
	local n = tonumber(opts.size)
	size = n and n >= 0.6 and n <= 4 and n or 1.35
end

return function(actions)
	local canvas = mp.create_osd_overlay('ass-events')
	canvas.z = 2900 -- above uosc (2000), under notify.lua's banners (3000)
	local pictures = dofile(mp.get_script_directory() .. '/picture.lua')(mp.get_script_directory())

	local items, countdown, added = {}, nil, nil
	local upcoming -- main.lua's: {id, title, detail, path (a local file), queued}
	local music -- user-data/music-info: a song's panel, with a place for the card (slot)
	local overlay -- the picture overlay-add shows: {file, x, y, w, h}
	local card_picture -- the picture the card drawn last wants shown
	local card_text -- what the card drawn last says, for the tests
	local bottom -- user-data/uosc/bottom-ui
	local scale = 1
	local expanded, over = false, false
	local leave_timer, peek_timer
	local peek_until = 0
	local ending = false -- the file's last seconds
	local pointer -- mouse-pos
	local pressed -- {id, y, row} while the left button is held on a row
	local dragging -- {id, y} once that press moved
	local scroll = 0
	local hits = {} -- {x0, y0, x1, y1, what, id} of what was drawn, for the pointer
	local box -- the panel's or card's rectangle
	local keeping_ui = false
	local section_on = false

	local function px(v)
		return math.floor(v * scale * size + 0.5)
	end

	local function ass_escape(str)
		return (str:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('[\r\n]+', ' '))
	end

	---@param alpha string two hex digits, 00 = opaque
	---@param fade number 0..1, 1 = fully shown
	local function faded(alpha, fade)
		local a = tonumber(alpha, 16)
		return string.format('%02X', math.floor(255 - (255 - a) * fade + 0.5))
	end

	local function rect(x, y, w, h, color, alpha, radius, fade, edge)
		local path = assdraw.ass_new()
		if radius and radius > 0 then
			path:round_rect_cw(0, 0, w, h, math.min(radius, w / 2, h / 2))
		else
			path:rect_cw(0, 0, w, h)
		end
		return string.format(
			'{\\rDefault\\an7\\pos(%d,%d)\\blur0\\bord%d\\shad0\\1c&H%s&\\1a&H%s&\\3c&H%s&\\3a&H%s&\\p%d}%s{\\p0}',
			x,
			y,
			edge and 1 or 0,
			color,
			faded(alpha, fade),
			edge and EDGE or color,
			faded(edge and EDGE_ALPHA or alpha, fade),
			path.scale,
			path.text
		)
	end

	local function text(x, y, fs, color, str, fade, clip, an)
		return string.format(
			'{\\rDefault\\an%d\\pos(%d,%d)\\q2\\blur0\\bord0\\shad0\\fs%d\\1c&H%s&\\1a&H%s&%s}%s',
			an or 7,
			x,
			y,
			fs,
			color,
			faded('00', fade),
			clip or '',
			ass_escape(str)
		)
	end

	local function icon(x, y, fs, name, color, fade)
		return string.format(
			'{\\rDefault\\an5\\pos(%d,%d)\\fnMaterialIconsRound-Regular\\b0\\q2\\blur0\\bord0\\shad0\\fs%d\\1c&H%s&\\1a&H%s&}%s',
			x,
			y,
			fs,
			color or ACCENT,
			faded('00', fade),
			name
		)
	end

	local function clip(x0, y0, x1, y1)
		return string.format('\\clip(%d,%d,%d,%d)', x0, y0, x1, y1)
	end

	local function fs(v)
		return px(v * FONT_SCALE)
	end

	--- Where the panel may be: its right edge and bottom, and how high it may reach.
	local function frame()
		local w, h = mp.get_osd_size()
		if not w or not h or w <= 0 or h <= 0 then
			return nil
		end
		local b = bottom or {}
		local right = (b.volume and b.volume.bx) or (w - px(GAP))
		local base = (b.controls_top and b.controls_top < h and b.controls_top or h - px(60)) - px(GAP)
		local top = b.volume and b.volume.by + px(GAP) or px(46)
		if base - top < px(HEAD_H + ROW_H + 2 * PAD) then
			top = px(46) -- a short window: over the slider rather than no room
		end
		return { w = w, h = h, right = right, base = base, top = top }
	end

	local function shown_fade()
		if not upcoming then
			return 0
		end
		if expanded or countdown or dragging or mp.get_time() < peek_until or ending then
			return 1
		end
		return bottom and tonumber(bottom.visibility) or 0
	end

	--- music-info.lua's panel keeps a place for the card in its right column while a song plays: the card goes there
	--- while that panel shows, at its fade (the owner, 2026-11-25).
	local function music_slot()
		local slot = music and music.slot
		local visibility = music and tonumber(music.visibility) or 0
		if type(slot) ~= 'table' or not tonumber(slot.x) or visibility <= 0 then
			return nil
		end
		return { x = slot.x, y = slot.y, w = slot.w, h = slot.h, fade = visibility }
	end

	--- How much the card or list shows, and the panel's slot it sits in (nil: on its own above the controls).
	local function current_fade()
		local slot = music_slot()
		if expanded and #items > 0 then
			return 1, slot
		end
		if slot then
			return slot.fade, slot
		end
		return shown_fade(), nil
	end

	---@param ... string|nil
	---@return string|nil
	local function joined(...)
		local parts = {}
		for i = 1, select('#', ...) do
			local v = select(i, ...)
			if v and v ~= '' then
				parts[#parts + 1] = v
			end
		end
		return #parts > 0 and table.concat(parts, ' · ') or nil
	end

	---@param seconds number
	---@return string
	local function clock(seconds)
		local t = math.floor(seconds + 0.5)
		local hours, minutes = math.floor(t / 3600), math.floor(t % 3600 / 60)
		if hours > 0 then
			return string.format('%d:%02d:%02d', hours, minutes, t % 60)
		end
		return string.format('%d:%02d', minutes, t % 60)
	end

	--- The card: its picture (a frame, a cover, else an icon), "Up next" (a countdown, when one runs), the title, a
	--- detail line, and how many more are queued.
	---@param place table {x, y, w, h, boxed}
	local function draw_card(fade, events, place)
		local item = upcoming
		local x0, y0, w, h = place.x, place.y, place.w, place.h
		local right = x0 + w
		box = { x0 = x0, y0 = y0, x1 = right, y1 = y0 + h }
		if place.boxed then
			events[#events + 1] = rect(x0, y0, w, h, BOX, '00', px(RADIUS), fade, true)
		end
		local result = item.path and pictures.get(item.path, px(PIC_W), px(PIC_H)) or nil
		local info = result and result.info or {}
		-- a song: sound with a cover, or sound only
		local song = info.audio and (info.cover or not info.w)
		local pic_x, pic_h = x0 + px(PIC_PAD), px(PIC_H)
		local pic_y = y0 + math.floor((h - pic_h) / 2)
		local pic_w
		if result and result.state == 'ready' then
			pic_w = result.w
			card_picture = {
				file = result.file,
				x = pic_x,
				y = pic_y + math.floor((pic_h - result.h) / 2),
				w = result.w,
				h = result.h,
			}
		else
			pic_w = pic_h
			events[#events + 1] = rect(pic_x, pic_y, pic_w, pic_h, '1A1A1A', '00', px(4), fade)
			local name = not item.path and 'playlist_play' or song and 'music_note' or 'movie'
			events[#events + 1] = icon(pic_x + pic_w / 2, pic_y + pic_h / 2, px(ICON + 3), name, ACCENT, fade)
		end
		local tx = pic_x + pic_w + px(9)
		local more = #items > 1 and ('+' .. (#items - 1)) or nil
		local badge_w = more and px(26) or 0
		local cut = clip(tx, y0, right - px(PAD) - badge_w, y0 + h)
		local label = countdown and string.format('Up next in %d s', math.ceil(countdown.left)) or 'Up next'
		local title, detail = item.title, item.detail
		if song then
			title = info.title or title
			detail = joined(info.artist, info.album) or detail
		elseif item.path and tonumber(info.duration) then
			detail = joined(clock(info.duration), detail)
		end
		card_text = { label = label, title = title, detail = detail }
		events[#events + 1] = text(tx, y0 + px(4), fs(LABEL), countdown and ACCENT or DETAIL_COLOR, label, fade, cut)
		events[#events + 1] = text(tx, y0 + px(15), fs(TITLE), TITLE_COLOR, title, fade, cut)
		if detail then
			events[#events + 1] = text(tx, y0 + px(31), fs(DETAIL), DETAIL_COLOR, detail, fade, cut)
		end
		if more then
			local bw, bh = px(22), px(14)
			local bx, by = right - px(PAD) - bw, y0 + (h - bh) / 2
			events[#events + 1] = rect(bx, by, bw, bh, '2A2A2A', '00', bh / 2, fade)
			events[#events + 1] = text(bx + bw / 2, by + bh / 2, fs(LABEL), 'DDDDDD', more, fade, nil, 5)
		end
		if countdown then
			local done = 1 - countdown.left / countdown.total
			events[#events + 1] =
				rect(x0, y0 + h - px(BAR), math.max(1, math.floor(w * done)), px(BAR), ACCENT, '00', 0, fade)
		end
		hits = { { x0 = x0, y0 = y0, x1 = right, y1 = y0 + h, what = 'card' } }
	end

	--- overlay-add cannot fade: the picture shows while the card is at least half in.
	local function show_picture(picture)
		if overlay and overlay.file == picture.file and overlay.x == picture.x and overlay.y == picture.y then
			return
		end
		local done = mp.command_native({
			'overlay-add',
			OVERLAY_ID,
			picture.x,
			picture.y,
			picture.file,
			0,
			'bgra',
			picture.w,
			picture.h,
			4 * picture.w,
		})
		overlay = done ~= nil and picture or nil
	end

	local function hide_picture()
		if overlay then
			mp.command_native({ 'overlay-remove', OVERLAY_ID })
			overlay = nil
		end
	end

	--- The whole list: a header with Clear, a row per item (number, title, site), the hovered row's x.
	local function draw_list(f, fade, events)
		local w = math.min(px(LIST_W), f.right - px(GAP))
		local pad, row_h, head_h = px(4.5), px(ROW_H), px(HEAD_H)
		local room = math.max(1, math.floor((f.base - f.top - head_h - 2 * pad) / row_h))
		local rows = math.min(#items, room)
		scroll = math.max(0, math.min(scroll, #items - rows))
		local h = 2 * pad + head_h + rows * row_h
		local x0, y0 = f.right - w, f.base - h
		box = { x0 = x0, y0 = y0, x1 = f.right, y1 = f.base }
		hits = {}
		events[#events + 1] = rect(x0, y0, w, h, BOX, '00', px(RADIUS), fade, true)
		-- header
		local hy = y0 + pad
		events[#events + 1] =
			icon(x0 + pad + px(PAD) + px(ICON) / 2, hy + head_h / 2, px(ICON), 'playlist_play', ACCENT, fade)
		local tx = x0 + pad + px(PAD) + px(ICON) + px(7)
		events[#events + 1] = text(tx, hy + head_h / 2, fs(12), TITLE_COLOR, 'Queue', fade, nil, 4)
		local label = countdown and string.format('next in %d s', math.ceil(countdown.left)) or (#items .. ' waiting')
		events[#events + 1] =
			text(tx + px(42), hy + head_h / 2, fs(DETAIL), countdown and ACCENT or DETAIL_COLOR, label, fade, nil, 4)
		local cw, ch = px(44), px(19)
		local cx, cy = f.right - pad - px(5) - cw, hy + (head_h - ch) / 2
		local clear_over = pointer
			and pointer.x >= cx
			and pointer.x <= cx + cw
			and pointer.y >= cy
			and pointer.y <= cy + ch
		events[#events + 1] = rect(cx, cy, cw, ch, clear_over and '2E2E2E' or BOX, '00', px(4), fade, true)
		events[#events + 1] = text(
			cx + cw / 2,
			cy + ch / 2,
			fs(DETAIL),
			clear_over and TITLE_COLOR or DETAIL_COLOR,
			'Clear',
			fade,
			nil,
			5
		)
		hits[#hits + 1] = { x0 = cx, y0 = cy, x1 = cx + cw, y1 = cy + ch, what = 'clear' }
		-- rows; a dragged one follows the pointer and the others make room for it
		local list_top = hy + head_h
		local order = {}
		for i = scroll + 1, scroll + rows do
			order[#order + 1] = i
		end
		local drag_slot
		if dragging then
			drag_slot = math.max(1, math.min(rows, math.floor((pointer.y - list_top) / row_h) + 1))
		end
		local slot = 0
		for _, i in ipairs(order) do
			local item = items[i]
			if not (dragging and item.id == dragging.id) then
				slot = slot + 1
				if drag_slot and slot == drag_slot then
					slot = slot + 1
				end
				local ry = list_top + (slot - 1) * row_h
				local hovered = not dragging
					and pointer
					and pointer.x >= x0
					and pointer.x <= f.right
					and pointer.y >= ry
					and pointer.y < ry + row_h
				local is_new = added and added.id == item.id and mp.get_time() - added.at < PEEK_SECONDS
				if hovered then
					events[#events + 1] = rect(x0 + pad, ry, w - 2 * pad, row_h, HOVER_BOX, '00', px(4), fade)
				end
				local nx = x0 + pad + px(PAD) + px(ICON) / 2
				if hovered then
					events[#events + 1] = icon(nx, ry + row_h / 2, px(ICON), 'play_arrow', TITLE_COLOR, fade)
				else
					events[#events + 1] =
						text(nx, ry + row_h / 2, fs(9.5), is_new and ACCENT or DETAIL_COLOR, tostring(i), fade, nil, 5)
				end
				local xw = px(25)
				local right_edge = f.right - pad - px(5) - (hovered and xw + px(4) or 0)
				local cut = clip(tx, ry, right_edge, ry + row_h)
				events[#events + 1] = text(tx, ry + px(5), fs(TITLE), TITLE_COLOR, item.title, fade, cut)
				local detail = item.detail
				if is_new then
					detail = 'just added' .. (detail ~= '' and (' · ' .. detail) or '')
				elseif i == 1 and not countdown then
					detail = 'next' .. (detail ~= '' and (' · ' .. detail) or '')
				end
				events[#events + 1] =
					text(tx, ry + px(19), fs(DETAIL), is_new and ACCENT or DETAIL_COLOR, detail, fade, cut)
				-- hit_at looks from the last box back: the x, inside its row, comes after it
				hits[#hits + 1] =
					{ x0 = x0, y0 = ry, x1 = f.right, y1 = ry + row_h, what = 'row', id = item.id, index = i }
				if hovered then
					local bx, by = f.right - pad - px(5) - xw, ry + (row_h - xw) / 2
					events[#events + 1] = rect(bx, by, xw, xw, '2E2E2E', '00', px(4), fade)
					events[#events + 1] = icon(bx + xw / 2, by + xw / 2, px(13), 'close', TITLE_COLOR, fade)
					hits[#hits + 1] = { x0 = bx, y0 = by, x1 = bx + xw, y1 = by + xw, what = 'remove', id = item.id }
				end
			end
		end
		if dragging then
			local item
			for _, it in ipairs(items) do
				if it.id == dragging.id then
					item = it
				end
			end
			if item then
				local ry = math.max(list_top, math.min(pointer.y - row_h / 2, list_top + (rows - 1) * row_h))
				events[#events + 1] = rect(x0 + pad, ry, w - 2 * pad, row_h, '262626', '00', px(4), fade)
				events[#events + 1] = rect(x0 + pad, ry, px(BAR), row_h, ACCENT, '00', 0, fade)
				local cut = clip(tx, ry, f.right - pad - px(5), ry + row_h)
				events[#events + 1] = text(tx, ry + px(5), fs(TITLE), TITLE_COLOR, item.title, fade, cut)
				events[#events + 1] = text(tx, ry + px(19), fs(DETAIL), ACCENT, 'drop to move', fade, cut)
			end
			dragging.slot = drag_slot and (scroll + drag_slot) or nil
		end
		if #items > rows then
			local more = string.format('%d-%d of %d', scroll + 1, scroll + rows, #items)
			events[#events + 1] =
				text(f.right - pad - px(5) - cw - px(8), hy + head_h / 2, fs(DETAIL), DETAIL_COLOR, more, fade, nil, 6)
		end
	end

	local set_section -- (below)

	local function draw()
		local f = frame()
		local fade, slot = current_fade()
		-- the card's size, for music-info.lua's place in its panel
		local card = upcoming and { w = px(CARD_W), h = px(CARD_H) } or nil
		card_picture, card_text = nil, nil
		if not f or fade <= 0 or not upcoming then
			canvas:remove()
			hide_picture()
			box, hits = nil, {}
			set_section(false)
			mp.set_property_native('user-data/queue-panel', { shown = false, expanded = expanded, card = card })
			return
		end
		canvas.res_x, canvas.res_y = f.w, f.h
		local events = {}
		local place
		if expanded and #items > 0 then
			place = 'list'
			if slot then
				-- the list opens from the card where it was, in the song's panel
				f.right, f.base = slot.x + slot.w, slot.y + slot.h
				f.top = math.min(f.top, px(46))
			end
			draw_list(f, fade, events)
		elseif slot then
			place = 'slot'
			draw_card(fade, events, { x = slot.x, y = slot.y, w = slot.w, h = slot.h })
		else
			place = 'card'
			local w = math.min(px(CARD_W), f.right - px(GAP))
			local h = px(CARD_H)
			draw_card(fade, events, { x = f.right - w, y = f.base - h, w = w, h = h, boxed = true })
		end
		canvas.data = table.concat(events, '\n')
		canvas:update()
		if card_picture and fade >= 0.5 then
			show_picture(card_picture)
		else
			hide_picture()
		end
		local rows = {}
		for _, hit in ipairs(hits) do
			rows[#rows + 1] =
				{ what = hit.what, id = hit.id, x = hit.x0, y = hit.y0, w = hit.x1 - hit.x0, h = hit.y1 - hit.y0 }
		end
		mp.set_property_native('user-data/queue-panel', {
			shown = true,
			expanded = expanded,
			place = place,
			fade = fade,
			box = box and { x = box.x0, y = box.y0, w = box.x1 - box.x0, h = box.y1 - box.y0 } or nil,
			hits = rows,
			card = card,
			text = card_text,
			picture = overlay and { x = overlay.x, y = overlay.y, w = overlay.w, h = overlay.h } or nil,
		})
	end
	pictures.on_change(function()
		draw()
	end)

	local function keep_ui(on)
		if on ~= keeping_ui then
			keeping_ui = on
			mp.commandv(
				'script-message-to',
				'uosc',
				'set-min-visibility',
				on and '1' or '0',
				'timeline,controls,volume'
			)
		end
	end

	local function hit_at(pos)
		if not pos then
			return nil
		end
		for i = #hits, 1, -1 do
			local hit = hits[i]
			if pos.x >= hit.x0 and pos.x < hit.x1 and pos.y >= hit.y0 and pos.y < hit.y1 then
				return hit
			end
		end
	end

	local function inside(pos)
		return pos
			and box
			and pos.hover ~= false
			and pos.x >= box.x0
			and pos.x <= box.x1
			and pos.y >= box.y0
			and pos.y <= box.y1
	end

	local function collapse()
		if leave_timer then
			leave_timer:kill()
			leave_timer = nil
		end
		if pressed or dragging then
			return
		end
		expanded = false
		scroll = 0
		keep_ui(false)
		draw()
	end

	local on_mouse -- (below)

	--- A click can come before the mouse-pos observer heard of the move that led to it (a move and a press in the
	--- same instant): the pointer catches up first, so the hover, the boxes and the click agree.
	local function catch_up()
		local pos = mp.get_property_native('mouse-pos')
		if pos and (not pointer or pos.x ~= pointer.x or pos.y ~= pointer.y) then
			on_mouse(nil, pos)
		end
	end

	local function on_down()
		catch_up()
		local hit = hit_at(pointer)
		if hit and hit.what == 'row' then
			pressed = { id = hit.id, y = pointer.y }
		elseif hit then
			pressed = { what = hit.what, id = hit.id }
		end
	end

	local function on_up()
		catch_up()
		local was, drag = pressed, dragging
		pressed, dragging = nil, nil
		if drag then
			if drag.slot then
				actions.move(drag.id, drag.slot)
			end
			draw()
			return
		end
		local hit = hit_at(pointer)
		if not was or not hit then
			draw()
			return
		end
		if hit.what == 'card' and #items > 0 then
			expanded = true
			keep_ui(true)
		elseif hit.what == 'card' then
			-- the playlist's next local file: a click plays it now, as a row's does
			actions.next()
		elseif hit.what == 'clear' and was.what == 'clear' then
			actions.clear()
		elseif hit.what == 'remove' and was.what == 'remove' and was.id == hit.id then
			actions.remove(hit.id)
		elseif hit.what == 'row' and was.id == hit.id then
			actions.play(hit.id)
		end
		draw()
	end

	local function on_wheel(step)
		if expanded then
			scroll = scroll + step
			draw()
		end
	end

	set_section = function(on)
		if on == section_on and not on then
			return
		end
		section_on = on
		if on then
			mp.enable_key_bindings('queue-panel', 'allow-hide-cursor')
		else
			mp.disable_key_bindings('queue-panel')
		end
	end

	mp.set_key_bindings({
		{ 'mbtn_left', on_up, on_down },
		{ 'mbtn_left_dbl', function() end }, -- input.conf's fullscreen double click stays off the panel
		{
			'wheel_up',
			function()
				on_wheel(-1)
			end,
		},
		{
			'wheel_down',
			function()
				on_wheel(1)
			end,
		},
	}, 'queue-panel', 'force')

	on_mouse = function(_, pos)
		pointer = pos
		if not upcoming or current_fade() <= 0 then
			if over then
				over = false
				set_section(false)
			end
			return
		end
		if pressed and not dragging and pressed.y and pos and math.abs(pos.y - pressed.y) > DRAG_PX then
			dragging = { id = pressed.id }
		end
		local now = inside(pos) or dragging ~= nil
		if now then
			if leave_timer then
				leave_timer:kill()
				leave_timer = nil
			end
			-- the queue opens under the pointer; a local file's card has no list
			if not expanded and #items > 0 then
				expanded = true
				keep_ui(true)
			end
			set_section(true)
			-- uosc pushes its own click section whenever the pointer crosses one of its zones (banner-click.lua)
			mp.add_timeout(0.05, function()
				if over then
					set_section(true)
				end
			end)
		elseif over then
			set_section(false)
			if not leave_timer then
				leave_timer = mp.add_timeout(LEAVE_SECONDS, collapse)
			end
		end
		over = now
		draw()
	end

	mp.observe_property('user-data/uosc/bottom-ui', 'native', function(_, value)
		bottom = type(value) == 'table' and value or nil
		draw()
	end)
	mp.observe_property('user-data/uosc/ui-scale', 'number', function(_, value)
		scale = value and value > 0 and value or 1
		draw()
	end)
	mp.observe_property('osd-dimensions', 'native', function()
		draw()
	end)
	mp.observe_property('mouse-pos', 'native', on_mouse)
	mp.observe_property('user-data/music-info', 'native', function(_, value)
		music = type(value) == 'table' and value or nil
		draw()
	end)
	-- shown_fade() asks for a card first: something that becomes next in the last seconds shows at once, paused too
	mp.observe_property('time-remaining', 'number', function(_, left)
		local now = left ~= nil and left <= END_SECONDS
		if now ~= ending then
			ending = now
			draw()
		end
	end)

	local handle = {}

	--- The queue changed (main.lua): the items, the countdown, what was added last, what comes next.
	function handle.update(list, running, last, next_item)
		items, countdown, upcoming = list, running, next_item
		if last and (not added or last.at ~= added.at) and mp.get_time() - last.at < 1 then
			peek_until = mp.get_time() + PEEK_SECONDS
			if peek_timer then
				peek_timer:kill()
			end
			peek_timer = mp.add_timeout(PEEK_SECONDS + 0.05, draw)
		end
		added = last
		if #items == 0 then
			expanded, pressed, dragging = false, nil, nil
			keep_ui(false)
		end
		draw()
	end

	return handle
end
