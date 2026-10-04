-- Real renderer, fullscreen: switching between Off, Anime, Movie and the Movie
-- sharpness levels - by menu message, by Shift+A/Shift+Y and by the toolbar
-- cycle - must be smooth and leave nothing behind. Per switch: the right
-- chain is loaded and on screen quickly, no frame is dropped or late. Over the
-- whole run: nothing recompiles after the first round (the cache and
-- libplacebo's in-memory objects are reused), no renderer errors, and VRAM
-- does not grow from round to round.
--
-- Runs on a FastStream-marked 720p anime clip, so the decode path is the
-- streaming one (both decode with d3d11va-copy since 2026-10-04).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local ROUNDS = 4
-- How often the chain-set check polls. glsl-shaders/glsl-shader-opts are plain
-- option reads (no video-thread round trip), so 10 ms is harmless and gives
-- ms-level latency numbers; MPV_TEST_POLL overrides it.
local POLL = tonumber(os.getenv('MPV_TEST_POLL') or '') or 0.01

local ANIME = table.concat({
	'Anime4K_Clamp_Highlights.glsl',
	'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
	'Anime4K_AutoDownscalePre_x2.glsl',
	'Anime4K_AutoDownscalePre_x4.glsl',
	'Anime4K_Restore_CNN_M.glsl',
	'Anime4K_Upscale_CNN_x2_M.glsl',
}, ';')

local compiles, errors = 0, {}
mp.enable_messages('debug')
mp.register_event('log-message', function(e)
	if e.prefix == 'vo/gpu-next/libplacebo' and e.text:find('shaderc compile status', 1, true) then
		compiles = compiles + 1
	end
	if (e.level == 'error' or e.level == 'fatal') and not e.prefix:find('^test_') then
		errors[#errors + 1] = e.prefix .. ': ' .. e.text
	end
end)

local function chain()
	local names = {}
	for _, p in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		local _, name = utils.split_path(p)
		names[#names + 1] = name
	end
	return table.concat(names, ';')
end

local function curve_height()
	return (mp.get_property_native('glsl-shader-opts') or {})['adaptive-sharpen/curve_height']
end

local function passes()
	local vp = mp.get_property_native('vo-passes') or {}
	return vp.fresh or {}
end

-- ms per frame spent in the renderer's passes (sum of each pass's average)
local function render_ms()
	local ns = 0
	for _, p in ipairs(passes()) do
		ns = ns + (p.avg or 0)
	end
	return ns / 1e6
end

local function counters()
	return {
		drop = mp.get_property_number('frame-drop-count', 0),
		decoder = mp.get_property_number('decoder-frame-drop-count', 0),
		delayed = mp.get_property_number('vo-delayed-frame-count', 0),
		mistimed = mp.get_property_number('mistimed-frame-count', 0),
	}
end

local function vram_mb()
	local pid = mp.get_property_number('pid')
	local r = mp.command_native({
		name = 'subprocess',
		playback_only = false,
		capture_stdout = true,
		args = {
			'powershell',
			'-NoProfile',
			'-NonInteractive',
			'-Command',
			'(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory'
				.. " | Where-Object Name -like 'pid_"
				.. pid
				.. "_*' | Measure-Object DedicatedUsage -Sum).Sum",
		},
	})
	local bytes = tonumber(((r and r.stdout) or ''):match('%d+'))
	return bytes and bytes / 2 ^ 20 or nil
end

local function send(...)
	mp.commandv('script-message-to', 'gpu_toggles', ...)
end

H.run(function()
	local dw, dh = mp.get_property_number('display-width'), mp.get_property_number('display-height')
	local vw, vh = mp.get_property_number('width'), mp.get_property_number('height')
	if not H.check('display and video size known', dw and dh and vw and vh, tostring(dw) .. 'x' .. tostring(dh)) then
		return
	end
	local scale = math.min(dw / vw, dh / vh)
	local movie = scale >= 2 and 'FSRCNNX_x2_16-0-4-1.glsl;SSimSuperRes.glsl;CfL_Prediction.glsl'
		or 'SSimSuperRes.glsl;CfL_Prediction.glsl'
	local movie_sharp = movie .. ';adaptive-sharpen.glsl'
	local auto = string.format('%.3f', math.max(0.5, math.min(1.5, scale - 1)))
	H.info(
		string.format(
			'display %dx%d, video %dx%d, scale %.2f, hwdec %s',
			dw,
			dh,
			vw,
			vh,
			scale,
			mp.get_property('hwdec-current', '?')
		)
	)
	H.eq('FastStream anime file starts with Anime (Auto)', chain(), ANIME)

	-- label, action, expected chain, expected curve_height (or nil), passes
	-- predicate for "the new chain is on screen" (nil = same chain as before)
	local function is_off(n)
		return n <= 8
	end
	local function is_heavy(n)
		return n > 8
	end
	local round = {
		{
			'menu Off',
			function()
				send('set-upscale', '0')
			end,
			'',
			nil,
			is_off,
		},
		{
			'menu Anime',
			function()
				send('set-upscale', '2')
			end,
			ANIME,
			nil,
			is_heavy,
		},
		{
			'menu Movie',
			function()
				send('set-upscale', '3')
			end,
			movie_sharp,
			auto,
			is_heavy,
		},
		{
			'sharpness Low',
			function()
				send('set-movie-sharpness', '0.5')
			end,
			movie_sharp,
			'0.500',
		},
		{
			'sharpness High',
			function()
				send('set-movie-sharpness', '1.5')
			end,
			movie_sharp,
			'1.500',
		},
		{
			'sharpness Off',
			function()
				send('set-movie-sharpness', '0')
			end,
			movie,
			nil,
		},
		{
			'sharpness Auto',
			function()
				send('set-movie-sharpness', 'auto')
			end,
			movie_sharp,
			auto,
		},
		{
			'Shift+A (Movie -> Anime)',
			function()
				mp.commandv('keypress', 'Shift+A')
			end,
			ANIME,
			nil,
			is_heavy,
		},
		{
			'Shift+Y (Anime -> Movie)',
			function()
				mp.commandv('keypress', 'Shift+Y')
			end,
			movie_sharp,
			auto,
			is_heavy,
		},
		{
			'Shift+Y (Movie -> off)',
			function()
				mp.commandv('keypress', 'Shift+Y')
			end,
			'',
			nil,
			is_off,
		},
		{
			'toolbar click (off -> Auto)',
			function()
				mp.commandv('script-binding', 'gpu_toggles/cycle-upscale')
			end,
			ANIME,
			nil,
			is_heavy,
		},
		{
			'toolbar click (Auto -> Anime)',
			function()
				mp.commandv('script-binding', 'gpu_toggles/cycle-upscale')
			end,
			ANIME,
			nil,
		},
		{
			'toolbar click (Anime -> Movie)',
			function()
				mp.commandv('script-binding', 'gpu_toggles/cycle-upscale')
			end,
			movie_sharp,
			auto,
			is_heavy,
		},
		{
			'toolbar click (Movie -> off)',
			function()
				mp.commandv('script-binding', 'gpu_toggles/cycle-upscale')
			end,
			'',
			nil,
			is_off,
		},
	}

	local worst_state, worst_frame, worst_label = 0, 0, ''
	local slowest = {} -- label -> time until the new chain is set, one entry per round
	-- Round 1 is each chain's FIRST use in this process: mpv reads and parses
	-- its .glsl files (~45 ms for the Movie chain) and libplacebo allocates its
	-- textures and pipelines, on the render thread. At 24 fps that can make a
	-- few frames late, once (measured 2026-09-26: 0-4 on the first switch to
	-- Movie, with or without the gpu-toggles speed-up). Rounds 2+ are the
	-- steady state and must be clean.
	local late_first, late_total, compiles_after_first = 0, 0, 0
	local vram_first, vram_last
	local start = counters()

	for r = 1, ROUNDS do
		local compiles_at_round = compiles
		for _, s in ipairs(round) do
			local label, action, want, want_curve, on_screen = s[1], s[2], s[3], s[4], s[5]
			local before = counters()
			local t0 = mp.get_time()
			action()
			local ok = H.wait_until(function()
				return chain() == want and (not want_curve or curve_height() == want_curve)
			end, 2, POLL)
			local t_state = mp.get_time() - t0
			local t_frame = t_state
			if ok and on_screen then
				-- vo-passes is answered by the video thread: poll it gently, or
				-- the polling itself delays frames (10 ms polling did, 2026-09-26)
				ok = H.wait_until(function()
					return on_screen(#passes())
				end, 2, 0.05)
				t_frame = mp.get_time() - t0
			end
			if not ok then
				H.fail(
					string.format('round %d: %s', r, label),
					'got ' .. chain() .. ' / curve ' .. tostring(curve_height())
				)
			end
			H.sleep(0.8)
			local after = counters()
			local late = (after.drop - before.drop)
				+ (after.delayed - before.delayed)
				+ (after.decoder - before.decoder)
			if r == 1 then
				late_first = late_first + late
			else
				late_total = late_total + late
			end
			if late > 0 then
				H.info(string.format('round %d %s: %d dropped/late frames', r, label, late))
			end
			if t_frame > worst_frame then
				worst_state, worst_frame, worst_label = t_state, t_frame, label
			end
			slowest[label] = slowest[label] or {}
			table.insert(slowest[label], t_state)
		end
		if r > 1 then
			compiles_after_first = compiles_after_first + (compiles - compiles_at_round)
		end
		-- the round ends on Off: same state each time, so VRAM is comparable
		local mb = vram_mb()
		if mb then
			vram_first = vram_first or mb
			vram_last = mb
			H.info(string.format('round %d: VRAM %.0f MB, %d compiles so far', r, mb, compiles))
		end
	end

	local total = counters()
	for _, s in ipairs(round) do
		local t = slowest[s[1]]
		table.sort(t)
		H.info(
			string.format(
				'chain set after %-32s median %4.0f ms, worst %4.0f ms (%d rounds)',
				s[1],
				t[math.ceil(#t / 2)] * 1000,
				t[#t] * 1000,
				#t
			)
		)
	end
	H.info(
		string.format(
			'slowest switch: %s - chain set after %.0f ms, on screen after %.0f ms',
			worst_label,
			worst_state * 1000,
			worst_frame * 1000
		)
	)
	H.check(
		string.format('%d switches: every chain on screen within 0.5 s', ROUNDS * #round),
		worst_frame < 0.5,
		string.format('%s took %.0f ms', worst_label, worst_frame * 1000)
	)
	H.eq(string.format('no dropped or late frames while switching (rounds 2-%d)', ROUNDS), late_total, 0)
	H.check('first use of each chain costs at most 6 late frames (round 1)', late_first <= 6, late_first .. ' frames')
	H.info(string.format('round 1 (first use of each chain): %d dropped/late frames', late_first))
	H.eq('no mistimed frames', total.mistimed - start.mistimed, 0)
	H.eq('no shader recompiles after the first round', compiles_after_first, 0)
	H.check('no renderer/script errors', #errors == 0, table.concat(errors, ' | '))
	if vram_first and vram_last then
		H.check(
			string.format('VRAM stable over %d rounds (%.0f -> %.0f MB)', ROUNDS, vram_first, vram_last),
			vram_last - vram_first < 64,
			string.format('grew %.0f MB', vram_last - vram_first)
		)
	else
		H.info('VRAM not measured (GPU performance counters unavailable)')
	end

	-- a different source size picks the other Movie chain, and switching
	-- file keeps working with a chain active
	send('set-upscale', '3')
	H.load(H.media_path('gpu/movie1080/film#fs-content=movie&fs-id=3333333333333333.mkv'))
	local s2 = math.min(dw / 1920, dh / 1080)
	local want2 = (s2 >= 2 and 'FSRCNNX_x2_16-0-4-1.glsl;' or '')
		.. 'SSimSuperRes.glsl;CfL_Prediction.glsl'
		.. (s2 > 1 and ';adaptive-sharpen.glsl' or '')
	H.wait_until(function()
		return chain() == want2
	end, 2)
	H.eq(string.format('1080p source (scale %.2f) gets its Movie chain', s2), chain(), want2)
	H.info(string.format('render time per frame: %.2f ms (Movie @1080p)', render_ms()))
end, { timeout = 280 })
