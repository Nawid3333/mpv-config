-- video-info.lua - a small banner top right when a video starts: what it is
-- and how big it is.

local mp = require('mp')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

-- Long enough to read a three-part line.
local NOTE_SECONDS = 4

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

-- The bit depth in a pixel-format name ("10-bit"), nil when it carries none: a trailing "10le"/"16be" or bare number;
-- "nv12"/"nv16" end in digits that are no depth, and a one-off like rgb48's 48 is left unnamed.
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

---@return table|nil
local function video_track()
	for _, t in ipairs(mp.get_property_native('track-list') or {}) do
		if t.type == 'video' and t.selected and not t.albumart and not t.image then
			return t
		end
	end
	return nil
end

---@param path string
---@return boolean
local function faststream_tagged(path)
	return fragment.value(path, 'fs-content=') ~= nil
end

---@return string
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

-- The same file and picture are not worth a second banner (the observer fires on every change, nil -> table too).
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
	-- The banner belongs to its file: gone as soon as it unloads.
	mp.commandv('script-message-to', 'notify', 'hide', 'video-info')
end)
