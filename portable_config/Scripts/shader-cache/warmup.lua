-- warmup.lua - the shader cache warm-up. It runs in its OWN mpv process, never
-- inside the player, and always embedded in a window that is never shown
-- (host.ps1): main.lua starts it in the background when the startup check finds
-- the cache stale, installer/warm-shader-cache.ps1 on request (and, with
-- check=yes, for tests/run-tests.ps1 -Tier gpu). Nothing of it is on screen and
-- it gets no input, so no key, click or pause in the player reaches it. mpv
-- loads only a folder's main.lua, so this file is never a player script by
-- accident.
--
-- Draws every upscale chain once in the real renderer, so that libplacebo's
-- compiled shaders land in the on-disk shader cache before a real video needs
-- them. A cache miss costs up to ~0.3 s before the first frame (measured
-- 2026-09-26: Anime 491 ms cold vs 182 ms warm at 720p).
--
-- What makes a new cache entry (measured the same day): the passes that run,
-- not the video size - Anime at 1080p after 720p needed 1 new compile out of
-- ~49. So the matrix covers each scale tier the chains branch on (Anime4K's
-- x2/x4 AutoDownscalePre, Movie's FSRCNNX at >= 2x, no sharpening when not
-- enlarged), 8-bit and 10-bit sources, and both decode paths: d3d11va-copy
-- (local files) and vulkan (FastStream streams, mpv.conf [faststream-hwdec]).
-- Change the matrix -> bump fingerprint.lua's WARMUP_VERSION.
--
-- LEARNED cases (2026-10-02, cases.lua): after the matrix, a full warm-up also
-- replays every case real playback needed and the matrix lacked - recorded by
-- the player's capture, title-free - each from a 1 s clip in exactly that
-- format and colour tagging (mpv's own encoder; FFV1 for software decoding,
-- H.264/HEVC for the GPU decoders), decoded the same way, through the same
-- chain and sharpness, at the same displayed scale (video-zoom against this
-- window's fit). mpv's empty window is a case too (stop, then draw idle). A
-- quick check replays them only when it escalates to a full warm-up. A case
-- whose clip cannot be made is skipped with a RESULT INFO line, never fatal.
--
-- How long it takes, and why (measured 2026-09-26, cold cache, Ryzen 5 7600X):
-- the real compile work is ~1.3 s (GLSL->SPIR-V 1.2 s, pipelines 0.1 s). The
-- first version slept a fixed 0.4-0.6 s per step and took 44.7 s - 96 %
-- waiting, CPU ~20 %. Now each clip sits paused and every step frame-steps
-- just far enough to prove the new chain was drawn (settle()); a paused clip
-- also keeps the GPU nearly idle, which matters when this runs next to a
-- playing video. After the steps, each clip PLAYS a few frames (play_frames):
-- a playing video draws some passes slightly differently from a stepped one
-- (the main pass and an overlay pass had extra specialization constants), and
-- a stepping-only warm-up left 4 compiles for the next real start of a 720p
-- FastStream file (Anime, Movie, Off) - 0 with the played frames.
--
-- The process loads only gpu-toggles.lua (the chains), uosc (its UI is drawn
-- over every real video, so its passes belong in the cache), notify.lua (the
-- banner gpu-toggles shows at each switch, as in the player) and this script
-- (--load-scripts=no): nothing that keeps state (remember-speed,
-- stream-resume, autoload) runs here. Progress goes to shader-warmup.progress in
-- the cache folder, for main.lua's small bar and the manual script's terminal.
-- (Until 2026-09-26 the manual run covered the monitor with a "Preparing video
-- shaders" screen and took Esc/q - removed at the user's request: no blocking
-- screen anywhere, and a focused window was one that pausing could reach.)
--
-- Counts cache misses from libplacebo's own log ("shaderc compile status"
-- appears once per GLSL->SPIR-V compile, never on a cache hit) and prints
--   RESULT INFO <step>: <n> compiles
-- and, with check=yes, a final RESULT PASS/FAIL "shader cache warm". Exit
-- codes: 0 done, 1 check found misses (or could not draw), 2 setup error,
-- 3 hard timeout, 4 stamp not written, 6 the player stopped drawing.
local utils = require('mp.utils')
local options = require('mp.options')

local here = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or ''
local fingerprint = dofile(here .. 'fingerprint.lua')
local cases = dofile(here .. 'cases.lua')

local o = {
	check = false, -- report misses, write no stamp
	quick = false, -- stop after the QUICK clips if they compiled nothing
	matrix = 'full', -- 'test': one tiny clip, for the headless tests
	settle_frames = 3, -- frames stepped after a switch before it counts as drawn (see settle())
	play_frames = 3, -- then frames played (see settle())
	learned = true, -- replay the learned cases (cases.lua) in a full warm-up
	shipped = true, -- replay shipped-cases.lua in a full warm-up (not with matrix=test)
}
options.read_options(o, 'shader_warmup')

local function out(line)
	io.stdout:write(line .. '\n')
	io.stdout:flush()
end

local function quit(code)
	mp.command('quit ' .. code)
end

-- ---- cache misses, from libplacebo's log -----------------------------------

-- work_ms: the real compile work - GLSL->SPIR-V ("translating SPIR-V") plus
-- the driver's pipeline creation.
local compiles, pipelines, work_ms = 0, 0, 0
mp.enable_messages('debug')
mp.register_event('log-message', function(e)
	if e.prefix ~= 'vo/gpu-next/libplacebo' then
		return
	end
	if e.text:find('shaderc compile status', 1, true) then
		compiles = compiles + 1
	else
		local ms, what = e.text:match('Spent ([%d.]+) ms (%a+ %a+)')
		ms = tonumber(ms)
		if ms and (what == 'translating SPIR' or what == 'creating pipeline') then
			work_ms = work_ms + ms
		end
		-- a driver compile (no usable blob): ms, not the ~0.1-0.4 ms of a hit
		if ms and what == 'creating pipeline' and ms >= 2 then
			pipelines = pipelines + 1
		end
	end
end)

-- ---- progress, for main.lua's bar and the manual script --------------------

local status = {
	title = (o.quick or o.check) and 'Checking shaders' or 'Compiling shaders',
	done = 0,
	total = 0,
}
local progress_file = fingerprint.path('shader-warmup.progress')

-- "<done> <total>", what is being drawn and the title (polled by the reader).
local function write_progress()
	local f = io.open(progress_file, 'w')
	if f then
		f:write(string.format('%d %d\n%s\n%s\n', status.done, status.total, status.detail or '', status.title))
		f:close()
	end
end

local function progress(done, total, detail)
	status.done, status.total, status.detail = done, total, detail
	write_progress()
end

-- ---- coroutine plumbing --------------------------------------------------------

local co
local function resume(...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		out('RESULT FAIL warm-up script :: ' .. tostring(err))
		quit(2)
	end
end
local function sleep(sec)
	mp.add_timeout(sec, resume)
	coroutine.yield()
end
local function run(args)
	mp.command_native_async(
		{ name = 'subprocess', args = args, playback_only = false, capture_stderr = true },
		function(_, res)
			resume(res)
		end
	)
	return coroutine.yield()
end
local function wait_restart(timeout)
	local fired = false
	local function on()
		fired = true
	end
	mp.register_event('playback-restart', on)
	local deadline = mp.get_time() + timeout
	while not fired and mp.get_time() < deadline do
		sleep(0.01)
	end
	mp.unregister_event(on)
	return fired
end

-- Frames queued to the VO: time-pos moves once per frame.
local frames = 0
mp.observe_property('time-pos', 'number', function()
	frames = frames + 1
end)

local function actions_done()
	return mp.get_property_number('user-data/gpu-toggles/applied', 0)
end

-- A switch is drawn once (1) gpu-toggles has finished every action sent so far
-- (its entry() counter reaches `target`) and (2) SETTLE_FRAMES more frames were
-- queued after that, one frame-step at a time from pause. The VO draws frames
-- in order and reads option changes at the start of each draw, so the third
-- frame queued after the change means the first one drawn with the new chain
-- is finished - every pass of it created, compiled or loaded from the cache. A
-- long compile stalls the VO and with it the stepping, so a cold step simply
-- takes as long as its compile. Measured by a fullscreen check after a warm-up:
-- 0-2 misses, the same run-to-run stragglers as with the old fixed sleeps.
local SETTLE_FRAMES = o.settle_frames
local SETTLE_CAP = 10
local PLAY_FRAMES = o.play_frames
local slow_steps = 0
local function settle(target)
	local deadline = mp.get_time() + SETTLE_CAP
	while actions_done() < target and mp.get_time() < deadline do
		sleep(0.005)
	end
	local n = 0
	while n < SETTLE_FRAMES and mp.get_time() < deadline do
		local start = frames
		mp.command('frame-step')
		while frames == start and mp.get_time() < deadline do
			sleep(0.005)
		end
		if frames ~= start then
			n = n + 1
		end
	end
	-- then a few frames PLAYING: a playing video draws some passes a little
	-- differently from a stepped one (see PLAY_FRAMES)
	if PLAY_FRAMES > 0 and mp.get_time() < deadline then
		local start = frames
		mp.set_property_native('pause', false)
		while frames < start + PLAY_FRAMES and mp.get_time() < deadline do
			sleep(0.005)
		end
		mp.set_property_native('pause', true)
	end
	if mp.get_time() >= deadline then
		slow_steps = slow_steps + 1
	end
end

-- ---- the matrix ------------------------------------------------------------------

local H264 = { codec = 'libx264', pix = 'yuv420p', tag = 'h264 8-bit', bits = '8-bit' }
local HEVC10 = { codec = 'libx265', pix = 'yuv420p10le', tag = 'hevc 10-bit', bits = '10-bit' }
local PATHS = { vulkan = 'FastStream', ['d3d11va-copy'] = 'local file', no = 'software' }

local runs = {}
if o.matrix == 'test' then
	-- one tiny clip twice: enough to tell a quick check (1 run) from a full one (2)
	runs[1] = { hwdec = 'no', size = '320x180', fmt = H264 }
	runs[2] = { hwdec = 'no', size = '320x180', fmt = H264 }
else
	-- The quick check (only shaders/presets changed) stops after these if they
	-- compiled nothing: FastStream at 720p (Movie = FSRCNNX + SSimSuperRes) and
	-- 1080p (Movie = SSimSuperRes alone), the local-file path in 10-bit, and
	-- FastStream at 480p - the one size here at which Anime4K's
	-- AutoDownscalePre_x4 runs on a 1440p screen (its WHEN wants a 2.4-4x
	-- scale; added 2026-10-02, an edit to it compiled nothing in the others).
	runs = {
		{ hwdec = 'vulkan', size = '1280x720', fmt = H264 },
		{ hwdec = 'vulkan', size = '1920x1080', fmt = H264 },
		{ hwdec = 'd3d11va-copy', size = '1280x720', fmt = HEVC10 },
		{ hwdec = 'vulkan', size = '854x480', fmt = H264 },
	}
	local seen = {}
	for _, r in ipairs(runs) do
		seen[r.hwdec .. r.size .. r.fmt.codec] = true
	end
	for _, hwdec in ipairs({ 'd3d11va-copy', 'vulkan' }) do
		for _, size in ipairs({ '640x360', '854x480', '1280x720', '1920x1080', '3840x2160' }) do
			for _, fmt in ipairs({ H264, HEVC10 }) do
				if not seen[hwdec .. size .. fmt.codec] then
					runs[#runs + 1] = { hwdec = hwdec, size = size, fmt = fmt }
				end
			end
		end
	end
end
local QUICK = o.matrix == 'test' and 1 or 4 -- the first QUICK runs
local STEPS_PER_RUN = 4

-- the learned cases: clips to replay, and whether the empty window is one
local learned, learned_idle = {}, false
if o.learned then
	for _, c in ipairs(cases.replay_list()) do
		if c.idle then
			learned_idle = true
		else
			c.recipe = cases.recipe(c)
			if c.recipe then
				learned[#learned + 1] = c
			else
				out('RESULT INFO learned case skipped (no clip for it): ' .. cases.describe(c))
			end
		end
	end
end
-- the shipped cases (shipped-cases.lua): measured gaps of the matrix, drawn
-- before the learned ones in every full warm-up
local shipped = {}
if o.shipped and o.matrix ~= 'test' then
	for _, c in ipairs(dofile(here .. 'shipped-cases.lua')) do
		-- a shipped file (clip.file) where no encoder can make the clip
		c.recipe = c.clip.file and { file = here .. c.clip.file, name = c.clip.file } or cases.clip_recipe(c.clip)
		if c.recipe then
			shipped[#shipped + 1] = c
		else
			out('RESULT INFO shipped case skipped (no clip for it): ' .. cases.describe_shipped(c))
		end
	end
end
local function learned_steps()
	return #shipped + #learned + (learned_idle and 1 or 0)
end

-- Generated once with this mpv's own encoder; the folder name is shared with
-- the old installer script so existing clips are reused.
local exe = utils.join_path(mp.command_native({ 'expand-path', '~~exe_dir/' }), 'mpv.exe')
local clip_dir = utils.join_path(os.getenv('TEMP') or os.getenv('TMP') or '.', 'mpv-shader-warmup-v1')

-- The clips of runs 1..limit: a quick check makes only its own (all 13 took
-- seconds of encoding, a 4K x265 one among them, when the folder had been
-- emptied); one that turns into a full warm-up makes the rest then.
local function ensure_clips(limit)
	if not utils.file_info(clip_dir) then
		run({ 'cmd', '/d', '/c', 'mkdir', (clip_dir:gsub('/', '\\')) })
	end
	local todo = {}
	for i, r in ipairs(runs) do
		if i > limit then
			break
		end
		r.path = utils.join_path(clip_dir, r.size .. '-' .. r.fmt.codec .. '.mkv')
		if not utils.file_info(r.path) and not todo[r.path] then
			todo[#todo + 1] = r
			todo[r.path] = true
		end
	end
	for i = limit + 1, #runs do
		runs[i].path = utils.join_path(clip_dir, runs[i].size .. '-' .. runs[i].fmt.codec .. '.mkv')
	end
	for i, r in ipairs(todo) do
		progress(0, 1, string.format('Making test clips (%d of %d)', i, #todo))
		local part = r.path .. '.part.mkv'
		local res = run({
			exe,
			'--no-config',
			'--really-quiet',
			string.format('av://lavfi:testsrc2=size=%s:rate=24:duration=4,format=%s', r.size, r.fmt.pix),
			'--o=' .. part,
			'--ovc=' .. r.fmt.codec,
			'--ovcopts=preset=ultrafast',
		})
		if not (res and res.status == 0 and utils.file_info(part) and os.rename(part, r.path)) then
			os.remove(part)
			return false, r.size .. ' ' .. r.fmt.tag .. ': ' .. tostring(res and res.stderr)
		end
		out('RESULT INFO generated clip ' .. r.size .. ' ' .. r.fmt.tag)
	end
	return true
end

-- A learned case's clip, made once like the matrix's; nil when this build
-- cannot make it (that case is then skipped, the rest go on). At most
-- NEW_CLIPS are made per warm-up (a 4K 10-bit clip is a few seconds of
-- encoding): the rest wait for the next full warm-up, which keeps this one
-- well inside its time limit.
-- A shipped case's clips are all made in the first full warm-up (about 20
-- small encodes, once): without them that warm-up would not be complete.
local NEW_CLIPS = 12
local made = 0
local function ensure_case_clip(c, kind, what)
	if c.recipe.file then
		if utils.file_info(c.recipe.file) then
			return c.recipe.file
		end
		out('RESULT INFO ' .. kind .. ' case skipped (file missing: ' .. c.recipe.file .. '): ' .. what)
		return nil
	end
	local path = utils.join_path(clip_dir, c.recipe.name)
	if utils.file_info(path) then
		return path
	end
	if kind == 'learned' and made >= NEW_CLIPS then
		out('RESULT INFO learned case deferred to the next warm-up: ' .. what)
		return nil
	end
	if kind == 'learned' then
		made = made + 1
	end
	progress(status.done, status.total, 'Making a clip for a ' .. kind .. ' case')
	local part = path .. '.part.mkv'
	local args = { exe, '--no-config', '--really-quiet', c.recipe.source, '--o=' .. part, '--ovc=' .. c.recipe.ovc }
	if c.recipe.ovcopts ~= '' then
		args[#args + 1] = '--ovcopts=' .. c.recipe.ovcopts
	end
	local res = run(args)
	if not (res and res.status == 0 and utils.file_info(part) and os.rename(part, path)) then
		os.remove(part)
		out('RESULT INFO ' .. kind .. ' case skipped (clip failed: ' .. c.recipe.name .. '): ' .. what)
		return nil
	end
	out('RESULT INFO generated clip for a ' .. kind .. ' case: ' .. c.recipe.name)
	return path
end

-- What a shipped case draws over the video - a subtitle line, an RGBA bitmap -
-- written once next to the clips.
local function aux_file(name, content)
	local path = utils.join_path(clip_dir, name)
	if not utils.file_info(path) then
		local f = io.open(path, 'wb')
		if f then
			f:write(content)
			f:close()
		end
	end
	return path
end
local SUBS_ASS = table.concat({
	'[Script Info]',
	'ScriptType: v4.00+',
	'PlayResX: 1920',
	'PlayResY: 1080',
	'',
	'[V4+ Styles]',
	'Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BorderStyle, Outline, Shadow, Alignment',
	'Style: Default,Arial,64,&H00FFFFFF,&H00000000,1,3,1,2',
	'',
	'[Events]',
	'Format: Layer, Start, End, Style, Text',
	'Dialogue: 0,0:00:00.00,9:00:00.00,Default,A subtitle line on screen',
	'',
}, '\n')
local EQ = { 'contrast', 'brightness', 'gamma', 'saturation', 'hue' }

local function upscale(...)
	mp.commandv('script-message-to', 'gpu_toggles', ...)
end

local steps, missed, total = 0, {}, 0
-- `target`: the gpu-toggles action count once everything sent so far is done.
local function step(label, target, detail)
	status.detail = detail
	write_progress()
	local before = compiles
	settle(target)
	local n = compiles - before
	steps = steps + 1
	total = total + n
	if n > 0 then
		missed[#missed + 1] = label .. ' (' .. n .. ')'
	end
	out(string.format('RESULT INFO %s: %d compiles', label, n))
	progress(steps, status.total, detail)
end

local function write_stamp()
	fingerprint.collect(function(result)
		resume(result)
	end)
	local fp = coroutine.yield()
	if not fingerprint.write(fingerprint.STAMP, fp, fingerprint.count_cache_files()) then
		out('RESULT FAIL shader cache stamp :: could not write ' .. fingerprint.path(fingerprint.STAMP))
		return false
	end
	fingerprint.remove(fingerprint.FAILED)
	return true
end

co = coroutine.create(function()
	local ok, err = ensure_clips(o.quick and QUICK or #runs)
	if not ok then
		out('RESULT FAIL warm-up clips :: ' .. err)
		return quit(2)
	end
	local t_start = mp.get_time()
	mp.set_property_native('pause', true)
	-- --untimed playback runs as fast as frames are made (with --vo=null, a whole
	-- clip between two checks): a looping clip never reaches an end where
	-- frame-step and play_frames would stall
	mp.set_property('loop-file', 'inf')
	-- the UI overlay (uosc) and OSD text are passes too
	mp.commandv('script-binding', 'uosc/flash-ui')
	local limit = o.quick and QUICK or #runs
	status.total = limit * STEPS_PER_RUN + (o.quick and 0 or learned_steps())
	local quick_ok = false
	local i = 0
	while i < limit do
		i = i + 1
		local r = runs[i]
		local tag = r.hwdec .. ' ' .. r.size .. ' ' .. r.fmt.tag
		local where = r.size .. ' ' .. r.fmt.bits .. ' · ' .. (PATHS[r.hwdec] or r.hwdec)
		local done = actions_done()
		mp.set_property('hwdec', r.hwdec)
		upscale('set-upscale', '0')
		upscale('set-movie-sharpness', 'auto')
		mp.commandv('loadfile', r.path, 'replace')
		if not wait_restart(20) then
			out('RESULT FAIL ' .. tag .. ' :: did not start playing')
			slow_steps = slow_steps + 1
		else
			-- the two messages above + gpu-toggles' own file-loaded re-evaluation
			step(tag .. ' off', done + 3, 'No upscaler · ' .. where)
			upscale('set-upscale', '2')
			step(tag .. ' Anime', done + 4, 'Anime · ' .. where)
			upscale('set-upscale', '3')
			step(tag .. ' Movie', done + 5, 'Movie · ' .. where)
			upscale('set-movie-sharpness', '0')
			step(tag .. ' Movie, sharpening off', done + 6, 'Movie, no sharpening · ' .. where)
		end
		if o.quick and i == limit and limit < #runs then
			if total == 0 then
				quick_ok = true
			else
				-- something changed: do everything
				limit = #runs
				status.title = 'Compiling shaders'
				status.total = limit * STEPS_PER_RUN + learned_steps()
				ok, err = ensure_clips(limit)
				if not ok then
					out('RESULT FAIL warm-up clips :: ' .. err)
					return quit(2)
				end
			end
		end
	end
	-- the shipped and the learned cases, in a full warm-up (a quick one that
	-- found nothing stops above: the cache was current for the matrix, and so
	-- for them)
	if not quick_ok and (#shipped > 0 or #learned > 0 or learned_idle) then
		local CHAIN_MODE = { off = '0', anime = '2', movie = '3' }
		local overlay_file = #shipped > 0 and aux_file('warmup-overlay.bgra', string.rep('\255\255\255\128', 64 * 64))
		local subs_file = #shipped > 0 and aux_file('warmup-subs.ass', SUBS_ASS)
		local function replay(c, kind)
			local what = kind == 'shipped' and cases.describe_shipped(c) or cases.describe(c)
			local path = ensure_case_clip(c, kind, what)
			if not path then
				return
			end
			local label = kind .. ' ' .. what
			local done = actions_done()
			-- the displayed scale: a shipped case is fitted, 1:1 or at the scale
			-- of its as_size; a learned one has its ratio. Both by video-zoom
			-- (a power of 2) on top of the fit r0 of this window.
			local zoom = 0
			local d = mp.get_property_native('osd-dimensions') or {}
			local w, h = c.w or (c.clip or {}).w, c.h or (c.clip or {}).h
			local ratio = c.ratio
			if c.as_size and d.w and d.w > 0 and d.h > 0 then
				ratio = math.min(d.w / c.as_size[1], d.h / c.as_size[2])
			end
			if ratio and w and h and d.w and d.w > 0 and d.h > 0 then
				local r0 = math.min(d.w / w, d.h / h)
				zoom = math.max(-6, math.min(3, math.log(ratio / r0) / math.log(2)))
			end
			mp.set_property_number('video-zoom', zoom)
			mp.set_property_native('video-unscaled', c.unscaled == true)
			mp.set_property_native('deband', c.deband ~= false)
			for _, p in ipairs(EQ) do
				mp.set_property_number(p, (c.eq or {})[p] or 0)
			end
			mp.set_property_number('video-rotate', c.rotate or 0)
			mp.set_property('hwdec', c.hwdec or 'no')
			upscale('set-upscale', CHAIN_MODE[c.chain] or '0')
			upscale('set-movie-sharpness', c.sharpen and tostring(c.sharpen) or 'auto')
			mp.commandv('loadfile', path, 'replace')
			if not wait_restart(20) then
				out('RESULT FAIL ' .. label .. ' :: did not start playing')
				slow_steps = slow_steps + 1
				return
			end
			if c.subs and subs_file then
				mp.commandv('sub-add', subs_file, 'select')
			end
			if c.overlay and overlay_file then
				mp.commandv('overlay-add', '1', '40', '40', overlay_file, '0', 'bgra', '64', '64', '256')
			end
			step(label, done + 3, (kind == 'shipped' and 'Shipped case · ' or 'Learned case · ') .. what)
			if c.overlay then
				mp.commandv('overlay-remove', '1')
			end
		end
		for _, c in ipairs(shipped) do
			replay(c, 'shipped')
		end
		for _, c in ipairs(learned) do
			replay(c, 'learned')
		end
		-- back to the player's defaults for what follows
		mp.set_property_number('video-zoom', 0)
		mp.set_property_native('video-unscaled', false)
		mp.set_property_native('deband', true)
		for _, p in ipairs(EQ) do
			mp.set_property_number(p, 0)
		end
		mp.set_property_number('video-rotate', 0)
		if learned_idle then
			-- mpv's empty window: no video, only the UI over the background
			local before = compiles
			status.detail = 'Learned case · empty window'
			write_progress()
			mp.command('stop')
			sleep(0.6)
			local n = compiles - before
			steps, total = steps + 1, total + n
			if n > 0 then
				missed[#missed + 1] = 'learned empty window (' .. n .. ')'
			end
			out(string.format('RESULT INFO learned empty window: %d compiles', n))
			progress(steps, status.total, status.detail)
		end
	end
	upscale('set-movie-sharpness', 'auto')
	upscale('set-upscale', '1')
	if pipelines > 0 then
		out(string.format('RESULT INFO %d pipelines compiled by the GPU driver (no cached binary)', pipelines))
	end
	local timing = string.format('in %.1f s (%.1f s of it compiling)', mp.get_time() - t_start, work_ms / 1000)
	-- A step that never got its frames drawn proves nothing (a minimized window
	-- draws nothing and would otherwise "pass" with 0 compiles).
	local stalled = slow_steps > 0
			and string.format('%d of %d steps were never drawn (stuck for %d s)', slow_steps, steps, SETTLE_CAP)
		or nil
	if o.check then
		if stalled then
			out('RESULT FAIL shader cache is warm for every chain :: ' .. stalled)
		elseif total == 0 then
			out(
				string.format(
					'RESULT PASS shader cache is warm for every chain (%d steps, 0 compiles, %s)',
					steps,
					timing
				)
			)
		else
			out(
				string.format(
					'RESULT FAIL shader cache is warm for every chain :: %d compiles in %d of %d steps: %s'
						.. ' - run installer\\warm-shader-cache.ps1',
					total,
					#missed,
					steps,
					table.concat(missed, ', ')
				)
			)
		end
		return quit((stalled or total > 0) and 1 or 0)
	end
	if stalled then
		out('RESULT FAIL warm-up :: ' .. stalled .. ' - no stamp written')
		return quit(6)
	end
	progress(status.total, status.total, 'Saving')
	if not write_stamp() then
		return quit(4)
	end
	if quick_ok then
		out(
			string.format(
				'RESULT INFO quick check: 0 compiles over %d steps %s - cache current, stamp written',
				steps,
				timing
			)
		)
	else
		out(string.format('RESULT INFO warmed: %d compiles over %d steps %s, stamp written', total, steps, timing))
	end
	quit(0)
end)

mp.add_timeout(0.2, resume)
-- a hard stop so it can never hang unseen
mp.add_timeout(240, function()
	out('RESULT FAIL warm-up :: still running after 240 s')
	quit(3)
end)
