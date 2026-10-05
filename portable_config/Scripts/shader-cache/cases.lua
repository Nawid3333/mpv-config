-- cases.lua - the clips of the shipped warm-up cases (shipped-cases.lua): how
-- warmup.lua makes each one with mpv's own encoder, and how it names a case in
-- its RESULT lines and progress. Loaded with dofile(), like fingerprint.lua.
--
-- History: from 2026-10-02 to 2026-10-05 it also held the LEARNED cases - every
-- shader real playback still compiled, recorded by main.lua's capture into
-- ~~state/shader-cases.json and replayed by each full warm-up. The owner's
-- measurement (mpv issue #39) kept the warm-up and removed the capture and the
-- learned cases; a leftover shader-cases.json or shader-misses.log is no longer
-- read. Clip names are unchanged, so clips made before stay valid.

local M = {}

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

--- How to make a clip from a shipped case's `clip` (shipped-cases.lua):
---   w, h       size              pix    FFmpeg's pixel format
---   codec      mpv's encoder (--ovc)
---   matrix, primaries, gamma, levels    colour tags, mpv's names
---   sar        pixel aspect ('64/45': anamorphic)
---   grain      AV1 film grain (libsvtav1 only)
--- Returns the lavfi source, encoder options and a file name naming exactly
--- that recipe (sar/grain only added when set, so clips made before stay
--- valid).
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
