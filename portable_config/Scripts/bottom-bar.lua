-- bottom-bar.lua - what moves with uosc's bottom bar: the soft dark scrim the
-- controls sit on, and the subtitles, which rise above the bar while it shows.
--
-- 2026-10-02, design pass ("make the mpv design more modern and cohesive"):
--
-- The scrim. uosc draws each control as its own black square (uosc.conf
-- opacity controls=1, chosen so the buttons "sit IN the bar, not floating over
-- video") - over a picture that reads as a row of separate tiles. This draws
-- what modern players draw instead: one dark gradient behind the whole row,
-- from clear above the buttons to OLED black where uosc's (solid black)
-- timeline starts. The buttons themselves have no squares any more
-- (opacity controls=0); uosc gives every icon a dark outline (text_border) and
-- a hover highlight, so they stay readable on any picture. It fades in and out
-- exactly with uosc's bar: uosc publishes the bar's visibility and edges as
-- user-data/uosc/bottom-ui (a marked local change in uosc/main.lua, the one
-- music-info.lua uses).
--
-- The lift. mpv draws subtitles where they always are, and uosc's controls are
-- drawn over them: every mouse move covered the line being spoken (seen on the
-- 2026-10-02 screenshots - the subtitle sat behind the buttons). While the bar
-- shows - and while the sync tool's panel is open, which sits in the same
-- place - the subtitles move up to just above it, then back down with the fade:
--   - text subtitles (SRT, WebVTT - everything mpv styles itself): through
--     sub-margin-y-offset, the option mpv provides for exactly this ("dynamic
--     margin adjustments at runtime, e.g. by scripts like the OSC to avoid
--     subtitle/UI overlap"); mpv's own OSC uses it the same way
--   - ASS and picture subtitles (their own margins, which that option does not
--     touch): through sub-pos, on top of whatever the user set. libass moves
--     only bottom-aligned dialogue with it - signs and anything placed with
--     \pos stay where the typesetter put them. mpv.conf removes sub-pos from the
--     watch-later options, so a lifted position is never saved for a file.
--
-- State for tests: user-data/bottom-bar = {visibility, scrim (drawn: true),
-- lift_px (how far the subtitles were raised, real pixels), mode ('margin' |
-- 'pos' | nil), sub_pos (the user's own sub-pos, what it returns to)}.

local mp = require('mp')

-- Design units at a 720-line window, times uosc's interface scale - the same
-- units as notify.lua and uosc itself.
local FADE = 76 -- how far above the controls the scrim starts
local MAX_OPACITY = 0.88 -- at the timeline's top edge (the timeline is solid black)
local CURVE = 1.6 -- > 1: the darkness gathers low, behind the buttons
local STRIP = 2 -- the gradient is drawn in strips this tall
local GAP = 10 -- between the lifted subtitles and the bar
-- ASS/picture subtitles: their own bottom margin is unknown here (MarginV of
-- the file's styles); typical scripts sit 3-5 % above the frame's bottom, this
-- assumes the lower end so a line is rather lifted a little more than less.
local ASS_MARGIN = 0.02

local IMAGE_CODECS = { hdmv_pgs_subtitle = true, dvd_subtitle = true, dvb_subtitle = true, xsub = true }

local scrim = mp.create_osd_overlay('ass-events')
scrim.z = 900 -- under music-info's panel (1000) and uosc (2000)

local bottom = nil -- user-data/uosc/bottom-ui
local sync_panel = nil -- user-data/subtitle-sync's panel while the tool is open
local loaded = false

-- the user's own sub-pos (what the subtitles go back to) and what this script
-- last wrote, to tell its own writes from the user's
local user_pos = nil
local written_pos = nil
local applied = { lift = 0, mode = nil, offset = 0 }
local scrim_drawn = false

local function scale(h)
	local s = mp.get_property_number('user-data/uosc/ui-scale')
	if s and s > 0 then
		return s
	end
	return h / 720
end

---@return number|nil controls_top, number|nil timeline_top, number visibility  in this window's pixels
local function edges(h)
	if not bottom or not bottom.controls_top or not bottom.timeline_top then
		return nil, nil, 0
	end
	-- uosc reports in the pixels of the window size it last laid out
	local k = (bottom.height and bottom.height > 0) and h / bottom.height or 1
	return bottom.controls_top * k, bottom.timeline_top * k, math.max(0, math.min(1, bottom.visibility or 0))
end

local function publish()
	mp.set_property_native('user-data/bottom-bar', {
		visibility = bottom and bottom.visibility or 0,
		scrim = scrim_drawn,
		lift_px = applied.lift,
		mode = applied.mode,
		sub_pos = user_pos,
	})
end

-- ---- the scrim ---------------------------------------------------------------------

local function draw_scrim(w, h, k, controls_top, timeline_top, visibility)
	if not loaded or visibility <= 0 or not controls_top or controls_top >= h then
		scrim:remove()
		return false
	end
	local top = math.max(0, math.floor(controls_top - FADE * k))
	local stop = math.floor(timeline_top + 0.5)
	local strip = math.max(1, math.floor(STRIP * k + 0.5))
	local span = math.max(1, stop - top)
	local events = {}
	for y = top, stop - 1, strip do
		local t = (y + strip / 2 - top) / span
		local opacity = MAX_OPACITY * (t ^ CURVE) * visibility
		local alpha = math.floor((1 - opacity) * 255 + 0.5)
		if alpha < 255 then
			local y1 = math.min(y + strip, stop)
			events[#events + 1] = string.format(
				'{\\rDefault\\an7\\pos(0,0)\\blur0\\bord0\\shad0\\1c&H000000&\\1a&H%02X&\\p1}m 0 %d l %d %d %d %d 0 %d{\\p0}',
				alpha,
				y,
				w,
				y,
				w,
				y1,
				y1
			)
		end
	end
	scrim.res_x, scrim.res_y = w, h
	scrim.data = table.concat(events, '\n')
	scrim:update()
	return true
end

-- ---- the lift ----------------------------------------------------------------------

-- Takes over a sub-pos change this script did not make, as the user's own
-- position. Read before every write, not only in the observer: observer
-- notifications arrive later, and a change made just before the bar moved
-- would otherwise be overwritten unseen (the test caught that race).
local function adopt_user_pos()
	local current = mp.get_property_number('sub-pos')
	if not current then
		return
	end
	if written_pos == nil then
		user_pos = current
	elseif math.abs(current - written_pos) > 0.001 then
		-- a step made while lifted is a step from the user's own position
		user_pos = current + (applied.mode == 'pos' and applied.offset or 0)
		written_pos = nil
	end
end

local function set_pos(value)
	value = math.max(0, math.min(150, value))
	written_pos = value
	mp.set_property_number('sub-pos', value)
end

---@param mode string|nil 'margin', 'pos' or nil (nothing to lift)
---@param lift number real pixels
---@param offset number sub-margin-y-offset (scaled pixels) or sub-pos points
local function apply(mode, lift, offset)
	if applied.mode == 'margin' and mode ~= 'margin' then
		mp.set_property_number('sub-margin-y-offset', 0)
	end
	if applied.mode == 'pos' and mode ~= 'pos' and user_pos then
		set_pos(user_pos)
	end
	if mode == 'margin' then
		-- an integer option: a fractional number is rejected, not rounded
		offset = math.floor(offset + 0.5)
		mp.set_property_number('sub-margin-y-offset', offset)
	elseif mode == 'pos' and user_pos then
		set_pos(user_pos - offset)
	end
	applied = { lift = lift, mode = mode, offset = offset }
end

local function update_lift(h, dims, controls_top, visibility)
	adopt_user_pos()
	local track = mp.get_property_native('current-tracks/sub')
	local target = nil
	if controls_top and visibility > 0 then
		target = controls_top
	end
	-- the sync tool's panel sits where the controls are, whether they show or not
	if sync_panel and sync_panel.y0 then
		target = math.min(target or h, sync_panel.y0)
		visibility = 1
	end
	if not loaded or not track or not target or not mp.get_property_bool('sub-visibility', true) then
		apply(nil, 0, 0)
		return
	end
	local k = scale(h)
	target = target - GAP * k
	local codec = track.codec or ''
	if codec == 'ass' or codec == 'ssa' or IMAGE_CODECS[codec] then
		-- the libass frame of ASS/picture subtitles is the video, not the window
		-- (ass-use-margins=no): their bottom line sits a margin above the
		-- video's bottom edge, and sub-pos moves them by % of the video height
		local frame_h = h - (dims.mt or 0) - (dims.mb or 0)
		if frame_h <= 0 then
			apply(nil, 0, 0)
			return
		end
		local sub_bottom = h - (dims.mb or 0) - ASS_MARGIN * frame_h
		local lift = math.max(0, sub_bottom - target) * visibility
		if lift < 0.5 then
			apply(nil, 0, 0)
			return
		end
		apply('pos', lift, lift / frame_h * 100)
	else
		-- text subtitles: their bottom margin is sub-margin-y scaled pixels
		-- (720-line units, scaled with the window unless sub-scale-by-window=no)
		local per_px = mp.get_property_bool('sub-scale-by-window', true) and 720 / h or 1
		local margin = mp.get_property_number('sub-margin-y', 34) / per_px
		local lift = math.max(0, (h - target) - margin) * visibility
		if lift < 0.5 then
			apply(nil, 0, 0)
			return
		end
		apply('margin', lift, lift * per_px)
	end
end

-- ---- wiring ------------------------------------------------------------------------

local function update()
	local dims = mp.get_property_native('osd-dimensions') or {}
	local w, h = dims.w or 0, dims.h or 0
	if w <= 0 or h <= 0 then
		-- no OSD surface (--vo=null): nothing to draw; the lift still follows
		-- the bar's reported geometry, so it can be tested headless
		w, h = 0, bottom and bottom.height or 0
	end
	local controls_top, timeline_top, visibility = edges(h)
	scrim_drawn = w > 0 and draw_scrim(w, h, scale(h), controls_top, timeline_top, visibility) or false
	if h > 0 then
		update_lift(h, dims, controls_top, visibility)
	end
	publish()
end

mp.observe_property('user-data/uosc/bottom-ui', 'native', function(_, value)
	bottom = type(value) == 'table' and value or nil
	update()
end)
mp.observe_property('user-data/subtitle-sync', 'native', function(_, value)
	local panel = type(value) == 'table' and value.open and value.panel or nil
	if (panel and panel.y0) ~= (sync_panel and sync_panel.y0) then
		sync_panel = panel
		update()
	end
end)
mp.observe_property('sub-pos', 'number', function()
	-- the user (or a menu entry) moved the subtitles: that is the new
	-- position to come back to, and the lift goes on top of it
	local before = user_pos
	adopt_user_pos()
	if user_pos ~= before then
		if applied.mode == 'pos' then
			apply('pos', applied.lift, applied.offset)
		end
		publish()
	end
end)
for _, name in ipairs({ 'osd-dimensions', 'current-tracks/sub', 'sub-visibility' }) do
	mp.observe_property(name, 'native', update)
end
mp.register_event('file-loaded', function()
	loaded = true
	update()
end)
mp.register_event('end-file', function()
	loaded = false
	update()
end)
