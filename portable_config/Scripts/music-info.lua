-- music-info.lua - who and what is playing: "Artist – Title (feat. X)" in the
-- window title, and a black panel with every detail above uosc's bottom bar. Its
-- right column keeps a place (slot) for the queue's Up next card, which
-- queue/panel.lua draws there; without that card, a line names what plays next.

local mp = require('mp')
local utils = require('mp.utils')

local PAD = 14 -- left/right, like the banners' right margin
local TITLE_SIZE, ARTIST_SIZE, DETAIL_SIZE = 24, 16, 12
local WHITE, SOFT, GREY = 'FFFFFF', 'DCDCDC', 'B4B4B4'
local GAP = 24 -- between the left column and the right one
-- Segoe UI (osd-font) has a 1.19x taller line box than the Arial the sizes were designed with (uosc, notify: same).
local FONT_SCALE = 1.19

---@param s string
---@return string
local function trim(s)
	return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param key string
---@return string|nil
local function tag(key)
	local v = mp.get_property('metadata/by-key/' .. key)
	return v and trim(v) ~= '' and trim(v) or nil
end

-- Several ARTIST tags arrive joined with ";" (FFmpeg). Not split on "/" or "&":
-- AC/DC, Simon & Garfunkel.
---@param s string|nil
---@return string|nil
local function artist_list(s)
	if not s then
		return nil
	end
	local parts = {}
	for part in s:gmatch('[^;]+') do
		if trim(part) ~= '' then
			parts[#parts + 1] = trim(part)
		end
	end
	return #parts > 0 and table.concat(parts, ', ') or nil
end

-- Longest first. A marker needs a space or bracket before it and a space
-- after it, so "Soft Cell" or "Aftermath" never split.
local MARKERS = { 'featuring', 'feat%.', 'feat', 'ft%.', 'ft' }

--- "X feat. Y" / "X (feat. Y) [Remix]" / "X [ft. Y]" -> "X" / "X [Remix]", "Y".
---@param s string
---@return string main, string|nil featured
local function split_feat(s)
	local lower = s:lower() -- same byte positions: only ASCII letters change
	for _, marker in ipairs(MARKERS) do
		local a, b = lower:find('%s*[%(%[]%s*' .. marker .. '%s+')
		if a then
			local close = lower:find('[%)%]]', b + 1) or (#s + 1)
			return trim(s:sub(1, a - 1) .. s:sub(close + 1)), trim(s:sub(b + 1, close - 1))
		end
		a, b = lower:find('%s+' .. marker .. '%s+')
		if a then
			return trim(s:sub(1, a - 1)), trim(s:sub(b + 1))
		end
	end
	return s, nil
end

--- The given values that are not nil/false, in order (ipairs over a table literal stops at the first nil).
---@return string[]
local function present(...)
	local list = {}
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if v then
			list[#list + 1] = v
		end
	end
	return list
end

local SEPARATORS = { ' - ', ' – ', ' — ' }

--- "Artist - Title", "01 - Artist - Title", "01. Artist - Title" -> artist, title;
--- "07 - Title" -> no artist, title.
---@param name string
---@return string|nil artist, string title
local function from_name(name)
	name = trim((name:gsub('_', ' ')))
	local parts = { name }
	for _, sep in ipairs(SEPARATORS) do
		if name:find(sep, 1, true) then
			parts = {}
			local rest = name
			local i = rest:find(sep, 1, true)
			while i do
				parts[#parts + 1] = rest:sub(1, i - 1)
				rest = rest:sub(i + #sep)
				i = rest:find(sep, 1, true)
			end
			parts[#parts + 1] = rest
			break
		end
	end
	if #parts >= 3 and parts[1]:match('^%d+$') then
		table.remove(parts, 1)
	end
	-- bare track number + title: no artist. One or two digits only, so a band
	-- named with a number ("311 - Amber") keeps its name.
	if #parts == 2 and trim(parts[1]):match('^%d%d?$') then
		return nil, trim(parts[2])
	end
	parts[1] = parts[1]:gsub('^%d+%.%s+', '')
	if #parts == 1 then
		return nil, trim(parts[1])
	end
	return trim(parts[1]), trim(table.concat(parts, ' - ', 2))
end

---@param a string|nil
---@param b string|nil
---@return string|nil
local function join(a, b, sep)
	if a and b then
		return a .. sep .. b
	end
	return a or b
end

--- "4/14" or "4" plus a separate total tag -> "Track 4 of 14".
---@param word string
---@param value string|nil
---@param total string|nil
---@param only_if_several boolean|nil
---@return string|nil
local function numbered(word, value, total, only_if_several)
	local n, of = (value or ''):match('^%s*(%d+)%s*/?%s*(%d*)')
	if not n then
		return nil
	end
	of = of ~= '' and of or (total and total:match('%d+'))
	if only_if_several and tonumber(n) <= 1 and (not of or tonumber(of) <= 1) then
		return nil
	end
	return word .. ' ' .. tonumber(n) .. (of and (' of ' .. tonumber(of)) or '')
end

local CODECS = {
	mp3 = 'MP3',
	aac = 'AAC',
	flac = 'FLAC',
	alac = 'ALAC',
	opus = 'Opus',
	vorbis = 'Vorbis',
	wavpack = 'WavPack',
	ape = 'APE',
	tta = 'TTA',
	ac3 = 'AC-3',
	eac3 = 'E-AC-3',
	dts = 'DTS',
	wmav2 = 'WMA',
}

--- "FLAC · 44.1 kHz · Stereo · 912 kbps"
---@return string|nil
local function audio_format()
	local a = mp.get_property_native('current-tracks/audio')
	if not a then
		return nil
	end
	local codec = a.codec or ''
	local parts = { CODECS[codec] or (codec:match('^pcm') and 'PCM') or codec:upper() }
	local rate = a['demux-samplerate']
	if rate then
		parts[#parts + 1] = string.format('%g kHz', math.floor(rate / 100 + 0.5) / 10)
	end
	local channels = a['demux-channel-count']
	if channels then
		parts[#parts + 1] = channels == 1 and 'Mono' or channels == 2 and 'Stereo' or (a['demux-channels'] or '')
	end
	local bitrate = a['demux-bitrate'] or mp.get_property_number('audio-bitrate')
	if bitrate and bitrate > 0 then
		parts[#parts + 1] = math.floor(bitrate / 1000 + 0.5) .. ' kbps'
	end
	return table.concat(parts, ' · ')
end

--- What plays next: "Artist – Title" (from the playlist entry's title or file name).
---@return string|nil next, string|nil position
local function playlist_info()
	local pos, count = mp.get_property_number('playlist-pos', -1), mp.get_property_number('playlist-count', 0)
	local position = count > 1 and pos >= 0 and string.format('%d / %d', pos + 1, count) or nil
	if pos < 0 or pos + 1 >= count then
		return nil, position
	end
	local entry = mp.get_property_native('playlist/' .. (pos + 1)) or {}
	if entry.title then
		return entry.title, position
	end
	local _, file = utils.split_path(entry.filename or '')
	local artist, title = from_name((file:gsub('%.[^.]+$', '')))
	return join(artist, title, ' – '), position
end

---@return boolean audio, boolean cover
local function kind()
	if not mp.get_property_native('current-tracks/audio') then
		return false, false
	end
	local video = mp.get_property_native('current-tracks/video')
	if not video then
		return true, false
	end
	if video.albumart or video.image then
		return true, true
	end
	return false, false
end

---@return table|nil
local function read_song()
	local audio, cover = kind()
	local title, artist = tag('title'), artist_list(tag('artist'))
	local tagged_artist = artist ~= nil
	local file_artist, file_title = from_name(mp.get_property('filename/no-ext') or '')
	if not title then
		local icy = tag('icy-title') -- a radio stream's "Artist - Title"
		if icy then
			artist, title = from_name(icy)
		elseif audio then
			-- the file name's title; its artist only where no ARTIST tag names one
			artist, title = artist or file_artist, file_title
		end
	elseif not artist and file_artist and file_title:lower():find(title:lower(), 1, true) then
		artist = file_artist -- file name's title part matches the tag: trust its artist part
	end
	artist = artist or artist_list(tag('album_artist'))
	-- videos: only with an artist TAG (music videos); a film's file name stays
	if not audio and not (tagged_artist and title) then
		return nil
	end
	title = title or file_title

	local feats, seen = {}, {}
	local function add(list)
		for name in (list or ''):gmatch('[^,]+') do
			name = trim(name)
			if name ~= '' and not seen[name:lower()] then
				seen[name:lower()] = true
				feats[#feats + 1] = name
			end
		end
	end
	local feat
	if artist then
		artist, feat = split_feat(artist)
		add(feat)
	end
	title, feat = split_feat(title)
	add(feat)
	local featured = #feats > 0 and table.concat(feats, ', ') or nil

	local album, album_artist = tag('album'), artist_list(tag('album_artist'))
	if album and album_artist and album_artist:lower() ~= (artist or ''):lower() then
		album = album .. ' — ' .. album_artist
	end
	local details = present(
		album,
		((tag('date') or tag('year') or tag('originaldate') or ''):match('%d%d%d%d')),
		numbered('Track', tag('track') or tag('tracknumber'), tag('tracktotal') or tag('totaltracks')),
		numbered('Disc', tag('disc') or tag('discnumber'), tag('disctotal') or tag('totaldiscs'), true),
		tag('genre')
	)
	local credits = {}
	if tag('composer') then
		credits[#credits + 1] = 'Composer: ' .. tag('composer')
	end
	local label = tag('label') or tag('publisher') or tag('organization')
	if label then
		credits[#credits + 1] = 'Label: ' .. label
	end

	return {
		audio = audio,
		cover = cover,
		title = title,
		artist = artist,
		featured = featured,
		details = #details > 0 and table.concat(details, ' · ') or nil,
		credits = #credits > 0 and table.concat(credits, ' · ') or nil,
		-- no artist found anywhere: the title bar keeps mpv's own title
		window_title = artist and (artist .. ' – ' .. title .. (featured and (' (feat. ' .. featured .. ')') or '')),
	}
end

local song = nil ---@type table|nil

local function set_title()
	if song and song.window_title then
		-- the title option expands ${...}: a literal $ is $$
		mp.set_property('file-local-options/title', song.window_title:gsub('%$', '$$') .. ' - mpv')
	end
end

local panel = mp.create_osd_overlay('ass-events')
panel.z = 1000 -- under uosc (2000): its buttons draw on the panel, its menus over it
local meter = mp.create_osd_overlay('ass-events')
meter.hidden = true
meter.compute_bounds = true

local bottom = nil -- user-data/uosc/bottom-ui
local shown = 0
local card = nil -- user-data/queue-panel/card: the Up next card's size {w, h}, when there is one
local slot = nil -- where the panel keeps the card's place: {x, y, w, h}
local column = nil -- the right column's lines as drawn last

-- A backslash gets a zero-width no-break space after it (as mpv's osc.lua
-- does), braces are escaped: a title can never start an override tag.
---@param s string
---@return string
local function ass_escape(s)
	return (s:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('[\r\n]+', ' '))
end

---@return string
local function text(x, y, align, size, color, alpha, str, clip)
	return string.format(
		'{\\rDefault\\an%d\\pos(%d,%d)\\q2\\blur0\\bord0\\shad0\\fs%d\\1c&H%s&\\alpha&H%s&%s}%s',
		align,
		x,
		y,
		math.floor(size * FONT_SCALE + 0.5),
		color,
		alpha,
		clip or '',
		str
	)
end

-- Measured on the panel's own canvas (the window in real pixels): libass sizes text by window height over res_y,
-- and on any other canvas every line measures h/720 times its real width.
---@param str string
---@param size number
---@param res_x number
---@param res_y number
---@return number
local function text_width(str, size, res_x, res_y)
	meter.res_x, meter.res_y = res_x, res_y
	meter.data = text(0, 0, 7, size, WHITE, '00', ass_escape(str))
	local bounds = meter:update()
	if type(bounds) == 'table' and bounds.x1 and bounds.x0 then
		return bounds.x1 - bounds.x0
	end
	return #str * size * 0.55
end

local function publish()
	local s = song
	if not s then
		mp.set_property_native('user-data/music-info', {})
		return
	end
	mp.set_property_native('user-data/music-info', {
		audio = s.audio,
		cover = s.cover,
		title = s.title,
		artist = s.artist,
		featured = s.featured,
		details = s.details,
		credits = s.credits,
		window_title = s.window_title,
		format = s.audio and audio_format() or nil,
		next = s.audio and (playlist_info()) or nil,
		visibility = shown,
		slot = slot,
		column = column,
	})
end

local function draw()
	local s = song
	local visibility = 0
	if s and s.audio then
		visibility = s.cover and (bottom and bottom.visibility or 0) or 1
	end
	shown = visibility
	local w, h = mp.get_osd_size()
	if not s or visibility <= 0 or not w or w <= 0 or h <= 0 then
		slot, column = nil, nil
		publish()
		panel:remove()
		return
	end
	-- uosc's interface scale (window height / 720 until it reports): the panel keeps uosc's physical size.
	local k = mp.get_property_number('user-data/uosc/ui-scale', h / 720)
	local function px(v)
		return math.floor(v * k + 0.5)
	end
	local pad = px(PAD)
	-- uosc's bottom bar is drawn in real pixels; its edges are moved from the
	-- window height it published to this one (the usual case: same window).
	local reported_h = bottom and bottom.height or nil
	local to_draw = bottom and reported_h and reported_h > 0 and h / reported_h or 1
	-- +1: the box is drawn in whole canvas units; rounding down leaves a 1 px
	-- line of the cover between the panel and uosc's timeline
	local timeline_top = bottom and math.ceil(bottom.timeline_top * to_draw) + 1 or h
	local controls_top = bottom and math.ceil(bottom.controls_top * to_draw) or timeline_top
	local alpha = string.format('%02X', math.floor((1 - visibility) * 255 + 0.5))

	-- right column: format, what plays next (the queue's card under the lines, else a line), playlist position
	local next_title, position = playlist_info()
	local card_w = card and math.min(math.floor(tonumber(card.w) or 0), math.floor(w * 0.45)) or 0
	local card_h = card and math.floor(tonumber(card.h) or 0) or 0
	local with_card = card_w > 0 and card_h > 0
	local right = present(
		audio_format(),
		not with_card and next_title and ('Up next: ' .. next_title) or nil,
		position and ('Playlist ' .. position)
	)
	local right_w = with_card and card_w or 0
	for _, line in ipairs(right) do
		right_w = math.max(right_w, text_width(line, px(DETAIL_SIZE), w, h))
	end

	-- left column, top to bottom: title, artist (+ feat.), details, credits
	local has_artist = s.artist or s.featured
	local rows = px(10 + 30)
		+ (has_artist and px(22) or 0)
		+ (s.details and px(17) or 0)
		+ (s.credits and px(17) or 0)
		+ px(8)
	local lines_h = px(14) + #right * px(17)
	if with_card then
		rows = math.max(rows, lines_h + px(6) + card_h + px(8))
	end
	local top = controls_top - rows
	local left_edge = w - pad - math.ceil(right_w) - (right_w > 0 and px(GAP) or 0)
	local clip = string.format('\\clip(%d,%d,%d,%d)', pad, top, left_edge, controls_top)

	local events = {
		string.format(
			'{\\rDefault\\an7\\pos(0,0)\\blur0\\bord0\\shad0\\1c&H000000&\\alpha&H%s&\\p1}m 0 %d l %d %d %d %d 0 %d{\\p0}',
			alpha,
			top,
			w,
			top,
			w,
			timeline_top,
			timeline_top
		),
	}
	local y = top + px(10)
	events[#events + 1] = text(pad, y, 7, px(TITLE_SIZE), WHITE, alpha, ass_escape(s.title), clip)
	y = y + px(30)
	if has_artist then
		local artist = s.artist and ass_escape(s.artist) or ''
		if s.featured then
			artist = artist
				.. string.format('{\\1c&H%s&}%sfeat. %s', GREY, s.artist and '  ' or '', ass_escape(s.featured))
		end
		events[#events + 1] = text(pad, y, 7, px(ARTIST_SIZE), SOFT, alpha, artist, clip)
		y = y + px(22)
	end
	for _, line in ipairs({ s.details or false, s.credits or false }) do
		if line then
			events[#events + 1] = text(pad, y, 7, px(DETAIL_SIZE), GREY, alpha, ass_escape(line), clip)
			y = y + px(17)
		end
	end
	for i, line in ipairs(right) do
		events[#events + 1] =
			text(w - pad, top + px(14) + (i - 1) * px(17), 9, px(DETAIL_SIZE), GREY, alpha, ass_escape(line))
	end

	slot = with_card and { x = w - pad - card_w, y = top + lines_h + px(6), w = card_w, h = card_h } or nil
	column = right
	publish()
	panel.res_x, panel.res_y = w, h
	panel.data = table.concat(events, '\n')
	panel:update()
end

local function refresh()
	song = read_song()
	set_title()
	draw()
end

mp.register_event('file-loaded', refresh)
mp.register_event('end-file', function()
	song = nil
	draw()
end)
-- tags can change while playing (radio streams), a cover can arrive late
for _, name in ipairs({ 'metadata', 'current-tracks/video' }) do
	mp.observe_property(name, 'native', function()
		if mp.get_property('path') then
			refresh()
		end
	end)
end
for _, name in ipairs({ 'osd-dimensions', 'playlist-pos', 'playlist-count' }) do
	mp.observe_property(name, 'native', function()
		if song then
			draw()
		end
	end)
end
mp.observe_property('user-data/uosc/bottom-ui', 'native', function(_, value)
	bottom = type(value) == 'table' and value or nil
	if song then
		draw()
	end
end)
-- The queue's card: the panel redraws on every music-info change, so only a new size may redraw here (no loop). The
-- whole table is observed: a card gone is a key gone from it, and that must reach here too.
mp.observe_property('user-data/queue-panel', 'native', function(_, value)
	local new = type(value) == 'table' and type(value.card) == 'table' and value.card or nil
	local same = (new and new.w) == (card and card.w) and (new and new.h) == (card and card.h)
	card = new
	if not same and song then
		draw()
	end
end)

publish()
