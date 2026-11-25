-- queue/probe.lua - runs in the short hidden mpv picture.lua starts for the Up next card, never in the player (mpv
-- loads a script folder through its main.lua only): once the next file is open, and before mpv makes its decoders
-- (on_preloaded: a filter set later came too late for the first frame), it picks the picture (a video's frame, else a
-- song's cover), scales it to fit the card's box and writes what the card shows as JSON. That mpv then encodes the
-- one frame as raw BGRA (--o), and overlay-add shows it.

local mp = require('mp')
local utils = require('mp.utils')

local out = mp.get_opt('queue_probe-json')
local box_w = tonumber(mp.get_opt('queue_probe-w')) or 0
local box_h = tonumber(mp.get_opt('queue_probe-h')) or 0

local function tag(key)
	local v = mp.get_property('metadata/by-key/' .. key)
	return v and v:match('%S') and v or nil
end

mp.add_hook('on_preloaded', 50, function()
	local info = {
		duration = mp.get_property_number('duration'),
		title = tag('title'),
		artist = tag('artist'),
		album = tag('album'),
		audio = false,
	}
	-- a video's own track before a cover (an attached picture, a cover.jpg beside it)
	local pick
	for _, track in ipairs(mp.get_property_native('track-list') or {}) do
		if track.type == 'audio' then
			info.audio = true
		elseif
			track.type == 'video'
			and (tonumber(track['demux-w']) or 0) > 0
			and (tonumber(track['demux-h']) or 0) > 0
		then
			local still = (track.albumart or track.image) and true or false
			if not pick or (pick.still and not still) then
				pick = { track = track, still = still }
			end
		end
	end
	if pick and box_w > 0 and box_h > 0 then
		local track = pick.track
		local aspect = track['demux-w'] * (tonumber(track['demux-par']) or 1) / track['demux-h']
		-- the box's height, the width the picture's: a cover square, a frame 16:9, at most the box's width
		local h = box_h
		local w = math.floor(h * aspect + 0.5)
		if w > box_w then
			w = box_w
			h = math.floor(w / aspect + 0.5)
		end
		w, h = math.max(2, w), math.max(2, h)
		info.w, info.h, info.cover = w, h, pick.still
		mp.set_property_native('vid', track.id)
		mp.set_property('vf', string.format('scale=w=%d:h=%d,format=bgra', w, h))
		if not pick.still then
			-- a third in: past a title card or a black opening; a cover is the same everywhere
			mp.set_property('start', '33%')
		end
	end
	local file = out and io.open(out, 'w')
	if file then
		file:write(utils.format_json(info) or '{}')
		file:close()
	end
	if not info.w then
		-- no picture (a song without a cover): nothing to encode
		mp.command('quit 3')
	end
end)
