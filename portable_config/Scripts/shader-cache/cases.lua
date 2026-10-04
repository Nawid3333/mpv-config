-- cases.lua - what real playback needed that the warm-up's fixed clip list does
-- not draw, learned automatically (2026-10-02). Shared by main.lua (records a
-- case at every real miss) and warmup.lua (replays every case in each full
-- warm-up). Loaded with dofile(), like fingerprint.lua.
--
-- Why: the capture (main.lua, shader-misses.log) shows each shader real
-- playback still had to compile, and until now a person read that log about
-- once a month and added each gap to warmup.lua's matrix by hand. The log
-- holds the titles of what was watched, so it was only ever opened with the
-- user's go-ahead. A miss is already in the cache once it happened - the
-- moment that matters is LATER: a new GPU driver or libplacebo makes every
-- cached shader stale, and the warm-up then rebuilds only what its matrix
-- draws. So each miss is also stored here as a CASE, everything that decides
-- which shaders run and nothing that names a file:
--   w, h        source size                  pix, hwpix  pixel format (+ the
--   matrix, primaries, gamma, levels         decoder's surface format)
--   hwdec       the decoder path really used ('d3d11va-copy', 'no'; 'vulkan' in
--               cases recorded before 2026-10-04, replayed as d3d11va-copy)
--   chain       'off' | 'anime' | 'movie', sharpen (Movie's curve_height)
--   ratio       the displayed size / the source size (window, fullscreen,
--               zoom - it picks scaler passes and their kernel size)
--   idle        mpv's empty window (no video)
-- and every full warm-up replays every case: a 1 s clip made with mpv's own
-- encoder in exactly that format and those colour tags (verified: mpv reads
-- them back as the same video-params), decoded the same way, drawn through
-- the same chain at the same scale (video-zoom), next to the fixed matrix.
-- The file is title-free on purpose, so it can be read at any time.
--
-- ~~state/shader-cases.json:
--   { version = 1, imported = <date the old log was imported>,
--     last_gap = <date of the newest case>, cases = { <case>, ... } }
-- each case also has key, count (misses seen), first, last (dates).
local utils = require('mp.utils')

local M = {}

M.FILE = mp.command_native({ 'expand-path', '~~state/shader-cases.json' })
M.LOG = mp.command_native({ 'expand-path', '~~state/shader-misses.log' })
-- replayed per warm-up, newest first: a bound on the warm-up's time
M.MAX_REPLAY = 40

local KEY_FIELDS = {
	'idle',
	'w',
	'h',
	'pix',
	'hwpix',
	'matrix',
	'primaries',
	'gamma',
	'levels',
	'hwdec',
	'chain',
	'sharpen',
	'ratio',
}

-- 'Movie (FSRCNNX+SSimSuperRes), sharpen 0.5' / 'Anime' / 'no upscaler'
---@param label string
---@return string chain, number|nil sharpen
function M.parse_chain(label)
	label = label or ''
	local sharpen = tonumber(label:match('sharpen ([%d.]+)'))
	if label:find('^Movie') then
		return 'movie', sharpen
	elseif label:find('^Anime') then
		return 'anime', nil
	end
	return 'off', nil
end

--- The case for what is on screen now (nil fields where mpv knows nothing).
---@param chain_label string main.lua's chain_label()
---@return table
function M.current(chain_label)
	local vp = mp.get_property_native('video-params')
	if not vp or not vp.w then
		return { idle = true }
	end
	local d = mp.get_property_native('osd-dimensions') or {}
	local ratio = nil
	local dw, dh = vp.dw or vp.w, vp.dh or vp.h
	if d.w and d.w > 0 and dw > 0 and dh > 0 then
		local vw = d.w - (d.ml or 0) - (d.mr or 0)
		local vh = d.h - (d.mt or 0) - (d.mb or 0)
		ratio = math.min(vw / dw, vh / dh)
	end
	local chain, sharpen = M.parse_chain(chain_label)
	return {
		w = vp.w,
		h = vp.h,
		pix = vp.pixelformat,
		hwpix = vp['hw-pixelformat'],
		matrix = vp.colormatrix,
		primaries = vp.primaries,
		gamma = vp.gamma,
		levels = vp.colorlevels,
		hwdec = mp.get_property('hwdec-current', 'no'),
		chain = chain,
		sharpen = sharpen,
		ratio = ratio,
	}
end

-- ratio to 2 decimals: a window a few pixels bigger is the same case
local function norm(case)
	if case.ratio then
		case.ratio = math.floor(case.ratio * 100 + 0.5) / 100
	end
	if case.hwdec == '' then
		case.hwdec = 'no'
	end
	return case
end

---@param case table
---@return string
function M.key(case)
	local parts = {}
	for _, k in ipairs(KEY_FIELDS) do
		parts[#parts + 1] = tostring(case[k] == nil and '' or case[k])
	end
	return table.concat(parts, '|')
end

function M.load()
	local f = io.open(M.FILE, 'r')
	local data = nil
	if f then
		data = utils.parse_json(f:read('*a') or '')
		f:close()
	end
	if type(data) ~= 'table' or type(data.cases) ~= 'table' then
		data = { version = 1, cases = {} }
	end
	return data
end

-- One case per line, so the file reads well in an editor (it is title-free
-- on purpose: safe to open at any time).
function M.save(data)
	local head = {}
	for k, v in pairs(data) do
		if k ~= 'cases' then
			head[k] = v
		end
	end
	local json = utils.format_json(head)
	if not json then
		return false
	end
	local lines = {}
	for _, c in ipairs(data.cases) do
		local one = utils.format_json(c)
		if one then
			lines[#lines + 1] = '  ' .. one
		end
	end
	json = json:gsub('}$', '') .. (json == '{}' and '' or ',') .. '"cases":[\n' .. table.concat(lines, ',\n') .. '\n]}'
	local tmp = M.FILE .. '.tmp'
	local f = io.open(tmp, 'w')
	if not f then
		return false
	end
	f:write(json, '\n')
	f:close()
	os.remove(M.FILE) -- rename does not replace on Windows
	return os.rename(tmp, M.FILE) == true
end

--- Adds (or counts again) cases; returns how many were NEW.
---@param data table M.load()'s result, changed in place
---@param list table[]
---@param when string date
---@return integer
function M.merge(data, list, when)
	local by_key = {}
	for _, c in ipairs(data.cases) do
		by_key[c.key] = c
	end
	local new = 0
	for _, case in ipairs(list) do
		norm(case)
		case.key = M.key(case)
		local known = by_key[case.key]
		if known then
			known.count = (known.count or 1) + 1
			known.last = when
		else
			case.count, case.first, case.last = 1, when, when
			data.cases[#data.cases + 1] = case
			by_key[case.key] = case
			new = new + 1
			if not data.last_gap or when > data.last_gap then
				data.last_gap = when
			end
		end
	end
	return new
end

-- ---- the old log, imported once ---------------------------------------------------

-- '1920x1080 yuv420p h264 bt.709/bt.1886, decoder d3d11va-copy'
-- '1280x720 vulkan/nv12 h264 bt.709/bt.1886, decoder vulkan'
local function parse_video(field)
	local w, h, pix, matrix, gamma, dec = field:match('^(%d+)x(%d+) (%S+) %S+ ([^/%s]+)/(%S+), decoder (%S+)$')
	if not w then
		return nil
	end
	local p, hp = pix:match('^([^/]+)/(.+)$')
	return {
		w = tonumber(w),
		h = tonumber(h),
		pix = p or pix,
		hwpix = hp,
		matrix = matrix ~= '?' and matrix or nil,
		gamma = gamma ~= '?' and gamma or nil,
		hwdec = dec,
	}
end

--- One context of a log line ("title | video | chain | 1920x1080 window") as
--- a case; the title is dropped. Split from the right: a title may hold '|'.
local function parse_context(ctx)
	local parts = {}
	for part in (ctx .. ' | '):gmatch('(.-) | ') do
		parts[#parts + 1] = part
	end
	if #parts < 4 then
		return nil
	end
	local video, chain_label, out = parts[#parts - 2], parts[#parts - 1], parts[#parts]
	local chain, sharpen = M.parse_chain(chain_label)
	if video == 'no video' then
		return { idle = true }
	end
	local case = parse_video(video)
	if not case then
		return nil
	end
	local ow, oh = out:match('^(%d+)x(%d+)')
	ow, oh = tonumber(ow), tonumber(oh)
	if ow and oh and ow > 0 and case.w > 0 and case.h > 0 then
		case.ratio = math.min(ow / case.w, oh / case.h)
	end
	case.chain, case.sharpen = chain, sharpen
	return case
end

--- The cases in shader-misses.log's real gaps: lines marked [cache fresh] or
--- [cache done] (a [cache stale] line only means the warm-up had not run).
--- A line with "(before: ...)" gives both states - the compile may belong to
--- either. Titles never leave this function.
---@param path string
---@return table[] cases, table[] dates
function M.read_log(path)
	local f = io.open(path, 'r')
	if not f then
		return {}, {}
	end
	local list, dates = {}, {}
	for line in f:lines() do
		local date, rest = line:match('^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)  %+%d+  (.*)$')
		local cache = rest and rest:match('%[cache (%S+)%]%s*$')
		if cache == 'fresh' or cache == 'done' then
			rest = rest:gsub('%s*%[cache %S+%]%s*$', '')
			local ctx, before = rest:match('^(.-)  %(before: (.*)%)$')
			for _, c in ipairs({ ctx or rest, before or false }) do
				local case = c and parse_context(c)
				if case then
					list[#list + 1] = case
					dates[#dates + 1] = date
				end
			end
		end
	end
	f:close()
	return list, dates
end

--- Imports the log into the cases file (each line under its own date).
---@param data table
---@return integer new cases
function M.import_log(data, path)
	local list, dates = M.read_log(path or M.LOG)
	local new = 0
	for i, case in ipairs(list) do
		new = new + M.merge(data, { case }, dates[i])
	end
	data.imported = os.date('%Y-%m-%d %H:%M:%S')
	return new
end

-- ---- replaying a case (warmup.lua) -------------------------------------------------

-- mpv's names -> FFmpeg's (setparams / the encoders' VUI options)
local MATRIX = {
	['bt.601'] = 'smpte170m',
	['bt.709'] = 'bt709',
	['bt.2020-ncl'] = 'bt2020nc',
	['bt.2020-cl'] = 'bt2020c',
	['smpte-240m'] = 'smpte240m',
	['ycgco'] = 'ycgco',
}
local PRIMARIES = {
	['bt.601-525'] = 'smpte170m',
	['bt.601-625'] = 'bt470bg',
	['bt.709'] = 'bt709',
	['bt.2020'] = 'bt2020',
	['bt.470m'] = 'bt470m',
	['dci-p3'] = 'smpte431',
	['display-p3'] = 'smpte432',
	['film-c'] = 'film',
}
local TRANSFER = {
	['bt.1886'] = 'bt709',
	['srgb'] = 'iec61966-2-1',
	['linear'] = 'linear',
	['gamma2.2'] = 'gamma22',
	['gamma2.8'] = 'gamma28',
	['pq'] = 'smpte2084',
	['hlg'] = 'arib-std-b67',
	['st428'] = 'smpte428',
}
local LEVELS = { limited = 'tv', full = 'pc' }

-- bit depth and chroma of a pixel format, from mpv's name or a hw surface's
local function depth_chroma(pix)
	pix = pix or ''
	local surfaces = {
		nv12 = { 8, '420' },
		p010 = { 10, '420' },
		p012 = { 12, '420' },
		p016 = { 16, '420' },
		nv24 = { 8, '444' },
		y210 = { 10, '422' },
		yuyv422 = { 8, '422' },
	}
	if surfaces[pix] then
		return surfaces[pix][1], surfaces[pix][2]
	end
	local chroma, bits = pix:match('^yuvj?(4%d%d)p(%d*)')
	if chroma then
		return tonumber(bits) or 8, chroma
	end
	return nil
end

--- How to make a clip from an explicit description - a shipped case's `clip`
--- (shipped-cases.lua), or what recipe() derives from a learned one:
---   w, h       size              pix    FFmpeg's pixel format
---   codec      mpv's encoder (--ovc)
---   matrix, primaries, gamma, levels    colour tags, mpv's names
---   sar        pixel aspect ('64/45': anamorphic)
---   grain      AV1 film grain (libsvtav1 only)
--- Returns the lavfi source, encoder options and a file name naming exactly
--- that recipe (the names learned cases always had: sar/grain only added
--- when set, so clips made before stay valid).
---@param clip table
---@return table|nil {source, ovc, ovcopts, name}
function M.clip_recipe(clip)
	local w, h = (clip.w or 0) - (clip.w or 0) % 2, (clip.h or 0) - (clip.h or 0) % 2
	if w < 16 or h < 16 or w > 8192 or h > 4352 or not clip.pix or not clip.codec then
		return nil
	end
	local opts = {}
	if clip.codec == 'libx264' or clip.codec == 'libx265' then
		opts[1] = 'preset=ultrafast'
	elseif clip.codec == 'libsvtav1' then
		opts[1] = 'preset=12'
		if clip.grain then
			opts[2] = 'svtav1-params=film-grain=8'
		end
	end
	local params = {}
	if MATRIX[clip.matrix] then
		params[#params + 1] = 'colorspace=' .. MATRIX[clip.matrix]
	end
	if LEVELS[clip.levels] then
		params[#params + 1] = 'range=' .. LEVELS[clip.levels]
	end
	-- primaries and transfer: mpv's encoder drops them from the frames, but
	-- passes them on as encoder options (measured: ffprobe and mpv agree)
	if PRIMARIES[clip.primaries] then
		params[#params + 1] = 'color_primaries=' .. PRIMARIES[clip.primaries]
		opts[#opts + 1] = 'color_primaries=' .. PRIMARIES[clip.primaries]
	end
	if TRANSFER[clip.gamma] then
		params[#params + 1] = 'color_trc=' .. TRANSFER[clip.gamma]
		opts[#opts + 1] = 'color_trc=' .. TRANSFER[clip.gamma]
	end
	local source = string.format('av://lavfi:testsrc2=size=%dx%d:rate=24:duration=1,format=%s', w, h, clip.pix)
	if clip.sar then
		source = source .. ',setsar=' .. clip.sar
	end
	if #params > 0 then
		source = source .. ',setparams=' .. table.concat(params, ':')
	end
	local parts = {
		'case',
		w .. 'x' .. h,
		clip.pix,
		clip.codec,
		clip.matrix or '-',
		clip.primaries or '-',
		clip.gamma or '-',
		clip.levels or '-',
	}
	if clip.sar then
		parts[#parts + 1] = 'sar' .. clip.sar
	end
	if clip.grain then
		parts[#parts + 1] = 'grain'
	end
	local name = table.concat(parts, '-'):gsub('[^%w%.%-]', '_') .. '.mkv'
	return { source = source, ovc = clip.codec, ovcopts = table.concat(opts, ','), name = name }
end

--- How to make a clip that reproduces a learned `case` (see clip_recipe()).
--- Software-decoded cases use FFV1 (lossless, takes nearly every pixel format
--- as it is, so the renderer gets that same format); hardware-decoded ones a
--- codec the GPU decodes: H.264 for 8-bit 4:2:0, HEVC otherwise.
---@return table|nil {source, ovc, ovcopts, name}
function M.recipe(case)
	if case.idle or not case.w or not case.h then
		return nil
	end
	local fmt, ovc
	local bits, chroma = depth_chroma(case.hwpix or case.pix)
	if case.hwdec == 'no' or case.hwdec == nil then
		fmt = (case.pix or 'yuv420p'):gsub('^yuvj', 'yuv')
		if fmt:match('%d$') and fmt:match('p1[0246]$') then
			fmt = fmt .. 'le' -- mpv's yuv420p10 is FFmpeg's yuv420p10le
		end
		ovc = 'ffv1'
	else
		bits, chroma = bits or 8, chroma or '420'
		if bits > 10 then
			bits = 10 -- this build's x265: 8 and 10 bit
		end
		fmt = 'yuv' .. chroma .. 'p' .. (bits > 8 and (bits .. 'le') or '')
		if bits == 8 and chroma == '420' then
			ovc = 'libx264'
		else
			ovc = 'libx265'
		end
	end
	return M.clip_recipe({
		w = case.w,
		h = case.h,
		pix = fmt,
		codec = ovc,
		matrix = case.matrix,
		primaries = case.primaries,
		gamma = case.gamma,
		levels = case.levels,
	})
end

--- The cases to replay, newest first, at most MAX_REPLAY.
function M.replay_list(data)
	local list = {}
	for _, c in ipairs((data or M.load()).cases) do
		list[#list + 1] = c
	end
	table.sort(list, function(a, b)
		return (a.last or '') > (b.last or '')
	end)
	while #list > M.MAX_REPLAY do
		table.remove(list)
	end
	return list
end

--- One line per case, title-free, for the status banner and the report.
function M.describe(c)
	if c.idle then
		return 'empty window (no video)'
	end
	local parts = {
		string.format('%sx%s %s', c.w or '?', c.h or '?', c.hwpix and (c.pix .. '/' .. c.hwpix) or (c.pix or '?')),
		string.format('%s/%s', c.matrix or '?', c.gamma or '?'),
		'decoder ' .. (c.hwdec or '?'),
		c.chain .. (c.sharpen and (' ' .. c.sharpen) or ''),
		c.ratio and string.format('x%.2f', c.ratio) or nil,
	}
	return table.concat(parts, ' · ')
end

--- The same for a shipped case (shipped-cases.lua): its clip and what it sets.
function M.describe_shipped(c)
	local k = c.clip or {}
	local extras = {}
	if c.unscaled then
		extras[#extras + 1] = '1:1'
	end
	if c.deband == false then
		extras[#extras + 1] = 'deband off'
	end
	for p, v in pairs(c.eq or {}) do
		extras[#extras + 1] = p .. ' ' .. v
	end
	if c.rotate then
		extras[#extras + 1] = 'rotate ' .. c.rotate
	end
	if c.overlay then
		extras[#extras + 1] = 'RGBA overlay'
	end
	if c.subs then
		extras[#extras + 1] = 'subtitles'
	end
	if c.ratio then
		extras[#extras + 1] = string.format('x%.2f', c.ratio)
	end
	if c.as_size then
		extras[#extras + 1] = string.format('as %dx%d', c.as_size[1], c.as_size[2])
	end
	local parts = {
		k.file and (k.file:match('[^/]+$') or k.file) or string.format(
			'%sx%s %s %s%s%s',
			k.w or '?',
			k.h or '?',
			k.pix or '?',
			k.codec or '?',
			k.grain and ' grain' or '',
			k.sar and (' sar ' .. k.sar) or ''
		),
	}
	if k.primaries or k.gamma then
		parts[#parts + 1] = string.format('%s/%s', k.primaries or '?', k.gamma or '?')
	end
	parts[#parts + 1] = 'decoder ' .. (c.hwdec or 'no')
	parts[#parts + 1] = c.chain or 'off'
	if #extras > 0 then
		parts[#parts + 1] = table.concat(extras, ', ')
	end
	return table.concat(parts, ' · ')
end

return M
