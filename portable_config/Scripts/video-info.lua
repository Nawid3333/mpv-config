-- video-info.lua - a small banner top right when a video starts: what it is
-- and how big it is.
--
-- 2026-09-28, at the user's request: "when the MPV video starts ... a small
-- banner shown on the right for a short amount of time. What resolution is the
-- video or the stream". It draws with the same notify.lua banners as every
-- other message in this setup (nothing of its own), and disappears by itself
-- after NOTE_SECONDS like they all do.
--
-- Title: the resolution as the picture is shown, e.g. "1280x720" - dwidth/
-- dheight (aspect-corrected, what is actually on screen), rotation applied,
-- which plain video-params/w/h would not be. Detail line, in order, only what
-- is known, " · " between:
--   the codec (h264 -> H.264, hevc -> HEVC, ...)
--   the pixel depth, the same word the compiling banner uses ("8-bit",
--   "10-bit"); from hw-pixelformat when hardware decoding is zero-copy (the
--   copied format), pixelformat otherwise - pixelformat alone would say "vulkan"
--   the source: "FastStream" (the same #fs-content= marker gpu-toggles.lua and
--   stream-resume.lua read from path), "stream" for any other URL, "local file"
--
-- When: on video-params, the property that arrives with the first decoded
-- frame - at file-loaded the decoder has not spoken yet, so a banner fired
-- there would miss on streams and only get the container's guess. The same
-- property re-fires when a stream changes its parameters mid-play, which
-- re-shows the banner with the new size (replaced in place, never stacked).
-- Songs get no banner: their "video" is cover art (track-list albumart/image),
-- and a cover's size is not what anyone wants to know.

local mp = require('mp')

-- The banner stays long enough to read a three-part line, then out of the way.
local NOTE_SECONDS = 4

-- The codec names mpv's properties use -> the short names a viewer knows.
local CODECS = {
	h264 = 'H.264',
	hevc = 'HEVC',
	mpeg2video = 'MPEG-2',
	mpeg4 = 'MPEG-4',
	vp9 = 'VP9',
	av1 = 'AV1',
	vc1 = 'VC-1',
	mjpeg = 'MJPEG',
}

-- The bit depth in a pixel-format name, as the compiling banner says it:
-- "8-bit" for the usual 8-bit formats, "10-bit"/"12-bit"/"16-bit" for the
-- deeper ones, nil for a name that holds none of it. The depth token is the
-- trailing "10le"/"16be"-style number or bare "10"/"16" (mpv reports native
-- endianness: "yuv420p10", "p010", "y412"). "nv12"/"nv16" also end in two
-- digits that are NOT a depth, so the nv family is excluded, and a one-off
-- depth like rgb48's 48 is left unnamed rather than guessed.
---@param pixelformat string|nil
---@return string|nil
local function bits_of(pixelformat)
	if not pixelformat then
		return nil
	end
	local n = tonumber(pixelformat:match('(%d%d)l?[be]$'))
	if not n and pixelformat:sub(1, 2) ~= 'nv' then
		n = tonumber(pixelformat:match('(%d%d)$'))
	end
	if not n then
		return '8-bit' -- nv12, yuv420p, bgr0 ...: the name carries no depth token
	end
	if n < 10 or n > 16 then
		return nil
	end
	return n .. '-bit'
end

--- The track that is being shown as the picture, or nil: a song, or no video.
---@return table|nil
local function video_track()
	for _, t in ipairs(mp.get_property_native('track-list') or {}) do
		if t.type == 'video' and t.selected and not t.albumart and not t.image then
			return t
		end
	end
	return nil
end

-- The source line. `path` is the full URL for a stream and the local path
-- otherwise (the same string the FastStream markers arrive in either way).
---@return string
-- FastStream's tag: a whole fs-content= item of the URL fragment, as gpu-toggles,
-- stream-resume and source-info read theirs (FastStream #155) - not the text
-- anywhere in the address, which a site's own query can hold (review, 2026-10-09).
-- Plain string compares: a stray "%" in the path never starts a Lua pattern class.
local function faststream_tagged(path)
	local hash = path:find('#', 1, true)
	if not hash then
		return false
	end
	for item in (path:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
		if item:sub(1, 11) == 'fs-content=' then
			return true
		end
	end
	return false
end

local function source_of()
	local path = mp.get_property('path') or ''
	if faststream_tagged(path) then
		return 'FastStream'
	end
	if path:find('://', 1, true) then
		return 'stream'
	end
	return 'local file'
end

--- "1280x720", "H.264 · 8-bit · local file" - or nil while there is nothing
--- to say: no video track yet, or no decoded size yet.
---@return string|nil title, string|nil detail
local function describe()
	local track = video_track()
	if not track then
		return nil
	end
	local params = mp.get_property_native('video-params')
	local w, h = params and params.dw or nil, params and params.dh or nil
	if not w or not h or w <= 0 or h <= 0 then
		return nil
	end
	local rotate = params.rotate or 0
	if rotate % 180 == 90 then
		w, h = h, w
	end
	local parts = {}
	local codec = track.codec or ''
	if codec ~= '' then
		parts[#parts + 1] = CODECS[codec] or codec:upper()
	end
	local bits = bits_of(params['hw-pixelformat'] or params.pixelformat)
	if bits then
		parts[#parts + 1] = bits
	end
	parts[#parts + 1] = source_of()
	return w .. 'x' .. h, table.concat(parts, ' · ')
end

-- What the last banner said; the same file and the same picture are not worth
-- a second banner (the observer fires once per parameter change, including the
-- nil -> table one every new file makes).
---@type {path: string, title: string, detail: string}|nil
local announced = nil

local function announce()
	local path = mp.get_property('path')
	if not path then
		return
	end
	local title, detail = describe()
	if not title then
		return
	end
	detail = detail or '' -- always a string: a video always names its source
	if announced and announced.path == path and announced.title == title and announced.detail == detail then
		return
	end
	announced = { path = path, title = title, detail = detail }
	-- A banner with the same id is replaced where it stands (Scripts/notify.lua).
	mp.commandv('script-message-to', 'notify', 'show', 'video-info', title, detail, tostring(NOTE_SECONDS))
end

mp.observe_property('video-params', 'native', announce)

mp.register_event('end-file', function()
	announced = nil
	-- The banner belongs to its file: gone as soon as it unloads (the next
	-- video's own banner would replace it anyway; a song's would not).
	mp.commandv('script-message-to', 'notify', 'hide', 'video-info')
end)
