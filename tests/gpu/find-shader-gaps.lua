-- shader-gaps: what real playback still compiles AFTER a full warm-up.
--
-- run-tests.ps1 -Tier gaps warms an empty shader cache exactly as the player
-- does it (warm-shader-cache.ps1: warmup.lua's matrix + its shipped cases,
-- hidden window), then starts this script in a player with the WHOLE config
-- (uosc, banners, every script), fullscreen on the real GPU, on that cache. It
-- plays every corpus entry (tests/lib/gap-media.ps1) under the conditions the
-- entry names and counts, per condition, what had to be made:
--   compiles   GLSL->SPIR-V ("shaderc compile status" in libplacebo's log -
--              never printed on a cache hit, as warmup.lua counts them)
--   pipelines  the driver building a pipeline with no cached binary (>= 2 ms)
--   files      new shader_<16 hex> objects in the cache folder (what the
--              player's own capture, shader-misses.log, counts)
-- Anything above 0 is a GAP: a shader a real video would wait for. Each gap is
-- a FAIL line plus a title-free case (cases.lua's format) in the JSON file
-- shader_gaps-out names, ready to be shipped as a warm-up case.
--
-- Conditions (apply, then draw: ~12 frames playing, 2 stepped while paused):
--   fs-off | fs-anime | fs-movie           fullscreen x chain (sharpness auto)
--   fs-movie-low | fs-movie-high           Movie at sharpness 0.5 / 1.5
--   win-1x[-anime|-movie]                  a window at the video's size (how
--                                          mpv opens a local file here)
--   win-half | win-quarter | win-max       window-scale 0.5 / 0.25 / maximized
--   deband-off | equalizer | rotate | zoom-out
--   osd | rgba-overlay | pause | subs[-anime|-movie]
--   still | still-1x | still-anime         a picture that does not move
-- and once each: mpv's empty window, fullscreen and windowed.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local utils = require('mp.utils')
local options = require('mp.options')

local o = { manifest = '', out = '', overlay = '' }
options.read_options(o, 'shader_gaps')

local cases = dofile(H.root .. '/portable_config/Scripts/shader-cache/cases.lua')

-- ---- what was made ------------------------------------------------------------

local compiles, pipelines = 0, 0
mp.enable_messages('debug')
mp.register_event('log-message', function(e)
	if e.prefix ~= 'vo/gpu-next/libplacebo' then
		return
	end
	if e.text:find('shaderc compile status', 1, true) then
		compiles = compiles + 1
	else
		local ms, what = e.text:match('Spent ([%d.]+) ms (%a+ %a+)')
		if tonumber(ms) and what == 'creating pipeline' and tonumber(ms) >= 2 then
			pipelines = pipelines + 1
		end
	end
end)

local cache_dir = mp.command_native({
	'expand-path',
	(
		mp.get_property('options/gpu-shader-cache-dir', '') ~= ''
			and mp.get_property('options/gpu-shader-cache-dir')
		or '~~cache/'
	),
})
local function cache_files()
	local n = 0
	for _, f in ipairs(utils.readdir(cache_dir, 'files') or {}) do
		if #f == 23 and f:match('^shader_%x+$') then
			n = n + 1
		end
	end
	return n
end

local frames = 0
mp.observe_property('time-pos', 'number', function()
	frames = frames + 1
end)

-- main.lua's chain_label(), for cases.current()
local function chain_label()
	local names = {}
	for _, s in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		names[#names + 1] = s:match('([^/\\]+)%.glsl$') or s
	end
	local all = table.concat(names, ' ')
	if #names == 0 then
		return 'no upscaler'
	end
	-- the same rule as Scripts/shader-cache/main.lua's chain_label()
	local family = mp.get_property_native('user-data/gpu-toggles/preset')
	local label = all
	if family == 'anime' or (family == nil and all:find('Anime4K', 1, true)) then
		label = 'Anime'
	elseif family == 'movie' or (family == nil and all:find('SSimSuperRes', 1, true)) then
		label = all:find('FSRCNNX', 1, true) and 'Movie (FSRCNNX+SSimSuperRes)' or 'Movie (SSimSuperRes)'
	end
	local sharpen = (mp.get_property_native('glsl-shader-opts') or {})['adaptive-sharpen/curve_height']
	return (sharpen and label:find('^Movie')) and (label .. ', sharpen ' .. sharpen) or label
end

-- ---- state changes --------------------------------------------------------------

local function applied()
	return mp.get_property_number('user-data/gpu-toggles/applied', 0)
end

-- mode: '0' off, '2' Anime, '3' Movie; sharpness 'auto' or a number
local function set_chain(mode, sharpness)
	local target = applied() + 2
	mp.commandv('script-message-to', 'gpu_toggles', 'set-movie-sharpness', sharpness or 'auto')
	mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', mode)
	H.wait_until(function()
		return applied() >= target
	end, 3, 0.01)
end

local function osd_size()
	local d = mp.get_property_native('osd-dimensions') or {}
	return (d.w or 0) .. 'x' .. (d.h or 0)
end

-- waits until the window has kept one size for 0.3 s (a mode change resizes
-- in steps)
local function settle_window()
	local last, since = osd_size(), mp.get_time()
	local deadline = mp.get_time() + 4
	while mp.get_time() < deadline do
		H.sleep(0.05)
		local now = osd_size()
		if now ~= last then
			last, since = now, mp.get_time()
		elseif mp.get_time() - since >= 0.3 then
			return
		end
	end
end

local window = 'fs'
local function set_window(mode)
	if mode == window then
		return
	end
	if mode == 'fs' then
		mp.set_property_native('window-maximized', false)
		mp.set_property_native('fullscreen', true)
	else
		if window == 'fs' then
			mp.set_property_native('fullscreen', false)
			settle_window()
		end
		if mode == 'max' then
			mp.set_property_native('window-maximized', true)
		else
			mp.set_property_native('window-maximized', false)
			settle_window()
			mp.set_property_number('window-scale', mode == 'half' and 0.5 or mode == 'quarter' and 0.25 or 1)
		end
	end
	window = mode
	settle_window()
end

local overlay_on = false
local function restore()
	mp.set_property_native('deband', true)
	for _, p in ipairs({ 'contrast', 'brightness', 'saturation', 'gamma', 'hue', 'video-rotate', 'video-zoom' }) do
		mp.set_property_number(p, 0)
	end
	mp.set_property('sid', 'no')
	if overlay_on then
		mp.commandv('overlay-remove', '1')
		overlay_on = false
	end
end

local CONDITIONS = {
	['fs-off'] = { 'fs', '0' },
	['fs-anime'] = { 'fs', '2' },
	['fs-movie'] = { 'fs', '3' },
	['fs-movie-low'] = { 'fs', '3', '0.5' },
	['fs-movie-high'] = { 'fs', '3', '1.5' },
	['win-1x'] = { '1x', '0' },
	['win-1x-anime'] = { '1x', '2' },
	['win-1x-movie'] = { '1x', '3' },
	['win-half'] = { 'half', '0' },
	['win-quarter'] = { 'quarter', '0' },
	['win-max'] = { 'max', '0' },
	['still'] = { 'fs', '0' },
	['still-1x'] = { '1x', '0' },
	['still-anime'] = { 'fs', '2' },
	['subs'] = { 'fs', '0', nil, { sid = '1' } },
	['subs-anime'] = { 'fs', '2', nil, { sid = '1' } },
	['subs-movie'] = { 'fs', '3', nil, { sid = '1' } },
	['deband-off'] = { 'fs', '0', nil, { deband = false } },
	-- what the right-click menu's Video > Equalizer steps set
	['equalizer'] = { 'fs', '0', nil, { contrast = 5, brightness = 5, saturation = 5, gamma = 5 } },
	['eq-contrast'] = { 'fs', '0', nil, { contrast = 2 } },
	['eq-brightness'] = { 'fs', '0', nil, { brightness = 2 } },
	['eq-gamma'] = { 'fs', '0', nil, { gamma = 2 } },
	['eq-saturation'] = { 'fs', '0', nil, { saturation = 2 } },
	['eq-hue'] = { 'fs', '0', nil, { hue = 2 } },
	['rotate'] = { 'fs', '0', nil, { ['video-rotate'] = 90 } },
	['rotate-180'] = { 'fs', '0', nil, { ['video-rotate'] = 180 } },
	['zoom-out'] = { 'fs', '0', nil, { ['video-zoom'] = -1 } },
	['osd'] = { 'fs', '0', nil, nil, 'osd' },
	['rgba-overlay'] = { 'fs', '0', nil, nil, 'overlay' },
	['pause'] = { 'fs', '0', nil, nil, 'pause' },
}

local function apply(name)
	local c = CONDITIONS[name]
	if not c then
		return false
	end
	restore()
	set_window(c[1])
	set_chain(c[2], c[3])
	for prop, v in pairs(c[4] or {}) do
		mp.set_property_native(prop, v)
	end
	if c[5] == 'osd' then
		-- mpv's own boxed OSD text (menu actions, screenshots)
		mp.commandv('show-text', 'Contrast: 1', '3000')
	elseif c[5] == 'overlay' and o.overlay ~= '' then
		-- an RGBA bitmap over the video: thumbfast's timeline thumbnails and
		-- picture subtitles (PGS, VobSub) are drawn this way
		mp.commandv('overlay-add', '1', '40', '40', o.overlay, '0', 'bgra', '64', '64', '256')
		overlay_on = true
	end
	return true, c[5] == 'pause'
end

-- ---- drawing and counting ---------------------------------------------------------

local function draw(still, paused)
	mp.commandv('script-binding', 'uosc/flash-ui')
	if still or paused then
		mp.set_property_native('pause', paused or mp.get_property_native('pause'))
		H.sleep(0.8)
	else
		local start = frames
		mp.set_property_native('pause', false)
		H.wait_until(function()
			return frames >= start + 12
		end, 6, 0.01)
		mp.set_property_native('pause', true)
		-- a stepped frame draws a few passes differently (warmup.lua play_frames)
		for _ = 1, 2 do
			local s = frames
			mp.command('frame-step')
			H.wait_until(function()
				return frames > s
			end, 3, 0.01)
		end
	end
	H.sleep(0.25) -- the last log lines of a compile arrive after its frame
end

local gaps, steps, clean = {}, 0, 0
local function measure(label, cond, still, paused, from)
	from = from or { compiles, pipelines, cache_files() }
	draw(still, paused)
	local n, p, f = compiles - from[1], pipelines - from[2], cache_files() - from[3]
	steps = steps + 1
	local name = label .. ' · ' .. cond
	-- a gap is something the cache did not have: a compile or a new object. A
	-- slow pipeline creation alone (>= 2 ms, no new object) was a cache hit
	-- that took longer - measured 3 times in the first run, never repeatable.
	if n + f == 0 then
		clean = clean + 1
		H.pass(name)
		if p > 0 then
			H.info(name .. ': ' .. p .. ' slow pipeline creation(s), nothing new in the cache')
		end
	else
		local case = cases.current(chain_label())
		case.condition = cond
		case.corpus = label
		case.compiles, case.pipelines, case.files = n, p, f
		gaps[#gaps + 1] = case
		H.fail(name, string.format('%d compiles, %d pipelines, %d new cache files - %s', n, p, f, cases.describe(case)))
	end
end

local function write_gaps()
	if o.out == '' then
		return
	end
	local f = io.open(o.out, 'w')
	if f then
		f:write(utils.format_json({ gaps = gaps, steps = steps }) or '{}', '\n')
		f:close()
	end
end

H.run(function()
	local t0 = mp.get_time()
	local fh = io.open(o.manifest, 'r')
	local corpus = fh and utils.parse_json(fh:read('*a') or '') or nil
	if fh then
		fh:close()
	end
	if not H.check('the corpus list is readable', type(corpus) == 'table' and #corpus > 0, o.manifest) then
		return
	end
	mp.set_property('loop-file', 'inf')
	mp.set_property_native('fullscreen', true)
	settle_window()
	set_chain('0')

	-- mpv's empty window, as a double-click on mpv.exe shows it
	measure('empty window', 'fullscreen', true)
	set_window('1x')
	measure('empty window', 'window', true)
	set_window('fs')

	for _, e in ipairs(corpus) do
		restore()
		set_window('fs')
		set_chain('0')
		local first = { compiles, pipelines, cache_files() }
		if not H.load(e.path, 60) then
			H.fail(e.label .. ' · load', 'did not start playing')
		else
			for i, cond in ipairs(e.conds or {}) do
				local ok, paused = apply(cond)
				if ok then
					-- the first condition owns what starting the file compiled
					measure(e.label, cond, e.still, paused, i == 1 and first or nil)
				else
					H.info('unknown condition ' .. cond)
				end
			end
		end
		write_gaps()
	end
	restore()
	set_chain('0')
	mp.command('stop')
	write_gaps()
	H.info(
		string.format(
			'%d steps over %d corpus entries: %d clean, %d gaps (%.0f s)',
			steps,
			#corpus,
			clean,
			#gaps,
			mp.get_time() - t0
		)
	)
end, { wait_file = false })
